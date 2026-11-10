import Foundation
import Testing
@testable import Overlook

// MARK: - A Janus signaling socket, answered in the test

/// Stands in for the WebSocket under a connection's Janus signaling sends. It records every frame
/// it is given, and can be told to hold frames for good (a connection that has stopped draining)
/// or to take a moment over each one (so frames sent at the same time would overlap).
final class FakeSignalingSocket: SignalingSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    private var inFlight = 0
    private var mostInFlight = 0
    private var _holdsFrames = false
    private var _sendDelay: Duration?

    /// New frames are never taken: their completion is never called.
    var holdsFrames: Bool {
        get { lock.withLock { _holdsFrames } }
        set { lock.withLock { _holdsFrames = newValue } }
    }

    /// How long the socket takes over each frame; nil to take it at once.
    var sendDelay: Duration? {
        get { lock.withLock { _sendDelay } }
        set { lock.withLock { _sendDelay = newValue } }
    }

    /// Every frame's text, in the order the socket was given them.
    var frames: [String] { lock.withLock { recorded } }
    /// The `janus` verb of each frame.
    var verbs: [String] {
        frames.compactMap { text in
            guard let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return object["janus"] as? String
        }
    }
    /// The most frames the socket was ever asked to hold at the same time.
    var mostFramesAtOnce: Int { lock.withLock { mostInFlight } }

    func send(_ message: URLSessionWebSocketTask.Message, completion: @escaping @Sendable (Error?) -> Void) {
        let text: String
        switch message {
        case .string(let string): text = string
        case .data(let data): text = String(decoding: data, as: UTF8.self)
        @unknown default: text = ""
        }
        let (holds, delay): (Bool, Duration?) = lock.withLock {
            recorded.append(text)
            inFlight += 1
            mostInFlight = max(mostInFlight, inFlight)
            return (_holdsFrames, _sendDelay)
        }
        guard !holds else { return }
        let finish: @Sendable () -> Void = { [self] in
            lock.withLock { inFlight -= 1 }
            completion(nil)
        }
        if let delay {
            DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(Int(delay / .nanoseconds(1)))) { finish() }
        } else {
            DispatchQueue.global().async { finish() }
        }
    }
}

typealias SignalingTiming = JanusSignalingSender.Timing
typealias SignalingError = JanusSignalingSender.SendError

extension SignalingTiming {
    /// Long enough that nothing fires unless a test asks for it.
    static func testing(sendTimeout: Duration = .seconds(30), openTimeout: Duration = .seconds(30)) -> SignalingTiming {
        SignalingTiming(sendTimeout: sendTimeout, openTimeout: openTimeout)
    }
}

/// Counts what a sender reports about its socket.
@MainActor
final class StuckReports {
    private(set) var reports: [String] = []
    var count: Int { reports.count }

    func note(_ what: String, _ deadline: Duration) {
        reports.append("\(what) \(Int(deadline / .milliseconds(1))) ms")
    }
}

private func frame(_ verb: String, _ index: Int) -> URLSessionWebSocketTask.Message {
    .string(#"{"janus":"\#(verb)","transaction":"t\#(index)"}"#)
}

// MARK: - The sender on its own

/// The signaling socket's send path: one frame at a time and in order, a deadline on each, and a
/// close that never waits for a stuck socket.
@MainActor
@Suite("Janus signaling sends")
struct JanusSignalingSenderTests {
    private func sender(
        on socket: FakeSignalingSocket,
        timing: SignalingTiming,
        reports: StuckReports
    ) -> JanusSignalingSender {
        JanusSignalingSender(socket: socket, timing: timing) { what, deadline in
            reports.note(what, deadline)
        }
    }

    @Test func framesGoOutOneAtATimeInTheOrderTheyWereSent() async throws {
        // The bug this guards: a keepalive, trickled candidates and the answer were all handed to
        // the socket at once, with nothing keeping their order.
        let socket = FakeSignalingSocket()
        socket.sendDelay = .milliseconds(2)
        let reports = StuckReports()
        let signaling = sender(on: socket, timing: .testing(), reports: reports)

        var sends: [Task<Void, Error>] = []
        var expected: [String] = []
        for index in 0..<30 {
            let verb = ["keepalive", "trickle", "message"][index % 3]
            expected.append(#"{"janus":"\#(verb)","transaction":"t\#(index)"}"#)
            sends.append(Task { try await signaling.send(frame(verb, index), describing: verb) })
        }
        for send in sends {
            try await send.value
        }

        #expect(socket.frames == expected)
        #expect(socket.mostFramesAtOnce == 1)
        #expect(reports.count == 0)
        #expect(signaling.isClosed == false)
    }

    @Test func aFrameTheSocketNeverTakesTimesOutAndIsReportedOnce() async throws {
        let socket = FakeSignalingSocket()
        let reports = StuckReports()
        let signaling = sender(
            on: socket,
            timing: .testing(sendTimeout: .milliseconds(200), openTimeout: .milliseconds(200)),
            reports: reports
        )
        try await signaling.send(frame("create", 0), describing: "create")

        socket.holdsFrames = true
        let start = ContinuousClock.now
        await #expect(throws: SignalingError.timedOut) {
            try await signaling.send(frame("keepalive", 1), describing: "keepalive")
        }

        #expect(ContinuousClock.now - start < .seconds(2))
        #expect(signaling.isClosed)
        #expect(reports.reports == ["keepalive 200 ms"])
    }

    @Test func framesQueuedBehindAStuckOneFailAtOnceWhenItTimesOut() async throws {
        let socket = FakeSignalingSocket()
        let reports = StuckReports()
        let signaling = sender(
            on: socket,
            timing: .testing(sendTimeout: .milliseconds(300), openTimeout: .milliseconds(300)),
            reports: reports
        )
        try await signaling.send(frame("create", 0), describing: "create")
        socket.holdsFrames = true

        let stuck = Task { try await signaling.send(frame("keepalive", 1), describing: "keepalive") }
        #expect(await waitUntil { socket.frames.count == 2 })
        let queued = [
            Task { try await signaling.send(frame("trickle", 2), describing: "trickle") },
            Task { try await signaling.send(frame("message", 3), describing: "message start") },
        ]
        let start = ContinuousClock.now

        await #expect(throws: SignalingError.timedOut) { try await stuck.value }
        for send in queued {
            await #expect(throws: SignalingError.closed) { try await send.value }
        }
        #expect(ContinuousClock.now - start < .seconds(2))
        // The queued frames never reached the socket: they were waiting their turn when it was
        // found dead. And the dead socket is reported once, not once per frame.
        #expect(socket.frames.count == 2)
        try await Task.sleep(for: .milliseconds(400))
        #expect(reports.reports == ["keepalive 300 ms"])
    }

    @Test func theFirstFrameHasTheOpenDeadline() async throws {
        // The first frame waits for the handshake, so it gets the longer of the two deadlines.
        let socket = FakeSignalingSocket()
        socket.holdsFrames = true
        let reports = StuckReports()
        let signaling = sender(
            on: socket,
            timing: .testing(sendTimeout: .milliseconds(100), openTimeout: .milliseconds(400)),
            reports: reports
        )
        await #expect(throws: SignalingError.timedOut) {
            try await signaling.send(frame("create", 0), describing: "create")
        }
        #expect(reports.reports == ["create 400 ms"])
    }

    @Test func closingDuringAStuckFrameReturnsAtOnceAndReportsNothing() async throws {
        let socket = FakeSignalingSocket()
        socket.holdsFrames = true  // stuck for good: the socket never gives the frame back
        let reports = StuckReports()
        let signaling = sender(
            on: socket,
            timing: .testing(sendTimeout: .milliseconds(300), openTimeout: .milliseconds(300)),
            reports: reports
        )

        let stuck = Task { try await signaling.send(frame("create", 0), describing: "create") }
        #expect(await waitUntil { socket.frames.count == 1 })
        let queued = Task { try await signaling.send(frame("keepalive", 1), describing: "keepalive") }
        try await Task.sleep(for: .milliseconds(20))

        let start = ContinuousClock.now
        signaling.close()
        #expect(ContinuousClock.now - start < .milliseconds(500))

        await #expect(throws: SignalingError.closed) { try await stuck.value }
        await #expect(throws: SignalingError.closed) { try await queued.value }
        #expect(ContinuousClock.now - start < .milliseconds(500))

        // Past the deadline the stuck frame would have had: a close is not a dead socket.
        try await Task.sleep(for: .milliseconds(450))
        #expect(reports.count == 0)
        #expect(socket.frames.count == 1)
    }

    @Test func aSendAfterCloseNeverReachesTheSocket() async throws {
        let socket = FakeSignalingSocket()
        let reports = StuckReports()
        let signaling = sender(on: socket, timing: .testing(), reports: reports)
        signaling.close()

        await #expect(throws: SignalingError.closed) {
            try await signaling.send(frame("keepalive", 0), describing: "keepalive")
        }
        #expect(socket.frames.isEmpty)
        #expect(reports.count == 0)
    }

    @Test func framesAreNamedByVerbAndPluginRequest() {
        #expect(JanusSignalingSender.describe(["janus": "keepalive"]) == "keepalive")
        #expect(JanusSignalingSender.describe(["janus": "trickle", "candidate": ["completed": true]]) == "trickle")
        #expect(JanusSignalingSender.describe(["janus": "message", "body": ["request": "start"]]) == "message start")
        #expect(JanusSignalingSender.describe([:]) == "frame")
    }
}

// MARK: - Through the manager

/// A connection's sender as the manager makes it: a stuck send reconnects the connection once,
/// and a teardown during one neither waits for it nor reconnects.
@MainActor
@Suite("Janus signaling sends through the manager")
struct ManagerSignalingSendTests {
    let scratch = ScratchDefaults()
    let log = SessionLog(destination: .inMemory())
    let manager: WebRTCManager

    init() {
        manager = WebRTCManager(audioPreferences: AudioPreferences(defaults: scratch.defaults), log: log)
    }

    private func count(_ text: String) -> Int {
        log.store.events(in: .allDevices).filter { $0.message.contains(text) }.count
    }

    /// The reconnect path's entry: with no device to reconnect to (no connect ran), it logs that it
    /// was asked and stands down, so nothing here reaches the network.
    private let reconnectRequested = "Reconnect suppressed (Signaling send timed out)"

    @Test func aStuckSendReconnectsTheConnectionOnce() async throws {
        let socket = FakeSignalingSocket()
        let signaling = manager.makeSignalingSender(
            for: socket,
            timing: .testing(sendTimeout: .milliseconds(200), openTimeout: .milliseconds(200))
        )
        try await signaling.send(frame("create", 0), describing: "create")
        socket.holdsFrames = true

        let sends = (1...3).map { index in
            Task { try await signaling.send(frame("keepalive", index), describing: "keepalive") }
        }
        for send in sends {
            _ = try? await send.value
        }

        #expect(await waitUntil { count(reconnectRequested) == 1 })
        #expect(count("Signaling socket did not take a keepalive frame within 200 ms") == 1)
        try await Task.sleep(for: .milliseconds(300))
        #expect(count(reconnectRequested) == 1)
        #expect(count("did not take a") == 1)
    }

    @Test func aTeardownDuringAStuckSendReturnsAtOnceAndDoesNotReconnect() async throws {
        let socket = FakeSignalingSocket()
        socket.holdsFrames = true
        let signaling = manager.makeSignalingSender(
            for: socket,
            timing: .testing(sendTimeout: .milliseconds(200), openTimeout: .milliseconds(200))
        )
        let stuck = Task { try await signaling.send(frame("create", 0), describing: "create") }
        let queued = Task { try await signaling.send(frame("keepalive", 1), describing: "keepalive") }
        #expect(await waitUntil { socket.frames.count == 1 })

        let start = ContinuousClock.now
        manager.disconnect()
        #expect(ContinuousClock.now - start < .milliseconds(500))
        await #expect(throws: SignalingError.closed) { try await stuck.value }
        await #expect(throws: SignalingError.closed) { try await queued.value }
        #expect(ContinuousClock.now - start < .milliseconds(500))

        // Well past the deadline the stuck frame had.
        try await Task.sleep(for: .milliseconds(400))
        #expect(count("did not take a") == 0)
        #expect(count("Signaling send timed out") == 0)
    }

    @Test func aSendAfterTeardownIsANoOp() async throws {
        let socket = FakeSignalingSocket()
        let signaling = manager.makeSignalingSender(for: socket, timing: .testing())
        manager.disconnect()

        await #expect(throws: SignalingError.closed) {
            try await signaling.send(frame("trickle", 0), describing: "trickle")
        }
        #expect(socket.frames.isEmpty)
        try await Task.sleep(for: .milliseconds(50))
        #expect(count("Signaling send timed out") == 0)
    }
}
