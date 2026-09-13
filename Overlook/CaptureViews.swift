import SwiftUI
import AppKit

// MARK: - Toolbar controls

/// Camera button: saves the frame on screen as a PNG.
struct ScreenshotButton: View {
    @EnvironmentObject var captureManager: CaptureManager
    let isConnected: Bool

    var body: some View {
        Button(action: { captureManager.saveScreenshot() }) {
            Image(systemName: "camera")
        }
        .disabled(!isConnected)
        .help("Save Screenshot (⇧⌘S)")
    }
}

/// Record button: click to start or stop. What gets recorded is chosen in `RecordingModePicker`.
struct RecordingButton: View {
    @EnvironmentObject var captureManager: CaptureManager
    let isConnected: Bool

    var body: some View {
        Button(action: { captureManager.toggleRecording() }) {
            if captureManager.isRecording {
                Image(systemName: "stop.circle.fill")
                    .foregroundStyle(.red)
            } else {
                Image(systemName: "record.circle")
            }
        }
        .disabled(!isConnected && !captureManager.isRecording)
        .help(captureManager.isRecording ? "Stop Recording (⇧⌘R)" : "Start Recording (⇧⌘R)")
    }
}

/// Pop-up next to the record button: video and audio, video only, or audio only. A native pop-up
/// rather than items inside the record button's menu — a SwiftUI `Menu` in the toolbar showed the
/// choices but neither applied nor refreshed a selection made inside it.
struct RecordingModePicker: View {
    @EnvironmentObject var captureManager: CaptureManager

    var body: some View {
        Picker("Record", selection: $captureManager.recordingMode) {
            ForEach(RecordingMode.allCases) { mode in
                Label(mode.shortTitle, systemImage: mode.systemImage).tag(mode)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
        .help(captureManager.isRecording
              ? "What the next recording keeps — this one is \(captureManager.activeRecordingMode?.title ?? "in progress")"
              : "What a recording keeps")
    }
}

/// `0:42` next to the record button while recording.
struct RecordingElapsedLabel: View {
    @ObservedObject var clock: RecordingClock

    var body: some View {
        Text(clock.elapsedText)
            .font(.callout)
            .monospacedDigit()
            .foregroundStyle(.red)
            .accessibilityLabel("Recording for \(clock.elapsedText)")
    }
}

// MARK: - Overlays on the video

/// Top-right capsule while recording: pulsing red dot, elapsed time, what is being recorded.
/// Also the only indicator in fullscreen, where the toolbar is hidden.
struct RecordingBadge: View {
    @ObservedObject var clock: RecordingClock
    let mode: RecordingMode

    @State private var isDimmed = false

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(.red)
                .frame(width: 8, height: 8)
                .opacity(isDimmed ? 0.35 : 1)
                .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: isDimmed)
            Text(clock.elapsedText)
                .monospacedDigit()
            Image(systemName: mode.systemImage)
                .foregroundStyle(.secondary)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .allowsHitTesting(false)
        .onAppear { isDimmed = true }
        .accessibilityLabel("Recording \(mode.title), \(clock.elapsedText)")
    }
}

/// Brief white flash over the video when a screenshot is taken: snaps to 65% white, fades out.
struct ScreenshotFlash: View {
    let trigger: Int

    var body: some View {
        Color.white
            .phaseAnimator([false, true], trigger: trigger) { view, lit in
                view.opacity(lit ? 0.65 : 0)
            } animation: { lit in
                lit ? .linear(duration: 0.02) : .easeOut(duration: 0.35)
            }
            .allowsHitTesting(false)
    }
}

/// Bottom-right toast after a save (or a failure), with Show for the file and a close button.
struct CaptureNoticeView: View {
    let notice: CaptureManager.Notice
    let onShow: (URL) -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: notice.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(notice.isError ? Color.orange : Color.green)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                Text(notice.title)
                    .font(.callout.weight(.medium))
                if let detail = notice.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            if let url = notice.fileURL {
                Button("Show") { onShow(url) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
        .frame(maxWidth: 420)
    }
}

// MARK: - Capture menu (menu bar of the app)

/// The Capture menu. Its shortcuts work when the window has focus and keys are not being sent to
/// the target; `InputManager` reproduces ⇧⌘S and ⇧⌘R while they are.
struct CaptureCommands: Commands {
    @ObservedObject var captureManager: CaptureManager

    var body: some Commands {
        CommandMenu("Capture") {
            Button("Save Screenshot") {
                captureManager.saveScreenshot()
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])

            Button(captureManager.isRecording ? "Stop Recording" : "Start Recording") {
                captureManager.toggleRecording()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])

            Divider()

            Picker("Record", selection: $captureManager.recordingMode) {
                ForEach(RecordingMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }

            Picker("Video Codec", selection: $captureManager.videoCodec) {
                ForEach(RecordingVideoCodec.allCases) { codec in
                    Text(codec.title).tag(codec)
                }
            }

            Divider()

            Button("Show Screenshots in Finder") {
                captureManager.revealFolder(.screenshots)
            }
            Button("Show Recordings in Finder") {
                captureManager.revealFolder(.recordings)
            }
        }
    }
}

// MARK: - Settings section

struct CaptureSettingsSection: View {
    @EnvironmentObject var captureManager: CaptureManager

    @Binding var isExpanded: Bool

    var body: some View {
        DisclosureGroup("Capture", isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                CaptureFolderRow(folder: .screenshots)
                CaptureFolderRow(folder: .recordings)

                Picker("Video codec", selection: $captureManager.videoCodec) {
                    ForEach(RecordingVideoCodec.allCases) { codec in
                        Text(codec.title).tag(codec)
                    }
                }
                .help("Applies to the next recording. Audio is always AAC.")

                Text("⇧⌘S saves a screenshot; ⇧⌘R starts and stops a recording. Both work while keys are being sent to the target, so the target never sees them.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 6)
        }
    }
}

/// One folder setting: label, current path (⌘-click to open), Choose…, and reset to the default.
private struct CaptureFolderRow: View {
    @EnvironmentObject var captureManager: CaptureManager
    let folder: CaptureManager.Folder

    var body: some View {
        let url = captureManager.folderURL(folder)
        VStack(alignment: .leading, spacing: 4) {
            Text(folder.title)
            HStack(spacing: 6) {
                Button(action: { captureManager.revealFolder(folder) }) {
                    Text(CaptureManager.displayPath(url))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.plain)
                .help("Open \(url.path) in Finder")

                Spacer(minLength: 4)

                Button("Choose…") {
                    captureManager.chooseFolder(folder)
                }
                .controlSize(.small)

                Button(action: { captureManager.resetFolder(folder) }) {
                    Image(systemName: "arrow.counterclockwise")
                }
                .controlSize(.small)
                .disabled(url.standardizedFileURL == folder.defaultURL.standardizedFileURL)
                .help("Use the default folder, \(CaptureManager.displayPath(folder.defaultURL))")
            }
        }
    }
}
