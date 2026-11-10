import Foundation
import AppKit
import Combine

// Settings kept on this Mac rather than on the KVM, one object each for every console window and
// for the Settings window (Overlook › Settings…). They used to be read once by each window's own
// `InputManager` and `CaptureManager`, so a change made in one window did not reach the others,
// and nothing could be changed with no window open. Every session is handed these objects now, and
// the Settings window binds to the same ones. The keys are the ones these settings have always been
// stored under. (`AudioPreferences` and `NetworkPreferences` follow the same pattern, in their own
// files.)

// MARK: - Input

/// Relative mouse mode on this Mac: the local sensitivity and whether raw counts are sent.
@MainActor
final class InputPreferences: ObservableObject {
    enum Keys {
        static let relativeSensitivity = "overlook.relativeMouseSensitivity"
        static let unacceleratedInput = "overlook.relativeMouseUnacceleratedInput"
    }

    /// The range and step the Settings slider offers.
    static let sensitivityRange: ClosedRange<Double> = 0.25...4.0
    static let sensitivityStep: Double = 0.05

    /// Multiplier applied to relative mouse movement. With accelerated input it sits on top of the
    /// view-to-remote scale; with unaccelerated input it is the only factor. Read on every captured
    /// mouse move, so a change applies at once in every window.
    @Published var relativeSensitivity: Double {
        didSet { defaults.set(relativeSensitivity, forKey: Keys.relativeSensitivity) }
    }

    /// Send the mouse's raw movement counts (kCGEventUnacceleratedPointerMovementX/Y) instead of
    /// macOS-accelerated deltas, so the target applies its own pointer settings once.
    @Published var useUnacceleratedRelativeInput: Bool {
        didSet { defaults.set(useUnacceleratedRelativeInput, forKey: Keys.unacceleratedInput) }
    }

    /// The app's, on this Mac's own defaults (the test host's suite when hosting the tests).
    static let shared = InputPreferences(defaults: AppEnvironment.defaults)

    /// The app's object for the app's defaults, or one of its own for a test's scratch suite.
    static func forDefaults(_ defaults: UserDefaults) -> InputPreferences {
        defaults === AppEnvironment.defaults ? .shared : InputPreferences(defaults: defaults)
    }

    let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        relativeSensitivity = (defaults.object(forKey: Keys.relativeSensitivity) as? Double) ?? 1.0
        useUnacceleratedRelativeInput = defaults.bool(forKey: Keys.unacceleratedInput)
    }
}

// MARK: - Capture

/// Screenshots and recordings: what a recording keeps, its codec, where files go, and whether the
/// capture region's outline is drawn. The region itself is not here: it belongs to the window it was
/// drawn in and is never saved (`CaptureManager.captureRegion`).
@MainActor
final class CapturePreferences: ObservableObject {
    enum Keys {
        static let recordingMode = "overlook.capture.recordingMode"
        static let videoCodec = "overlook.capture.videoCodec"
        static let showsRegionOutline = "overlook.capture.showsRegionOutline"
        static var screenshotsFolder: String { CaptureManager.Folder.screenshots.defaultsKey }
        static var recordingsFolder: String { CaptureManager.Folder.recordings.defaultsKey }
    }

    @Published var recordingMode: RecordingMode {
        didSet { defaults.set(recordingMode.rawValue, forKey: Keys.recordingMode) }
    }
    @Published var videoCodec: RecordingVideoCodec {
        didSet { defaults.set(videoCodec.rawValue, forKey: Keys.videoCodec) }
    }
    @Published var screenshotsFolder: URL {
        didSet { defaults.set(screenshotsFolder.path, forKey: Keys.screenshotsFolder) }
    }
    @Published var recordingsFolder: URL {
        didSet { defaults.set(recordingsFolder.path, forKey: Keys.recordingsFolder) }
    }
    /// Whether the dashed outline of a set region is drawn over the video. Off hides the outline
    /// only; the region stays in effect.
    @Published var showsRegionOutline: Bool {
        didSet { defaults.set(showsRegionOutline, forKey: Keys.showsRegionOutline) }
    }

    /// The app's, on this Mac's own defaults (the test host's suite when hosting the tests).
    static let shared = CapturePreferences(defaults: AppEnvironment.defaults)

    /// The app's object for the app's defaults, or one of its own for a test's scratch suite.
    static func forDefaults(_ defaults: UserDefaults) -> CapturePreferences {
        defaults === AppEnvironment.defaults ? .shared : CapturePreferences(defaults: defaults)
    }

    let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        recordingMode = RecordingMode(rawValue: defaults.string(forKey: Keys.recordingMode) ?? "") ?? .videoAndAudio
        videoCodec = RecordingVideoCodec(rawValue: defaults.string(forKey: Keys.videoCodec) ?? "") ?? .h264
        screenshotsFolder = Self.storedFolder(.screenshots, in: defaults)
        recordingsFolder = Self.storedFolder(.recordings, in: defaults)
        showsRegionOutline = defaults.object(forKey: Keys.showsRegionOutline) as? Bool ?? true
    }

    func folderURL(_ folder: CaptureManager.Folder) -> URL {
        switch folder {
        case .screenshots: return screenshotsFolder
        case .recordings: return recordingsFolder
        }
    }

    func setFolder(_ folder: CaptureManager.Folder, to url: URL) {
        switch folder {
        case .screenshots: screenshotsFolder = url
        case .recordings: recordingsFolder = url
        }
    }

    func resetFolder(_ folder: CaptureManager.Folder) {
        setFolder(folder, to: folder.defaultURL)
    }

    /// Asks for a folder with an open panel and keeps it. Needs no window: the panel is app-modal.
    func chooseFolder(_ folder: CaptureManager.Folder) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose where Overlook saves \(folder.title.lowercased())."
        panel.directoryURL = folderURL(folder)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setFolder(folder, to: url)
    }

    /// Opens the folder in Finder, making it first if nothing has been saved there yet.
    func revealFolder(_ folder: CaptureManager.Folder) {
        let url = folderURL(folder)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    private static func storedFolder(_ folder: CaptureManager.Folder, in defaults: UserDefaults) -> URL {
        if let path = defaults.string(forKey: folder.defaultsKey), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return folder.defaultURL
    }
}

// MARK: - Connecting

/// What Overlook does as it connects.
@MainActor
final class ConnectionPreferences: ObservableObject {
    enum Keys {
        static let wakeDisplayOnConnect = "overlook.connection.wakeDisplayOnConnect"
    }

    /// Send one Shift tap (ShiftLeft down, then up) through the HID socket each time it comes up,
    /// so a target whose display has gone to sleep shows something. Off unless turned on.
    @Published var wakeDisplayOnConnect: Bool {
        didSet { defaults.set(wakeDisplayOnConnect, forKey: Keys.wakeDisplayOnConnect) }
    }

    /// The app's, on this Mac's own defaults (the test host's suite when hosting the tests).
    static let shared = ConnectionPreferences(defaults: AppEnvironment.defaults)

    /// The app's object for the app's defaults, or one of its own for a test's scratch suite.
    static func forDefaults(_ defaults: UserDefaults) -> ConnectionPreferences {
        defaults === AppEnvironment.defaults ? .shared : ConnectionPreferences(defaults: defaults)
    }

    let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        wakeDisplayOnConnect = defaults.bool(forKey: Keys.wakeDisplayOnConnect)
    }
}

// MARK: - Appearance

/// Light, dark, or following the system, for every Overlook window. Stored under
/// `overlook.appAppearance` with `@AppStorage`, as it always has been.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let key = "overlook.appAppearance"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// Applies a stored value to the whole app; anything unrecognised follows the system.
    @MainActor
    static func apply(_ stored: String) {
        switch AppAppearance(rawValue: stored) ?? .system {
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        case .system: NSApp.appearance = nil
        }
    }
}
