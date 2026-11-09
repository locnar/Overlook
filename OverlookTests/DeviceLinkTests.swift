import Foundation
import Testing
@testable import Overlook

/// "This is <device>": after connecting to an address no saved device has, a certificate that
/// matches a saved device's pin offers to add the address to that device. Pins are written to a
/// scratch trust store as a first connection would have recorded them.
@MainActor
@Suite("Linking an address by its certificate")
struct DeviceLinkTests {
    let scratch = ScratchDefaults()
    let credentials = FakeCredentialStore()

    static let lan = DeviceAddress(host: "192.168.0.131", port: 443)
    static let tailnet = DeviceAddress(host: "mdesktopkvm.tail1234.ts.net", port: 443)

    private func pin(_ pins: [DeviceAddress: String]) {
        var stored: [String: String] = [:]
        for (address, fingerprint) in pins {
            stored[DeviceTrustStore.key(host: address.host, port: address.port)] = fingerprint
        }
        scratch.defaults.set(stored, forKey: "overlook.trusted_certificates.v1")
    }

    /// A catalog with Desk saved at its LAN address, a token for it, and the given pins.
    private func setUp(pins: [DeviceAddress: String]) -> (KVMDeviceManager, KVMDevice, DeviceTrustStore) {
        pin(pins)
        let trust = Fixtures.trustStore(scratch)
        let catalog = Fixtures.catalog(scratch, credentials: credentials, trust: trust)
        let desk = catalog.persistDevice(Fixtures.device(nickname: "Desk", host: Self.lan.host, authToken: "desk-token"))
        return (catalog, desk, trust)
    }

    /// Connects a session to the Tailscale address as a device of its own, as a Manual Connect
    /// would, and returns the session with whether the address was saved before.
    private func connectNewAddress(_ catalog: KVMDeviceManager) async -> (ConsoleSession, Bool) {
        let addressWasSaved = catalog.savedDevice(containing: Self.tailnet) != nil
        let session = ConsoleSession(
            catalog: catalog,
            defaults: scratch.defaults,
            link: RecordingSessionLink(catalog: catalog),
            connectionLog: .inMemory()
        )
        let manual = catalog.addManualDevice(host: Self.tailnet.host, port: 443, type: .glinetComet, authToken: "tailnet-token")
        _ = await session.connect(to: manual)
        return (session, addressWasSaved)
    }

    // MARK: - When to ask

    @Test func aMatchingCertificateAsksAboutTheSavedDevice() async throws {
        let (catalog, desk, _) = setUp(pins: [Self.lan: "aa", Self.tailnet: "aa"])
        let (session, wasSaved) = await connectNewAddress(catalog)
        let connected = try #require(session.connection.connectedDevice)

        let prompt = try #require(DeviceLinkPrompt.after(connecting: connected, addressWasSaved: wasSaved, catalog: catalog))

        #expect(prompt.candidate.id == desk.id)
        #expect(prompt.title == "This is Desk")
        #expect(prompt.message.contains("mdesktopkvm (Tailscale)"))
        #expect(DeviceLinkPrompt.addTitle == "Add address")
        #expect(DeviceLinkPrompt.keepTitle == "Keep separate")
        #expect(DeviceLinkPrompt.escapeAnswer == .keepSeparate)
    }

    @Test func aDifferentCertificateDoesNotAsk() async throws {
        let (catalog, _, _) = setUp(pins: [Self.lan: "aa", Self.tailnet: "bb"])
        let (session, wasSaved) = await connectNewAddress(catalog)
        let connected = try #require(session.connection.connectedDevice)

        #expect(DeviceLinkPrompt.after(connecting: connected, addressWasSaved: wasSaved, catalog: catalog) == nil)
    }

    @Test func noPinDoesNotAsk() async throws {
        // A certificate the system trusts is never pinned, so there is nothing to compare.
        let (catalog, _, _) = setUp(pins: [Self.lan: "aa"])
        let (session, wasSaved) = await connectNewAddress(catalog)
        let connected = try #require(session.connection.connectedDevice)

        #expect(DeviceLinkPrompt.after(connecting: connected, addressWasSaved: wasSaved, catalog: catalog) == nil)
    }

    @Test func anAddressAlreadySavedDoesNotAsk() async throws {
        let (catalog, _, _) = setUp(pins: [Self.lan: "aa", Self.tailnet: "aa"])
        // Kept separate once: the address is now a saved device of its own.
        _ = catalog.persistDevice(Fixtures.device(id: "manual-t", nickname: nil, host: Self.tailnet.host))
        let (session, wasSaved) = await connectNewAddress(catalog)
        let connected = try #require(session.connection.connectedDevice)

        #expect(wasSaved)
        #expect(DeviceLinkPrompt.after(connecting: connected, addressWasSaved: wasSaved, catalog: catalog) == nil)
        // And connecting through an address of the device itself never asks either.
        #expect(DeviceLinkPrompt.after(connecting: catalog.availableDevices.first { $0.nickname == "Desk" }!, addressWasSaved: true, catalog: catalog) == nil)
    }

    // MARK: - The answers

    @Test func addAddressMakesItOneOfTheDevicesAndTheSessionTheDevices() async throws {
        let (catalog, desk, trust) = setUp(pins: [Self.lan: "aa", Self.tailnet: "aa"])
        let (session, wasSaved) = await connectNewAddress(catalog)
        let connected = try #require(session.connection.connectedDevice)
        let client = session.connection.glkvmClient
        let prompt = try #require(DeviceLinkPrompt.after(connecting: connected, addressWasSaved: wasSaved, catalog: catalog))

        let linked = try #require(prompt.answer(.addAddress, catalog: catalog))

        #expect(linked.id == desk.id)
        #expect(linked.addresses == [Self.lan, Self.tailnet])
        #expect(linked.lastUsedAddress == Self.tailnet)
        #expect(catalog.availableDevices.map(\.id) == [desk.id])
        let records = try Fixtures.readRecords(from: scratch.defaults)
        #expect(records.map(\.id) == [desk.id])
        #expect(records.first?.addresses.map(\.host) == [Self.lan.host, Self.tailnet.host])
        // The session is now the device's, still through the address it connected with.
        #expect(session.connection.connectedDevice?.id == desk.id)
        #expect(session.connection.connectedDevice?.displayName == "Desk")
        #expect(session.connection.connectedDevice?.address == Self.tailnet)
        #expect(session.connection.glkvmClient === client)
        #expect(session.isShowing(catalog.availableDevices[0]))
        // Nothing stored is lost: both tokens and both pins stay.
        #expect(credentials.deletedTokens.isEmpty)
        #expect(credentials.tokens[FakeCredentialStore.key(host: Self.tailnet.host, port: 443)] == "tailnet-token")
        #expect(credentials.tokens[FakeCredentialStore.key(host: Self.lan.host, port: 443)] == "desk-token")
        #expect(trust.pinnedFingerprint(host: Self.tailnet.host, port: 443) == "aa")
        #expect(trust.pinnedFingerprint(host: Self.lan.host, port: 443) == "aa")
    }

    @Test func addAddressGivesTheAddressTheDevicesTokenWhenItHasNone() async throws {
        let (catalog, _, _) = setUp(pins: [Self.lan: "aa", Self.tailnet: "aa"])
        // Saved on its own without a token (as after a sign-in that has since expired).
        let separate = catalog.persistDevice(Fixtures.device(id: "manual-t", nickname: nil, host: Self.tailnet.host))
        let prompt = DeviceLinkPrompt(connected: separate, candidate: catalog.availableDevices.first { $0.nickname == "Desk" }!)

        prompt.answer(.addAddress, catalog: catalog)

        #expect(credentials.tokens[FakeCredentialStore.key(host: Self.tailnet.host, port: 443)] == "desk-token")
    }

    @Test func keepSeparateChangesNothing() async throws {
        let (catalog, desk, _) = setUp(pins: [Self.lan: "aa", Self.tailnet: "aa"])
        let (session, wasSaved) = await connectNewAddress(catalog)
        let connected = try #require(session.connection.connectedDevice)
        let prompt = try #require(DeviceLinkPrompt.after(connecting: connected, addressWasSaved: wasSaved, catalog: catalog))
        let before = try Fixtures.readRecords(from: scratch.defaults)

        #expect(prompt.answer(.keepSeparate, catalog: catalog) == nil)

        #expect(try Fixtures.readRecords(from: scratch.defaults) == before)
        #expect(before.count == 2)
        #expect(session.connection.connectedDevice?.id == connected.id)
        #expect(catalog.availableDevices.first { $0.id == desk.id }?.addresses == [Self.lan])
    }
}
