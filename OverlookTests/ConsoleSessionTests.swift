import Combine
import Foundation
import Testing
@testable import Overlook

/// The split between the shared device catalog and a console's own session. Connections here are
/// set directly rather than made: a real connect needs a device on the network.
@MainActor
@Suite("Console session")
struct ConsoleSessionTests {
    let scratch = ScratchDefaults()
    let catalog: KVMDeviceManager

    init() {
        catalog = KVMDeviceManager(
            defaults: scratch.defaults,
            credentials: FakeCredentialStore(),
            trustStore: Fixtures.trustStore(scratch)
        )
    }

    private func makeSession() -> ConsoleSession {
        ConsoleSession(catalog: catalog, defaults: scratch.defaults, connectionLog: .inMemory())
    }

    // MARK: - The session's own objects

    @Test func startsDisconnectedWithNoPanelOpen() {
        let session = makeSession()
        #expect(session.connection.connectedDevice == nil)
        #expect(session.connection.glkvmClient == nil)
        #expect(session.panels.openPanel == nil)
        #expect(session.panels.isSessionActive == false)
        #expect(session.captureManager.isRecording == false)
    }

    @Test func theConnectionDrivesWhetherTheSessionIsActive() {
        let session = makeSession()

        session.connection.connectedDevice = Fixtures.device()
        #expect(session.panels.isSessionActive)
        #expect(session.panels.isEnabled(.settings))

        session.connection.disconnectFromDevice()
        #expect(session.panels.isSessionActive == false)
        #expect(session.panels.isEnabled(.settings) == false)
    }

    @Test func captureFollowsTheSessionsOwnConnection() {
        let session = makeSession()
        session.captureManager.beginRegionSelection()
        #expect(session.captureManager.isSelectingRegion == false)

        session.connection.connectedDevice = Fixtures.device()
        session.captureManager.beginRegionSelection()
        #expect(session.captureManager.isSelectingRegion)

        session.connection.disconnectFromDevice()
        #expect(session.captureManager.isSelectingRegion == false)
    }

    @Test func disconnectingClearsTheDeviceAndTheClient() throws {
        let connection = SessionConnection(catalog: catalog)
        let device = Fixtures.device()
        connection.connectedDevice = device
        connection.glkvmClient = try GLKVMClient(device: device)

        connection.disconnectFromDevice()

        #expect(connection.connectedDevice == nil)
        #expect(connection.glkvmClient == nil)
    }

    @Test func settingsSavedByOneSessionAreReadByTheNext() {
        let first = makeSession()
        first.panels.width = 640
        first.panels.persistWidth()
        first.captureManager.videoCodec = .hevc

        let second = makeSession()

        #expect(second.panels.width == 640)
        #expect(second.captureManager.videoCodec == .hevc)
    }

    // MARK: - Sessions are independent of each other

    @Test func twoSessionsOnOneCatalogDoNotShareState() {
        let a = makeSession()
        let b = makeSession()

        a.connection.connectedDevice = Fixtures.device()
        a.panels.show(.log)

        #expect(b.connection.connectedDevice == nil)
        #expect(b.panels.isSessionActive == false)
        #expect(b.panels.openPanel == nil)
        #expect(a.webRTCManager !== b.webRTCManager)
        #expect(a.inputManager !== b.inputManager)
        #expect(a.captureManager !== b.captureManager)
    }

    // MARK: - Shortcuts reach only their own session

    /// What keyboard capture does on ⇧⌘S, ⇧⌘R and ⌘C: hand the chord to its session.
    private func press(_ shortcut: InputManager.LocalShortcut, in session: ConsoleSession) {
        session.inputManager.onLocalShortcut?(shortcut)
    }

    @Test func aCapturedScreenshotChordReachesOnlyItsOwnSession() {
        let a = makeSession()
        let b = makeSession()

        press(.saveScreenshot, in: a)

        // No stream, so the attempt reports there is nothing to capture — in `a` alone.
        #expect(a.captureManager.notice?.title == "No video to capture")
        #expect(b.captureManager.notice == nil)
    }

    @Test func aCapturedRecordingChordReachesOnlyItsOwnSession() {
        let a = makeSession()
        let b = makeSession()

        press(.toggleRecording, in: b)

        #expect(b.captureManager.notice?.title == "Not connected")
        #expect(a.captureManager.notice == nil)
    }

    @Test func aCapturedCopyModeChordReachesOnlyItsOwnSession() {
        let a = makeSession()
        let b = makeSession()
        var toggles: [String] = []
        let subscriptions = [
            a.copyModeRequests.sink { _ in toggles.append("a") },
            b.copyModeRequests.sink { _ in toggles.append("b") },
        ]

        press(.toggleCopyMode, in: a)
        press(.toggleCopyMode, in: a)
        b.perform(.toggleCopyMode)

        #expect(toggles == ["a", "a", "b"])
        _ = subscriptions
    }

    // MARK: - Catalog changes reach only the session they concern

    @Test func catalogChangesLeaveConnectionsAlone() {
        let session = makeSession()
        let connected = Fixtures.device(host: "192.0.2.20")
        session.connection.connectedDevice = connected

        let manual = catalog.addManualDevice(host: "192.0.2.21", port: 443, type: .glinetComet)
        let saved = catalog.persistDevice(Fixtures.device(name: "Other", host: "192.0.2.22"))
        catalog.removeDevice(manual)
        catalog.forgetDevice(saved)
        catalog.cancelScan()

        #expect(session.connection.connectedDevice?.host == "192.0.2.20")
        #expect(session.panels.isSessionActive)
    }

    @Test func removingTheConnectedEntryClearsTheDeviceButNotTheClient() throws {
        let connection = SessionConnection(catalog: catalog)
        let device = catalog.addManualDevice(host: "192.0.2.70", port: 443, type: .glinetComet)
        connection.connectedDevice = device
        connection.glkvmClient = try GLKVMClient(device: device)

        catalog.removeDevice(device)

        #expect(connection.connectedDevice == nil)
        // As before the split: removal clears only the device.
        #expect(connection.glkvmClient != nil)
    }

    @Test func forgettingTheConnectedAddressClearsTheConnection() throws {
        let connection = SessionConnection(catalog: catalog)
        let saved = catalog.persistDevice(Fixtures.device(host: "192.0.2.80"))
        // Matched by host and port, not id.
        let connected = Fixtures.device(id: "something-else", host: "192.0.2.80")
        connection.connectedDevice = connected
        connection.glkvmClient = try GLKVMClient(device: connected)

        catalog.forgetDevice(saved)

        #expect(connection.connectedDevice == nil)
        #expect(connection.glkvmClient == nil)
    }

    @Test func forgettingADeviceReachesOnlyTheSessionConnectedToIt() throws {
        let a = makeSession()
        let b = makeSession()
        let savedA = catalog.persistDevice(Fixtures.device(name: "A", host: "192.0.2.30"))
        let deviceB = Fixtures.device(name: "B", host: "192.0.2.31")
        a.connection.connectedDevice = savedA
        a.connection.glkvmClient = try GLKVMClient(device: savedA)
        b.connection.connectedDevice = deviceB
        b.connection.glkvmClient = try GLKVMClient(device: deviceB)

        catalog.forgetDevice(savedA)

        #expect(a.connection.connectedDevice == nil)
        #expect(a.connection.glkvmClient == nil)
        #expect(a.panels.isSessionActive == false)
        #expect(b.connection.connectedDevice?.host == "192.0.2.31")
        #expect(b.connection.glkvmClient != nil)
        #expect(b.panels.isSessionActive)
    }

    @Test func aConnectionThatIsGoneIsNotKeptAliveByTheCatalog() {
        weak var released: SessionConnection?
        do {
            let connection = SessionConnection(catalog: catalog)
            released = connection
        }
        #expect(released == nil)

        // And the catalog carries on without it.
        let device = catalog.addManualDevice(host: "192.0.2.40", port: 443, type: .glinetComet)
        catalog.removeDevice(device)
        #expect(catalog.availableDevices.isEmpty)
    }
}
