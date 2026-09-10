import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// A display-ready snapshot of everything the connections panel shows about the session: the
/// HID socket and what the device reports over it, the session's history, and the periodic
/// WebRTC video + audio statistics.
///
/// Every field is already quantized to the precision the UI renders (whole kbps, whole fps,
/// whole milliseconds), so two ticks that would render identically compare equal — which is
/// what lets `StreamTelemetryModel` skip the publish and keep the SwiftUI graph quiet while
/// a stream is steady.
///
/// Ownership: `InputManager` writes the device fields, `WebRTCManager` the session and stream
/// fields. The three groups are cleared independently: a stream teardown (including the ones
/// inside an automatic reconnect) must not blank the HID link or the session history.
struct StreamTelemetry: Equatable {
    // MARK: Device — the HID WebSocket and the state the device pushes over it

    enum HIDLink: Equatable {
        case disconnected
        case connecting
        case connected
        case reconnecting
    }

    var hidLink: HIDLink = .disconnected
    /// Ping → pong on the HID WebSocket, in whole milliseconds: the round trip keystrokes and
    /// mouse reports actually travel.
    var hidRoundTripMs: Int?
    /// HID commands queued and not yet sent, sampled with each pong.
    var hidQueueDepth: Int = 0
    /// The device's USB link to the target, as the device reports it.
    var hidUSBConnected: Bool?

    var hdmiOnline: Bool?
    var hdmiResolution: String?
    var hdmiCapturedFps: Int?
    var hdmiDesiredFps: Int?

    // MARK: Session — survives stream teardowns; cleared by an operator connect/disconnect

    var sessionConnectedAt: Date?
    var sessionReconnectCount: Int = 0
    var sessionLastReconnectReason: String?
    var sessionLastReconnectAt: Date?

    // MARK: Stream — WebRTC statistics; cleared on every teardown

    var videoKbps: Int?
    /// Whole frames per second, as rendered — the raw rate jitters every window.
    var videoFps: Int?
    var videoPlayoutDelayMs: Int?
    var videoJitterMs: Int?
    var videoDecodeMs: Int?
    /// Packet in to frame out inside WebRTC (jitter buffer + assembly + decode), per frame.
    var videoProcessingDelayMs: Int?
    var videoPacketsLost: Int?
    var videoFramesDropped: Int?
    /// Picture-loss indications and NACKs this receiver has sent: repair requests.
    var videoPliCount: Int?
    var videoNackCount: Int?
    var videoFreezeCount: Int?
    var videoFreezeDurationMs: Int?
    var videoPauseCount: Int?
    var videoRoundTripTimeMs: Int?
    /// e.g. "H264"
    var videoCodec: String?
    /// e.g. "VideoToolbox"
    var videoDecoder: String?
    var videoDecoderIsPowerEfficient: Bool?

    /// e.g. "host → host · UDP"
    var networkPath: String?
    var networkRemoteAddress: String?
    var availableIncomingKbps: Int?

    var audioKbps: Int?
    var audioPlayoutDelayMs: Int?
    var audioJitterMs: Int?
    var audioPacketsLost: Int?
    var audioRoundTripTimeMs: Int?

    static let empty = StreamTelemetry()

    /// True once the audio peer connection has reported anything worth showing; the stats
    /// UI hides its audio rows otherwise.
    var hasAudioStats: Bool {
        audioKbps != nil
            || audioJitterMs != nil
            || audioPacketsLost != nil
            || audioRoundTripTimeMs != nil
    }

    mutating func clearStreamStats() {
        apply(video: .empty)
        apply(audio: .empty)
        videoFps = nil
    }

    mutating func clearSession() {
        sessionConnectedAt = nil
        sessionReconnectCount = 0
        sessionLastReconnectReason = nil
        sessionLastReconnectAt = nil
    }

    mutating func clearDevice() {
        hidLink = .disconnected
        hidRoundTripMs = nil
        hidQueueDepth = 0
        hidUSBConnected = nil
        hdmiOnline = nil
        hdmiResolution = nil
        hdmiCapturedFps = nil
        hdmiDesiredFps = nil
    }
}

/// One polling tick of inbound video statistics, rounded to display precision.
///
/// Frames-per-second is deliberately absent: it is measured on the decode path, not in the
/// stats report, and is published on its own cadence.
struct VideoStatsSample: Equatable {
    var kbps: Int?
    var playoutDelayMs: Int?
    var jitterMs: Int?
    var decodeMs: Int?
    var processingDelayMs: Int?
    var packetsLost: Int?
    var framesDropped: Int?
    var pliCount: Int?
    var nackCount: Int?
    var freezeCount: Int?
    var freezeDurationMs: Int?
    var pauseCount: Int?
    var roundTripTimeMs: Int?
    var codec: String?
    var decoder: String?
    var decoderIsPowerEfficient: Bool?
    var networkPath: String?
    var networkRemoteAddress: String?
    var availableIncomingKbps: Int?

    static let empty = VideoStatsSample()
}

/// One polling tick of inbound audio statistics, rounded to display precision.
struct AudioStatsSample: Equatable {
    var kbps: Int?
    var playoutDelayMs: Int?
    var jitterMs: Int?
    var packetsLost: Int?
    var roundTripTimeMs: Int?

    static let empty = AudioStatsSample()
}

extension StreamTelemetry {
    mutating func apply(video: VideoStatsSample) {
        videoKbps = video.kbps
        videoPlayoutDelayMs = video.playoutDelayMs
        videoJitterMs = video.jitterMs
        videoDecodeMs = video.decodeMs
        videoProcessingDelayMs = video.processingDelayMs
        videoPacketsLost = video.packetsLost
        videoFramesDropped = video.framesDropped
        videoPliCount = video.pliCount
        videoNackCount = video.nackCount
        videoFreezeCount = video.freezeCount
        videoFreezeDurationMs = video.freezeDurationMs
        videoPauseCount = video.pauseCount
        videoRoundTripTimeMs = video.roundTripTimeMs
        videoCodec = video.codec
        videoDecoder = video.decoder
        videoDecoderIsPowerEfficient = video.decoderIsPowerEfficient
        networkPath = video.networkPath
        networkRemoteAddress = video.networkRemoteAddress
        availableIncomingKbps = video.availableIncomingKbps
    }

    mutating func apply(audio: AudioStatsSample) {
        audioKbps = audio.kbps
        audioPlayoutDelayMs = audio.playoutDelayMs
        audioJitterMs = audio.jitterMs
        audioPacketsLost = audio.packetsLost
        audioRoundTripTimeMs = audio.roundTripTimeMs
    }
}

/// Owns the single telemetry value the stats UI observes.
///
/// Telemetry lives here rather than on `WebRTCManager` for two reasons: a stats tick then
/// invalidates only the views that render stats, and every write goes through one
/// equality gate, so a steady stream publishes nothing at all.
@MainActor
final class StreamTelemetryModel: ObservableObject {
    @Published private(set) var snapshot: StreamTelemetry = .empty

    /// Publishes `next` only when it differs from what the UI is already showing.
    func publish(_ next: StreamTelemetry) {
        guard next != snapshot else { return }
        snapshot = next
    }

    /// Applies a batch of changes to the current snapshot as **one** potential publish.
    /// Producers should collect a whole tick's worth of values and call this once.
    func update(_ mutate: (inout StreamTelemetry) -> Void) {
        var next = snapshot
        mutate(&next)
        publish(next)
    }

    /// Clears the WebRTC statistics — used when a stream is torn down. The device and session
    /// groups are left alone; their owners clear them.
    func clearStreamStats() {
        update { $0.clearStreamStats() }
    }
}
