import SwiftUI

/// Renders the input data-channel latency.
///
/// This is its own observer so the chrome that contains it (status bar, connections popover)
/// stays out of the telemetry dependency graph: a latency tick invalidates this label only.
/// Colour is inherited, so callers can tint it with the usual modifiers.
struct ConnectionLatencyLabel: View {
    @EnvironmentObject private var telemetryModel: StreamTelemetryModel

    var body: some View {
        Text("Latency: \(telemetryModel.snapshot.latencyMs)ms")
            .font(.caption)
    }
}

/// The WebRTC statistics block of the connections popover.
///
/// Observes `StreamTelemetryModel` directly — the popover and everything above it never read
/// telemetry, so a stats tick re-evaluates this subtree and nothing else.
struct StreamStatsSection: View {
    @EnvironmentObject private var telemetryModel: StreamTelemetryModel

    /// Guest resolution. Not telemetry: it also drives input mapping and window aspect, so it
    /// stays on `WebRTCManager` and is handed down.
    let videoSize: CGSize?

    var body: some View {
        let telemetry = telemetryModel.snapshot

        let resolutionText: String = {
            guard let videoSize, videoSize.width > 0, videoSize.height > 0 else { return "—" }
            return "\(Int(videoSize.width))x\(Int(videoSize.height))"
        }()
        let kbpsText = telemetry.videoKbps.map { "\($0) kbps" } ?? "— kbps"
        let fpsText = telemetry.videoFps.map { "\($0) fps" } ?? "— fps"

        VStack(alignment: .leading, spacing: 6) {
            Text("WebRTC")
                .font(.caption)
                .foregroundColor(.secondary)

            StreamStatRow(label: "Video", value: "\(resolutionText) · \(fpsText) · \(kbpsText)")
            StreamStatRow(label: "Playout", value: Self.msText(telemetry.videoPlayoutDelayMs))
            StreamStatRow(label: "Jitter", value: Self.msText(telemetry.videoJitterMs))
            StreamStatRow(label: "Decode", value: Self.msText(telemetry.videoDecodeMs))
            StreamStatRow(label: "Lost", value: telemetry.videoPacketsLost.map(String.init) ?? "—")
            StreamStatRow(label: "ICE RTT", value: Self.msText(telemetry.videoRoundTripTimeMs))

            if telemetry.hasAudioStats {
                StreamStatRow(
                    label: "Audio",
                    value: telemetry.audioKbps.map { "\($0) kbps" } ?? "— kbps"
                )
                StreamStatRow(
                    label: "Audio Playout",
                    value: Self.msText(telemetry.audioPlayoutDelayMs)
                )
                StreamStatRow(label: "Audio Jitter", value: Self.msText(telemetry.audioJitterMs))
                StreamStatRow(
                    label: "Audio Lost",
                    value: telemetry.audioPacketsLost.map(String.init) ?? "—"
                )
                StreamStatRow(
                    label: "Audio ICE RTT",
                    value: Self.msText(telemetry.audioRoundTripTimeMs)
                )
            }
        }
    }

    private static func msText(_ value: Int?) -> String {
        value.map { "\($0) ms" } ?? "—"
    }
}

/// One labelled statistic row.
private struct StreamStatRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
            Spacer()
            Text(value)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}
