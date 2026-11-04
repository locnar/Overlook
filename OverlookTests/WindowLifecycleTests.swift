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

    // MARK: - The title

    @Test func theWindowTitleNamesTheDevice() {
        let device = Fixtures.device(name: "Rack 3")
        #expect(ContentView.windowTitlePrefix(device: device, isConnected: true) == "Overlook - Rack 3 / Connected")
        #expect(ContentView.windowTitlePrefix(device: device, isConnected: false) == "Overlook - Rack 3 / Disconnected")
        #expect(ContentView.windowTitlePrefix(device: nil, isConnected: false) == "Overlook - Overlook / Disconnected")
    }
}
