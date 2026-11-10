import AppKit
import Foundation
import Testing
@testable import Overlook

// MARK: - A device's HID socket, answered in the test

/// Stands in for the WebSocket under a HID client. It records every frame it is given, and can be
/// told to hold frames (a connection that has stopped draining), to leave pings unanswered (one
/// that has gone silent), or to take a moment over each frame (so frames sent at the same time
/// would overlap). It opens with a greeting, as kvmd sends its state when a socket opens.
final class FakeHIDSocket: HIDSocket, @unchecked Sendable {
    enum Frame: Equatable {
        case text(String)
        case binary([UInt8])

        var isPing: Bool {
            if case .text(let text) = self { return text.contains(#""event_type":"ping""#) }
            return false
        }

        /// A key report: the key's name and whether it went down.
        var key: (name: String, isDown: Bool)? {
            guard case .binary(let bytes) = self, bytes.count > 2, bytes[0] == 0x01 else { return nil }
            return (String(decoding: bytes[2...], as: UTF8.self), bytes[1] == 0x01)
        }

        /// "KeyA down", "ShiftLeft up"; nil for anything but a key report.
        var keyText: String? {
            key.map { "\($0.name) \($0.isDown ? "down" : "up")" }
        }

        /// The report that clears every key on the target.
        var clearsKeyboard: Bool { self == .binary([0x01, 0x00]) }
    }

    private let lock = NSLock()
    private var recorded: [Frame] = []
    private var inFlight = 0
    private var mostInFlight = 0
    private var held: [@Sendable (Error?) -> Void] = []
    private var inbox: [URLSessionWebSocketTask.Message] = []
    private var receiver: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?
    private var isClosed = false
    private var closedHow: String?

    private var _holdsFrames = false
    private var _completesHeldFramesWhenClosed = true
    private var _answersPings = true
    private var _sendDelay: Duration?

    /// New frames are held until the socket is closed.
    var holdsFrames: Bool {
        get { lock.withLock { _holdsFrames } }
        set { lock.withLock { _holdsFrames = newValue } }
    }
    /// Whether closing fails the held frames, as URLSession does. Off for a socket so stuck that
    /// it never gives them back.
    var completesHeldFramesWhenClosed: Bool {
        get { lock.withLock { _completesHeldFramesWhenClosed } }
        set { lock.withLock { _completesHeldFramesWhenClosed = newValue } }
    }
    var answersPings: Bool {
        get { lock.withLock { _answersPings } }
        set { lock.withLock { _answersPings = newValue } }
    }
    /// How long the socket takes over each frame; nil to take it at once.
    var sendDelay: Duration? {
        get { lock.withLock { _sendDelay } }
        set { lock.withLock { _sendDelay = newValue } }
    }

    var frames: [Frame] { lock.withLock { recorded } }
    var keyFrames: [Frame] { frames.filter { $0.key != nil } }
    var pingCount: Int { frames.filter(\.isPing).count }
    /// The most frames the socket was ever asked to hold at the same time.
    var mostFramesAtOnce: Int { lock.withLock { mostInFlight } }
    /// "aborted", "closed" (with a close frame), or nil while open.
    var howClosed: String? { lock.withLock { closedHow } }

    func resume() {
        deliver(#"{"event_type":"hid","event":{}}"#)
    }

    func send(_ message: URLSessionWebSocketTask.Message, completion: @escaping @Sendable (Error?) -> Void) {
        enum Next {
            case fail
            case hold
            case take(after: Duration?, pong: Bool)
        }
        let frame: Frame
        switch message {
        case .string(let text): frame = .text(text)
        case .data(let data): frame = .binary(Array(data))
        @unknown default: frame = .text("")
        }
        let next: Next = lock.withLock {
            recorded.append(frame)
            guard !isClosed else { return .fail }
            inFlight += 1
            mostInFlight = max(mostInFlight, inFlight)
            if _holdsFrames {
                held.append(completion)
                return .hold
            }
            return .take(after: _sendDelay, pong: frame.isPing && _answersPings)
        }
        switch next {
        case .fail:
            completion(URLError(.cancelled))
        case .hold:
            break
        case .take(let delay, let pong):
            let finish: @Sendable () -> Void = { [self] in
                lock.withLock { inFlight -= 1 }
                completion(nil)
                if pong {
                    deliver(#"{"event_type":"pong","event":{}}"#)
                }
            }
            if let delay {
                DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(Int(delay / .nanoseconds(1)))) { finish() }
            } else {
                DispatchQueue.global().async { finish() }
            }
        }
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await withCheckedThrowingContinuation { continuation in
            let ready: Result<URLSessionWebSocketTask.Message, Error>? = lock.withLock {
                if isClosed { return .failure(URLError(.cancelled)) }
                if !inbox.isEmpty { return .success(inbox.removeFirst()) }
                receiver = continuation
                return nil
            }
            if let ready {
                continuation.resume(with: ready)
            }
        }
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        close(how: "closed")
    }

    func abort() {
        close(how: "aborted")
    }

    private func deliver(_ text: String) {
        let waiting: CheckedContinuation<URLSessionWebSocketTask.Message, Error>? = lock.withLock {
            guard !isClosed else { return nil }
            guard let receiver else {
                inbox.append(.string(text))
                return nil
            }
            self.receiver = nil
            return receiver
        }
        waiting?.resume(returning: .string(text))
    }

    private func close(how: String) {
        let (waiting, failing) = lock.withLock {
            () -> (CheckedContinuation<URLSessionWebSocketTask.Message, Error>?, [@Sendable (Error?) -> Void]) in
            guard !isClosed else { return (nil, []) }
            isClosed = true
            closedHow = how
            let waiting = receiver
            receiver = nil
            var failing: [@Sendable (Error?) -> Void] = []
            if _completesHeldFramesWhenClosed {
                failing = held
                held.removeAll()
                inFlight -= failing.count
            }
            return (waiting, failing)
        }
        waiting?.resume(throwing: URLError(.cancelled))
        failing.forEach { $0(URLError(.cancelled)) }
    }
}

/// Hands out a new `FakeHIDSocket` each time a HID client connects, and keeps them all.
final class FakeHIDSockets: @unchecked Sendable {
    private let lock = NSLock()
    private var made: [FakeHIDSocket] = []

    var all: [FakeHIDSocket] { lock.withLock { made } }
    var count: Int { all.count }

    func make() -> FakeHIDSocket {
        let socket = FakeHIDSocket()
        lock.withLock { made.append(socket) }
        return socket
    }
}

typealias HIDTiming = GLKVMClient.WebSocketClient.Timing
typealias HIDError = GLKVMClient.WebSocketClient.WebSocketError

extension HIDTiming {
    /// Long enough that nothing fires unless a test asks for it.
    static func testing(
        pingInterval: Duration = .seconds(60),
        sendTimeout: Duration = .seconds(30),
        openTimeout: Duration = .seconds(30),
        pongDeadline: Duration = .seconds(60)
    ) -> HIDTiming {
        HIDTiming(pingInterval: pingInterval, sendTimeout: sendTimeout, openTimeout: openTimeout, pongDeadline: pongDeadline)
    }
}

// MARK: - The HID client on its own

/// The HID client's send path, deadlines and pings, on a socket answered in the test.
@MainActor
@Suite("HID socket")
struct HIDSocketTests {
    let log = SessionLog(destination: .inMemory())

    private func client(on socket: FakeHIDSocket, timing: HIDTiming) -> GLKVMClient.WebSocketClient {
        GLKVMClient.WebSocketClient(
            session: GLKVMURLSession(URLSession(configuration: .ephemeral)),
            request: URLRequest(url: URL(string: "wss://hid.invalid/api/ws")!),
            timing: timing,
            log: log,
            makeSocket: { _ in socket }
        )
    }

    @MainActor
    final class StreamWatch {
        private(set) var hasEnded = false
        private var task: Task<Void, Never>?

        init(_ client: GLKVMClient.WebSocketClient) {
            task = Task { @MainActor [weak self] in
                for await _ in client.events {}
                self?.hasEnded = true
            }
        }
    }

    private func logged(_ text: String) -> Bool {
        log.store.events(in: .allDevices).contains { $0.message.contains(text) }
    }

    @Test func aFrameTheSocketNeverTakesTimesOutAndClosesIt() async throws {
        let socket = FakeHIDSocket()
        let ws = client(on: socket, timing: .testing(sendTimeout: .milliseconds(200), openTimeout: .milliseconds(200)))
        await ws.connect()
        let stream = StreamWatch(ws)
        try await ws.sendHidKey(key: "KeyA", state: true)
        #expect(await ws.isConnected)

        socket.holdsFrames = true
        let start = ContinuousClock.now
        await #expect(throws: HIDError.sendTimedOut) {
            try await ws.sendHidKey(key: "KeyA", state: false)
        }

        #expect(ContinuousClock.now - start < .seconds(2))
        #expect(socket.howClosed == "aborted")
        #expect(await ws.isConnected == false)
        // The owner hears of it the way it hears of any drop, and reconnects.
        #expect(await waitUntil { stream.hasEnded })
        #expect(await waitUntil { logged("did not take a HID report frame within 200 ms") })
    }

    @Test func framesQueuedBehindAStuckOneFailAtOnceWhenItTimesOut() async throws {
        let socket = FakeHIDSocket()
        let ws = client(on: socket, timing: .testing(sendTimeout: .milliseconds(300), openTimeout: .milliseconds(300)))
        await ws.connect()
        socket.holdsFrames = true

        let stuck = Task { try await ws.sendHidKey(key: "KeyA", state: true) }
        #expect(await waitUntil { socket.frames.count == 1 })
        let queued = Task { try await ws.sendHidKey(key: "KeyB", state: true) }
        let start = ContinuousClock.now

        await #expect(throws: HIDError.sendTimedOut) { try await stuck.value }
        await #expect(throws: HIDError.notConnected) { try await queued.value }
        #expect(ContinuousClock.now - start < .seconds(2))
        // The queued frame never reached the socket: it was waiting its turn when the socket closed.
        #expect(socket.frames.count == 1)
    }

    @Test func closingDuringAStuckFrameReturnsAtOnce() async throws {
        let socket = FakeHIDSocket()
        socket.holdsFrames = true
        socket.completesHeldFramesWhenClosed = false  // stuck for good, even after the close
        let ws = client(on: socket, timing: .testing())
        await ws.connect()

        let stuck = Task { try await ws.sendHidKey(key: "KeyA", state: true) }
        #expect(await waitUntil { socket.frames.count == 1 })
        let queued = Task { try await ws.sendHidKey(key: "KeyA", state: false) }
        try await Task.sleep(for: .milliseconds(50))

        let start = ContinuousClock.now
        await ws.disconnect()
        #expect(ContinuousClock.now - start < .milliseconds(500))

        await #expect(throws: HIDError.notConnected) { try await stuck.value }
        await #expect(throws: HIDError.notConnected) { try await queued.value }
        #expect(ContinuousClock.now - start < .seconds(1))
        #expect(socket.howClosed == "closed")
    }

    @Test func aSocketThatStopsAnsweringPingsIsClosed() async throws {
        let socket = FakeHIDSocket()
        socket.answersPings = false
        let ws = client(on: socket, timing: .testing(pingInterval: .milliseconds(50), pongDeadline: .milliseconds(300)))
        await ws.connect()
        let stream = StreamWatch(ws)

        #expect(await waitUntil(timeout: .seconds(5)) { stream.hasEnded })
        #expect(socket.howClosed == "aborted")
        #expect(socket.pingCount >= 2)
        #expect(await waitUntil { logged("No pong from the device") })
    }

    @Test func aSocketThatAnswersItsPingsStaysOpen() async throws {
        let socket = FakeHIDSocket()
        let ws = client(on: socket, timing: .testing(pingInterval: .milliseconds(50), pongDeadline: .milliseconds(300)))
        await ws.connect()
        let stream = StreamWatch(ws)

        try await Task.sleep(for: .seconds(1))

        #expect(stream.hasEnded == false)
        #expect(socket.howClosed == nil)
        #expect(socket.pingCount >= 5)
        #expect(await ws.isConnected)
        await ws.disconnect()
    }

    @Test func pingsNeverOverlapInputAndInputKeepsItsOrder() async throws {
        // The bug this guards: the ping loop sent on its own, so a ping and a key report could be
        // on the socket at the same time.
        let socket = FakeHIDSocket()
        socket.sendDelay = .milliseconds(3)
        let ws = client(on: socket, timing: .testing(pingInterval: .milliseconds(5), pongDeadline: .seconds(30)))
        await ws.connect()

        var expected: [String] = []
        for index in 0..<40 {
            let key = index.isMultiple(of: 2) ? "ShiftLeft" : "KeyA"
            for isDown in [true, false] {
                try await ws.sendHidKey(key: key, state: isDown)
                expected.append("\(key) \(isDown ? "down" : "up")")
            }
        }

        #expect(socket.pingCount > 0)
        #expect(socket.mostFramesAtOnce == 1)
        #expect(socket.keyFrames.compactMap(\.keyText) == expected)
        await ws.disconnect()
    }
}

// MARK: - Through the input manager

/// Typing through an input manager whose HID sockets are answered in the test: a stuck socket is
/// replaced and typing carries on, and quitting neither hangs on a stuck socket nor skips the
/// release of held keys on a healthy one.
@MainActor
@Suite("HID socket recovery")
struct HIDRecoveryTests {
    private static let window = 9_101

    let scratch = ScratchDefaults()
    let device = StubDevice()
    let sockets = FakeHIDSockets()
    let input: InputManager

    init() {
        input = InputManager(defaults: scratch.defaults, log: SessionLog(destination: .inMemory()))
        input.startKeyboardCapture()
        input.windowDidBecomeKey(windowNumber: Self.window)
    }

    private func connect(timing: HIDTiming) throws {
        let client = try device.makeClient()
        client.hidSocketTiming = timing
        let sockets = self.sockets
        client.makeHIDSocket = { _ in sockets.make() }
        input.setGLKVMClient(client)
    }

    /// Waits for socket `index` to be made and for the keyboard resync that follows its greeting.
    private func openedSocket(_ index: Int) async throws -> FakeHIDSocket {
        #expect(await waitUntil(timeout: .seconds(5)) {
            sockets.count > index && sockets.all[index].frames.contains(where: \.clearsKeyboard)
        })
        return try #require(sockets.all.count > index ? sockets.all[index] : nil)
    }

    private func press(_ keyCode: UInt16, down: Bool) {
        let event = NSEvent.keyEvent(
            with: down ? .keyDown : .keyUp,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: Self.window,
            context: nil,
            characters: "a",
            charactersIgnoringModifiers: "a",
            isARepeat: false,
            keyCode: keyCode
        )!
        #expect(input.routeMonitoredKeyEvent(event) == nil)
    }

    private func keys(on socket: FakeHIDSocket) -> [String] {
        socket.keyFrames.compactMap(\.keyText)
    }

    @Test func aStuckSocketIsReplacedAndTypingCarriesOn() async throws {
        try connect(timing: .testing(sendTimeout: .milliseconds(200), openTimeout: .milliseconds(200)))
        let first = try await openedSocket(0)

        first.holdsFrames = true
        press(0, down: true)   // KeyA, which the stuck socket never takes
        press(0, down: false)

        // The stuck frame times out, the socket is dropped and the HID reconnect opens another.
        let second = try await openedSocket(1)
        #expect(first.howClosed == "aborted")

        press(11, down: true)  // KeyB
        press(11, down: false)
        #expect(await waitUntil { keys(on: second).suffix(2) == ["KeyB down", "KeyB up"] })
        #expect(keys(on: first) == ["KeyA down"])

        await input.shutdown()
    }

    @Test func quittingOverAStuckSocketDoesNotWaitForIt() async throws {
        try connect(timing: .testing(sendTimeout: .milliseconds(300), openTimeout: .milliseconds(300)))
        let socket = try await openedSocket(0)
        socket.holdsFrames = true
        socket.completesHeldFramesWhenClosed = false
        press(0, down: true)
        #expect(await waitUntil { keys(on: socket) == ["KeyA down"] })

        let start = ContinuousClock.now
        await input.shutdown()

        #expect(ContinuousClock.now - start < .seconds(2))
        // Nothing reconnects once quitting has begun.
        try await Task.sleep(for: .milliseconds(500))
        #expect(sockets.count == 1)
    }

    @Test func quittingReleasesHeldKeysOnAHealthySocket() async throws {
        try connect(timing: .testing())
        let socket = try await openedSocket(0)
        press(0, down: true)  // KeyA, still held at quit
        #expect(await waitUntil { keys(on: socket) == ["KeyA down"] })

        await input.shutdown()

        // Everything the resync sent went before the key press, in the HID queue's order.
        let frames = socket.frames
        let pressIndex = frames.firstIndex { $0.keyText == "KeyA down" }
        let press = try #require(pressIndex)
        let afterPress = Array(frames[(press + 1)...])
        #expect(afterPress.first?.keyText == "KeyA up")
        let clearsKeyboard = afterPress.contains(where: \.clearsKeyboard)
        #expect(clearsKeyboard)
        #expect(socket.howClosed == "closed")
    }
}

// MARK: - Scrolling

extension HIDSocketTests {
    /// Scrolling reaches the device only as a wheel report on the HID socket (kvmd's binary
    /// event 0x05: squash flag, then X and Y as signed bytes, clamped to -128...127). There is no
    /// HTTP wheel call.
    @Test func aWheelReportGoesOutOnTheHIDSocket() async throws {
        let socket = FakeHIDSocket()
        let ws = client(on: socket, timing: .testing(sendTimeout: .seconds(2), openTimeout: .seconds(2)))
        await ws.connect()

        try await ws.sendHidMouseWheel(deltaX: 0, deltaY: 3)
        try await ws.sendHidMouseWheel(deltaX: -2, deltaY: -1)
        try await ws.sendHidMouseWheel(deltaX: 300, deltaY: -300)

        let wheels = socket.frames.filter {
            if case .binary(let bytes) = $0 { return bytes.first == 0x05 }
            return false
        }
        #expect(wheels == [
            .binary([0x05, 0x00, 0x00, 0x03]),
            .binary([0x05, 0x00, 0xFE, 0xFF]),
            .binary([0x05, 0x00, 0x7F, 0x80]),
        ])
    }
}
