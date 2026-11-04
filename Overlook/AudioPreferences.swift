import Foundation
import Combine

/// The app's audio settings: whether the target's audio plays, whether this Mac's microphone is
/// sent, which devices each uses, and which console windows play what they receive.
///
/// One object for every console window. The settings were always app-wide in `UserDefaults`, but
/// each window's `WebRTCManager` kept a published copy of the two toggles, so switching one in one
/// window left the other windows' Settings showing, and their next connect using, the old value.
/// Every session is handed this object instead, and every window's Settings binds to it. The keys
/// are the ones these settings have always been stored under.
@MainActor
final class AudioPreferences: ObservableObject {
    /// Which console windows play the audio they receive.
    enum PlaybackScope: String, CaseIterable, Identifiable {
        /// Only the active window's: the key window, or the last one to have been key.
        case activeWindow
        case allWindows

        var id: Self { self }

        var title: String {
            switch self {
            case .activeWindow: return "Active window only"
            case .allWindows: return "All windows"
            }
        }
    }

    enum Keys {
        static let audioEnabled = "overlook.audio.enabled"
        static let micEnabled = "overlook.audio.micEnabled"
        static let inputDeviceUID = "overlook.audio.inputDeviceUID"
        static let outputDeviceUID = "overlook.audio.outputDeviceUID"
        static let playbackScope = "overlook.audio.playbackScope"
    }

    /// Takes effect on the next connect, when the audio peer connection is built; turning it off
    /// mutes playback at once.
    @Published var audioEnabled: Bool {
        didSet { defaults.set(audioEnabled, forKey: Keys.audioEnabled) }
    }
    /// Takes effect on the next connect; turning it off silences the microphone at once.
    @Published var micEnabled: Bool {
        didSet { defaults.set(micEnabled, forKey: Keys.micEnabled) }
    }
    /// The CoreAudio device UIDs to use, empty for the system default. Read when a connect builds
    /// its audio device.
    @Published var inputDeviceUID: String {
        didSet { defaults.set(inputDeviceUID, forKey: Keys.inputDeviceUID) }
    }
    @Published var outputDeviceUID: String {
        didSet { defaults.set(outputDeviceUID, forKey: Keys.outputDeviceUID) }
    }
    /// Takes effect at once, with no reconnect: a window that stops playing is muted, not
    /// disconnected (`SessionAudioRouter`).
    @Published var playbackScope: PlaybackScope {
        didSet { defaults.set(playbackScope.rawValue, forKey: Keys.playbackScope) }
    }

    /// The app's, on this Mac's own defaults.
    static let shared = AudioPreferences(defaults: .standard)

    private let defaults: UserDefaults

    /// `defaults` is `.standard` for the app's own object; tests pass a scratch suite.
    init(defaults: UserDefaults) {
        self.defaults = defaults
        audioEnabled = defaults.bool(forKey: Keys.audioEnabled)
        micEnabled = defaults.bool(forKey: Keys.micEnabled)
        inputDeviceUID = defaults.string(forKey: Keys.inputDeviceUID) ?? ""
        outputDeviceUID = defaults.string(forKey: Keys.outputDeviceUID) ?? ""
        playbackScope = PlaybackScope(rawValue: defaults.string(forKey: Keys.playbackScope) ?? "") ?? .activeWindow
    }
}

/// What one console session does with audio: whether it plays what it receives, and whether it
/// sends this Mac's microphone.
struct AudioRoute: Equatable {
    /// Plays the target's audio through this Mac's output. A session that does not still receives
    /// and decodes its audio, and still records it; only what reaches the output device is
    /// silenced (`WebRTCAudioDevice.finishPlayout`).
    var playsAudio: Bool
    /// Sends the microphone, when Microphone is on. Only the active session does: one microphone
    /// speaking into two targets at once is never what the operator meant.
    var sendsMicrophone: Bool

    /// A session the router has not reached yet behaves as one window always did.
    static let unrouted = AudioRoute(playsAudio: true, sendsMicrophone: true)

    /// The rule: a session plays if every window plays, or if it is the active session; only the
    /// active session sends the microphone.
    static func forSession(isActive: Bool, scope: AudioPreferences.PlaybackScope) -> AudioRoute {
        AudioRoute(playsAudio: scope == .allWindows || isActive, sendsMicrophone: isActive)
    }
}

/// Keeps every console session's `AudioRoute` in step with which session is active and with the
/// "Play audio from" setting. The app delegate owns one.
@MainActor
final class SessionAudioRouter {
    private var cancellable: AnyCancellable?

    init(registry: SessionRegistry, preferences: AudioPreferences) {
        // `@Published` fires in `willSet`, so the new values are the emitted ones, not what the
        // registry would report if asked back. What this holds on to is the registry's own current
        // list and active session, so it keeps no closed session alive.
        cancellable = registry.$sessions
            .combineLatest(registry.$activeSession, preferences.$playbackScope)
            .sink { sessions, active, scope in
                for session in sessions {
                    session.webRTCManager.setAudioRoute(.forSession(isActive: session === active, scope: scope))
                }
            }
    }
}
