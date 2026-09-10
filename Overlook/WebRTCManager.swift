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

#if canImport(WebRTC)
@MainActor
class WebRTCManager: NSObject, ObservableObject {
    @Published var videoView: RTCMTLNSVideoView?
    @Published var isConnected = false
    @Published var currentFrame: CVPixelBuffer?
    @Published var videoSize: CGSize?
    @Published var audioEnabled = false
    @Published var micEnabled = false
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
    
    private var peerConnection: RTCPeerConnection?
    private var audioPeerConnection: RTCPeerConnection?
    private var videoTrack: RTCVideoTrack?
    private var localAudioTrack: RTCAudioTrack?
    private var localAudioSender: RTCRtpSender?
    private var dataChannel: RTCDataChannel?
    private var factory: RTCPeerConnectionFactory?
    private var customAudioDevice: WebRTCAudioDevice?
    private var connectionTimer: Timer?

    private var lastConnectedDevice: KVMDevice?

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

    private let audioInputDeviceUIDDefaultsKey = "overlook.audio.inputDeviceUID"
    private let audioOutputDeviceUIDDefaultsKey = "overlook.audio.outputDeviceUID"

    private var fpsWindowStartTime: CFTimeInterval = 0
    private var fpsFrameCount: Int = 0
    private var lastFpsPublishTime: CFTimeInterval = 0

    private let streamHealthQueue = DispatchQueue(label: "com.overlook.stream-health")
    private var lastVideoFrameTime: CFTimeInterval?
    private var connectedIceTime: CFTimeInterval?
    private var streamHealthTimer: Timer?

    private let streamStallThresholdSeconds: CFTimeInterval = 3.0
    private let initialFrameTimeoutSeconds: CFTimeInterval = 5.0
    
    private var signalingSession: URLSession?
    private var webSocketTask: URLSessionWebSocketTask?
    private var signalingListenerTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    /// Bumped on every connect and teardown so work started for an earlier connection — the
    /// signaling listener, in-flight transactions — cannot act on a later one.
    private var connectionGeneration = 0
    /// Stall-triggered reconnects since video last flowed. Bounded, because a device that is up
    /// but has nothing to send (no HDMI signal, say) would otherwise be torn down every few seconds.
    private var consecutiveStallReconnects = 0
    private static let maxConsecutiveStallReconnects = 2

    private var janusSessionId: Int?
    private var janusHandleId: Int?
    private var janusAudioHandleId: Int?
    private var janusKeepAliveTimer: Timer?
    private var janusWaiters: [String: CheckedContinuation<[String: Any], Error>] = [:]
    private var janusTimeoutTasks: [String: Task<Void, Never>] = [:]
    private static let janusTransactionTimeoutNs: UInt64 = 8_000_000_000

    private var isFrameCaptureEnabled: Bool = false
    private var lastFrameCaptureTime: CFTimeInterval = 0
    
    override init() {
        super.init()
        setupWebRTC()
        startAudioDeviceChangeMonitoring()
    }

    deinit {
        if let block = audioDevicesListenerBlock {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )

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

    private func setLastVideoFrameTime(_ time: CFTimeInterval?) {
        streamHealthQueue.sync {
            lastVideoFrameTime = time
        }
    }

    private func getLastVideoFrameTime() -> CFTimeInterval? {
        streamHealthQueue.sync {
            lastVideoFrameTime
        }
    }
    
    private func setupWebRTC() {
        let inputUID = (UserDefaults.standard.string(forKey: audioInputDeviceUIDDefaultsKey) ?? "")
        let outputUID = (UserDefaults.standard.string(forKey: audioOutputDeviceUIDDefaultsKey) ?? "")
        let useCustomAudioDevice = !(inputUID.isEmpty && outputUID.isEmpty)

        let audioDevice: WebRTCAudioDevice? = useCustomAudioDevice
            ? WebRTCAudioDevice(inputDeviceUID: inputUID, outputDeviceUID: outputUID)
            : nil
        customAudioDevice = audioDevice

        factory = WebRTCFactoryBuilder.makeFactory(with: audioDevice)

        if videoView == nil {
            videoView = RTCMTLNSVideoView(frame: .zero)
        }
    }

    private func startAudioDeviceChangeMonitoring() {
        guard audioDevicesListenerBlock == nil else { return }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            Task { @MainActor in
                self.handleAudioDevicesChanged()
            }
        }

        audioDevicesListenerBlock = block
        _ = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            audioDevicesListenerQueue,
            block
        )
    }

    private func stopAudioDeviceChangeMonitoring() {
        guard let block = audioDevicesListenerBlock else { return }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        _ = AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            audioDevicesListenerQueue,
            block
        )

        audioDevicesListenerBlock = nil
        audioDeviceChangeDebounceTask?.cancel()
        audioDeviceChangeDebounceTask = nil
    }

    private func shouldAutoReconnectForMissingSelectedDevices() -> Bool {
        guard peerConnection != nil else { return false }

        let inputUID = (UserDefaults.standard.string(forKey: audioInputDeviceUIDDefaultsKey) ?? "")
        let outputUID = (UserDefaults.standard.string(forKey: audioOutputDeviceUIDDefaultsKey) ?? "")

        let selectedInputMissing = !inputUID.isEmpty && CoreAudioDevices.deviceID(forUID: inputUID) == nil
        let selectedOutputMissing = !outputUID.isEmpty && CoreAudioDevices.deviceID(forUID: outputUID) == nil

        let inputRelevant = micEnabled
        let outputRelevant = audioEnabled

        if selectedInputMissing && inputRelevant { return true }
        if selectedOutputMissing && outputRelevant { return true }
        return false
    }

    private func handleAudioDevicesChanged() {
        guard shouldAutoReconnectForMissingSelectedDevices() else { return }
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
        guard shouldAutoReconnectForMissingSelectedDevices() else { return }

        let now = Date()
        if let last = lastAutoReconnectAt, now.timeIntervalSince(last) < 3.0 {
            return
        }
        lastAutoReconnectAt = now

        isAutoReconnectInProgress = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isAutoReconnectInProgress = false }
            await self.reconnect(to: device, reason: "Audio device changed")
        }
    }
    
    func connect(to device: KVMDevice) async throws {
        // An operator connect supersedes, and releases, whatever is in flight: a retry loop, an
        // attempt still waiting on Janus, or the live session when switching devices.
        consecutiveStallReconnects = 0
        telemetry.update { $0.clearSession() }
        try await replaceConnection(with: device)
        telemetry.update { $0.sessionConnectedAt = Date() }
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
        setupWebRTC()

        guard let factory = factory else {
            throw WebRTCError.factoryNotInitialized
        }

        isConnecting = true
        isStreamStalled = false
        lastDisconnectReason = nil
        lastVideoFrameAgeSeconds = nil
        setLastVideoFrameTime(nil)
        connectedIceTime = nil
        hasEverConnectedToStream = false

        do {
            if videoView == nil {
                videoView = RTCMTLNSVideoView(frame: .zero)
            }
            
            // Create peer connection
            let configuration = RTCConfiguration()
            configuration.iceServers = [
                RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])
            ]
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
            }

            if micEnabled {
                let granted = await ensureMicrophoneAccess()
                // The permission prompt can outlive this attempt.
                guard generation == connectionGeneration else { throw WebRTCError.superseded }
                if granted {
                    setupLocalMicrophoneTrackIfNeeded(factory: factory, peerConnection: audioPeerConnection ?? peerConnection)
                }
            }
            
            // Setup data channel for input events
            setupDataChannel()
            
            // Connect to signaling server
            try await connectToSignalingServer(device: device)
            guard generation == connectionGeneration else { throw WebRTCError.superseded }

            // Start connection quality monitoring
            startStatsPolling()
            startStreamHealthMonitoring()
        } catch {
            // A newer connect or teardown has replaced this attempt's state; it is not ours to reset.
            guard generation == connectionGeneration else { throw WebRTCError.superseded }
            let reason = "Connect failed: \(String(describing: error))"
            tearDown(cancelReconnect: false)
            lastDisconnectReason = reason
            throw error
        }
    }

    /// `reason` is what the session history shows for this reconnect.
    func reconnect(to device: KVMDevice, reason: String = "Reconnect requested") async {
        // An explicit reconnect supersedes any retry loop in progress.
        consecutiveStallReconnects = 0
        noteReconnect(reason: reason)
        do {
            try await replaceConnection(with: device)
        } catch {
            if case WebRTCError.superseded = error { return }
            isConnecting = false
            showConnectionLost("Reconnect failed: \(String(describing: error))")
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
        guard reconnectTask == nil, let device = lastConnectedDevice else { return false }
        lastDisconnectReason = reason
        noteReconnect(reason: reason)
        reconnectTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Whoever cancelled this loop has already replaced the handle; don't wipe theirs.
            defer { if !Task.isCancelled { self.reconnectTask = nil } }
            let captureEnabled = self.isFrameCaptureEnabled
            let delays: [UInt64] = [delayNanoseconds, 1_000_000_000, 2_000_000_000, 4_000_000_000]
            for (index, delay) in delays.enumerated() {
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else { return }
                if skipIfRecovered, index == 0, self.isConnected { return }
                self.tearDown(cancelReconnect: false)
                // Keep the "Connection Lost" overlay up between attempts instead of a blank surface.
                self.showConnectionLost(reason)
                do {
                    try await self.performConnect(to: device)
                    if captureEnabled {
                        self.setFrameCaptureEnabled(true)
                    }
                    // A session whose first connect failed starts its clock here.
                    self.telemetry.update { if $0.sessionConnectedAt == nil { $0.sessionConnectedAt = Date() } }
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    if case WebRTCError.superseded = error { return }
                    self.showConnectionLost("\(reason) · retry \(index + 1) failed: \(error.localizedDescription)")
                }
            }
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
        guard consecutiveStallReconnects < Self.maxConsecutiveStallReconnects else { return }
        if requestReconnect(reason: "Video stream stalled") {
            consecutiveStallReconnects += 1
        }
    }

    func setFrameCaptureEnabled(_ enabled: Bool) {
        isFrameCaptureEnabled = enabled

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
        print("WebRTC signaling connect: \(url.absoluteString)")

        let config = URLSessionConfiguration.default
        // Same host:port as the HTTP API, so the certificate pinned there applies here too.
        let session = URLSession(configuration: config, delegate: DeviceTrustSessionDelegate(), delegateQueue: nil)
        signalingSession = session

        var request = URLRequest(url: url)
        if !device.authToken.isEmpty {
            request.setValue("auth_token=\(device.authToken)", forHTTPHeaderField: "Cookie")
        }
        request.setValue(device.originURL, forHTTPHeaderField: "Origin")
        request.setValue("janus-protocol", forHTTPHeaderField: "Sec-WebSocket-Protocol")

        let socketTask = session.webSocketTask(with: request)
        webSocketTask = socketTask
        socketTask.resume()

        let generation = connectionGeneration
        signalingListenerTask?.cancel()
        signalingListenerTask = Task { [weak self] in
            guard let self else { return }
            await self.listenForSignalingMessages(socket: socketTask, generation: generation)
        }

        // Janus session setup
        let createTransaction = makeJanusTransaction()
        try await sendJanusMessage([
            "janus": "create",
            "transaction": createTransaction,
        ])

        let createResponse = try await waitForJanusTransaction(createTransaction)
        guard let data = createResponse["data"] as? [String: Any],
              let sessionId = data["id"] as? Int else {
            throw WebRTCError.signalingConnectionLost
        }
        janusSessionId = sessionId

        let attachTransaction = makeJanusTransaction()
        try await sendJanusMessage([
            "janus": "attach",
            "plugin": "janus.plugin.ustreamer",
            "opaque_id": "oid-\(UUID().uuidString)",
            "transaction": attachTransaction,
            "session_id": sessionId,
        ])

        let attachResponse = try await waitForJanusTransaction(attachTransaction)
        guard let attachData = attachResponse["data"] as? [String: Any],
              let handleId = attachData["id"] as? Int else {
            throw WebRTCError.signalingConnectionLost
        }
        janusHandleId = handleId

        // Video handle always requests video-only to avoid A/V sync causing video buffering.
        let watchTransaction = makeJanusTransaction()
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
            "transaction": watchTransaction,
            "session_id": sessionId,
            "handle_id": handleId,
        ])

        if (audioEnabled || micEnabled), let audioPeerConnection {
            let audioAttachTransaction = makeJanusTransaction()
            try await sendJanusMessage([
                "janus": "attach",
                "plugin": "janus.plugin.ustreamer",
                "opaque_id": "oid-audio-\(UUID().uuidString)",
                "transaction": audioAttachTransaction,
                "session_id": sessionId,
            ])

            let audioAttachResponse = try await waitForJanusTransaction(audioAttachTransaction)
            guard let audioAttachData = audioAttachResponse["data"] as? [String: Any],
                  let audioHandleId = audioAttachData["id"] as? Int else {
                throw WebRTCError.signalingConnectionLost
            }
            janusAudioHandleId = audioHandleId

            let audioWatchTransaction = makeJanusTransaction()
            try await sendJanusMessage([
                "janus": "message",
                "body": [
                    "request": "watch",
                    "params": [
                        "orientation": 0,
                        "audio": audioEnabled,
                        "video": false,
                        "mic": micEnabled,
                        "camera": false,
                    ],
                ],
                "transaction": audioWatchTransaction,
                "session_id": sessionId,
                "handle_id": audioHandleId,
            ])

            _ = audioPeerConnection
        }

        startJanusKeepAlive()
    }

    private func startJanusKeepAlive() {
        janusKeepAliveTimer?.invalidate()
        let generation = connectionGeneration
        janusKeepAliveTimer = Timer.scheduledTimer(withTimeInterval: 25.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard generation == self.connectionGeneration else { return }
                do {
                    try await self.sendJanusKeepAlive()
                } catch {
                    // A keepalive cancelled by a teardown must not reconnect what was just hung up.
                    guard generation == self.connectionGeneration else { return }
                    self.requestReconnect(reason: "Signaling keepalive failed")
                }
            }
        }
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

    private func waitForJanusTransaction(_ transaction: String) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            janusWaiters[transaction] = continuation
            // A device that never answers used to leave connect() suspended forever.
            janusTimeoutTasks[transaction] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: Self.janusTransactionTimeoutNs)
                guard !Task.isCancelled, let self,
                      let waiter = self.janusWaiters.removeValue(forKey: transaction) else { return }
                self.janusTimeoutTasks.removeValue(forKey: transaction)
                waiter.resume(throwing: WebRTCError.signalingTimeout)
            }
        }
    }

    private func sendJanusMessage(_ message: [String: Any]) async throws {
        guard let webSocketTask = webSocketTask,
              let data = try? JSONSerialization.data(withJSONObject: message),
              let text = String(data: data, encoding: .utf8) else {
            throw WebRTCError.signalingConnectionLost
        }
        try await webSocketTask.send(.string(text))
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
                print("WebSocket receive error: \(error)")
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

    private func handleJanusMessage(_ message: [String: Any]) async {
        if let transaction = message["transaction"] as? String,
           let waiter = janusWaiters.removeValue(forKey: transaction) {
            janusTimeoutTasks.removeValue(forKey: transaction)?.cancel()
            waiter.resume(returning: message)
            return
        }

        guard let janusType = message["janus"] as? String else { return }
        if janusType == "trickle" {
            guard let candidateObj = message["candidate"] as? [String: Any],
                  let candidateString = candidateObj["candidate"] as? String,
                  let videoPeerConnection = peerConnection else {
                return
            }

            let senderHandleId = message["sender"] as? Int
            let peerConnection: RTCPeerConnection
            if let senderHandleId, senderHandleId == janusAudioHandleId, let audioPeerConnection {
                peerConnection = audioPeerConnection
            } else {
                peerConnection = videoPeerConnection
            }

            if (candidateObj["completed"] as? Bool) == true {
                return
            }

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

        if janusType != "event" { return }

        let senderHandleId = message["sender"] as? Int
        guard let jsep = message["jsep"] as? [String: Any],
              let jsepType = jsep["type"] as? String,
              jsepType == "offer",
              let sdpString = jsep["sdp"] as? String else {
            return
        }

        await handleOfferSDP(sdpString, senderHandleId: senderHandleId)
    }
    
    private func handleOfferSDP(_ sdpString: String, senderHandleId: Int?) async {
        guard let videoHandleId = janusHandleId else { return }

        let peerConnection: RTCPeerConnection?
        let handleId: Int?
        if let senderHandleId, senderHandleId == janusAudioHandleId {
            peerConnection = audioPeerConnection
            handleId = janusAudioHandleId
        } else {
            peerConnection = self.peerConnection
            handleId = videoHandleId
        }

        guard let peerConnection, let handleId else { return }
        
        let sessionDescription = RTCSessionDescription(
            type: .offer,
            sdp: sdpString
        )
        
        do {
            try await peerConnection.setRemoteDescription(sessionDescription)
        } catch {
            print("Failed to set remote description: \(error)")
        }
        
        // Create and send answer
        await createAndSendAnswer(peerConnection: peerConnection, handleId: handleId)
    }

    private func createAndSendAnswer(peerConnection: RTCPeerConnection, handleId: Int) async {

        do {
            let sessionDescription = try await peerConnection.answer(
                for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
            )
            try await peerConnection.setLocalDescription(sessionDescription)
        } catch {
            print("Failed to create/send answer: \(error)")
            return
        }
        
        // Send answer to Janus
        guard let localDescription = peerConnection.localDescription,
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
            print("Failed to send Janus answer: \(error)")
        }
    }
    
    private func startStatsPolling() {
        connectionTimer?.invalidate()
        connectionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.measureStreamStats()
            }
        }
    }

    private func startStreamHealthMonitoring() {
        streamHealthTimer?.invalidate()
        streamHealthTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
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

                let lastFrame = self.getLastVideoFrameTime()
                let age = lastFrame.map { now - $0 }

                if let age {
                    self.setLastVideoFrameAgeSeconds(max(0, Int(age.rounded())))
                } else {
                    self.setLastVideoFrameAgeSeconds(nil)
                }

                if let age, age > self.streamStallThresholdSeconds {
                    if self.isStreamStalled == false {
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
                        self.setIsStreamStalled(true)
                        self.setLastDisconnectReason("Video stream stalled")
                        self.reconnectAfterStall()
                    }
                    return
                }

                if self.isStreamStalled {
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

        let video = await collectInboundVideoStats(from: peerConnection)

        let audio: AudioStatsSample
        if let audioPeerConnection {
            audio = await collectInboundAudioStats(from: audioPeerConnection)
        } else {
            lastInboundAudioBytesReceived = nil
            lastInboundAudioBytesTimestamp = nil
            lastAudioJitterBufferDelaySeconds = nil
            lastAudioJitterBufferEmittedCount = nil
            audio = .empty
        }

        telemetry.update { snapshot in
            snapshot.apply(video: video)
            snapshot.apply(audio: audio)
        }
    }

    /// The ICE candidate pair traffic is flowing over. libwebrtc names it on the `transport`
    /// statistic (`selectedCandidatePairId`); the pair itself carries no `selected` flag. A
    /// nominated, succeeded pair is the fallback for builds that lack the transport entry.
    private static func selectedCandidatePair(in report: RTCStatisticsReport) -> RTCStatistics? {
        for statistic in report.statistics.values where statistic.type == "transport" {
            if let pairId = statistic.values["selectedCandidatePairId"] as? String,
               let pair = report.statistics[pairId] {
                return pair
            }
        }
        for statistic in report.statistics.values where statistic.type == "candidate-pair" {
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
        pair: RTCStatistics,
        in report: RTCStatisticsReport
    ) -> (path: String?, remoteAddress: String?) {
        func candidate(_ key: String) -> RTCStatistics? {
            guard let id = pair.values[key] as? String else { return nil }
            return report.statistics[id]
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

    private func collectInboundVideoStats(from peerConnection: RTCPeerConnection) async -> VideoStatsSample {
        let lastBytes = lastInboundVideoBytesReceived
        let lastTs = lastInboundVideoBytesTimestamp

        let report = await peerConnection.statistics()
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

        for statistic in report.statistics.values {
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
               let mimeType = report.statistics[codecId]?.values["mimeType"] as? String {
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

    private func collectInboundAudioStats(from audioPeerConnection: RTCPeerConnection) async -> AudioStatsSample {
        let lastAudioBytes = lastInboundAudioBytesReceived
        let lastAudioTs = lastInboundAudioBytesTimestamp

        let audioReport = await audioPeerConnection.statistics()
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

        for statistic in audioReport.statistics.values {
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
        // Nothing may auto-reconnect after an operator disconnect.
        lastConnectedDevice = nil
        consecutiveStallReconnects = 0
        telemetry.update { $0.clearSession() }
        tearDown(cancelReconnect: true)
    }

    /// Tears the connection down. `cancelReconnect` is false when the caller is the retry loop
    /// itself (or a reconnect that should not kill a pending retry).
    private func tearDown(cancelReconnect: Bool) {
        connectionGeneration += 1
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

        janusKeepAliveTimer?.invalidate()
        janusKeepAliveTimer = nil
        janusSessionId = nil
        janusHandleId = nil
        janusAudioHandleId = nil
        let waiters = janusWaiters
        janusWaiters.removeAll()
        janusTimeoutTasks.values.forEach { $0.cancel() }
        janusTimeoutTasks.removeAll()
        for (_, waiter) in waiters {
            waiter.resume(throwing: WebRTCError.signalingConnectionLost)
        }
        
        webSocketTask?.cancel()
        webSocketTask = nil
        // A URLSession retains itself and its delegate until invalidated; one was leaked per connect.
        signalingSession?.invalidateAndCancel()
        signalingSession = nil
        
        dataChannel?.close()
        dataChannel = nil
        
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
        setLastVideoFrameTime(nil)
        connectedIceTime = nil
        videoSize = nil
        isFrameCaptureEnabled = false
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
        fpsWindowStartTime = 0
        fpsFrameCount = 0
        lastFpsPublishTime = 0
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
        localAudioTrack = audioTrack
        localAudioSender = peerConnection.add(audioTrack, streamIds: ["stream0"])
    }
}

// MARK: - RTCPeerConnectionDelegate
extension WebRTCManager: @preconcurrency RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        Task { @MainActor in
            print("Signaling state changed: \(stateChanged)")
        }
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        Task { @MainActor in
            print("Media stream added")
        }
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {
        Task { @MainActor in
            print("Media stream removed")
        }
    }
    
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        Task { @MainActor in
            print("Should negotiate")
        }
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCIceConnectionState) {
        Task { @MainActor in
            // Drive UI connection state from the video peer connection only.
            // Audio may connect/disconnect independently when split into a separate PeerConnection.
            guard peerConnection === self.peerConnection else {
                print("(audio) ICE connection state changed: \(stateChanged)")
                return
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
            print("ICE connection state changed: \(stateChanged)")
        }
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCIceGatheringState) {
        Task { @MainActor in
            print("ICE gathering state changed: \(stateChanged)")

            if stateChanged == .complete {
                do {
                    if peerConnection === self.audioPeerConnection {
                        if let handleId = self.janusAudioHandleId {
                            try await sendJanusTrickleCompleted(handleId: handleId)
                        }
                    } else {
                        if let handleId = self.janusHandleId {
                            try await sendJanusTrickleCompleted(handleId: handleId)
                        }
                    }
                } catch {
                    // ignore
                }
            }
        }
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        Task { @MainActor in
            do {
                if peerConnection === self.audioPeerConnection {
                    if let handleId = self.janusAudioHandleId {
                        try await sendJanusTrickleCandidate(candidate, handleId: handleId)
                    }
                } else {
                    if let handleId = self.janusHandleId {
                        try await sendJanusTrickleCandidate(candidate, handleId: handleId)
                    }
                }
            } catch {
                print("Failed to send Janus ICE candidate: \(error)")
            }
        }
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {
        Task { @MainActor in
            print("ICE candidates removed")
        }
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        Task { @MainActor in
            print("Data channel opened")
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams: [RTCMediaStream]) {
        applyPlayoutDelayHintIfPossible()
        guard let track = rtpReceiver.track as? RTCVideoTrack else { return }
        videoTrack = track
        if let videoView {
            track.add(videoView)
        }
        track.add(self)
    }
}

// MARK: - RTCDataChannelDelegate
extension WebRTCManager: @preconcurrency RTCDataChannelDelegate {
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        Task { @MainActor in
            print("Data channel state changed: \(dataChannel.readyState)")
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

// MARK: - RTCVideoRenderer
extension WebRTCManager: @preconcurrency RTCVideoRenderer {
    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }

        let now = CACurrentMediaTime()

        setLastVideoFrameTime(now)

        if fpsWindowStartTime == 0 {
            fpsWindowStartTime = now
            lastFpsPublishTime = now
        }

        fpsFrameCount += 1

        if now - lastFpsPublishTime >= 0.5 {
            let dt = now - fpsWindowStartTime
            if dt > 0 {
                let fps = Int((Double(fpsFrameCount) / dt).rounded())
                Task { @MainActor in
                    telemetry.update { $0.videoFps = fps }
                }
            }
            fpsWindowStartTime = now
            fpsFrameCount = 0
            lastFpsPublishTime = now
        }

        guard isFrameCaptureEnabled else { return }

        let minInterval: CFTimeInterval = 1.0 / 12.0
        if now - lastFrameCaptureTime < minInterval {
            return
        }
        lastFrameCaptureTime = now

        if let cvBuffer = frame.buffer as? RTCCVPixelBuffer {
            let pb = cvBuffer.pixelBuffer
            Task { @MainActor in
                currentFrame = pb
            }
        }
    }
    
    func setSize(_ size: CGSize) {
        Task { @MainActor in
            if size.width > 0, size.height > 0, videoSize != size {
                videoSize = size
            }
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
    @Published var audioEnabled = false
    @Published var micEnabled = false

    let telemetry = StreamTelemetryModel()
    
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
