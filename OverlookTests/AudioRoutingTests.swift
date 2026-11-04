import AudioUnit
import Foundation
import Testing
@testable import Overlook

/// Which windows play their audio and which one has the microphone, and the audio settings every
/// window shares. Sessions are never connected here: the route is decided and applied to each
/// session's audio device whether or not a stream is up, and the settings live in a scratch suite.
@MainActor
@Suite("Audio routing")
struct AudioRoutingTests {
    let scratch = ScratchDefaults()
    let catalog: KVMDeviceManager
    let preferences: AudioPreferences
    let registry: SessionRegistry
    let router: SessionAudioRouter
    /// Each session's recording link, in the order the sessions were made.
    private let links = LinkBox()

    final class LinkBox {
        var all: [RecordingSessionLink] = []
    }

    init() {
        let catalog = KVMDeviceManager(
            defaults: scratch.defaults,
            credentials: FakeCredentialStore(),
            trustStore: Fixtures.trustStore(scratch)
        )
        self.catalog = catalog
        let preferences = AudioPreferences(defaults: scratch.defaults)
        self.preferences = preferences
        let scratch = self.scratch
        let links = self.links
        registry = SessionRegistry(catalog: catalog) { catalog in
            let link = RecordingSessionLink(catalog: catalog)
            links.all.append(link)
            return ConsoleSession(
                catalog: catalog,
                defaults: scratch.defaults,
                link: link,
                audioPreferences: preferences
            )
        }
        router = SessionAudioRouter(registry: registry, preferences: preferences)
    }

    /// A session whose window has appeared.
    private func openWindow() -> ConsoleSession {
        let session = registry.sessionForNewWindow()
        registry.add(session)
        return session
    }

    private func plays(_ session: ConsoleSession) -> Bool {
        // Both the decision and the audio device it was applied to.
        let route = session.webRTCManager.audioRoute.playsAudio
        #expect(session.webRTCManager.isPlaybackMuted == !route)
        return route
    }

    // MARK: - The rule

    @Test func aSessionPlaysWhenEveryWindowDoesOrWhenItIsActive() {
        #expect(AudioRoute.forSession(isActive: true, scope: .activeWindow) == AudioRoute(playsAudio: true, sendsMicrophone: true))
        #expect(AudioRoute.forSession(isActive: false, scope: .activeWindow) == AudioRoute(playsAudio: false, sendsMicrophone: false))
        #expect(AudioRoute.forSession(isActive: true, scope: .allWindows) == AudioRoute(playsAudio: true, sendsMicrophone: true))
        // Every window plays, but the microphone still goes to one target only.
        #expect(AudioRoute.forSession(isActive: false, scope: .allWindows) == AudioRoute(playsAudio: true, sendsMicrophone: false))
    }

    @Test func onlyTheActiveWindowPlaysByDefault() {
        #expect(preferences.playbackScope == .activeWindow)
        let a = openWindow()
        let b = openWindow()
        #expect(plays(a))
        #expect(!plays(b))

        registry.sessionDidBecomeKey(b)
        #expect(!plays(a))
        #expect(plays(b))
    }

    @Test func playingFromAllWindowsTakesEffectAtOnceWithoutReconnecting() async {
        let a = openWindow()
        let b = openWindow()
        _ = await b.connect(to: Fixtures.device(name: "Rack 7", host: "192.0.2.70"))
        let bLink = links.all[1]
        let stepsBefore = bLink.steps

        preferences.playbackScope = .allWindows
        #expect(plays(a))
        #expect(plays(b))

        preferences.playbackScope = .activeWindow
        #expect(plays(a))
        #expect(!plays(b))
        // Muted, not disconnected: nothing was hung up or brought up again.
        #expect(b.connection.connectedDevice?.host == "192.0.2.70")
        #expect(bLink.steps == stepsBefore)
    }

    @Test func theMicrophoneFollowsTheActiveSession() {
        preferences.playbackScope = .allWindows
        let a = openWindow()
        let b = openWindow()
        #expect(a.webRTCManager.audioRoute.sendsMicrophone)
        #expect(!b.webRTCManager.audioRoute.sendsMicrophone)

        registry.sessionDidBecomeKey(b)
        #expect(!a.webRTCManager.audioRoute.sendsMicrophone)
        #expect(b.webRTCManager.audioRoute.sendsMicrophone)

        // Closing the active window hands the microphone back to the one used before it.
        registry.sessionDidBecomeKey(a)
        registry.sessionDidBecomeKey(b)
        registry.remove(b)
        #expect(a.webRTCManager.audioRoute.sendsMicrophone)
        #expect(plays(a))
    }

    // MARK: - Shared settings

    @Test func everySessionSeesOneSetOfAudioSettings() {
        let a = openWindow()
        let b = openWindow()

        preferences.audioEnabled = true
        preferences.micEnabled = true
        preferences.outputDeviceUID = "BuiltInSpeakerDevice"
        #expect(a.webRTCManager.audioEnabled && b.webRTCManager.audioEnabled)
        #expect(a.webRTCManager.micEnabled && b.webRTCManager.micEnabled)
        #expect(a.webRTCManager.audioPreferences === b.webRTCManager.audioPreferences)

        preferences.audioEnabled = false
        #expect(!a.webRTCManager.audioEnabled && !b.webRTCManager.audioEnabled)
    }

    @Test func theSettingsKeepTheirDefaultsKeys() {
        preferences.audioEnabled = true
        preferences.micEnabled = true
        preferences.inputDeviceUID = "mic-uid"
        preferences.outputDeviceUID = "speaker-uid"
        preferences.playbackScope = .allWindows

        // The keys these settings have always been stored under, spelled out.
        let defaults = scratch.defaults
        #expect(defaults.bool(forKey: "overlook.audio.enabled"))
        #expect(defaults.bool(forKey: "overlook.audio.micEnabled"))
        #expect(defaults.string(forKey: "overlook.audio.inputDeviceUID") == "mic-uid")
        #expect(defaults.string(forKey: "overlook.audio.outputDeviceUID") == "speaker-uid")
        #expect(defaults.string(forKey: "overlook.audio.playbackScope") == "allWindows")

        let reloaded = AudioPreferences(defaults: defaults)
        #expect(reloaded.audioEnabled && reloaded.micEnabled)
        #expect(reloaded.inputDeviceUID == "mic-uid")
        #expect(reloaded.outputDeviceUID == "speaker-uid")
        #expect(reloaded.playbackScope == .allWindows)
    }

    // MARK: - Muting after the recording tap

    @Test func aMutedWindowStillHandsItsAudioToTheRecordingTap() {
        let samples = 8
        let bytes = samples * MemoryLayout<Int16>.size
        let data = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: MemoryLayout<Int16>.alignment)
        defer { data.deallocate() }
        let list = AudioBufferList.allocate(maximumBuffers: 1)
        defer { free(list.unsafeMutablePointer) }
        let flags = UnsafeMutablePointer<AudioUnitRenderActionFlags>.allocate(capacity: 1)
        defer { flags.deallocate() }

        func fill() {
            data.bindMemory(to: Int16.self, capacity: samples).update(repeating: 1000, count: samples)
            list[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(bytes), mData: data)
            flags.pointee = []
        }
        func output() -> [Int16] {
            Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Int16.self), count: samples))
        }

        // Muted: the tap sees the audio, the output device gets silence.
        fill()
        var tapped: [Int16] = []
        WebRTCAudioDevice.finishPlayout(list.unsafeMutablePointer, flags: flags, isMuted: true) { buffers in
            let buffer = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffers))[0]
            tapped = Array(UnsafeBufferPointer(start: buffer.mData?.assumingMemoryBound(to: Int16.self), count: samples))
        }
        #expect(tapped == Array(repeating: 1000, count: samples))
        #expect(output() == Array(repeating: 0, count: samples))
        #expect(flags.pointee.contains(.unitRenderAction_OutputIsSilence))

        // Playing: both get it unchanged.
        fill()
        tapped = []
        WebRTCAudioDevice.finishPlayout(list.unsafeMutablePointer, flags: flags, isMuted: false) { buffers in
            let buffer = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffers))[0]
            tapped = Array(UnsafeBufferPointer(start: buffer.mData?.assumingMemoryBound(to: Int16.self), count: samples))
        }
        #expect(tapped == Array(repeating: 1000, count: samples))
        #expect(output() == Array(repeating: 1000, count: samples))
        #expect(!flags.pointee.contains(.unitRenderAction_OutputIsSilence))
    }
}
