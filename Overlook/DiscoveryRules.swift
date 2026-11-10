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
///
/// A host is listed only on an answer that kvmd (the daemon behind GLKVM's web UI and API, from
/// PiKVM) gives and other web servers do not:
/// - an API endpoint answering kvmd's JSON envelope, `{"ok": <Boolean>, "result": {…}}`, with `ok`
///   true exactly when the status is 200. kvmd's `make_json_response` writes that envelope for
///   every API answer, errors included: an unauthenticated `GET /api/auth/check` gets 401 with
///   `{"ok": false, "result": {"error": "UnauthorizedError", "error_msg": "Unauthorized"}}`, and
///   `GET /api/init/is_inited` (GL.iNet's addition, no login needed) gets 200 with
///   `{"ok": true, "result": {"is_inited": true, …}}`;
/// - or, failing that, a 200 web page titled exactly `GLKVM`, the title GLKVM's web UI carries.
///
/// A redirect, a bare 401 or 403, a JSON error in another shape (UniFi OS answers
/// `{"error": {"code": 401, …}}`) and a page that merely mentions "kvm" do not list a host.
enum DiscoveryProbe {
    /// The GLKVM API endpoints probed. Any one answering kvmd's JSON envelope lists the host.
    static let apiPaths = ["api/auth/check", "api/init/is_inited"]

    /// How much of a page is searched for its title. GLKVM's page names itself within its first
    /// 400 bytes.
    static let pageBytesRead = 8192

    /// The schemes tried on `port`, in order: https first on 443 and 8443, http first elsewhere.
    static func schemes(forPort port: Int) -> [String] {
        (port == 443 || port == 8443) ? ["https", "http"] : ["http", "https"]
    }

    /// Whether an API answer is kvmd's JSON envelope: an object with a Boolean `ok` and an
    /// object `result`, where `ok` is true for a 200 and false for anything else.
    static func isKVMDAnswer(status: Int, body: Data) -> Bool {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: body),
              case .bool(let ok)? = json["ok"],
              case .object? = json["result"] else { return false }
        return ok == (status == 200)
    }

    /// Whether a page is GLKVM's web UI: a 200 whose `<title>` is `GLKVM`, in any case.
    static func isGLKVMPage(status: Int, body: Data) -> Bool {
        guard status == 200 else { return false }
        return pageTitle(body)?.caseInsensitiveCompare("GLKVM") == .orderedSame
    }

    /// The text of the first `<title>` element in the first `pageBytesRead` bytes, trimmed.
    static func pageTitle(_ body: Data) -> String? {
        let text = String(decoding: body.prefix(pageBytesRead), as: UTF8.self)
        guard let open = text.range(of: "<title", options: .caseInsensitive),
              let openEnd = text.range(of: ">", range: open.upperBound..<text.endIndex),
              let close = text.range(of: "</title>", options: .caseInsensitive, range: openEnd.upperBound..<text.endIndex)
        else { return nil }
        return text[openEnd.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether a probe follows a redirect: only to the host it asked, as GLKVM's own http to
    /// https redirect does. A redirect elsewhere (a router's login portal, a vendor's site) is not
    /// followed, so a probe never leaves the address it was sent to.
    static func followsRedirect(from original: URL?, to destination: URL?) -> Bool {
        guard let from = original?.host, let to = destination?.host else { return false }
        return DiscoveredMerge.hostKey(from) == DiscoveredMerge.hostKey(to)
    }
}

/// How a scan works through the swept hosts, in two stages: a quick TCP connect to each host's
/// candidate ports, then HTTP probes (`DiscoveryHTTPProbe`) only on the ports that accepted the
/// connection, each started as soon as its port accepts. Most addresses on a /24 have nothing behind them, and a closed or absent port now
/// costs one short connect attempt instead of holding an HTTP probe slot.
///
/// The connecting and the probing are handed in, so the stage logic can be checked without a
/// network.
enum DiscoverySweep {
    /// One host:port to try.
    struct Target: Hashable, Sendable {
        let host: String
        let port: Int
    }

    /// What one connect attempt learned about a port.
    enum PortState: Sendable, Equatable {
        /// It accepted the connection.
        case open
        /// It refused, the host is known to be down, or nothing answered in time.
        case closed
        /// The attempt was held up by something about the Mac's side rather than the host
        /// ("Network is down" while Network warms up for the app's first connections) and ran out
        /// of time. Tried once more after the other targets.
        case unsure
    }

    /// What a sweep found.
    struct Outcome: Sendable {
        /// The targets that accepted a TCP connection, in target order.
        var openTargets: [Target] = []
        /// The devices the HTTP probes identified, in target order.
        var found: [KVMDevice] = []
        /// How many targets were unsure on the first try and connected to again.
        var retried = 0

        /// How many hosts answered on at least one port.
        var hostsAnswering: Int { Set(openTargets.map(\.host)).count }
    }

    /// How long a connect attempt may take before the port counts as closed. On the home network
    /// (measured 2026-11-09) the GLKVMs accepted in 8 to 28 ms, most hosts answered (accepted or
    /// refused) within 30 ms, and the slowest answer, from a host on Wi-Fi, took 284 ms: power
    /// save can hold a reply for a beacon interval or two. Half a second leaves room over that.
    /// Most of a sweep's attempts go to addresses with no host, and each of those waits out the
    /// full timeout, so this sets the sweep's length.
    static let connectTimeout: TimeInterval = 0.5

    /// How many connect attempts run at once. Targets go host by host, so this is about 12 hosts
    /// (4 ports each) at a time: a dozen ARP requests and 48 SYNs per half second, well under what
    /// a home router handles and far from the 256 file descriptors a Mac app gets by default (each
    /// attempt holds one socket). Not 64: probing 64 targets at a time once tripped rate limiting
    /// on some Wi-Fi routers and starved the Bonjour browse running alongside (872d6d1).
    static let connectLimit = 48

    /// How many HTTP probes run at once, on top of the connects. Only ports that accepted a
    /// connection get one, a handful per network, so this rarely binds; it is the old sweep's
    /// limit. Connects and probes together hold at most 64 sockets plus the few a probe's
    /// requests open.
    static let probeLimit = 16

    /// Every host's ports, host by host, each host's ports in the order given.
    static func targets(hosts: [String], ports: [Int]) -> [Target] {
        hosts.flatMap { host in ports.map { Target(host: host, port: $0) } }
    }

    /// Whether a connect attempt that Network reports as waiting with `code` has its answer: the
    /// port refused (a host is there, the port is closed), or the system already knows the host
    /// is down (an ARP request for it went unanswered moments ago). Any other reason is about the
    /// Mac's side and may clear up within the timeout.
    static func isAnswer(_ code: POSIXErrorCode) -> Bool {
        code == .ECONNREFUSED || code == .EHOSTDOWN
    }

    /// Connects to every target, `connectLimit` at a time, and probes each port as soon as it
    /// accepts, `probeLimit` at a time, alongside the connects still running: a slow host's HTTP
    /// answers then overlap the rest of the sweep instead of adding to it. Once every target has
    /// had one try, the unsure ones get a second. Once the calling task is cancelled no new
    /// connect or probe starts; what already started finishes, and the outcome holds what was
    /// learned by then.
    static func run(
        targets: [Target],
        connectLimit: Int = connectLimit,
        probeLimit: Int = probeLimit,
        connect: @escaping @Sendable (Target) async -> PortState,
        probe: @escaping @Sendable (Target) async -> KVMDevice?
    ) async -> Outcome {
        enum Event: Sendable {
            case connected(Int, PortState)
            case probed(Int, KVMDevice?)
        }

        var states = [PortState?](repeating: nil, count: targets.count)
        var devices: [Int: KVMDevice] = [:]
        var retried = 0
        await withTaskGroup(of: Event.self) { group in
            var connectQueue = ArraySlice(targets.indices)
            var probeQueue: [Int] = []
            var isOnSecondTries = false
            var connecting = 0
            var probing = 0
            while true {
                if !Task.isCancelled {
                    while connecting < max(connectLimit, 1), let index = connectQueue.popFirst() {
                        let target = targets[index]
                        group.addTask { .connected(index, await connect(target)) }
                        connecting += 1
                    }
                    if !isOnSecondTries, connectQueue.isEmpty, connecting == 0 {
                        isOnSecondTries = true
                        let unsure = states.indices.filter { states[$0] == .unsure }
                        retried = unsure.count
                        connectQueue = ArraySlice(unsure)
                        continue
                    }
                    while probing < max(probeLimit, 1), !probeQueue.isEmpty {
                        let index = probeQueue.removeFirst()
                        let target = targets[index]
                        group.addTask { .probed(index, await probe(target)) }
                        probing += 1
                    }
                }
                guard connecting + probing > 0, let event = await group.next() else { break }
                switch event {
                case .connected(let index, let state):
                    connecting -= 1
                    states[index] = state
                    if state == .open {
                        probeQueue.append(index)
                    }
                case .probed(let index, let device):
                    probing -= 1
                    devices[index] = device
                }
            }
        }

        var outcome = Outcome()
        outcome.openTargets = zip(targets, states).compactMap { $0.1 == .open ? $0.0 : nil }
        outcome.found = devices.keys.sorted().compactMap { devices[$0] }
        outcome.retried = retried
        return outcome
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
