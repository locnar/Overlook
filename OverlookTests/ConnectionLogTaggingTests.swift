import Foundation
import Testing
@testable import Overlook

/// Lines tagged with the session and device they came from: what a session's objects log, how the
/// file and copied text show it, and what each window's log panel, toolbar dot and last-problem
/// summary take from the shared ring. Every log here is kept in memory, so nothing reaches the
/// operator's log file or the unified log.
@MainActor
@Suite("Connection log tagging")
struct ConnectionLogTaggingTests {
    let scratch = ScratchDefaults()
    let catalog: KVMDeviceManager
    let log = ConnectionLog.inMemory()

    init() {
        catalog = KVMDeviceManager(
            defaults: scratch.defaults,
            credentials: FakeCredentialStore(),
            trustStore: Fixtures.trustStore(scratch)
        )
    }

    private func makeSession() -> ConsoleSession {
        ConsoleSession(
            catalog: catalog,
            defaults: scratch.defaults,
            link: RecordingSessionLink(catalog: catalog),
            audioPreferences: AudioPreferences(defaults: scratch.defaults),
            connectionLog: log
        )
    }

    /// Each line reaches the ring in a main-actor task of its own; wait for `count` of them.
    private func settle(_ count: Int) async {
        var turns = 0
        while log.store.events.count < count, turns < 1_000 {
            await Task.yield()
            turns += 1
        }
    }

    private func event(
        _ id: UInt64,
        _ level: ConnectionLogLevel = .info,
        from source: ConnectionLogSource? = nil,
        _ message: String = "",
        category: ConnectionLogCategory = .lifecycle
    ) -> ConnectionLogEvent {
        ConnectionLogEvent(
            id: id,
            date: Date(timeIntervalSince1970: TimeInterval(id)),
            level: level,
            category: category,
            message: message.isEmpty ? "event \(id)" : message,
            source: source
        )
    }

    // MARK: - Tagging

    @Test func aSessionsLinesNameTheSessionAndDeviceAndTheAppsDoNot() async {
        let sessionLog = SessionLog(destination: log)
        sessionLog.deviceLabel = "192.168.0.131"
        sessionLog.notice(.ice, "Video ICE state: connected")
        log.info(.lifecycle, "Scan started")
        await settle(2)

        let session = log.store.events.first { $0.message == "Video ICE state: connected" }
        #expect(session?.source == ConnectionLogSource(sessionID: sessionLog.sessionID, device: "192.168.0.131"))
        #expect(session?.category == .ice)
        #expect(session?.level == .notice)

        let app = log.store.events.first { $0.message == "Scan started" }
        #expect(app != nil)
        #expect(app?.source == nil)
    }

    @Test func aDeviceIsNamedByItsHostWithTheOddPortOnly() {
        #expect(SessionLog.label(host: "192.168.0.131", port: 443) == "192.168.0.131")
        #expect(SessionLog.label(host: "mdesktopkvm", port: 443) == "mdesktopkvm")
        // A Tailscale name in full: the bare MagicDNS name is a different address.
        #expect(SessionLog.label(host: "mdesktopkvm.tail235926.ts.net", port: 443) == "mdesktopkvm.tail235926.ts.net")
        #expect(SessionLog.label(host: "mdesktopkvm.tail235926.ts.net", port: 80) == "mdesktopkvm.tail235926.ts.net")
        #expect(SessionLog.label(host: "mdesktopkvm.tail235926.ts.net", port: 8443) == "mdesktopkvm.tail235926.ts.net:8443")
        #expect(SessionLog.label(host: "kvm.local", port: 80) == "kvm.local")
        #expect(SessionLog.label(host: "kvm.local", port: 8443) == "kvm.local:8443")
        #expect(SessionLog.label(host: "fe80::1", port: 8443) == "[fe80::1]:8443")
    }

    @Test func everyObjectOfASessionLogsAsThatSessionAndItsDevice() async {
        let session = makeSession()
        #expect(session.webRTCManager.log === session.log)
        #expect(session.inputManager.log === session.log)

        _ = await session.connect(to: Fixtures.device(nickname: "Rack 8", host: "192.0.2.88", port: 8443))
        #expect(session.log.deviceLabel == "192.0.2.88:8443")

        // The operator disconnect line, which the session logs as it hangs up.
        session.disconnect()
        // "Connecting via", "Connected via", then the disconnect.
        await settle(3)
        let line = log.store.events.first { $0.message == "Operator disconnect" }
        #expect(line?.source == ConnectionLogSource(sessionID: session.log.sessionID, device: "192.0.2.88:8443"))
    }

    @Test func theFileAndCopiedTextNameTheDeviceAfterTheCategory() {
        let source = ConnectionLogSource(sessionID: UUID(), device: "192.168.0.131")
        let tagged = event(1, .notice, from: source, "Video ICE state: connected", category: .ice)
        let untagged = event(2, .info, "Scan started")

        #expect(ConnectionLog.fileLine(for: tagged).hasSuffix("  NOTE  [ice] [192.168.0.131] Video ICE state: connected"))
        #expect(ConnectionLog.fileLine(for: untagged).hasSuffix("  INFO  [lifecycle] Scan started"))
        #expect(ConnectionLogRow.plainText(tagged).hasSuffix("  NOTE  [ice] [192.168.0.131] Video ICE state: connected"))
        #expect(ConnectionLogRow.plainText(untagged).hasSuffix("  INFO  [lifecycle] Scan started"))

        // A session's line from before it first connected has no device to name.
        let early = event(3, .info, from: ConnectionLogSource(sessionID: UUID(), device: nil), "HID link connecting", category: .hid)
        #expect(ConnectionLog.fileLine(for: early).hasSuffix("  INFO  [hid] HID link connecting"))
    }

    // MARK: - The panel's filter

    @Test func thisWindowShowsItsSessionAndTheAppAndAllDevicesShowsEverything() {
        let a = UUID()
        let b = UUID()
        let events = [
            event(4, .warning, from: ConnectionLogSource(sessionID: b, device: "mdesktopkvm"), category: .ice),
            event(3, .info, "Scan started"),
            event(2, .debug, from: ConnectionLogSource(sessionID: a, device: "192.168.0.131"), category: .signaling),
            event(1, .info, from: ConnectionLogSource(sessionID: a, device: "192.168.0.131"), category: .ice),
        ]

        let thisWindow = ConnectionLogFilter(scope: .session(a), minimumLevel: .debug, category: nil)
        #expect(thisWindow.apply(to: events).map(\.id) == [3, 2, 1])
        #expect(thisWindow.showsDeviceTags == false)

        let allDevices = ConnectionLogFilter(scope: .allDevices, minimumLevel: .debug, category: nil)
        #expect(allDevices.apply(to: events).map(\.id) == [4, 3, 2, 1])
        #expect(allDevices.showsDeviceTags)

        // Level and category still narrow within either scope.
        #expect(ConnectionLogFilter(scope: .session(a), minimumLevel: .info, category: nil).apply(to: events).map(\.id) == [3, 1])
        #expect(ConnectionLogFilter(scope: .allDevices, minimumLevel: .debug, category: .ice).apply(to: events).map(\.id) == [4, 1])
        #expect(ConnectionLogFilter(scope: .allDevices, minimumLevel: .warning, category: nil).apply(to: events).map(\.id) == [4])
    }

    @Test func thePanelOpensOnThisWindow() {
        let a = UUID()
        #expect(ConnectionLogFilter.scope(showsAllDevices: false, sessionID: a) == .session(a))
        #expect(ConnectionLogFilter.scope(showsAllDevices: true, sessionID: a) == .allDevices)
        // A view with no session to narrow to shows everything rather than nothing.
        #expect(ConnectionLogFilter.scope(showsAllDevices: false, sessionID: nil) == .allDevices)
    }

    @Test func anEmptyListSaysWhyInEitherScope() {
        let thisWindow = ConnectionLogFilter(scope: .session(UUID()), minimumLevel: .info, category: nil)
        let allDevices = ConnectionLogFilter(scope: .allDevices, minimumLevel: .info, category: nil)
        #expect(thisWindow.emptyMessage(hasEventsInScope: false).hasPrefix("Nothing recorded for this window yet."))
        #expect(allDevices.emptyMessage(hasEventsInScope: false).hasPrefix("Nothing recorded yet."))
        #expect(thisWindow.emptyMessage(hasEventsInScope: true) == "No events at this level.")
        #expect(ConnectionLogFilter(scope: .allDevices, minimumLevel: .info, category: .hid).emptyMessage(hasEventsInScope: true)
            == "No hid events at this level.")
    }

    // MARK: - Each window's problems

    @Test func eachWindowSummarizesItsOwnLastProblem() {
        let a = UUID()
        let b = UUID()
        let store = ConnectionLogStore()
        store.append(event(1, .warning, from: ConnectionLogSource(sessionID: a, device: "192.168.0.131"), "a's problem"))
        store.append(event(2, .error, from: ConnectionLogSource(sessionID: b, device: "mdesktopkvm"), "b's problem"))

        #expect(store.lastProblem(in: .session(a))?.message == "a's problem")
        #expect(store.lastProblem(in: .session(b))?.message == "b's problem")
        #expect(store.lastProblem(in: .allDevices)?.message == "b's problem")

        // The app's own problems are every window's.
        store.append(event(3, .warning, "app problem"))
        #expect(store.lastProblem(in: .session(a))?.message == "app problem")
        #expect(store.lastProblem(in: .session(b))?.message == "app problem")
    }

    @Test func eachWindowsDotCountsItsOwnProblemsAndClearsOnItsOwn() {
        let a = UUID()
        let b = UUID()
        let store = ConnectionLogStore()
        store.append(event(1, .warning, from: ConnectionLogSource(sessionID: a, device: "192.168.0.131")))
        store.append(event(2, .error, from: ConnectionLogSource(sessionID: b, device: "mdesktopkvm")))
        store.append(event(3, .error, from: ConnectionLogSource(sessionID: b, device: "mdesktopkvm")))
        store.append(event(4, .warning))
        #expect(store.unseenProblemCount(for: a) == 2)
        #expect(store.unseenProblemCount(for: b) == 3)

        // Opening A's log clears A's dot only, and keeps it clear while open.
        store.beginViewingProblems(for: a)
        store.append(event(5, .error, from: ConnectionLogSource(sessionID: a, device: "192.168.0.131")))
        #expect(store.unseenProblemCount(for: a) == 0)
        #expect(store.unseenProblemCount(for: b) == 3)
        store.endViewingProblems(for: a)
        #expect(store.unseenProblemCount(for: a) == 0)

        store.append(event(6, .warning, from: ConnectionLogSource(sessionID: b, device: "mdesktopkvm")))
        #expect(store.unseenProblemCount(for: a) == 0)
        #expect(store.unseenProblemCount(for: b) == 4)
    }

    @Test func clearingThisWindowLeavesTheOtherWindowsLines() {
        let a = UUID()
        let b = UUID()
        let store = ConnectionLogStore()
        store.append(event(1, .error, from: ConnectionLogSource(sessionID: a, device: "192.168.0.131")))
        store.append(event(2, .error, from: ConnectionLogSource(sessionID: b, device: "mdesktopkvm")))
        store.append(event(3, .info))

        store.clear(.session(a))
        #expect(store.events.map(\.id) == [2])
        #expect(store.lastProblem(in: .session(a)) == nil)
        #expect(store.lastProblem(in: .session(b))?.id == 2)

        store.clear(.allDevices)
        #expect(store.events.isEmpty)
        #expect(store.lastProblem(in: .allDevices) == nil)
    }
}
