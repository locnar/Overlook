import Foundation
import Testing
@testable import Overlook

/// What closing a console window does to its session, and what the window shows in its title.
/// The window itself is stood in for: these call what its attachment calls — `closeDecision` when
/// the operator asks to close, `stopRecordingAndDisconnect` when they confirm, `windowWillClose` as
/// it closes. Recordings are real files, in a scratch folder.
@MainActor
@Suite("Window lifecycle")
struct WindowLifecycleTests {
    let scratch = ScratchDefaults()
    let catalog: KVMDeviceManager

    init() {
        catalog = KVMDeviceManager(
            defaults: scratch.defaults,
            credentials: FakeCredentialStore(),
            trustStore: Fixtures.trustStore(scratch)
        )
    }

    private func makeSession(_ link: RecordingSessionLink) -> ConsoleSession {
        ConsoleSession(catalog: catalog, defaults: scratch.defaults, link: link, connectionLog: .inMemory())
    }

    private func makeRecordingsFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OverlookTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A session connected to "Rack 3" and recording into `folder`.
    private func recordingSession(_ link: RecordingSessionLink, into folder: URL) async -> ConsoleSession {
        let session = makeSession(link)
        _ = await session.connect(to: Fixtures.device(name: "Rack 3", host: "192.0.2.80"))
        session.captureManager.recordingsFolder = folder
        session.captureManager.startRecording()
        return session
    }

    // MARK: - Deciding

    @Test func whatClosingInvolvesFollowsTheSessionsState() {
        let device = Fixtures.device(name: "Rack 3")
        #expect(ConsoleSession.closeDecision(device: nil, isConnecting: false, isRecording: false) == .close)
        #expect(ConsoleSession.closeDecision(device: device, isConnecting: false, isRecording: false) == .disconnectAndClose)
        #expect(ConsoleSession.closeDecision(device: nil, isConnecting: true, isRecording: false) == .disconnectAndClose)
        #expect(ConsoleSession.closeDecision(device: device, isConnecting: false, isRecording: true) == .confirmStopRecording(deviceName: "Rack 3"))
    }

    @Test func returnAndEscapeBothCancelTheQuestion() {
        let buttons = StopRecordingQuestion.buttons
        #expect(StopRecordingQuestion.messageText(deviceName: "Rack 3") == "Rack 3 is recording")
        // Cancel comes first and holds Return, which makes it the default button.
        #expect(buttons.first?.answer == .cancel)
        #expect(buttons.filter { $0.keyEquivalent == "\r" }.map(\.answer) == [.cancel])
        // Stopping has no key at all: it takes a click.
        #expect(buttons.first { $0.answer == .stopRecordingAndClose }?.keyEquivalent == "")
        // Escape, which no button holds, cancels as well; other keys are left to the buttons.
        #expect(buttons.allSatisfy { $0.keyEquivalent != "\u{1b}" })
        #expect(StopRecordingQuestion.answer(forKeyCode: 53) == .cancel)   // Escape
        #expect(StopRecordingQuestion.answer(forKeyCode: 36) == nil)       // Return
        #expect(StopRecordingQuestion.answer(forKeyCode: 49) == nil)       // Space
    }

    @Test func aRecordingWindowAsksBeforeClosing() async throws {
        let folder = try makeRecordingsFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = await recordingSession(RecordingSessionLink(), into: folder)
        #expect(session.captureManager.isRecording)

        #expect(session.closeDecision == .confirmStopRecording(deviceName: "Rack 3"))
    }

    // MARK: - Closing

    @Test func closingADisconnectedWindowDoesNothingElse() {
        let link = RecordingSessionLink()
        let session = makeSession(link)
        #expect(session.closeDecision == .close)

        session.windowWillClose()

        #expect(link.steps.isEmpty)
        #expect(session.isClosed)
    }

    @Test func closingAConnectedWindowDisconnects() async {
        let link = RecordingSessionLink()
        let session = makeSession(link)
        _ = await session.connect(to: Fixtures.device())
        #expect(session.closeDecision == .disconnectAndClose)

        session.windowWillClose()

        #expect(Array(link.steps.suffix(2)) == [.hangUp, .stopInput])
        #expect(session.connection.connectedDevice == nil)
        #expect(session.panels.isSessionActive == false)
    }

    @Test func cancellingTheQuestionKeepsRecordingAndConnected() async throws {
        let folder = try makeRecordingsFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let link = RecordingSessionLink()
        let session = await recordingSession(link, into: folder)
        let stepsBefore = link.steps

        // Cancel: the window answers windowShouldClose with false and calls nothing else.
        _ = session.closeDecision

        #expect(session.captureManager.isRecording)
        #expect(session.connection.connectedDevice != nil)
        #expect(link.steps == stepsBefore)
        #expect(session.isClosed == false)
    }

    @Test func confirmingFinishesTheRecordingThenDisconnects() async throws {
        let folder = try makeRecordingsFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let link = RecordingSessionLink()
        let session = await recordingSession(link, into: folder)

        await session.stopRecordingAndDisconnect()

        #expect(session.captureManager.isRecording == false)
        #expect(session.connection.connectedDevice == nil)
        // The recording was finished before the hang-up, not by it.
        let hangUp = link.entries.first { $0.step == .hangUp }
        #expect(hangUp?.wasRecording == false)
        #expect(hangUp?.device?.name == "Rack 3")
        // With nothing to ask about any more, the close goes ahead.
        #expect(session.closeDecision == .close)
    }

    @Test func aConnectThatLandsAfterTheWindowClosedIsUndone() async {
        let link = RecordingSessionLink()
        let session = makeSession(link)
        link.duringSignIn = { session in session.windowWillClose() }

        let outcome = await session.connect(to: Fixtures.device())

        guard case .cancelled = outcome else {
            Issue.record("Expected the connect to be undone, got \(outcome)")
            return
        }
        #expect(link.steps.contains(.startInput) == false)
        #expect(link.steps.contains(.startStream(host: "192.0.2.10")) == false)
        #expect(link.steps.last == .stopInput)
        #expect(session.connection.connectedDevice == nil)
    }

    // MARK: - Quitting

    @Test func quittingFinishesARecordingBeforeShuttingDown() async throws {
        let folder = try makeRecordingsFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let link = RecordingSessionLink()
        let session = await recordingSession(link, into: folder)
        let registry = SessionRegistry(catalog: catalog) { _ in session }
        registry.add(registry.sessionForNewWindow())

        await registry.shutDownAll()

        #expect(link.entries.last?.step == .shutDown)
        #expect(link.entries.last?.wasRecording == false)
    }

    // MARK: - The operator disconnect is logged once

    /// How many times `session` has logged "Operator disconnect". Each line reaches the ring in a
    /// main-actor task of its own, so a marker is logged after everything else and waited for.
    private func operatorDisconnects(in session: ConsoleSession) async -> Int {
        let marker = "End of test \(UUID())"
        session.log.notice(.lifecycle, marker)
        var turns = 0
        while !session.log.store.events.contains(where: { $0.message == marker }), turns < 1_000 {
            await Task.yield()
            turns += 1
        }
        return session.log.store.events.filter {
            $0.message == "Operator disconnect" && $0.source?.sessionID == session.log.sessionID
        }.count
    }

    @Test func disconnectingLogsOnceEvenWhenTheWindowThenCloses() async {
        let link = RecordingSessionLink()
        let session = makeSession(link)
        _ = await session.connect(to: Fixtures.device())

        // The window's Disconnect button and the menu bar's both come here; the second finds
        // nothing left to disconnect.
        session.disconnect()
        session.disconnect()
        session.windowWillClose()

        #expect(await operatorDisconnects(in: session) == 1)
    }

    @Test func closingAConnectedWindowLogsOnce() async {
        let link = RecordingSessionLink()
        let session = makeSession(link)
        _ = await session.connect(to: Fixtures.device())

        session.windowWillClose()

        #expect(await operatorDisconnects(in: session) == 1)
    }

    @Test func quittingAndThenClosingTheWindowLogsOnce() async {
        let link = RecordingSessionLink()
        let session = makeSession(link)
        _ = await session.connect(to: Fixtures.device())
        let registry = SessionRegistry(catalog: catalog) { _ in session }
        registry.add(registry.sessionForNewWindow())

        await registry.shutDownAll()
        // AppKit closes the windows as the app exits, over a session quitting has hung up.
        session.windowWillClose()

        #expect(await operatorDisconnects(in: session) == 1)
        // Only the log changed: both still tear down, quitting first.
        #expect(Array(link.steps.suffix(3)) == [.shutDown, .hangUp, .stopInput])
    }

    @Test func closingTheWindowAndThenQuittingLogsOnce() async {
        let link = RecordingSessionLink()
        let session = makeSession(link)
        _ = await session.connect(to: Fixtures.device())

        session.windowWillClose()
        await session.shutDownForTermination()

        #expect(await operatorDisconnects(in: session) == 1)
    }

    @Test func aWindowClosedWhileConnectingLogsOnce() async {
        let link = RecordingSessionLink()
        let session = makeSession(link)
        link.duringSignIn = { session in session.windowWillClose() }

        // The close disconnects the connect under way, and the connect undoes itself as it lands.
        _ = await session.connect(to: Fixtures.device())

        #expect(link.steps.filter { $0 == .hangUp }.count == 2)
        #expect(await operatorDisconnects(in: session) == 1)
    }

    @Test func aDeviceTheCatalogLetGoOfLogsOnceAsTheSessionEnds() async throws {
        let forgetting = RecordingSessionLink(catalog: catalog)
        let forgotten = makeSession(forgetting)
        _ = await forgotten.connect(to: Fixtures.device(host: "192.0.2.90"))
        let saved = try #require(forgotten.connection.connectedDevice)

        // The catalog dropping the device is not the operator disconnecting.
        catalog.forgetDevice(saved)
        #expect(forgotten.connection.connectedDevice == nil)
        #expect(await operatorDisconnects(in: forgotten) == 0)

        await forgotten.shutDownForTermination()
        forgotten.windowWillClose()
        #expect(await operatorDisconnects(in: forgotten) == 1)

        let removing = RecordingSessionLink()
        let removed = makeSession(removing)
        let manual = catalog.addManualDevice(host: "192.0.2.91", port: 443, type: .glinetComet)
        _ = await removed.connect(to: manual)
        // The recording link connects under a saved id; point the session at the listed entry,
        // which is what a removal matches.
        removed.connection.connectedDevice = manual

        catalog.removeDevice(manual)
        #expect(removed.connection.connectedDevice == nil)
        removed.disconnect()
        removed.windowWillClose()
        await removed.shutDownForTermination()
        #expect(await operatorDisconnects(in: removed) == 1)
    }

    @Test func eachConnectionLogsItsOwnDisconnect() async {
        let link = RecordingSessionLink()
        let session = makeSession(link)

        _ = await session.connect(to: Fixtures.device())
        session.disconnect()
        _ = await session.connect(to: Fixtures.device())
        session.disconnect()

        #expect(await operatorDisconnects(in: session) == 2)
    }

    @Test func aSessionThatNeverConnectedLogsNoDisconnect() async {
        let link = RecordingSessionLink()
        link.signInError = KVMError.authenticationFailed
        let session = makeSession(link)

        _ = await session.connect(to: Fixtures.device())
        await session.shutDownForTermination()
        session.windowWillClose()

        #expect(await operatorDisconnects(in: session) == 0)
    }

    // MARK: - The title

    @Test func theWindowTitleNamesTheDevice() {
        let device = Fixtures.device(name: "Rack 3")
        #expect(ContentView.windowTitlePrefix(device: device, isConnected: true) == "Overlook - Rack 3 / Connected")
        #expect(ContentView.windowTitlePrefix(device: device, isConnected: false) == "Overlook - Rack 3 / Disconnected")
        #expect(ContentView.windowTitlePrefix(device: nil, isConnected: false) == "Overlook - Overlook / Disconnected")
    }
}
