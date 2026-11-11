import Foundation
#if canImport(CoreVideo)
import CoreVideo
#endif
#if canImport(CoreAudio)
import CoreAudio
#endif
#if canImport(WebRTC)
@preconcurrency import WebRTC
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif
import Network
import Combine
#if canImport(AppKit)
import AppKit
#endif

struct InputEvent: Codable {
    let type: String
    let data: [String: JSONValue]
    
    enum CodingKeys: String, CodingKey {
        case type
        case data
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(data, forKey: .data)
    }
    
    init(type: String, data: [String: JSONValue]) {
        self.type = type
        self.data = data
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        data = try container.decode([String: JSONValue].self, forKey: .data)
    }
}

/// System-object properties that can make the audio units bind to the wrong device: the device
/// list (a chosen device unplugged) and the two defaults (followed when no UID is set). File scope
/// so `deinit`, which is not main-actor isolated, can use them.
private let audioHardwareListenerSelectors: [AudioObjectPropertySelector] = [
    kAudioHardwarePropertyDevices,
    kAudioHardwarePropertyDefaultOutputDevice,
    kAudioHardwarePropertyDefaultInputDevice,
]

private func audioHardwareAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
}

/// Which of a connection's two peer connections (video, and audio when it is on) an ICE callback
/// came from, and what to do with it.
///
/// WebRTC calls the delegate on its own thread and the manager handles each call in a main-actor
/// task, so a teardown can let go of its peer connections before their closing callbacks are
/// handled. Telling the peers apart by comparing with the manager's current ones then read the
/// video peer's close as an audio one: every disconnect logged "Audio ICE state: closed" twice
/// and the video close not at all. This remembers each peer's role from the connect that made it
/// until its close has been handled.
struct PeerConnectionRoles<Peer: AnyObject> {
    enum Role: Equatable {
        case video
        case audio
    }

    /// What one ICE state change calls for.
    enum Disposition: Equatable {
        /// From the current connection: log it, and for video let it drive the connection state.
        case live(Role)
        /// The close of a peer a teardown let go of: log it once, and leave the connection state
        /// alone, because by now it may belong to the next connection.
        case closed(Role)
        /// Anything else from a torn-down peer, or from a peer this never saw: it would only be
        /// read as part of whatever connection is current, so it is not logged.
        case ignore
    }

    private struct Entry {
        /// Held so that a released peer's address cannot be handed to a new peer, and its late
        /// callbacks read as the new one's, before this has finished with it.
        let peer: Peer
        let role: Role
        /// The teardown that let go of it, or nil while it belongs to the current connection.
        var retiredAt: Int?
    }

    private var entries: [ObjectIdentifier: Entry] = [:]
    private var teardowns = 0

    /// Peers this still holds: the current connection's and those whose close has not come in.
    var count: Int { entries.count }

    mutating func register(_ peer: Peer, as role: Role) {
        entries[ObjectIdentifier(peer)] = Entry(peer: peer, role: role, retiredAt: nil)
    }

    /// The current connection's peers stop being current. A peer whose close has still not come
    /// in by the teardown after next never will, so it is let go then rather than held for good.
    mutating func retireAll() {
        teardowns += 1
        let now = teardowns
        entries = entries.filter { _, entry in
            guard let retiredAt = entry.retiredAt else { return true }
            return retiredAt >= now - 1
        }
        for key in Array(entries.keys) where entries[key]?.retiredAt == nil {
            entries[key]?.retiredAt = now
        }
    }

    /// The role of `peer` while it belongs to the current connection; nil once a teardown has let
    /// go of it, or for a peer this never saw. Unlike `disposition`, asking changes nothing.
    func currentRole(of peer: Peer) -> Role? {
        guard let entry = entries[ObjectIdentifier(peer)], entry.retiredAt == nil else { return nil }
        return entry.role
    }

    /// The Janus handle that what `peer` gathers (a local candidate, or the end of them) is
    /// trickled to: `videoHandle` or `audioHandle` by the peer's own role, or nil for a peer that
    /// is no longer current, whose candidates belong to a session that is gone.
    ///
    /// WebRTC reports candidates on its own thread and each is handled in a main-actor task, so
    /// one gathered just before a teardown can be handled after the next connect has its handles.
    /// Routing by "is it the current audio peer, else video" sent such a candidate, from either
    /// leg, to the new video handle.
    func trickleHandle(for peer: Peer, videoHandle: Int?, audioHandle: Int?) -> Int? {
        switch currentRole(of: peer) {
        case .video: return videoHandle
        case .audio: return audioHandle
        case nil: return nil
        }
    }

    /// What a track that arrived on `peer` calls for. Only the current connection's peers count:
    /// a torn-down peer's track is ignored, so it neither renders into the next connection nor
    /// changes its audio. Audio is switched to follow the Audio setting on either current peer;
    /// video is rendered only from the video peer, since a second stream would fight over the
    /// view.
    func action(forAdded kind: AddedTrackKind, on peer: Peer) -> AddedTrackAction {
        guard let role = currentRole(of: peer) else { return .ignore }
        switch kind {
        case .audio:
            return .playAudio
        case .video:
            return role == .video ? .renderVideo : .hintOnly
        case .other:
            return .hintOnly
        }
    }

    /// Where a callback that is only logged came from (signaling state, streams added and
    /// removed, renegotiation, candidates removed, a data channel opening).
    enum LogSource: Equatable {
        /// The current connection's peer.
        case current(Role)
        /// A peer a teardown has let go of, whose close has not been handled yet. The current
        /// connection's own teardown lines land here: they are handled after the teardown.
        case tornDown(Role)
        /// A peer whose close has been handled, or one this never saw.
        case unknown
    }

    /// Where a log-only callback from `peer` came from. Asking changes nothing.
    func logSource(of peer: Peer) -> LogSource {
        guard let entry = entries[ObjectIdentifier(peer)] else { return .unknown }
        return entry.retiredAt == nil ? .current(entry.role) : .tornDown(entry.role)
    }

    /// What goes in front of a log-only line, so a torn-down peer's late line reads as that peer's
    /// rather than as part of whatever connection is current when it is handled. No line is
    /// dropped: a connection's own teardown lines come in after the teardown, and still appear.
    static func logPrefix(_ source: LogSource) -> String {
        switch source {
        case .current(.video): return "Video peer: "
        case .current(.audio): return "Audio peer: "
        case .tornDown(.video): return "Torn-down video peer: "
        case .tornDown(.audio): return "Torn-down audio peer: "
        case .unknown: return "Torn-down peer: "
        }
    }

    /// `isClosed` is whether the new state is `closed`, which only a teardown's `close()` causes.
    mutating func disposition(for peer: Peer, isClosed: Bool) -> Disposition {
        let key = ObjectIdentifier(peer)
        guard let entry = entries[key] else { return .ignore }
        guard entry.retiredAt != nil else { return .live(entry.role) }
        guard isClosed else { return .ignore }
        entries[key] = nil
        return .closed(entry.role)
    }
}

/// The kind of track a receiver added to a peer connection carries.
enum AddedTrackKind: Equatable {
    case audio
    case video
    case other
}

/// What a track added to a peer connection calls for (`PeerConnectionRoles.action(forAdded:on:)`).
enum AddedTrackAction: Equatable {
    /// From a peer that is no longer current, or one never seen: change nothing.
    case ignore
    /// Received audio on a current peer: hint low-latency playout and switch it on or off to
    /// follow the Audio setting.
    case playAudio
    /// Video on the current video peer: hint low-latency playout and render it.
    case renderVideo
    /// Anything else on a current peer: hint low-latency playout only.
    case hintOnly
}

/// The Janus requests that are answered by transaction (`create` and `attach`) and are still
/// waiting for that answer.
///
/// Each request's waiter is in place before the request is sent. Janus's answer is read by the
/// signaling listener, and the send's completion and the answer both come back through URLSession
/// callbacks that then wait their turn on the main actor, in no set order: a device on the LAN can
/// have its answer handled while the send is still suspended. A waiter registered only once the
/// send had returned missed such an answer, and the connect then sat out the whole timeout.
@MainActor
final class JanusTransactions {
    typealias Reply = [String: Any]

    private struct Pending {
        let continuation: CheckedContinuation<Reply, Error>
        let deadline: Task<Void, Never>
    }

    private var pending: [String: Pending] = [:]
    private let timeoutNanoseconds: UInt64
    private let timeoutError: Error

    /// Requests that have neither been answered nor failed yet.
    var count: Int { pending.count }

    /// `timeoutError` is what a request throws when no answer comes within `timeoutNanoseconds`.
    nonisolated init(timeoutNanoseconds: UInt64, timeoutError: Error) {
        self.timeoutNanoseconds = timeoutNanoseconds
        self.timeoutError = timeoutError
    }

    /// Waits for Janus's answer to `transaction`, which `send` puts on the wire. The deadline
    /// starts before the send, so a send that never finishes times out as well. A send that fails
    /// fails the request at once with its own error.
    func request(_ transaction: String, send: @escaping @MainActor () async throws -> Void) async throws -> Reply {
        try await withCheckedThrowingContinuation { continuation in
            let timeoutNanoseconds = self.timeoutNanoseconds
            let timeoutError = self.timeoutError
            let deadline = Task { [weak self] in
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                guard !Task.isCancelled else { return }
                self?.finish(transaction, with: .failure(timeoutError))
            }
            pending[transaction] = Pending(continuation: continuation, deadline: deadline)
            Task { [weak self] in
                do {
                    try await send()
                } catch {
                    self?.finish(transaction, with: .failure(error))
                }
            }
        }
    }

    /// Hands `message` to the request waiting on its transaction. False when no request is
    /// waiting on it, so the caller treats it as a notification (a keepalive's ack, say).
    func deliver(_ message: Reply) -> Bool {
        guard let transaction = message["transaction"] as? String, pending[transaction] != nil else {
            return false
        }
        finish(transaction, with: .success(message))
        return true
    }

    /// Ends every waiting request with `error`; for a teardown.
    func failAll(_ error: Error) {
        for transaction in Array(pending.keys) {
            finish(transaction, with: .failure(error))
        }
    }

    /// Whichever of the answer, the deadline, a failed send and a teardown comes first ends the
    /// request; the others find nothing left to end.
    private func finish(_ transaction: String, with result: Result<Reply, Error>) {
        guard let entry = pending.removeValue(forKey: transaction) else { return }
        entry.deadline.cancel()
        entry.continuation.resume(with: result)
    }
}

/// One entry of a WebRTC statistics report: its `type` ("inbound-rtp", "candidate-pair", …) and
/// its values. A polling tick works from these, keyed by entry id, rather than from
/// `RTCStatisticsReport`, which only WebRTC can make, so a test can hand a tick numbers of its own.
struct StatsEntry {
    let type: String
    let values: [String: Any]
}

#if canImport(WebRTC)
@MainActor
class WebRTCManager: NSObject, ObservableObject {
    @Published var videoView: RTCMTLNSVideoView?
    @Published var isConnected = false
    @Published var currentFrame: CVPixelBuffer?
    @Published var videoSize: CGSize?
    /// The app's audio settings, shared by every window's manager. Audio and Microphone both take
    /// effect on the next connect (the peer connections are built then); turning either off acts
    /// at once.
    let audioPreferences: AudioPreferences
    var audioEnabled: Bool { audioPreferences.audioEnabled }
    var micEnabled: Bool { audioPreferences.micEnabled }
    /// The session's handle on the connection log; every line from here names the session's device.
    let log: SessionLog
    /// Whether this window plays its audio and sends the microphone, as `SessionAudioRouter` last
    /// decided from which window is active.
    private(set) var audioRoute: AudioRoute = .unrouted
    /// Settings › Network, shared by every window; read as each connect starts.
    let networkPreferences: NetworkPreferences
    /// The "Video and audio addresses" setting the current connection was made with; nil while
    /// not connected. Settings compares it with the setting to say a change waits for the next
    /// connect.
    @Published private(set) var mediaAddressesInEffect: MediaAddresses?
    /// What the current connect's video and audio may use (`MediaRoute.decide`).
    private(set) var mediaRoute: MediaRoute = .allAddresses()
    /// Candidate addresses the current connect has already named in the log, so the video and
    /// audio legs, which carry the same addresses, produce one line between them.
    private var loggedDroppedRemoteAddresses: Set<String> = []
    private var droppedLocalAddresses: [String] = []
    private var loggedDroppedLocalAddresses: Set<String> = []
    /// How a connect resolves a host name, and reads this Mac's interface addresses, to decide
    /// its media route. Tests replace both so nothing reaches DNS.
    var resolveHost: (String) async -> [String] = { await HostResolver.addresses(of: $0) }
    var localInterfaces: () -> [LocalInterfaceAddress] = { LocalInterfaceAddress.current() }
    /// Reads the connected device's `video_mode` (`GLKVMVideoMode`). The session points it at its
    /// HTTP client; nil reads nothing, and a failed connect is then reported as it always was.
    var readVideoMode: GLKVMVideoMode.Reader?
    /// The device's video mode as last read, by Settings or after a failed connect, and for which
    /// address. A connect to that address in WebRTC (Native) mode is refused before Janus is tried.
    private(set) var knownVideoMode: KnownVideoMode?
    /// Whether this operator connect or reconnect has logged the WebRTC (Native) mode yet; the
    /// retries that follow it do not log it again.
    private var hasLoggedNativeVideoMode = false
    /// True after a connect asked for the microphone and macOS refused (System Settings ›
    /// Privacy & Security › Microphone). The session goes on without the mic.
    @Published private(set) var isMicrophoneAccessDenied = false
    @Published var preferLowLatencyPlayout = true
    @Published var isConnecting = false
    @Published var hasEverConnectedToStream = false
    @Published var isStreamStalled = false
    @Published var lastDisconnectReason: String?
    @Published var lastVideoFrameAgeSeconds: Int?

    /// Periodic stream statistics (latency, kbps, fps, jitter, …). Deliberately a plain `let`, not
    /// `@Published`: the model publishes one equality-gated snapshot, so a stats tick invalidates
    /// only the views that render it — never `ContentView` or the video surface.
    let telemetry = StreamTelemetryModel()

    /// Hand-off point for screenshots and recordings: every decoded frame and every playout
    /// buffer passes through it (see `renderFrame` and `WebRTCAudioDevice`). Also a plain `let`.
    let captureHub = MediaCaptureHub()

    /// True when the current connection can deliver remote audio to a recording: audio is on and
    /// the audio peer connection exists. Playout runs through `WebRTCAudioDevice` on every
    /// connection now, so that is the only condition.
    var isAudioPlayoutAvailable: Bool {
        audioEnabled && audioPeerConnection != nil
    }

    /// Channels and rate the playout unit delivers — what a recording's audio track is configured
    /// for, so its AAC runs at the device's own rate with no resampling in between.
    var playoutChannelCount: Int {
        customAudioDevice?.outputNumberOfChannels ?? 2
    }

    var playoutSampleRate: Double {
        customAudioDevice?.deviceOutputSampleRate ?? 48_000
    }

    private var peerConnection: RTCPeerConnection?
    private var audioPeerConnection: RTCPeerConnection?
    /// Which peer an ICE callback came from, still known after a teardown lets go of the peer.
    private var peerRoles = PeerConnectionRoles<RTCPeerConnection>()
    /// The current connection's video track, the renderers added to it, and the relay among
    /// them that hands its frames to this manager; all taken off it when it is let go of.
    private var videoTrack: VideoRendererHost?
    private var videoTrackRenderers: [RTCVideoRenderer] = []
    private var videoFrameRelay: VideoFrameRelay?
    private var localAudioTrack: RTCAudioTrack?
    private var localAudioSender: RTCRtpSender?
    /// What the current connect will actually send: the mic only when macOS granted it, so a
    /// refused microphone is not negotiated as a silent sendrecv track.
    private var negotiatedMicEnabled = false
    private var dataChannel: RTCDataChannel?
    private var factory: RTCPeerConnectionFactory?
    private var customAudioDevice: WebRTCAudioDevice?
    private var connectionTimer: Timer?

    private var lastConnectedDevice: KVMDevice?
    /// Stats ticks in the order they started, and the newest one applied. A tick whose reads take
    /// longer than the 1 s interval can finish after the next one; it is then dropped rather than
    /// applied over newer numbers (and made the kbps baseline).
    private var statsTicksStarted = 0
    private var newestStatsTickApplied = 0

    private let audioDevicesListenerQueue = DispatchQueue(label: "com.overlook.audio-device-change")
    private var audioDevicesListenerBlock: AudioObjectPropertyListenerBlock?
    private var audioDeviceChangeDebounceTask: Task<Void, Never>?
    private var isAutoReconnectInProgress: Bool = false
    private var lastAutoReconnectAt: Date?

    private var lastInboundVideoBytesReceived: Int64?
    private var lastInboundVideoBytesTimestamp: TimeInterval?

    private var lastInboundAudioBytesReceived: Int64?
    private var lastInboundAudioBytesTimestamp: TimeInterval?

    private var lastJitterBufferDelaySeconds: Double?
    private var lastJitterBufferEmittedCount: Double?
    private var lastTotalDecodeTimeSeconds: Double?
    private var lastTotalProcessingDelaySeconds: Double?
    private var lastFramesDecodedForDelays: Double?

    private var lastAudioJitterBufferDelaySeconds: Double?
    private var lastAudioJitterBufferEmittedCount: Double?

    private var lastPlayoutHintApplyTime: TimeInterval?

    /// Frame arrivals for the current connection: last-frame time, frame rate, frames kept.
    private let frameMeter = VideoFrameMeter()
    private var connectedIceTime: CFTimeInterval?
    private var streamHealthTimer: Timer?

    private let streamStallThresholdSeconds: CFTimeInterval = 3.0
    private let initialFrameTimeoutSeconds: CFTimeInterval = 5.0
    
    private var signalingSession: URLSession?
    private var webSocketTask: URLSessionWebSocketTask?
    /// The one send path onto `webSocketTask`: frames in order, each with a deadline.
    private var signalingSender: JanusSignalingSender?
    private var signalingListenerTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    /// Bumped on every connect and teardown so work started for an earlier connection — the
    /// signaling listener, in-flight transactions — cannot act on a later one.
    private var connectionGeneration = 0
    /// Stall-triggered reconnects since video last flowed. Bounded, because a device that is up
    /// but has nothing to send (no HDMI signal, say) would otherwise be torn down every few seconds.
    private var consecutiveStallReconnects = 0
    private static let maxConsecutiveStallReconnects = 2

    /// Internal so a test can stand in for a created Janus session.
    var janusSessionId: Int?
    private var janusHandleId: Int?
    private var janusAudioHandleId: Int?
    /// Which of the current handles a pushed message came from; strays are dropped.
    private var janusSenders = JanusSenderFilter()
    private var janusKeepAliveTimer: Timer?
    private static let janusTransactionTimeoutNs: UInt64 = 8_000_000_000
    private let janusTransactions = JanusTransactions(
        timeoutNanoseconds: WebRTCManager.janusTransactionTimeoutNs,
        timeoutError: WebRTCError.signalingTimeout
    )
    /// When Janus last answered anything. `URLSessionWebSocketTask.send` reports success long
    /// after the far end has stopped listening, so a send that "worked" is not evidence the
    /// session is alive; an ack is.
    private var lastJanusAckAt: Date?
    /// Sending every 15s against Janus's stock 60s `session_timeout` leaves room for three
    /// missed keepalives. The old 25s left room for one, which a timer-coalescing window or a
    /// long modal tracking loop could eat on its own.
    private static let janusKeepAliveInterval: TimeInterval = 15.0
    /// Reconnect once the server has been silent for longer than its own timeout window would
    /// allow, rather than waiting for the socket read to fail (which can take minutes when the
    /// path is black-holing rather than refusing).
    private static let janusAckSilenceLimit: TimeInterval = 50.0

    /// Held for the life of a connection. Without it macOS applies App Nap once the window is
    /// occluded or the app is backgrounded, which widens every timer's coalescing window — and
    /// the keepalive timer is the one that must not slip.
    private var powerAssertion: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var pathMonitor: NWPathMonitor?
    private var lastPathSummary: String?
    /// Set while the machine is asleep, so the wake handler knows a reconnect is warranted even
    /// if nothing has noticed the sockets are dead yet.
    private var didSleepDuringSession = false

    /// The last candidate pair written to the log, so only transitions are recorded and not
    /// one line per second.
    private var lastLoggedCandidatePath: String?

    private var isFrameCaptureEnabled: Bool = false
    
    private var cancellables = Set<AnyCancellable>()

    /// `audioPreferences` and `networkPreferences` are the app's shared objects unless a test hands
    /// in its own; `log` is the session's handle on the connection log (a manager on its own logs
    /// untagged lines to the app's log, under a session of its own).
    init(
        audioPreferences: AudioPreferences? = nil,
        networkPreferences: NetworkPreferences? = nil,
        log: SessionLog? = nil
    ) {
        self.audioPreferences = audioPreferences ?? .shared
        self.networkPreferences = networkPreferences ?? .shared
        self.log = log ?? SessionLog(destination: .shared)
        super.init()
        setupWebRTC()
        startAudioDeviceChangeMonitoring()

        // The toggles are shared by every window, so a change made in another window's Settings
        // lands here too. `@Published` fires in `willSet`: the new value is the emitted one.
        self.audioPreferences.$audioEnabled
            .dropFirst()
            .sink { [weak self] enabled in
                // Playback follows the toggle at once; only the negotiation waits for a connect.
                self?.audioPeerConnection?.receivers
                    .compactMap { $0.track as? RTCAudioTrack }
                    .forEach { $0.isEnabled = enabled }
            }
            .store(in: &cancellables)
        self.audioPreferences.$micEnabled
            .dropFirst()
            .sink { [weak self] enabled in
                self?.applyMicrophoneRoute(micEnabled: enabled)
            }
            .store(in: &cancellables)
    }

    /// Plays or mutes this window's audio and sends or silences the microphone, without touching
    /// the connection. Muting happens at the output, after the recording tap, so a muted window
    /// still records its audio; the microphone track stays negotiated and sends silence while
    /// another window has it.
    func setAudioRoute(_ route: AudioRoute) {
        guard route != audioRoute else { return }
        audioRoute = route
        customAudioDevice?.isOutputMuted = !route.playsAudio
        applyMicrophoneRoute(micEnabled: micEnabled)
    }

    private func applyMicrophoneRoute(micEnabled: Bool) {
        localAudioTrack?.isEnabled = micEnabled && audioRoute.sendsMicrophone
    }

    /// Whether the output device is silenced for this window right now.
    var isPlaybackMuted: Bool {
        customAudioDevice?.isOutputMuted ?? !audioRoute.playsAudio
    }

    deinit {
        if let block = audioDevicesListenerBlock {
            for selector in audioHardwareListenerSelectors {
                var address = audioHardwareAddress(selector)
                _ = AudioObjectRemovePropertyListenerBlock(
                    AudioObjectID(kAudioObjectSystemObject),
                    &address,
                    audioDevicesListenerQueue,
                    block
                )
            }
        }

        audioDevicesListenerBlock = nil
        audioDeviceChangeDebounceTask?.cancel()
        audioDeviceChangeDebounceTask = nil
    }

    /// When the current connection's last video frame arrived; nil before its first. What the
    /// stall check reads. Internal so a test can see whether a frame was counted.
    var lastVideoFrameTimestamp: CFTimeInterval? {
        frameMeter.lastFrameTime
    }
    
    /// `adapters` is the connect's media route's (`MediaRoute.adapterOptions`); the standard set
    /// leaves the factory exactly as it has always been built.
    private func setupWebRTC(adapters: MediaAdapterOptions = .standard) {
        let inputUID = audioPreferences.inputDeviceUID
        let outputUID = audioPreferences.outputDeviceUID

        // Always our own audio device, even with the system defaults: it is the only place the
        // received audio can be tapped for recordings (libwebrtc's built-in module exposes no
        // playout sink). With no UID it binds to the default devices; a default that changes
        // mid-session is followed by a reconnect (see `audioDeviceReconnectReason`).
        let audioDevice = WebRTCAudioDevice(
            inputDeviceUID: inputUID,
            outputDeviceUID: outputUID,
            playoutTap: captureHub,
            log: log
        )
        audioDevice.isOutputMuted = !audioRoute.playsAudio
        customAudioDevice = audioDevice

        let factory = WebRTCFactoryBuilder.makeFactory(with: audioDevice)
        if adapters != .standard {
            // Set before any peer connection exists: a peer's port allocator reads the factory's
            // network ignore mask when it is made.
            let options = RTCPeerConnectionFactoryOptions()
            options.ignoreVPNNetworkAdapter = adapters.ignoresVPN
            options.ignoreLoopbackNetworkAdapter = adapters.ignoresLoopback
            factory.setOptions(options)
        }
        self.factory = factory

        if videoView == nil {
            videoView = RTCMTLNSVideoView(frame: .zero)
        }
    }

    private func startAudioDeviceChangeMonitoring() {
        guard audioDevicesListenerBlock == nil else { return }

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            Task { @MainActor in
                self.handleAudioHardwareChanged()
            }
        }

        audioDevicesListenerBlock = block
        for selector in audioHardwareListenerSelectors {
            var address = audioHardwareAddress(selector)
            _ = AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                audioDevicesListenerQueue,
                block
            )
        }
    }

    private func stopAudioDeviceChangeMonitoring() {
        guard let block = audioDevicesListenerBlock else { return }

        for selector in audioHardwareListenerSelectors {
            var address = audioHardwareAddress(selector)
            _ = AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                audioDevicesListenerQueue,
                block
            )
        }

        audioDevicesListenerBlock = nil
        audioDeviceChangeDebounceTask?.cancel()
        audioDeviceChangeDebounceTask = nil
    }

    /// Why the live session's audio units no longer match the configuration, or nil when they do.
    /// Two cases, each only for a direction that is in use (mic on, or audio on):
    /// - a chosen device (UID in defaults) is gone;
    /// - no device is chosen and the system default moved away from the device the unit was
    ///   bound to at init (`WebRTCAudioDevice` resolves the default once; libwebrtc's own module
    ///   used to follow it silently — a reconnect is how this one follows).
    private func audioDeviceReconnectReason() -> String? {
        guard peerConnection != nil else { return nil }

        let inputUID = audioPreferences.inputDeviceUID
        let outputUID = audioPreferences.outputDeviceUID

        let inputRelevant = micEnabled
        let outputRelevant = audioEnabled

        if inputRelevant, !inputUID.isEmpty, CoreAudioDevices.deviceID(forUID: inputUID) == nil {
            return "Audio device changed"
        }
        if outputRelevant, !outputUID.isEmpty, CoreAudioDevices.deviceID(forUID: outputUID) == nil {
            return "Audio device changed"
        }

        if let audioDevice = customAudioDevice {
            if outputRelevant, outputUID.isEmpty, let bound = audioDevice.activeOutputDeviceID {
                let current = WebRTCAudioDevice.systemDefaultDeviceID(selector: kAudioHardwarePropertyDefaultOutputDevice)
                if current != 0, current != bound { return "Default output device changed" }
            }
            if inputRelevant, inputUID.isEmpty, let bound = audioDevice.activeInputDeviceID {
                let current = WebRTCAudioDevice.systemDefaultDeviceID(selector: kAudioHardwarePropertyDefaultInputDevice)
                if current != 0, current != bound { return "Default input device changed" }
            }
        }
        return nil
    }

    private func handleAudioHardwareChanged() {
        guard audioDeviceReconnectReason() != nil else { return }
        guard peerConnection != nil else { return }
        guard lastConnectedDevice != nil else { return }

        audioDeviceChangeDebounceTask?.cancel()
        audioDeviceChangeDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            await MainActor.run {
                self?.autoReconnectIfStillNeeded()
            }
        }
    }

    private func autoReconnectIfStillNeeded() {
        guard isAutoReconnectInProgress == false else { return }
        guard let device = lastConnectedDevice else { return }
        guard let reason = audioDeviceReconnectReason() else { return }

        let now = Date()
        if let last = lastAutoReconnectAt, now.timeIntervalSince(last) < 3.0 {
            return
        }
        lastAutoReconnectAt = now

        isAutoReconnectInProgress = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isAutoReconnectInProgress = false }
            await self.reconnect(to: device, reason: reason)
        }
    }
    
    func connect(to device: KVMDevice) async throws {
        // An operator connect supersedes, and releases, whatever is in flight: a retry loop, an
        // attempt still waiting on Janus, or the live session when switching devices.
        consecutiveStallReconnects = 0
        hasLoggedNativeVideoMode = false
        telemetry.update { $0.clearSession() }
        self.log.notice(.lifecycle, "Connect requested: \(device.displayName) (\(device.connectionString))")
        beginSessionEnvironment()
        do {
            try await replaceConnection(with: device)
        } catch {
            // The video-mode message has been logged already, once.
            if !(error is NativeWebRTCVideoModeError) {
                self.log.error(.lifecycle, "Connect failed: \(error.localizedDescription)")
            }
            // The caller only surfaces the error (see ContentView); without this the activity
            // assertion, the sleep/wake observers and the path monitor would outlive the failed
            // attempt with nothing left to release them.
            endSessionEnvironment()
            throw error
        }
        telemetry.update { $0.sessionConnectedAt = Date() }
        self.log.notice(.lifecycle, "Connected to \(device.displayName)")
    }

    // MARK: - Session environment

    /// Reflexive candidates are worth gathering only when the peer is somewhere a host candidate
    /// cannot reach. A KVM on the LAN, on Tailscale (by address, `*.ts.net` or a bare MagicDNS
    /// name), or on link-local is always reachable directly, so a public STUN server adds a round
    /// trip to every connect and a stall to every connect on a network that filters UDP/3478
    /// outbound (`MediaNetworkRules.isDirectlyReachable`).
    private static func iceServers(for device: KVMDevice, route: MediaRoute, log: SessionLog) -> [RTCIceServer] {
        if case .chosen(let network) = route.scope {
            log.info(.ice, "Peer \(device.host) on \(network.name): gathering host candidates only")
            return []
        }
        if !route.addsPublicSTUN {
            log.info(.ice, "Local peer \(device.host): gathering host candidates only")
            return []
        }
        log.info(.ice, "Remote peer \(device.host): adding public STUN")
        return [RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])]
    }

    /// Taken when a session starts, released when it ends. Three things live here, all of them
    /// reasons a connection dies on a network that never went anywhere:
    ///
    /// - The App Nap assertion. Occlude the window and macOS widens every timer's coalescing
    ///   window; the keepalive is the timer that cannot afford it. Deliberately
    ///   `.userInitiatedAllowingIdleSystemSleep` and not `.userInitiated`: the latter implies
    ///   `.idleSystemSleepDisabled`, which would stop the operator's Mac idle-sleeping for as
    ///   long as a console window is open. Suppressing App Nap is the goal; holding the machine
    ///   awake is not.
    /// - Sleep and wake. Sockets do not survive sleep, and nothing noticed until a read failed.
    /// - Path changes. `NWPathMonitor` was already running for device discovery but never told
    ///   the session that the interface moved — a Wi-Fi/Ethernet switch or a Tailscale
    ///   direct↔DERP transition looked like an unexplained drop.
    private func beginSessionEnvironment() {
        if powerAssertion == nil {
            powerAssertion = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep],
                reason: "Overlook remote console session"
            )
            self.log.info(.power, "App Nap suppressed for the session")
        }

        let center = NSWorkspace.shared.notificationCenter
        if sleepObserver == nil {
            sleepObserver = center.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.didSleepDuringSession = true
                    self.log.notice(.power, "System going to sleep")
                }
            }
        }
        if wakeObserver == nil {
            wakeObserver = center.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.log.notice(.power, "System woke")
                    guard self.didSleepDuringSession else { return }
                    self.didSleepDuringSession = false
                    guard self.lastConnectedDevice != nil else { return }
                    // Don't wait for a socket read to notice: a black-holed path can take
                    // minutes to surface an error.
                    self.requestReconnect(reason: "Resumed from sleep", delayNanoseconds: 1_500_000_000)
                }
            }
        }

        if pathMonitor == nil {
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] path in
                Task { @MainActor in
                    self?.handlePathUpdate(path)
                }
            }
            monitor.start(queue: DispatchQueue(label: "com.overlook.session-path"))
            pathMonitor = monitor
        }
    }

    private func endSessionEnvironment() {
        if let powerAssertion {
            ProcessInfo.processInfo.endActivity(powerAssertion)
            self.log.info(.power, "App Nap assertion released")
        }
        powerAssertion = nil

        let center = NSWorkspace.shared.notificationCenter
        if let sleepObserver { center.removeObserver(sleepObserver) }
        if let wakeObserver { center.removeObserver(wakeObserver) }
        sleepObserver = nil
        wakeObserver = nil

        pathMonitor?.cancel()
        pathMonitor = nil
        lastPathSummary = nil
        didSleepDuringSession = false
    }

    /// Logs every interface transition, and reconnects when the route actually moved rather than
    /// merely flapped. The first update after the monitor starts is the baseline, not a change.
    private func handlePathUpdate(_ path: NWPath) {
        // Only the preferred interface — the one traffic actually leaves by. Keying on the full
        // available-interface list turns every unrelated bit of churn (a VPN tunnel appearing, a
        // dongle, Wi-Fi associating while the session runs on Ethernet) into a "path changed"
        // and a reconnect the session never needed.
        let route = path.availableInterfaces.first.map { "\($0.name)/\($0.type)" } ?? "none"
        let summary = "\(path.status) via \(route)"
            + (path.isExpensive ? " expensive" : "")

        guard let previous = lastPathSummary else {
            lastPathSummary = summary
            self.log.info(.network, "Network path: \(summary)")
            return
        }
        guard previous != summary else { return }
        lastPathSummary = summary
        self.log.notice(.network, "Network path changed: \(previous) → \(summary)")

        guard lastConnectedDevice != nil, path.status == .satisfied else { return }
        guard isConnected || hasEverConnectedToStream else { return }
        requestReconnect(
            reason: "Network path changed",
            delayNanoseconds: 1_000_000_000,
            skipIfRecovered: true
        )
    }

    // MARK: - Media route

    /// Decides which addresses this connect's video and audio may use, from the address it goes
    /// through and Settings › Network, and logs the decision once. A host name is resolved first
    /// (only when the setting needs it), so a bare MagicDNS name counts as Tailscale. Internal so a
    /// test can set a route up without connecting, with `resolveHost` and `localInterfaces` of
    /// its own.
    @discardableResult
    func prepareMediaRoute(for device: KVMDevice) async -> MediaRoute {
        let preference = networkPreferences.mediaAddresses
        var resolved: [String] = []
        var interfaces: [LocalInterfaceAddress] = []
        if preference == .chosenNetwork {
            if MediaNetwork.needsResolution(host: device.host) {
                resolved = await resolveHost(device.host)
            }
            interfaces = localInterfaces()
        }
        let route = MediaRoute.decide(preference: preference, host: device.host, resolved: resolved, interfaces: interfaces)
        mediaRoute = route
        mediaAddressesInEffect = preference
        loggedDroppedRemoteAddresses = []
        droppedLocalAddresses = []
        loggedDroppedLocalAddresses = []
        if route.unclassifiedReason != nil {
            log.notice(.ice, route.connectDescription)
        } else {
            log.info(.ice, route.connectDescription)
        }
        return route
    }

    /// Applies the KVM's offer to a leg's peer through `setRemoteDescription`, with the candidates
    /// this connect's route does not keep taken out, and logs what was taken out the first time
    /// an address is dropped in this connect. Internal so a test can see what reaches
    /// `setRemoteDescription` without a peer connection.
    func applyRemoteOffer(
        _ sdp: String,
        leg: JanusLeg,
        setRemoteDescription: (RTCSessionDescription) async throws -> Void
    ) async {
        let result = mediaRoute.filterRemoteOffer(sdp)
        if result.keptWholeOffer {
            let used = result.usedWholeLabels
            log.warning(
                .ice,
                "\(mediaRoute.limitDescription): the KVM's \(leg) offer has no candidate on that network; "
                    + "keeping all of its candidates for this offer"
                    + (used.isEmpty ? "" : " (\(used.joined(separator: ", ")))")
            )
        } else if !result.dropped.isEmpty {
            let labels = result.dropped.map(\.label)
            let new = labels.filter { !loggedDroppedRemoteAddresses.contains($0) }
            if !new.isEmpty {
                loggedDroppedRemoteAddresses.formUnion(new)
                let count = result.dropped.count
                log.notice(
                    .ice,
                    "\(mediaRoute.limitDescription): dropped \(count) remote candidate\(count == 1 ? "" : "s") "
                        + "(\(labels.joined(separator: ", ")))"
                )
            } else {
                log.debug(.ice, "Dropped the same \(result.dropped.count) remote candidates from the \(leg) offer")
            }
        }
        do {
            try await setRemoteDescription(RTCSessionDescription(type: .offer, sdp: result.sdp))
        } catch {
            log.error(.signaling, "Set remote description failed: \(error.localizedDescription)")
        }
    }

    /// Whether a candidate the KVM trickled is used, under this connect's route.
    func keepsTrickledRemoteCandidate(_ candidate: String) -> Bool {
        guard let line = ICECandidateLine(candidate) else { return true }
        let keeps = mediaRoute.keepsRemote(line)
        if !keeps {
            log.debug(.ice, "\(mediaRoute.limitDescription): dropped a trickled remote candidate (\(line.label))")
        }
        return keeps
    }

    /// Sends a candidate this Mac gathered to the KVM, unless this connect's route keeps it to
    /// itself. Internal so a test can see which candidates reach the signaling socket.
    func trickleLocalCandidate(_ candidate: RTCIceCandidate, handleId: Int) async {
        if let line = ICECandidateLine(candidate.sdp), !mediaRoute.keepsLocal(line) {
            if !droppedLocalAddresses.contains(line.address) {
                droppedLocalAddresses.append(line.address)
            }
            return
        }
        do {
            try await sendJanusTrickleCandidate(candidate, handleId: handleId)
        } catch {
            log.warning(.ice, "Send ICE candidate failed: \(error.localizedDescription)")
        }
    }

    /// Once a leg has gathered: names the local addresses not sent to the KVM, each once per
    /// connect. Internal so a test can check the line.
    func logHeldBackLocalCandidates() {
        let new = droppedLocalAddresses.filter { !loggedDroppedLocalAddresses.contains($0) }
        guard !new.isEmpty else { return }
        loggedDroppedLocalAddresses.formUnion(new)
        log.notice(
            .ice,
            "\(mediaRoute.limitDescription): not sending \(new.count) local address\(new.count == 1 ? "" : "es") "
                + "to the KVM (\(new.joined(separator: ", ")))"
        )
    }

    /// Tears down the current connection and connects to `device`, carrying the frame-capture
    /// setting across because teardown clears it.
    private func replaceConnection(with device: KVMDevice) async throws {
        let captureEnabled = isFrameCaptureEnabled
        tearDown(cancelReconnect: true)
        try await performConnect(to: device)
        if captureEnabled {
            setFrameCaptureEnabled(true)
        }
    }

    private func performConnect(to device: KVMDevice) async throws {
        connectionGeneration += 1
        let generation = connectionGeneration
        lastConnectedDevice = device
        // A device already known to be in WebRTC (Native) mode is not tried: Janus is stopped.
        if await isKnownToBlockStream(device) {
            guard generation == connectionGeneration else { throw WebRTCError.superseded }
            isConnecting = false
            showConnectionLost(NativeWebRTCVideoModeError.message)
            logNativeVideoModeOnce()
            throw NativeWebRTCVideoModeError()
        }
        guard generation == connectionGeneration else { throw WebRTCError.superseded }
        let route = await prepareMediaRoute(for: device)
        // Resolving a host name suspends, and a newer connect or a teardown can land meanwhile.
        guard generation == connectionGeneration else { throw WebRTCError.superseded }
        setupWebRTC(adapters: route.adapterOptions)

        guard let factory = factory else {
            throw WebRTCError.factoryNotInitialized
        }

        isConnecting = true
        isStreamStalled = false
        lastDisconnectReason = nil
        lastVideoFrameAgeSeconds = nil
        frameMeter.reset(generation: generation)
        connectedIceTime = nil
        hasEverConnectedToStream = false

        do {
            if videoView == nil {
                videoView = RTCMTLNSVideoView(frame: .zero)
            }
            
            // Create peer connection
            let configuration = RTCConfiguration()
            // A reflexive candidate is only useful when the peer is off-link. For a KVM on the
            // LAN or over Tailscale the host candidate always wins, and reaching a public STUN
            // server can only add gathering latency — or block on a network that filters it.
            configuration.iceServers = Self.iceServers(for: device, route: route, log: log)
            configuration.sdpSemantics = .unifiedPlan
            
            let constraints = RTCMediaConstraints(
                mandatoryConstraints: nil,
                optionalConstraints: ["OfferToReceiveVideo": "true"]
            )
            
            peerConnection = factory.peerConnection(
                with: configuration,
                constraints: constraints,
                delegate: self
            )
            if let peerConnection {
                peerRoles.register(peerConnection, as: .video)
            }

            if audioEnabled || micEnabled {
                let audioConstraints = RTCMediaConstraints(
                    mandatoryConstraints: nil,
                    optionalConstraints: ["OfferToReceiveAudio": "true", "OfferToReceiveVideo": "false"]
                )
                audioPeerConnection = factory.peerConnection(
                    with: configuration,
                    constraints: audioConstraints,
                    delegate: self
                )
                if let audioPeerConnection {
                    peerRoles.register(audioPeerConnection, as: .audio)
                }
            }

            var micGranted = false
            if micEnabled {
                micGranted = await ensureMicrophoneAccess()
                // The permission prompt can outlive this attempt.
                guard generation == connectionGeneration else { throw WebRTCError.superseded }
                isMicrophoneAccessDenied = !micGranted
                if micGranted {
                    setupLocalMicrophoneTrackIfNeeded(factory: factory, peerConnection: audioPeerConnection ?? peerConnection)
                }
            } else {
                isMicrophoneAccessDenied = false
            }
            negotiatedMicEnabled = micGranted
            
            // Setup data channel for input events
            setupDataChannel()
            
            // Connect to signaling server
            do {
                try await connectToSignalingServer(device: device)
            } catch WebRTCError.superseded {
                throw WebRTCError.superseded
            } catch {
                // Janus did not answer. In WebRTC (Native) mode the device has stopped it; say so
                // rather than pass on the transport error.
                guard generation == connectionGeneration else { throw WebRTCError.superseded }
                let explained = await GLKVMVideoMode.explain(error, readMode: readVideoMode)
                if let mode = explained.mode {
                    knownVideoMode = KnownVideoMode(address: device.address, mode: mode)
                }
                guard generation == connectionGeneration else { throw WebRTCError.superseded }
                if explained.error is NativeWebRTCVideoModeError {
                    logNativeVideoModeOnce()
                }
                throw explained.error
            }
            guard generation == connectionGeneration else { throw WebRTCError.superseded }

            // Start connection quality monitoring
            startStatsPolling()
            startStreamHealthMonitoring()
        } catch {
            // A newer connect or teardown has replaced this attempt's state; it is not ours to reset.
            guard generation == connectionGeneration else { throw WebRTCError.superseded }
            let reason = Self.failureReason(error, prefix: "Connect failed")
            tearDown(cancelReconnect: false)
            if error is NativeWebRTCVideoModeError {
                // The overlay comes up even for a first connect: retrying will not help, and the
                // message is what the operator needs.
                showConnectionLost(reason)
            } else {
                lastDisconnectReason = reason
            }
            throw error
        }
    }

    // MARK: - Video mode

    /// The video mode last read for one address.
    struct KnownVideoMode: Equatable {
        let address: DeviceAddress
        let mode: String
    }

    /// Keeps the mode Settings read from the connected device.
    func noteVideoMode(_ mode: String, for address: DeviceAddress) {
        knownVideoMode = KnownVideoMode(address: address, mode: mode)
    }

    /// Whether `device` is known to be in WebRTC (Native) mode. Only a known native mode is read
    /// again before it refuses a connect, so a mode changed in the web page since is picked up;
    /// when that read fails the known mode stands.
    private func isKnownToBlockStream(_ device: KVMDevice) async -> Bool {
        guard let known = knownVideoMode, known.address == device.address,
              GLKVMVideoMode.blocksStream(known.mode) else { return false }
        if let readVideoMode, let mode = await readVideoMode() {
            knownVideoMode = KnownVideoMode(address: device.address, mode: mode)
            return GLKVMVideoMode.blocksStream(mode)
        }
        return true
    }

    /// The log has the message once per operator connect or reconnect.
    private func logNativeVideoModeOnce() {
        guard !hasLoggedNativeVideoMode else { return }
        hasLoggedNativeVideoMode = true
        log.error(.lifecycle, NativeWebRTCVideoModeError.message)
    }

    /// What the overlay says for a failed attempt: the video-mode message on its own, or the error
    /// after `prefix`.
    nonisolated static func failureReason(_ error: Error, prefix: String) -> String {
        if error is NativeWebRTCVideoModeError {
            return NativeWebRTCVideoModeError.message
        }
        return "\(prefix): \(String(describing: error))"
    }

    /// `reason` is what the session history shows for this reconnect.
    func reconnect(to device: KVMDevice, reason: String = "Reconnect requested") async {
        // An explicit reconnect supersedes any retry loop in progress.
        consecutiveStallReconnects = 0
        hasLoggedNativeVideoMode = false
        noteReconnect(reason: reason)
        do {
            try await replaceConnection(with: device)
        } catch {
            if case WebRTCError.superseded = error { return }
            isConnecting = false
            showConnectionLost(Self.failureReason(error, prefix: "Reconnect failed"))
        }
    }

    /// Reconnects to the last device after a signaling, ICE, or stream failure, retrying with
    /// backoff. One loop at a time; an operator connect or disconnect cancels it. With
    /// `skipIfRecovered` the loop stands down if the connection is back up when the first delay
    /// ends (ICE `disconnected` is often transient).
    @discardableResult
    private func requestReconnect(
        reason: String,
        delayNanoseconds: UInt64 = 500_000_000,
        skipIfRecovered: Bool = false
    ) -> Bool {
        guard reconnectTask == nil else {
            self.log.debug(.lifecycle, "Reconnect suppressed (\(reason)): a loop is already running")
            return false
        }
        guard let device = lastConnectedDevice else {
            self.log.debug(.lifecycle, "Reconnect suppressed (\(reason)): no device to reconnect to")
            return false
        }
        self.log.warning(.lifecycle, "Reconnect starting: \(reason)")
        reconnectTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Whoever cancelled this loop has already replaced the handle; don't wipe theirs.
            defer { if !Task.isCancelled { self.reconnectTask = nil } }
            let captureEnabled = self.isFrameCaptureEnabled
            let delays: [UInt64] = [delayNanoseconds, 1_000_000_000, 2_000_000_000, 4_000_000_000]
            for (index, delay) in delays.enumerated() {
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else { return }
                if skipIfRecovered, index == 0, self.isConnected {
                    // Recovered on its own during the delay. Nothing dropped, so the session
                    // history must not gain a reconnect and the overlay must not gain a reason.
                    self.log.info(.lifecycle, "Reconnect stood down, connection recovered: \(reason)")
                    return
                }
                if index == 0 {
                    // Past the stand-down check: this is a real reconnect, so record it now.
                    self.lastDisconnectReason = reason
                    self.noteReconnect(reason: reason)
                }
                self.tearDown(cancelReconnect: false)
                // Keep the "Connection Lost" overlay up between attempts instead of a blank surface.
                self.showConnectionLost(reason)
                do {
                    try await self.performConnect(to: device)
                    if captureEnabled {
                        self.setFrameCaptureEnabled(true)
                    }
                    self.log.notice(.lifecycle, "Reconnect succeeded on attempt \(index + 1)")
                    // A session whose first connect failed starts its clock here.
                    self.telemetry.update { if $0.sessionConnectedAt == nil { $0.sessionConnectedAt = Date() } }
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    if case WebRTCError.superseded = error { return }
                    if error is NativeWebRTCVideoModeError {
                        // Retrying cannot help until the mode is changed in the web page; the
                        // overlay says so and keeps its Reconnect button.
                        self.showConnectionLost(NativeWebRTCVideoModeError.message)
                        return
                    }
                    self.log.error(
                        .lifecycle,
                        "Reconnect retry \(index + 1)/\(delays.count) failed: \(error.localizedDescription)"
                    )
                    self.showConnectionLost("\(reason) · retry \(index + 1) failed: \(error.localizedDescription)")
                }
            }
            self.log.error(.lifecycle, "Reconnect gave up after \(delays.count) attempts: \(reason)")
            // Every retry failed: the overlay stays, with its Reconnect button, for the operator.
        }
        return true
    }

    /// Session history for the connections panel: how many times this session has been
    /// reconnected, automatically or by hand, and why the last time.
    private func noteReconnect(reason: String) {
        telemetry.update { snapshot in
            snapshot.sessionReconnectCount += 1
            snapshot.sessionLastReconnectReason = reason
            snapshot.sessionLastReconnectAt = Date()
        }
    }

    /// Puts the surface into its "Connection Lost" state with `reason` and a Reconnect button.
    private func showConnectionLost(_ reason: String) {
        hasEverConnectedToStream = true
        lastDisconnectReason = reason
    }

    /// A stalled stream is reconnected at most a couple of times in a row; after that the overlay
    /// stays up with its Reconnect button and the decision is the operator's.
    private func reconnectAfterStall() {
        guard consecutiveStallReconnects < Self.maxConsecutiveStallReconnects else {
            self.log.error(
                .stream,
                "Stall reconnect budget spent (\(Self.maxConsecutiveStallReconnects)); waiting for the operator"
            )
            return
        }
        if requestReconnect(reason: "Video stream stalled") {
            consecutiveStallReconnects += 1
        }
    }

    func setFrameCaptureEnabled(_ enabled: Bool) {
        isFrameCaptureEnabled = enabled
        frameMeter.setKeepsFrames(enabled)

        if enabled == false {
            currentFrame = nil
        }
    }
    
    private func setupDataChannel() {
        guard let peerConnection = peerConnection else { return }
        
        let dataChannelConfig = RTCDataChannelConfiguration()
        dataChannelConfig.isOrdered = true
        dataChannelConfig.isNegotiated = false
        dataChannelConfig.channelId = 0
        
        dataChannel = peerConnection.dataChannel(
            forLabel: "input-events",
            configuration: dataChannelConfig
        )
        dataChannel?.delegate = self
    }

    func setPreferLowLatencyPlayout(_ enabled: Bool) {
        preferLowLatencyPlayout = enabled
        applyPlayoutDelayHintIfPossible()
    }

    private func applyPlayoutDelayHintIfPossible() {
        guard let peerConnection else { return }
        guard preferLowLatencyPlayout else { return }
        for receiver in peerConnection.receivers {
            guard let kind = receiver.track?.kind else { continue }
            guard kind == "video" || kind == "audio" else { continue }
            WebRTCFactoryBuilder.setPlayoutDelayHintIfSupportedFor(receiver, seconds: 0.0)
        }
    }
    
    private func connectToSignalingServer(device: KVMDevice) async throws {
        guard let rawURL = URL(string: device.webRTCURL) else {
            throw WebRTCError.invalidSignalingURL
        }

        let url = normalizedWebSocketURL(rawURL)
        self.log.info(.signaling, "Signaling connect: \(url.absoluteString)")

        let config = URLSessionConfiguration.default
        // Same host:port as the HTTP API, so the certificate pinned there applies here too.
        let session = URLSession(configuration: config, delegate: DeviceTrustSessionDelegate(log: log), delegateQueue: nil)
        signalingSession = session

        var request = URLRequest(url: url)
        if !device.authToken.isEmpty {
            request.setValue("auth_token=\(device.authToken)", forHTTPHeaderField: "Cookie")
        }
        request.setValue(device.originURL, forHTTPHeaderField: "Origin")
        request.setValue("janus-protocol", forHTTPHeaderField: "Sec-WebSocket-Protocol")

        let socketTask = session.webSocketTask(with: request)
        webSocketTask = socketTask
        let sender = makeSignalingSender(for: URLSessionSignalingSocket(socketTask))
        socketTask.resume()

        let generation = connectionGeneration
        signalingListenerTask?.cancel()
        signalingListenerTask = Task { [weak self] in
            guard let self else { return }
            await self.listenForSignalingMessages(socket: socketTask, generation: generation)
        }

        // Janus session setup. Every step goes out on this connect's own sender and checks that the
        // connect is still current when it resumes: after a teardown, `signalingSender` and the
        // handle IDs belong to the next connection, and carrying on would attach to its session.
        let createResponse = try await requestJanus(["janus": "create"], on: sender, generation: generation)
        guard let data = createResponse["data"] as? [String: Any],
              let sessionId = data["id"] as? Int else {
            throw WebRTCError.signalingConnectionLost
        }
        janusSessionId = sessionId

        let attachResponse = try await requestJanus([
            "janus": "attach",
            "plugin": "janus.plugin.ustreamer",
            "opaque_id": "oid-\(UUID().uuidString)",
            "session_id": sessionId,
        ], on: sender, generation: generation)
        guard let attachData = attachResponse["data"] as? [String: Any],
              let handleId = attachData["id"] as? Int else {
            throw WebRTCError.signalingConnectionLost
        }
        janusHandleId = handleId

        // Video handle always requests video-only to avoid A/V sync causing video buffering.
        // Nothing waits on a `watch`: Janus acks it, and the event that follows with the offer is
        // handled by the listener whenever it comes.
        try await sendJanusMessage([
            "janus": "message",
            "body": [
                "request": "watch",
                "params": [
                    "orientation": 0,
                    "audio": false,
                    "video": true,
                    "mic": false,
                    "camera": false,
                ],
            ],
            "transaction": makeJanusTransaction(),
            "session_id": sessionId,
            "handle_id": handleId,
        ], on: sender)
        guard generation == connectionGeneration else { throw WebRTCError.superseded }

        if (audioEnabled || negotiatedMicEnabled), let audioPeerConnection {
            let audioAttachResponse = try await requestJanus([
                "janus": "attach",
                "plugin": "janus.plugin.ustreamer",
                "opaque_id": "oid-audio-\(UUID().uuidString)",
                "session_id": sessionId,
            ], on: sender, generation: generation)
            guard let audioAttachData = audioAttachResponse["data"] as? [String: Any],
                  let audioHandleId = audioAttachData["id"] as? Int else {
                throw WebRTCError.signalingConnectionLost
            }
            janusAudioHandleId = audioHandleId

            // The device carries the microphone on the audio session's transceiver, so a mic-only
            // request has to ask for audio too (its own web client enforces "mic only with audio").
            // Playback of that audio is muted locally when the Audio toggle is off.
            try await sendJanusMessage([
                "janus": "message",
                "body": [
                    "request": "watch",
                    "params": [
                        "orientation": 0,
                        "audio": audioEnabled || negotiatedMicEnabled,
                        "video": false,
                        "mic": negotiatedMicEnabled,
                        "camera": false,
                    ],
                ],
                "transaction": makeJanusTransaction(),
                "session_id": sessionId,
                "handle_id": audioHandleId,
            ], on: sender)
            guard generation == connectionGeneration else { throw WebRTCError.superseded }

            _ = audioPeerConnection
        }

        startJanusKeepAlive()
    }

    private func startJanusKeepAlive() {
        janusKeepAliveTimer?.invalidate()
        let generation = connectionGeneration
        lastJanusAckAt = Date()
        janusKeepAliveTimer = Self.scheduleCommonModeTimer(
            interval: Self.janusKeepAliveInterval
        ) { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                guard generation == self.connectionGeneration else { return }

                // Silence for longer than the server's own timeout window means the session is
                // already gone, whatever the socket still claims.
                if let last = self.lastJanusAckAt,
                   Date().timeIntervalSince(last) > Self.janusAckSilenceLimit {
                    self.log.error(
                        .signaling,
                        "No Janus ack for \(Int(Date().timeIntervalSince(last)))s; treating session as dead"
                    )
                    self.requestReconnect(reason: "Signaling went silent")
                    return
                }

                do {
                    try await self.sendJanusKeepAlive()
                } catch {
                    // A keepalive cancelled by a teardown must not reconnect what was just hung up.
                    guard generation == self.connectionGeneration else { return }
                    // The sender reports a socket that missed a deadline itself, once (see
                    // `signalingSendMissedDeadline`); a second reconnect request here would only
                    // be suppressed.
                    if error is JanusSignalingSender.SendError { return }
                    self.log.error(.signaling, "Keepalive send failed: \(error.localizedDescription)")
                    self.requestReconnect(reason: "Signaling keepalive failed")
                }
            }
        }
    }

    /// `Timer.scheduledTimer` installs into `.default`, which stops firing for the duration of
    /// any modal run-loop tracking: an open menu, a window drag or resize, a scroll tracking
    /// loop. A minute of that is enough for Janus to reap the session at the far end. Every
    /// timer that keeps a connection alive belongs in `.common`.
    private static func scheduleCommonModeTimer(
        interval: TimeInterval,
        _ body: @escaping @MainActor () -> Void
    ) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { body() }
        }
        // Keepalives and stall detection are correctness, not animation: no slack.
        timer.tolerance = 0
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    private func sendJanusKeepAlive() async throws {
        guard let sessionId = janusSessionId else { return }
        try await sendJanusMessage([
            "janus": "keepalive",
            "session_id": sessionId,
            "transaction": makeJanusTransaction(),
        ])
    }

    private func sendJanusTrickleCandidate(_ candidate: RTCIceCandidate, handleId: Int) async throws {
        guard let sessionId = janusSessionId else {
            return
        }

        try await sendJanusMessage([
            "janus": "trickle",
            "candidate": [
                "candidate": candidate.sdp,
                "sdpMid": candidate.sdpMid ?? "0",
                "sdpMLineIndex": Int(candidate.sdpMLineIndex),
            ],
            "transaction": makeJanusTransaction(),
            "session_id": sessionId,
            "handle_id": handleId,
        ])
    }

    private func sendJanusTrickleCompleted(handleId: Int) async throws {
        guard let sessionId = janusSessionId else {
            return
        }

        try await sendJanusMessage([
            "janus": "trickle",
            "candidate": ["completed": true],
            "transaction": makeJanusTransaction(),
            "session_id": sessionId,
            "handle_id": handleId,
        ])
    }

    private func makeJanusTransaction() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    /// Sends `message` on `socket` as a new transaction and returns Janus's answer to it. The
    /// waiter is registered before the send (see `JanusTransactions`); a device that never answers
    /// fails the request after `janusTransactionTimeoutNs` rather than leaving connect() suspended.
    private func requestJanus(
        _ message: [String: Any],
        on sender: JanusSignalingSender,
        generation: Int
    ) async throws -> [String: Any] {
        let transaction = makeJanusTransaction()
        var request = message
        request["transaction"] = transaction
        let reply = try await janusTransactions.request(transaction) { [weak self] in
            guard let self else { throw WebRTCError.superseded }
            try await self.sendJanusMessage(request, on: sender)
        }
        guard generation == connectionGeneration else { throw WebRTCError.superseded }
        return reply
    }

    /// Sends on the current connection's signaling socket. After a teardown there is none, and
    /// nothing is sent.
    private func sendJanusMessage(_ message: [String: Any]) async throws {
        guard let signalingSender else {
            throw JanusSignalingSender.SendError.closed
        }
        try await sendJanusMessage(message, on: signalingSender)
    }

    private func sendJanusMessage(_ message: [String: Any], on sender: JanusSignalingSender) async throws {
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let text = String(data: data, encoding: .utf8) else {
            throw WebRTCError.signalingConnectionLost
        }
        try await sender.send(.string(text), describing: JanusSignalingSender.describe(message))
    }

    /// The send path for the connection being made, on `socket`. A frame that misses its deadline
    /// reconnects that connection, unless a teardown has replaced it by then. Internal so a test
    /// can hand it a socket of its own.
    @discardableResult
    func makeSignalingSender(
        for socket: SignalingSocket,
        timing: JanusSignalingSender.Timing = .standard
    ) -> JanusSignalingSender {
        let generation = connectionGeneration
        let sender = JanusSignalingSender(socket: socket, timing: timing) { [weak self] what, deadline in
            self?.signalingSendMissedDeadline(what, deadline: deadline, generation: generation)
        }
        signalingSender?.close()
        signalingSender = sender
        return sender
    }

    /// A socket that has not taken a frame within its deadline has stopped draining; waiting for
    /// a read to fail, or for the ack-silence limit, can take minutes on a black-holed path.
    private func signalingSendMissedDeadline(_ what: String, deadline: Duration, generation: Int) {
        // A teardown closes the sender first, so this is only a backstop: a stuck send must never
        // reconnect a connection that has been hung up or replaced.
        guard generation == connectionGeneration else { return }
        let milliseconds = Int((deadline / .milliseconds(1)).rounded())
        self.log.error(
            .signaling,
            "Signaling socket did not take a \(what) frame within \(milliseconds) ms; treating it as dead"
        )
        requestReconnect(reason: "Signaling send timed out")
    }

    private func normalizedWebSocketURL(_ url: URL) -> URL {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }

        if comps.scheme == "https" {
            comps.scheme = "wss"
        } else if comps.scheme == "http" {
            comps.scheme = "ws"
        } else if comps.scheme == nil {
            comps.scheme = "wss"
        }

        return comps.url ?? url
    }
    
    private func listenForSignalingMessages(socket: URLSessionWebSocketTask, generation: Int) async {
        while !Task.isCancelled, generation == connectionGeneration {
            do {
                let message = try await socket.receive()
                guard generation == connectionGeneration else { return }
                await handleSignalingMessage(message)
            } catch {
                // A listener for a torn-down connection must not touch the state of its successor.
                guard !Task.isCancelled, generation == connectionGeneration else { return }
                self.log.error(.signaling, "Signaling socket read failed: \(error.localizedDescription)")
                isConnecting = false
                if isConnected || hasEverConnectedToStream || lastDisconnectReason == nil {
                    lastDisconnectReason = "Signaling connection lost"
                }
                requestReconnect(reason: "Signaling connection lost")
                break
            }
        }
    }
    
    private func handleSignalingMessage(_ message: URLSessionWebSocketTask.Message) async {
        switch message {
        case .string(let string):
            guard let data = string.data(using: .utf8),
                  let signalingMessage = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return
            }

            await handleJanusMessage(signalingMessage)
            
        case .data(let data):
            guard let signalingMessage = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return
            }

            await handleJanusMessage(signalingMessage)
            
        @unknown default:
            break
        }
    }

    /// Internal so a test can hand it recorded messages.
    func handleJanusMessage(_ message: [String: Any]) async {
        // Only a transaction someone is *waiting* on short-circuits here. Keepalives register no
        // waiter on purpose, so their acks fall through to the switch below and refresh
        // `lastJanusAckAt` — which is the whole liveness check. Registering a waiter for them
        // would silently break it.
        if janusTransactions.deliver(message) {
            return
        }

        guard let janusType = message["janus"] as? String else { return }

        // A candidate or an offer is applied to the peer of the leg whose handle sent it, and to
        // no peer when that handle is not one of the current connection's.
        let leg: JanusLeg?
        switch janusSenders.verdict(for: message, videoHandle: janusHandleId, audioHandle: janusAudioHandleId) {
        case .leg(let senderLeg):
            leg = senderLeg
        case .session:
            leg = nil
        case .drop(let sender, let isFirst):
            if isFirst {
                self.log.info(
                    .signaling,
                    "Dropped Janus \(JanusSenderFilter.describe(message)) from unknown sender "
                        + "\(sender.map(String.init) ?? "(none)"); later ones from it are dropped silently"
                )
            }
            return
        }

        if janusType == "trickle" {
            guard let leg,
                  let peerConnection = peer(for: leg),
                  let candidateObj = message["candidate"] as? [String: Any],
                  let candidateString = candidateObj["candidate"] as? String else {
                return
            }

            if (candidateObj["completed"] as? Bool) == true {
                return
            }
            guard keepsTrickledRemoteCandidate(candidateString) else { return }

            let sdpMid = candidateObj["sdpMid"] as? String
            let sdpMLineIndex: Int32
            if let idx32 = candidateObj["sdpMLineIndex"] as? Int32 {
                sdpMLineIndex = idx32
            } else if let idx = candidateObj["sdpMLineIndex"] as? Int {
                sdpMLineIndex = Int32(idx)
            } else {
                sdpMLineIndex = 0
            }
            let iceCandidate = RTCIceCandidate(sdp: candidateString, sdpMLineIndex: sdpMLineIndex, sdpMid: sdpMid)
            try? await peerConnection.add(iceCandidate)
            return
        }

        let senderHandleId = message["sender"] as? Int

        // Janus's asynchronous notifications. These used to be dropped on the floor by an early
        // `janusType != "event"` bail, which is why a disconnect never had a server-side reason
        // attached to it: `hangup` carries one, and `timeout` says the session was reaped because
        // our keepalives stopped arriving. Fields are logged as the server sent them rather than
        // interpreted — Janus's `uplink`/`receiving` semantics differ between versions, and a log
        // that records the wrong reading of a flag is worse than one that records the flag.
        switch janusType {
        case "ack":
            lastJanusAckAt = Date()
            return

        case "keepalive":
            lastJanusAckAt = Date()
            return

        case "webrtcup":
            self.log.notice(.signaling, "Janus webrtcup on \(janusHandleLabel(senderHandleId)) handle")
            return

        case "media":
            let kind = message["type"] as? String ?? "?"
            let receiving = message["receiving"] as? Bool
            let mid = message["mid"] as? String
            let midText = mid.map { " mid=\($0)" } ?? ""
            let text = "Janus media \(kind) receiving=\(receiving.map(String.init(describing:)) ?? "?")"
                + "\(midText) on \(janusHandleLabel(senderHandleId)) handle"
            if receiving == false {
                // The server has stopped seeing media on this leg. Distinguishes a source-side
                // stall from anything happening on our own link.
                self.log.warning(.stream, text)
                if kind == "video" {
                    setLastDisconnectReason("Device stopped sending video")
                }
            } else {
                self.log.notice(.stream, text)
                // Janus repeats these; without the clear, a recovered stream leaves a stale
                // reason behind for whatever overlay comes up next.
                if kind == "video", lastDisconnectReason == "Device stopped sending video" {
                    setLastDisconnectReason(nil)
                }
            }
            return

        case "slowlink":
            let lost = message["lost"] as? Int
            let uplink = message["uplink"] as? Bool
            let mid = message["mid"] as? String
            self.log.warning(
                .stream,
                "Janus slowlink lost=\(lost.map(String.init) ?? "?") "
                    + "uplink=\(uplink.map(String.init(describing:)) ?? "?") "
                    + "mid=\(mid ?? "?") on \(janusHandleLabel(senderHandleId)) handle"
            )
            return

        case "hangup":
            let reason = message["reason"] as? String ?? "no reason given"
            self.log.error(.signaling, "Janus hangup on \(janusHandleLabel(senderHandleId)) handle: \(reason)")
            // Only the video leg drives the UI; an audio hangup is noted and otherwise ignored,
            // the same rule the ICE delegate follows.
            if senderHandleId == nil || senderHandleId == janusHandleId {
                requestReconnect(reason: "Server hung up: \(reason)")
            }
            return

        case "detached":
            self.log.notice(.signaling, "Janus detached \(janusHandleLabel(senderHandleId)) handle")
            return

        case "timeout":
            // The session was reaped server-side: our keepalives stopped arriving in time.
            let sinceAck = lastJanusAckAt.map { Int(Date().timeIntervalSince($0)) }
            self.log.error(
                .signaling,
                "Janus session timed out (last ack \(sinceAck.map { "\($0)s ago" } ?? "never"))"
            )
            requestReconnect(reason: "Signaling session timed out")
            return

        case "error":
            let error = message["error"] as? [String: Any]
            let code = error?["code"] as? Int
            let reason = error?["reason"] as? String ?? "unknown"
            self.log.error(.signaling, "Janus error \(code.map(String.init) ?? "?"): \(reason)")
            return

        case "event":
            break

        default:
            self.log.debug(.signaling, "Janus \(janusType) (unhandled)")
            return
        }

        if let plugindata = message["plugindata"] as? [String: Any],
           let data = plugindata["data"] as? [String: Any] {
            if let error = data["error"] as? String {
                let code = data["error_code"] as? Int
                self.log.error(.signaling, "Streaming plugin error \(code.map(String.init) ?? "?"): \(error)")
            } else if let status = data["status"] as? String {
                self.log.info(.signaling, "Streaming plugin status: \(status)")
            }
        }

        guard let leg,
              let jsep = message["jsep"] as? [String: Any],
              let jsepType = jsep["type"] as? String,
              jsepType == "offer",
              let sdpString = jsep["sdp"] as? String else {
            return
        }

        await handleOfferSDP(sdpString, leg: leg)
    }

    private func peer(for leg: JanusLeg) -> RTCPeerConnection? {
        switch leg {
        case .video: return peerConnection
        case .audio: return audioPeerConnection
        }
    }

    /// `RTCIceConnectionState` is an ObjC enum: it logs as an integer unless named.
    static func iceStateName(_ state: RTCIceConnectionState) -> String {
        switch state {
        case .new: return "new"
        case .checking: return "checking"
        case .connected: return "connected"
        case .completed: return "completed"
        case .failed: return "failed"
        case .disconnected: return "disconnected"
        case .closed: return "closed"
        case .count: return "count"
        @unknown default: return "unknown(\(state.rawValue))"
        }
    }

    /// "video", "audio", or "unknown" for whichever Janus handle a notification came from.
    private func janusHandleLabel(_ senderHandleId: Int?) -> String {
        guard let senderHandleId else { return "unknown" }
        if senderHandleId == janusHandleId { return "video" }
        if senderHandleId == janusAudioHandleId { return "audio" }
        return "unknown"
    }
    
    private func handleOfferSDP(_ sdpString: String, leg: JanusLeg) async {
        let handleId: Int?
        switch leg {
        case .video: handleId = janusHandleId
        case .audio: handleId = janusAudioHandleId
        }
        guard let peerConnection = peer(for: leg), let handleId else { return }
        
        await applyRemoteOffer(sdpString, leg: leg) { offer in
            try await peerConnection.setRemoteDescription(offer)
        }

        // The audio handle asks for `video: false`, a parameter the device's own client never
        // sends. If the plugin offers video anyway, decline it here rather than decode the
        // stream twice.
        if peerConnection === audioPeerConnection {
            for transceiver in peerConnection.transceivers where transceiver.mediaType == .video {
                // `-setDirection:error:` returns void, so Swift imports the error out-parameter
                // rather than making the call throw.
                transceiver.setDirection(.inactive, error: nil)
            }
        }

        // Create and send answer
        await createAndSendAnswer(peerConnection: peerConnection, handleId: handleId)
    }

    private func createAndSendAnswer(peerConnection: RTCPeerConnection, handleId: Int) async {
        let generation = connectionGeneration
        do {
            let generated = try await peerConnection.answer(
                for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
            )
            // libwebrtc configures its receive-side Opus decoder from the *local* description, so
            // without `stereo=1` in our answer the device's stereo stream is decoded as mono. Same
            // edit the device's own web client makes.
            let sessionDescription = RTCSessionDescription(
                type: generated.type,
                sdp: generated.sdp.replacingOccurrences(of: "useinbandfec=1", with: "useinbandfec=1;stereo=1")
            )
            try await peerConnection.setLocalDescription(sessionDescription)
        } catch {
            self.log.error(.signaling, "Create/send answer failed: \(error.localizedDescription)")
            return
        }
        
        // Send answer to Janus. Making it suspends twice, and a teardown in between hands the
        // session to the next connection: this answer belongs to a handle that is gone.
        guard generation == connectionGeneration,
              let localDescription = peerConnection.localDescription,
              let sessionId = janusSessionId else {
            return
        }

        let startTransaction = makeJanusTransaction()
        do {
            try await sendJanusMessage([
                "janus": "message",
                "body": ["request": "start"],
                "transaction": startTransaction,
                "session_id": sessionId,
                "handle_id": handleId,
                "jsep": [
                    "type": "answer",
                    "sdp": localDescription.sdp,
                ],
            ])
        } catch {
            self.log.error(.signaling, "Send Janus answer failed: \(error.localizedDescription)")
        }
    }
    
    private func startStatsPolling() {
        connectionTimer?.invalidate()
        connectionTimer = Self.scheduleCommonModeTimer(interval: 1.0) { [weak self] in
            Task { @MainActor in
                await self?.measureStreamStats()
            }
        }
    }

    private func startStreamHealthMonitoring() {
        streamHealthTimer?.invalidate()
        streamHealthTimer = Self.scheduleCommonModeTimer(interval: 1.0) { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                let now = CACurrentMediaTime()

                // Every write here is compare-before-write: this ticks once a second for the
                // life of a connection, and an unchanged value must not publish.
                if self.isConnected == false {
                    self.setIsStreamStalled(false)
                    self.setLastVideoFrameAgeSeconds(nil)
                    return
                }

                let lastFrame = self.lastVideoFrameTimestamp
                let age = lastFrame.map { now - $0 }

                if let age {
                    self.setLastVideoFrameAgeSeconds(max(0, Int(age.rounded())))
                } else {
                    self.setLastVideoFrameAgeSeconds(nil)
                }

                if let age, age > self.streamStallThresholdSeconds {
                    if self.isStreamStalled == false {
                        self.log.warning(
                            .stream,
                            "Video stalled: no frame for \(String(format: "%.1f", age))s "
                                + "(threshold \(String(format: "%.1f", self.streamStallThresholdSeconds))s)"
                        )
                        self.setIsStreamStalled(true)
                        self.setLastDisconnectReason("Video stream stalled")
                        self.reconnectAfterStall()
                    }
                    return
                }

                if let age, age <= self.streamStallThresholdSeconds {
                    // Video is flowing; a later stall starts with a fresh retry budget.
                    self.consecutiveStallReconnects = 0
                }

                if lastFrame == nil,
                   let connectedAt = self.connectedIceTime,
                   now - connectedAt > self.initialFrameTimeoutSeconds {
                    if self.isStreamStalled == false {
                        self.log.warning(
                            .stream,
                            "No first frame \(String(format: "%.1f", now - connectedAt))s after ICE connected"
                        )
                        self.setIsStreamStalled(true)
                        self.setLastDisconnectReason("Video stream stalled")
                        self.reconnectAfterStall()
                    }
                    return
                }

                if self.isStreamStalled {
                    self.log.notice(.stream, "Video recovered")
                    self.setIsStreamStalled(false)
                    self.setLastDisconnectReason(nil)
                }
            }
        }
    }

    private func setLastVideoFrameAgeSeconds(_ value: Int?) {
        guard lastVideoFrameAgeSeconds != value else { return }
        lastVideoFrameAgeSeconds = value
    }

    private func setIsStreamStalled(_ value: Bool) {
        guard isStreamStalled != value else { return }
        isStreamStalled = value
    }

    private func setLastDisconnectReason(_ value: String?) {
        guard lastDisconnectReason != value else { return }
        lastDisconnectReason = value
    }

    /// One polling tick. Collects the video and audio samples and hands them to the telemetry
    /// model as a single transaction; the model publishes only if something rendered changes.
    /// No `MainActor.run` hops: this class is already main-actor isolated, and the old per-field
    /// hops turned one tick into several separate SwiftUI invalidations.
    private func measureStreamStats() async {
        guard let peerConnection else {
            lastInboundVideoBytesReceived = nil
            lastInboundVideoBytesTimestamp = nil
            lastJitterBufferDelaySeconds = nil
            lastJitterBufferEmittedCount = nil
            lastTotalDecodeTimeSeconds = nil
            lastTotalProcessingDelaySeconds = nil
            lastFramesDecodedForDelays = nil
            lastInboundAudioBytesReceived = nil
            lastInboundAudioBytesTimestamp = nil
            lastAudioJitterBufferDelaySeconds = nil
            lastAudioJitterBufferEmittedCount = nil
            telemetry.update { snapshot in
                snapshot.apply(video: .empty)
                snapshot.apply(audio: .empty)
            }
            return
        }

        if preferLowLatencyPlayout {
            let now = Date().timeIntervalSince1970
            if lastPlayoutHintApplyTime == nil || (now - (lastPlayoutHintApplyTime ?? 0)) > 2.0 {
                applyPlayoutDelayHintIfPossible()
                lastPlayoutHintApplyTime = now
            }
        }

        var readAudio: (@MainActor () async -> [String: StatsEntry])?
        if let audioPeerConnection {
            readAudio = { await Self.statisticsEntries(of: audioPeerConnection) }
        }
        await measureStreamStats(
            readVideo: { await Self.statisticsEntries(of: peerConnection) },
            readAudio: readAudio
        )
    }

    private static func statisticsEntries(of peerConnection: RTCPeerConnection) async -> [String: StatsEntry] {
        await peerConnection.statistics().statistics.mapValues { StatsEntry(type: $0.type, values: $0.values) }
    }

    /// Reads the video report and, when there is an audio peer, the audio one, then turns them
    /// into samples against the previous tick's counters. Internal so a test can run a tick on
    /// reports of its own.
    func measureStreamStats(
        readVideo: @MainActor () async -> [String: StatsEntry],
        readAudio: (@MainActor () async -> [String: StatsEntry])?
    ) async {
        // Both reads suspend, and a teardown or a reconnect can land during either. The teardown
        // resets the previous tick's counters, which then belong to the next connection: applied
        // after that, an old peer's report became the new connection's kbps baseline (its first
        // reading compared the new peer's byte count with the old one's) and put the old
        // connection's numbers in the new session's panel. So nothing is read from or written to
        // that state until both reports are in, and then only if the connection is the same one.
        let generation = connectionGeneration
        statsTicksStarted += 1
        let tick = statsTicksStarted
        let videoReport = await readVideo()
        var audioReport: [String: StatsEntry]?
        if let readAudio {
            audioReport = await readAudio()
        }
        guard generation == connectionGeneration else {
            self.log.debug(.stream, "Dropped a stats sample from a connection that has since been replaced")
            return
        }
        guard tick > newestStatsTickApplied else {
            self.log.debug(.stream, "Dropped a stats sample that finished after a newer one")
            return
        }
        newestStatsTickApplied = tick

        let video = inboundVideoSample(from: videoReport)

        let audio: AudioStatsSample
        if let audioReport {
            audio = inboundAudioSample(from: audioReport)
        } else {
            lastInboundAudioBytesReceived = nil
            lastInboundAudioBytesTimestamp = nil
            lastAudioJitterBufferDelaySeconds = nil
            lastAudioJitterBufferEmittedCount = nil
            audio = .empty
        }

        // The candidate pair moving is the single most diagnostic line in the log on a link
        // that "never went down": a Tailscale direct↔DERP transition, a Wi-Fi/Ethernet switch,
        // or a NAT rebinding all show up here first, seconds before anything else notices.
        if let path = video.networkPath {
            let described = "\(path) → \(video.networkRemoteAddress ?? "?")"
            if let previous = lastLoggedCandidatePath, previous != described {
                self.log.notice(.ice, "Candidate pair changed: \(previous) ⇒ \(described)")
            } else if lastLoggedCandidatePath == nil {
                self.log.info(.ice, "Candidate pair: \(described)")
            }
            lastLoggedCandidatePath = described
        }

        telemetry.update { snapshot in
            snapshot.apply(video: video)
            snapshot.apply(audio: audio)
        }
    }

    /// The ICE candidate pair traffic is flowing over. libwebrtc names it on the `transport`
    /// statistic (`selectedCandidatePairId`); the pair itself carries no `selected` flag. A
    /// nominated, succeeded pair is the fallback for builds that lack the transport entry.
    private static func selectedCandidatePair(in report: [String: StatsEntry]) -> StatsEntry? {
        for statistic in report.values where statistic.type == "transport" {
            if let pairId = statistic.values["selectedCandidatePairId"] as? String,
               let pair = report[pairId] {
                return pair
            }
        }
        for statistic in report.values where statistic.type == "candidate-pair" {
            let state = statistic.values["state"] as? String
            let nominated = (statistic.values["nominated"] as? Bool)
                ?? (statistic.values["nominated"] as? NSNumber)?.boolValue
                ?? false
            if state == "succeeded", nominated {
                return statistic
            }
        }
        return nil
    }

    /// "host → host · UDP", plus the remote address, for the selected pair.
    private static func describeNetworkPath(
        pair: StatsEntry,
        in report: [String: StatsEntry]
    ) -> (path: String?, remoteAddress: String?) {
        func candidate(_ key: String) -> StatsEntry? {
            guard let id = pair.values[key] as? String else { return nil }
            return report[id]
        }
        let local = candidate("localCandidateId")
        let remote = candidate("remoteCandidateId")
        guard local != nil || remote != nil else { return (nil, nil) }

        let localType = (local?.values["candidateType"] as? String) ?? "?"
        let remoteType = (remote?.values["candidateType"] as? String) ?? "?"
        let protocolName = ((local?.values["protocol"] as? String)
            ?? (remote?.values["protocol"] as? String))?.uppercased()
        let networkType = local?.values["networkType"] as? String

        var parts = ["\(localType) → \(remoteType)"]
        if let protocolName { parts.append(protocolName) }
        if let networkType, networkType != "unknown" { parts.append(networkType) }

        var remoteAddress: String?
        if let address = (remote?.values["address"] as? String) ?? (remote?.values["ip"] as? String) {
            if let port = (remote?.values["port"] as? NSNumber)?.intValue {
                remoteAddress = "\(address):\(port)"
            } else {
                remoteAddress = address
            }
        }
        return (parts.joined(separator: " · "), remoteAddress)
    }

    private func inboundVideoSample(from report: [String: StatsEntry]) -> VideoStatsSample {
        let lastBytes = lastInboundVideoBytesReceived
        let lastTs = lastInboundVideoBytesTimestamp

        func numberValue(_ any: Any?) -> NSNumber? {
            any as? NSNumber
        }

        var bytesReceived: Int64?
        var jitterSeconds: Double?
        var jitterBufferDelaySeconds: Double?
        var jitterBufferEmittedCount: Double?
        var totalDecodeTimeSeconds: Double?
        var totalProcessingDelaySeconds: Double?
        var framesDecoded: Double?
        var packetsLost: Int?
        var framesDropped: Int?
        var pliCount: Int?
        var nackCount: Int?
        var freezeCount: Int?
        var freezeDurationMs: Int?
        var pauseCount: Int?
        var codec: String?
        var decoder: String?
        var decoderIsPowerEfficient: Bool?

        for statistic in report.values {
            guard statistic.type == "inbound-rtp" else { continue }

            if let kind = statistic.values["kind"] as? String, kind != "video" { continue }
            if let mediaType = statistic.values["mediaType"] as? String, mediaType != "video" { continue }

            if let n = numberValue(statistic.values["bytesReceived"]) {
                bytesReceived = n.int64Value
            }
            if let n = numberValue(statistic.values["jitter"]) {
                jitterSeconds = n.doubleValue
            }
            if let n = numberValue(statistic.values["jitterBufferDelay"]) {
                jitterBufferDelaySeconds = n.doubleValue
            }
            if let n = numberValue(statistic.values["jitterBufferEmittedCount"]) {
                jitterBufferEmittedCount = n.doubleValue
            }
            if let n = numberValue(statistic.values["totalDecodeTime"]) {
                totalDecodeTimeSeconds = n.doubleValue
            }
            if let n = numberValue(statistic.values["totalProcessingDelay"]) {
                totalProcessingDelaySeconds = n.doubleValue
            }
            if let n = numberValue(statistic.values["framesDecoded"]) {
                framesDecoded = n.doubleValue
            }
            if let n = numberValue(statistic.values["packetsLost"]) {
                packetsLost = n.intValue
            }
            if let n = numberValue(statistic.values["framesDropped"]) {
                framesDropped = n.intValue
            }
            if let n = numberValue(statistic.values["pliCount"]) {
                pliCount = n.intValue
            }
            if let n = numberValue(statistic.values["nackCount"]) {
                nackCount = n.intValue
            }
            if let n = numberValue(statistic.values["freezeCount"]) {
                freezeCount = n.intValue
            }
            if let n = numberValue(statistic.values["totalFreezesDuration"]) {
                freezeDurationMs = Int((n.doubleValue * 1000.0).rounded())
            }
            if let n = numberValue(statistic.values["pauseCount"]) {
                pauseCount = n.intValue
            }
            if let codecId = statistic.values["codecId"] as? String,
               let mimeType = report[codecId]?.values["mimeType"] as? String {
                // "video/H264" → "H264"
                codec = mimeType.split(separator: "/").last.map(String.init) ?? mimeType
            }
            if let implementation = statistic.values["decoderImplementation"] as? String,
               !implementation.isEmpty, implementation != "unknown" {
                decoder = implementation
            }
            if let efficient = statistic.values["powerEfficientDecoder"] as? Bool {
                decoderIsPowerEfficient = efficient
            } else if let n = numberValue(statistic.values["powerEfficientDecoder"]) {
                decoderIsPowerEfficient = n.boolValue
            }

            break
        }

        var currentRoundTripTimeSeconds: Double?
        var networkPath: String?
        var networkRemoteAddress: String?
        var availableIncomingKbps: Int?
        if let pair = Self.selectedCandidatePair(in: report) {
            if let rtt = numberValue(pair.values["currentRoundTripTime"])?.doubleValue {
                currentRoundTripTimeSeconds = rtt
            }
            if let bps = numberValue(pair.values["availableIncomingBitrate"])?.doubleValue, bps > 0 {
                availableIncomingKbps = Int((bps / 1000.0).rounded())
            }
            (networkPath, networkRemoteAddress) = Self.describeNetworkPath(pair: pair, in: report)
        }

        let now = Date().timeIntervalSince1970

        guard let bytesReceived else {
            lastInboundVideoBytesReceived = nil
            lastInboundVideoBytesTimestamp = nil
            lastTotalProcessingDelaySeconds = nil
            lastFramesDecodedForDelays = nil
            lastTotalDecodeTimeSeconds = nil
            return .empty
        }

        var kbps: Int?
        if let lastBytes, let lastTs {
            let dt = now - lastTs
            let db = Double(bytesReceived - lastBytes)
            if dt > 0, db >= 0 {
                kbps = Int((db * 8.0 / dt) / 1000.0)
            }
        }

        let jitterMs: Int?
        if let jitterSeconds {
            jitterMs = Int((jitterSeconds * 1000.0).rounded())
        } else {
            jitterMs = nil
        }

        let playoutDelayMs: Int? = {
            guard let jitterBufferDelaySeconds,
                  let jitterBufferEmittedCount,
                  jitterBufferEmittedCount > 0 else {
                return nil
            }

            if let lastDelay = lastJitterBufferDelaySeconds,
               let lastEmitted = lastJitterBufferEmittedCount {
                let dDelay = jitterBufferDelaySeconds - lastDelay
                let dEmit = jitterBufferEmittedCount - lastEmitted
                if dDelay >= 0, dEmit > 0 {
                    return Int(((dDelay / dEmit) * 1000.0).rounded())
                }
            }

            return Int(((jitterBufferDelaySeconds / jitterBufferEmittedCount) * 1000.0).rounded())
        }()

        // Decode and processing delay are cumulative totals; report the per-frame average over
        // the frames decoded since the last tick, so the number follows what is happening now
        // rather than the session-long mean. First tick falls back to the cumulative average.
        func perFrameMs(total: Double?, lastTotal: Double?) -> Int? {
            guard let total, let framesDecoded, framesDecoded > 0 else { return nil }
            if let lastTotal, let lastFrames = lastFramesDecodedForDelays {
                // No frames this window (stall, pause): show nothing rather than the session mean.
                let dFrames = framesDecoded - lastFrames
                guard dFrames > 0 else { return nil }
                let dTotal = total - lastTotal
                return dTotal >= 0 ? Int(((dTotal / dFrames) * 1000.0).rounded()) : nil
            }
            return Int(((total / framesDecoded) * 1000.0).rounded())
        }
        let decodeMs = perFrameMs(total: totalDecodeTimeSeconds, lastTotal: lastTotalDecodeTimeSeconds)
        let processingDelayMs = perFrameMs(total: totalProcessingDelaySeconds, lastTotal: lastTotalProcessingDelaySeconds)

        let rttMs: Int?
        if let currentRoundTripTimeSeconds {
            rttMs = Int((currentRoundTripTimeSeconds * 1000.0).rounded())
        } else {
            rttMs = nil
        }

        lastInboundVideoBytesReceived = bytesReceived
        lastInboundVideoBytesTimestamp = now
        lastJitterBufferDelaySeconds = jitterBufferDelaySeconds
        lastJitterBufferEmittedCount = jitterBufferEmittedCount
        lastTotalDecodeTimeSeconds = totalDecodeTimeSeconds
        lastTotalProcessingDelaySeconds = totalProcessingDelaySeconds
        lastFramesDecodedForDelays = framesDecoded

        return VideoStatsSample(
            kbps: kbps,
            playoutDelayMs: playoutDelayMs,
            jitterMs: jitterMs,
            decodeMs: decodeMs,
            processingDelayMs: processingDelayMs,
            packetsLost: packetsLost,
            framesDropped: framesDropped,
            pliCount: pliCount,
            nackCount: nackCount,
            freezeCount: freezeCount,
            freezeDurationMs: freezeDurationMs,
            pauseCount: pauseCount,
            roundTripTimeMs: rttMs,
            codec: codec,
            decoder: decoder,
            decoderIsPowerEfficient: decoderIsPowerEfficient,
            networkPath: networkPath,
            networkRemoteAddress: networkRemoteAddress,
            availableIncomingKbps: availableIncomingKbps
        )
    }

    private func inboundAudioSample(from audioReport: [String: StatsEntry]) -> AudioStatsSample {
        let lastAudioBytes = lastInboundAudioBytesReceived
        let lastAudioTs = lastInboundAudioBytesTimestamp

        func audioNumberValue(_ any: Any?) -> NSNumber? {
            any as? NSNumber
        }

        var audioBytesReceived: Int64?
        var audioJitterSeconds: Double?
        var audioJitterBufferDelaySeconds: Double?
        var audioJitterBufferEmittedCount: Double?
        var audioPacketsLost: Int?
        var audioCurrentRoundTripTimeSeconds: Double?

        if let pair = Self.selectedCandidatePair(in: audioReport),
           let rtt = audioNumberValue(pair.values["currentRoundTripTime"])?.doubleValue {
            audioCurrentRoundTripTimeSeconds = rtt
        }

        for statistic in audioReport.values {
            guard statistic.type == "inbound-rtp" else { continue }

            if let kind = statistic.values["kind"] as? String, kind != "audio" { continue }
            if let mediaType = statistic.values["mediaType"] as? String, mediaType != "audio" { continue }

            if let n = audioNumberValue(statistic.values["bytesReceived"]) {
                audioBytesReceived = n.int64Value
            }
            if let n = audioNumberValue(statistic.values["jitter"]) {
                audioJitterSeconds = n.doubleValue
            }
            if let n = audioNumberValue(statistic.values["jitterBufferDelay"]) {
                audioJitterBufferDelaySeconds = n.doubleValue
            }
            if let n = audioNumberValue(statistic.values["jitterBufferEmittedCount"]) {
                audioJitterBufferEmittedCount = n.doubleValue
            }
            if let n = audioNumberValue(statistic.values["packetsLost"]) {
                audioPacketsLost = n.intValue
            }

            break
        }

        let audioNow = Date().timeIntervalSince1970

        guard let audioBytesReceived else {
            lastInboundAudioBytesReceived = nil
            lastInboundAudioBytesTimestamp = nil
            lastAudioJitterBufferDelaySeconds = nil
            lastAudioJitterBufferEmittedCount = nil
            return .empty
        }

        var audioKbps: Int?
        if let lastAudioBytes, let lastAudioTs {
            let dt = audioNow - lastAudioTs
            let db = Double(audioBytesReceived - lastAudioBytes)
            if dt > 0, db >= 0 {
                audioKbps = Int((db * 8.0 / dt) / 1000.0)
            }
        }

        let audioJitterMs: Int?
        if let audioJitterSeconds {
            audioJitterMs = Int((audioJitterSeconds * 1000.0).rounded())
        } else {
            audioJitterMs = nil
        }

        let audioPlayoutDelayMs: Int? = {
            guard let audioJitterBufferDelaySeconds,
                  let audioJitterBufferEmittedCount,
                  audioJitterBufferEmittedCount > 0 else {
                return nil
            }

            if let lastDelay = lastAudioJitterBufferDelaySeconds,
               let lastEmitted = lastAudioJitterBufferEmittedCount {
                let dDelay = audioJitterBufferDelaySeconds - lastDelay
                let dEmit = audioJitterBufferEmittedCount - lastEmitted
                if dDelay >= 0, dEmit > 0 {
                    return Int(((dDelay / dEmit) * 1000.0).rounded())
                }
            }

            return Int(((audioJitterBufferDelaySeconds / audioJitterBufferEmittedCount) * 1000.0).rounded())
        }()

        let audioRttMs: Int?
        if let audioCurrentRoundTripTimeSeconds {
            audioRttMs = Int((audioCurrentRoundTripTimeSeconds * 1000.0).rounded())
        } else {
            audioRttMs = nil
        }

        lastInboundAudioBytesReceived = audioBytesReceived
        lastInboundAudioBytesTimestamp = audioNow
        lastAudioJitterBufferDelaySeconds = audioJitterBufferDelaySeconds
        lastAudioJitterBufferEmittedCount = audioJitterBufferEmittedCount

        return AudioStatsSample(
            kbps: audioKbps,
            playoutDelayMs: audioPlayoutDelayMs,
            jitterMs: audioJitterMs,
            packetsLost: audioPacketsLost,
            roundTripTimeMs: audioRttMs
        )
    }
    
    func sendInputEvent(_ event: InputEvent) {
        guard let data = try? JSONEncoder().encode(event),
              let dataChannel = dataChannel,
              dataChannel.readyState == .open else {
            return
        }
        
        let buffer = RTCDataBuffer(data: data, isBinary: true)
        dataChannel.sendData(buffer)
    }
    
    func disconnect() {
        // Nothing may auto-reconnect after an operator disconnect. The session logs the
        // disconnect itself: this runs again when a window closes over a session that quitting
        // has already hung up, and the log should say the operator disconnected once.
        lastConnectedDevice = nil
        consecutiveStallReconnects = 0
        telemetry.update { $0.clearSession() }
        tearDown(cancelReconnect: true)
        // Only an operator disconnect ends the session: a reconnect's teardown must keep the
        // App Nap assertion and the observers, or every retry would drop them and retake them.
        endSessionEnvironment()
    }

    /// Tears the connection down. `cancelReconnect` is false when the caller is the retry loop
    /// itself (or a reconnect that should not kill a pending retry).
    private func tearDown(cancelReconnect: Bool) {
        connectionGeneration += 1
        // First, so nothing from the old track counts towards what follows: once this returns no
        // frame from it reaches the manager, and one already past the relay is not counted.
        detachVideoTrack()
        frameMeter.reset(generation: connectionGeneration)
        signalingListenerTask?.cancel()
        signalingListenerTask = nil
        if cancelReconnect {
            reconnectTask?.cancel()
            reconnectTask = nil
        }

        connectionTimer?.invalidate()
        connectionTimer = nil

        streamHealthTimer?.invalidate()
        streamHealthTimer = nil

        lastLoggedCandidatePath = nil
        lastJanusAckAt = nil
        mediaAddressesInEffect = nil

        janusKeepAliveTimer?.invalidate()
        janusKeepAliveTimer = nil
        janusSessionId = nil
        janusHandleId = nil
        janusAudioHandleId = nil
        janusSenders.reset()
        janusTransactions.failAll(WebRTCError.signalingConnectionLost)
        // Fails every send in flight or queued at once, without waiting on a socket that may never
        // give a frame back.
        signalingSender?.close()
        signalingSender = nil
        
        webSocketTask?.cancel()
        webSocketTask = nil
        // A URLSession retains itself and its delegate until invalidated; one was leaked per connect.
        signalingSession?.invalidateAndCancel()
        signalingSession = nil
        
        dataChannel?.close()
        dataChannel = nil
        
        // Their closing ICE callbacks are handled after the references below are cleared, and
        // still have to be told apart.
        peerRoles.retireAll()
        peerConnection?.close()
        peerConnection = nil

        audioPeerConnection?.close()
        audioPeerConnection = nil

        localAudioSender = nil
        localAudioTrack = nil
        
        videoView = nil
        isConnected = false
        isConnecting = false
        hasEverConnectedToStream = false
        isStreamStalled = false
        lastDisconnectReason = nil
        lastVideoFrameAgeSeconds = nil
        connectedIceTime = nil
        videoSize = nil
        isFrameCaptureEnabled = false
        frameMeter.setKeepsFrames(false)
        // The video view is gone too; a screenshot now would show a stream that no longer exists.
        captureHub.clearLatestFrame()
        telemetry.clearStreamStats()
        lastInboundVideoBytesReceived = nil
        lastInboundVideoBytesTimestamp = nil
        lastJitterBufferDelaySeconds = nil
        lastJitterBufferEmittedCount = nil
        lastTotalDecodeTimeSeconds = nil
        lastTotalProcessingDelaySeconds = nil
        lastFramesDecodedForDelays = nil
        lastInboundAudioBytesReceived = nil
        lastInboundAudioBytesTimestamp = nil
        lastAudioJitterBufferDelaySeconds = nil
        lastAudioJitterBufferEmittedCount = nil
    }

    // MARK: - Video track

    /// Renders `track` in the video view and counts its frames for this connection, after taking
    /// everything off the track it replaces. Internal so a test can hand it a track of its own.
    func attachVideoTrack(_ track: VideoRendererHost) {
        detachVideoTrack()
        let generation = connectionGeneration
        let relay = VideoFrameRelay(
            onFrame: { [weak self] frame in self?.handleDecodedFrame(frame, generation: generation) },
            onSize: { [weak self] size in self?.handleVideoSize(size, generation: generation) }
        )
        var renderers: [RTCVideoRenderer] = []
        if let videoView {
            track.add(videoView)
            renderers.append(videoView)
        }
        track.add(relay)
        renderers.append(relay)
        videoTrack = track
        videoTrackRenderers = renderers
        videoFrameRelay = relay
    }

    /// Takes every renderer this manager added off the current video track and lets go of it.
    /// The relay is retired first, so a frame it is handing on right now finishes before this
    /// returns, and nothing after it gets through.
    private func detachVideoTrack() {
        videoFrameRelay?.retire()
        videoFrameRelay = nil
        if let videoTrack {
            for renderer in videoTrackRenderers {
                videoTrack.remove(renderer)
            }
        }
        videoTrack = nil
        videoTrackRenderers = []
    }

    /// libwebrtc's decoder thread, by way of the relay of the track the frame came from;
    /// `generation` is that track's connection. A frame from a connection that is no longer current
    /// is dropped here, and work it queued for the main actor is dropped there.
    nonisolated private func handleDecodedFrame(_ frame: RTCVideoFrame, generation: Int) {
        let now = CACurrentMediaTime()
        guard let tick = frameMeter.record(at: now, generation: generation) else { return }
        captureHub.handleVideoFrame(frame, hostTime: now)

        if let fps = tick.fps {
            Task { @MainActor in
                guard generation == self.connectionGeneration else { return }
                self.telemetry.update { $0.videoFps = fps }
            }
        }
        if tick.keepsFrame, let cvBuffer = frame.buffer as? RTCCVPixelBuffer {
            let pixelBuffer = cvBuffer.pixelBuffer
            Task { @MainActor in
                guard generation == self.connectionGeneration, self.isFrameCaptureEnabled else { return }
                self.currentFrame = pixelBuffer
            }
        }
    }

    nonisolated private func handleVideoSize(_ size: CGSize, generation: Int) {
        Task { @MainActor in
            guard generation == self.connectionGeneration else { return }
            if size.width > 0, size.height > 0, self.videoSize != size {
                self.videoSize = size
            }
        }
    }

    private func ensureMicrophoneAccess() async -> Bool {
#if canImport(AVFoundation)
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        default:
            return false
        }
#else
        return false
#endif
    }

    private func setupLocalMicrophoneTrackIfNeeded(factory: RTCPeerConnectionFactory, peerConnection: RTCPeerConnection?) {
        guard localAudioTrack == nil else { return }
        guard let peerConnection else { return }

        let audioSource = factory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
        let audioTrack = factory.audioTrack(with: audioSource, trackId: "audio0")
        // Made for every connect with Microphone on, but live only in the active window.
        audioTrack.isEnabled = audioRoute.sendsMicrophone
        localAudioTrack = audioTrack
        localAudioSender = peerConnection.add(audioTrack, streamIds: ["stream0"])
    }
}

// MARK: - RTCPeerConnectionDelegate
extension WebRTCManager: @preconcurrency RTCPeerConnectionDelegate {
    /// The peer a log-only callback came from, in front of its line (`PeerConnectionRoles.logPrefix`).
    private func peerLogPrefix(_ peerConnection: RTCPeerConnection) -> String {
        PeerConnectionRoles<RTCPeerConnection>.logPrefix(peerRoles.logSource(of: peerConnection))
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        Task { @MainActor in
            self.log.debug(.signaling, "\(self.peerLogPrefix(peerConnection))Signaling state: \(stateChanged.rawValue)")
        }
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        Task { @MainActor in
            self.log.info(.stream, "\(self.peerLogPrefix(peerConnection))Media stream added")
        }
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {
        Task { @MainActor in
            self.log.notice(.stream, "\(self.peerLogPrefix(peerConnection))Media stream removed")
        }
    }
    
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        Task { @MainActor in
            self.log.debug(.signaling, "\(self.peerLogPrefix(peerConnection))Renegotiation needed")
        }
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCIceConnectionState) {
        Task { @MainActor in
            let stateName = Self.iceStateName(stateChanged)
            switch self.peerRoles.disposition(for: peerConnection, isClosed: stateChanged == .closed) {
            case .ignore:
                return
            case .closed(.video):
                self.log.notice(.ice, "Video ICE state: \(stateName)")
                return
            case .live(.audio), .closed(.audio):
                // Only video drives the connection state: audio has a peer connection of its own
                // and may connect and disconnect independently.
                self.log.info(.ice, "Audio ICE state: \(stateName)")
                return
            case .live(.video):
                break
            }

            isConnected = (stateChanged == .connected || stateChanged == .completed)
            if isConnected {
                isConnecting = false
                hasEverConnectedToStream = true
                connectedIceTime = CACurrentMediaTime()
                lastDisconnectReason = nil
            } else {
                if stateChanged == .disconnected {
                    lastDisconnectReason = "Video connection lost"
                    isConnecting = false
                } else if stateChanged == .failed {
                    lastDisconnectReason = "Video connection failed"
                    isConnecting = false
                } else if stateChanged == .closed {
                    lastDisconnectReason = "Video connection closed"
                    isConnecting = false
                }
                if stateChanged == .disconnected || stateChanged == .failed {
                    requestReconnect(
                        reason: lastDisconnectReason ?? "Video connection lost",
                        delayNanoseconds: 750_000_000,
                        skipIfRecovered: stateChanged == .disconnected
                    )
                }
            }
            self.log.notice(.ice, "Video ICE state: \(stateName)")
        }
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCIceGatheringState) {
        Task { @MainActor in
            // A torn-down peer's gathering is not part of the current connection, and its end of
            // candidates must not reach the current connection's handles.
            guard self.peerRoles.currentRole(of: peerConnection) != nil else { return }
            self.log.debug(.ice, "ICE gathering: \(stateChanged.rawValue)")

            if stateChanged == .complete {
                self.logHeldBackLocalCandidates()
            }
            guard stateChanged == .complete,
                  let handleId = self.peerRoles.trickleHandle(
                      for: peerConnection,
                      videoHandle: self.janusHandleId,
                      audioHandle: self.janusAudioHandleId
                  ) else { return }
            do {
                try await sendJanusTrickleCompleted(handleId: handleId)
            } catch {
                // ignore
            }
        }
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        Task { @MainActor in
            guard let handleId = self.peerRoles.trickleHandle(
                for: peerConnection,
                videoHandle: self.janusHandleId,
                audioHandle: self.janusAudioHandleId
            ) else {
                if self.peerRoles.currentRole(of: peerConnection) == nil {
                    self.log.debug(.ice, "Dropped a local candidate from a torn-down peer connection")
                }
                return
            }
            await self.trickleLocalCandidate(candidate, handleId: handleId)
        }
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {
        Task { @MainActor in
            self.log.debug(.ice, "\(self.peerLogPrefix(peerConnection))ICE candidates removed")
        }
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        Task { @MainActor in
            self.log.debug(.signaling, "\(self.peerLogPrefix(peerConnection))Data channel opened")
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams: [RTCMediaStream]) {
        // WebRTC's thread: only the track is read here. The playout hint reads the manager's
        // peer connection and preference, and the audio switch follows the Audio setting, all
        // main-actor state, so both wait for the main actor, where a torn-down peer's late
        // callback does nothing to the next connection.
        let track = rtpReceiver.track
        let kind: AddedTrackKind = track is RTCAudioTrack ? .audio : (track is RTCVideoTrack ? .video : .other)
        Task { @MainActor in
            let action = self.peerRoles.action(forAdded: kind, on: peerConnection)
            guard action != .ignore else { return }
            self.applyPlayoutDelayHintIfPossible()
            switch action {
            case .playAudio:
                // Present whenever the mic is on (see the audio watch request); heard only if
                // asked for.
                (track as? RTCAudioTrack)?.isEnabled = self.audioEnabled
            case .renderVideo:
                if let videoTrack = track as? RTCVideoTrack {
                    self.attachVideoTrack(videoTrack)
                }
            case .hintOnly, .ignore:
                break
            }
        }
    }
}

// MARK: - RTCDataChannelDelegate
extension WebRTCManager: @preconcurrency RTCDataChannelDelegate {
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        Task { @MainActor in
            self.log.debug(.signaling, "Data channel state: \(dataChannel.readyState.rawValue)")
        }
    }
    
    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard buffer.isBinary,
              let message = try? JSONDecoder().decode(InputMessage.self, from: buffer.data) else {
            return
        }
        
        Task { @MainActor in
            await handleDataChannelMessage(message)
        }
    }
    
    private func handleDataChannelMessage(_ message: InputMessage) async {
        // The data channel used to carry a ping/pong latency probe; nothing on the device answers
        // it. Input round trips are measured on the HID WebSocket instead (InputManager).
        switch message.type {
        case "video-frame":
            // Handle video frame metadata if needed
            break
        default:
            break
        }
    }
 }

// MARK: - Supporting Types
enum WebRTCError: Error {
    case factoryNotInitialized
    case invalidSignalingURL
    case signalingConnectionLost
    case signalingTimeout
    case peerConnectionFailed
    /// A newer connect or teardown replaced this attempt while it was in flight.
    case superseded
}

struct InputMessage: Codable {
    let type: String
    let timestamp: TimeInterval?
}

#else

@MainActor
final class WebRTCManager: NSObject, ObservableObject {
    @Published var isConnected = false
    @Published var isConnecting = false
    @Published var hasEverConnectedToStream = false
    @Published var isStreamStalled = false
    @Published var lastDisconnectReason: String?
    @Published var lastVideoFrameAgeSeconds: Int?
    @Published var currentFrame: CVPixelBuffer?
    let audioPreferences: AudioPreferences
    var audioEnabled: Bool { audioPreferences.audioEnabled }
    var micEnabled: Bool { audioPreferences.micEnabled }
    private(set) var audioRoute: AudioRoute = .unrouted
    @Published private(set) var isMicrophoneAccessDenied = false
    let log: SessionLog

    let telemetry = StreamTelemetryModel()

    let networkPreferences: NetworkPreferences
    @Published private(set) var mediaAddressesInEffect: MediaAddresses?

    init(
        audioPreferences: AudioPreferences? = nil,
        networkPreferences: NetworkPreferences? = nil,
        log: SessionLog? = nil
    ) {
        self.audioPreferences = audioPreferences ?? .shared
        self.networkPreferences = networkPreferences ?? .shared
        self.log = log ?? SessionLog(destination: .shared)
        super.init()
    }

    func setAudioRoute(_ route: AudioRoute) {
        audioRoute = route
    }

    var isPlaybackMuted: Bool { !audioRoute.playsAudio }

    var readVideoMode: GLKVMVideoMode.Reader?

    func noteVideoMode(_ mode: String, for address: DeviceAddress) {
    }
    
    func connect(to device: KVMDevice) async throws {
        isConnected = false
    }

    func reconnect(to device: KVMDevice, reason: String = "") async {
        disconnect()
    }
    
    func sendInputEvent(_ event: InputEvent) {
    }
    
    func disconnect() {
        isConnected = false
        isConnecting = false
        hasEverConnectedToStream = false
        isStreamStalled = false
        lastDisconnectReason = nil
        lastVideoFrameAgeSeconds = nil
        telemetry.clearStreamStats()
        currentFrame = nil
    }
}

#endif
