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

/// Capture-region button. Off: click, then drag a rectangle on the video. Lit while selecting
/// (click again cancels) and while a region is set (click again clears it). Choosing a different
/// region without clearing first is Capture › Select Capture Region….
struct CaptureRegionToggle: View {
    @EnvironmentObject var captureManager: CaptureManager
    @EnvironmentObject var webRTCManager: WebRTCManager
    let isConnected: Bool

    var body: some View {
        Toggle(isOn: Binding(
            get: { captureManager.isSelectingRegion || captureManager.captureRegion != nil },
            set: { _ in captureManager.toggleRegionSelection() }
        )) {
            Image(systemName: captureManager.captureRegion == nil ? "rectangle.dashed" : "rectangle.inset.filled")
        }
        .toggleStyle(.button)
        // Turning a set region off must work even after a disconnect; starting one needs video.
        .disabled(!isConnected && captureManager.captureRegion == nil && !captureManager.isSelectingRegion)
        .help(helpText)
        .accessibilityLabel("Capture Region")
    }

    private var helpText: String {
        if captureManager.isSelectingRegion {
            return "Drag on the video to select the capture region — Esc or click again to cancel"
        }
        if captureManager.captureRegion != nil {
            let size = captureManager.regionSizeText(videoSize: webRTCManager.videoSize).map { " \($0)" } ?? ""
            return "Capture region\(size) — screenshots and recordings keep only this area. Click to turn it off"
        }
        return "Select Capture Region — drag a rectangle on the video; screenshots and recordings then keep only that area"
    }
}

// MARK: - Overlays on the video

/// Top-right capsule while recording: pulsing red dot, elapsed time, what is being recorded.
/// Also the only indicator in fullscreen, where the toolbar is hidden.
struct RecordingBadge: View {
    @ObservedObject var clock: RecordingClock
    let mode: RecordingMode
    /// The recording keeps only the capture region; shown as a crop mark.
    var isCropped = false

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
            if isCropped {
                Image(systemName: "crop")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .allowsHitTesting(false)
        .onAppear { isDimmed = true }
        .accessibilityLabel("Recording \(mode.title)\(isCropped ? " of the capture region" : ""), \(clock.elapsedText)")
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

/// Drag-to-select overlay while a capture region is being chosen: the video dims except inside the
/// rubber band, the band's size in guest pixels hangs off its corner, and a hint sits top-center.
/// Esc cancels through a local key monitor — keyboard capture is paused while selecting, so the
/// key reaches the app, but nothing in the video surface has focus to receive it.
struct CaptureRegionSelectionOverlay: View {
    let selectionRectInView: CGRect?
    let sizeText: String?
    let viewSize: CGSize
    let onCancel: () -> Void

    @State private var escapeMonitor: Any?

    var body: some View {
        ZStack(alignment: .top) {
            // Everything outside the band is dimmed (even-odd fill leaves the band clear).
            Path { path in
                path.addRect(CGRect(origin: .zero, size: viewSize))
                if let selectionRectInView {
                    path.addRect(selectionRectInView)
                }
            }
            .fill(Color.black.opacity(0.4), style: FillStyle(eoFill: true))

            if let selectionRectInView {
                let labelFitsBelow = selectionRectInView.maxY + 26 <= viewSize.height
                Rectangle()
                    .stroke(Color.white, lineWidth: 1.5)
                    .shadow(color: .black.opacity(0.7), radius: 1)
                    .frame(width: selectionRectInView.width, height: selectionRectInView.height)
                    .overlay(alignment: .bottomTrailing) {
                        if let sizeText {
                            Text(sizeText)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 4))
                                .fixedSize()
                                // Hangs just below the bottom-right corner; inside it when the
                                // band reaches the bottom of the view.
                                .alignmentGuide(.bottom) { d in labelFitsBelow ? d[.top] - 6 : d[.bottom] + 6 }
                                .alignmentGuide(.trailing) { d in labelFitsBelow ? d[.trailing] : d[.trailing] + 6 }
                        }
                    }
                    .position(x: selectionRectInView.midX, y: selectionRectInView.midY)
            }

            HStack(spacing: 6) {
                Image(systemName: "rectangle.dashed")
                Text("Drag to select the capture region")
                Text("·")
                    .foregroundStyle(.secondary)
                Text("Esc cancels")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .padding(.top, 12)
        }
        .frame(width: viewSize.width, height: viewSize.height)
        .allowsHitTesting(false)
        .onAppear {
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.keyCode == 53 else { return event }   // Escape
                onCancel()
                return nil
            }
        }
        .onDisappear {
            if let escapeMonitor {
                NSEvent.removeMonitor(escapeMonitor)
            }
            escapeMonitor = nil
        }
    }
}

/// Dashed outline of the set capture region over the video, with corner marks so it reads on any
/// content. Never hit-testable; hidden by Capture › Show Capture Region Outline.
struct CaptureRegionOutline: View {
    let rectInView: CGRect

    var body: some View {
        ZStack {
            Rectangle()
                .stroke(Color.black.opacity(0.55), lineWidth: 3.5)
            Rectangle()
                .stroke(Color.white, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            CornerMarks(length: 10)
                .stroke(Color.white, style: StrokeStyle(lineWidth: 2, lineCap: .square))
                .shadow(color: .black.opacity(0.7), radius: 1)
        }
        .frame(width: rectInView.width, height: rectInView.height)
        .position(x: rectInView.midX, y: rectInView.midY)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private struct CornerMarks: Shape {
        let length: CGFloat

        func path(in rect: CGRect) -> Path {
            var path = Path()
            let l = min(length, rect.width / 2, rect.height / 2)
            // Top-left
            path.move(to: CGPoint(x: rect.minX, y: rect.minY + l))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX + l, y: rect.minY))
            // Top-right
            path.move(to: CGPoint(x: rect.maxX - l, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + l))
            // Bottom-right
            path.move(to: CGPoint(x: rect.maxX, y: rect.maxY - l))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX - l, y: rect.maxY))
            // Bottom-left
            path.move(to: CGPoint(x: rect.minX + l, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - l))
            return path
        }
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

            // No key equivalents on purpose: every chord intercepted here is one the target loses,
            // and drawing a region is a mouse action anyway.
            Button("Select Capture Region…") {
                captureManager.beginRegionSelection()
            }
            Button("Clear Capture Region") {
                captureManager.clearCaptureRegion()
            }
            .disabled(captureManager.captureRegion == nil)
            Toggle("Show Capture Region Outline", isOn: $captureManager.showsRegionOutline)

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

                CaptureRegionRow()

                Text("⇧⌘S saves a screenshot; ⇧⌘R starts and stops a recording. Both work while keys are being sent to the target, so the target never sees them. A capture region limits both to part of the screen until it is turned off or Overlook quits.")
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

/// Capture region status with Select…/Clear, and the outline switch. The region itself is drawn on
/// the video; this row is the place to find it from Settings.
private struct CaptureRegionRow: View {
    @EnvironmentObject var captureManager: CaptureManager
    @EnvironmentObject var webRTCManager: WebRTCManager

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Capture region")
                Spacer(minLength: 4)
                if captureManager.captureRegion != nil {
                    Text(captureManager.regionSizeText(videoSize: webRTCManager.videoSize) ?? "Set")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Button("Clear") {
                        captureManager.clearCaptureRegion()
                    }
                    .controlSize(.small)
                } else {
                    Text("Whole screen")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Button("Select…") {
                        captureManager.beginRegionSelection()
                    }
                    .controlSize(.small)
                    .help("Drag a rectangle on the video; screenshots and recordings then keep only that area")
                }
            }

            Toggle("Outline the region on the video", isOn: $captureManager.showsRegionOutline)
                .help("Off hides the dashed outline only; the region stays in effect")
        }
    }
}
