import Combine
import Foundation
import Testing
@testable import Overlook

/// The settings kept on this Mac (`InputPreferences`, `CapturePreferences`): one object for every
/// window and for the Settings window, stored under the keys these settings always had, and read
/// live by every session's input and capture managers.
@MainActor
@Suite("Mac preferences")
struct MacPreferencesTests {
    let scratch = ScratchDefaults()
    let catalog: KVMDeviceManager

    init() {
        catalog = KVMDeviceManager(
            defaults: scratch.defaults,
            credentials: FakeCredentialStore(),
            trustStore: Fixtures.trustStore(scratch)
        )
    }

    private func makeSession(
        input: InputPreferences? = nil,
        capture: CapturePreferences? = nil
    ) -> ConsoleSession {
        ConsoleSession(
            catalog: catalog,
            defaults: scratch.defaults,
            link: RecordingSessionLink(),
            audioPreferences: AudioPreferences(defaults: scratch.defaults),
            inputPreferences: input,
            capturePreferences: capture,
            connectionLog: .inMemory()
        )
    }

    // MARK: - Where the app's objects keep their values

    @Test func theAppsObjectsUseTheTestHostsThrowawayDefaults() {
        #expect(AppEnvironment.isHostingTests)
        #expect(AppEnvironment.defaults !== UserDefaults.standard)
        #expect(InputPreferences.shared.defaults === AppEnvironment.defaults)
        #expect(CapturePreferences.shared.defaults === AppEnvironment.defaults)
    }

    @Test func theAppsDefaultsGetTheSharedObjectsAndAScratchSuiteGetsItsOwn() {
        #expect(InputPreferences.forDefaults(AppEnvironment.defaults) === InputPreferences.shared)
        #expect(CapturePreferences.forDefaults(AppEnvironment.defaults) === CapturePreferences.shared)

        let input = InputPreferences.forDefaults(scratch.defaults)
        let capture = CapturePreferences.forDefaults(scratch.defaults)
        #expect(input !== InputPreferences.shared)
        #expect(capture !== CapturePreferences.shared)
        #expect(input.defaults === scratch.defaults)
        #expect(capture.defaults === scratch.defaults)
    }

    // MARK: - Input

    @Test func inputSettingsKeepTheirKeys() {
        #expect(InputPreferences.Keys.relativeSensitivity == "overlook.relativeMouseSensitivity")
        #expect(InputPreferences.Keys.unacceleratedInput == "overlook.relativeMouseUnacceleratedInput")
    }

    @Test func inputSettingsReadWhatWasStoredBefore() {
        scratch.defaults.set(2.25, forKey: "overlook.relativeMouseSensitivity")
        scratch.defaults.set(true, forKey: "overlook.relativeMouseUnacceleratedInput")

        let preferences = InputPreferences(defaults: scratch.defaults)
        #expect(preferences.relativeSensitivity == 2.25)
        #expect(preferences.useUnacceleratedRelativeInput)
    }

    @Test func inputSettingsDefaultAndWriteThroughToTheirKeys() {
        let preferences = InputPreferences(defaults: scratch.defaults)
        #expect(preferences.relativeSensitivity == 1.0)
        #expect(preferences.useUnacceleratedRelativeInput == false)

        preferences.relativeSensitivity = 0.75
        preferences.useUnacceleratedRelativeInput = true
        #expect(scratch.defaults.double(forKey: "overlook.relativeMouseSensitivity") == 0.75)
        #expect(scratch.defaults.bool(forKey: "overlook.relativeMouseUnacceleratedInput"))
    }

    @Test func changingSensitivityInTheSharedObjectReachesEveryOpenSession() {
        let preferences = InputPreferences(defaults: scratch.defaults)
        let first = makeSession(input: preferences)
        let second = makeSession(input: preferences)

        // What Settings › Input does.
        preferences.relativeSensitivity = 2.5
        preferences.useUnacceleratedRelativeInput = true

        #expect(first.inputManager.relativeSensitivity == 2.5)
        #expect(second.inputManager.relativeSensitivity == 2.5)
        #expect(first.inputManager.useUnacceleratedRelativeInput)
        #expect(second.inputManager.useUnacceleratedRelativeInput)
    }

    @Test func aChangeThroughOneSessionIsSeenByTheOthersAndBySettings() {
        let preferences = InputPreferences(defaults: scratch.defaults)
        let first = makeSession(input: preferences)
        let second = makeSession(input: preferences)

        first.inputManager.relativeSensitivity = 0.5
        #expect(second.inputManager.relativeSensitivity == 0.5)
        #expect(preferences.relativeSensitivity == 0.5)
        #expect(scratch.defaults.double(forKey: "overlook.relativeMouseSensitivity") == 0.5)
    }

    // MARK: - Capture

    @Test func captureSettingsKeepTheirKeys() {
        #expect(CapturePreferences.Keys.recordingMode == "overlook.capture.recordingMode")
        #expect(CapturePreferences.Keys.videoCodec == "overlook.capture.videoCodec")
        #expect(CapturePreferences.Keys.showsRegionOutline == "overlook.capture.showsRegionOutline")
        #expect(CapturePreferences.Keys.screenshotsFolder == "overlook.capture.screenshotsFolder")
        #expect(CapturePreferences.Keys.recordingsFolder == "overlook.capture.recordingsFolder")
    }

    @Test func captureSettingsWriteThroughToTheirKeysWithNoSessionAtAll() {
        let preferences = CapturePreferences(defaults: scratch.defaults)
        preferences.recordingMode = .audioOnly
        preferences.videoCodec = .hevc
        preferences.showsRegionOutline = false
        preferences.setFolder(.recordings, to: URL(fileURLWithPath: "/tmp/overlook-movies", isDirectory: true))

        #expect(scratch.defaults.string(forKey: "overlook.capture.recordingMode") == "audioOnly")
        #expect(scratch.defaults.string(forKey: "overlook.capture.videoCodec") == "hevc")
        #expect(scratch.defaults.object(forKey: "overlook.capture.showsRegionOutline") as? Bool == false)
        #expect(scratch.defaults.string(forKey: "overlook.capture.recordingsFolder") == "/tmp/overlook-movies")

        preferences.resetFolder(.recordings)
        #expect(preferences.recordingsFolder == CaptureManager.Folder.recordings.defaultURL)
    }

    @Test func aCaptureChangeInSettingsReachesEveryOpenSession() {
        let preferences = CapturePreferences(defaults: scratch.defaults)
        let first = makeSession(capture: preferences)
        let second = makeSession(capture: preferences)

        preferences.videoCodec = .hevc
        preferences.recordingMode = .videoOnly
        preferences.showsRegionOutline = false

        for session in [first, second] {
            #expect(session.captureManager.videoCodec == .hevc)
            #expect(session.captureManager.recordingMode == .videoOnly)
            #expect(session.captureManager.showsRegionOutline == false)
        }

        // The toolbar's Record pop-up in one window changes it for the other, and for Settings.
        first.captureManager.recordingMode = .audioOnly
        #expect(second.captureManager.recordingMode == .audioOnly)
        #expect(preferences.recordingMode == .audioOnly)
    }

    @Test func aCaptureManagerTellsItsWindowWhenSettingsChange() {
        let preferences = CapturePreferences(defaults: scratch.defaults)
        let session = makeSession(capture: preferences)
        var changes = 0
        let watch = session.captureManager.objectWillChange.sink { changes += 1 }
        defer { watch.cancel() }

        preferences.showsRegionOutline.toggle()
        #expect(changes > 0)
    }
}
