import SwiftUI
import AppKit
import Combine

// Overlook › Settings… (⌘,): the settings kept on this Mac, in a standard macOS Settings window
// with toolbar tabs. The console's Settings panel keeps only what is stored on the KVM itself, and
// links here. Every control binds to the app's shared settings object for its area (`.shared`),
// stored under the key that setting has always had, so it works with no console window open and a
// change applies to every window.

// MARK: - Tabs

/// The Settings window's tabs, in toolbar order.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case audio
    case capture
    case input
    case network

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .audio: return "Audio"
        case .capture: return "Capture"
        case .input: return "Input"
        case .network: return "Network"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .audio: return "speaker.wave.2"
        case .capture: return "camera"
        case .input: return "computermouse"
        case .network: return "network"
        }
    }

    /// The keys the tab's controls read and write, in the order the controls appear.
    var storedKeys: [String] {
        switch self {
        case .general:
            return [AppAppearance.key, ConnectionPreferences.Keys.wakeDisplayOnConnect]
        case .audio:
            return [
                AudioPreferences.Keys.audioEnabled,
                AudioPreferences.Keys.playbackScope,
                AudioPreferences.Keys.micEnabled,
                AudioPreferences.Keys.inputDeviceUID,
                AudioPreferences.Keys.outputDeviceUID,
            ]
        case .capture:
            return [
                CapturePreferences.Keys.recordingMode,
                CapturePreferences.Keys.videoCodec,
                CapturePreferences.Keys.screenshotsFolder,
                CapturePreferences.Keys.recordingsFolder,
                CapturePreferences.Keys.showsRegionOutline,
            ]
        case .input:
            return [InputPreferences.Keys.relativeSensitivity, InputPreferences.Keys.unacceleratedInput]
        case .network:
            return [NetworkPreferences.Keys.mediaAddresses]
        }
    }
}

// MARK: - What the open windows are doing

/// What the Settings window needs to know about the console windows: whether any is connected,
/// which "Video and audio addresses" choice each connected one was made with, and whether macOS
/// refused one the microphone. Follows the registry's sessions as windows open and close.
@MainActor
final class SettingsSessionsModel: ObservableObject {
    @Published private(set) var connectedCount = 0
    /// The "Video and audio addresses" choice each connected window connected with.
    @Published private(set) var mediaAddressesInEffect: [MediaAddresses] = []
    @Published private(set) var isMicrophoneAccessDenied = false

    private weak var registry: SessionRegistry?
    private var registryWatch: AnyCancellable?
    private var sessionWatch: AnyCancellable?

    init(registry: SessionRegistry?) {
        self.registry = registry
        // `@Published` fires before the value changes; read the registry back a turn later.
        registryWatch = registry?.$sessions
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.watchSessions() }
        refresh()
    }

    private func watchSessions() {
        let sessions = registry?.sessions ?? []
        let changes: [AnyPublisher<Void, Never>] = sessions.flatMap { session in
            [
                session.connection.$connectedDevice.map { _ in () }.eraseToAnyPublisher(),
                session.webRTCManager.$mediaAddressesInEffect.map { _ in () }.eraseToAnyPublisher(),
                session.webRTCManager.$isMicrophoneAccessDenied.map { _ in () }.eraseToAnyPublisher(),
            ]
        }
        sessionWatch = Publishers.MergeMany(changes)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.refresh() }
        refresh()
    }

    func refresh() {
        let sessions = registry?.sessions ?? []
        let connected = sessions.filter { $0.connection.connectedDevice != nil }
        connectedCount = connected.count
        mediaAddressesInEffect = connected.compactMap { $0.webRTCManager.mediaAddressesInEffect }
        isMicrophoneAccessDenied = sessions.contains { $0.webRTCManager.isMicrophoneAccessDenied }
    }

    /// Reconnects the stream of every connected window, so new audio settings take effect.
    func reconnectConnectedWindows() async {
        for session in registry?.sessions ?? [] {
            guard let device = session.connection.connectedDevice else { continue }
            await session.webRTCManager.reconnect(to: device, reason: "Audio settings changed")
        }
    }
}

// MARK: - The window

struct OverlookSettingsView: View {
    let audio: AudioPreferences
    let capture: CapturePreferences
    let input: InputPreferences
    let network: NetworkPreferences
    let connection: ConnectionPreferences
    @StateObject private var sessions: SettingsSessionsModel
    @StateObject private var paneHeights = SettingsPaneHeights()

    @State private var selectedTab: SettingsTab = .general

    /// The app's shared settings objects unless a caller hands others.
    init(
        registry: SessionRegistry?,
        audio: AudioPreferences? = nil,
        capture: CapturePreferences? = nil,
        input: InputPreferences? = nil,
        network: NetworkPreferences? = nil,
        connection: ConnectionPreferences? = nil
    ) {
        self.audio = audio ?? .shared
        self.capture = capture ?? .shared
        self.input = input ?? .shared
        self.network = network ?? .shared
        self.connection = connection ?? .shared
        _sessions = StateObject(wrappedValue: SettingsSessionsModel(registry: registry))
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            ForEach(SettingsTab.allCases) { tab in
                pane(for: tab)
                    .tabItem { Label(tab.title, systemImage: tab.systemImage) }
                    .tag(tab)
            }
        }
        .environmentObject(paneHeights)
    }

    @ViewBuilder
    private func pane(for tab: SettingsTab) -> some View {
        switch tab {
        case .general:
            GeneralSettingsPane(connection: connection)
        case .audio:
            AudioSettingsPane(preferences: audio, sessions: sessions)
        case .capture:
            CaptureSettingsPane(preferences: capture)
        case .input:
            InputSettingsPane(preferences: input)
        case .network:
            NetworkSettingsPane(preferences: network, sessions: sessions)
        }
    }
}

/// How tall each tab's form is, as measured while the window is open, so a tab comes back at its
/// own height when it's chosen again.
@MainActor
final class SettingsPaneHeights: ObservableObject {
    @Published private(set) var heights: [SettingsTab: CGFloat] = [:]

    /// A shrink smaller than this is ignored. While the window resizes, a grouped form's content
    /// height moves by a few points as the toolbar's inset comes and goes; following those would
    /// resize the window again, and again. Rows and captions that come and go are taller than this.
    static let shrinkThreshold: CGFloat = 12

    /// The height a pane takes after measuring `contentHeight`, given the height it has now, or
    /// nil to keep the one it has: it grows at once, and shrinks only past `shrinkThreshold`.
    static func height(afterMeasuring contentHeight: CGFloat, current: CGFloat?) -> CGFloat? {
        guard contentHeight > 0 else { return nil }
        let measured = contentHeight.rounded(.up)
        guard let current else { return measured }
        if measured > current || measured < current - shrinkThreshold {
            return measured
        }
        return nil
    }

    func record(contentHeight: CGFloat, for tab: SettingsTab) {
        if let height = Self.height(afterMeasuring: contentHeight, current: heights[tab]) {
            heights[tab] = height
        }
    }
}

/// One tab's content: a grouped form of a fixed width, as macOS's own Settings windows have, as
/// tall as its rows, so it doesn't scroll. On macOS 15 and later the form's content is measured,
/// so the pane follows rows and captions that come and go, long device names and the text size.
/// macOS 14 can't measure it; there the pane takes `fallbackHeight`, which is also its height
/// until the first measurement arrives. Each tab's fallback is what it measured on a current
/// macOS at the default text size in its tallest state, plus some room; macOS 14's rows are
/// shorter.
private struct SettingsPane<Content: View>: View {
    let tab: SettingsTab
    let fallbackHeight: CGFloat
    @ViewBuilder let content: Content

    @EnvironmentObject private var heights: SettingsPaneHeights

    var body: some View {
        if #available(macOS 15, *) {
            form
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    // The content alone: the top inset is the toolbar, which the form runs
                    // under, and isn't part of the pane's frame.
                    geometry.contentSize.height
                } action: { _, contentHeight in
                    heights.record(contentHeight: contentHeight, for: tab)
                }
                .frame(width: 520, height: heights.heights[tab] ?? fallbackHeight)
        } else {
            form
                .frame(width: 520, height: fallbackHeight)
        }
    }

    private var form: some View {
        Form {
            content
        }
        .formStyle(.grouped)
    }
}

/// Grey explanatory text under a control.
private struct SettingsCaption: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - General

private struct GeneralSettingsPane: View {
    @ObservedObject var connection: ConnectionPreferences
    @AppStorage(AppAppearance.key) private var appAppearance: String = AppAppearance.system.rawValue

    var body: some View {
        SettingsPane(tab: .general, fallbackHeight: 180) {
            Section {
                Picker("App appearance", selection: $appAppearance) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.title).tag(appearance.rawValue)
                    }
                }
                .onChange(of: appAppearance) { _, newValue in
                    // Console windows apply it too; this covers having none open.
                    AppAppearance.apply(newValue)
                }
            }

            Section {
                Toggle("Wake the target's display when connecting", isOn: $connection.wakeDisplayOnConnect)
                    .help("After each connect, and each automatic reconnect of the keyboard and mouse link, Overlook presses and releases Shift on the target once. Not sent when Keyboard Control is off on the device.")
            } footer: {
                SettingsCaption("Sends one Shift key press after each connect. Off by default.")
            }
        }
    }
}

// MARK: - Audio

private struct AudioSettingsPane: View {
    @ObservedObject var preferences: AudioPreferences
    @ObservedObject var sessions: SettingsSessionsModel

    @State private var inputDevices: [CoreAudioDeviceInfo] = []
    @State private var outputDevices: [CoreAudioDeviceInfo] = []
    @State private var isReconnecting = false

    var body: some View {
        SettingsPane(tab: .audio, fallbackHeight: AudioSettingsPane.fallbackHeight(
            connected: sessions.connectedCount > 0,
            microphoneDenied: sessions.isMicrophoneAccessDenied
        )) {
            Section {
                Toggle("Audio", isOn: $preferences.audioEnabled)
                    .help("Play the target's audio. Takes effect on the next connect.")
                Picker("Play audio from", selection: $preferences.playbackScope) {
                    ForEach(AudioPreferences.PlaybackScope.allCases) { scope in
                        Text(scope.title).tag(scope)
                    }
                }
                .help("Applies to every window, at once. With \"Active window only\", the other windows stay connected and keep recording their audio; only this Mac's speakers skip them.")
            }

            Section {
                Toggle("Microphone", isOn: $preferences.micEnabled)
                    .help("Send this Mac's microphone to the target as its USB microphone. The device carries it on the audio session, so this also opens audio; playback stays muted while Audio is off. Takes effect on the next connect. Only the active window sends it; the others send silence.")
                if sessions.isMicrophoneAccessDenied {
                    Text("macOS refused microphone access. Allow Overlook under System Settings › Privacy & Security › Microphone, then reconnect.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Picker("Microphone device", selection: $preferences.inputDeviceUID) {
                    Text("System Default").tag("")
                    if !preferences.inputDeviceUID.isEmpty,
                       inputDevices.contains(where: { $0.uid == preferences.inputDeviceUID }) == false {
                        Text("Unavailable").tag(preferences.inputDeviceUID)
                    }
                    ForEach(inputDevices, id: \.uid) { device in
                        Text(device.name).tag(device.uid)
                    }
                }

                Picker("Output device", selection: $preferences.outputDeviceUID) {
                    Text("System Default").tag("")
                    if !preferences.outputDeviceUID.isEmpty,
                       outputDevices.contains(where: { $0.uid == preferences.outputDeviceUID }) == false {
                        Text("Unavailable").tag(preferences.outputDeviceUID)
                    }
                    ForEach(outputDevices, id: \.uid) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
            } footer: {
                SettingsCaption("Audio, Microphone and the two devices take effect the next time a window connects. Play audio from applies at once.")
            }

            if sessions.connectedCount > 0 {
                Section {
                    HStack {
                        Text("Reconnect required")
                        Spacer()
                        Button(sessions.connectedCount == 1 ? "Reconnect Window" : "Reconnect \(sessions.connectedCount) Windows") {
                            isReconnecting = true
                            Task {
                                await sessions.reconnectConnectedWindows()
                                isReconnecting = false
                            }
                        }
                        .disabled(isReconnecting)
                    }
                } footer: {
                    SettingsCaption("Windows already connected keep the audio they connected with until they reconnect.")
                }
            }
        }
        .onAppear(perform: refreshDevices)
    }

    /// The height on macOS 14, where the form can't be measured: room for every row this state
    /// shows, with some to spare.
    static func fallbackHeight(connected: Bool, microphoneDenied: Bool) -> CGFloat {
        310 + (connected ? 90 : 0) + (microphoneDenied ? 50 : 0)
    }

    private func refreshDevices() {
        inputDevices = CoreAudioDevices.listInputDevices()
        outputDevices = CoreAudioDevices.listOutputDevices()
    }
}

// MARK: - Capture

private struct CaptureSettingsPane: View {
    @ObservedObject var preferences: CapturePreferences

    var body: some View {
        SettingsPane(tab: .capture, fallbackHeight: 340) {
            Section {
                Picker("Record", selection: $preferences.recordingMode) {
                    ForEach(RecordingMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .help("What the next recording keeps.")
                Picker("Video codec", selection: $preferences.videoCodec) {
                    ForEach(RecordingVideoCodec.allCases) { codec in
                        Text(codec.title).tag(codec)
                    }
                }
                .help("Applies to the next recording. Audio is always AAC.")
            }

            Section {
                CaptureFolderRow(preferences: preferences, folder: .screenshots)
                CaptureFolderRow(preferences: preferences, folder: .recordings)
            }

            Section {
                Toggle("Outline the capture region on the video", isOn: $preferences.showsRegionOutline)
                    .help("Off hides the dashed outline only; the region stays in effect")
            } footer: {
                SettingsCaption("⇧⌘S saves a screenshot; ⇧⌘R starts and stops a recording. Both work while keys are being sent to the target, so the target never sees them. A capture region, chosen from the toolbar or Capture › Select Capture Region…, limits both to part of the screen until it is turned off or Overlook quits.")
            }
        }
    }
}

/// One folder: its name, the current path (click to open it in Finder), Choose…, and back to the
/// default.
private struct CaptureFolderRow: View {
    @ObservedObject var preferences: CapturePreferences
    let folder: CaptureManager.Folder

    var body: some View {
        let url = preferences.folderURL(folder)
        LabeledContent(folder.title) {
            HStack(spacing: 6) {
                Button(action: { preferences.revealFolder(folder) }) {
                    Text(CaptureManager.displayPath(url))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.plain)
                .help("Open \(url.path) in Finder")

                Button("Choose…") {
                    preferences.chooseFolder(folder)
                }
                .controlSize(.small)

                Button(action: { preferences.resetFolder(folder) }) {
                    Image(systemName: "arrow.counterclockwise")
                }
                .controlSize(.small)
                .disabled(url.standardizedFileURL == folder.defaultURL.standardizedFileURL)
                .help("Use the default folder, \(CaptureManager.displayPath(folder.defaultURL))")
            }
        }
    }
}

// MARK: - Input

/// Overlook's own keyboard shortcuts, for the read-only list in Settings › Input.
struct OverlookShortcut: Identifiable, Equatable {
    let keys: String
    let action: String

    var id: String { keys }

    /// The chords keyboard capture keeps for Overlook (`InputManager.InterceptedChord`), then the
    /// chord that releases a captured pointer.
    static let all: [OverlookShortcut] = InputManager.InterceptedChord.allCases.map {
        OverlookShortcut(keys: $0.keysText, action: $0.actionTitle)
    } + [
        OverlookShortcut(keys: "⌃⌥", action: "Release the captured pointer (relative mode)"),
    ]
}

extension InputManager.InterceptedChord {
    /// How the chord is written in menus: "⇧⌘C".
    var keysText: String {
        switch self {
        case .copyMode: return "⇧⌘C"
        case .paste: return "⇧⌘V"
        case .saveScreenshot: return "⇧⌘S"
        case .toggleRecording: return "⇧⌘R"
        case .copyTextFromArea: return "⇧⌘T"
        case .quit: return "⌘Q"
        }
    }

    /// What the chord does, for Settings › Input.
    var actionTitle: String {
        switch self {
        case .copyMode: return "Toggle OCR selection"
        case .paste: return "Paste the Mac clipboard to the target"
        case .saveScreenshot: return "Save a screenshot"
        case .toggleRecording: return "Start or stop a recording"
        case .copyTextFromArea: return "Copy text from an area of the screen"
        case .quit: return "Quit Overlook"
        }
    }
}

private struct InputSettingsPane: View {
    @ObservedObject var preferences: InputPreferences

    var body: some View {
        SettingsPane(tab: .input, fallbackHeight: 550) {
            Section {
                LabeledContent("Local sensitivity") {
                    HStack {
                        Slider(
                            value: $preferences.relativeSensitivity,
                            in: InputPreferences.sensitivityRange,
                            step: InputPreferences.sensitivityStep
                        )
                        .labelsHidden()
                        .frame(width: 200)
                        Text(String(format: "%.2f×", preferences.relativeSensitivity))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 48, alignment: .trailing)
                    }
                }
                .help("Multiplier on mouse movement while the pointer is captured. At 1.00× the remote cursor travels the same on-screen distance your local cursor would have — or, with unaccelerated input on, the target receives your mouse's raw counts unchanged.")

                Toggle("Unaccelerated input (experimental)", isOn: $preferences.useUnacceleratedRelativeInput)
                    .help("Send the mouse's raw movement counts instead of macOS-accelerated movement, so the target applies its own pointer settings once, as with a directly attached mouse. Falls back to accelerated movement when the system does not provide counts. Expect to re-tune sensitivity.")
            } header: {
                Text("Relative mode on this Mac")
            } footer: {
                SettingsCaption("Applies at once in every window. Click the video to capture the pointer; press ⌃⌥ to release it.")
            }

            Section {
                ForEach(OverlookShortcut.all) { shortcut in
                    LabeledContent(shortcut.action) {
                        Text(shortcut.keys)
                            .monospaced()
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Overlook's shortcuts")
            } footer: {
                SettingsCaption("These stay with Overlook while keys are being sent to the target, so the target never receives them. Every other shortcut, ⌘C and ⌘V included, goes to the target then.")
            }
        }
    }
}

// MARK: - Network

/// The lines under the "Video and audio addresses" pop-up.
enum MediaAddressesCaption {
    /// What each choice does and, when a connected window was made with a different choice than
    /// the one selected, when the selected one applies. `inEffect` holds the choice each connected
    /// window connected with.
    static func lines(selected: MediaAddresses, inEffect: [MediaAddresses]) -> [String] {
        var lines = [
            "Chosen network only: video and audio use the same network as the address you connected through (LAN or Tailscale).",
            "All addresses: the KVM may pick any network both sides share.",
        ]
        if inEffect.contains(where: { $0 != selected }) {
            lines.append("Takes effect the next time you connect.")
        }
        return lines
    }
}

private struct NetworkSettingsPane: View {
    @ObservedObject var preferences: NetworkPreferences
    @ObservedObject var sessions: SettingsSessionsModel

    var body: some View {
        SettingsPane(tab: .network, fallbackHeight: 170) {
            Section {
                Picker("Video and audio addresses", selection: $preferences.mediaAddresses) {
                    ForEach(MediaAddresses.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(
                        MediaAddressesCaption.lines(selected: preferences.mediaAddresses, inEffect: sessions.mediaAddressesInEffect),
                        id: \.self
                    ) { line in
                        SettingsCaption(line)
                    }
                }
            }
        }
    }
}
