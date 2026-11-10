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
