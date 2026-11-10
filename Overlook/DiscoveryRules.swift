import Foundation

// The pure rules behind Scan: which of the Mac's own addresses decide what gets swept, and what a
// probed host has to answer to be listed. `KVMDeviceManager` does the network work; everything
// here can be checked without touching the network.

/// One IPv4 address on one of the Mac's network interfaces, as `getifaddrs` reports it.
struct IPv4Interface: Equatable, Sendable {
    /// The BSD name: `en0`, `utun3`, `bridge100`, `lo0`.
    let name: String
    /// Dotted quad.
    let address: String
    /// Dotted quad; empty when the interface reported none.
    let netmask: String
    var isUp = true
    var isRunning = true
    var isLoopback = false
    var isPointToPoint = false
}

/// Which hosts a scan sweeps, worked out from the Mac's own interfaces.
///
/// Only the Mac's own Ethernet and Wi-Fi networks are swept: an interface qualifies when it is up
/// and running, is not loopback or point-to-point, is named `en<number>`, and has a private
/// (RFC 1918) IPv4 address. That leaves out VPN tunnels and Tailscale (`utun*`, 100.64.0.0/10),
/// VM and Internet Sharing bridges (`bridge*`), AWDL and low-latency WLAN (`awdl*`, `llw*`),
/// access-point, tunnel and 6to4 interfaces (`ap*`, `gif*`, `stf*`), `anpi*`, and loopback.
/// No network is swept on a guess: with no interface that qualifies, nothing is.
enum LocalSweep {
    /// The most a scan sweeps around one interface address: a /24, 254 hosts.
    static let widestPrefixLength = 24

    /// The hosts swept for one interface address.
    struct Range: Equatable, Sendable {
        /// The interface the range was worked out from.
        let interface: String
        /// The range in CIDR form: `192.168.0.0/24`.
        let cidr: String
        /// Every address in the range but the network and broadcast addresses, in order.
        let hosts: [String]
    }

    /// Whether `interface` is one whose network a scan sweeps.
    static func isSweepable(_ interface: IPv4Interface) -> Bool {
        interface.isUp
            && interface.isRunning
            && !interface.isLoopback
            && !interface.isPointToPoint
            && isEthernetOrWiFi(interface.name)
            && AddressTag.classify(host: interface.address) == .lan
    }

    /// `en0`, `en5`: the names macOS gives Wi-Fi and Ethernet ports, USB and Thunderbolt adapters
    /// included.
    static func isEthernetOrWiFi(_ name: String) -> Bool {
        let digits = name.dropFirst(2)
        return name.hasPrefix("en") && !digits.isEmpty && digits.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// The range swept for `interface`, or nil when it does not qualify or its subnet holds no
    /// other host. A netmask wider than /24 (a /16, say) is narrowed to the /24 that holds the
    /// Mac's address; a narrower one (a /26) is swept as it is. A missing or malformed netmask
    /// counts as /24.
    static func range(for interface: IPv4Interface) -> Range? {
        guard isSweepable(interface), let address = ipv4Value(interface.address) else { return nil }
        let length = max(prefixLength(ofNetmask: interface.netmask) ?? widestPrefixLength, widestPrefixLength)
        // A /31 or /32 has no address for another host.
        guard length <= 30 else { return nil }
        let mask = ~UInt32(0) << UInt32(32 - length)
        let network = address & mask
        let broadcast = network | ~mask
        let hosts = ((network + 1)..<broadcast).map(dottedQuad)
        return Range(interface: interface.name, cidr: "\(dottedQuad(network))/\(length)", hosts: hosts)
    }

    /// The ranges a scan sweeps, one per network: two interfaces on the same /24 share one.
    static func ranges(for interfaces: [IPv4Interface]) -> [Range] {
        var ranges: [Range] = []
        for interface in interfaces {
            guard let range = range(for: interface), !ranges.contains(where: { $0.cidr == range.cidr }) else {
                continue
            }
            ranges.append(range)
        }
        return ranges
    }

    /// Every host a scan probes, each once, leaving out the Mac's own addresses.
    static func hosts(for interfaces: [IPv4Interface]) -> [String] {
        let own = Set(interfaces.map(\.address))
        var seen: Set<String> = []
        return ranges(for: interfaces).flatMap(\.hosts).filter { !own.contains($0) && seen.insert($0).inserted }
    }

    /// The length of a contiguous netmask (`255.255.255.0` is 24), or nil for anything else.
    static func prefixLength(ofNetmask netmask: String) -> Int? {
        guard let value = ipv4Value(netmask) else { return nil }
        // The leading one bits; contiguous when no one bit follows them.
        let length = (~value).leadingZeroBitCount
        let expected: UInt32 = length == 0 ? 0 : ~UInt32(0) << UInt32(32 - length)
        return value == expected ? length : nil
    }

    static func ipv4Value(_ text: String) -> UInt32? {
        guard let octets = AddressTag.ipv4Octets(text) else { return nil }
        return octets.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }

    static func dottedQuad(_ value: UInt32) -> String {
        "\(value >> 24).\(value >> 16 & 0xFF).\(value >> 8 & 0xFF).\(value & 0xFF)"
    }
}

/// What a probed host has to answer to be listed as a KVM. Every swept host goes through the same
/// check, whatever network it is on.
enum DiscoveryProbe {
    /// The GLKVM API endpoints probed. Any one answering `apiStatusLooksLikeGLKVM` lists the host.
    static let apiPaths = ["api/auth/check", "api/init/is_inited"]

    /// The schemes tried on `port`, in order: https first on 443 and 8443, http first elsewhere.
    static func schemes(forPort port: Int) -> [String] {
        (port == 443 || port == 8443) ? ["https", "http"] : ["http", "https"]
    }

    /// A GLKVM answers its API endpoints with success, an auth refusal, or a redirect.
    static func apiStatusLooksLikeGLKVM(_ status: Int) -> Bool {
        [200, 401, 403, 301, 302, 307, 308].contains(status)
    }

    /// A web UI page that names a KVM: a 2xx or 3xx response whose first 4 KB mention `kvm`
    /// (which covers `kvmd` and `glkvm`) or `comet`, in any case.
    static func pageLooksLikeKVM(status: Int, body: Data) -> Bool {
        guard (200...399).contains(status) else { return false }
        let text = String(decoding: body.prefix(4096), as: UTF8.self).lowercased()
        return text.contains("kvm") || text.contains("comet")
    }
}

/// How one scan's results become one entry per host. The same KVM is often found several times —
/// over Bonjour as `_comet._tcp` and `_kvm._tcp`, by the sweep, and on both 443 and 80 — and is
/// listed once. Different hosts are never merged, whatever their Bonjour names.
enum DiscoveredMerge {
    /// The host as compared: trimmed, lowercased, without a trailing dot.
    static func hostKey(_ host: String) -> String {
        var key = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if key.hasSuffix(".") {
            key.removeLast()
        }
        return key
    }

    /// Which of a host's ports its entry uses, lowest first: 443, then other https ports (8443),
    /// then http ports other than 80 (8080), then 80. The schemes are `GLKVMClient`'s.
    static func portRank(_ port: Int) -> Int {
        switch port {
        case 443: return 0
        case 80: return 3
        case 8080: return 2
        default: return 1
        }
    }

    /// One entry per host, in the order hosts were first found. A host's entry is its best-ranked
    /// result by port (a GL.iNet result before a generic one on the same port), carrying the
    /// Bonjour name if any result for the host had one. Hosts that a device in `pinned` (a saved
    /// or added device) already has an address on are left out: that device is what is listed.
    static func merge(_ found: [KVMDevice], shownAs pinned: [KVMDevice] = []) -> [KVMDevice] {
        var order: [String] = []
        var groups: [String: [KVMDevice]] = [:]
        for device in found {
            let key = hostKey(device.host)
            guard !key.isEmpty, listedAs(device, among: pinned) == nil else { continue }
            if groups[key] == nil {
                order.append(key)
            }
            groups[key, default: []].append(device)
        }
        return order.compactMap { key in
            guard let members = groups[key] else { return nil }
            let ranked = members.enumerated().sorted { lhs, rhs in
                let left = (portRank(lhs.element.port), typeRank(lhs.element.type), lhs.offset)
                let right = (portRank(rhs.element.port), typeRank(rhs.element.type), rhs.offset)
                return left < right
            }.map(\.element)
            guard var chosen = ranked.first else { return nil }
            chosen.nickname = chosen.nickname ?? ranked.lazy.compactMap(\.nickname).first
            return chosen
        }
    }

    /// The device in `pinned` that has an address on `device`'s host, if any.
    static func listedAs(_ device: KVMDevice, among pinned: [KVMDevice]) -> KVMDevice? {
        let key = hostKey(device.host)
        return pinned.first { listed in
            hostKey(listed.host) == key || listed.addresses.contains { hostKey($0.host) == key }
        }
    }

    private static func typeRank(_ type: KVMDeviceType) -> Int {
        type == .glinetComet ? 0 : 1
    }
}
