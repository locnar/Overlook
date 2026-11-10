import Foundation

/// The socket under a connection's Janus signaling sends: a `URLSessionWebSocketTask` in the app,
/// and in tests a stand-in that can hold a frame.
protocol SignalingSocket: AnyObject, Sendable {
    /// Calls `completion` once: when the socket has taken the frame, or with the error that
    /// stopped it.
    func send(_ message: URLSessionWebSocketTask.Message, completion: @escaping @Sendable (Error?) -> Void)
}

/// A `URLSessionWebSocketTask` as a `SignalingSocket`.
final class URLSessionSignalingSocket: SignalingSocket, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    init(_ task: URLSessionWebSocketTask) {
        self.task = task
    }

    func send(_ message: URLSessionWebSocketTask.Message, completion: @escaping @Sendable (Error?) -> Void) {
        task.send(message) { error in completion(error) }
    }
}

/// Every send on one connection's Janus signaling socket: the session setup, keepalives, trickled
/// candidates and the SDP answer.
///
/// They used to go straight to the socket, so a keepalive, a few candidates and the answer could
/// all be on it at once, and none had a deadline: a socket that had stopped draining held each of
/// them for as long as it liked, and only the keepalive's 50 s ack-silence check would notice.
/// Here frames go out one at a time, in the order they were sent, the way the HID socket's do
/// (`GLKVMClient.WebSocketClient.transmit`).
///
/// Each frame has a deadline. A socket that has not taken a frame by then is dead: this sender
/// closes, every frame queued behind it fails at once, and `onStuck` is called, once, so the
/// owner can reconnect. `close()` (a teardown) fails the frame in flight and every queued one at
/// once, without waiting for the socket, and never calls `onStuck`. One sender serves one
/// connection; a closed one stays closed.
@MainActor
final class JanusSignalingSender {
    enum SendError: LocalizedError, Equatable {
        /// The sender was closed before this frame went out (or while it was in flight): by a
        /// teardown, or because an earlier frame missed its deadline.
        case closed
        /// The socket did not take this frame within its deadline. The sender is closed.
        case timedOut

        var errorDescription: String? {
            switch self {
            case .closed: return "the signaling socket is closed"
            case .timedOut: return "the signaling socket did not take the frame in time"
            }
        }
    }

    /// How long the socket may take over one frame before it is taken to be dead.
    struct Timing: Sendable, Equatable {
        /// For a frame once the socket is open.
        var sendTimeout: Duration
        /// For a frame sent before the socket is known to be open: the first one (Janus `create`)
        /// goes out right after `resume()`, and waits for the TCP, TLS and HTTP upgrade first.
        var openTimeout: Duration

        /// Every frame is small: a keepalive or a candidate is under 300 bytes, and the SDP answer
        /// a few KB (about 3–6 KB with its codec lines). An open socket takes a frame as soon as
        /// it fits in the TCP send buffer, which is far larger than that, so the send completes in
        /// well under a millisecond whatever the round trip; it waits only once the buffer is full
        /// because the far end has stopped acknowledging. Five seconds is far past any healthy
        /// send and past a few TCP retransmission backoffs on a lossy Wi-Fi link, so a slow link
        /// is not mistaken for a dead one, yet a dead socket is found within one keepalive
        /// interval (15 s) instead of after the 50 s ack-silence limit.
        ///
        /// The handshake takes 30–80 ms on the LAN and a few hundred over a Tailscale relay. Six
        /// seconds leaves room for a slow one and still fires before the `create` request's own
        /// 8 s answer deadline, so a socket that never opens is logged as that rather than as a
        /// Janus that never answered.
        static let standard = Timing(sendTimeout: .seconds(5), openTimeout: .seconds(6))
    }

    private let socket: SignalingSocket
    private let timing: Timing
    private let onStuck: @MainActor (_ what: String, _ deadline: Duration) -> Void

    /// True once closed: by `close()`, or by a frame that missed its deadline.
    private(set) var isClosed = false
    /// True once the socket has taken a frame: the handshake is done.
    private var isOpen = false
    private var isSending = false
    /// Sends waiting for the one before them, resumed with false if the sender closes first.
    private var waitingToSend: [CheckedContinuation<Bool, Never>] = []
    private var sendInFlight: PendingSignalingSend?

    /// `onStuck` is told what kind of frame missed its deadline, and the deadline it missed.
    init(
        socket: SignalingSocket,
        timing: Timing = .standard,
        onStuck: @escaping @MainActor (_ what: String, _ deadline: Duration) -> Void
    ) {
        self.socket = socket
        self.timing = timing
        self.onStuck = onStuck
    }

    /// Puts `message` on the socket after every frame sent before it. `what` names the frame in
    /// the log ("keepalive", "trickle", "message start").
    func send(_ message: URLSessionWebSocketTask.Message, describing what: String) async throws {
        guard !isClosed else { throw SendError.closed }
        if isSending {
            let isOurTurn = await withCheckedContinuation { waitingToSend.append($0) }
            guard isOurTurn else { throw SendError.closed }
        } else {
            isSending = true
        }
        defer { passTheTurn() }
        // The turn can be handed over and the sender closed before this resumes to take it.
        guard !isClosed else { throw SendError.closed }

        let deadline = isOpen ? timing.sendTimeout : timing.openTimeout
        let socket = self.socket
        let outcome: PendingSignalingSend.Outcome = await withCheckedContinuation { continuation in
            let pending = PendingSignalingSend(continuation)
            sendInFlight = pending
            socket.send(message) { error in
                pending.end(error.map { PendingSignalingSend.Outcome.failed($0) } ?? .sent)
            }
            pending.startDeadline(deadline)
        }
        sendInFlight = nil

        switch outcome {
        case .sent:
            isOpen = true
        case .failed(let error):
            throw error
        case .timedOut:
            if !isClosed {
                close()
                onStuck(what, deadline)
            }
            throw SendError.timedOut
        case .closed:
            throw SendError.closed
        }
    }

    /// Fails the frame in flight and every queued one at once. Returns without waiting for the
    /// socket, which may never give the frame in flight back. Later sends fail at once without
    /// reaching the socket.
    func close() {
        guard !isClosed else { return }
        isClosed = true
        sendInFlight?.end(.closed)
        sendInFlight = nil
        let waiting = waitingToSend
        waitingToSend.removeAll()
        waiting.forEach { $0.resume(returning: false) }
    }

    private func passTheTurn() {
        if waitingToSend.isEmpty {
            isSending = false
        } else {
            waitingToSend.removeFirst().resume(returning: true)
        }
    }

    /// What a Janus request is called in the log: its `janus` verb, with the plugin request when
    /// it carries one ("message start", "message watch").
    nonisolated static func describe(_ message: [String: Any]) -> String {
        let verb = message["janus"] as? String ?? "frame"
        if let body = message["body"] as? [String: Any], let request = body["request"] as? String {
            return "\(verb) \(request)"
        }
        return verb
    }
}

/// One frame's wait for the socket, ended once by whichever comes first: the socket taking the
/// frame (or failing it), the deadline, or the sender closing. The socket's completion arrives on
/// a URLSession queue, hence the lock.
private final class PendingSignalingSend: @unchecked Sendable {
    enum Outcome: Sendable {
        case sent
        case failed(Error)
        case timedOut
        case closed
    }

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Outcome, Never>?
    private var deadline: Task<Void, Never>?

    init(_ continuation: CheckedContinuation<Outcome, Never>) {
        self.continuation = continuation
    }

    func startDeadline(_ duration: Duration) {
        let timer = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.end(.timedOut)
        }
        let hasEnded = lock.withLock { () -> Bool in
            guard continuation != nil else { return true }
            deadline = timer
            return false
        }
        if hasEnded {
            timer.cancel()
        }
    }

    func end(_ outcome: Outcome) {
        let (continuation, deadline) = lock.withLock {
            () -> (CheckedContinuation<Outcome, Never>?, Task<Void, Never>?) in
            defer {
                self.continuation = nil
                self.deadline = nil
            }
            return (self.continuation, self.deadline)
        }
        deadline?.cancel()
        continuation?.resume(returning: outcome)
    }
}

// MARK: - Which handle a pushed message came from

/// The two legs of a connection, each with a Janus handle of its own: video, and audio when it
/// is on.
enum JanusLeg: Equatable, Sendable {
    case video
    case audio
}

/// Decides, from its `sender`, whether a message Janus pushed belongs to one of the current
/// connection's handles.
///
/// A remote candidate or an offer used to go to the audio peer when its sender was the audio
/// handle and to the video peer otherwise, so one from any other handle (a previous
/// connection's, or one this never attached) was applied to the video peer. Candidates and
/// offers now need a sender that is one of the current handles; anything else is dropped. Other
/// notifications that name a handle (`webrtcup`, `media`, `slowlink`, `hangup`, `detached`, plugin
/// events) are dropped too when it is not a current one. A message that names no handle and is
/// not a candidate or an offer is session-level (a keepalive's `ack`, `timeout`, an `error`) and
/// is handled as before.
struct JanusSenderFilter {
    enum Verdict: Equatable {
        /// From one of the current connection's handles.
        case leg(JanusLeg)
        /// Names no handle, and is not a candidate or an offer: about the session as a whole.
        case session
        /// From a handle that is not one of the current connection's, or a candidate or an offer
        /// that names none (`sender` is then nil). `isFirst` is true the first time a sender is
        /// dropped since the last `reset()`, so it is logged once rather than once per message.
        case drop(sender: Int?, isFirst: Bool)
    }

    private var reported: Set<Int?> = []

    /// Candidates and offers belong to one leg's peer connection: without a known sender there is
    /// no telling which.
    static func needsLeg(_ message: [String: Any]) -> Bool {
        message["janus"] as? String == "trickle" || message["jsep"] != nil
    }

    mutating func verdict(for message: [String: Any], videoHandle: Int?, audioHandle: Int?) -> Verdict {
        let sender = message["sender"] as? Int
        if let sender {
            if sender == videoHandle { return .leg(.video) }
            if sender == audioHandle { return .leg(.audio) }
        } else if !Self.needsLeg(message) {
            return .session
        }
        return .drop(sender: sender, isFirst: reported.insert(sender).inserted)
    }

    /// For a teardown: the next connection logs its own strays once each.
    mutating func reset() {
        reported.removeAll()
    }

    /// What a dropped message is called in the log: "trickle", "event with offer".
    static func describe(_ message: [String: Any]) -> String {
        let type = message["janus"] as? String ?? "message"
        if let jsep = message["jsep"] as? [String: Any], let jsepType = jsep["type"] as? String {
            return "\(type) with \(jsepType)"
        }
        return type
    }
}
