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
    func setPassword(_ password: String, host: String, port: Int)
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

    func setPassword(_ password: String, host: String, port: Int) {
        DevicePasswordStore.save(password, host: host, port: port)
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
    /// The networks the running scan sweeps, in CIDR form (`192.168.0.0/24`), as its start is
    /// logged. Empty when no scan is running, or when the Mac has no network to sweep.
    @Published private(set) var scanRanges: [String] = []
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

    // The running scan and its generation. Results are only published when the generation still
    // matches, so a cancelled scan never overwrites the device list after the fact.
    private var scanTask: Task<Void, Never>?
    private var scanGeneration = 0

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
    
    // Internal so a test can see which stores the app's catalog was built on.
    let defaults: UserDefaults
    /// Where a scan looks: the network in the app, a stand-in in tests.
    private let discovery: ScanDiscovery
    /// Where a scan's start, end and cancellation are logged.
    private let scanLog: ConnectionLogging
    let credentials: DeviceCredentialStore
    let trustStore: DeviceTrustStore

    /// The parameters are for tests, which hand in a scratch defaults suite, an in-memory
    /// credential store and a trust store of their own. The app takes the defaults: `.standard`
    /// and the login keychain, or the test host's stand-ins (`AppEnvironment`).
    init(
        defaults: UserDefaults = AppEnvironment.defaults,
        credentials: DeviceCredentialStore = AppEnvironment.makeCredentialStore(),
        trustStore: DeviceTrustStore = .shared,
        discovery: ScanDiscovery = LiveScanDiscovery(),
        scanLog: ConnectionLogging = clog
    ) {
        self.defaults = defaults
        self.credentials = credentials
        self.trustStore = trustStore
        self.discovery = discovery
        self.scanLog = scanLog
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

        let interfaces = discovery.interfaces()
        let sweepHosts = LocalSweep.hosts(for: interfaces)
        scanRanges = LocalSweep.ranges(for: interfaces).map(\.cidr)
        logScanStart(interfaces: interfaces)
        let started = Date()
        let discovery = discovery
        let scanLog = scanLog

        // Bonjour and the sweep side by side. Cancelling this task cancels each of
        // them: the Bonjour browsers stop, the sweep starts no new connect or probe, and probes in
        // flight are cancelled with their requests.
        scanTask = Task { [weak self] in
            await withTaskGroup(of: [KVMDevice].self) { group in
                for type in Self.bonjourServiceTypes {
                    group.addTask { await discovery.bonjour(type: type) }
                }
                group.addTask { await discovery.sweep(hosts: sweepHosts) }

                var allDevices: [KVMDevice] = []
                for await devices in group {
                    if Task.isCancelled {
                        group.cancelAll()
                        return
                    }
                    allDevices.append(contentsOf: devices)

                    let found = allDevices
                    await MainActor.run {
                        guard let self, self.scanGeneration == generation else { return }
                        self.availableDevices = Self.scanListing(pinned: pinnedDevices, found: found)
                    }
                }

                let found = allDevices
                await MainActor.run {
                    guard let self, self.scanGeneration == generation else { return }
                    Self.logScanEnd(found: found, pinned: pinnedDevices, elapsed: Date().timeIntervalSince(started), log: scanLog)
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

    /// Stops a scan in progress: the Bonjour browsers, the sweep and its HTTP probes are
    /// cancelled, and nothing they still return reaches the device list, which keeps what it
    /// showed at the time of the call. A Scan straight after starts a scan of its own.
    func cancelScan() {
        if isScanning {
            scanLog.info(.network, "Scan cancelled")
        }
        scanGeneration += 1
        scanTask?.cancel()
        finishScan()
    }

    /// Scan when idle, Cancel scan while scanning: what the Connections panel's button does.
    func toggleScan() {
        if isScanning {
            cancelScan()
        } else {
            scanForDevices()
        }
    }

    /// Logs what a scan is about to sweep, and at debug level the interfaces it leaves out.
    private func logScanStart(interfaces: [IPv4Interface]) {
        let ranges = LocalSweep.ranges(for: interfaces)
        let bonjour = "browsing Bonjour \(Self.bonjourServiceTypes.joined(separator: ", "))"
        if ranges.isEmpty {
            scanLog.info(.network, "Scan started: no Ethernet or Wi-Fi interface with a private IPv4 address, so no subnet is swept; \(bonjour)")
        } else {
            let swept = ranges.map { "\($0.cidr) (\($0.interface))" }.joined(separator: ", ")
            let ports = Self.sweptPorts.map(String.init).joined(separator: ", ")
            scanLog.info(.network, "Scan started: sweeping \(swept) on ports \(ports); \(bonjour)")
        }
        let skipped = interfaces.filter { !LocalSweep.isSweepable($0) && !$0.isLoopback }
        if !skipped.isEmpty {
            scanLog.debug(.network, "Scan leaves out " + skipped.map { "\($0.name) \($0.address)" }.joined(separator: ", "))
        }
    }

    /// Logs what a scan found, each host once, and which of them are already listed as a saved
    /// or added device.
    nonisolated private static func logScanEnd(found: [KVMDevice], pinned: [KVMDevice], elapsed: TimeInterval, log: ConnectionLogging) {
        let labels = DiscoveredMerge.merge(found).map { device -> String in
            var label = device.nickname.map { "\($0) (\(device.address.label))" } ?? device.address.label
            if let listedAs = DiscoveredMerge.listedAs(device, among: pinned) {
                label += " [listed as \(listedAs.displayName)]"
            }
            return label
        }
        let seconds = String(format: "%.1f", elapsed)
        log.info(.network, labels.isEmpty
            ? "Scan finished in \(seconds) s: nothing found"
            : "Scan finished in \(seconds) s: found \(labels.joined(separator: ", "))")
    }

    private func finishScan() {
        scanTask = nil
        isScanning = false
        scanRanges = []
        scanProgress = 1.0
        scanTimer?.invalidate()
        scanTimer = nil
    }

    /// The services of `type` that resolve to an address and answer there as a GLKVM, the same
    /// check a swept host goes through (`DiscoveryProbe`). Anything can advertise a Bonjour
    /// service, so the service type alone does not list a host.
    nonisolated static func discoverBonjour(type: String, session: URLSession) async -> [KVMDevice] {
        let makeDevice: (NWEndpoint, DeviceAddress) -> KVMDevice = type == bonjourServiceTypes[0]
            ? { createGLiNetDevice(from: $0, resolved: $1) }
            : { createGenericKVMDevice(from: $0, resolved: $1) }
        let endpoints = await browseBonjour(type: type)
        guard !Task.isCancelled else { return [] }
        let resolved = await resolveAll(endpoints)
        guard !Task.isCancelled else { return [] }
        let probe = DiscoveryHTTPProbe(session: session)
        let checked = await checkBonjourServices(resolved, makeDevice: makeDevice) { address in
            await probe.isGLKVM(host: address.host, port: address.port)
        }
        guard !Task.isCancelled else { return checked.listed }
        for name in checked.unresolved {
            clog.info(.network, "Bonjour: \(name) (\(type)) did not resolve to an IPv4 address; not listed")
        }
        for device in checked.refused {
            clog.info(.network, "Bonjour: \(device.nickname ?? type) at \(device.address.label) did not answer as a GLKVM; not listed")
        }
        return checked.listed
    }

    /// What became of a browse's services.
    struct BonjourCheck {
        /// Services that resolved and answered as a GLKVM, as devices, in the order given.
        var listed: [KVMDevice] = []
        /// The names of services that did not resolve.
        var unresolved: [String] = []
        /// Services that resolved but did not answer as a GLKVM, as the devices they would have been.
        var refused: [KVMDevice] = []
    }

    /// Checks each resolved service's host:port with `isGLKVM`, all at once. A service that did
    /// not resolve is not checked and not listed: without an address there is nothing to probe.
    nonisolated static func checkBonjourServices(
        _ services: [(endpoint: NWEndpoint, address: DeviceAddress?)],
        makeDevice: (NWEndpoint, DeviceAddress) -> KVMDevice,
        isGLKVM: @escaping @Sendable (DeviceAddress) async -> Bool
    ) async -> BonjourCheck {
        var check = BonjourCheck()
        var candidates: [KVMDevice] = []
        for service in services {
            guard let address = service.address else {
                if case .service(let name, _, _, _) = service.endpoint {
                    check.unresolved.append(name)
                } else {
                    check.unresolved.append("\(service.endpoint)")
                }
                continue
            }
            candidates.append(makeDevice(service.endpoint, address))
        }
        let addresses = candidates.map(\.address)
        let answers = await withTaskGroup(of: (Int, Bool).self) { group in
            for (index, address) in addresses.enumerated() {
                group.addTask { (index, await isGLKVM(address)) }
            }
            var answers = [Bool](repeating: false, count: addresses.count)
            for await (index, answer) in group {
                answers[index] = answer
            }
            return answers
        }
        for (device, answer) in zip(candidates, answers) {
            if answer {
                check.listed.append(device)
            } else {
                check.refused.append(device)
            }
        }
        return check
    }

    /// Every service of `type` that Bonjour reports within `duration`, each once. Cancelling the
    /// calling task stops the browser at once and returns what it had found.
    nonisolated private static func browseBonjour(type: String, duration: TimeInterval = 5) async -> [NWEndpoint] {
        /// The browse's results and its one ending, by the deadline or by cancellation. Touched
        /// from the browser's queue, the main queue and the cancelling thread, hence the lock.
        final class Browse: @unchecked Sendable {
            private let lock = NSLock()
            private var endpoints: [NWEndpoint] = []
            private var continuation: CheckedContinuation<[NWEndpoint], Never>?
            private var isFinished = false
            let browser: NWBrowser

            init(browser: NWBrowser) {
                self.browser = browser
            }

            func add(_ found: [NWEndpoint]) {
                lock.withLock {
                    for endpoint in found where !endpoints.contains(endpoint) {
                        endpoints.append(endpoint)
                    }
                }
            }

            /// Called once, before `finish` can do anything.
            func start(_ continuation: CheckedContinuation<[NWEndpoint], Never>) {
                let finishedEarly = lock.withLock { () -> Bool in
                    self.continuation = continuation
                    return isFinished
                }
                if finishedEarly {
                    browser.browseResultsChangedHandler = nil
                    browser.cancel()
                    continuation.resume(returning: [])
                }
            }

            /// Stops the browser and resumes the caller with what was found; only the first call
            /// does anything.
            func finish() {
                let (continuation, found) = lock.withLock { () -> (CheckedContinuation<[NWEndpoint], Never>?, [NWEndpoint]) in
                    guard !isFinished else { return (nil, []) }
                    isFinished = true
                    let continuation = self.continuation
                    self.continuation = nil
                    return (continuation, endpoints)
                }
                guard let continuation else { return }
                browser.browseResultsChangedHandler = nil
                browser.cancel()
                continuation.resume(returning: found)
            }
        }

        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: type, domain: nil), using: .tcp)
        let browse = Browse(browser: browser)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // Each call carries the whole current set, not just what changed.
                browser.browseResultsChangedHandler = { results, _ in
                    browse.add(results.map(\.endpoint))
                }
                browse.start(continuation)
                browser.start(queue: DispatchQueue(label: "com.overlook.bonjour.\(type)"))
                DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
                    browse.finish()
                }
            }
        } onCancel: {
            browse.finish()
        }
    }

    /// Each Bonjour service with the IPv4 address and port it resolves to, or nil where it does
    /// not resolve in time. In the order given.
    nonisolated private static func resolveAll(
        _ endpoints: [NWEndpoint]
    ) async -> [(endpoint: NWEndpoint, address: DeviceAddress?)] {
        await withTaskGroup(of: (Int, DeviceAddress?).self) { group in
            for (index, endpoint) in endpoints.enumerated() {
                group.addTask { (index, Task.isCancelled ? nil : await resolve(endpoint)) }
            }
            var addresses = [DeviceAddress?](repeating: nil, count: endpoints.count)
            for await (index, address) in group {
                addresses[index] = address
            }
            return Array(zip(endpoints, addresses)).map { (endpoint: $0.0, address: $0.1) }
        }
    }

    /// The IPv4 address and port a Bonjour service resolves to, read off a TCP connection to it,
    /// which is closed as soon as it is up. Nil when it does not come up within `timeout`.
    nonisolated private static func resolve(_ endpoint: NWEndpoint, timeout: TimeInterval = 2) async -> DeviceAddress? {
        final class Flag {
            var value = false
        }

        let parameters = NWParameters.tcp
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let queue = DispatchQueue(label: "com.overlook.bonjour.resolve")
        let connection = NWConnection(to: endpoint, using: parameters)

        return await withCheckedContinuation { continuation in
            let finished = Flag()

            // Runs on `queue` only.
            let finish: (DeviceAddress?) -> Void = { address in
                if finished.value { return }
                finished.value = true
                connection.stateUpdateHandler = nil
                connection.cancel()
                continuation.resume(returning: address)
            }

            queue.asyncAfter(deadline: .now() + timeout) { finish(nil) }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(address(of: connection.currentPath?.remoteEndpoint))
                case .waiting, .failed, .cancelled:
                    finish(nil)
                default:
                    break
                }
            }

            connection.start(queue: queue)
        }
    }

    /// The host and port of a resolved endpoint: the dotted quad for IPv4, the name for a host
    /// name. Nil for IPv6 (resolution asks for IPv4) and for anything that is not a host and port.
    nonisolated static func address(of endpoint: NWEndpoint?) -> DeviceAddress? {
        guard case .hostPort(let host, let port)? = endpoint else { return nil }
        switch host {
        case .ipv4(let ipv4):
            let bytes = Array(ipv4.rawValue)
            guard bytes.count == 4 else { return nil }
            return DeviceAddress(host: bytes.map(String.init).joined(separator: "."), port: Int(port.rawValue))
        case .name(let name, _):
            return DeviceAddress(host: name, port: Int(port.rawValue))
        default:
            return nil
        }
    }

    /// A `_comet._tcp` service as a device: at the address it resolved to, named after the
    /// service. Unresolved, it keeps the service's own name as its host and 443 as its port.
    nonisolated static func createGLiNetDevice(from endpoint: NWEndpoint, resolved: DeviceAddress? = nil) -> KVMDevice {
        let found = bonjourIdentity(of: endpoint, resolved: resolved, defaultPort: 443, fallbackName: "GL.iNet Comet")
        return KVMDevice(
            id: "glinet-\(found.host)-\(found.port)",
            nickname: found.name,
            host: found.host,
            port: found.port,
            type: .glinetComet,
            authToken: "",
            capabilities: [.videoStreaming, .keyboardInput, .mouseInput, .virtualMedia, .powerManagement]
        )
    }

    /// A `_kvm._tcp` service as a device, as `createGLiNetDevice` does; unresolved, port 8080.
    nonisolated static func createGenericKVMDevice(from endpoint: NWEndpoint, resolved: DeviceAddress? = nil) -> KVMDevice {
        let found = bonjourIdentity(of: endpoint, resolved: resolved, defaultPort: 8080, fallbackName: "Generic KVM")
        return KVMDevice(
            id: "generic-\(found.host)-\(found.port)",
            nickname: found.name,
            host: found.host,
            port: found.port,
            type: .generic,
            authToken: "",
            capabilities: [.videoStreaming, .keyboardInput, .mouseInput]
        )
    }

    nonisolated private static func bonjourIdentity(
        of endpoint: NWEndpoint,
        resolved: DeviceAddress?,
        defaultPort: Int,
        fallbackName: String
    ) -> (name: String, host: String, port: Int) {
        var name = fallbackName
        var host = ""
        if case .service(let serviceName, let type, let domain, _) = endpoint {
            name = serviceName
            host = "\(serviceName).\(type).\(domain)"
        }
        if let resolved {
            return (name, resolved.host, resolved.port)
        }
        return (name, host, defaultPort)
    }

    /// The ports probed on every swept host.
    nonisolated static let sweptPorts = [443, 8443, 80, 8080]

    /// The Bonjour service types Scan browses. Each must be listed under `NSBonjourServices` in
    /// Info.plist, or macOS refuses the browse.
    nonisolated static let bonjourServiceTypes = ["_comet._tcp", "_kvm._tcp"]

    /// The /24 sweep, in `DiscoverySweep`'s two stages: a TCP connect to every swept host's
    /// ports, then HTTP probes on the ports that accepted.
    nonisolated static func scanKnownPorts(hosts: [String], session: URLSession) async -> [KVMDevice] {
        guard !hosts.isEmpty else { return [] }
        let started = Date()
        let targets = DiscoverySweep.targets(hosts: hosts, ports: Self.sweptPorts)
        let outcome = await DiscoverySweep.run(
            targets: targets,
            connect: { target in
                await Self.checkPort(host: target.host, port: target.port, timeout: DiscoverySweep.connectTimeout)
            },
            probe: { target in
                await DiscoveryHTTPProbe(session: session).identify(host: target.host, port: target.port)
            }
        )
        guard !Task.isCancelled else { return outcome.found }
        let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
        let glkvms = Set(outcome.found.map { DiscoveredMerge.hostKey($0.host) }).count
        let retried = outcome.retried > 0 ? ", \(outcome.retried) tried twice" : ""
        clog.info(.network, "Sweep finished in \(seconds) s: \(outcome.hostsAnswering) of \(hosts.count) hosts answered on a port "
            + "(\(outcome.openTargets.count) open ports; \(DiscoverySweep.connectLimit) connects at a time, "
            + "\(Int(DiscoverySweep.connectTimeout * 1000)) ms timeout\(retried)); \(glkvms) \(glkvms == 1 ? "is a GLKVM" : "are GLKVMs")")
        return outcome.found
    }

    /// Every IPv4 address on the Mac's interfaces, with the interface's name, netmask and flags.
    nonisolated static func readIPv4Interfaces() -> [IPv4Interface] {
        var interfaces: [IPv4Interface] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            defer { ptr = p.pointee.ifa_next }
            guard let addr = p.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  let address = numericHost(addr) else { continue }
            let netmask = p.pointee.ifa_netmask.flatMap(numericHost) ?? ""
            let flags = Int32(p.pointee.ifa_flags)
            interfaces.append(IPv4Interface(
                name: String(cString: p.pointee.ifa_name),
                address: address,
                netmask: netmask,
                isUp: (flags & IFF_UP) != 0,
                isRunning: (flags & IFF_RUNNING) != 0,
                isLoopback: (flags & IFF_LOOPBACK) != 0,
                isPointToPoint: (flags & IFF_POINTOPOINT) != 0
            ))
        }
        return interfaces
    }

    /// The dotted quad in an `AF_INET` sockaddr. A netmask's sockaddr may come back with
    /// `sa_family` unset, so the family is not checked here.
    nonisolated private static func numericHost(_ addr: UnsafeMutablePointer<sockaddr>) -> String? {
        var sin = sockaddr_in()
        memcpy(&sin, addr, min(Int(addr.pointee.sa_len), MemoryLayout<sockaddr_in>.size))
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &sin.sin_addr, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        return String(cString: buffer)
    }

    /// What one TCP connect to `host:port` learns within `timeout`. A refusal, or a host the
    /// system already knows is down, closes the port at once (`DiscoverySweep.isAnswer`); while
    /// Network waits for any other reason the attempt carries on (Network retries by itself), and
    /// if it runs out of time after such a wait the port is unsure rather than closed.
    nonisolated static func checkPort(host: String, port: Int, timeout: TimeInterval) async -> DiscoverySweep.PortState {
        guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else {
            return .closed
        }

        // Touched on `queue` only, which serializes it.
        final class Attempt: @unchecked Sendable {
            var finished = false
            var heldUp = false
        }

        let queue = DispatchQueue(label: "com.overlook.probe.port")
        let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)

        return await withCheckedContinuation { continuation in
            let attempt = Attempt()

            let finish: @Sendable (DiscoverySweep.PortState) -> Void = { state in
                if attempt.finished { return }
                attempt.finished = true
                connection.stateUpdateHandler = nil
                connection.cancel()
                continuation.resume(returning: state)
            }

            queue.asyncAfter(deadline: .now() + timeout) {
                finish(attempt.heldUp ? .unsure : .closed)
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(.open)
                case .waiting(let error):
                    if case .posix(let code) = error, DiscoverySweep.isAnswer(code) {
                        finish(.closed)
                    } else {
                        attempt.heldUp = true
                    }
                case .failed, .cancelled:
                    finish(.closed)
                default:
                    break
                }
            }

            connection.start(queue: queue)
        }
    }

    /// The device list a scan shows: every saved or added device, whatever the scan found or
    /// failed to reach, plus one entry per other host found.
    nonisolated static func scanListing(pinned: [KVMDevice], found: [KVMDevice]) -> [KVMDevice] {
        mergeListed(pinned + DiscoveredMerge.merge(found, shownAs: pinned))
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

    /// What a typed address (Manual Connect, Quick Connect) connects to: the saved device that has
    /// it, through that address, or else a new manual entry for it.
    func device(forTyped address: DeviceAddress) -> KVMDevice {
        if let saved = savedDevice(containing: address) {
            return saved.via(address)
        }
        return addManualDevice(host: address.host, port: address.port, type: .glinetComet)
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
    /// A pairing the operator answered Keep separate to is not offered again.
    func linkCandidate(for connected: KVMDevice) -> KVMDevice? {
        guard let pin = trustStore.pinnedFingerprint(host: connected.host, port: connected.port) else {
            return nil
        }
        let declined = Set(defaults.stringArray(forKey: Self.declinedLinksKey) ?? [])
        return availableDevices.first { candidate in
            candidate.isSaved
                && candidate.id != connected.id
                && !candidate.addresses.contains(connected.address)
                && !declined.contains(Self.declinedLinkKey(connected.address, candidate.id))
                && candidate.addresses.contains { address in
                    trustStore.pinnedFingerprint(host: address.host, port: address.port) == pin
                }
        }
    }

    /// Pairs of address and device the operator chose to keep separate, as `host:port|id`.
    static let declinedLinksKey = "overlook.declined_links.v1"

    private static func declinedLinkKey(_ address: DeviceAddress, _ deviceID: String) -> String {
        "\(DeviceTrustStore.key(host: address.host, port: address.port))|\(deviceID)"
    }

    /// Keep separate: `address` is not offered to `candidate` again.
    func declineLink(_ address: DeviceAddress, to candidate: KVMDevice) {
        var declined = defaults.stringArray(forKey: Self.declinedLinksKey) ?? []
        let key = Self.declinedLinkKey(address, candidate.id)
        guard !declined.contains(key) else { return }
        declined.append(key)
        defaults.set(declined, forKey: Self.declinedLinksKey)
    }

    /// Add address: `address`, which `source` was saved with on its own, becomes another address
    /// of `target`, and its last-used one unless `makeLastUsed` is false (the device is open in
    /// another window through an address of its own, and the next plain Connect should use that
    /// one). `source`'s record loses the address and goes when it has none left. Tokens and pins
    /// stay where they are; `target`'s token is copied to the address if it has none.
    @discardableResult
    func link(_ address: DeviceAddress, of source: KVMDevice, to target: KVMDevice, makeLastUsed: Bool = true) -> KVMDevice? {
        var current = readStoredDevices()
        guard let targetIndex = current.firstIndex(where: { $0.id == target.id }) else { return nil }
        if !current[targetIndex].addresses.contains(address) {
            current[targetIndex].addresses.append(address)
        }
        if makeLastUsed {
            current[targetIndex].lastUsed = address
        }
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
    }
}

/// Where a scan looks for devices. `KVMDeviceManager` runs a scan through one of these: the app
/// uses `LiveScanDiscovery`, and tests hand in a stand-in, so a scan can be started, cancelled and
/// started again without touching the network.
protocol ScanDiscovery: Sendable {
    /// The Mac's IPv4 interfaces, which decide which networks the sweep covers.
    func interfaces() -> [IPv4Interface]
    /// The GLKVMs among the Bonjour services of `type` (one of `bonjourServiceTypes`).
    func bonjour(type: String) async -> [KVMDevice]
    /// The GLKVMs among `hosts`, swept on `sweptPorts`.
    func sweep(hosts: [String]) async -> [KVMDevice]
}

/// The network: Bonjour and the /24 sweep, each probed with `DiscoveryHTTPProbe`.
struct LiveScanDiscovery: ScanDiscovery {
    /// Discovery probes accept any certificate: they hit arbitrary LAN hosts, send no credentials,
    /// and must not pin whatever those hosts present. Real connections go through DeviceTrustStore.
    /// They follow a redirect only to the host they asked (`DiscoveryProbe.followsRedirect`).
    private final class ProbeTLSDelegate: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            let follows = DiscoveryProbe.followsRedirect(from: task.originalRequest?.url, to: request.url)
            completionHandler(follows ? request : nil)
        }

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

    static let probeSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 3
        return URLSession(configuration: config, delegate: ProbeTLSDelegate(), delegateQueue: nil)
    }()

    func interfaces() -> [IPv4Interface] {
        KVMDeviceManager.readIPv4Interfaces()
    }

    func bonjour(type: String) async -> [KVMDevice] {
        await KVMDeviceManager.discoverBonjour(type: type, session: Self.probeSession)
    }

    func sweep(hosts: [String]) async -> [KVMDevice] {
        await KVMDeviceManager.scanKnownPorts(hosts: hosts, session: Self.probeSession)
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

/// The HTTP half of probing one swept host:port: asks it whether it is a GLKVM, as
/// `DiscoveryProbe` defines one. Read-only GETs, no credentials. The session is the scan's probe
/// session in the app (any certificate accepted, redirects followed only on the same host) and a
/// stubbed one in tests.
struct DiscoveryHTTPProbe: Sendable {
    let session: URLSession

    /// A device for `host:port` when it answers as a GLKVM, else nil. The API endpoints are asked
    /// first, on each scheme in `DiscoveryProbe.schemes(forPort:)` order; the web page only when
    /// no API endpoint answered as kvmd.
    func identify(host: String, port: Int) async -> KVMDevice? {
        guard await isGLKVM(host: host, port: port) else { return nil }
        return KVMDevice(
            id: "scanned-\(host)-\(port)",
            host: host,
            port: port,
            type: .glinetComet,
            authToken: "",
            capabilities: [.videoStreaming, .keyboardInput, .mouseInput, .virtualMedia, .powerManagement]
        )
    }

    /// Whether `host:port` answers as a GLKVM: an API endpoint in kvmd's envelope, or failing
    /// that GLKVM's web page. Swept hosts and resolved Bonjour services both go through this.
    func isGLKVM(host: String, port: Int) async -> Bool {
        if await answersAsKVMD(host: host, port: port) {
            return true
        }
        // A cancelled scan stops here rather than asking for the page as well.
        guard !Task.isCancelled else { return false }
        return await servesGLKVMPage(host: host, port: port)
    }

    func answersAsKVMD(host: String, port: Int) async -> Bool {
        for scheme in DiscoveryProbe.schemes(forPort: port) {
            for path in DiscoveryProbe.apiPaths {
                guard !Task.isCancelled else { return false }
                guard let answer = await get("\(scheme)://\(host):\(port)/\(path)", timeout: 3) else { continue }
                if DiscoveryProbe.isKVMDAnswer(status: answer.status, body: answer.body) {
                    return true
                }
            }
        }
        return false
    }

    func servesGLKVMPage(host: String, port: Int) async -> Bool {
        for scheme in DiscoveryProbe.schemes(forPort: port) {
            guard !Task.isCancelled else { return false }
            guard let answer = await get("\(scheme)://\(host):\(port)/", timeout: 2) else { continue }
            if DiscoveryProbe.isGLKVMPage(status: answer.status, body: answer.body) {
                return true
            }
        }
        return false
    }

    /// The status and body of a GET, or nil when it fails or is cancelled.
    private func get(_ address: String, timeout: TimeInterval) async -> (status: Int, body: Data)? {
        guard let url = URL(string: address) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        guard let answer = try? await session.data(for: request),
              let http = answer.1 as? HTTPURLResponse else { return nil }
        return (http.statusCode, answer.0)
    }
}
