import Foundation
import Network
import Testing
@testable import Overlook

/// Scan's rules: what is swept and what a probed host must answer. Nothing here touches the
/// network; the interface lists are made up.
@Suite("Discovery sweep")
struct DiscoverySweepTests {
    static let wifi = IPv4Interface(name: "en0", address: "192.168.0.42", netmask: "255.255.255.0")

    @Test func the192_168_200NetworkIsNotSweptWithoutAnInterfaceOnIt() {
        let hosts = LocalSweep.hosts(for: [Self.wifi])
        #expect(!hosts.contains { $0.hasPrefix("192.168.200.") })
        #expect(hosts.contains("192.168.0.131"))
    }

    @Test func the192_168_200NetworkIsSweptWhenTheMacIsOnIt() {
        let gadget = IPv4Interface(name: "en7", address: "192.168.200.2", netmask: "255.255.255.0")
        let hosts = LocalSweep.hosts(for: [Self.wifi, gadget])
        #expect(hosts.contains("192.168.200.1"))
        #expect(hosts.contains("192.168.200.5"))
        #expect(hosts.contains("192.168.0.131"))
    }

    @Test func sweepsThe24AroundTheInterfaceAddress() {
        let hosts = LocalSweep.hosts(for: [Self.wifi])
        #expect(hosts.first == "192.168.0.1")
        #expect(hosts.last == "192.168.0.254")
        #expect(!hosts.contains("192.168.0.0"))
        #expect(!hosts.contains("192.168.0.255"))
        #expect(!hosts.contains("192.168.1.1"))
    }

    @Test func aPublicAddressIsNotSwept() {
        let publicInterface = IPv4Interface(name: "en0", address: "203.0.113.7", netmask: "255.255.255.0")
        let hosts = LocalSweep.hosts(for: [Self.wifi, publicInterface])
        #expect(!hosts.contains { $0.hasPrefix("203.0.113.") })
    }
}

/// Which interfaces' networks are swept, and how much of each.
@Suite("Discovery interfaces")
struct DiscoveryInterfaceTests {
    // A Mac on Wi-Fi with Tailscale up, a VM bridge, a USB Ethernet adapter on a /16, and the
    // interfaces macOS always has.
    static let wifi = IPv4Interface(name: "en0", address: "192.168.0.42", netmask: "255.255.255.0")
    static let tailscale = IPv4Interface(
        name: "utun3", address: "100.101.102.103", netmask: "255.192.0.0", isPointToPoint: true
    )
    static let vmBridge = IPv4Interface(name: "bridge100", address: "192.168.64.1", netmask: "255.255.255.0")
    static let loopback = IPv4Interface(name: "lo0", address: "127.0.0.1", netmask: "255.0.0.0", isLoopback: true)
    static let wideEthernet = IPv4Interface(name: "en5", address: "10.20.30.40", netmask: "255.255.0.0")
    static let unpluggedEthernet = IPv4Interface(
        name: "en6", address: "192.168.50.10", netmask: "255.255.255.0", isUp: true, isRunning: false
    )
    static let downEthernet = IPv4Interface(
        name: "en8", address: "192.168.60.10", netmask: "255.255.255.0", isUp: false, isRunning: false
    )
    static let all = [wifi, tailscale, vmBridge, loopback, wideEthernet, unpluggedEthernet, downEthernet]

    @Test func onlyUpEthernetAndWiFiWithAPrivateAddressAreSwept() {
        let ranges = LocalSweep.ranges(for: Self.all)
        #expect(ranges.map(\.interface) == ["en0", "en5"])
        #expect(ranges.map(\.cidr) == ["192.168.0.0/24", "10.20.30.0/24"])
    }

    @Test func tailscaleIsNeverSwept() {
        let hosts = LocalSweep.hosts(for: Self.all)
        #expect(!hosts.contains { AddressTag.classify(host: $0) == .tailscale })
        #expect(!LocalSweep.isSweepable(Self.tailscale))
        // Not even on an interface that looks like Ethernet: 100.64.0.0/10 is not RFC 1918.
        let oddTailscale = IPv4Interface(name: "en9", address: "100.64.0.9", netmask: "255.255.255.0")
        #expect(!LocalSweep.isSweepable(oddTailscale))
    }

    @Test func vmBridgesAndLoopbackAreNotSwept() {
        let hosts = Set(LocalSweep.hosts(for: Self.all))
        #expect(!hosts.contains("192.168.64.2"))
        #expect(!hosts.contains { $0.hasPrefix("127.") })
        #expect(!LocalSweep.isSweepable(Self.vmBridge))
        #expect(!LocalSweep.isSweepable(Self.loopback))
    }

    @Test func interfacesThatAreDownOrNotRunningAreNotSwept() {
        #expect(!LocalSweep.isSweepable(Self.unpluggedEthernet))
        #expect(!LocalSweep.isSweepable(Self.downEthernet))
        let hosts = Set(LocalSweep.hosts(for: Self.all))
        #expect(!hosts.contains("192.168.50.1"))
        #expect(!hosts.contains("192.168.60.1"))
    }

    @Test func otherInterfaceKindsAreNotSwept() {
        for name in ["utun0", "bridge0", "awdl0", "llw0", "ap1", "gif0", "stf0", "anpi0", "lo0", "en", "enx1", "vmenet0"] {
            let interface = IPv4Interface(name: name, address: "192.168.0.42", netmask: "255.255.255.0")
            #expect(!LocalSweep.isSweepable(interface), "\(name)")
        }
        for name in ["en0", "en1", "en5", "en12"] {
            let interface = IPv4Interface(name: name, address: "192.168.0.42", netmask: "255.255.255.0")
            #expect(LocalSweep.isSweepable(interface), "\(name)")
        }
    }

    @Test func aPointToPointLinkIsNotSwept() {
        let link = IPv4Interface(name: "en3", address: "10.0.0.2", netmask: "255.255.255.0", isPointToPoint: true)
        #expect(!LocalSweep.isSweepable(link))
    }

    @Test func onlyRFC1918AddressesAreSwept() {
        for address in ["10.1.2.3", "172.16.0.5", "172.31.255.1", "192.168.1.9"] {
            #expect(LocalSweep.isSweepable(IPv4Interface(name: "en0", address: address, netmask: "255.255.255.0")), "\(address)")
        }
        for address in ["172.15.0.5", "172.32.0.5", "169.254.10.20", "100.64.1.1", "8.8.8.8"] {
            #expect(!LocalSweep.isSweepable(IPv4Interface(name: "en0", address: address, netmask: "255.255.255.0")), "\(address)")
        }
    }

    @Test func aWideNetmaskIsNarrowedToThe24HoldingTheMac() throws {
        let range = try #require(LocalSweep.range(for: Self.wideEthernet))
        #expect(range.cidr == "10.20.30.0/24")
        #expect(range.hosts.count == 254)
        #expect(range.hosts.first == "10.20.30.1")
        #expect(range.hosts.last == "10.20.30.254")
        let classA = IPv4Interface(name: "en0", address: "10.200.7.9", netmask: "255.0.0.0")
        #expect(LocalSweep.range(for: classA)?.cidr == "10.200.7.0/24")
    }

    @Test func aNarrowNetmaskIsSweptAsItIs() throws {
        let small = IPv4Interface(name: "en0", address: "192.168.0.70", netmask: "255.255.255.192")
        let range = try #require(LocalSweep.range(for: small))
        #expect(range.cidr == "192.168.0.64/26")
        #expect(range.hosts.first == "192.168.0.65")
        #expect(range.hosts.last == "192.168.0.126")
        #expect(range.hosts.count == 62)
    }

    @Test func aSubnetWithNoOtherHostIsNotSwept() {
        let slash31 = IPv4Interface(name: "en0", address: "10.0.0.0", netmask: "255.255.255.254")
        let slash32 = IPv4Interface(name: "en0", address: "10.0.0.1", netmask: "255.255.255.255")
        #expect(LocalSweep.range(for: slash31) == nil)
        #expect(LocalSweep.range(for: slash32) == nil)
    }

    @Test func aMissingOrMalformedNetmaskCountsAs24() {
        let none = IPv4Interface(name: "en0", address: "192.168.0.42", netmask: "")
        let gappy = IPv4Interface(name: "en0", address: "192.168.0.42", netmask: "255.0.255.0")
        #expect(LocalSweep.range(for: none)?.cidr == "192.168.0.0/24")
        #expect(LocalSweep.range(for: gappy)?.cidr == "192.168.0.0/24")
    }

    @Test func netmaskPrefixLengths() {
        #expect(LocalSweep.prefixLength(ofNetmask: "255.255.255.0") == 24)
        #expect(LocalSweep.prefixLength(ofNetmask: "255.255.0.0") == 16)
        #expect(LocalSweep.prefixLength(ofNetmask: "255.255.255.192") == 26)
        #expect(LocalSweep.prefixLength(ofNetmask: "255.255.255.255") == 32)
        #expect(LocalSweep.prefixLength(ofNetmask: "0.0.0.0") == 0)
        #expect(LocalSweep.prefixLength(ofNetmask: "255.0.255.0") == nil)
        #expect(LocalSweep.prefixLength(ofNetmask: "not a mask") == nil)
    }

    @Test func twoInterfacesOnOneNetworkSweepItOnce() {
        let ethernet = IPv4Interface(name: "en7", address: "192.168.0.43", netmask: "255.255.255.0")
        let ranges = LocalSweep.ranges(for: [Self.wifi, ethernet])
        #expect(ranges.map(\.cidr) == ["192.168.0.0/24"])
        let hosts = LocalSweep.hosts(for: [Self.wifi, ethernet])
        #expect(hosts.count == Set(hosts).count)
    }

    @Test func theMacsOwnAddressesAreNotProbed() {
        let hosts = LocalSweep.hosts(for: Self.all)
        #expect(!hosts.contains("192.168.0.42"))
        #expect(!hosts.contains("10.20.30.40"))
        #expect(hosts.contains("192.168.0.41"))
        #expect(hosts.count == 254 - 1 + 254 - 1)
    }

    /// Reads this Mac's own interface list (no traffic): loopback is always there, with its
    /// netmask and flags read correctly.
    @Test func readsTheMacsInterfacesWithNetmaskAndFlags() throws {
        let interfaces = KVMDeviceManager.readIPv4Interfaces()
        let loopback = try #require(interfaces.first { $0.name == "lo0" && $0.address == "127.0.0.1" })
        #expect(loopback.netmask == "255.0.0.0")
        #expect(loopback.isLoopback)
        #expect(loopback.isUp)
        #expect(!LocalSweep.isSweepable(loopback))
    }

    @Test func withNoQualifyingInterfaceNothingIsSwept() {
        #expect(LocalSweep.hosts(for: []).isEmpty)
        #expect(LocalSweep.hosts(for: [Self.tailscale, Self.vmBridge, Self.loopback, Self.downEthernet]).isEmpty)
    }
}

@Suite("Discovery probe")
struct DiscoveryProbeTests {
    @Test func httpsIsTriedFirstOnTheTLSPorts() {
        #expect(DiscoveryProbe.schemes(forPort: 443) == ["https", "http"])
        #expect(DiscoveryProbe.schemes(forPort: 8443) == ["https", "http"])
        #expect(DiscoveryProbe.schemes(forPort: 80) == ["http", "https"])
        #expect(DiscoveryProbe.schemes(forPort: 8080) == ["http", "https"])
    }

    @Test func theAPIEndpointsProbed() {
        #expect(DiscoveryProbe.apiPaths == ["api/auth/check", "api/init/is_inited"])
    }

    @Test func apiAnswersThatListAHost() {
        for status in [200, 401, 403, 301, 302, 307, 308] {
            #expect(DiscoveryProbe.apiStatusLooksLikeGLKVM(status), "\(status)")
        }
        for status in [204, 400, 404, 405, 500, 502, 503] {
            #expect(!DiscoveryProbe.apiStatusLooksLikeGLKVM(status), "\(status)")
        }
    }

    @Test func aPageThatNamesAKVMListsAHost() {
        func page(_ text: String) -> Data { Data(text.utf8) }
        #expect(DiscoveryProbe.pageLooksLikeKVM(status: 200, body: page("<title>GLKVM</title>")))
        #expect(DiscoveryProbe.pageLooksLikeKVM(status: 200, body: page("served by KVMD")))
        #expect(DiscoveryProbe.pageLooksLikeKVM(status: 302, body: page("Comet")))
        #expect(!DiscoveryProbe.pageLooksLikeKVM(status: 200, body: page("<title>Router login</title>")))
        #expect(!DiscoveryProbe.pageLooksLikeKVM(status: 404, body: page("glkvm")))
        #expect(!DiscoveryProbe.pageLooksLikeKVM(status: 500, body: page("kvm")))
    }

    @Test func onlyTheFirst4KBOfAPageAreRead() {
        let late = Data(String(repeating: "x", count: 4096).utf8) + Data("glkvm".utf8)
        #expect(!DiscoveryProbe.pageLooksLikeKVM(status: 200, body: late))
    }
}

/// The keys macOS 15 needs before it lets Scan browse Bonjour and reach the local network, read
/// from the running app's Info.plist (the test host is the app).
@Suite("Local network permission")
struct LocalNetworkPermissionTests {
    @Test func explainsTheLocalNetworkPrompt() {
        let description = Bundle.main.infoDictionary?["NSLocalNetworkUsageDescription"] as? String
        #expect(description == "Overlook finds and connects to KVM devices on your local network.")
    }

    @Test func listsEveryBonjourServiceScanBrowses() throws {
        let services = try #require(Bundle.main.infoDictionary?["NSBonjourServices"] as? [String])
        #expect(services == ["_comet._tcp", "_kvm._tcp"])
        #expect(Set(services) == Set(KVMDeviceManager.bonjourServiceTypes))
    }

    @Test func theGeneratedKeysAreStillThere() {
        let info = Bundle.main.infoDictionary ?? [:]
        #expect(info["CFBundleDisplayName"] as? String == "Overlook")
        #expect(info["NSMicrophoneUsageDescription"] as? String
            == "Overlook needs microphone access to send audio to the remote device.")
    }
}

/// One scan's results merged into one entry per host.
@Suite("Discovered devices merge")
struct DiscoveredMergeTests {
    static func swept(_ host: String, _ port: Int = 443, type: KVMDeviceType = .glinetComet) -> KVMDevice {
        Fixtures.device(id: "scanned-\(host)-\(port)", nickname: nil, host: host, port: port, type: type)
    }

    static func comet(_ name: String, at host: String, _ port: Int = 443) -> KVMDevice {
        KVMDeviceManager.createGLiNetDevice(
            from: .service(name: name, type: "_comet._tcp", domain: "local.", interface: nil),
            resolved: DeviceAddress(host: host, port: port)
        )
    }

    @Test func aBonjourHitAndASweepHitForOneAddressAreOneEntryWithTheBonjourName() throws {
        let merged = DiscoveredMerge.merge([Self.swept("192.168.0.131"), Self.comet("GLKVM-Desk", at: "192.168.0.131")])
        #expect(merged.count == 1)
        let device = try #require(merged.first)
        #expect(device.nickname == "GLKVM-Desk")
        #expect(device.address == DeviceAddress(host: "192.168.0.131", port: 443))
    }

    @Test func httpAndHttpsOnOneHostAreOneEntryOnHttps() throws {
        for found in [
            [Self.swept("192.168.0.114", 80), Self.swept("192.168.0.114", 443)],
            [Self.swept("192.168.0.114", 443), Self.swept("192.168.0.114", 80)],
        ] {
            let merged = DiscoveredMerge.merge(found)
            #expect(merged.count == 1)
            #expect(merged.first?.port == 443)
        }
    }

    @Test func aBonjourNameOnTheHttpResultIsKeptWhenHttpsWins() {
        let bonjourOn80 = Self.comet("Rack KVM", at: "192.168.0.114", 80)
        let merged = DiscoveredMerge.merge([bonjourOn80, Self.swept("192.168.0.114", 443)])
        #expect(merged.count == 1)
        #expect(merged.first?.port == 443)
        #expect(merged.first?.nickname == "Rack KVM")
    }

    @Test func twoHostsWithTheSameBonjourNameStayTwoEntries() {
        let merged = DiscoveredMerge.merge([Self.comet("GLKVM", at: "192.168.0.131"), Self.comet("GLKVM", at: "192.168.0.114")])
        #expect(merged.count == 2)
        #expect(Set(merged.map(\.host)) == ["192.168.0.131", "192.168.0.114"])
        #expect(merged.allSatisfy { $0.nickname == "GLKVM" })
    }

    @Test func differentHostsAreNeverMerged() {
        let merged = DiscoveredMerge.merge([Self.swept("192.168.0.13"), Self.swept("192.168.0.131"), Self.swept("192.168.0.1", 80)])
        #expect(merged.map(\.host) == ["192.168.0.13", "192.168.0.131", "192.168.0.1"])
    }

    @Test func hostsCompareWithoutCaseOrATrailingDot() {
        let merged = DiscoveredMerge.merge([Self.swept("GLKVM.local.", 80), Self.swept("glkvm.local", 443)])
        #expect(merged.count == 1)
        #expect(merged.first?.port == 443)
        #expect(DiscoveredMerge.hostKey(" Desk.Local. ") == "desk.local")
    }

    @Test func portsArePreferredHttpsFirstAnd80Last() {
        #expect(DiscoveredMerge.portRank(443) < DiscoveredMerge.portRank(8443))
        #expect(DiscoveredMerge.portRank(8443) < DiscoveredMerge.portRank(8080))
        #expect(DiscoveredMerge.portRank(8080) < DiscoveredMerge.portRank(80))
        let merged = DiscoveredMerge.merge([Self.swept("10.0.0.5", 80), Self.swept("10.0.0.5", 8080), Self.swept("10.0.0.5", 8443)])
        #expect(merged.map(\.port) == [8443])
    }

    @Test func aGLiNetResultBeatsAGenericOneOnTheSamePort() {
        let generic = Self.swept("192.168.0.131", 443, type: .generic)
        let glinet = Self.swept("192.168.0.131", 443, type: .glinetComet)
        #expect(DiscoveredMerge.merge([generic, glinet]).first?.type == .glinetComet)
    }

    @Test func cometAndKVMServicesOnOneHostAreOneEntry() {
        let kvm = KVMDeviceManager.createGenericKVMDevice(
            from: .service(name: "desk-kvm", type: "_kvm._tcp", domain: "local.", interface: nil),
            resolved: DeviceAddress(host: "192.168.0.131", port: 8080)
        )
        let merged = DiscoveredMerge.merge([kvm, Self.comet("desk-comet", at: "192.168.0.131"), Self.swept("192.168.0.131", 80)])
        #expect(merged.count == 1)
        #expect(merged.first?.port == 443)
        #expect(merged.first?.type == .glinetComet)
        #expect(merged.first?.nickname == "desk-comet")
    }

    @Test func hostsKeepTheOrderTheyWereFirstFoundIn() {
        let merged = DiscoveredMerge.merge([Self.swept("192.168.0.9"), Self.swept("192.168.0.2"), Self.swept("192.168.0.9", 80)])
        #expect(merged.map(\.host) == ["192.168.0.9", "192.168.0.2"])
    }

    // MARK: - Saved devices

    static let desk = Fixtures.device(
        id: "saved-desk",
        nickname: "Desk",
        host: "192.168.0.131",
        addresses: [DeviceAddress(host: "192.168.0.131", port: 443), DeviceAddress(host: "mdesktopkvm", port: 443)]
    )

    @Test func aResultAtASavedDevicesAddressIsShownAsThatDevice() {
        let found = [Self.swept("192.168.0.131"), Self.comet("GLKVM", at: "192.168.0.131"), Self.swept("192.168.0.114")]
        let merged = DiscoveredMerge.merge(found, shownAs: [Self.desk])
        #expect(merged.map(\.host) == ["192.168.0.114"])

        let listed = KVMDeviceManager.mergeListed([Self.desk] + merged)
        #expect(listed.map(\.id) == ["scanned-192.168.0.114-443", "saved-desk"])
        #expect(listed.filter { $0.host == "192.168.0.131" }.map(\.id) == ["saved-desk"])
    }

    @Test func anotherPortOnASavedDevicesHostIsShownAsThatDevice() {
        let merged = DiscoveredMerge.merge([Self.swept("192.168.0.131", 80)], shownAs: [Self.desk])
        #expect(merged.isEmpty)
        #expect(DiscoveredMerge.listedAs(Self.swept("192.168.0.131", 80), among: [Self.desk])?.id == "saved-desk")
    }

    @Test func aSavedDevicesOtherAddressesClaimTheirHostsToo() {
        let tailnetHit = Self.swept("MDESKTOPKVM.", 443)
        #expect(DiscoveredMerge.merge([tailnetHit], shownAs: [Self.desk]).isEmpty)
    }

    @Test func aResultWithNoHostIsDropped() {
        #expect(DiscoveredMerge.merge([Self.swept("")]).isEmpty)
    }

    // MARK: - Bonjour results

    @Test func aResolvedBonjourServiceIsAtItsAddressUnderItsName() {
        let device = Self.comet("GLKVM-Desk", at: "192.168.0.131", 443)
        #expect(device.host == "192.168.0.131")
        #expect(device.port == 443)
        #expect(device.nickname == "GLKVM-Desk")
        #expect(device.id == "glinet-192.168.0.131-443")
        #expect(device.type == .glinetComet)
    }

    @Test func anUnresolvedBonjourServiceKeepsItsServiceNameAndDefaultPort() {
        let endpoint = NWEndpoint.service(name: "GLKVM", type: "_comet._tcp", domain: "local.", interface: nil)
        let comet = KVMDeviceManager.createGLiNetDevice(from: endpoint)
        #expect(comet.host == "GLKVM._comet._tcp.local.")
        #expect(comet.port == 443)
        #expect(comet.nickname == "GLKVM")
        let kvm = KVMDeviceManager.createGenericKVMDevice(
            from: .service(name: "box", type: "_kvm._tcp", domain: "local.", interface: nil)
        )
        #expect(kvm.port == 8080)
        #expect(kvm.type == .generic)
    }

    @Test func aResolvedEndpointsAddressIsReadOff() throws {
        let ipv4 = try #require(IPv4Address("192.168.0.131"))
        #expect(KVMDeviceManager.address(of: .hostPort(host: .ipv4(ipv4), port: 443))
            == DeviceAddress(host: "192.168.0.131", port: 443))
        #expect(KVMDeviceManager.address(of: .hostPort(host: "glkvm.local", port: 8443))
            == DeviceAddress(host: "glkvm.local", port: 8443))
        let ipv6 = try #require(IPv6Address("fd00::5"))
        #expect(KVMDeviceManager.address(of: .hostPort(host: .ipv6(ipv6), port: 443)) == nil)
        #expect(KVMDeviceManager.address(of: .service(name: "x", type: "_comet._tcp", domain: "local.", interface: nil)) == nil)
        #expect(KVMDeviceManager.address(of: nil) == nil)
    }
}
