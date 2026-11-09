import Foundation
import Network
import Combine
import CryptoKit

/// Where the device catalog keeps per-device secrets: auth tokens and saved passwords. The app
/// uses the login keychain; tests pass an in-memory store so they never touch it.
protocol DeviceCredentialStore {
    func token(host: String, port: Int) -> String?
    @discardableResult
    func setToken(_ token: String, host: String, port: Int) -> Bool
    func deleteToken(host: String, port: Int)
    func password(host: String, port: Int) -> String?
    func deletePassword(host: String, port: Int)
}

/// The keychain-backed stores the catalog has always used.
struct KeychainDeviceCredentials: DeviceCredentialStore {
    func token(host: String, port: Int) -> String? {
        KeychainTokenStore.token(host: host, port: port)
    }

    @discardableResult
    func setToken(_ token: String, host: String, port: Int) -> Bool {
        KeychainTokenStore.setToken(token, host: host, port: port)
    }

    func deleteToken(host: String, port: Int) {
        _ = KeychainTokenStore.deleteToken(host: host, port: port)
    }

    func password(host: String, port: Int) -> String? {
        DevicePasswordStore.load(host: host, port: port)
    }

    func deletePassword(host: String, port: Int) {
        DevicePasswordStore.delete(host: host, port: port)
    }
}

/// A device leaving the catalog, as a session connected to it needs to hear about it.
enum KVMDeviceRemoval: Equatable {
    /// `removeDevice`: that one list entry, by id.
    case removed(id: String)
    /// `forgetDevice`: the device and everything saved for each of its addresses.
    case forgotten(id: String, addresses: [DeviceAddress])
}

/// A device that changed in the catalog, as a session connected to it needs to hear about it.
struct KVMDeviceUpdate: Equatable {
    /// The catalog's entry now.
    let device: KVMDevice
    /// Ids of entries the device took the place of.
    let replacedIDs: Set<String>

    static func == (lhs: KVMDeviceUpdate, rhs: KVMDeviceUpdate) -> Bool {
        lhs.device.id == rhs.device.id
            && lhs.device.nickname == rhs.device.nickname
            && lhs.device.addresses == rhs.device.addresses
            && lhs.replacedIDs == rhs.replacedIDs
    }

    /// Whether a session connected to `connected` should take this update.
    func applies(to connected: KVMDevice) -> Bool {
        connected.id == device.id || replacedIDs.contains(connected.id)
    }

    /// The device a session connected to `connected` holds after this update: the new name and
    /// addresses, still connected through the same address with the same token.
    func applied(to connected: KVMDevice) -> KVMDevice {
        var updated = device.via(connected.address)
        updated.authToken = connected.authToken
        return updated
    }
}

/// The devices the app knows about: discovered by a scan, added by hand, or saved after a
/// connection. Shared by the whole app; which device a console is connected to is that console's
/// business, and lives in its `SessionConnection`.
@MainActor
final class KVMDeviceManager: NSObject, ObservableObject {
    @Published var availableDevices: [KVMDevice] = []
    @Published var isScanning = false
    @Published var scanProgress: Double = 0.0
    @Published var autoScanEnabled: Bool = false

    /// Announces removed and forgotten devices. The catalog does not know which sessions exist,
    /// so each session watches this and lets go of a device it was connected to.
    let deviceRemovals = PassthroughSubject<KVMDeviceRemoval, Never>()

    /// Announces a device whose nickname or addresses changed, or that took over other entries
    /// (an unsaved entry saved by the Edit sheet, a separate entry linked as another address).
    /// A session connected to any of `replacedIDs` or to `device.id` takes the new details and
    /// keeps the address it is connected through.
    let deviceUpdates = PassthroughSubject<KVMDeviceUpdate, Never>()
    
    private var networkMonitor: NWPathMonitor?
    private var scanTimer: Timer?
    private var deviceDiscoverySessions: [NWBrowser] = []

    // The running scan and its generation. Results are only published when the generation still
    // matches, so a cancelled scan never overwrites the device list after the fact.
    private var scanTask: Task<Void, Never>?
    private var scanGeneration = 0
    /// Upper bound on simultaneous TCP probes during the /24 sweep. 64 was enough to trip
    /// rate limiting on some Wi-Fi routers and starve the mDNS browsers running alongside.
    private static let maximumConcurrentProbes = 16

    /// Discovery probes accept any certificate: they hit arbitrary LAN hosts, send no credentials,
    /// and must not pin whatever those hosts present. Real connections go through DeviceTrustStore.
    private final class ProbeTLSDelegate: NSObject, URLSessionDelegate {
        func urlSession(
            _ session: URLSession,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
               let trust = challenge.protectionSpace.serverTrust {
                completionHandler(.useCredential, URLCredential(trust: trust))
                return
            }
            completionHandler(.performDefaultHandling, nil)
        }
    }

    private let probeSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 3
        return URLSession(configuration: config, delegate: ProbeTLSDelegate(), delegateQueue: nil)
    }()

    private let commonProbeTargets: [(host: String, port: Int)] = [
        ("192.168.200.5", 443),
        ("192.168.200.1", 443),
        ("192.168.200.1", 80),
    ]

    /// One record per host:port, written by versions before devices had several addresses.
    /// Read once to migrate, then left as it is, so going back to an earlier build still finds
    /// the devices that were saved then.
    static let legacySavedDevicesKey = "overlook.saved_devices.v1"
    /// A copy of the legacy records made when they are migrated, untouched afterwards.
    static let legacyBackupKey = "overlook.saved_devices.v1.backup"
    /// One record per device, with all of its addresses.
    static let savedDevicesKey = "overlook.saved_devices.v2"

    private struct PersistedDevice: Codable, Hashable {
        let host: String
        let port: Int
        let name: String
        let type: KVMDeviceType
        /// Legacy: tokens now live in the keychain (KeychainTokenStore). Only present in records
        /// written before the migration; never written anymore.
        let authToken: String?
        let capabilities: Set<KVMCapability>
    }

    /// A saved device as `savedDevicesKey` holds it. Its token, saved password and certificate
    /// pin stay where they always were, keyed by each address's host:port.
    private struct StoredDevice: Codable {
        var id: String
        var nickname: String?
        var addresses: [DeviceAddress]
        var lastUsed: DeviceAddress?
        var type: KVMDeviceType
        var capabilities: Set<KVMCapability>
    }
    
    private let defaults: UserDefaults
    private let credentials: DeviceCredentialStore
    private let trustStore: DeviceTrustStore

    /// The parameters are for tests, which hand in a scratch defaults suite, an in-memory
    /// credential store and a trust store of their own. The app takes the defaults.
    init(
        defaults: UserDefaults = .standard,
        credentials: DeviceCredentialStore = KeychainDeviceCredentials(),
        trustStore: DeviceTrustStore = .shared
    ) {
        self.defaults = defaults
        self.credentials = credentials
        self.trustStore = trustStore
        super.init()
        setupNetworkMonitoring()
        loadPersistedDevices()
    }
    
    private func setupNetworkMonitoring() {
        networkMonitor = NWPathMonitor()
        networkMonitor?.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                if path.status == .satisfied, self?.autoScanEnabled == true {
                    self?.scanForDevices()
                }
            }
        }
        
        let queue = DispatchQueue(label: "com.overlook.network")
        networkMonitor?.start(queue: queue)
    }
    
    func scanForDevices() {
        guard !isScanning else { return }

        scanGeneration += 1
        let generation = scanGeneration
        isScanning = true
        scanProgress = 0.0
        let pinnedDevices = availableDevices.filter { $0.id.hasPrefix("manual-") || $0.isSaved }
        availableDevices = pinnedDevices

        // Start multiple discovery methods
        scanTask = Task { [weak self] in
            guard let self else { return }
            await withTaskGroup(of: [KVMDevice].self) { group in
                // GL.iNet Comet discovery
                group.addTask {
                    await self.discoverGLiNetDevices()
                }
                
                // Generic KVM discovery
                group.addTask {
                    await self.discoverGenericKVMDevices()
                }
                
                // Network scan for known ports
                group.addTask {
                    await self.scanKnownPorts()
                }

                // Quick probe for common/default KVM addresses
                group.addTask {
                    await self.probeCommonTargets()
                }
                
                // Tailscale network discovery
                group.addTask {
                    await self.discoverTailscaleDevices()
                }
                
                // Collect results
                var allDevices: [KVMDevice] = []
                let pinnedDevices = await MainActor.run {
                    self.availableDevices.filter { $0.id.hasPrefix("manual-") || $0.isSaved }
                }

                for await devices in group {
                    if Task.isCancelled {
                        group.cancelAll()
                        return
                    }
                    allDevices.append(contentsOf: devices)

                    let found = allDevices
                    await MainActor.run {
                        guard self.scanGeneration == generation else { return }
                        self.availableDevices = Self.mergeListed(pinnedDevices + found)
                    }
                }

                await MainActor.run {
                    guard self.scanGeneration == generation else { return }
                    self.finishScan()
                }
            }
        }

        // Update progress
        scanTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.scanProgress < 0.9 else { return }
                self.scanProgress += 0.05
            }
        }
    }

    /// Stops a scan in progress. Probes already in flight finish on their own, but their results
    /// are discarded and the device list keeps whatever it showed at the time of the call.
    func cancelScan() {
        scanGeneration += 1
        scanTask?.cancel()
        finishScan()
    }

    private func finishScan() {
        scanTask = nil
        isScanning = false
        scanProgress = 1.0
        scanTimer?.invalidate()
        scanTimer = nil
    }

    private func discoverGLiNetDevices() async -> [KVMDevice] {
        actor DeviceCollector {
            private var devices: [KVMDevice] = []
            func add(_ device: KVMDevice) {
                devices.append(device)
            }
            func all() -> [KVMDevice] {
                devices
            }
        }

        let collector = DeviceCollector()
        
        // GL.iNet Comet uses mDNS/Bonjour discovery
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_comet._tcp", domain: nil), using: .tcp)
        
        return await withCheckedContinuation { continuation in
            browser.browseResultsChangedHandler = { results, changes in
                for result in results {
                    let device = Self.createGLiNetDevice(from: result.endpoint)
                    Task {
                        await collector.add(device)
                    }
                }
            }
            
            browser.start(queue: DispatchQueue(label: "com.overlook.glinet"))
            
            // Stop after 5 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                Task {
                    let devices = await collector.all()
                    browser.cancel()
                    continuation.resume(returning: devices)
                }
            }
        }
    }
    
    nonisolated private static func createGLiNetDevice(from endpoint: NWEndpoint) -> KVMDevice {
        var name = "GL.iNet Comet"
        var host = ""
        let port = 443
        
        if case .service(let serviceName, let type, let domain, _) = endpoint {
            name = serviceName
            host = "\(serviceName).\(type).\(domain)"
        }
        
        return KVMDevice(
            id: "glinet-\(UUID().uuidString)",
            nickname: name,
            host: host,
            port: port,
            type: .glinetComet,
            authToken: "",
            capabilities: [.videoStreaming, .keyboardInput, .mouseInput, .virtualMedia, .powerManagement]
        )
    }
    
    private func discoverGenericKVMDevices() async -> [KVMDevice] {
        actor DeviceCollector {
            private var devices: [KVMDevice] = []
            func add(_ device: KVMDevice) {
                devices.append(device)
            }
            func all() -> [KVMDevice] {
                devices
            }
        }

        let collector = DeviceCollector()
        
        // Generic KVM discovery via mDNS
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_kvm._tcp", domain: nil), using: .tcp)
        
        return await withCheckedContinuation { continuation in
            browser.browseResultsChangedHandler = { results, changes in
                for result in results {
                    let device = Self.createGenericKVMDevice(from: result.endpoint)
                    Task {
                        await collector.add(device)
                    }
                }
            }
            
            browser.start(queue: DispatchQueue(label: "com.overlook.generic"))
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                Task {
                    let devices = await collector.all()
                    browser.cancel()
                    continuation.resume(returning: devices)
                }
            }
        }
    }
    
    nonisolated private static func createGenericKVMDevice(from endpoint: NWEndpoint) -> KVMDevice {
        var name = "Generic KVM"
        var host = ""
        let port = 8080
        
        if case .service(let serviceName, let type, let domain, _) = endpoint {
            name = serviceName
            host = "\(serviceName).\(type).\(domain)"
        }
        
        return KVMDevice(
            id: "generic-\(UUID().uuidString)",
            nickname: name,
            host: host,
            port: port,
            type: .generic,
            authToken: "",
            capabilities: [.videoStreaming, .keyboardInput, .mouseInput]
        )
    }
    
    private func scanKnownPorts() async -> [KVMDevice] {
        var devices: [KVMDevice] = []
        
        // Common KVM ports to scan
        let knownPorts = [443, 8443, 80, 8080]
        let localNetwork = getLocalNetworkRange()

        let maxConcurrent = Self.maximumConcurrentProbes
        var targets: [(host: String, port: Int)] = []
        targets.reserveCapacity(localNetwork.count * knownPorts.count)
        for host in localNetwork {
            for port in knownPorts {
                targets.append((host: host, port: port))
            }
        }

        await withTaskGroup(of: KVMDevice?.self) { group in
            var nextIndex = 0
            var inFlight = 0

            while nextIndex < targets.count || inFlight > 0 {
                if Task.isCancelled {
                    group.cancelAll()
                    return
                }
                while inFlight < maxConcurrent && nextIndex < targets.count {
                    let target = targets[nextIndex]
                    nextIndex += 1
                    inFlight += 1
                    group.addTask {
                        await self.checkKVMService(host: target.host, port: target.port)
                    }
                }

                if let device = await group.next() {
                    inFlight -= 1
                    if let device {
                        devices.append(device)
                    }
                }
            }
        }
        
        return devices
    }
    
    private func getLocalNetworkRange() -> [String] {
        var prefixes: Set<String> = []
        var hosts: [String] = []

        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0, let first = ifaddr {
            defer { freeifaddrs(ifaddr) }

            var ptr: UnsafeMutablePointer<ifaddrs>? = first
            while let p = ptr {
                defer { ptr = p.pointee.ifa_next }
                guard let addr = p.pointee.ifa_addr else { continue }
                if addr.pointee.sa_family != UInt8(AF_INET) { continue }

                let flags = Int32(p.pointee.ifa_flags)
                if (flags & IFF_LOOPBACK) != 0 { continue }

                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let result = getnameinfo(
                    addr,
                    socklen_t(addr.pointee.sa_len),
                    &hostname,
                    socklen_t(hostname.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )
                if result != 0 { continue }
                let ip = String(cString: hostname)

                let parts = ip.split(separator: ".")
                guard parts.count == 4 else { continue }

                // Only scan typical private IPv4 ranges.
                let p0 = Int(parts[0]) ?? 0
                let p1 = Int(parts[1]) ?? 0
                let isPrivate = (p0 == 10) || (p0 == 192 && p1 == 168) || (p0 == 172 && (16...31).contains(p1))
                guard isPrivate else { continue }

                // Pragmatic /24 scan based on the interface IP.
                prefixes.insert("\(parts[0]).\(parts[1]).\(parts[2])")
            }
        }

        if prefixes.isEmpty {
            prefixes = [
                "192.168.1",
                "192.168.0",
                "10.0.0",
            ]
        }

        prefixes.insert("192.168.200")

        for prefix in prefixes {
            for i in 1...254 {
                hosts.append("\(prefix).\(i)")
            }
        }

        return hosts
    }

    private func probeCommonTargets() async -> [KVMDevice] {
        var devices: [KVMDevice] = []
        for target in commonProbeTargets {
            if let device = await checkKVMService(host: target.host, port: target.port) {
                devices.append(device)
                continue
            }

            // If the port is open but the HTTP probe didn't identify the service,
            // still surface it for the common/default targets (helps with devices
            // that redirect/behave oddly on probe endpoints).
            if await probeTCPPortOpen(host: target.host, port: target.port) {
                devices.append(
                    KVMDevice(
                        id: "scanned-\(target.host)-\(target.port)",
                        host: target.host,
                        port: target.port,
                        type: .glinetComet,
                        authToken: "",
                        capabilities: [.videoStreaming, .keyboardInput, .mouseInput, .virtualMedia, .powerManagement]
                    )
                )
            }
        }
        return devices
    }

    private func probeTCPPortOpen(host: String, port: Int, timeout: TimeInterval = 0.7) async -> Bool {
        guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            return false
        }

        final class Flag {
            var value: Bool = false
        }

        let queue = DispatchQueue(label: "com.overlook.probe.port")
        let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)

        return await withCheckedContinuation { continuation in
            let finished = Flag()

            let timeoutWorkItem = DispatchWorkItem {
                if finished.value { return }
                finished.value = true
                connection.stateUpdateHandler = nil
                connection.cancel()
                continuation.resume(returning: false)
            }

            queue.asyncAfter(deadline: .now() + timeout, execute: timeoutWorkItem)

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if finished.value { return }
                    finished.value = true
                    timeoutWorkItem.cancel()
                    connection.stateUpdateHandler = nil
                    connection.cancel()
                    continuation.resume(returning: true)
                case .failed, .cancelled:
                    if finished.value { return }
                    finished.value = true
                    timeoutWorkItem.cancel()
                    connection.stateUpdateHandler = nil
                    connection.cancel()
                    continuation.resume(returning: false)
                default:
                    break
                }
            }

            connection.start(queue: queue)
        }
    }
    
    private func checkKVMService(host: String, port: Int) async -> KVMDevice? {
        // A closed or absent port is rejected by one TCP probe in about a second; the HTTP probes
        // below would each wait out their own timeouts on it, several times over per target.
        guard await probeTCPPortOpen(host: host, port: port, timeout: 1.0) else { return nil }

        if await probeGLKVM(host: host, port: port) {
            return KVMDevice(
                id: "scanned-\(host)-\(port)",
                host: host,
                port: port,
                type: .glinetComet,
                authToken: "",
                capabilities: [.videoStreaming, .keyboardInput, .mouseInput, .virtualMedia, .powerManagement]
            )
        }

        if await probeWebUIKeywords(host: host, port: port) {
            return KVMDevice(
                id: "scanned-\(host)-\(port)",
                host: host,
                port: port,
                type: .generic,
                authToken: "",
                capabilities: [.videoStreaming, .keyboardInput, .mouseInput]
            )
        }

        return nil
    }

    private func probeGLKVM(host: String, port: Int) async -> Bool {
        let preferredSchemes: [String] = (port == 443 || port == 8443) ? ["https", "http"] : ["http", "https"]

        let paths = [
            "api/auth/check",
            "api/init/is_inited",
        ]

        for scheme in preferredSchemes {
            for path in paths {
                guard let url = URL(string: "\(scheme)://\(host):\(port)/\(path)") else { continue }
                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                request.timeoutInterval = 3

                do {
                    let (_, response) = try await probeSession.data(for: request)
                    guard let http = response as? HTTPURLResponse else { continue }

                    switch http.statusCode {
                    case 200, 401, 403, 301, 302, 307, 308:
                        return true
                    default:
                        continue
                    }
                } catch {
                    continue
                }
            }
        }

        return false
    }

    private func probeWebUIKeywords(host: String, port: Int) async -> Bool {
        let preferredSchemes: [String] = (port == 443 || port == 8443) ? ["https", "http"] : ["http", "https"]

        for scheme in preferredSchemes {
            guard let url = URL(string: "\(scheme)://\(host):\(port)/") else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 2

            do {
                let (data, response) = try await probeSession.data(for: request)
                guard let http = response as? HTTPURLResponse else { continue }
                guard (200...399).contains(http.statusCode) else { continue }
                let text = String(decoding: data.prefix(4096), as: UTF8.self).lowercased()

                if text.contains("kvmd") || text.contains("glkvm") || text.contains("comet") || text.contains("kvm") {
                    return true
                }
            } catch {
                continue
            }
        }

        return false
    }
    
    private func discoverTailscaleDevices() async -> [KVMDevice] {
        var devices: [KVMDevice] = []
        
        // Check if Tailscale is available and discover devices on Tailscale network
        let tailscaleHosts = await getTailscaleHosts()
        
        for host in tailscaleHosts {
            if let device = await checkTailscaleKVM(host: host) {
                devices.append(device)
            }
        }
        
        return devices
    }
    
    private func getTailscaleHosts() async -> [String] {
        // Get Tailscale network hosts
        // This would typically involve calling tailscale API or parsing status output
        return []
    }
    
    private func checkTailscaleKVM(host: String) async -> KVMDevice? {
        // Check common KVM ports on Tailscale hosts
        let ports = [8443, 8080, 443]
        
        for port in ports {
            if let device = await checkKVMService(host: host, port: port) {
                var tailscaleDevice = device
                tailscaleDevice.type = .tailscale
                return tailscaleDevice
            }
        }
        
        return nil
    }
    
    /// The device list as shown: saved devices first claim every one of their addresses, then
    /// each other entry is kept unless its address is already claimed, so a scan that finds a
    /// saved device's address (any of them) shows that device rather than a second entry.
    /// Sorted by the name shown, the address breaking ties.
    nonisolated static func mergeListed(_ devices: [KVMDevice]) -> [KVMDevice] {
        var kept: [KVMDevice] = []
        var claimed: Set<DeviceAddress> = []
        let ordered = devices.filter(\.isSaved) + devices.filter { !$0.isSaved }
        for device in ordered {
            if device.isSaved {
                guard !kept.contains(where: { $0.id == device.id }) else { continue }
                if claimed.contains(device.address) && device.addresses.allSatisfy(claimed.contains) {
                    continue
                }
            } else if claimed.contains(device.address) {
                continue
            }
            kept.append(device)
            claimed.insert(device.address)
            claimed.formUnion(device.addresses)
        }
        return sorted(kept)
    }

    nonisolated static func sorted(_ devices: [KVMDevice]) -> [KVMDevice] {
        devices.sorted { lhs, rhs in
            let order = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
            if order != .orderedSame {
                return order == .orderedAscending
            }
            return lhs.address.hostPort < rhs.address.hostPort
        }
    }
    
    @discardableResult
    func addManualDevice(host: String, port: Int, type: KVMDeviceType, authToken: String = "") -> KVMDevice {
        let device = KVMDevice(
            id: "manual-\(UUID().uuidString)",
            host: host,
            port: port,
            type: type,
            authToken: authToken,
            capabilities: [.videoStreaming, .keyboardInput, .mouseInput]
        )
        
        availableDevices.append(device)
        return device
    }
    
    func removeDevice(_ device: KVMDevice) {
        availableDevices.removeAll { $0.id == device.id }
        deviceRemovals.send(.removed(id: device.id))
    }

    /// Forgets a device and everything saved for any of its addresses: the record, the tokens,
    /// the saved passwords and the certificate pins.
    func forgetDevice(_ device: KVMDevice) {
        var current = readStoredDevices()
        let index = current.firstIndex { $0.id == device.id }
            ?? current.firstIndex { $0.addresses.contains(device.address) }
        var addresses = index.map { current[$0].addresses } ?? []
        for address in [device.address] + device.addresses where !addresses.contains(address) {
            addresses.append(address)
        }
        let forgottenID = index.map { current[$0].id } ?? device.id
        if let index {
            current.remove(at: index)
            writeStoredDevices(current)
        }
        for address in addresses {
            credentials.deleteToken(host: address.host, port: address.port)
            credentials.deletePassword(host: address.host, port: address.port)
            trustStore.reset(host: address.host, port: address.port)
        }

        availableDevices.removeAll { $0.id == forgottenID || $0.id == device.id || addresses.contains($0.address) }
        deviceRemovals.send(.forgotten(id: forgottenID, addresses: addresses))
    }

    /// The listed entry at `address`: the one using it, else the one that has it among its
    /// addresses.
    func device(at address: DeviceAddress) -> KVMDevice? {
        availableDevices.first { $0.address == address }
            ?? availableDevices.first { $0.includes(address) }
    }

    /// The saved device that has `address` among its addresses, if any.
    func savedDevice(containing address: DeviceAddress) -> KVMDevice? {
        availableDevices.first { $0.isSaved && $0.addresses.contains(address) }
    }

    /// The saved device other than `excludingID` that already has `address`. An address belongs
    /// to one device at most, so the Edit sheet refuses one that is taken.
    func owner(of address: DeviceAddress, excludingID: String?) -> KVMDevice? {
        availableDevices.first { $0.isSaved && $0.id != excludingID && $0.addresses.contains(address) }
    }

    /// Replaces the listed entry with the same id, if there is one. A connect uses it to show a
    /// fresh token in the list before the device is saved.
    func updateDevice(_ device: KVMDevice) {
        if let index = availableDevices.firstIndex(where: { $0.id == device.id }) {
            var updated = device
            // A connect hands in the device as it connects (`via`), which may not be the
            // address the list shows for it.
            let listed = availableDevices[index]
            updated.host = listed.host
            updated.port = listed.port
            availableDevices[index] = updated
        }
    }

    // MARK: - Saving

    /// Saves a device a session has just connected to, with its token in the credential store,
    /// and lists it under its saved id in place of whatever entry it was connected from.
    ///
    /// A device already saved keeps its nickname and its addresses; the address connected
    /// through becomes its last-used one. An address that no saved device has is saved as a new
    /// device with that one address.
    func persistDevice(_ device: KVMDevice) -> KVMDevice {
        let address = device.address
        var current = readStoredDevices()
        let record: StoredDevice
        if let index = current.firstIndex(where: { $0.id == device.id })
            ?? current.firstIndex(where: { $0.addresses.contains(address) }) {
            var existing = current[index]
            if existing.addresses.contains(address) {
                existing.lastUsed = address
            }
            existing.capabilities = device.capabilities
            current[index] = existing
            record = existing
        } else {
            record = StoredDevice(
                id: uniqueSavedID(for: address, among: current),
                nickname: DeviceNaming.cleanNickname(device.nickname),
                addresses: [address],
                lastUsed: address,
                type: device.type,
                capabilities: device.capabilities
            )
            current.append(record)
        }
        writeStoredDevices(current)
        credentials.setToken(device.authToken, host: address.host, port: address.port)

        var saved = makeDevice(from: record, token: device.authToken).via(address)
        saved.authToken = device.authToken
        list(makeDevice(from: record, token: device.authToken), replacing: [device.id])
        return saved
    }

    /// Records the address the next plain Connect uses. The Connect menu calls this as soon as
    /// an address is picked, so the next plain Connect repeats the operator's choice whether or
    /// not that connect got through.
    func setLastUsedAddress(_ address: DeviceAddress, for device: KVMDevice) {
        var current = readStoredDevices()
        guard let index = current.firstIndex(where: { $0.id == device.id }),
              current[index].addresses.contains(address) else { return }
        current[index].lastUsed = address
        writeStoredDevices(current)
        let token = availableDevices.first { $0.id == device.id }?.authToken ?? device.authToken
        let entry = makeDevice(from: current[index], token: token)
        list(entry, replacing: [])
        deviceUpdates.send(KVMDeviceUpdate(device: entry, replacedIDs: []))
    }

    /// The Edit sheet's Save: the nickname (nil shows the address) and the address list, in
    /// order. A device that is not saved yet is saved by this. An address new to the device gets
    /// the device's token under its own host:port, unless that already has one. Nothing stored
    /// for a removed address is deleted.
    @discardableResult
    func saveEdits(of device: KVMDevice, nickname: String?, addresses: [DeviceAddress]) -> KVMDevice? {
        var unique: [DeviceAddress] = []
        for address in addresses where !unique.contains(address) {
            unique.append(address)
        }
        guard !unique.isEmpty else { return nil }

        var current = readStoredDevices()
        let previousAddresses: [DeviceAddress]
        var record: StoredDevice
        if let index = current.firstIndex(where: { $0.id == device.id }) {
            previousAddresses = current[index].addresses
            record = current[index]
            record.nickname = DeviceNaming.cleanNickname(nickname)
            record.addresses = unique
            if let lastUsed = record.lastUsed, !unique.contains(lastUsed) {
                record.lastUsed = nil
            }
            current[index] = record
        } else {
            previousAddresses = device.addresses
            let lastUsed = unique.contains(device.address) ? device.address : nil
            record = StoredDevice(
                id: uniqueSavedID(for: unique[0], among: current),
                nickname: DeviceNaming.cleanNickname(nickname),
                addresses: unique,
                lastUsed: lastUsed,
                type: device.type,
                capabilities: device.capabilities
            )
            current.append(record)
        }
        writeStoredDevices(current)

        let token = device.authToken.isEmpty
            ? resolveToken(for: [device.address] + previousAddresses)
            : device.authToken
        copyToken(token, to: unique.filter { !previousAddresses.contains($0) })

        let entry = makeDevice(from: record, token: token)
        let replaced = device.id == entry.id ? [] : [device.id]
        list(entry, replacing: replaced)
        deviceUpdates.send(KVMDeviceUpdate(device: entry, replacedIDs: Set(replaced)))
        return entry
    }

    // MARK: - Credentials across addresses

    /// The token for a device: the first one stored under any of `addresses`, in that order.
    private func resolveToken(for addresses: [DeviceAddress]) -> String {
        for address in addresses {
            if let token = credentials.token(host: address.host, port: address.port), !token.isEmpty {
                return token
            }
        }
        return ""
    }

    /// Gives each of `addresses` that has no token of its own a copy of `token`.
    private func copyToken(_ token: String, to addresses: [DeviceAddress]) {
        guard !token.isEmpty else { return }
        for address in addresses where (credentials.token(host: address.host, port: address.port) ?? "").isEmpty {
            credentials.setToken(token, host: address.host, port: address.port)
        }
    }

    /// The password saved for a device, under the address it is connecting through first and
    /// then under each of its other addresses, with the address it was found under.
    func savedPassword(for device: KVMDevice) -> (password: String, address: DeviceAddress)? {
        var seen: [DeviceAddress] = []
        for address in [device.address] + device.addresses where !seen.contains(address) {
            seen.append(address)
            if let password = credentials.password(host: address.host, port: address.port), !password.isEmpty {
                return (password, address)
            }
        }
        return nil
    }

    // MARK: - Linking a new address to a saved device

    /// The saved device a just-connected entry is, judged by its certificate: the pin recorded
    /// for the address it connected through matches the pin of one of that device's addresses.
    /// Nil when the address has no pin (a certificate the system trusts is never pinned), or no
    /// other saved device has a matching one.
    func linkCandidate(for connected: KVMDevice) -> KVMDevice? {
        guard let pin = trustStore.pinnedFingerprint(host: connected.host, port: connected.port) else {
            return nil
        }
        return availableDevices.first { candidate in
            candidate.isSaved
                && candidate.id != connected.id
                && !candidate.addresses.contains(connected.address)
                && candidate.addresses.contains { address in
                    trustStore.pinnedFingerprint(host: address.host, port: address.port) == pin
                }
        }
    }

    /// Add address: `address`, which `source` was saved with on its own, becomes another address
    /// of `target`, and its last-used one. `source`'s record loses the address and goes when it
    /// has none left. Tokens and pins stay where they are; `target`'s token is copied to the
    /// address if it has none.
    @discardableResult
    func link(_ address: DeviceAddress, of source: KVMDevice, to target: KVMDevice) -> KVMDevice? {
        var current = readStoredDevices()
        guard let targetIndex = current.firstIndex(where: { $0.id == target.id }) else { return nil }
        if !current[targetIndex].addresses.contains(address) {
            current[targetIndex].addresses.append(address)
        }
        current[targetIndex].lastUsed = address
        let record = current[targetIndex]
        var removedIDs: [String] = []
        if source.id != target.id {
            removedIDs.append(source.id)
            if let sourceIndex = current.firstIndex(where: { $0.id == source.id }) {
                current[sourceIndex].addresses.removeAll { $0 == address }
                if current[sourceIndex].addresses.isEmpty {
                    current.remove(at: sourceIndex)
                } else {
                    removedIDs.removeAll()
                    list(makeDevice(from: current[sourceIndex], token: source.authToken), replacing: [])
                }
            }
        }
        writeStoredDevices(current)

        let token = resolveToken(for: [record.lastUsed].compactMap { $0 } + record.addresses)
        copyToken(token, to: [address])
        let entry = makeDevice(from: record, token: token)
        list(entry, replacing: removedIDs)
        deviceUpdates.send(KVMDeviceUpdate(device: entry, replacedIDs: Set(removedIDs + [source.id]).subtracting([entry.id])))
        return entry
    }

    // MARK: - Loading and storing

    /// The catalog entry for a stored device: at its preferred address, with its token found
    /// under any of its addresses (that one first) unless `token` is given.
    private func makeDevice(from record: StoredDevice, token: String? = nil) -> KVMDevice {
        var device = KVMDevice(
            id: record.id,
            nickname: record.nickname,
            host: record.addresses.first?.host ?? "",
            port: record.addresses.first?.port ?? AddressInput.defaultPort,
            addresses: record.addresses,
            lastUsedAddress: record.lastUsed,
            type: record.type,
            authToken: "",
            capabilities: record.capabilities
        )
        device = device.via(device.preferredAddress)
        if let token, !token.isEmpty {
            device.authToken = token
        } else {
            device.authToken = resolveToken(for: [device.preferredAddress] + record.addresses)
        }
        return device
    }

    /// Puts `entry` in the list in place of its own old entry, the entries `replacing` names,
    /// and any unsaved entry at one of its addresses.
    private func list(_ entry: KVMDevice, replacing ids: [String]) {
        availableDevices.removeAll { listed in
            listed.id == entry.id
                || ids.contains(listed.id)
                || (!listed.isSaved && entry.includes(listed.address))
        }
        availableDevices.append(entry)
        availableDevices = Self.mergeListed(availableDevices)
    }

    /// `saved-<host>-<port>` for the address a device was first saved with, as ids have always
    /// been made, with a suffix in the rare case that id is taken (the address was saved, then
    /// moved to another device).
    private func uniqueSavedID(for address: DeviceAddress, among records: [StoredDevice]) -> String {
        let base = savedDeviceId(host: address.host, port: address.port)
        var candidate = base
        var counter = 2
        while records.contains(where: { $0.id == candidate }) {
            candidate = "\(base)-\(counter)"
            counter += 1
        }
        return candidate
    }

    private func loadPersistedDevices() {
        let records: [StoredDevice]
        var unmovedTokens: [DeviceAddress: String] = [:]
        if defaults.object(forKey: Self.savedDevicesKey) != nil {
            records = readStoredDevices()
        } else {
            (records, unmovedTokens) = migrateLegacyRecords()
        }
        guard !records.isEmpty else { return }
        availableDevices = Self.mergeListed(records.map { record in
            makeDevice(from: record, token: record.addresses.lazy.compactMap { unmovedTokens[$0] }.first)
        })
    }

    /// The one-time move from one record per host:port to one record per device. Each legacy
    /// record becomes a device with that one address and the same id as before; a generated name
    /// becomes no nickname. The legacy records are left where they are and copied to a backup
    /// key; no token or pin is touched.
    ///
    /// A token the keychain refused to take is still only in its legacy record. It is used from
    /// there for this run, and the new records are not written, so the next launch migrates
    /// again rather than leave that token behind.
    private func migrateLegacyRecords() -> ([StoredDevice], [DeviceAddress: String]) {
        guard let data = defaults.data(forKey: Self.legacySavedDevicesKey) else { return ([], [:]) }
        let legacy = migrateLegacyTokens(readLegacyRecords())
        if defaults.object(forKey: Self.legacyBackupKey) == nil {
            defaults.set(data, forKey: Self.legacyBackupKey)
        }

        var devices: [StoredDevice] = []
        for record in legacy {
            let address = DeviceAddress(host: record.host, port: record.port)
            guard !devices.contains(where: { $0.addresses.contains(address) }) else { continue }
            devices.append(StoredDevice(
                id: savedDeviceId(host: record.host, port: record.port),
                nickname: DeviceNaming.nickname(fromLegacyName: record.name),
                addresses: [address],
                lastUsed: nil,
                type: record.type,
                capabilities: record.capabilities
            ))
        }
        var unmovedTokens: [DeviceAddress: String] = [:]
        for record in legacy {
            if let token = record.authToken, !token.isEmpty {
                unmovedTokens[DeviceAddress(host: record.host, port: record.port)] = token
            }
        }
        if !legacy.isEmpty, unmovedTokens.isEmpty {
            writeStoredDevices(devices)
        }
        return (devices, unmovedTokens)
    }

    /// One-time migration: records written before tokens moved to the keychain still carry the
    /// token in UserDefaults. Move it and rewrite the record without it — but only once the
    /// keychain write has succeeded, so a refused write does not lose the token.
    private func migrateLegacyTokens(_ records: [PersistedDevice]) -> [PersistedDevice] {
        var rewritten: [PersistedDevice] = []
        var needsRewrite = false
        for record in records {
            var stored = record
            if let legacy = record.authToken, !legacy.isEmpty {
                let current = credentials.token(host: record.host, port: record.port) ?? ""
                let token = current.isEmpty ? legacy : current
                if credentials.setToken(token, host: record.host, port: record.port) {
                    stored = PersistedDevice(
                        host: record.host,
                        port: record.port,
                        name: record.name,
                        type: record.type,
                        authToken: nil,
                        capabilities: record.capabilities
                    )
                    needsRewrite = true
                }
            }
            rewritten.append(stored)
        }
        if needsRewrite, let data = try? JSONEncoder().encode(rewritten) {
            defaults.set(data, forKey: Self.legacySavedDevicesKey)
        }
        return rewritten
    }

    private func savedDeviceId(host: String, port: Int) -> String {
        let safeHost = host.replacingOccurrences(of: ":", with: "_")
        return "saved-\(safeHost)-\(port)"
    }

    private func readLegacyRecords() -> [PersistedDevice] {
        guard let data = defaults.data(forKey: Self.legacySavedDevicesKey) else { return [] }
        return (try? JSONDecoder().decode([PersistedDevice].self, from: data)) ?? []
    }

    private func readStoredDevices() -> [StoredDevice] {
        guard let data = defaults.data(forKey: Self.savedDevicesKey) else { return [] }
        return (try? JSONDecoder().decode([StoredDevice].self, from: data)) ?? []
    }

    private func writeStoredDevices(_ devices: [StoredDevice]) {
        guard let data = try? JSONEncoder().encode(devices) else { return }
        defaults.set(data, forKey: Self.savedDevicesKey)
    }
    
    /// Drops the pinned certificate for a device so the next connection pins the one it presents.
    /// Only call this after the user has confirmed the change is expected.
    func trustNewCertificate(host: String, port: Int) {
        trustStore.reset(host: host, port: port)
    }
    
    deinit {
        scanTask?.cancel()
        networkMonitor?.cancel()
        scanTimer?.invalidate()
        deviceDiscoverySessions.forEach { $0.cancel() }
    }
}

// MARK: - KVM Device Model

/// One KVM: what the operator calls it, every address it answers on, and which of them a value of
/// this type connects through.
///
/// `host` and `port` are the address in use: for a catalog entry, the address a plain Connect
/// would use (the last one used, or the first); for a session's connected device, the one it is
/// connected through. Everything that talks to the device (the HTTP client, the stream, the log)
/// reads those two, so connecting through another address is `via(_:)` and nothing else.
struct KVMDevice: Identifiable, Codable {
    var id: String
    /// The operator's name for the device. Nil shows the address instead.
    var nickname: String?
    var host: String
    var port: Int
    /// Every address of the device, in the order the operator listed them. Holds at least the
    /// address in use when the device is made; the Edit sheet can later remove that one while a
    /// session is still connected through it.
    var addresses: [DeviceAddress]
    /// The address the last connect used, or the last one the operator picked from the Connect
    /// menu; nil when nothing is recorded.
    var lastUsedAddress: DeviceAddress?
    var type: KVMDeviceType
    var authToken: String
    let capabilities: Set<KVMCapability>

    init(
        id: String,
        nickname: String? = nil,
        host: String,
        port: Int,
        addresses: [DeviceAddress] = [],
        lastUsedAddress: DeviceAddress? = nil,
        type: KVMDeviceType,
        authToken: String,
        capabilities: Set<KVMCapability>
    ) {
        self.id = id
        self.nickname = DeviceNaming.cleanNickname(nickname)
        self.host = host
        self.port = port
        self.addresses = addresses.isEmpty ? [DeviceAddress(host: host, port: port)] : addresses
        self.lastUsedAddress = lastUsedAddress
        self.type = type
        self.authToken = authToken
        self.capabilities = capabilities
    }

    /// What the app calls the device everywhere it names it: the nickname, or the address in use.
    var displayName: String {
        nickname ?? address.label
    }

    /// Saved in the catalog, as opposed to found by a scan or added by hand and not yet connected.
    var isSaved: Bool { id.hasPrefix("saved-") }

    /// The address a plain Connect uses: the last-used one while it is still listed, otherwise
    /// the first.
    var preferredAddress: DeviceAddress {
        if let lastUsedAddress, addresses.contains(lastUsedAddress) {
            return lastUsedAddress
        }
        return addresses.first ?? address
    }

    /// Whether `address` is one of this device's, or the one it is using.
    func includes(_ address: DeviceAddress) -> Bool {
        self.address == address || addresses.contains(address)
    }

    /// The same device, connecting through `address`.
    func via(_ address: DeviceAddress) -> KVMDevice {
        var copy = self
        copy.host = address.host
        copy.port = address.port
        return copy
    }

    var connectionString: String {
        return "\(host):\(port)"
    }

    var httpScheme: String {
        GLKVMClient.defaultHTTPScheme(for: port)
    }

    var webSocketScheme: String {
        GLKVMClient.defaultWebSocketScheme(for: port)
    }

    var originURL: String {
        return "\(httpScheme)://\(host):\(port)"
    }
    
    var webRTCURL: String {
        return "\(webSocketScheme)://\(host):\(port)/janus/ws"
    }
}

/// Where a device is: its host and port. Host names compare without regard to case, as DNS does
/// and as the keychain and trust-pin keys always have.
///
/// A device's `id` changes when the entry it was connected from is saved (`manual-…` and
/// `scanned-…` become `saved-…`), so anything that has to keep pointing at the same device across
/// a connect — a selection in another window, the check for a device already open somewhere —
/// holds an address instead.
struct DeviceAddress: Hashable, Codable {
    let host: String
    let port: Int

    static func == (lhs: DeviceAddress, rhs: DeviceAddress) -> Bool {
        lhs.port == rhs.port && lhs.host.lowercased() == rhs.host.lowercased()
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(host.lowercased())
        hasher.combine(port)
    }
}

extension KVMDevice {
    var address: DeviceAddress { DeviceAddress(host: host, port: port) }
}

extension KVMDevice: Hashable {
    static func == (lhs: KVMDevice, rhs: KVMDevice) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

enum KVMDeviceType: String, Codable, CaseIterable {
    case glinetComet = "glinet_comet"
    case generic = "generic"
    case tailscale = "tailscale"
    case custom = "custom"
    
    var displayName: String {
        switch self {
        case .glinetComet:
            return "GL.iNet Comet"
        case .generic:
            return "Generic KVM"
        case .tailscale:
            return "Tailscale KVM"
        case .custom:
            return "Custom KVM"
        }
    }
}

enum KVMCapability: String, Codable, CaseIterable {
    case videoStreaming = "video_streaming"
    case keyboardInput = "keyboard_input"
    case mouseInput = "mouse_input"
    case virtualMedia = "virtual_media"
    case powerManagement = "power_management"
    case ocrSupport = "ocr_support"
    
    var displayName: String {
        switch self {
        case .videoStreaming:
            return "Video Streaming"
        case .keyboardInput:
            return "Keyboard Input"
        case .mouseInput:
            return "Mouse Input"
        case .virtualMedia:
            return "Virtual Media"
        case .powerManagement:
            return "Power Management"
        case .ocrSupport:
            return "OCR Support"
        }
    }
}

enum KVMError: Error, LocalizedError, Equatable, CustomStringConvertible {
    case deviceNotFound
    case connectionFailed
    case authenticationFailed
    case unsupportedCapability
    case networkUnavailable
    /// The device presented a certificate other than the one pinned on first connection.
    case certificateChanged(host: String, port: Int, fingerprint: String)
    
    var errorDescription: String? {
        switch self {
        case .deviceNotFound:
            return "KVM device not found"
        case .connectionFailed:
            return "Failed to connect to KVM device"
        case .authenticationFailed:
            return "Authentication failed"
        case .unsupportedCapability:
            return "Device does not support this capability"
        case .networkUnavailable:
            return "Network is not available"
        case .certificateChanged(let host, let port, let fingerprint):
            return "The certificate for \(host):\(port) has changed since you first connected (SHA-256 \(DeviceTrustStore.display(fingerprint))). If you reset or re-flashed the KVM, forget the device or accept the new certificate from the main window; otherwise the connection may be intercepted."
        }
    }

    var description: String {
        errorDescription ?? String(reflecting: self)
    }
}
