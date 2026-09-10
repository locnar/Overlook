import Foundation
import Network
import Combine
import AppKit

@MainActor
class TailscaleManager: ObservableObject {
    @Published var isConnected = false
    @Published var status: TailscaleStatus = .unknown
    @Published var availableNodes: [TailscaleNode] = []
    @Published var currentUser: TailscaleUser?
    @Published var isInstalled = false
    
    private var statusTimer: Timer?
    private var processMonitor: Process?
    
    init() {
        checkTailscaleInstallation()
        startStatusMonitoring()
    }
    
    // MARK: - Installation Check
    
    private func checkTailscaleInstallation() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/local/bin/tailscale")
        task.arguments = ["status"]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        
        do {
            try task.run()
            task.waitUntilExit()
            
            if task.terminationStatus == 0 {
                isInstalled = true
                updateStatus()
            } else {
                isInstalled = false
            }
        } catch {
            isInstalled = false
        }
    }
    
    // MARK: - Status Monitoring
    
    private func startStatusMonitoring() {
        statusTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
            Task { @MainActor in
                self.updateStatus()
            }
        }
        
        updateStatus()
    }
    
    private func updateStatus() {
        guard isInstalled else { return }
        
        Task {
            let statusResult = await getTailscaleStatus()
            let nodesResult = await getTailscaleNodes()
            let userResult = await getCurrentUser()
            
            await MainActor.run {
                if let status = statusResult {
                    self.status = status
                    self.isConnected = (status == .connected)
                }
                
                if let nodes = nodesResult {
                    self.availableNodes = nodes
                }
                
                if let user = userResult {
                    self.currentUser = user
                }
            }
        }
    }
    
    private func getTailscaleStatus() async -> TailscaleStatus? {
        return await withCheckedContinuation { continuation in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/local/bin/tailscale")
            task.arguments = ["status", "--json"]
            
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = pipe
            
            do {
                try task.run()
                
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()
                
                if task.terminationStatus == 0,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let backendState = json["BackendState"] as? String {
                    
                    let status: TailscaleStatus
                    switch backendState {
                    case "Running":
                        status = .connected
                    case "Starting":
                        status = .connecting
                    case "Stopped":
                        status = .disconnected
                    default:
                        status = .unknown
                    }
                    
                    continuation.resume(returning: status)
                } else {
                    continuation.resume(returning: nil)
                }
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }
    
    private func getTailscaleNodes() async -> [TailscaleNode]? {
        return await withCheckedContinuation { continuation in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/local/bin/tailscale")
            task.arguments = ["status", "--json"]
            
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = pipe
            
            do {
                try task.run()
                
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()
                
                if task.terminationStatus == 0,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let peerList = json["Peer"] as? [String: Any] {
                    
                    var nodes: [TailscaleNode] = []
                    
                    for (nodeID, peerData) in peerList {
                        if let peerDict = peerData as? [String: Any],
                           let hostname = peerDict["HostName"] as? String,
                           let dnsName = peerDict["DNSName"] as? String,
                           let os = peerDict["OS"] as? String,
                           let online = peerDict["Online"] as? Bool {
                            
                            let node = TailscaleNode(
                                id: nodeID,
                                hostname: hostname,
                                dnsName: dnsName,
                                os: os,
                                online: online,
                                addresses: peerDict["TailscaleIPs"] as? [String] ?? [],
                                tags: peerDict["Tags"] as? [String] ?? []
                            )
                            nodes.append(node)
                        }
                    }
                    
                    continuation.resume(returning: nodes)
                } else {
                    continuation.resume(returning: [])
                }
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }
    
    private func getCurrentUser() async -> TailscaleUser? {
        return await withCheckedContinuation { continuation in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/local/bin/tailscale")
            task.arguments = ["status", "--json"]
            
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = pipe
            
            do {
                try task.run()
                
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()
                
                if task.terminationStatus == 0,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let user = json["User"] as? String {
                    
                    let tailscaleUser = TailscaleUser(
                        loginName: user,
                        displayName: user,
                        profilePictureURL: nil
                    )
                    
                    continuation.resume(returning: tailscaleUser)
                } else {
                    continuation.resume(returning: nil)
                }
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }
    
    // MARK: - Connection Management
    
    func connect() async throws {
        guard isInstalled else {
            throw TailscaleError.notInstalled
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/local/bin/tailscale")
            task.arguments = ["up"]
            
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = pipe
            
            do {
                try task.run()
                task.waitUntilExit()
                
                if task.terminationStatus == 0 {
                    Task { @MainActor in
                        self.updateStatus()
                    }
                    continuation.resume()
                } else {
                    let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    continuation.resume(throwing: TailscaleError.connectionFailed(output))
                }
            } catch {
                continuation.resume(throwing: TailscaleError.connectionFailed(error.localizedDescription))
            }
        }
    }
    
    func disconnect() async throws {
        guard isInstalled else {
            throw TailscaleError.notInstalled
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/local/bin/tailscale")
            task.arguments = ["down"]
            
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = pipe
            
            do {
                try task.run()
                task.waitUntilExit()
                
                if task.terminationStatus == 0 {
                    Task { @MainActor in
                        self.updateStatus()
                    }
                    continuation.resume()
                } else {
                    let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    continuation.resume(throwing: TailscaleError.disconnectionFailed(output))
                }
            } catch {
                continuation.resume(throwing: TailscaleError.disconnectionFailed(error.localizedDescription))
            }
        }
    }
    
    // MARK: - KVM Device Discovery
    
    func discoverKVMDevices() async -> [KVMDevice] {
        guard isConnected else { return [] }
        
        var kvmDevices: [KVMDevice] = []
        
        for node in availableNodes {
            if node.isKVMDevice {
                let device = await createKVMDevice(from: node)
                if let device = device {
                    kvmDevices.append(device)
                }
            }
        }
        
        return kvmDevices
    }
    
    private func createKVMDevice(from node: TailscaleNode) async -> KVMDevice? {
        // Try common KVM ports on the Tailscale node
        let commonPorts = [8443, 8080, 443, 80]
        
        for port in commonPorts {
            if await isKVMServiceAvailable(host: node.dnsName, port: port) {
                return KVMDevice(
                    id: "tailscale-\(node.id)",
                    name: "\(node.hostname) (Tailscale)",
                    host: node.dnsName,
                    port: port,
                    type: .tailscale,
                    authToken: "",
                    capabilities: [.videoStreaming, .keyboardInput, .mouseInput, .virtualMedia, .powerManagement]
                )
            }
        }
        
        return nil
    }
    
    private func isKVMServiceAvailable(host: String, port: Int) async -> Bool {
        return await withCheckedContinuation { continuation in
            let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp)
            
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    continuation.resume(returning: true)
                case .failed, .cancelled:
                    continuation.resume(returning: false)
                default:
                    break
                }
            }
            
            connection.start(queue: DispatchQueue(label: "com.overlook.tailscale.probe"))
            
            // Timeout after 3 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                connection.cancel()
                continuation.resume(returning: false)
            }
        }
    }
    
    // MARK: - Network Configuration
    
    func getTailscaleIP() -> String? {
        guard let node = availableNodes.first(where: { $0.isCurrentMachine }) else { return nil }
        return node.addresses.first
    }
    
    func enableMagicDNS() async throws {
        guard isInstalled else {
            throw TailscaleError.notInstalled
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/local/bin/tailscale")
            task.arguments = ["set", "--magic-dns=true"]
            
            do {
                try task.run()
                task.waitUntilExit()
                
                if task.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: TailscaleError.configurationFailed)
                }
            } catch {
                continuation.resume(throwing: TailscaleError.configurationFailed)
            }
        }
    }
    
    func enableKeyExpiry() async throws {
        guard isInstalled else {
            throw TailscaleError.notInstalled
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/local/bin/tailscale")
            task.arguments = ["set", "--key-expire=90d"]
            
            do {
                try task.run()
                task.waitUntilExit()
                
                if task.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: TailscaleError.configurationFailed)
                }
            } catch {
                continuation.resume(throwing: TailscaleError.configurationFailed)
            }
        }
    }
    
    // MARK: - Authentication
    
    func login() async throws {
        guard isInstalled else {
            throw TailscaleError.notInstalled
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/local/bin/tailscale")
            task.arguments = ["login"]
            
            do {
                try task.run()
                task.waitUntilExit()
                
                if task.terminationStatus == 0 {
                    Task { @MainActor in
                        self.updateStatus()
                    }
                    continuation.resume()
                } else {
                    continuation.resume(throwing: TailscaleError.authenticationFailed)
                }
            } catch {
                continuation.resume(throwing: TailscaleError.authenticationFailed)
            }
        }
    }
    
    func logout() async throws {
        guard isInstalled else {
            throw TailscaleError.notInstalled
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/local/bin/tailscale")
            task.arguments = ["logout"]
            
            do {
                try task.run()
                task.waitUntilExit()
                
                if task.terminationStatus == 0 {
                    Task { @MainActor in
                        self.updateStatus()
                    }
                    continuation.resume()
                } else {
                    continuation.resume(throwing: TailscaleError.authenticationFailed)
                }
            } catch {
                continuation.resume(throwing: TailscaleError.authenticationFailed)
            }
        }
    }
    
    deinit {
        statusTimer?.invalidate()
        processMonitor?.terminate()
    }
}

// MARK: - Supporting Types
enum TailscaleStatus: String, CaseIterable {
    case unknown = "unknown"
    case disconnected = "disconnected"
    case connecting = "connecting"
    case connected = "connected"
    
    var displayName: String {
        switch self {
        case .unknown:
            return "Unknown"
        case .disconnected:
            return "Disconnected"
        case .connecting:
            return "Connecting"
        case .connected:
            return "Connected"
        }
    }
}

struct TailscaleNode: Identifiable, Codable {
    let id: String
    let hostname: String
    let dnsName: String
    let os: String
    let online: Bool
    let addresses: [String]
    let tags: [String]
    
    var isKVMDevice: Bool {
        // Check if this node looks like a KVM device based on hostname, tags, or OS
        return hostname.lowercased().contains("kvm") ||
               hostname.lowercased().contains("comet") ||
               hostname.lowercased().contains("remote") ||
               tags.contains("tag:kvm") ||
               tags.contains("tag:remote") ||
               os.lowercased().contains("linux")
    }
    
    var isCurrentMachine: Bool {
        // Check if this is the current machine (simplified)
        return hostname.contains(Foundation.Host.current().localizedName ?? "")
    }
    
    var displayAddresses: String {
        return addresses.joined(separator: ", ")
    }
}

struct TailscaleUser: Codable {
    let loginName: String
    let displayName: String
    let profilePictureURL: URL?
    
    var initials: String {
        let components = displayName.components(separatedBy: " ")
        return components.compactMap { $0.first }.map(String.init).joined().uppercased()
    }
}

enum TailscaleError: Error, LocalizedError {
    case notInstalled
    case connectionFailed(String)
    case disconnectionFailed(String)
    case authenticationFailed
    case configurationFailed
    case networkUnavailable
    case manualInstallationRequired
    
    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "Tailscale is not installed"
        case .connectionFailed(let message):
            return "Failed to connect to Tailscale: \(message)"
        case .disconnectionFailed(let message):
            return "Failed to disconnect from Tailscale: \(message)"
        case .authenticationFailed:
            return "Tailscale authentication failed"
        case .configurationFailed:
            return "Failed to configure Tailscale"
        case .networkUnavailable:
            return "Network is not available"
        case .manualInstallationRequired:
            return "Install Tailscale from tailscale.com, then try again"
        }
    }
}

// MARK: - Tailscale Installation Helper
extension TailscaleManager {
    /// Overlook does not download and run installers: an unverified binary fetched over the
    /// network and executed from a temp directory is exactly what Gatekeeper exists to prevent.
    /// Installation is the user's action on Tailscale's download page.
    func installTailscale() async throws {
        openTailscaleWebsite()
        throw TailscaleError.manualInstallationRequired
    }
    
    func openTailscaleWebsite() {
        if let url = URL(string: "https://tailscale.com/download/mac/") {
            NSWorkspace.shared.open(url)
        }
    }
}
