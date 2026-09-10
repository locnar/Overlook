import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// A display-ready snapshot of the periodic WebRTC video + audio statistics.
///
/// Every field is already quantized to the precision the UI renders (whole kbps, whole fps,
/// whole milliseconds), so two ticks that would render identically compare equal — which is
/// what lets `StreamTelemetryModel` skip the publish and keep the SwiftUI graph quiet while
/// a stream is steady.
struct StreamTelemetry: Equatable {
    /// Round trip of the input data-channel ping, in whole milliseconds.
    var latencyMs: Int = 0

    var videoKbps: Int?
    /// Whole frames per second, as rendered — the raw rate jitters every window.
    var videoFps: Int?
    var videoPlayoutDelayMs: Int?
    var videoJitterMs: Int?
    var videoDecodeMs: Int?
    var videoPacketsLost: Int?
    var videoRoundTripTimeMs: Int?

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
    var packetsLost: Int?
    var roundTripTimeMs: Int?

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
        videoPacketsLost = video.packetsLost
        videoRoundTripTimeMs = video.roundTripTimeMs
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

    /// Clears every field — used when a connection is torn down.
    func reset() {
        publish(.empty)
    }
}
