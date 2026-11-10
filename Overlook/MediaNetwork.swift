import Foundation
import Darwin

// Which network a connection's video and audio travel over. The pure rules live here: reading an
// IP address, which ranges are the LAN and which are Tailscale, and which peers can be reached
// without a public STUN server.

/// An IPv4 or IPv6 address, read from the text form an address or an ICE candidate carries.
struct IPAddress: Hashable, CustomStringConvertible {
    enum Family: Hashable {
        case v4
        case v6
    }

    let family: Family
    /// 4 bytes for IPv4, 16 for IPv6, in network order.
    let bytes: [UInt8]

    /// Reads `192.168.0.131`, `fd7a:115c:a1e0::9428:4907`, `[fe80::1]` or `fe80::1%en0` (the zone
    /// is dropped); nil for anything else, host names included.
    init?(_ text: String) {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("[") && text.hasSuffix("]") {
            text = String(text.dropFirst().dropLast())
        }
        if let zone = text.firstIndex(of: "%") {
            text = String(text[..<zone])
        }
        guard !text.isEmpty else { return nil }

        var v4 = in_addr()
        if text.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 {
            family = .v4
            bytes = withUnsafeBytes(of: &v4) { Array($0) }
            return
        }
        var v6 = in6_addr()
        if text.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 {
            family = .v6
            bytes = withUnsafeBytes(of: &v6) { Array($0) }
            return
        }
        return nil
    }

    init?(family: Family, bytes: [UInt8]) {
        guard bytes.count == (family == .v4 ? 4 : 16) else { return nil }
        self.family = family
        self.bytes = bytes
    }

    /// The usual text form: dotted quad, or compressed IPv6.
    var description: String {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let ok: Bool = bytes.withUnsafeBytes { raw in
            inet_ntop(family == .v4 ? AF_INET : AF_INET6, raw.baseAddress, &buffer, socklen_t(buffer.count)) != nil
        }
        return ok ? String(cString: buffer) : bytes.map(String.init).joined(separator: ".")
    }

    /// Whether the first `length` bits match `prefix`'s.
    func hasPrefix(_ prefix: [UInt8], length: Int) -> Bool {
        guard prefix.count * 8 >= length, bytes.count * 8 >= length else { return false }
        var remaining = length
        var index = 0
        while remaining > 0 {
            let bits = min(8, remaining)
            let mask = UInt8(truncatingIfNeeded: 0xFF << (8 - bits))
            if bytes[index] & mask != prefix[index] & mask { return false }
            remaining -= bits
            index += 1
        }
        return true
    }

    /// Tailscale's ranges: 100.64.0.0/10 (its CGNAT block) and fd7a:115c:a1e0::/48.
    var isTailscale: Bool {
        switch family {
        case .v4: return hasPrefix([100, 64], length: 10)
        case .v6: return hasPrefix([0xFD, 0x7A, 0x11, 0x5C, 0xA1, 0xE0], length: 48)
        }
    }

    /// RFC 1918: 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16.
    var isPrivateLAN: Bool {
        guard family == .v4 else { return false }
        return hasPrefix([10], length: 8) || hasPrefix([172, 16], length: 12) || hasPrefix([192, 168], length: 16)
    }

    /// 169.254.0.0/16 and fe80::/10.
    var isLinkLocal: Bool {
        switch family {
        case .v4: return hasPrefix([169, 254], length: 16)
        case .v6: return hasPrefix([0xFE, 0x80], length: 10)
        }
    }

    /// 127.0.0.0/8 and ::1.
    var isLoopback: Bool {
        switch family {
        case .v4: return hasPrefix([127], length: 8)
        case .v6: return bytes == [UInt8](repeating: 0, count: 15) + [1]
        }
    }
}

enum MediaNetworkRules {
    /// Whether a KVM at `host` can be reached with host candidates alone, so a connect to it needs
    /// no public STUN server: RFC 1918, loopback and link-local IPv4, Tailscale (100.64.0.0/10,
    /// fd7a:115c:a1e0::/48 and `*.ts.net`), `.local` and `localhost`, and a single-label name such
    /// as `mdesktopkvm`, which only a local resolver (Tailscale's MagicDNS, the router's DNS, a
    /// hosts file) can answer.
    static func isDirectlyReachable(host: String) -> Bool {
        var name = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if name.hasPrefix("[") && name.hasSuffix("]") {
            name = String(name.dropFirst().dropLast())
        }
        if name.hasSuffix(".") {
            name.removeLast()
        }
        guard !name.isEmpty else { return false }

        if let address = IPAddress(name) {
            switch address.family {
            case .v4:
                return address.isPrivateLAN || address.isLoopback || address.isLinkLocal || address.isTailscale
            case .v6:
                return address.isTailscale
            }
        }
        if name == "localhost" || name.hasSuffix(".local") || name.hasSuffix(".ts.net") {
            return true
        }
        // A name with no dot that is not an address (an IPv6 address has colons, not dots).
        return !name.contains(".") && !name.contains(":")
    }
}

// MARK: - The setting

/// Which addresses a connection's video and audio may use (Settings › Network › Video and audio
/// addresses). Global: it applies to every KVM.
enum MediaAddresses: String, CaseIterable, Identifiable {
    /// Only the network of the address the connect went through: the LAN or Tailscale.
    case chosenNetwork
    /// Any network the KVM and this Mac share; the KVM picks.
    case all

    var id: Self { self }

    var title: String {
        switch self {
        case .chosenNetwork: return "Chosen network only"
        case .all: return "All addresses"
        }
    }
}

/// The app's network settings. Read when a connect starts, so a change takes effect on the next
/// connect.
@MainActor
final class NetworkPreferences: ObservableObject {
    enum Keys {
        static let mediaAddresses = "overlook.network.mediaAddresses"
    }

    @Published var mediaAddresses: MediaAddresses {
        didSet { defaults.set(mediaAddresses.rawValue, forKey: Keys.mediaAddresses) }
    }

    /// The app's, on this Mac's own defaults (the test host's suite when hosting the tests).
    static let shared = NetworkPreferences(defaults: AppEnvironment.defaults)

    /// Internal so a test can see which defaults the app's object was given.
    let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        mediaAddresses = MediaAddresses(rawValue: defaults.string(forKey: Keys.mediaAddresses) ?? "") ?? .chosenNetwork
    }
}

// MARK: - Which network a connect is on

/// The network a connect went through, as the media route sees it.
enum MediaNetwork: Equatable {
    case lan
    case tailscale

    /// For the log: "the LAN", "Tailscale".
    var name: String {
        switch self {
        case .lan: return "the LAN"
        case .tailscale: return "Tailscale"
        }
    }

    /// RFC 1918 is the LAN; 100.64.0.0/10 and fd7a:115c:a1e0::/48 are Tailscale; anything else
    /// (a public address, IPv6 other than Tailscale's) is neither.
    static func classify(_ address: IPAddress) -> MediaNetwork? {
        if address.isTailscale { return .tailscale }
        if address.isPrivateLAN { return .lan }
        return nil
    }

    /// What `host` says on its own: an address by its range, `*.ts.net` as Tailscale. Nil for any
    /// other name, which has to be resolved first (`needsResolution`).
    static func classify(host: String) -> MediaNetwork? {
        let name = normalized(host)
        if let address = IPAddress(name) {
            return classify(address)
        }
        if name.hasSuffix(".ts.net") {
            return .tailscale
        }
        return nil
    }

    /// True for a host name other than `*.ts.net`: only the address it resolves to says which
    /// network it is on (a bare `mdesktopkvm` resolves to a Tailscale address through MagicDNS).
    static func needsResolution(host: String) -> Bool {
        let name = normalized(host)
        return !name.isEmpty && IPAddress(name) == nil && !name.hasSuffix(".ts.net")
    }

    private static func normalized(_ host: String) -> String {
        var name = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if name.hasSuffix(".") {
            name.removeLast()
        }
        return name
    }
}

// MARK: - ICE candidates

/// The parts of an ICE candidate line the route looks at. Reads the offer's
/// `a=candidate:1 1 udp 2015372799 192.168.0.131 30272 typ host` and a trickled
/// `candidate:3310090850 1 udp 2121998079 192.168.0.104 60988 typ host generation 0 …` alike.
struct ICECandidateLine: Equatable {
    /// As written: an address, or a name (an mDNS `.local` candidate).
    let address: String
    /// host, srflx, prflx or relay.
    let type: String

    var ip: IPAddress? { IPAddress(address) }

    init?(_ line: String) {
        var text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("a=") {
            text.removeFirst(2)
        }
        guard text.hasPrefix("candidate:") else { return nil }
        let fields = text.split(separator: " ", omittingEmptySubsequences: true)
        // foundation component transport priority address port "typ" type
        guard fields.count >= 8, fields[6] == "typ" else { return nil }
        address = String(fields[4])
        type = String(fields[7]).lowercased()
    }

    /// "70.134.225.46 srflx", or just the address for a host candidate: how the log names it.
    var label: String {
        type == "host" ? address : "\(address) \(type)"
    }
}

/// What filtering an offer did.
struct RemoteOfferFilterResult: Equatable {
    /// The offer to apply: the filtered one, or the original when filtering would have left a
    /// media section with no candidate at all.
    let sdp: String
    /// The candidates taken out, in the order they appeared.
    let dropped: [ICECandidateLine]
    /// True when filtering would have left nothing to connect to, so the offer was left whole.
    let keptWholeOffer: Bool
}

// MARK: - The route for one connect

/// One of this Mac's IPv4 interface addresses and its netmask, for telling which local address
/// is on the KVM's subnet.
struct LocalInterfaceAddress: Equatable {
    let name: String
    let address: IPAddress
    let netmask: IPAddress

    /// Whether `other` is on this address's subnet.
    func sharesSubnet(with other: IPAddress) -> Bool {
        guard address.family == .v4, other.family == .v4, netmask.family == .v4 else { return false }
        // A /32 (a point-to-point tunnel) contains only itself.
        guard netmask.bytes != [255, 255, 255, 255] else { return false }
        for index in 0..<4 where (address.bytes[index] & netmask.bytes[index]) != (other.bytes[index] & netmask.bytes[index]) {
            return false
        }
        return true
    }

    /// This Mac's IPv4 interface addresses that are up, from `getifaddrs`.
    static func current() -> [LocalInterfaceAddress] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var found: [LocalInterfaceAddress] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0,
                  let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET),
                  let mask = entry.pointee.ifa_netmask else { continue }
            func bytes(_ pointer: UnsafeMutablePointer<sockaddr>) -> [UInt8] {
                pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { inet in
                    withUnsafeBytes(of: inet.pointee.sin_addr) { Array($0) }
                }
            }
            guard let address = IPAddress(family: .v4, bytes: bytes(addr)),
                  let netmask = IPAddress(family: .v4, bytes: bytes(mask)) else { continue }
            found.append(LocalInterfaceAddress(name: String(cString: entry.pointee.ifa_name), address: address, netmask: netmask))
        }
        return found
    }
}

/// Which local adapters the peer connection factory leaves out of gathering.
struct MediaAdapterOptions: Equatable {
    var ignoresVPN = false
    var ignoresLoopback = false

    /// No options set: the factory as it has always been built.
    static let standard = MediaAdapterOptions()
}

/// What one connect's video and audio may use, decided from the address the connect went
/// through and the setting. Built once per connect; every rule that keeps or drops a candidate
/// reads it.
struct MediaRoute: Equatable {
    enum Scope: Equatable {
        /// Only this network. `peer` is the KVM's address on it (the host itself, or what the
        /// host name resolved to), when known.
        case chosen(MediaNetwork)
        /// Today's behaviour: every candidate, both ways.
        case all
    }

    let scope: Scope
    /// The address the connect went through, as typed.
    let host: String
    /// The KVM's IP for this connect: `host` itself, or the first address it resolved to.
    let peerAddress: IPAddress?
    /// For a LAN route, the local addresses on the KVM's subnet. Local candidates on any other
    /// adapter (a Parallels or VMware host-only network, say) are not sent to the KVM. Empty when
    /// no local address shares the KVM's subnet (the KVM is behind a router), and then nothing
    /// is held back on that ground.
    let onLinkLocalAddresses: Set<IPAddress>
    /// Why the setting was not applied, when it could not be: for the log.
    let unclassifiedReason: String?

    /// Today's behaviour, for a manager that has not connected yet and for "All addresses".
    static func allAddresses(host: String = "") -> MediaRoute {
        MediaRoute(scope: .all, host: host, peerAddress: nil, onLinkLocalAddresses: [], unclassifiedReason: nil)
    }

    /// The route for a connect through `host` with `preference`. `resolved` is what a host name
    /// resolved to (the system's preferred address first); ignored for an address or `*.ts.net`.
    /// `interfaces` are this Mac's IPv4 addresses, for the LAN's on-link rule.
    static func decide(
        preference: MediaAddresses,
        host: String,
        resolved: [String],
        interfaces: [LocalInterfaceAddress]
    ) -> MediaRoute {
        guard preference == .chosenNetwork else { return .allAddresses(host: host) }

        let peerAddress: IPAddress?
        let network: MediaNetwork?
        if MediaNetwork.needsResolution(host: host) {
            peerAddress = resolved.lazy.compactMap { IPAddress($0) }.first
            network = peerAddress.flatMap { MediaNetwork.classify($0) }
        } else {
            peerAddress = IPAddress(host)
            network = MediaNetwork.classify(host: host)
        }

        guard let network else {
            let reason: String
            if MediaNetwork.needsResolution(host: host), peerAddress == nil {
                reason = "\(host) did not resolve"
            } else if let peerAddress, peerAddress.description != host {
                reason = "\(host) resolved to \(peerAddress), which is neither a LAN nor a Tailscale address"
            } else {
                reason = "\(host) is neither a LAN nor a Tailscale address"
            }
            return MediaRoute(scope: .all, host: host, peerAddress: peerAddress, onLinkLocalAddresses: [], unclassifiedReason: reason)
        }

        var onLink: Set<IPAddress> = []
        if network == .lan, let peerAddress {
            onLink = Set(interfaces.filter { $0.sharesSubnet(with: peerAddress) }.map(\.address))
        }
        return MediaRoute(scope: .chosen(network), host: host, peerAddress: peerAddress, onLinkLocalAddresses: onLink, unclassifiedReason: nil)
    }

    /// The setting this route carries out: what a connect actually used.
    var appliedPreference: MediaAddresses {
        if case .chosen = scope { return .chosenNetwork }
        return .all
    }

    /// For the LAN, the factory gathers no VPN adapter (Tailscale's utun) and no loopback (a
    /// fresh options object turns loopback gathering on, so it is turned off explicitly). For
    /// Tailscale nothing can be left out at the factory, because Tailscale is the VPN adapter;
    /// the candidate rules do the work there. "All addresses" sets no options at all.
    var adapterOptions: MediaAdapterOptions {
        switch scope {
        case .chosen(.lan): return MediaAdapterOptions(ignoresVPN: true, ignoresLoopback: true)
        case .chosen(.tailscale), .all: return .standard
        }
    }

    /// Whether a public STUN server is added. A route on one chosen network never needs one;
    /// "All addresses" keeps the reachability rule.
    var addsPublicSTUN: Bool {
        switch scope {
        case .chosen: return false
        case .all: return !MediaNetworkRules.isDirectlyReachable(host: host)
        }
    }

    /// Whether the KVM's candidate is kept. LAN: host candidates that are not Tailscale,
    /// link-local or loopback. Tailscale: Tailscale addresses only.
    func keepsRemote(_ candidate: ICECandidateLine) -> Bool {
        switch scope {
        case .all:
            return true
        case .chosen(.lan):
            guard candidate.type == "host", let ip = candidate.ip else { return false }
            return !ip.isTailscale && !ip.isLinkLocal && !ip.isLoopback
        case .chosen(.tailscale):
            return candidate.ip?.isTailscale == true
        }
    }

    /// Whether a candidate this Mac gathered is sent to the KVM. Tailscale: Tailscale addresses
    /// only. LAN: never a Tailscale address, and only the KVM's subnet when this Mac has an
    /// address on it.
    func keepsLocal(_ candidate: ICECandidateLine) -> Bool {
        switch scope {
        case .all:
            return true
        case .chosen(.tailscale):
            return candidate.ip?.isTailscale == true
        case .chosen(.lan):
            guard let ip = candidate.ip else { return false }
            if ip.isTailscale || ip.isLoopback { return false }
            return onLinkLocalAddresses.isEmpty || onLinkLocalAddresses.contains(ip)
        }
    }

    /// The offer with the candidates this route does not keep taken out, line endings as they
    /// were. When a media section that had candidates would be left with none, the offer is
    /// left whole: an offer with nothing to connect to fails for certain, one with every address
    /// at worst takes the long way.
    func filterRemoteOffer(_ sdp: String) -> RemoteOfferFilterResult {
        guard case .chosen = scope else {
            return RemoteOfferFilterResult(sdp: sdp, dropped: [], keptWholeOffer: false)
        }
        let lines = sdp.components(separatedBy: "\n")
        var kept: [String] = []
        var dropped: [ICECandidateLine] = []
        var sectionHad = 0
        var sectionKept = 0
        var emptiedASection = false

        func closeSection() {
            if sectionHad > 0 && sectionKept == 0 { emptiedASection = true }
            sectionHad = 0
            sectionKept = 0
        }

        for line in lines {
            if line.hasPrefix("m=") {
                closeSection()
            }
            if line.hasPrefix("a=candidate:"), let candidate = ICECandidateLine(line) {
                sectionHad += 1
                if keepsRemote(candidate) {
                    sectionKept += 1
                } else {
                    dropped.append(candidate)
                    continue
                }
            }
            kept.append(line)
        }
        closeSection()

        if emptiedASection {
            return RemoteOfferFilterResult(sdp: sdp, dropped: [], keptWholeOffer: true)
        }
        return RemoteOfferFilterResult(sdp: kept.joined(separator: "\n"), dropped: dropped, keptWholeOffer: false)
    }

    /// The line written once per connect when it starts.
    var connectDescription: String {
        switch scope {
        case .chosen(let network):
            var text = "Video and audio limited to \(network.name) (chosen network only), connecting through \(host)"
            if let peerAddress, peerAddress.description != host {
                text += " (\(peerAddress))"
            }
            switch network {
            case .lan:
                text += "; VPN and loopback adapters left out"
                if !onLinkLocalAddresses.isEmpty {
                    let addresses = onLinkLocalAddresses.map(\.description).sorted().joined(separator: ", ")
                    text += "; local candidates limited to \(addresses)"
                }
            case .tailscale:
                text += "; only Tailscale candidates used"
            }
            return text
        case .all:
            if let unclassifiedReason {
                return "Video and audio may use any network (all addresses) for this connect: \(unclassifiedReason)"
            }
            return "Video and audio may use any network (all addresses)"
        }
    }

    /// The prefix of the per-connect lines about dropped candidates.
    var limitDescription: String {
        if case .chosen(let network) = scope {
            return "Video and audio limited to \(network.name) (chosen network only)"
        }
        return "Video and audio may use any network (all addresses)"
    }
}

// MARK: - Resolving a host name

enum HostResolver {
    /// The addresses `host` resolves to, in the order the system prefers them; empty when it does
    /// not resolve within `timeout`. Uses the same resolver the signaling connection does
    /// (`getaddrinfo`, which answers MagicDNS names through Tailscale's DNS).
    static func addresses(of host: String, timeout: TimeInterval = 2) async -> [String] {
        final class Once: @unchecked Sendable {
            private let lock = NSLock()
            private var done = false
            func claim() -> Bool { lock.withLock { defer { done = true }; return !done } }
        }
        let once = Once()
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
                if once.claim() { continuation.resume(returning: []) }
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let found = lookUp(host)
                if once.claim() { continuation.resume(returning: found) }
            }
        }
    }

    private static func lookUp(_ host: String) -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return [] }
        defer { freeaddrinfo(result) }
        var addresses: [String] = []
        for entry in sequence(first: first, next: { $0.pointee.ai_next }) {
            guard let addr = entry.pointee.ai_addr else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, entry.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                let text = String(cString: buffer)
                if !addresses.contains(text) { addresses.append(text) }
            }
        }
        return addresses
    }
}
