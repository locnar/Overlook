import SwiftUI

/// Renders the HID WebSocket round trip — the path keystrokes and mouse reports take.
///
/// This is its own observer so the chrome that contains it stays out of the telemetry
/// dependency graph: a pong invalidates this label only. Colour is inherited, so callers can
/// tint it with the usual modifiers.
struct HIDRoundTripLabel: View {
    @EnvironmentObject private var telemetryModel: StreamTelemetryModel

    var body: some View {
        let ms = telemetryModel.snapshot.hidRoundTripMs
        Text("HID RTT: \(ms.map { "\($0) ms" } ?? "—")")
            .font(.caption)
    }
}

/// One line of session history: how long the session has been up, how many times it has been
/// reconnected and why the last time. Empty until a session exists. The uptime re-renders on
/// the minute without a single telemetry publish.
struct SessionHistoryLabel: View {
    @EnvironmentObject private var telemetryModel: StreamTelemetryModel

    var body: some View {
        let telemetry = telemetryModel.snapshot
        if let connectedAt = telemetry.sessionConnectedAt {
            TimelineView(.everyMinute) { context in
                Text(Self.text(connectedAt: connectedAt, now: context.date, telemetry: telemetry))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private static func text(connectedAt: Date, now: Date, telemetry: StreamTelemetry) -> String {
        var parts = ["Up \(uptimeText(seconds: now.timeIntervalSince(connectedAt)))"]
        let reconnects = telemetry.sessionReconnectCount
        if reconnects > 0 {
            parts.append("\(reconnects) reconnect\(reconnects == 1 ? "" : "s")")
            if let reason = telemetry.sessionLastReconnectReason, !reason.isEmpty {
                if let at = telemetry.sessionLastReconnectAt {
                    parts.append("last \(agoText(seconds: now.timeIntervalSince(at))): \(reason)")
                } else {
                    parts.append("last: \(reason)")
                }
            }
        }
        return parts.joined(separator: " · ")
    }

    private static func uptimeText(seconds: TimeInterval) -> String {
        let minutes = max(0, Int(seconds / 60))
        if minutes < 1 { return "<1 min" }
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) h \(minutes % 60) min"
    }

    private static func agoText(seconds: TimeInterval) -> String {
        let minutes = max(0, Int(seconds / 60))
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes) min ago" }
        return "\(minutes / 60) h \(minutes % 60) min ago"
    }
}

/// The statistics block of the connections popover: what the device reports over the HID
/// socket, then the WebRTC video and audio figures.
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

        VStack(alignment: .leading, spacing: 6) {
            Text("Device")
                .font(.caption)
                .foregroundColor(.secondary)

            StreamStatRow(label: "HID link", value: Self.hidLinkText(telemetry))
            StreamStatRow(label: "HDMI in", value: Self.hdmiText(telemetry))

            Text("WebRTC")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.top, 4)

            StreamStatRow(label: "Video", value: Self.videoText(telemetry, videoSize: videoSize))
            StreamStatRow(label: "Codec", value: Self.codecText(telemetry))
            StreamStatRow(label: "Playout", value: Self.msText(telemetry.videoPlayoutDelayMs))
            StreamStatRow(label: "Jitter", value: Self.msText(telemetry.videoJitterMs))
            StreamStatRow(label: "Decode", value: Self.msText(telemetry.videoDecodeMs))
            StreamStatRow(label: "Processing", value: Self.msText(telemetry.videoProcessingDelayMs))
            StreamStatRow(label: "Lost", value: Self.countText(telemetry.videoPacketsLost, unit: "packet"))
            StreamStatRow(label: "Dropped", value: Self.countText(telemetry.videoFramesDropped, unit: "frame"))
            StreamStatRow(label: "Repair", value: Self.repairText(telemetry))
            StreamStatRow(label: "Freezes", value: Self.freezesText(telemetry))
            StreamStatRow(label: "ICE RTT", value: Self.msText(telemetry.videoRoundTripTimeMs))
            StreamStatRow(label: "Path", value: telemetry.networkPath ?? "—")
            StreamStatRow(label: "Remote", value: telemetry.networkRemoteAddress ?? "—")
            if let kbps = telemetry.availableIncomingKbps {
                StreamStatRow(label: "Link", value: "\(kbps) kbps available")
            }

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

    // MARK: Formatting

    private static func msText(_ value: Int?) -> String {
        value.map { "\($0) ms" } ?? "—"
    }

    private static func countText(_ value: Int?, unit: String) -> String {
        guard let value else { return "—" }
        return "\(value) \(unit)\(value == 1 ? "" : "s")"
    }

    private static func hidLinkText(_ telemetry: StreamTelemetry) -> String {
        let link: String
        switch telemetry.hidLink {
        case .disconnected: link = "Disconnected"
        case .connecting: link = "Connecting…"
        case .connected: link = "Connected"
        case .reconnecting: link = "Reconnecting…"
        }
        var parts = [link]
        if telemetry.hidLink == .connected {
            parts.append("queue \(telemetry.hidQueueDepth)")
        }
        if let usb = telemetry.hidUSBConnected {
            parts.append(usb ? "USB up" : "USB down")
        }
        return parts.joined(separator: " · ")
    }

    private static func hdmiText(_ telemetry: StreamTelemetry) -> String {
        guard let online = telemetry.hdmiOnline else { return "—" }
        guard online else { return "No signal" }
        var parts: [String] = []
        if let resolution = telemetry.hdmiResolution {
            parts.append(resolution)
        }
        switch (telemetry.hdmiCapturedFps, telemetry.hdmiDesiredFps) {
        case (let captured?, let desired?) where captured != desired:
            parts.append("\(captured) fps (\(desired) wanted)")
        case (let captured?, _):
            parts.append("\(captured) fps")
        case (nil, let desired?):
            parts.append("\(desired) fps wanted")
        default:
            break
        }
        parts.append("signal")
        return parts.joined(separator: " · ")
    }

    private static func videoText(_ telemetry: StreamTelemetry, videoSize: CGSize?) -> String {
        let resolutionText: String = {
            guard let videoSize, videoSize.width > 0, videoSize.height > 0 else { return "—" }
            return "\(Int(videoSize.width))x\(Int(videoSize.height))"
        }()
        let kbpsText = telemetry.videoKbps.map { "\($0) kbps" } ?? "— kbps"
        let fpsText = telemetry.videoFps.map { "\($0) fps" } ?? "— fps"
        return "\(resolutionText) · \(fpsText) · \(kbpsText)"
    }

    private static func codecText(_ telemetry: StreamTelemetry) -> String {
        guard telemetry.videoCodec != nil || telemetry.videoDecoder != nil else { return "—" }
        var parts: [String] = []
        if let codec = telemetry.videoCodec { parts.append(codec) }
        if let decoder = telemetry.videoDecoder {
            if let efficient = telemetry.videoDecoderIsPowerEfficient {
                parts.append("\(decoder) (\(efficient ? "hardware" : "software"))")
            } else {
                parts.append(decoder)
            }
        }
        return parts.joined(separator: " · ")
    }

    private static func repairText(_ telemetry: StreamTelemetry) -> String {
        guard telemetry.videoPliCount != nil || telemetry.videoNackCount != nil else { return "—" }
        return "\(telemetry.videoPliCount ?? 0) PLI · \(telemetry.videoNackCount ?? 0) NACK"
    }

    private static func freezesText(_ telemetry: StreamTelemetry) -> String {
        guard let freezes = telemetry.videoFreezeCount else { return "—" }
        var text = "\(freezes)"
        if let durationMs = telemetry.videoFreezeDurationMs, durationMs > 0 {
            text += String(format: " (%.1f s)", Double(durationMs) / 1000.0)
        }
        if let pauses = telemetry.videoPauseCount, pauses > 0 {
            text += " · \(pauses) pause\(pauses == 1 ? "" : "s")"
        }
        return text
    }
}

/// One labelled statistic row.
private struct StreamStatRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption)
            Spacer()
            Text(value)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}
