import Foundation
import Testing
@testable import Overlook

/// The pure rules of a device's identity: the network tag of an address, how a typed address is
/// read, which old names were generated, and the name a device is shown by.
@Suite("Device identity")
struct DeviceIdentityTests {
    // MARK: - Address tags

    @Test(arguments: [
        ("mdesktopkvm.tail1234.ts.net", AddressTag.tailscale),
        ("MDesktopKVM.Tail1234.TS.NET.", .tailscale),
        ("100.64.0.1", .tailscale),
        ("100.101.102.103", .tailscale),
        ("100.127.255.254", .tailscale),
        ("192.168.0.131", .lan),
        ("10.0.0.5", .lan),
        ("172.16.0.1", .lan),
        ("172.31.255.255", .lan),
    ])
    func addressesAreTagged(host: String, tag: AddressTag) {
        #expect(AddressTag.classify(host: host) == tag)
    }

    @Test(arguments: [
        "mdesktopkvm",          // a bare MagicDNS name says nothing on its own
        "kvm.example.com",
        "ts.net.example.com",
        "100.63.255.255",       // just below 100.64.0.0/10
        "100.128.0.1",          // just above it
        "172.15.0.1",
        "172.32.0.1",
        "192.169.0.1",
        "8.8.8.8",
        "fd7a:115c:a1e0::1",
        "192.168.0",
        "192.168.0.256",
        "",
    ])
    func otherAddressesHaveNoTag(host: String) {
        #expect(AddressTag.classify(host: host) == nil)
    }

    @Test func addressesAreWrittenShortWithTheirTag() {
        #expect(DeviceAddress(host: "192.168.0.131", port: 443).labelWithTag == "192.168.0.131 (LAN)")
        #expect(DeviceAddress(host: "mdesktopkvm.tail1234.ts.net", port: 443).labelWithTag == "mdesktopkvm.tail1234.ts.net (Tailscale)")
        #expect(DeviceAddress(host: "mdesktopkvm", port: 443).labelWithTag == "mdesktopkvm")
        #expect(DeviceAddress(host: "kvm.example", port: 8443).labelWithTag == "kvm.example:8443")
        #expect(DeviceAddress(host: "192.168.0.131", port: 443).hostPort == "192.168.0.131:443")
        #expect(DeviceAddress(host: "fd00::5", port: 8443).hostPort == "[fd00::5]:8443")
    }

    @Test func addressesCompareWithoutRegardToHostCase() {
        let lower = DeviceAddress(host: "kvm.example", port: 443)
        let upper = DeviceAddress(host: "KVM.Example", port: 443)
        #expect(lower == upper)
        #expect(Set([lower, upper]).count == 1)
        #expect(lower != DeviceAddress(host: "kvm.example", port: 8443))
    }

    // MARK: - Typed addresses

    @Test(arguments: [
        ("192.168.0.131", "", "192.168.0.131", 443),
        ("  192.168.0.131  ", "443", "192.168.0.131", 443),
        ("192.168.0.131", "8443", "192.168.0.131", 8443),
        ("192.168.0.131:8443", "", "192.168.0.131", 8443),
        ("192.168.0.131:8443", "443", "192.168.0.131", 8443),
        ("https://kvm.example/", "", "kvm.example", 443),
        ("https://kvm.example:8443/login", "", "kvm.example", 8443),
        ("mdesktopkvm", "", "mdesktopkvm", 443),
        ("fd00::5", "", "fd00::5", 443),
        ("[fd00::5]:8443", "", "fd00::5", 8443),
    ])
    func typedAddressesAreRead(host: String, port: String, expectedHost: String, expectedPort: Int) {
        #expect(AddressInput.parse(host, port: port) == .success(DeviceAddress(host: expectedHost, port: expectedPort)))
    }

    @Test func badAddressesAreRefusedWithAReason() {
        #expect(AddressInput.parse("", port: "443") == .failure(.emptyHost))
        #expect(AddressInput.parse("   ") == .failure(.emptyHost))
        #expect(AddressInput.parse("https://") == .failure(.emptyHost))
        #expect(AddressInput.parse("my kvm") == .failure(.invalidHost))
        #expect(AddressInput.parse("kvm.example:") == .failure(.invalidHost))
        #expect(AddressInput.parse("[fd00::5") == .failure(.invalidHost))
        #expect(AddressInput.parse("kvm.example", port: "abc") == .failure(.invalidPort))
        #expect(AddressInput.parse("kvm.example", port: "0") == .failure(.invalidPort))
        #expect(AddressInput.parse("kvm.example", port: "65536") == .failure(.invalidPort))
        #expect(AddressInput.parse("kvm.example:99999") == .failure(.invalidPort))
        #expect(AddressInput.Problem.invalidPort.message.contains("65535"))
    }

    // MARK: - Generated names

    @Test(arguments: [
        "Manual KVM @ 192.168.0.131:443",
        "KVM @ 192.168.200.1:80",
        "GLKVM @ 192.168.0.131:443",
        "GLKVM @ kvm.tail1234.ts.net:443 (Tailscale)",
        "  KVM @ 10.0.0.2:443",
    ])
    func generatedNamesAreNotNicknames(name: String) {
        #expect(DeviceNaming.isGenerated(name))
        #expect(DeviceNaming.nickname(fromLegacyName: name) == nil)
    }

    @Test func otherNamesAreKeptAsNicknames() {
        #expect(DeviceNaming.nickname(fromLegacyName: "Rack 3") == "Rack 3")
        #expect(DeviceNaming.nickname(fromLegacyName: "  Lab KVM ") == "Lab KVM")
        #expect(DeviceNaming.nickname(fromLegacyName: "mdesktop (Tailscale)") == "mdesktop (Tailscale)")
        #expect(DeviceNaming.nickname(fromLegacyName: "My KVM @ home") == "My KVM @ home")
        #expect(DeviceNaming.nickname(fromLegacyName: "   ") == nil)
    }

    // MARK: - A device's name and addresses

    @Test func aDeviceIsShownByItsNicknameOrElseItsAddress() {
        #expect(Fixtures.device(nickname: "Rack 3", host: "192.168.0.131").displayName == "Rack 3")
        #expect(Fixtures.device(nickname: nil, host: "192.168.0.131").displayName == "192.168.0.131")
        #expect(Fixtures.device(nickname: "   ", host: "192.168.0.131").displayName == "192.168.0.131")
        #expect(Fixtures.device(nickname: nil, host: "kvm.example", port: 8443).displayName == "kvm.example:8443")
        #expect(Fixtures.device(nickname: nil, host: "mdesktopkvm.tail1234.ts.net").displayName == "mdesktopkvm.tail1234.ts.net")
    }

    @Test func aNewDeviceHasItsOwnAddress() {
        let device = Fixtures.device(host: "192.168.0.131")
        #expect(device.addresses == [DeviceAddress(host: "192.168.0.131", port: 443)])
        #expect(device.preferredAddress == device.address)
    }

    @Test func plainConnectPrefersTheLastUsedAddressWhileItIsListed() {
        let lan = DeviceAddress(host: "192.168.0.131", port: 443)
        let tailnet = DeviceAddress(host: "mdesktopkvm", port: 443)
        var device = Fixtures.device(host: lan.host, addresses: [lan, tailnet])
        #expect(device.preferredAddress == lan)

        device.lastUsedAddress = tailnet
        #expect(device.preferredAddress == tailnet)

        device.lastUsedAddress = DeviceAddress(host: "gone.example", port: 443)
        #expect(device.preferredAddress == lan)
    }

    @Test func connectingViaAnotherAddressKeepsEverythingElse() {
        let lan = DeviceAddress(host: "192.168.0.131", port: 443)
        let tailnet = DeviceAddress(host: "mdesktopkvm", port: 8443)
        let device = Fixtures.device(id: "saved-x", nickname: "Desk", host: lan.host, addresses: [lan, tailnet], authToken: "tok")

        let via = device.via(tailnet)

        #expect(via.host == "mdesktopkvm")
        #expect(via.port == 8443)
        #expect(via.webRTCURL == "wss://mdesktopkvm:8443/janus/ws")
        #expect(via.id == "saved-x")
        #expect(via.nickname == "Desk")
        #expect(via.addresses == [lan, tailnet])
        #expect(via.authToken == "tok")
        #expect(via.includes(lan))
        #expect(via.includes(DeviceAddress(host: "MDESKTOPKVM", port: 8443)))
        #expect(via.includes(DeviceAddress(host: "mdesktopkvm", port: 443)) == false)
    }
}
