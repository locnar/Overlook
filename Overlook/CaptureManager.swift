import Foundation
import AppKit
import Combine
import CoreImage
import ImageIO
import UniformTypeIdentifiers
#if canImport(WebRTC)
import WebRTC
#endif

/// Elapsed time of the running recording, published on its own object so only the labels that
/// show it re-render each tick — `ContentView` observes `CaptureManager`, which changes rarely.
@MainActor
final class RecordingClock: ObservableObject {
    @Published private(set) var elapsed: TimeInterval = 0

    private var startedAt: Date?
    private var timer: Timer?

    var elapsedText: String {
        let total = Int(elapsed.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    func start() {
        startedAt = Date()
        elapsed = 0
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let startedAt = self.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(startedAt)
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        startedAt = nil
    }
}

/// Screenshots and recordings of the remote console.
///
/// Both read the media the app already receives: the latest decoded frame kept by
/// `MediaCaptureHub` (a screenshot) and the frame and playout-PCM feeds forwarded to a
/// `SessionRecorder` (a recording). Files land in fixed folders under timestamped names; a notice
/// with a Show button appears for a few seconds after each save. Triggered from the toolbar, the
/// Capture menu (⇧⌘S / ⇧⌘R), the menu bar agent, and — while keyboard capture would otherwise
/// swallow the shortcuts — `InputManager`, which posts the notifications handled here.
@MainActor
final class CaptureManager: ObservableObject {
    struct Notice: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let detail: String?
        let fileURL: URL?
        let isError: Bool
    }

    enum Folder {
        case screenshots
        case recordings

        var defaultsKey: String {
            switch self {
            case .screenshots: return "overlook.capture.screenshotsFolder"
            case .recordings: return "overlook.capture.recordingsFolder"
            }
        }

        /// ~/Pictures/Overlook and ~/Movies/Overlook.
        var defaultURL: URL {
            let base: URL
            switch self {
            case .screenshots:
                base = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
                    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures")
            case .recordings:
                base = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
                    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies")
            }
            return base.appendingPathComponent("Overlook", isDirectory: true)
        }

        var title: String {
            switch self {
            case .screenshots: return "Screenshots"
            case .recordings: return "Recordings"
            }
        }
    }

    @Published private(set) var isRecording = false
    /// The mode the running recording actually uses, which can differ from `recordingMode` when
    /// audio was asked for but is off (see `startRecording`).
    @Published private(set) var activeRecordingMode: RecordingMode?
    @Published private(set) var notice: Notice?
    /// Bumped once per screenshot; the video surface flashes when it changes.
    @Published private(set) var screenshotFlashCount = 0

    @Published var recordingMode: RecordingMode {
        didSet { UserDefaults.standard.set(recordingMode.rawValue, forKey: Self.recordingModeDefaultsKey) }
    }
    @Published var videoCodec: RecordingVideoCodec {
        didSet { UserDefaults.standard.set(videoCodec.rawValue, forKey: Self.videoCodecDefaultsKey) }
    }
    @Published var screenshotsFolder: URL {
        didSet { UserDefaults.standard.set(screenshotsFolder.path, forKey: Folder.screenshots.defaultsKey) }
    }
    @Published var recordingsFolder: URL {
        didSet { UserDefaults.standard.set(recordingsFolder.path, forKey: Folder.recordings.defaultsKey) }
    }

    let clock = RecordingClock()

    private static let recordingModeDefaultsKey = "overlook.capture.recordingMode"
    private static let videoCodecDefaultsKey = "overlook.capture.videoCodec"

    private let webRTCManager: WebRTCManager
    private let kvmDeviceManager: KVMDeviceManager
    private var hub: MediaCaptureHub { webRTCManager.captureHub }

    private var recorder: SessionRecorder?
    private var noticeDismissTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    private static let fileTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter
    }()

    init(webRTCManager: WebRTCManager, kvmDeviceManager: KVMDeviceManager) {
        self.webRTCManager = webRTCManager
        self.kvmDeviceManager = kvmDeviceManager

        let defaults = UserDefaults.standard
        recordingMode = RecordingMode(rawValue: defaults.string(forKey: Self.recordingModeDefaultsKey) ?? "") ?? .videoAndAudio
        videoCodec = RecordingVideoCodec(rawValue: defaults.string(forKey: Self.videoCodecDefaultsKey) ?? "") ?? .h264
        screenshotsFolder = Self.storedFolder(.screenshots)
        recordingsFolder = Self.storedFolder(.recordings)

        NotificationCenter.default.publisher(for: .overlookSaveScreenshot)
            .sink { [weak self] _ in self?.saveScreenshot() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .overlookToggleRecording)
            .sink { [weak self] _ in self?.toggleRecording() }
            .store(in: &cancellables)

        // An operator disconnect ends the recording; a dropped connection does not (the
        // auto-reconnect keeps the same recorder, with a gap in the file).
        kvmDeviceManager.$connectedDevice
            .dropFirst()
            .sink { [weak self] device in
                guard let self, device == nil, self.isRecording else { return }
                self.stopRecording()
            }
            .store(in: &cancellables)
    }

    // MARK: Screenshot

    func saveScreenshot() {
        guard let frame = hub.latestFrame else {
            showNotice(title: "No video to capture", detail: "Wait for the stream to show a frame, then try again.", fileURL: nil, isError: true)
            return
        }

        let url = makeFileURL(in: screenshotsFolder, extension: "png")
        screenshotFlashCount += 1

        Task.detached(priority: .userInitiated) {
            do {
                try ScreenshotWriter.writePNG(frame: frame, to: url)
                await MainActor.run {
                    self.showNotice(title: "Screenshot saved", detail: url.lastPathComponent, fileURL: url, isError: false)
                }
            } catch {
                await MainActor.run {
                    self.showNotice(title: "Screenshot failed", detail: error.localizedDescription, fileURL: nil, isError: true)
                }
            }
        }
    }

    // MARK: Recording

    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    func startRecording() {
        guard recorder == nil else { return }
        guard kvmDeviceManager.connectedDevice != nil else {
            showNotice(title: "Not connected", detail: "Connect to a device before recording.", fileURL: nil, isError: true)
            return
        }

        var mode = recordingMode
        var downgradeDetail: String?
        if mode.recordsAudio, webRTCManager.isAudioPlayoutAvailable == false {
            // Nothing would ever reach an audio track; an empty track confuses players.
            if mode == .audioOnly {
                showNotice(
                    title: "Audio is off",
                    detail: "Turn on Audio in Settings › Audio and reconnect to record audio.",
                    fileURL: nil,
                    isError: true
                )
                return
            }
            mode = .videoOnly
            downgradeDetail = "Audio is off in Settings › Audio, so this recording is video only."
        }

        let url = makeFileURL(in: recordingsFolder, extension: mode.fileExtension)
        do {
            let recorder = try SessionRecorder(
                url: url,
                mode: mode,
                codec: videoCodec,
                initialVideoSize: webRTCManager.videoSize,
                audioChannels: webRTCManager.playoutChannelCount,
                audioSampleRate: webRTCManager.playoutSampleRate
            )
            self.recorder = recorder
            hub.setRecorder(recorder)
            activeRecordingMode = mode
            isRecording = true
            clock.start()
            if let downgradeDetail {
                showNotice(title: "Recording video only", detail: downgradeDetail, fileURL: nil, isError: false)
            } else {
                dismissNotice()
            }
        } catch {
            showNotice(title: "Could not start recording", detail: error.localizedDescription, fileURL: nil, isError: true)
        }
    }

    func stopRecording() {
        guard let recorder else { return }
        hub.setRecorder(nil)
        self.recorder = nil
        isRecording = false
        activeRecordingMode = nil
        clock.stop()

        recorder.stop { [weak self] result in
            Task { @MainActor [weak self] in
                self?.handleRecordingFinished(result)
            }
        }
    }

    /// Quit path: finalize the file before the process exits, or the movie is unplayable.
    func finishRecordingForTermination() async {
        guard let recorder else { return }
        hub.setRecorder(nil)
        self.recorder = nil
        isRecording = false
        activeRecordingMode = nil
        clock.stop()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            recorder.stop { _ in continuation.resume() }
        }
    }

    private func handleRecordingFinished(_ result: Result<RecordingResult, Error>) {
        switch result {
        case .success(let recording):
            let length = Self.durationText(recording.duration)
            showNotice(
                title: "Recording saved (\(length))",
                detail: recording.url.lastPathComponent,
                fileURL: recording.url,
                isError: false
            )
        case .failure(let error):
            showNotice(title: "Recording not saved", detail: error.localizedDescription, fileURL: nil, isError: true)
        }
    }

    // MARK: Folders

    func chooseFolder(_ folder: Folder) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose where Overlook saves \(folder.title.lowercased())."
        panel.directoryURL = self.folderURL(folder)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setFolder(folder, to: url)
    }

    func resetFolder(_ folder: Folder) {
        setFolder(folder, to: folder.defaultURL)
    }

    func folderURL(_ folder: Folder) -> URL {
        switch folder {
        case .screenshots: return screenshotsFolder
        case .recordings: return recordingsFolder
        }
    }

    func revealFolder(_ folder: Folder) {
        let url = folderURL(folder)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// `~/Pictures/Overlook` style path for the settings panel.
    static func displayPath(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    private func setFolder(_ folder: Folder, to url: URL) {
        switch folder {
        case .screenshots: screenshotsFolder = url
        case .recordings: recordingsFolder = url
        }
    }

    private static func storedFolder(_ folder: Folder) -> URL {
        if let path = UserDefaults.standard.string(forKey: folder.defaultsKey), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return folder.defaultURL
    }

    // MARK: Notices

    func dismissNotice() {
        noticeDismissTask?.cancel()
        noticeDismissTask = nil
        notice = nil
    }

    private func showNotice(title: String, detail: String?, fileURL: URL?, isError: Bool) {
        noticeDismissTask?.cancel()
        let shown = Notice(title: title, detail: detail, fileURL: fileURL, isError: isError)
        notice = shown
        noticeDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: isError ? 8_000_000_000 : 5_000_000_000)
            guard !Task.isCancelled, let self, self.notice == shown else { return }
            self.notice = nil
        }
    }

    // MARK: Names

    /// `Overlook <device> 2026-09-13 at 14.05.22.png`, made unique with " (2)" etc. if needed.
    private func makeFileURL(in folder: URL, extension ext: String) -> URL {
        var stem = "Overlook"
        if let deviceName = kvmDeviceManager.connectedDevice?.name {
            let cleaned = deviceName
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                stem += " \(cleaned)"
            }
        }
        stem += " " + Self.fileTimestampFormatter.string(from: Date())

        var candidate = folder.appendingPathComponent(stem).appendingPathExtension(ext)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(stem) (\(counter))").appendingPathExtension(ext)
            counter += 1
        }
        return candidate
    }

    private static func durationText(_ duration: TimeInterval) -> String {
        let total = Int(duration.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - PNG output

enum ScreenshotWriter {
    enum WriteError: LocalizedError {
        case unsupportedFrame
        case imageCreationFailed
        case fileWriteFailed(URL)

        var errorDescription: String? {
            switch self {
            case .unsupportedFrame: return "The video frame is in a format that cannot be saved."
            case .imageCreationFailed: return "The frame could not be converted to an image."
            case .fileWriteFailed(let url): return "Could not write \(url.lastPathComponent)."
            }
        }
    }

    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    static func writePNG(frame: RTCVideoFrame, to url: URL) throws {
        guard let pixelBuffer = VideoFrameConversion.pixelBuffer(for: frame) else {
            throw WriteError.unsupportedFrame
        }
        // Core Image applies the buffer's YCbCr matrix and range when it reads a 4:2:0 buffer.
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = context.createCGImage(image, from: image.extent) else {
            throw WriteError.imageCreationFailed
        }

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw WriteError.fileWriteFailed(url)
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw WriteError.fileWriteFailed(url)
        }
    }
}
