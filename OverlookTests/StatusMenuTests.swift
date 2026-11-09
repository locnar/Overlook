import Foundation
import Testing
@testable import Overlook

/// The menu-bar status menu's contents ("option B"): the connected sessions with the active one
/// checked and any recording marked, and the actions on the active session with its device in
/// the labels and disabled while it is not connected. Built from `StatusMenuModel`, kept current
/// by `StatusMenuState` from a registry whose sessions connect through a recording link.
@MainActor
@Suite("Status menu")
struct StatusMenuTests {
    let scratch = ScratchDefaults()
    let catalog: KVMDeviceManager
    let registry: SessionRegistry
    let menu: StatusMenuState

    init() {
        let catalog = KVMDeviceManager(
            defaults: scratch.defaults,
            credentials: FakeCredentialStore(),
            trustStore: Fixtures.trustStore(scratch)
        )
        self.catalog = catalog
        let scratch = self.scratch
        let registry = SessionRegistry(catalog: catalog) { catalog in
            ConsoleSession(
                catalog: catalog,
                defaults: scratch.defaults,
                link: RecordingSessionLink(catalog: catalog),
                audioPreferences: AudioPreferences(defaults: scratch.defaults),
                connectionLog: .inMemory()
            )
        }
        self.registry = registry
        menu = StatusMenuState(registry: registry)
    }

    /// A session whose window has appeared.
    private func openWindow() -> ConsoleSession {
        let session = registry.sessionForNewWindow()
        registry.add(session)
        return session
    }

    private func openConnectedWindow(_ name: String, host: String) async -> ConsoleSession {
        let session = openWindow()
        _ = await session.connect(to: Fixtures.device(id: "manual-\(host)", nickname: name, host: host))
        return session
    }

    private func makeRecordingsFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OverlookTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func withNothingConnectedTheActionsAreThereButDisabled() {
        _ = openWindow()
        let model = menu.model
        #expect(model.connected.isEmpty)
        #expect(!model.isAnyConnected)
        #expect(model.canSaveScreenshot == false)
        #expect(model.canToggleRecording == false)
        #expect(model.canDisconnect == false)
        #expect(model.recordingTitle == "Start Recording")
        #expect(model.disconnectTitle == "Disconnect")
        #expect(StatusMenuModel.showTitle == "Show Overlook")
        #expect(StatusMenuModel.connectedHeader == "Connected")
        #expect(StatusMenuModel.screenshotTitle == "Save Screenshot")
    }

    @Test func connectedSessionsAreListedWithTheActiveOneChecked() async {
        _ = await openConnectedWindow("Rack 1", host: "192.0.2.11")
        _ = await openConnectedWindow("Rack 2", host: "192.0.2.12")
        _ = openWindow()   // Open, not connected: not listed.

        let model = menu.model
        #expect(model.connected.map(\.title) == ["Rack 1", "Rack 2"])
        #expect(model.connected.map(\.isActive) == [true, false])
        #expect(model.activeDeviceName == "Rack 1")
        #expect(model.disconnectTitle == "Disconnect Rack 1")
        #expect(model.canSaveScreenshot && model.canToggleRecording && model.canDisconnect)
    }

    @Test func theCheckmarkAndTheActionsFollowTheActiveSession() async {
        _ = await openConnectedWindow("Rack 1", host: "192.0.2.11")
        let b = await openConnectedWindow("Rack 2", host: "192.0.2.12")
        let c = openWindow()

        registry.sessionDidBecomeKey(b)
        #expect(menu.model.connected.map(\.isActive) == [false, true])
        #expect(menu.model.disconnectTitle == "Disconnect Rack 2")

        // The active window is not connected: nothing is checked and the actions are disabled.
        registry.sessionDidBecomeKey(c)
        #expect(menu.model.connected.map(\.isActive) == [false, false])
        #expect(menu.model.disconnectTitle == "Disconnect")
        #expect(menu.model.canSaveScreenshot == false)
        #expect(menu.model.canDisconnect == false)
    }

    @Test func connectingAndDisconnectingUpdateTheList() async {
        let a = openWindow()
        #expect(menu.model.connected.isEmpty)

        _ = await a.connect(to: Fixtures.device(nickname: "Rack 1", host: "192.0.2.11"))
        #expect(menu.model.connected.map(\.title) == ["Rack 1"])

        a.disconnect()
        #expect(menu.model.connected.isEmpty)
        #expect(menu.model.canDisconnect == false)
    }

    @Test func aRecordingSessionIsMarkedUntilItStops() async throws {
        let folder = try makeRecordingsFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = await openConnectedWindow("Rack 1", host: "192.0.2.11")
        let b = await openConnectedWindow("Rack 2", host: "192.0.2.12")

        b.captureManager.recordingsFolder = folder
        b.captureManager.startRecording()
        #expect(b.captureManager.isRecording)
        #expect(menu.model.connected.map(\.title) == ["Rack 1", "Rack 2  ● rec"])
        #expect(menu.model.connected.map(\.isRecording) == [false, true])
        // The active session (Rack 1) is not the one recording.
        #expect(menu.model.recordingTitle == "Start Recording")

        registry.sessionDidBecomeKey(b)
        #expect(menu.model.recordingTitle == "Stop Recording")
        #expect(menu.model.canToggleRecording)

        await b.captureManager.finishRecordingForTermination()
        #expect(menu.model.connected.map(\.title) == ["Rack 1", "Rack 2"])
        #expect(menu.model.recordingTitle == "Start Recording")
    }

    @Test func renamingAConnectedDeviceRenamesItInTheMenu() async throws {
        let a = await openConnectedWindow("Rack 1", host: "192.0.2.11")
        let saved = try #require(a.connection.connectedDevice)

        catalog.saveEdits(of: saved, nickname: "Desk", addresses: saved.addresses)
        #expect(menu.model.connected.map(\.title) == ["Desk"])
        #expect(menu.model.disconnectTitle == "Disconnect Desk")

        catalog.saveEdits(of: saved, nickname: nil, addresses: saved.addresses)
        #expect(menu.model.connected.map(\.title) == ["192.0.2.11"])
        #expect(menu.model.disconnectTitle == "Disconnect 192.0.2.11")
    }

    @Test func closingAWindowDropsItsSessionFromTheList() async {
        let a = await openConnectedWindow("Rack 1", host: "192.0.2.11")
        _ = await openConnectedWindow("Rack 2", host: "192.0.2.12")

        a.windowWillClose()
        registry.remove(a)
        #expect(menu.model.connected.map(\.title) == ["Rack 2"])
        #expect(menu.model.connected.map(\.isActive) == [true])
        #expect(menu.model.disconnectTitle == "Disconnect Rack 2")
    }
}
