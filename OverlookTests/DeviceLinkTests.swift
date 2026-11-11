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
    private func connectNewAddress(_ catalog: KVMDeviceManager) async -> (ConsoleSession, KVMDevice?) {
        let savedBefore = catalog.savedDevice(containing: Self.tailnet)
        let session = ConsoleSession(
            catalog: catalog,
            defaults: scratch.defaults,
            link: RecordingSessionLink(catalog: catalog),
            connectionLog: .inMemory()
        )
        let manual = catalog.addManualDevice(host: Self.tailnet.host, port: 443, type: .glinetComet, authToken: "tailnet-token")
        _ = await session.connect(to: manual)
        return (session, savedBefore)
    }

    // MARK: - When to ask

    @Test func aMatchingCertificateAsksAboutTheSavedDevice() async throws {
        let (catalog, desk, _) = setUp(pins: [Self.lan: "aa", Self.tailnet: "aa"])
        let (session, wasSaved) = await connectNewAddress(catalog)
        let connected = try #require(session.connection.connectedDevice)

        let prompt = try #require(DeviceLinkPrompt.after(connecting: connected, savedBefore: wasSaved, catalog: catalog))

        #expect(prompt.candidate.id == desk.id)
        #expect(prompt.title == "This is Desk")
        #expect(prompt.message.contains("mdesktopkvm.tail1234.ts.net (Tailscale)"))
        #expect(DeviceLinkPrompt.addTitle == "Add address")
        #expect(DeviceLinkPrompt.keepTitle == "Keep separate")
        #expect(DeviceLinkPrompt.escapeAnswer == .keepSeparate)
    }

    @Test func aDifferentCertificateDoesNotAsk() async throws {
        let (catalog, _, _) = setUp(pins: [Self.lan: "aa", Self.tailnet: "bb"])
        let (session, wasSaved) = await connectNewAddress(catalog)
        let connected = try #require(session.connection.connectedDevice)

        #expect(DeviceLinkPrompt.after(connecting: connected, savedBefore: wasSaved, catalog: catalog) == nil)
    }

    @Test func noPinDoesNotAsk() async throws {
        // A certificate the system trusts is never pinned, so there is nothing to compare.
        let (catalog, _, _) = setUp(pins: [Self.lan: "aa"])
        let (session, wasSaved) = await connectNewAddress(catalog)
        let connected = try #require(session.connection.connectedDevice)

        #expect(DeviceLinkPrompt.after(connecting: connected, savedBefore: wasSaved, catalog: catalog) == nil)
    }

    @Test func anAddressSavedOnItsOwnAsksTooAsDevicesFromEarlierVersionsAre() async throws {
        let (catalog, desk, _) = setUp(pins: [Self.lan: "aa", Self.tailnet: "aa"])
        // Saved as a device of its own, the way the migration leaves every old record.
        _ = catalog.persistDevice(Fixtures.device(id: "manual-t", nickname: nil, host: Self.tailnet.host))
        let (session, savedBefore) = await connectNewAddress(catalog)
        let connected = try #require(session.connection.connectedDevice)

        #expect(savedBefore != nil)
        let prompt = try #require(DeviceLinkPrompt.after(connecting: connected, savedBefore: savedBefore, catalog: catalog))
        #expect(prompt.candidate.id == desk.id)
        #expect(prompt.wasSavedSeparately)
        #expect(prompt.message.hasPrefix("mdesktopkvm.tail1234.ts.net (Tailscale) is saved as a device of its own"))

        prompt.answer(.addAddress, catalog: catalog)
        #expect(catalog.availableDevices.map(\.id) == [desk.id])
        #expect(catalog.availableDevices.first?.addresses == [Self.lan, Self.tailnet])
    }

    @Test func connectingThroughAnAddressOfADeviceWithSeveralNeverAsks() async throws {
        let (catalog, desk, _) = setUp(pins: [Self.lan: "aa", Self.tailnet: "aa", DeviceAddress(host: "192.0.2.9", port: 443): "aa"])
        let both = try #require(catalog.saveEdits(of: desk, nickname: "Desk", addresses: [Self.lan, Self.tailnet]))
        // Another device whose pin happens to match must not pull an address out of this one.
        _ = catalog.persistDevice(Fixtures.device(id: "manual-o", nickname: "Other", host: "192.0.2.9"))

        #expect(DeviceLinkPrompt.after(connecting: both.via(Self.tailnet), savedBefore: both, catalog: catalog) == nil)
    }

    @Test func keepSeparateIsNotAskedAgain() async throws {
        let (catalog, _, _) = setUp(pins: [Self.lan: "aa", Self.tailnet: "aa"])
        let (session, savedBefore) = await connectNewAddress(catalog)
        let connected = try #require(session.connection.connectedDevice)
        let prompt = try #require(DeviceLinkPrompt.after(connecting: connected, savedBefore: savedBefore, catalog: catalog))

        prompt.answer(.keepSeparate, catalog: catalog)

        let again = try #require(catalog.availableDevices.first { $0.id == connected.id })
        #expect(DeviceLinkPrompt.after(connecting: again, savedBefore: again, catalog: catalog) == nil)
        // Remembered across launches.
        let relaunched = Fixtures.catalog(scratch, credentials: credentials, trust: Fixtures.trustStore(scratch))
        #expect(DeviceLinkPrompt.after(connecting: again, savedBefore: again, catalog: relaunched) == nil)
    }

    // MARK: - The answers

    @Test func addAddressMakesItOneOfTheDevicesAndTheSessionTheDevices() async throws {
        let (catalog, desk, trust) = setUp(pins: [Self.lan: "aa", Self.tailnet: "aa"])
        let (session, wasSaved) = await connectNewAddress(catalog)
        let connected = try #require(session.connection.connectedDevice)
        let client = session.connection.glkvmClient
        let prompt = try #require(DeviceLinkPrompt.after(connecting: connected, savedBefore: wasSaved, catalog: catalog))

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
        let prompt = try #require(DeviceLinkPrompt.after(connecting: connected, savedBefore: wasSaved, catalog: catalog))
        let before = try Fixtures.readRecords(from: scratch.defaults)

        #expect(prompt.answer(.keepSeparate, catalog: catalog) == nil)

        #expect(try Fixtures.readRecords(from: scratch.defaults) == before)
        #expect(before.count == 2)
        #expect(session.connection.connectedDevice?.id == connected.id)
        #expect(catalog.availableDevices.first { $0.id == desk.id }?.addresses == [Self.lan])
    }

    // MARK: - Linking while the device is open in another window

    /// Two windows: the first shows Desk through its LAN address, the second has just connected
    /// to the Tailscale address as a device of its own and been asked "This is Desk". `links`
    /// holds each window's session link, in the order the windows opened.
    private func twoWindows(_ catalog: KVMDeviceManager, desk: KVMDevice) async throws
        -> (registry: SessionRegistry, first: ConsoleSession, second: ConsoleSession, links: [RecordingSessionLink], prompt: DeviceLinkPrompt) {
        let defaults = scratch.defaults
        var links: [RecordingSessionLink] = []
        let registry = SessionRegistry(catalog: catalog) { catalog in
            let link = RecordingSessionLink(catalog: catalog)
            links.append(link)
            return ConsoleSession(catalog: catalog, defaults: defaults, link: link, connectionLog: .inMemory())
        }
        let first = registry.sessionForNewWindow()
        registry.add(first)
        _ = await first.connect(to: desk.via(Self.lan))

        let second = registry.sessionForNewWindow()
        registry.add(second)
        let savedBefore = catalog.savedDevice(containing: Self.tailnet)
        let manual = catalog.addManualDevice(host: Self.tailnet.host, port: 443, type: .glinetComet, authToken: "tailnet-token")
        let outcome = await second.connect(to: manual)
        guard case .connected(let connected, _) = outcome else {
            Issue.record("Expected the second window to connect, got \(outcome)")
            throw CancellationError()
        }
        let prompt = try #require(DeviceLinkPrompt.after(connecting: connected, savedBefore: savedBefore, catalog: catalog))
        return (registry, first, second, links, prompt)
    }

    @Test func addAddressWhileOpenElsewhereBringsThatWindowForwardAndDisconnectsThisOne() async throws {
        let (catalog, desk, _) = setUp(pins: [Self.lan: "aa", Self.tailnet: "aa"])
        let (registry, first, second, links, prompt) = try await twoWindows(catalog, desk: desk)
        #expect(prompt.candidate.id == desk.id)
        var forward: [String] = []
        first.bringForwardObserver = { forward.append("first") }
        second.bringForwardObserver = { forward.append("second") }
        let stepsBefore = links[1].steps.count

        let outcome = second.answerLink(prompt, .addAddress)

        guard case .openElsewhere(let linked, let other) = outcome else {
            Issue.record("Expected open elsewhere, got \(outcome)")
            return
        }
        // The address is added, as without another window.
        #expect(linked.id == desk.id)
        #expect(catalog.availableDevices.map(\.id) == [desk.id])
        #expect(catalog.availableDevices.first?.addresses == [Self.lan, Self.tailnet])
        // The window that had the device comes forward, and keeps it through its own address.
        #expect(other === first)
        #expect(forward == ["first"])
        #expect(first.connection.connectedDevice?.id == desk.id)
        #expect(first.connection.connectedDevice?.address == Self.lan)
        #expect(Array(links[0].steps.suffix(1)) == [.startStream(host: Self.lan.host)])
        // The linking window hangs up as a Disconnect does, and stays open, disconnected.
        #expect(second.connection.connectedDevice == nil)
        #expect(Array(links[1].steps.dropFirst(stepsBefore)) == [.hangUp, .stopInput])
        #expect(registry.sessions.count == 2)
        #expect(second.isClosed == false)
        #expect(second.sessionNotice?.title == "Desk is already open in another window.")
        #expect(first.sessionNotice == nil)
        // One window per device.
        let device = try #require(catalog.availableDevices.first)
        #expect(registry.sessions.filter { $0.isShowing(device) }.map { ObjectIdentifier($0) } == [ObjectIdentifier(first)])
        #expect(registry.session(showing: Self.tailnet) === first)
    }

    @Test func theNoticeNamesTheDeviceAndGoesWithTheNextConnect() async throws {
        #expect(ConsoleSession.alreadyOpenNotice(deviceName: "Linux KVM").title == "Linux KVM is already open in another window.")

        let (catalog, desk, _) = setUp(pins: [Self.lan: "aa", Self.tailnet: "aa"])
        // The registry is held for the test: sessions hold it weakly.
        let (registry, _, second, _, prompt) = try await twoWindows(catalog, desk: desk)
        second.answerLink(prompt, .addAddress)
        #expect(second.sessionNotice != nil)
        #expect(registry.sessions.count == 2)

        _ = await second.connect(to: Fixtures.device(id: "manual-other", nickname: "Rack 2", host: "192.0.2.12"))
        #expect(second.sessionNotice == nil)
        #expect(second.connection.connectedDevice?.nickname == "Rack 2")
    }

    /// A recording in the linking window ends as it does on Disconnect: stopped and saved, with no
    /// question (only closing a window asks first).
    @Test func aRecordingInTheLinkingWindowStopsAsOnDisconnect() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("OverlookTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let (catalog, desk, _) = setUp(pins: [Self.lan: "aa", Self.tailnet: "aa"])
        let (registry, first, second, _, prompt) = try await twoWindows(catalog, desk: desk)
        second.captureManager.recordingsFolder = folder
        second.captureManager.startRecording()
        #expect(second.captureManager.isRecording)

        second.answerLink(prompt, .addAddress)

        #expect(second.captureManager.isRecording == false)
        #expect(second.connection.connectedDevice == nil)
        #expect(first.connection.connectedDevice?.id == desk.id)
        #expect(registry.session(showing: Self.tailnet) === first)
    }

    @Test func addAddressWithTheDeviceOpenNowhereElseKeepsThisWindowConnected() async throws {
        let (catalog, desk, _) = setUp(pins: [Self.lan: "aa", Self.tailnet: "aa"])
        let (registry, first, second, links, prompt) = try await twoWindows(catalog, desk: desk)
        first.disconnect()
        var forward = 0
        first.bringForwardObserver = { forward += 1 }
        second.bringForwardObserver = { forward += 1 }
        let stepsBefore = links[1].steps.count

        let outcome = second.answerLink(prompt, .addAddress)

        guard case .linked(let linked) = outcome else {
            Issue.record("Expected linked, got \(outcome)")
            return
        }
        #expect(linked.id == desk.id)
        #expect(linked.addresses == [Self.lan, Self.tailnet])
        #expect(second.connection.connectedDevice?.id == desk.id)
        #expect(second.connection.connectedDevice?.address == Self.tailnet)
        #expect(links[1].steps.count == stepsBefore)
        #expect(forward == 0)
        #expect(second.sessionNotice == nil)
        #expect(registry.session(showing: Self.lan) === second)
    }

    @Test func keepSeparateWhileOpenElsewhereChangesNothing() async throws {
        let (catalog, desk, _) = setUp(pins: [Self.lan: "aa", Self.tailnet: "aa"])
        let (registry, first, second, links, prompt) = try await twoWindows(catalog, desk: desk)
        let connected = try #require(second.connection.connectedDevice)
        var forward = 0
        first.bringForwardObserver = { forward += 1 }
        let before = try Fixtures.readRecords(from: scratch.defaults)
        let stepsBefore = links[1].steps.count

        let outcome = second.answerLink(prompt, .keepSeparate)

        guard case .unchanged = outcome else {
            Issue.record("Expected unchanged, got \(outcome)")
            return
        }
        #expect(try Fixtures.readRecords(from: scratch.defaults) == before)
        #expect(second.connection.connectedDevice?.id == connected.id)
        #expect(first.connection.connectedDevice?.id == desk.id)
        #expect(links[1].steps.count == stepsBefore)
        #expect(forward == 0)
        #expect(second.sessionNotice == nil)
        #expect(registry.sessions.count == 2)
    }
}
