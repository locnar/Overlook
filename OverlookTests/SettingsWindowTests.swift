import AppKit
import Foundation
import Testing
@testable import Overlook

/// The split between the console's Settings panel, which keeps what is stored on the KVM, and the
/// Settings window (Overlook › Settings…), which keeps what is stored on this Mac.
@MainActor
@Suite("Settings window and panel")
struct SettingsWindowTests {
    let scratch = ScratchDefaults()

    // MARK: - The panel

    @Test func thePanelKeepsOnlyTheKVMsSections() {
        #expect(WebUISettingsPanel.PanelSection.allCases == [.video, .remote, .keyboard, .system, .network, .advanced])
        let titles = WebUISettingsPanel.PanelSection.allCases.map(\.title)
        #expect(titles == ["Video", "Remote device settings", "Keyboard settings", "System", "Network", "Advanced"])
        #expect(!titles.contains("Audio"))
        #expect(!titles.contains("Capture"))
    }

    @Test func thePanelNoLongerShowsThisMacsSettings() {
        let rows = WebUISettingsPanel.PanelSection.allCases.flatMap(\.rows)
        for moved in [
            "App appearance", "Local sensitivity", "Unaccelerated input (experimental)",
            "Video and audio addresses", "Audio", "Microphone", "Microphone device", "Output device",
            "Play audio from", "Video codec", "Screenshots", "Recordings",
        ] {
            #expect(!rows.contains(moved), "\(moved) is still in the panel")
        }
        #expect(WebUISettingsPanel.PanelSection.system.rows == ["Color mode", "Language", "Timezone"])
        #expect(WebUISettingsPanel.PanelSection.network.rows == ["Modify", "Wi-Fi", "Ethernet"])
    }

    // MARK: - The window's tabs

    @Test func theTabsAreInOrderWithTheirSymbols() {
        #expect(SettingsTab.allCases.map(\.title) == ["General", "Audio", "Capture", "Input", "Network"])
        #expect(SettingsTab.allCases.map(\.systemImage) == ["gearshape", "speaker.wave.2", "camera", "computermouse", "network"])
    }

    /// The keys are the ones these settings were stored under before they moved, so every value
    /// carries over as it was.
    @Test func eachTabsControlsUseTheKeysTheSettingsAlwaysHad() {
        #expect(SettingsTab.general.storedKeys == ["overlook.appAppearance", "overlook.connection.wakeDisplayOnConnect"])
        #expect(SettingsTab.audio.storedKeys == [
            "overlook.audio.enabled", "overlook.audio.playbackScope", "overlook.audio.micEnabled",
            "overlook.audio.inputDeviceUID", "overlook.audio.outputDeviceUID",
        ])
        #expect(SettingsTab.capture.storedKeys == [
            "overlook.capture.recordingMode", "overlook.capture.videoCodec",
            "overlook.capture.screenshotsFolder", "overlook.capture.recordingsFolder",
            "overlook.capture.showsRegionOutline",
        ])
        #expect(SettingsTab.input.storedKeys == ["overlook.relativeMouseSensitivity", "overlook.relativeMouseUnacceleratedInput"])
        #expect(SettingsTab.network.storedKeys == ["overlook.network.mediaAddresses"])
    }

    /// Each tab binds to its area's settings object; a change through it lands on the tab's keys.
    @Test func changesThroughEachTabsSettingsObjectLandOnItsKeys() {
        let defaults = scratch.defaults

        let audio = AudioPreferences(defaults: defaults)
        audio.audioEnabled = true
        audio.playbackScope = .allWindows
        audio.micEnabled = true
        audio.inputDeviceUID = "mic-uid"
        audio.outputDeviceUID = "speaker-uid"

        let capture = CapturePreferences(defaults: defaults)
        capture.recordingMode = .videoOnly
        capture.videoCodec = .hevc
        capture.setFolder(.screenshots, to: URL(fileURLWithPath: "/tmp/shots", isDirectory: true))
        capture.setFolder(.recordings, to: URL(fileURLWithPath: "/tmp/movies", isDirectory: true))
        capture.showsRegionOutline = false

        let input = InputPreferences(defaults: defaults)
        input.relativeSensitivity = 1.75
        input.useUnacceleratedRelativeInput = true

        let network = NetworkPreferences(defaults: defaults)
        network.mediaAddresses = .all

        for tab in [SettingsTab.audio, .capture, .input, .network] {
            for key in tab.storedKeys {
                #expect(defaults.object(forKey: key) != nil, "\(tab.title): nothing stored under \(key)")
            }
        }
        #expect(defaults.string(forKey: "overlook.audio.playbackScope") == "allWindows")
        #expect(defaults.string(forKey: "overlook.network.mediaAddresses") == "all")
        #expect(defaults.double(forKey: "overlook.relativeMouseSensitivity") == 1.75)
    }

    @Test func theWindowUsesTheAppsSharedSettingsObjects() {
        let view = OverlookSettingsView(registry: nil)
        #expect(view.audio === AudioPreferences.shared)
        #expect(view.capture === CapturePreferences.shared)
        #expect(view.input === InputPreferences.shared)
        #expect(view.network === NetworkPreferences.shared)
        #expect(view.connection === ConnectionPreferences.shared)
    }

    @Test func theTestHostHasNoSettingsWindowOpen() {
        let settingsWindows = NSApp.windows.filter {
            $0.isVisible && ($0.identifier?.rawValue.localizedCaseInsensitiveContains("settings") ?? false)
        }
        #expect(settingsWindows.isEmpty)
    }

    // MARK: - Shortcuts

    @Test func theShortcutListNamesEveryChordOverlookKeeps() {
        let keys = OverlookShortcut.all.map(\.keys)
        #expect(keys.prefix(4) == ["⇧⌘C", "⇧⌘V", "⇧⌘S", "⇧⌘R"])
        for chord in InputManager.InterceptedChord.allCases {
            #expect(keys.contains(chord.keysText))
        }
        #expect(OverlookShortcut.all.first?.action == "Toggle OCR selection")
        #expect(OverlookShortcut.all[1].action == "Paste the Mac clipboard to the target")
        #expect(keys.last == "⌃⌥")
        #expect(Set(keys).count == keys.count)
        #expect(OverlookShortcut.all.contains(OverlookShortcut(keys: "⇧⌘T", action: "Copy text from an area of the screen")))
    }

    // MARK: - What the window knows about the console windows

    @Test func theWindowFollowsWhichConsoleWindowsAreConnected() async {
        let catalog = KVMDeviceManager(
            defaults: scratch.defaults,
            credentials: FakeCredentialStore(),
            trustStore: Fixtures.trustStore(scratch)
        )
        let scratch = self.scratch
        let registry = SessionRegistry(catalog: catalog) { catalog in
            ConsoleSession(
                catalog: catalog,
                defaults: scratch.defaults,
                link: RecordingSessionLink(catalog: catalog),
                audioPreferences: AudioPreferences(defaults: scratch.defaults),
                connectionLog: .inMemory()
            )
        }
        let model = SettingsSessionsModel(registry: registry)
        #expect(model.connectedCount == 0)

        let first = registry.sessionForNewWindow()
        registry.add(first)
        let second = registry.sessionForNewWindow()
        registry.add(second)

        first.connection.connectedDevice = Fixtures.device(id: "one", host: "192.0.2.11")
        #expect(await waitUntil { model.connectedCount == 1 })

        second.connection.connectedDevice = Fixtures.device(id: "two", host: "192.0.2.12")
        #expect(await waitUntil { model.connectedCount == 2 })

        first.connection.disconnectFromDevice()
        #expect(await waitUntil { model.connectedCount == 1 })
    }
}
