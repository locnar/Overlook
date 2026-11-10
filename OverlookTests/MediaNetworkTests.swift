import Foundation
import Testing
@testable import Overlook

/// Reading addresses, and the ranges they fall in.
@Suite("IP addresses")
struct IPAddressTests {
    @Test func readsIPv4AndIPv6AndNothingElse() throws {
        #expect(IPAddress("192.168.0.131")?.family == .v4)
        #expect(IPAddress("fd7a:115c:a1e0::9428:4907")?.family == .v6)
        #expect(IPAddress("[fe80::1]")?.family == .v6)
        #expect(IPAddress("fe80::9683:c4ff:fed7:d748%en0")?.family == .v6)
        #expect(IPAddress("mdesktopkvm") == nil)
        #expect(IPAddress("kvm.example.com") == nil)
        #expect(IPAddress("192.168.0") == nil)
        #expect(IPAddress("256.1.1.1") == nil)
        #expect(IPAddress("") == nil)
        #expect(try #require(IPAddress("fd7a:115c:a1e0:0::9428:4907")).description == "fd7a:115c:a1e0::9428:4907")
        #expect(try #require(IPAddress(" 10.0.0.1 ")).description == "10.0.0.1")
    }

    @Test func tailscaleRanges() {
        #expect(IPAddress("100.64.0.1")!.isTailscale)
        #expect(IPAddress("100.124.73.6")!.isTailscale)
        #expect(IPAddress("100.127.255.255")!.isTailscale)
        #expect(!IPAddress("100.63.255.255")!.isTailscale)
        #expect(!IPAddress("100.128.0.0")!.isTailscale)
        #expect(IPAddress("fd7a:115c:a1e0::9428:4907")!.isTailscale)
        #expect(IPAddress("fd7a:115c:a1e0:ffff::1")!.isTailscale)
        #expect(!IPAddress("fd7a:115c:a1e1::1")!.isTailscale)
        #expect(!IPAddress("fdb2:2c26:f4e4::1")!.isTailscale)
        #expect(!IPAddress("192.168.0.131")!.isTailscale)
    }

    @Test func lanLinkLocalAndLoopbackRanges() {
        for lan in ["10.0.0.1", "10.211.55.2", "172.16.0.1", "172.31.255.255", "192.168.0.131"] {
            #expect(IPAddress(lan)!.isPrivateLAN, "\(lan)")
        }
        for notLAN in ["172.15.0.1", "172.32.0.1", "192.169.0.1", "100.124.73.6", "70.134.225.46", "fdb2:2c26:f4e4::1"] {
            #expect(!IPAddress(notLAN)!.isPrivateLAN, "\(notLAN)")
        }
        #expect(IPAddress("169.254.10.1")!.isLinkLocal)
        #expect(IPAddress("fe80::9683:c4ff:fed7:d748")!.isLinkLocal)
        #expect(IPAddress("febf::1")!.isLinkLocal)
        #expect(!IPAddress("fec0::1")!.isLinkLocal)
        #expect(IPAddress("127.0.0.1")!.isLoopback)
        #expect(IPAddress("::1")!.isLoopback)
        #expect(!IPAddress("::2")!.isLoopback)
    }
}

/// Which hosts a connect reaches without a public STUN server.
@Suite("Direct reachability")
struct DirectReachabilityTests {
    private func reachable(_ host: String) -> Bool {
        MediaNetworkRules.isDirectlyReachable(host: host)
    }

    @Test func theRulesThatWereAlreadyThereStillHold() {
        for host in [
            "10.0.0.5", "172.16.4.4", "172.31.0.1", "192.168.0.131", "127.0.0.1", "169.254.3.3",
            "100.64.0.1", "100.124.73.6", "glkvm.local", "GLKVM.LOCAL", "localhost",
        ] {
            #expect(reachable(host), "\(host)")
        }
        for host in ["8.8.8.8", "70.134.225.46", "172.32.0.1", "100.128.0.1", "kvm.example.com"] {
            #expect(!reachable(host), "\(host)")
        }
    }

    @Test func tailscaleNamesAndAddressesAreDirectlyReachable() {
        #expect(reachable("mdesktopkvm.tail235926.ts.net"))
        #expect(reachable("MDesktopKVM.tail235926.ts.net."))
        #expect(reachable("fd7a:115c:a1e0::9428:4907"))
        #expect(reachable("[fd7a:115c:a1e0::9428:4907]"))
        #expect(!reachable("fd7a:115c:a1e1::1"))
    }

    @Test func aSingleLabelNameIsDirectlyReachable() {
        // A bare MagicDNS name: only a local resolver can answer it.
        #expect(reachable("mdesktopkvm"))
        #expect(reachable("mdesktopkvm."))
        #expect(reachable("glkvm"))
    }

    @Test func otherIPv6AddressesAndEmptyHostsAreNot() {
        // No dot, but an address, not a name.
        #expect(!reachable("2001:db8::1"))
        #expect(!reachable("fdb2:2c26:f4e4::1"))
        #expect(!reachable(""))
        #expect(!reachable("  "))
    }
}

// MARK: - Fixtures

/// What the KVM ("Linux KVM", 192.168.0.131 on the LAN, mdesktopkvm over Tailscale) puts in its
/// offers: every address it has, no trickle. The candidate lines are as Overlook logged them.
enum KVMOffer {
    static let candidates = [
        "a=candidate:1 1 udp 2015372799 192.168.0.131 30272 typ host",
        "a=candidate:2 1 udp 2015364863 100.124.73.6 20207 typ host",
        "a=candidate:3 1 udp 2015364351 fe80::9683:c4ff:fed7:d748 31051 typ host",
        "a=candidate:4 1 udp 2015364095 fd7a:115c:a1e0::9428:4907 31904 typ host",
        "a=candidate:5 1 udp 2015363839 fe80::cd48:fc39:244a:6817 21088 typ host",
        "a=candidate:6 1 udp 1679820287 70.134.225.46 30272 typ srflx raddr 192.168.0.131 rport 30272",
    ]

    static func section(_ kind: String, mid: Int, candidates: [String] = candidates) -> [String] {
        [
            "m=\(kind) 9 UDP/TLS/RTP/SAVPF 96",
            "c=IN IP4 192.168.0.131",
            "a=mid:\(mid)",
            "a=sendonly",
            "a=ice-ufrag:og3X",
            "a=ice-pwd:0123456789abcdef0123456789",
        ] + candidates + ["a=end-of-candidates"]
    }

    static let header = ["v=0", "o=- 1794326147 1 IN IP4 192.168.0.131", "s=Mountpoint 0", "t=0 0"]

    /// An SDP with CRLF line endings, as Janus sends them.
    static func sdp(_ lines: [String]) -> String {
        lines.map { $0 + "\r\n" }.joined()
    }

    static let video = sdp(header + section("video", mid: 0))
    static let audioAndVideo = sdp(header + section("audio", mid: 0) + section("video", mid: 1))
}

/// Candidates this Mac gathered on the day: en0, Parallels' two host-only networks, Tailscale.
enum MacCandidates {
    static let en0 = "candidate:3310090850 1 udp 2121998079 192.168.0.104 60988 typ host generation 0 ufrag cvSY network-id 5 network-cost 50"
    static let parallels1 = "candidate:1875148514 1 udp 2122129151 10.211.55.2 49811 typ host generation 0 ufrag cvSY network-id 1 network-cost 50"
    static let parallels2 = "candidate:2374150806 1 udp 2122063615 10.37.129.2 56652 typ host generation 0 ufrag cvSY network-id 3 network-cost 50"
    static let parallelsV6 = "candidate:1695909445 1 udp 2122265343 fdb2:2c26:f4e4::1 62582 typ host generation 0 ufrag cvSY network-id 2 network-cost 50"
    static let tailscale = "candidate:3275576066 1 udp 2121867007 100.70.188.74 60307 typ host generation 0 ufrag cvSY network-id 8 network-cost 50"
    static let tailscaleV6 = "candidate:1612082165 1 udp 2121937663 fd7a:115c:a1e0::2928:bc4b 50806 typ host generation 0 ufrag cvSY network-id 9 network-cost 50"
    static let en0TCP = "candidate:2590058906 1 tcp 1518018303 192.168.0.104 9 typ host tcptype passive generation 0 ufrag cvSY network-id 5 network-cost 50"
    static let loopback = "candidate:236875880 1 udp 2121735935 127.0.0.1 59281 typ host generation 0 ufrag cvSY network-id 6 network-cost 0"

    static let all = [en0, parallels1, parallels2, parallelsV6, tailscale, tailscaleV6, en0TCP, loopback]

    static func interface(_ name: String, _ address: String, _ mask: String) -> LocalInterfaceAddress {
        LocalInterfaceAddress(name: name, address: IPAddress(address)!, netmask: IPAddress(mask)!)
    }

    static let interfaces = [
        interface("lo0", "127.0.0.1", "255.0.0.0"),
        interface("en0", "192.168.0.104", "255.255.255.0"),
        interface("bridge100", "10.211.55.2", "255.255.255.0"),
        interface("bridge101", "10.37.129.2", "255.255.255.0"),
        interface("utun14", "100.70.188.74", "255.255.255.255"),
    ]
}

private func route(
    _ host: String,
    preference: MediaAddresses = .chosenNetwork,
    resolved: [String] = [],
    interfaces: [LocalInterfaceAddress] = MacCandidates.interfaces
) -> MediaRoute {
    MediaRoute.decide(preference: preference, host: host, resolved: resolved, interfaces: interfaces)
}

private func kept(_ route: MediaRoute, _ lines: [String]) -> [String] {
    lines.filter { route.keepsLocal(ICECandidateLine($0)!) }.map { ICECandidateLine($0)!.address }
}

// MARK: - Classification

@Suite("Which network a connect is on")
struct MediaNetworkClassificationTests {
    @Test func addressesAndTailscaleNamesClassifyOnTheirOwn() {
        #expect(MediaNetwork.classify(host: "192.168.0.131") == .lan)
        #expect(MediaNetwork.classify(host: "10.1.2.3") == .lan)
        #expect(MediaNetwork.classify(host: "172.20.0.9") == .lan)
        #expect(MediaNetwork.classify(host: "100.124.73.6") == .tailscale)
        #expect(MediaNetwork.classify(host: "fd7a:115c:a1e0::9428:4907") == .tailscale)
        #expect(MediaNetwork.classify(host: "mdesktopkvm.tail235926.ts.net") == .tailscale)
        #expect(MediaNetwork.classify(host: "MDESKTOPKVM.tail235926.ts.net.") == .tailscale)
        #expect(MediaNetwork.classify(host: "70.134.225.46") == nil)
        #expect(MediaNetwork.classify(host: "fdb2:2c26:f4e4::1") == nil)
        #expect(MediaNetwork.classify(host: "mdesktopkvm") == nil)
    }

    @Test func onlyOtherHostNamesNeedResolving() {
        #expect(MediaNetwork.needsResolution(host: "mdesktopkvm"))
        #expect(MediaNetwork.needsResolution(host: "kvm.example.com"))
        #expect(!MediaNetwork.needsResolution(host: "mdesktopkvm.tail235926.ts.net"))
        #expect(!MediaNetwork.needsResolution(host: "192.168.0.131"))
        #expect(!MediaNetwork.needsResolution(host: "fd7a:115c:a1e0::9428:4907"))
    }

    @Test func aLANAddressGivesTheLANRoute() {
        let lan = route("192.168.0.131")
        #expect(lan.scope == .chosen(.lan))
        #expect(lan.peerAddress == IPAddress("192.168.0.131"))
        #expect(lan.unclassifiedReason == nil)
        #expect(lan.appliedPreference == .chosenNetwork)
    }

    @Test func aBareMagicDNSNameIsClassifiedByWhatItResolvedTo() {
        let tailscale = route("mdesktopkvm", resolved: ["100.124.73.6", "fd7a:115c:a1e0::9428:4907"])
        #expect(tailscale.scope == .chosen(.tailscale))
        #expect(tailscale.peerAddress == IPAddress("100.124.73.6"))

        // The system's preferred address is the one that counts.
        let lanName = route("kvm.home.arpa", resolved: ["192.168.0.131", "100.124.73.6"])
        #expect(lanName.scope == .chosen(.lan))
    }

    @Test func whatCannotBeClassifiedUsesAllAddressesAndSaysWhy() {
        let unresolved = route("mdesktopkvm", resolved: [])
        #expect(unresolved.scope == .all)
        #expect(unresolved.unclassifiedReason == "mdesktopkvm did not resolve")
        #expect(unresolved.connectDescription
            == "Video and audio may use any network (all addresses) for this connect: mdesktopkvm did not resolve")

        let publicName = route("kvm.example.com", resolved: ["203.0.113.5"])
        #expect(publicName.scope == .all)
        #expect(publicName.unclassifiedReason
            == "kvm.example.com resolved to 203.0.113.5, which is neither a LAN nor a Tailscale address")

        let publicAddress = route("70.134.225.46")
        #expect(publicAddress.scope == .all)
        #expect(publicAddress.unclassifiedReason == "70.134.225.46 is neither a LAN nor a Tailscale address")
        #expect(publicAddress.appliedPreference == .all)
    }

    @Test func allAddressesIsTodaysBehaviourWhateverTheHost() {
        for host in ["192.168.0.131", "mdesktopkvm", "100.124.73.6"] {
            let all = route(host, preference: .all, resolved: ["100.124.73.6"])
            #expect(all.scope == .all)
            #expect(all.unclassifiedReason == nil)
            #expect(all.connectDescription == "Video and audio may use any network (all addresses)")
        }
    }
}

// MARK: - The factory and STUN

@Suite("Factory options and STUN per route")
struct MediaRouteFactoryTests {
    @Test func theLANLeavesOutVPNAndLoopbackAdapters() {
        #expect(route("192.168.0.131").adapterOptions == MediaAdapterOptions(ignoresVPN: true, ignoresLoopback: true))
    }

    @Test func tailscaleAndAllAddressesSetNoOptions() {
        #expect(route("mdesktopkvm.tail235926.ts.net").adapterOptions == .standard)
        #expect(route("192.168.0.131", preference: .all).adapterOptions == .standard)
        #expect(route("kvm.example.com", resolved: ["203.0.113.5"]).adapterOptions == .standard)
        #expect(MediaAdapterOptions.standard == MediaAdapterOptions(ignoresVPN: false, ignoresLoopback: false))
    }

    @Test func aChosenNetworkNeverAddsPublicSTUN() {
        #expect(!route("192.168.0.131").addsPublicSTUN)
        #expect(!route("mdesktopkvm", resolved: ["100.124.73.6"]).addsPublicSTUN)
        // A public-looking name that resolved to Tailscale still needs no STUN.
        #expect(!route("kvm.example.com", resolved: ["100.124.73.6"]).addsPublicSTUN)
    }

    @Test func allAddressesKeepsTheReachabilityRule() {
        #expect(!route("192.168.0.131", preference: .all).addsPublicSTUN)
        #expect(!route("mdesktopkvm", preference: .all).addsPublicSTUN)
        #expect(route("kvm.example.com", preference: .all).addsPublicSTUN)
        #expect(route("kvm.example.com", resolved: ["203.0.113.5"]).addsPublicSTUN)
    }
}

// MARK: - The KVM's candidates

@Suite("Filtering the KVM's offer")
struct RemoteOfferFilterTests {
    @Test func readsCandidateLines() throws {
        let srflx = try #require(ICECandidateLine(KVMOffer.candidates[5]))
        #expect(srflx.address == "70.134.225.46")
        #expect(srflx.type == "srflx")
        #expect(srflx.label == "70.134.225.46 srflx")
        let local = try #require(ICECandidateLine(MacCandidates.en0TCP))
        #expect(local.address == "192.168.0.104")
        #expect(local.type == "host")
        #expect(ICECandidateLine("a=mid:0") == nil)
        #expect(ICECandidateLine("a=candidate:1 1 udp 2015372799 192.168.0.131") == nil)
    }

    @Test func theLANKeepsOnlyTheKVMsLANHostCandidate() {
        let result = route("192.168.0.131").filterRemoteOffer(KVMOffer.video)
        #expect(!result.keptWholeOffer)
        #expect(result.dropped.map(\.label) == [
            "100.124.73.6",
            "fe80::9683:c4ff:fed7:d748",
            "fd7a:115c:a1e0::9428:4907",
            "fe80::cd48:fc39:244a:6817",
            "70.134.225.46 srflx",
        ])
        #expect(result.sdp == KVMOffer.sdp(KVMOffer.header + KVMOffer.section("video", mid: 0, candidates: [KVMOffer.candidates[0]])))
    }

    @Test func tailscaleKeepsOnlyTheKVMsTailscaleCandidates() {
        let result = route("mdesktopkvm", resolved: ["100.124.73.6"]).filterRemoteOffer(KVMOffer.video)
        #expect(result.dropped.map(\.label) == [
            "192.168.0.131",
            "fe80::9683:c4ff:fed7:d748",
            "fe80::cd48:fc39:244a:6817",
            "70.134.225.46 srflx",
        ])
        #expect(result.sdp == KVMOffer.sdp(KVMOffer.header + KVMOffer.section(
            "video", mid: 0, candidates: [KVMOffer.candidates[1], KVMOffer.candidates[3]]
        )))
    }

    @Test func everyMediaSectionIsFiltered() {
        let result = route("192.168.0.131").filterRemoteOffer(KVMOffer.audioAndVideo)
        #expect(result.dropped.count == 10)
        let expected = KVMOffer.header
            + KVMOffer.section("audio", mid: 0, candidates: [KVMOffer.candidates[0]])
            + KVMOffer.section("video", mid: 1, candidates: [KVMOffer.candidates[0]])
        #expect(result.sdp == KVMOffer.sdp(expected))
    }

    @Test func allAddressesLeavesTheOfferAlone() {
        let result = route("192.168.0.131", preference: .all).filterRemoteOffer(KVMOffer.video)
        #expect(result.sdp == KVMOffer.video)
        #expect(result.dropped.isEmpty)
    }

    @Test func anOfferWithNothingOnTheChosenNetworkIsLeftWhole() {
        let tailscaleOnly = KVMOffer.sdp(KVMOffer.header + KVMOffer.section(
            "video", mid: 0, candidates: [KVMOffer.candidates[1], KVMOffer.candidates[5]]
        ))
        let result = route("192.168.0.131").filterRemoteOffer(tailscaleOnly)
        #expect(result.keptWholeOffer)
        #expect(result.sdp == tailscaleOnly)
        #expect(result.dropped.isEmpty)
    }

    @Test func anOfferWithNoCandidatesAtAllIsNotALeftWholeCase() {
        let none = KVMOffer.sdp(KVMOffer.header + KVMOffer.section("video", mid: 0, candidates: []))
        let result = route("192.168.0.131").filterRemoteOffer(none)
        #expect(!result.keptWholeOffer)
        #expect(result.sdp == none)
    }

    @Test func aTrickledCandidateFollowsTheSameRules() {
        let lan = route("192.168.0.131")
        let tailscale = route("mdesktopkvm.tail235926.ts.net")
        let lines = KVMOffer.candidates.map { ICECandidateLine(String($0.dropFirst(2)))! }
        #expect(lines.map(lan.keepsRemote) == [true, false, false, false, false, false])
        #expect(lines.map(tailscale.keepsRemote) == [false, true, false, true, false, false])
    }
}

// MARK: - This Mac's candidates

@Suite("Which local candidates are sent to the KVM")
struct LocalCandidateFilterTests {
    @Test func tailscaleSendsOnlyTailscaleAddresses() {
        let tailscale = route("mdesktopkvm.tail235926.ts.net")
        #expect(kept(tailscale, MacCandidates.all) == ["100.70.188.74", "fd7a:115c:a1e0::2928:bc4b"])
    }

    @Test func theLANSendsOnlyAddressesOnTheKVMsSubnet() {
        let lan = route("192.168.0.131")
        #expect(lan.onLinkLocalAddresses == [IPAddress("192.168.0.104")!])
        // Parallels' host-only networks, their IPv6, Tailscale and loopback stay off the KVM.
        #expect(kept(lan, MacCandidates.all) == ["192.168.0.104", "192.168.0.104"])
    }

    @Test func aKVMBehindARouterKeepsEveryLANAdapter() {
        // No local address shares 192.168.7.0/24, so nothing is held back on the subnet rule.
        let routed = route("192.168.7.20")
        #expect(routed.onLinkLocalAddresses.isEmpty)
        #expect(kept(routed, MacCandidates.all)
            == ["192.168.0.104", "10.211.55.2", "10.37.129.2", "fdb2:2c26:f4e4::1", "192.168.0.104"])
    }

    @Test func allAddressesSendsEverything() {
        let all = route("192.168.0.131", preference: .all)
        #expect(kept(all, MacCandidates.all).count == MacCandidates.all.count)
    }

    @Test func subnetsAreReadFromTheNetmask() {
        let en0 = MacCandidates.interface("en0", "192.168.0.104", "255.255.255.0")
        #expect(en0.sharesSubnet(with: IPAddress("192.168.0.131")!))
        #expect(!en0.sharesSubnet(with: IPAddress("192.168.1.131")!))
        #expect(!en0.sharesSubnet(with: IPAddress("fd7a:115c:a1e0::1")!))
        let wide = MacCandidates.interface("en1", "10.4.0.2", "255.252.0.0")
        #expect(wide.sharesSubnet(with: IPAddress("10.7.255.1")!))
        #expect(!wide.sharesSubnet(with: IPAddress("10.8.0.1")!))
        let tunnel = MacCandidates.interface("utun14", "100.70.188.74", "255.255.255.255")
        #expect(!tunnel.sharesSubnet(with: IPAddress("100.70.188.74")!))
    }

    @Test func theLogLinesNameTheRoute() {
        #expect(route("192.168.0.131").connectDescription
            == "Video and audio limited to the LAN (chosen network only), connecting through 192.168.0.131; "
                + "VPN and loopback adapters left out; local candidates limited to 192.168.0.104")
        #expect(route("mdesktopkvm", resolved: ["100.124.73.6"]).connectDescription
            == "Video and audio limited to Tailscale (chosen network only), connecting through mdesktopkvm "
                + "(100.124.73.6); only Tailscale candidates used")
        #expect(route("192.168.0.131").limitDescription == "Video and audio limited to the LAN (chosen network only)")
    }
}

// MARK: - The setting

@MainActor
@Suite("Video and audio addresses setting")
struct NetworkPreferencesTests {
    let scratch = ScratchDefaults()

    @Test func defaultsToChosenNetworkOnly() {
        let preferences = NetworkPreferences(defaults: scratch.defaults)
        #expect(preferences.mediaAddresses == .chosenNetwork)
        #expect(scratch.defaults.string(forKey: NetworkPreferences.Keys.mediaAddresses) == nil)
    }

    @Test func aChoiceIsSavedAndReadBack() {
        let preferences = NetworkPreferences(defaults: scratch.defaults)
        preferences.mediaAddresses = .all
        #expect(scratch.defaults.string(forKey: "overlook.network.mediaAddresses") == "all")
        #expect(NetworkPreferences(defaults: scratch.defaults).mediaAddresses == .all)

        preferences.mediaAddresses = .chosenNetwork
        #expect(scratch.defaults.string(forKey: "overlook.network.mediaAddresses") == "chosenNetwork")
        #expect(NetworkPreferences(defaults: scratch.defaults).mediaAddresses == .chosenNetwork)
    }

    @Test func anUnknownStoredValueReadsAsTheDefault() {
        scratch.defaults.set("everything", forKey: NetworkPreferences.Keys.mediaAddresses)
        #expect(NetworkPreferences(defaults: scratch.defaults).mediaAddresses == .chosenNetwork)
    }

    @Test func choicesAreTitledAsInSettings() {
        #expect(MediaAddresses.allCases.map(\.title) == ["Chosen network only", "All addresses"])
    }
}

// MARK: - Through the manager

/// The route as a connect applies it: decided before the peers exist, the offer filtered on its
/// way to `setRemoteDescription`, and local candidates held back from the signaling socket. No
/// peer connection is made and nothing reaches DNS or the network.
@MainActor
@Suite("Media route through the manager")
struct ManagerMediaRouteTests {
    let scratch = ScratchDefaults()
    let log = SessionLog(destination: .inMemory())
    let preferences: NetworkPreferences
    let manager: WebRTCManager
    private let lookups = LookupLog()

    final class LookupLog {
        var hosts: [String] = []
    }

    init() {
        preferences = NetworkPreferences(defaults: scratch.defaults)
        manager = WebRTCManager(
            audioPreferences: AudioPreferences(defaults: scratch.defaults),
            networkPreferences: preferences,
            log: log
        )
        let lookups = self.lookups
        manager.resolveHost = { host in
            lookups.hosts.append(host)
            return host == "mdesktopkvm" ? ["100.124.73.6", "fd7a:115c:a1e0::9428:4907"] : []
        }
        manager.localInterfaces = { MacCandidates.interfaces }
    }

    /// The log's lines containing `text`, once every line written so far has reached the store
    /// (the in-memory log publishes on the main actor, a hop later).
    private func messages(containing text: String) async -> [String] {
        let marker = "flush-\(UUID().uuidString)"
        log.debug(.ice, marker)
        await waitUntil { log.store.events(in: .allDevices).contains { $0.message.contains(marker) } }
        return log.store.events(in: .allDevices).map(\.message).filter { $0.contains(text) }
    }

    private func device(_ host: String) -> KVMDevice {
        Fixtures.device(nickname: "Linux KVM", host: host)
    }

    @Test func aConnectDecidesItsRouteFromTheAddressAndTheSetting() async {
        let lan = await manager.prepareMediaRoute(for: device("192.168.0.131"))
        #expect(lan.scope == .chosen(.lan))
        #expect(manager.mediaRoute == lan)
        #expect(manager.mediaAddressesInEffect == .chosenNetwork)
        #expect(lookups.hosts.isEmpty)

        let tailscale = await manager.prepareMediaRoute(for: device("mdesktopkvm"))
        #expect(tailscale.scope == .chosen(.tailscale))
        #expect(lookups.hosts == ["mdesktopkvm"])

        preferences.mediaAddresses = .all
        let all = await manager.prepareMediaRoute(for: device("mdesktopkvm"))
        #expect(all.scope == .all)
        #expect(manager.mediaAddressesInEffect == .all)
        // "All addresses" has no use for the name's address.
        #expect(lookups.hosts == ["mdesktopkvm"])
        #expect(await messages(containing: "Video and audio may use any network (all addresses)").count == 1)
    }

    @Test func anUnclassifiedConnectIsLoggedOnce() async {
        await manager.prepareMediaRoute(for: device("kvm.example.com"))
        #expect(await messages(containing: "for this connect: kvm.example.com did not resolve").count == 1)
        #expect(manager.mediaRoute.scope == .all)
        #expect(manager.mediaAddressesInEffect == .chosenNetwork)
    }

    @Test func theFilteredOfferIsWhatReachesSetRemoteDescription() async {
        await manager.prepareMediaRoute(for: device("192.168.0.131"))
        var applied: [RTCSessionDescription] = []
        await manager.applyRemoteOffer(KVMOffer.video, leg: .video) { applied.append($0) }
        await manager.applyRemoteOffer(KVMOffer.video, leg: .audio) { applied.append($0) }

        #expect(applied.count == 2)
        #expect(applied.allSatisfy { $0.type == .offer })
        let expected = KVMOffer.sdp(KVMOffer.header + KVMOffer.section("video", mid: 0, candidates: [KVMOffer.candidates[0]]))
        #expect(applied.allSatisfy { $0.sdp == expected })
        // One line for the two legs, which carry the same addresses.
        #expect(await messages(containing: "dropped 5 remote candidates").count == 1)
        #expect(await messages(containing: "Video and audio limited to the LAN (chosen network only): dropped 5 remote candidates "
            + "(100.124.73.6, fe80::9683:c4ff:fed7:d748, fd7a:115c:a1e0::9428:4907, fe80::cd48:fc39:244a:6817, 70.134.225.46 srflx)").count == 1)
    }

    @Test func allAddressesPassesTheOfferThroughUntouched() async {
        preferences.mediaAddresses = .all
        await manager.prepareMediaRoute(for: device("192.168.0.131"))
        var applied: [String] = []
        await manager.applyRemoteOffer(KVMOffer.video, leg: .video) { applied.append($0.sdp) }
        #expect(applied == [KVMOffer.video])
        #expect(await messages(containing: "dropped").isEmpty)
    }

    @Test func aFailedSetRemoteDescriptionIsLogged() async {
        await manager.prepareMediaRoute(for: device("192.168.0.131"))
        await manager.applyRemoteOffer(KVMOffer.video, leg: .video) { _ in throw TestError(name: "refused") }
        #expect(await messages(containing: "Set remote description failed").count == 1)
    }

    @Test func aTailscaleConnectTricklesOnlyTailscaleCandidates() async throws {
        await manager.prepareMediaRoute(for: device("mdesktopkvm"))
        let socket = FakeSignalingSocket()
        manager.makeSignalingSender(for: socket, timing: .testing())
        manager.janusSessionId = 41

        for line in MacCandidates.all {
            await manager.trickleLocalCandidate(RTCIceCandidate(sdp: line, sdpMLineIndex: 0, sdpMid: "0"), handleId: 42)
        }

        let sent = socket.frames.compactMap { text -> String? in
            guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  object["janus"] as? String == "trickle",
                  object["handle_id"] as? Int == 42,
                  let candidate = object["candidate"] as? [String: Any] else { return nil }
            return candidate["candidate"] as? String
        }
        #expect(sent == [MacCandidates.tailscale, MacCandidates.tailscaleV6])

        manager.logHeldBackLocalCandidates()
        manager.logHeldBackLocalCandidates()
        let line = "Video and audio limited to Tailscale (chosen network only): not sending 5 local addresses to the KVM "
            + "(192.168.0.104, 10.211.55.2, 10.37.129.2, fdb2:2c26:f4e4::1, 127.0.0.1)"
        #expect(await messages(containing: line).count == 1)
    }

    @Test func allAddressesTricklesEveryCandidate() async throws {
        preferences.mediaAddresses = .all
        await manager.prepareMediaRoute(for: device("mdesktopkvm"))
        let socket = FakeSignalingSocket()
        manager.makeSignalingSender(for: socket, timing: .testing())
        manager.janusSessionId = 41

        for line in MacCandidates.all {
            await manager.trickleLocalCandidate(RTCIceCandidate(sdp: line, sdpMLineIndex: 0, sdpMid: "0"), handleId: 42)
        }
        #expect(socket.verbs == Array(repeating: "trickle", count: MacCandidates.all.count))
    }

    @Test func trickledRemoteCandidatesFollowTheRoute() async {
        await manager.prepareMediaRoute(for: device("mdesktopkvm"))
        #expect(manager.keepsTrickledRemoteCandidate("candidate:2 1 udp 2015364863 100.124.73.6 20207 typ host"))
        #expect(!manager.keepsTrickledRemoteCandidate("candidate:1 1 udp 2015372799 192.168.0.131 30272 typ host"))
        // A line that cannot be read is left to libwebrtc.
        #expect(manager.keepsTrickledRemoteCandidate("not a candidate"))
    }

    @Test func disconnectingClearsTheSettingInEffect() async {
        await manager.prepareMediaRoute(for: device("192.168.0.131"))
        #expect(manager.mediaAddressesInEffect == .chosenNetwork)
        manager.disconnect()
        #expect(manager.mediaAddressesInEffect == nil)
    }
}
