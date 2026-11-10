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

    // MARK: - API answers

    @Test func kvmdsUnauthorizedAnswerListsAHost() {
        #expect(DiscoveryProbe.isKVMDAnswer(status: 401, body: ProbeFixtures.glkvmAuthCheck401))
    }

    @Test func kvmdsIsInitedAnswerListsAHost() {
        #expect(DiscoveryProbe.isKVMDAnswer(status: 200, body: ProbeFixtures.glkvmIsInited200))
    }

    @Test func kvmdsAnswerWithAuthenticationOffListsAHost() {
        // kvmd with auth disabled answers /auth/check with an empty success envelope.
        #expect(DiscoveryProbe.isKVMDAnswer(status: 200, body: Data(#"{"ok": true, "result": {}}"#.utf8)))
        #expect(DiscoveryProbe.isKVMDAnswer(status: 403, body: Data(#"{"ok": false, "result": {"error": "ForbiddenError", "error_msg": "Forbidden"}}"#.utf8)))
    }

    @Test func aUniFiJSONRefusalDoesNotListAHost() {
        #expect(!DiscoveryProbe.isKVMDAnswer(status: 401, body: ProbeFixtures.unifiAPI401))
    }

    @Test func aRouterRedirectToItsLoginPageDoesNotListAHost() {
        #expect(!DiscoveryProbe.isKVMDAnswer(status: 302, body: ProbeFixtures.router302ToLogin))
        #expect(!DiscoveryProbe.isKVMDAnswer(status: 302, body: Data()))
        for status in [301, 307, 308] {
            #expect(!DiscoveryProbe.isKVMDAnswer(status: status, body: Data()), "\(status)")
        }
    }

    @Test func aBare401Or403DoesNotListAHost() {
        #expect(!DiscoveryProbe.isKVMDAnswer(status: 401, body: Data()))
        #expect(!DiscoveryProbe.isKVMDAnswer(status: 403, body: Data()))
        #expect(!DiscoveryProbe.isKVMDAnswer(status: 401, body: ProbeFixtures.router401HTML))
    }

    @Test func aPageThatMentionsKVMDoesNotListAHostThroughTheAPI() {
        #expect(!DiscoveryProbe.isKVMDAnswer(status: 200, body: ProbeFixtures.genericPageMentioningKVM))
    }

    @Test func aNonJSONSuccessDoesNotListAHost() {
        #expect(!DiscoveryProbe.isKVMDAnswer(status: 200, body: ProbeFixtures.synologyRedirectPage200))
        #expect(!DiscoveryProbe.isKVMDAnswer(status: 200, body: ProbeFixtures.unifiPage200))
        #expect(!DiscoveryProbe.isKVMDAnswer(status: 400, body: ProbeFixtures.nginxPlainHTTPToHTTPSPort400))
        #expect(!DiscoveryProbe.isKVMDAnswer(status: 200, body: Data("OK".utf8)))
    }

    @Test func aJSONSuccessWithoutKVMDsEnvelopeDoesNotListAHost() {
        for json in [
            #"{"result": {}}"#,
            #"{"status": "ok", "data": {"is_inited": true}}"#,
            #"{"ok": true}"#,
            #"{"ok": "true", "result": {}}"#,
            #"{"ok": null, "result": {}}"#,
            #"{"ok": true, "result": "fine"}"#,
            #"{"ok": true, "result": [1, 2]}"#,
            #"[{"ok": true, "result": {}}]"#,
            #"true"#,
        ] {
            #expect(!DiscoveryProbe.isKVMDAnswer(status: 200, body: Data(json.utf8)), "\(json)")
        }
    }

    @Test func anEnvelopeWhoseOkDisagreesWithTheStatusDoesNotListAHost() {
        // kvmd sets ok to (status == 200), always.
        #expect(!DiscoveryProbe.isKVMDAnswer(status: 401, body: Data(#"{"ok": true, "result": {}}"#.utf8)))
        #expect(!DiscoveryProbe.isKVMDAnswer(status: 200, body: Data(#"{"ok": false, "result": {}}"#.utf8)))
        #expect(!DiscoveryProbe.isKVMDAnswer(status: 404, body: ProbeFixtures.glkvmIsInited200))
    }

    // MARK: - Web pages

    @Test func glkvmsWebPageListsAHost() {
        #expect(DiscoveryProbe.pageTitle(ProbeFixtures.glkvmPage200) == "GLKVM")
        #expect(DiscoveryProbe.isGLKVMPage(status: 200, body: ProbeFixtures.glkvmPage200))
        #expect(DiscoveryProbe.isGLKVMPage(status: 200, body: Data("<TITLE lang=en> glkvm\n</TITLE>".utf8)))
    }

    @Test func otherPagesDoNotListAHost() {
        #expect(!DiscoveryProbe.isGLKVMPage(status: 200, body: ProbeFixtures.unifiPage200))
        #expect(!DiscoveryProbe.isGLKVMPage(status: 200, body: ProbeFixtures.synologyRedirectPage200))
        #expect(!DiscoveryProbe.isGLKVMPage(status: 200, body: ProbeFixtures.genericPageMentioningKVM))
        #expect(!DiscoveryProbe.isGLKVMPage(status: 401, body: ProbeFixtures.router401HTML))
        #expect(!DiscoveryProbe.isGLKVMPage(status: 200, body: Data("<title>GLKVM Manager for routers</title>".utf8)))
        #expect(!DiscoveryProbe.isGLKVMPage(status: 200, body: Data("<p>GLKVM</p>".utf8)))
    }

    @Test func glkvmsPageOnlyCountsAsA200() {
        for status in [302, 401, 403, 404, 500] {
            #expect(!DiscoveryProbe.isGLKVMPage(status: status, body: ProbeFixtures.glkvmPage200), "\(status)")
        }
    }

    @Test func onlyThePagesFirst8KBAreSearchedForItsTitle() {
        let late = Data(String(repeating: " ", count: DiscoveryProbe.pageBytesRead).utf8) + Data("<title>GLKVM</title>".utf8)
        #expect(!DiscoveryProbe.isGLKVMPage(status: 200, body: late))
        #expect(DiscoveryProbe.pageTitle(Data("<title>unterminated".utf8)) == nil)
    }

    // MARK: - Redirects

    @Test func redirectsAreFollowedOnlyOnTheSameHost() {
        let http = URL(string: "http://192.168.0.131:80/api/auth/check")
        #expect(DiscoveryProbe.followsRedirect(from: http, to: URL(string: "https://192.168.0.131/api/auth/check")))
        #expect(DiscoveryProbe.followsRedirect(from: URL(string: "http://GLKVM.local/"), to: URL(string: "https://glkvm.local./login")))
        #expect(!DiscoveryProbe.followsRedirect(from: http, to: URL(string: "https://192.168.0.1/login")))
        #expect(!DiscoveryProbe.followsRedirect(from: http, to: URL(string: "https://unifi.ui.com/")))
        #expect(!DiscoveryProbe.followsRedirect(from: http, to: URL(string: "/login")))
        #expect(!DiscoveryProbe.followsRedirect(from: nil, to: http))
    }
}

/// Answers captured from Michael's network during a scan on 2026-11-09 (status, content type and
/// the first 200 bytes of each body were logged), plus made-up answers in the shapes other routers
/// give. The GLKVMs at .131 and .114 answered identically.
enum ProbeFixtures {
    /// GLKVM (.131, .114): `GET /api/auth/check` without a token, 401, `application/json`.
    static let glkvmAuthCheck401 = Data("""
    {
        "ok": false,
        "result": {
            "error": "UnauthorizedError",
            "error_msg": "Unauthorized"
        }
    }
    """.utf8)

    /// GLKVM (.131, .114): `GET /api/init/is_inited`, 200, `application/json`.
    static let glkvmIsInited200 = Data("""
    {
        "ok": true,
        "result": {
            "country_code": "",
            "has_screen": true,
            "is_inited": true
        }
    }
    """.utf8)

    /// GLKVM (.131, .114): `GET /`, 200, `text/html`. The captured start of the page, then the
    /// title as logged from further in.
    static let glkvmPage200 = Data("""
    <!doctype html>\r\n<html lang="en">\r\n    <head>\r\n        <meta charset="UTF-8" />\r\n        \
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />\r\n        \
    <link rel="icon" href="./assets/favico-BZEItO8Z.ico" />\r\n        <title>GLKVM</title>\r\n
    """.utf8)

    /// The router at .1 (UniFi OS, nginx): both API paths, 401, `application/json`.
    static let unifiAPI401 = Data(#"{"error":{"code":401,"message":"Unauthorized"}}"#.utf8)

    /// The router at .1: `GET /`, 200. The captured start of the page, then its title.
    static let unifiPage200 = Data("""
    <!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="robots" content="noindex">\
    <link rel="icon" href="/favicon.ico?v3" sizes="any"><title>UniFi OS</title></head><body></body></html>
    """.utf8)

    /// .250 (nginx, most likely a Synology NAS: the page hands off to DSM's ports 5000/5001):
    /// every path probed, 200, `text/html`. As captured (the first 200 bytes).
    static let synologyRedirectPage200 = Data("""
    <!DOCTYPE html>
    <html>
        <body>
            <input type="hidden" id="http" name="http" value="5000">
            <input type="hidden" id="https" name="https" value="5001">
            <input type="hidden" id="p
    """.utf8)

    /// nginx on an https port asked over plain http (seen on .1, .114, .131 and .250), 400.
    static let nginxPlainHTTPToHTTPSPort400 = Data("""
    <html>\r\n<head><title>400 The plain HTTP request was sent to HTTPS port</title></head>\r\n<body>\r\n\
    <center><h1>400 Bad Request</h1></center>\r\n<center>The plain HTTP request was sent to HTTPS port</center>
    """.utf8)

    /// Made up: a router sending every unknown path to its login page.
    static let router302ToLogin = Data("""
    <html><head><title>302 Found</title></head><body><center><h1>302 Found</h1></center></body></html>
    """.utf8)

    /// Made up: a router refusing the API paths with an HTML page.
    static let router401HTML = Data("""
    <html><head><title>401 Authorization Required</title></head>\
    <body><h1>401 Authorization Required</h1><p>Log in to manage your router.</p></body></html>
    """.utf8)

    /// Made up: a page that mentions KVM and kvmd without being one.
    static let genericPageMentioningKVM = Data("""
    <html><head><title>KVM switch inventory</title></head>\
    <body>Rack 2: 8-port KVM, kvmd not installed, GLKVM on order.</body></html>
    """.utf8)
}

/// The HTTP half of a probe, against stubbed hosts: nothing reaches the network.
@Suite("Discovery HTTP probe")
struct DiscoveryHTTPProbeTests {
    static func probe() -> DiscoveryHTTPProbe {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return DiscoveryHTTPProbe(session: URLSession(configuration: configuration))
    }

    static func answer(_ status: Int, _ body: Data) -> StubDevice.Response {
        StubDevice.Response(status: status, body: body)
    }

    @Test func aGLKVMIsFoundOnItsFirstAPIAnswer() async throws {
        let glkvm = StubDevice { request in
            switch request.path {
            case "/api/auth/check": return Self.answer(401, ProbeFixtures.glkvmAuthCheck401)
            case "/api/init/is_inited": return Self.answer(200, ProbeFixtures.glkvmIsInited200)
            default: return Self.answer(200, ProbeFixtures.glkvmPage200)
            }
        }
        let device = try #require(await Self.probe().identify(host: glkvm.host, port: 443))
        #expect(device.id == "scanned-\(glkvm.host)-443")
        #expect(device.address == DeviceAddress(host: glkvm.host, port: 443))
        #expect(device.type == .glinetComet)
        #expect(glkvm.requests.map(\.path) == ["/api/auth/check"])
        #expect(glkvm.requests.allSatisfy { $0.method == "GET" && $0.body.isEmpty })
    }

    @Test func aGLKVMIsFoundByIsInitedAlone() async {
        let glkvm = StubDevice { request in
            request.path == "/api/init/is_inited"
                ? Self.answer(200, ProbeFixtures.glkvmIsInited200)
                : Self.answer(404, Data())
        }
        #expect(await Self.probe().identify(host: glkvm.host, port: 80) != nil)
        #expect(glkvm.requests.map(\.path) == ["/api/auth/check", "/api/init/is_inited"])
    }

    @Test func aGLKVMWhoseAPIIsUnreachableIsFoundByItsPage() async {
        let glkvm = StubDevice { request in
            request.path == "/" ? Self.answer(200, ProbeFixtures.glkvmPage200) : Self.answer(404, Data())
        }
        #expect(await Self.probe().identify(host: glkvm.host, port: 443)?.type == .glinetComet)
    }

    @Test func theUniFiRouterIsNotListed() async {
        let router = StubDevice { request in
            request.path == "/" ? Self.answer(200, ProbeFixtures.unifiPage200) : Self.answer(401, ProbeFixtures.unifiAPI401)
        }
        #expect(await Self.probe().identify(host: router.host, port: 443) == nil)
        // Both API paths and the page, on both schemes.
        #expect(router.requests.map(\.path) == [
            "/api/auth/check", "/api/init/is_inited", "/api/auth/check", "/api/init/is_inited", "/", "/",
        ])
    }

    @Test func aHostAnsweringEveryPathWithAPageIsNotListed() async {
        let nas = StubDevice { _ in Self.answer(200, ProbeFixtures.synologyRedirectPage200) }
        #expect(await Self.probe().identify(host: nas.host, port: 80) == nil)
    }

    @Test func redirectsAndBareRefusalsAreNotListed() async {
        for response in [
            Self.answer(302, ProbeFixtures.router302ToLogin),
            Self.answer(401, ProbeFixtures.router401HTML),
            Self.answer(403, Data()),
            Self.answer(200, ProbeFixtures.genericPageMentioningKVM),
        ] {
            let host = StubDevice { _ in response }
            #expect(await Self.probe().identify(host: host.host, port: 8080) == nil, "\(response.status)")
        }
    }

    @Test func aHostThatDoesNotAnswerIsNotListed() async {
        // No stub registered for the host: every request fails.
        #expect(await Self.probe().identify(host: "nobody-\(UUID().uuidString.lowercased()).invalid", port: 443) == nil)
    }
}

/// The sweep's two stages, with a made-up connector and prober: nothing touches the network.
@Suite("Discovery sweep stages")
struct DiscoverySweepStageTests {
    typealias Target = DiscoverySweep.Target

    /// Counts calls and the most that were running at once.
    final class Tally: @unchecked Sendable {
        private let lock = NSLock()
        private var running = 0
        private(set) var started = 0
        private(set) var mostAtOnce = 0
        private var seen: [Target] = []

        var targets: [Target] { lock.withLock { seen } }
        var startedCount: Int { lock.withLock { started } }
        var peak: Int { lock.withLock { mostAtOnce } }

        @discardableResult
        func begin(_ target: Target) -> Int {
            lock.withLock {
                started += 1
                running += 1
                mostAtOnce = max(mostAtOnce, running)
                seen.append(target)
                return started
            }
        }

        func end() {
            lock.withLock { running -= 1 }
        }
    }

    /// Holds callers until opened.
    actor Gate {
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private var isOpen = false

        func pass() async {
            guard !isOpen else { return }
            await withCheckedContinuation { waiting.append($0) }
        }

        func open() {
            isOpen = true
            waiting.forEach { $0.resume() }
            waiting.removeAll()
        }
    }

    static let hosts = (1...30).map { "192.168.0.\($0)" }
    static let ports = KVMDeviceManager.sweptPorts

    static func device(_ target: Target) -> KVMDevice {
        Fixtures.device(id: "scanned-\(target.host)-\(target.port)", nickname: nil, host: target.host, port: target.port)
    }

    @Test func targetsGoHostByHostInPortOrder() {
        let targets = DiscoverySweep.targets(hosts: ["192.168.0.1", "192.168.0.2"], ports: [443, 8443, 80, 8080])
        #expect(targets.map { "\($0.host):\($0.port)" } == [
            "192.168.0.1:443", "192.168.0.1:8443", "192.168.0.1:80", "192.168.0.1:8080",
            "192.168.0.2:443", "192.168.0.2:8443", "192.168.0.2:80", "192.168.0.2:8080",
        ])
        #expect(KVMDeviceManager.sweptPorts == [443, 8443, 80, 8080])
    }

    @Test func theSweepsLimits() {
        #expect(DiscoverySweep.connectTimeout == 0.5)
        #expect(DiscoverySweep.connectLimit == 48)
        #expect(DiscoverySweep.probeLimit == 16)
    }

    @Test func onlyPortsThatAcceptedAConnectionAreProbed() async {
        let targets = DiscoverySweep.targets(hosts: Self.hosts, ports: Self.ports)
        let open: Set<Target> = [
            Target(host: "192.168.0.1", port: 443), Target(host: "192.168.0.1", port: 80),
            Target(host: "192.168.0.14", port: 8080), Target(host: "192.168.0.27", port: 443),
        ]
        let glkvm = Target(host: "192.168.0.27", port: 443)
        let connects = Tally()
        let probes = Tally()
        let outcome = await DiscoverySweep.run(
            targets: targets,
            connect: { target in
                connects.begin(target)
                defer { connects.end() }
                return open.contains(target) ? .open : .closed
            },
            probe: { target in
                probes.begin(target)
                defer { probes.end() }
                return target == glkvm ? Self.device(target) : nil
            }
        )
        #expect(connects.startedCount == targets.count)
        #expect(Set(connects.targets) == Set(targets))
        #expect(Set(probes.targets) == open)
        #expect(probes.startedCount == open.count)
        #expect(outcome.openTargets == targets.filter(open.contains))
        #expect(outcome.hostsAnswering == 3)
        #expect(outcome.found.map(\.id) == ["scanned-192.168.0.27-443"])
    }

    @Test(.timeLimit(.minutes(1)))
    func aPortIsProbedWhileOtherConnectsAreStillRunning() async {
        // The first host's port opens at once; every other connect waits until that probe has
        // run, which it could not if probing waited for the whole connect stage.
        let targets = DiscoverySweep.targets(hosts: Self.hosts, ports: [443])
        let first = Target(host: "192.168.0.1", port: 443)
        let probed = Gate()
        let outcome = await DiscoverySweep.run(
            targets: targets,
            connectLimit: 4,
            connect: { target in
                guard target != first else { return .open }
                await probed.pass()
                return .closed
            },
            probe: { target in
                await probed.open()
                return Self.device(target)
            }
        )
        #expect(outcome.found.map(\.host) == ["192.168.0.1"])
    }

    @Test func noPortOpenMeansNoProbe() async {
        let probes = Tally()
        let outcome = await DiscoverySweep.run(
            targets: DiscoverySweep.targets(hosts: Self.hosts, ports: Self.ports),
            connect: { _ in .closed },
            probe: { target in
                probes.begin(target)
                return nil
            }
        )
        #expect(probes.startedCount == 0)
        #expect(outcome.openTargets.isEmpty)
        #expect(outcome.found.isEmpty)
        #expect(outcome.hostsAnswering == 0)
    }

    @Test func unsureTargetsAreTriedOnceMoreAfterTheOthers() async {
        let targets = DiscoverySweep.targets(hosts: Self.hosts, ports: Self.ports)
        let router = Target(host: "192.168.0.1", port: 443)
        let glkvm = Target(host: "192.168.0.2", port: 443)
        let stuck = Target(host: "192.168.0.3", port: 443)
        let connects = Tally()
        let outcome = await DiscoverySweep.run(
            targets: targets,
            connect: { target in
                connects.begin(target)
                defer { connects.end() }
                let tries = connects.targets.filter { $0 == target }.count
                switch target {
                case router, glkvm: return tries == 1 ? .unsure : .open
                case stuck: return .unsure
                default: return .closed
                }
            },
            probe: { target in target == glkvm ? Self.device(target) : nil }
        )
        #expect(connects.startedCount == targets.count + 3)
        // The second tries come after every first try.
        #expect(Set(connects.targets.suffix(3)) == [router, glkvm, stuck])
        #expect(outcome.retried == 3)
        #expect(outcome.openTargets == [router, glkvm])
        #expect(outcome.found.map(\.host) == ["192.168.0.2"])
    }

    @Test func aSweepWithNothingUnsureTriesNothingTwice() async {
        let targets = DiscoverySweep.targets(hosts: Self.hosts, ports: Self.ports)
        let connects = Tally()
        let outcome = await DiscoverySweep.run(
            targets: targets,
            connect: { target in
                connects.begin(target)
                return .closed
            },
            probe: { _ in nil }
        )
        #expect(connects.startedCount == targets.count)
        #expect(outcome.retried == 0)
    }

    @Test func onlyARefusalOrAKnownDownHostClosesAPortAtOnce() {
        #expect(DiscoverySweep.isAnswer(.ECONNREFUSED))
        #expect(DiscoverySweep.isAnswer(.EHOSTDOWN))
        // Seen for every connect in the first second of an app's first scan, router included.
        #expect(!DiscoverySweep.isAnswer(.ENETDOWN))
        #expect(!DiscoverySweep.isAnswer(.ENETUNREACH))
        #expect(!DiscoverySweep.isAnswer(.EHOSTUNREACH))
        #expect(!DiscoverySweep.isAnswer(.ETIMEDOUT))
    }

    @Test func connectsNeverExceedTheirLimit() async {
        let targets = DiscoverySweep.targets(hosts: Self.hosts, ports: Self.ports)
        let connects = Tally()
        _ = await DiscoverySweep.run(
            targets: targets,
            connectLimit: 6,
            connect: { target in
                connects.begin(target)
                try? await Task.sleep(for: .milliseconds(5))
                connects.end()
                return .closed
            },
            probe: { _ in nil }
        )
        #expect(connects.startedCount == targets.count)
        #expect(connects.peak == 6)
    }

    @Test func probesNeverExceedTheirLimit() async {
        let targets = DiscoverySweep.targets(hosts: Self.hosts, ports: [443])
        let probes = Tally()
        let outcome = await DiscoverySweep.run(
            targets: targets,
            probeLimit: 3,
            connect: { _ in .open },
            probe: { target in
                probes.begin(target)
                try? await Task.sleep(for: .milliseconds(5))
                probes.end()
                return Self.device(target)
            }
        )
        #expect(probes.startedCount == targets.count)
        #expect(probes.peak == 3)
        // Results keep target order whatever order the probes finished in.
        #expect(outcome.found.map(\.host) == Self.hosts)
    }

    @Test func cancellingTheScanStopsNewConnectsAndProbes() async {
        let targets = DiscoverySweep.targets(hosts: Self.hosts, ports: Self.ports)
        let gate = Gate()
        let connects = Tally()
        let probes = Tally()
        let (saturated, signal) = AsyncStream<Void>.makeStream()
        // Connects 1-7 find the port closed at once; 8-11 wait at the gate, filling all 4 slots,
        // and then find it open, after the scan was cancelled.
        let sweep = Task {
            await DiscoverySweep.run(
                targets: targets,
                connectLimit: 4,
                connect: { target in
                    let number = connects.begin(target)
                    defer { connects.end() }
                    guard number >= 8 else { return .closed }
                    if number == 11 {
                        signal.yield()
                    }
                    await gate.pass()
                    return .open
                },
                probe: { target in
                    probes.begin(target)
                    return nil
                }
            )
        }
        for await _ in saturated {
            break
        }
        sweep.cancel()
        await gate.open()
        let outcome = await sweep.value
        #expect(connects.startedCount == 11)
        #expect(probes.startedCount == 0)
        #expect(outcome.openTargets.count == 4)
        #expect(outcome.found.isEmpty)
    }

    @Test func cancellingDuringProbesStopsNewProbes() async {
        let targets = DiscoverySweep.targets(hosts: Self.hosts, ports: [443])
        let gate = Gate()
        let probes = Tally()
        let (saturated, signal) = AsyncStream<Void>.makeStream()
        let sweep = Task {
            await DiscoverySweep.run(
                targets: targets,
                probeLimit: 2,
                connect: { _ in .open },
                probe: { target in
                    let number = probes.begin(target)
                    defer { probes.end() }
                    if number == 2 {
                        signal.yield()
                    }
                    await gate.pass()
                    return Self.device(target)
                }
            )
        }
        for await _ in saturated {
            break
        }
        sweep.cancel()
        await gate.open()
        let outcome = await sweep.value
        #expect(probes.startedCount == 2)
        #expect(outcome.found.count == 2)
        #expect(Set(outcome.found.map(\.host)) == Set(probes.targets.map(\.host)))
    }
}

/// Saved and added devices stay listed through a scan whatever it finds or fails to reach.
@Suite("Scan listing")
struct ScanListingTests {
    static let linux = Fixtures.device(id: "saved-linux", nickname: "Linux KVM", host: "192.168.0.131")
    static let surface = Fixtures.device(id: "saved-surface", nickname: "Surface KVM", host: "192.168.0.114")
    static let added = Fixtures.device(id: "manual-x", nickname: nil, host: "10.0.0.9")

    @Test func savedDevicesAreListedWhenTheScanFindsNothing() {
        let listed = KVMDeviceManager.scanListing(pinned: [Self.linux, Self.surface, Self.added], found: [])
        #expect(Set(listed.map(\.id)) == ["saved-linux", "saved-surface", "manual-x"])
    }

    @Test func aSavedDeviceFoundByTheScanIsListedOnce() {
        let found = [
            Fixtures.device(id: "scanned-192.168.0.131-443", nickname: nil, host: "192.168.0.131"),
            Fixtures.device(id: "scanned-192.168.0.131-80", nickname: nil, host: "192.168.0.131", port: 80),
            Fixtures.device(id: "scanned-192.168.0.77-443", nickname: nil, host: "192.168.0.77"),
        ]
        let listed = KVMDeviceManager.scanListing(pinned: [Self.linux, Self.surface], found: found)
        #expect(listed.filter { $0.host == "192.168.0.131" }.map(\.id) == ["saved-linux"])
        #expect(Set(listed.map(\.id)) == ["saved-linux", "saved-surface", "scanned-192.168.0.77-443"])
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

/// Bonjour results go through the same kvmd check as swept hosts before they are listed, against
/// stubbed hosts: nothing reaches the network.
@Suite("Bonjour results check")
struct BonjourCheckTests {
    static func service(_ name: String, type: String = "_comet._tcp") -> NWEndpoint {
        .service(name: name, type: type, domain: "local.", interface: nil)
    }

    static func makeComet(_ endpoint: NWEndpoint, _ address: DeviceAddress) -> KVMDevice {
        KVMDeviceManager.createGLiNetDevice(from: endpoint, resolved: address)
    }

    /// The real HTTP probe on a session whose requests the stubs answer.
    static func isGLKVM(_ address: DeviceAddress) async -> Bool {
        await DiscoveryHTTPProbeTests.probe().isGLKVM(host: address.host, port: address.port)
    }

    static func glkvm() -> StubDevice {
        StubDevice { request in
            switch request.path {
            case "/api/auth/check": return StubDevice.Response(status: 401, body: ProbeFixtures.glkvmAuthCheck401)
            case "/api/init/is_inited": return StubDevice.Response(status: 200, body: ProbeFixtures.glkvmIsInited200)
            default: return StubDevice.Response(status: 200, body: ProbeFixtures.glkvmPage200)
            }
        }
    }

    @Test func aServiceThatAnswersAsKVMDIsListedUnderItsName() async throws {
        let desk = Self.glkvm()
        let checked = await KVMDeviceManager.checkBonjourServices(
            [(Self.service("GLKVM-Desk"), DeviceAddress(host: desk.host, port: 443))],
            makeDevice: Self.makeComet,
            isGLKVM: { await Self.isGLKVM($0) }
        )
        let device = try #require(checked.listed.first)
        #expect(checked.listed.count == 1)
        #expect(device.nickname == "GLKVM-Desk")
        #expect(device.address == DeviceAddress(host: desk.host, port: 443))
        #expect(checked.refused.isEmpty && checked.unresolved.isEmpty)
        #expect(desk.requests.map(\.path) == ["/api/auth/check"])
    }

    @Test func aServiceServingGLKVMsPageIsListed() async {
        let page = StubDevice { request in
            request.path == "/"
                ? StubDevice.Response(status: 200, body: ProbeFixtures.glkvmPage200)
                : StubDevice.Response(status: 404, body: Data())
        }
        let checked = await KVMDeviceManager.checkBonjourServices(
            [(Self.service("Rack"), DeviceAddress(host: page.host, port: 443))],
            makeDevice: Self.makeComet,
            isGLKVM: { await Self.isGLKVM($0) }
        )
        #expect(checked.listed.map(\.host) == [page.host])
    }

    @Test func aServiceThatFailsTheCheckIsNotListed() async {
        let router = StubDevice { request in
            request.path == "/"
                ? StubDevice.Response(status: 200, body: ProbeFixtures.unifiPage200)
                : StubDevice.Response(status: 401, body: ProbeFixtures.unifiAPI401)
        }
        let checked = await KVMDeviceManager.checkBonjourServices(
            [(Self.service("not-a-kvm", type: "_kvm._tcp"), DeviceAddress(host: router.host, port: 8080))],
            makeDevice: Self.makeComet,
            isGLKVM: { await Self.isGLKVM($0) }
        )
        #expect(checked.listed.isEmpty)
        #expect(checked.refused.map(\.nickname) == ["not-a-kvm"])
        #expect(!router.requests.isEmpty)
    }

    @Test func aServiceThatDoesNotAnswerIsNotListed() async {
        let nobody = DeviceAddress(host: "nobody-\(UUID().uuidString.lowercased()).invalid", port: 443)
        let checked = await KVMDeviceManager.checkBonjourServices(
            [(Self.service("Gone"), nobody)],
            makeDevice: Self.makeComet,
            isGLKVM: { await Self.isGLKVM($0) }
        )
        #expect(checked.listed.isEmpty)
        #expect(checked.refused.count == 1)
    }

    @Test func aServiceThatDoesNotResolveIsNotCheckedOrListed() async {
        let asked = AskedAddresses()
        let checked = await KVMDeviceManager.checkBonjourServices(
            [(Self.service("Unresolved"), nil)],
            makeDevice: Self.makeComet,
            isGLKVM: { address in
                asked.add(address)
                return true
            }
        )
        #expect(checked.listed.isEmpty)
        #expect(checked.unresolved == ["Unresolved"])
        #expect(asked.all.isEmpty)
    }

    @Test func listedServicesKeepTheOrderTheyWereGiven() async {
        let first = Self.glkvm()
        let second = Self.glkvm()
        let router = StubDevice { _ in StubDevice.Response(status: 403, body: Data()) }
        let checked = await KVMDeviceManager.checkBonjourServices(
            [
                (Self.service("B"), DeviceAddress(host: second.host, port: 443)),
                (Self.service("X"), DeviceAddress(host: router.host, port: 443)),
                (Self.service("Y"), nil),
                (Self.service("A"), DeviceAddress(host: first.host, port: 443)),
            ],
            makeDevice: Self.makeComet,
            isGLKVM: { await Self.isGLKVM($0) }
        )
        #expect(checked.listed.map(\.nickname) == ["B", "A"])
        #expect(checked.refused.map(\.nickname) == ["X"])
        #expect(checked.unresolved == ["Y"])
    }

    @Test func aSavedDeviceStaysListedWhenItsBonjourServiceFailsTheCheck() async {
        let saved = Fixtures.device(id: "saved-linux", nickname: "Linux KVM", host: "192.168.0.131")
        let checked = await KVMDeviceManager.checkBonjourServices(
            [(Self.service("GLKVM"), DeviceAddress(host: "192.168.0.131", port: 443))],
            makeDevice: Self.makeComet,
            isGLKVM: { _ in false }
        )
        let listed = KVMDeviceManager.scanListing(pinned: [saved], found: checked.listed)
        #expect(listed.map(\.id) == ["saved-linux"])
    }

    final class AskedAddresses: @unchecked Sendable {
        private let lock = NSLock()
        private var addresses: [DeviceAddress] = []
        func add(_ address: DeviceAddress) { lock.withLock { addresses.append(address) } }
        var all: [DeviceAddress] { lock.withLock { addresses } }
    }
}

/// Stands in for the network under a scan: each source answers as the test says, and a source
/// told to hang waits until the scan is cancelled, noting that it was.
final class FakeScanDiscovery: ScanDiscovery, @unchecked Sendable {
    typealias Source = @Sendable () async -> [KVMDevice]

    private let lock = NSLock()
    private var sources: [String: Source] = [:]
    private var _cancelled: [String] = []
    private var _sweptHosts: [[String]] = []
    private var _entered: [String] = []
    let interfaceList: [IPv4Interface]

    init(interfaces: [IPv4Interface]) {
        interfaceList = interfaces
    }

    /// What the source named `name` ("_comet._tcp", "_kvm._tcp", "sweep", "tailnet") returns;
    /// nothing until set.
    func answer(_ name: String, with source: @escaping Source) {
        lock.withLock { sources[name] = source }
    }

    /// The source waits for the scan to be cancelled, notes it, and then returns `late`, which
    /// must never reach the list.
    func hang(_ name: String, thenReturn late: [KVMDevice] = []) {
        answer(name) { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            if Task.isCancelled {
                self?.lock.withLock { self?._cancelled.append(name) }
            }
            return late
        }
    }

    var cancelled: [String] { lock.withLock { _cancelled } }
    var sweptHosts: [[String]] { lock.withLock { _sweptHosts } }
    /// The sources a scan has called, in the order it called them.
    var entered: [String] { lock.withLock { _entered } }

    private func run(_ name: String) async -> [KVMDevice] {
        let source = lock.withLock {
            _entered.append(name)
            return sources[name]
        }
        return await source?() ?? []
    }

    func interfaces() -> [IPv4Interface] { interfaceList }
    func bonjour(type: String) async -> [KVMDevice] { await run(type) }
    func sweep(hosts: [String]) async -> [KVMDevice] {
        lock.withLock { _sweptHosts.append(hosts) }
        return await run("sweep")
    }
    func tailnet() async -> [KVMDevice] { await run("tailnet") }
}

/// The Connections panel's Scan / Cancel scan button and its caption.
@Suite("Scan row")
struct ScanRowStateTests {
    @Test func idleShowsScanAndNoCaption() {
        let row = ScanRowState(isScanning: false, ranges: [])
        #expect(row.buttonTitle == "Scan")
        #expect(row.isButtonEnabled)
        #expect(row.caption == nil)
        // Ranges left over from anywhere never show while idle.
        #expect(ScanRowState(isScanning: false, ranges: ["192.168.0.0/24"]).caption == nil)
    }

    @Test func scanningShowsCancelScanAndTheSweptRange() {
        let row = ScanRowState(isScanning: true, ranges: ["192.168.0.0/24"])
        #expect(row.buttonTitle == "Cancel scan")
        #expect(row.isButtonEnabled)
        #expect(row.caption == "Scanning 192.168.0.0/24…")
    }

    @Test func everySweptRangeIsNamed() {
        let row = ScanRowState(isScanning: true, ranges: ["192.168.0.0/24", "10.0.5.0/24"])
        #expect(row.caption == "Scanning 192.168.0.0/24, 10.0.5.0/24…")
    }

    @Test func withNoNetworkToSweepTheCaptionSaysBonjourOnly() {
        #expect(ScanRowState(isScanning: true, ranges: []).caption == "Scanning Bonjour services only…")
    }

    @Test func theButtonIsSizedForTheWiderLabel() {
        // The view lays out both labels at once; the wider must be the one shown while scanning.
        #expect(ScanRowState.cancelTitle.count > ScanRowState.scanTitle.count)
        #expect([ScanRowState.scanTitle, ScanRowState.cancelTitle] == ["Scan", "Cancel scan"])
    }
}

/// Starting, cancelling and restarting a scan through the catalog, with the network stood in for.
@MainActor
@Suite("Scan cancel")
struct ScanCancelTests {
    let scratch = ScratchDefaults()
    let log = RecordingConnectionLog()
    let discovery = FakeScanDiscovery(interfaces: [
        IPv4Interface(name: "en0", address: "192.168.0.42", netmask: "255.255.255.0"),
        IPv4Interface(name: "utun3", address: "100.101.102.103", netmask: "255.255.255.255", isPointToPoint: true),
    ])
    let catalog: KVMDeviceManager

    nonisolated static let linux = Fixtures.device(id: "scanned-192.168.0.131-443", nickname: nil, host: "192.168.0.131")
    nonisolated static let surface = Fixtures.device(id: "scanned-192.168.0.114-443", nickname: nil, host: "192.168.0.114")
    nonisolated static let late = Fixtures.device(id: "scanned-192.168.0.99-443", nickname: nil, host: "192.168.0.99")

    init() {
        catalog = KVMDeviceManager(
            defaults: scratch.defaults,
            credentials: FakeCredentialStore(),
            trustStore: Fixtures.trustStore(scratch),
            discovery: discovery,
            scanLog: log
        )
    }

    private var listedHosts: Set<String> { Set(catalog.availableDevices.map(\.host)) }

    @Test func aScanShowsTheRangeItSweeps() async {
        discovery.hang("sweep")
        catalog.scanForDevices()

        #expect(catalog.isScanning)
        #expect(catalog.scanRanges == ["192.168.0.0/24"])
        let row = ScanRowState(isScanning: catalog.isScanning, ranges: catalog.scanRanges)
        #expect(row.buttonTitle == "Cancel scan")
        #expect(row.caption == "Scanning 192.168.0.0/24…")
        #expect(log.messages.contains { $0.hasPrefix("Scan started: sweeping 192.168.0.0/24 (en0)") })
        // The caption names what the sweep is given: the /24 around en0, less the Mac's own address.
        #expect(await waitUntil { discovery.sweptHosts.count == 1 })
        #expect(discovery.sweptHosts.first?.count == 253)
        #expect(discovery.sweptHosts.first?.contains("192.168.0.42") == false)

        catalog.cancelScan()
    }

    @Test func cancelStopsEverySourceAndKeepsWhatWasFound() async {
        discovery.answer("_comet._tcp") { [Self.linux] }
        discovery.hang("_kvm._tcp", thenReturn: [Self.late])
        discovery.hang("sweep", thenReturn: [Self.late])
        discovery.hang("tailnet", thenReturn: [Self.late])

        catalog.toggleScan()
        #expect(await waitUntil { listedHosts.contains("192.168.0.131") })

        catalog.toggleScan()

        #expect(catalog.isScanning == false)
        #expect(catalog.scanRanges.isEmpty)
        #expect(ScanRowState(isScanning: catalog.isScanning, ranges: catalog.scanRanges) == ScanRowState(isScanning: false, ranges: []))
        #expect(listedHosts == ["192.168.0.131"])
        #expect(log.messages.filter { $0 == "Scan cancelled" }.count == 1)
        // The Bonjour browse still running, the sweep and the tailnet all see the cancellation.
        #expect(await waitUntil { Set(discovery.cancelled) == ["_kvm._tcp", "sweep", "tailnet"] })
        // What they return after it never reaches the list, and the scan never logs an end.
        try? await Task.sleep(for: .milliseconds(100))
        #expect(listedHosts == ["192.168.0.131"])
        #expect(!log.messages.contains { $0.hasPrefix("Scan finished") })
    }

    @Test func scanAfterACancelStartsACleanScan() async {
        discovery.hang("_comet._tcp", thenReturn: [Self.late])
        discovery.hang("_kvm._tcp", thenReturn: [Self.late])
        discovery.hang("sweep", thenReturn: [Self.late])
        discovery.hang("tailnet", thenReturn: [Self.late])
        catalog.scanForDevices()
        #expect(await waitUntil { discovery.entered.count == 4 })
        catalog.cancelScan()

        discovery.answer("_comet._tcp") { [Self.linux] }
        discovery.answer("_kvm._tcp") { [] }
        discovery.answer("sweep") { [Self.linux, Self.surface] }
        discovery.answer("tailnet") { [] }
        catalog.toggleScan()

        #expect(catalog.isScanning)
        #expect(catalog.scanRanges == ["192.168.0.0/24"])
        #expect(await waitUntil { catalog.isScanning == false })
        #expect(listedHosts == ["192.168.0.131", "192.168.0.114"])
        #expect(catalog.scanRanges.isEmpty)
        #expect(discovery.sweptHosts.count == 2)
        #expect(log.messages.filter { $0.hasPrefix("Scan started") }.count == 2)
        #expect(log.messages.filter { $0 == "Scan cancelled" }.count == 1)
        #expect(log.messages.contains { $0.hasPrefix("Scan finished") && $0.contains("192.168.0.131") && $0.contains("192.168.0.114") })
        // The first scan's sources return their late results once cancelled; none lands.
        #expect(await waitUntil { discovery.cancelled.count == 4 })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!listedHosts.contains("192.168.0.99"))
    }

    @Test func savedDevicesStayListedThroughACancel() async {
        let saved = catalog.persistDevice(Fixtures.device(id: "manual-x", nickname: "Linux KVM", host: "192.168.0.131"))
        discovery.hang("sweep")
        catalog.scanForDevices()
        catalog.cancelScan()
        #expect(catalog.availableDevices.map(\.id) == [saved.id])
    }

    @Test func cancelWithNoScanRunningLogsNothing() {
        catalog.cancelScan()
        #expect(catalog.isScanning == false)
        #expect(log.messages.isEmpty)
    }
}
