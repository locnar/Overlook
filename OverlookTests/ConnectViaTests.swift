import Foundation
import Testing
@testable import Overlook

/// Which address a connect goes through: a plain Connect uses the last-used address, an address
/// picked from the Connect menu is used as it is and becomes the last-used one, a failure makes
/// one attempt and says which address it tried, and the status line and the log name the address.
@MainActor
@Suite("Connect via an address")
struct ConnectViaTests {
    let scratch = ScratchDefaults()
    let credentials = FakeCredentialStore()
    let log = ConnectionLog.inMemory()
    let catalog: KVMDeviceManager

    static let lan = DeviceAddress(host: "192.168.0.131", port: 443)
    static let tailnet = DeviceAddress(host: "mdesktopkvm.tail1234.ts.net", port: 443)

    init() {
        catalog = Fixtures.catalog(scratch, credentials: credentials)
    }

    private func makeSession(_ link: RecordingSessionLink) -> ConsoleSession {
        ConsoleSession(catalog: catalog, defaults: scratch.defaults, link: link, connectionLog: log)
    }

    /// The Desk KVM saved with both addresses, LAN first, and nothing used yet.
    private func saveDesk() throws -> KVMDevice {
        try Fixtures.writeRecords([
            StoredDeviceRecordV2(
                id: "saved-192.168.0.131-443",
                nickname: "Desk",
                addresses: [.init(host: Self.lan.host, port: 443), .init(host: Self.tailnet.host, port: 443)],
                lastUsed: nil,
                type: "glinet_comet",
                capabilities: ["video_streaming"]
            ),
        ], to: scratch.defaults)
        let catalog = Fixtures.catalog(scratch, credentials: credentials)
        return try #require(catalog.availableDevices.first)
    }

    private func desk(in catalog: KVMDeviceManager) throws -> KVMDevice {
        try #require(catalog.availableDevices.first { $0.nickname == "Desk" })
    }

    /// Waits until `text` is in the log, or gives up.
    private func logged(_ text: String) async -> Bool {
        var turns = 0
        while !log.store.events.contains(where: { $0.message == text }), turns < 1_000 {
            await Task.yield()
            turns += 1
        }
        return log.store.events.contains { $0.message == text }
    }

    // MARK: - The menu

    @Test func theMenuListsEveryAddressWithItsTagAndMarksTheLastUsed() {
        var device = Fixtures.device(id: "saved-x", nickname: "Desk", host: Self.lan.host, addresses: [Self.lan, Self.tailnet])
        #expect(ConnectVia.items(for: device) == [
            .init(address: Self.lan, title: "192.168.0.131 (LAN)", isLastUsed: false),
            .init(address: Self.tailnet, title: "mdesktopkvm (Tailscale)", isLastUsed: false),
        ])

        device.lastUsedAddress = Self.tailnet
        #expect(ConnectVia.items(for: device) == [
            .init(address: Self.lan, title: "192.168.0.131 (LAN)", isLastUsed: false),
            .init(address: Self.tailnet, title: "mdesktopkvm (Tailscale) — last used", isLastUsed: true),
        ])
    }

    @Test func aDeviceWithOneAddressHasAOneItemMenu() {
        let device = Fixtures.device(nickname: nil, host: "kvm.example", port: 8443)
        #expect(ConnectVia.items(for: device).map(\.title) == ["kvm.example:8443"])
    }

    // MARK: - Plain Connect

    @Test func plainConnectUsesTheFirstAddressUntilOneIsUsed() async throws {
        _ = try saveDesk()
        let catalog = Fixtures.catalog(scratch, credentials: credentials)
        let link = RecordingSessionLink(catalog: catalog)
        let session = ConsoleSession(catalog: catalog, defaults: scratch.defaults, link: link, connectionLog: log)

        _ = await session.connect(to: ConnectVia.plainConnect(try desk(in: catalog)))

        #expect(link.steps.first == .signIn(host: Self.lan.host, password: nil))
    }

    @Test func plainConnectUsesTheLastUsedAddress() async throws {
        _ = try saveDesk()
        let catalog = Fixtures.catalog(scratch, credentials: credentials)
        catalog.setLastUsedAddress(Self.tailnet, for: try desk(in: catalog))
        let link = RecordingSessionLink(catalog: catalog)
        let session = ConsoleSession(catalog: catalog, defaults: scratch.defaults, link: link, connectionLog: log)

        _ = await session.connect(to: ConnectVia.plainConnect(try desk(in: catalog)))

        #expect(link.steps.first == .signIn(host: Self.tailnet.host, password: nil))
        #expect(session.connection.connectedDevice?.address == Self.tailnet)
    }

    // MARK: - Picking an address

    @Test func pickingAnAddressConnectsThroughExactlyThatOneAndMakesItLastUsed() async throws {
        _ = try saveDesk()
        let catalog = Fixtures.catalog(scratch, credentials: credentials)
        let link = RecordingSessionLink(catalog: catalog)
        let session = ConsoleSession(catalog: catalog, defaults: scratch.defaults, link: link, connectionLog: log)

        let target = ConnectVia.pick(Self.tailnet, of: try desk(in: catalog), in: catalog)
        // Recorded on the pick, before the connect has done anything.
        #expect(try desk(in: catalog).lastUsedAddress == Self.tailnet)

        _ = await session.connect(to: target)

        #expect(link.steps.filter { if case .signIn = $0 { return true } else { return false } }
            == [.signIn(host: Self.tailnet.host, password: nil)])
        #expect(link.steps.contains(.startStream(host: Self.tailnet.host)))

        // The next plain Connect repeats the choice.
        session.disconnect()
        let again = RecordingSessionLink(catalog: catalog)
        let next = ConsoleSession(catalog: catalog, defaults: scratch.defaults, link: again, connectionLog: log)
        _ = await next.connect(to: ConnectVia.plainConnect(try desk(in: catalog)))
        #expect(again.steps.first == .signIn(host: Self.tailnet.host, password: nil))
    }

    @Test func aPickThatFailsStillBecomesLastUsed() async throws {
        _ = try saveDesk()
        let catalog = Fixtures.catalog(scratch, credentials: credentials)
        let link = RecordingSessionLink(catalog: catalog)
        link.signInError = KVMError.connectionFailed
        let session = ConsoleSession(catalog: catalog, defaults: scratch.defaults, link: link, connectionLog: log)

        _ = await session.connect(to: ConnectVia.pick(Self.tailnet, of: try desk(in: catalog), in: catalog))

        #expect(try desk(in: catalog).lastUsedAddress == Self.tailnet)
        #expect(ConnectVia.plainConnect(try desk(in: catalog)).address == Self.tailnet)
    }

    // MARK: - A failed connect

    @Test func aFailedConnectMakesOneAttemptAndNamesTheAddress() async throws {
        _ = try saveDesk()
        let catalog = Fixtures.catalog(scratch, credentials: credentials)
        let link = RecordingSessionLink(catalog: catalog)
        link.signInError = KVMError.connectionFailed
        let session = ConsoleSession(catalog: catalog, defaults: scratch.defaults, link: link, connectionLog: log)
        let device = ConnectVia.plainConnect(try desk(in: catalog))

        let outcome = await session.connect(to: device)

        guard case .failed(let error) = outcome else {
            Issue.record("Expected a failure, got \(outcome)")
            return
        }
        // One sign-in, through the LAN address, and nothing after it: no second address tried.
        #expect(link.steps == [.signIn(host: Self.lan.host, password: nil)])
        #expect(session.connection.connectedDevice == nil)
        #expect(session.isIdle)
        #expect(ConnectVia.failureMessage(address: device.address, deviceHasOtherAddresses: true, error: error)
            == "Couldn't reach 192.168.0.131 (LAN). To use another address, choose it from the Connect menu.")
        #expect(await logged("Connect via 192.168.0.131 (LAN) failed: \(KVMError.connectionFailed.localizedDescription)"))
    }

    @Test func theFailureMessageFitsTheDeviceAndTheError() {
        #expect(ConnectVia.failureMessage(address: Self.lan, deviceHasOtherAddresses: false, error: KVMError.connectionFailed)
            == "Couldn't reach 192.168.0.131 (LAN).")
        let timeout = ConnectVia.failureMessage(address: Self.tailnet, deviceHasOtherAddresses: true, error: URLError(.timedOut))
        #expect(timeout.hasPrefix("Couldn't reach mdesktopkvm (Tailscale). To use another address, choose it from the Connect menu.\n\n"))
        let other = ConnectVia.failureMessage(address: DeviceAddress(host: "kvm.example", port: 8443), deviceHasOtherAddresses: false, error: TestError(name: "boom"))
        #expect(other.hasPrefix("Couldn't connect to kvm.example:8443.\n\n"))
        #expect(other.contains("boom"))
    }

    // MARK: - Status and log

    @Test func theStatusLineAndTheLogNameTheAddressUsed() async throws {
        _ = try saveDesk()
        let catalog = Fixtures.catalog(scratch, credentials: credentials)
        let link = RecordingSessionLink(catalog: catalog)
        let session = ConsoleSession(catalog: catalog, defaults: scratch.defaults, link: link, connectionLog: log)

        _ = await session.connect(to: ConnectVia.pick(Self.tailnet, of: try desk(in: catalog), in: catalog))

        let connected = try #require(session.connection.connectedDevice)
        #expect(ConnectVia.statusText(connectedThrough: connected.address) == "Connected via mdesktopkvm (Tailscale)")
        #expect(ConnectVia.statusText(connectedThrough: Self.lan) == "Connected via 192.168.0.131 (LAN)")
        #expect(await logged("Connecting via mdesktopkvm (Tailscale)"))
        #expect(await logged("Connected via mdesktopkvm (Tailscale)"))
        // The log's device tag stays the address, not the nickname.
        let line = log.store.events.first { $0.message == "Connected via mdesktopkvm (Tailscale)" }
        #expect(line?.source?.device == "mdesktopkvm")
    }

    @Test func aPasswordPromptIsNotLoggedAsAFailure() async throws {
        let link = RecordingSessionLink(catalog: catalog)
        link.signInError = KVMError.authenticationFailed
        let session = makeSession(link)

        _ = await session.connect(to: Fixtures.device(host: "192.0.2.5"))

        #expect(await logged("Connecting via 192.0.2.5"))
        #expect(log.store.events.contains { $0.message.contains("failed") } == false)
    }
}
