import SwiftUI
import Combine

/// Everything one console window drives: its connection, the stream, keyboard and mouse, OCR,
/// screenshots and recordings, and which side panel is open.
///
/// The app delegate owns the sessions and the device catalog they share (`KVMDeviceManager`).
/// There is one window and so one session for now; the type exists so that a second window can
/// have a second session without any of these objects knowing about the other.
@MainActor
final class ConsoleSession: ObservableObject {
    let connection: SessionConnection
    let webRTCManager: WebRTCManager
    let inputManager: InputManager
    let ocrManager: OCRManager
    let captureManager: CaptureManager
    /// Owned by the session rather than by `ContentView`: the View menu is built in the `App`
    /// scope, where a view's `@State` is out of reach. The key window hands its session's to the
    /// menu (`focusedSceneObject`).
    let panels: PanelPresentation

    /// Asks this session's window to toggle OCR copy mode. OCR mode is that window's view state;
    /// the chord that toggles it, and the menu-bar item, reach it through here.
    let copyModeRequests = PassthroughSubject<Void, Never>()

    private let link: ConsoleSessionLink
    private var cancellables = Set<AnyCancellable>()

    /// `defaults` is for tests, which pass a scratch suite; the app takes `.standard`. `link` is
    /// for tests too: the app's reaches the device, the stream and the connection log.
    init(catalog: KVMDeviceManager, defaults: UserDefaults = .standard, link: ConsoleSessionLink? = nil) {
        // Made here rather than as the default argument, which is evaluated outside the main actor.
        self.link = link ?? LiveSessionLink()
        let connection = SessionConnection(catalog: catalog)
        let webRTCManager = WebRTCManager()
        self.connection = connection
        self.webRTCManager = webRTCManager
        inputManager = InputManager(defaults: defaults)
        ocrManager = OCRManager()
        captureManager = CaptureManager(webRTCManager: webRTCManager, connection: connection, defaults: defaults)
        panels = PanelPresentation(defaults: defaults)
        // Here rather than in the window's `onAppear`: the menu-bar agent can connect a session
        // before its window has appeared.
        inputManager.setup(with: webRTCManager)

        // Straight off the connection, not mirrored from `ContentView`: the menu-bar agent can
        // connect a session before its window has appeared, and a view-scoped mirror would leave
        // the View menu's Settings item enabled over a dead session (or greyed out over a live one).
        connection.$connectedDevice
            .map { $0 != nil }
            .removeDuplicates()
            .assign(to: \.isSessionActive, on: panels)
            .store(in: &cancellables)

        // The chords keyboard capture keeps for the app act on this session. They used to be
        // posted app-wide, which every window would have answered.
        inputManager.onLocalShortcut = { [weak self] shortcut in
            self?.perform(shortcut)
        }
    }

    /// Runs one of the app's own shortcuts on this session: from its keyboard capture, or from
    /// the menu-bar agent for the active session.
    func perform(_ shortcut: InputManager.LocalShortcut) {
        switch shortcut {
        case .saveScreenshot:
            captureManager.saveScreenshot()
        case .toggleRecording:
            captureManager.toggleRecording()
        case .toggleCopyMode:
            copyModeRequests.send()
        }
    }

    // MARK: - Connecting

    /// How a connect ended, for whoever asked for it to report in its own way: the window with
    /// sheets and alerts, the menu-bar agent with modal alerts.
    enum ConnectOutcome {
        /// Signed in, with input started. `streamError` is set when the video did not come up;
        /// the API connection stands regardless, as it always has.
        case connected(KVMDevice, streamError: Error?)
        /// The device turned down the saved token and password, or there was neither.
        case needsPassword
        /// The device presented a certificate other than the pinned one.
        case certificateChanged(host: String, port: Int, fingerprint: String)
        case failed(Error)
    }

    /// The one connect path, used by the window and the menu-bar agent alike: sign in, start
    /// keyboard and mouse, tell the device a console is attached, then bring up the video.
    /// `onSignedIn` runs as soon as the device has accepted the session, before the stream (which
    /// can take seconds) — the window closes its Connections panel there.
    func connect(
        to device: KVMDevice,
        password: String? = nil,
        savePassword: Bool = false,
        onSignedIn: (KVMDevice) -> Void = { _ in }
    ) async -> ConnectOutcome {
        let connected: KVMDevice
        do {
            connected = try await link.signIn(self, to: device, password: password, savePassword: savePassword)
        } catch KVMError.authenticationFailed {
            return .needsPassword
        } catch KVMError.certificateChanged(let host, let port, let fingerprint) {
            return .certificateChanged(host: host, port: port, fingerprint: fingerprint)
        } catch {
            return .failed(error)
        }

        onSignedIn(connected)

        if connection.glkvmClient != nil {
            await link.startInput(self)
        }

        do {
            try await link.startStream(self, to: connected)
        } catch {
            return .connected(connected, streamError: error)
        }
        return .connected(connected, streamError: nil)
    }

    /// The operator's disconnect, from the window or the menu bar: hang up the stream, tell the
    /// device the console has gone, forget the device, and release whatever is still held on it.
    func disconnect() {
        link.hangUp(self)
        connection.disconnectFromDevice()
        link.stopInput(self)
    }

    /// The quit path for this session. A running recording is finalized first — an unfinished MP4
    /// has no index and will not play — then held keys and buttons are released on the remote,
    /// and the video session is hung up rather than left to time out on the device.
    func shutDownForTermination() async {
        await captureManager.finishRecordingForTermination()
        await link.shutDown(self)
    }
}

// MARK: - What a session does outside the app

/// The steps of a connect and a disconnect that reach outside the app: the device's HTTP API, its
/// HID socket, the video stream, and the connection log all of them write to. The session decides
/// the order and keeps its own state; the steps themselves sit behind this so tests can stand a
/// recorder in for them, with no device on the network and nothing in the operator's log.
@MainActor
protocol ConsoleSessionLink {
    /// Checks the device is reachable, signs in, saves it, and points the session's connection at
    /// it. Throws `KVMError.authenticationFailed` when a password is needed.
    func signIn(_ session: ConsoleSession, to device: KVMDevice, password: String?, savePassword: Bool) async throws -> KVMDevice
    /// Hands the signed-in client to keyboard and mouse, starts capturing them, and tells the
    /// device a console is attached.
    func startInput(_ session: ConsoleSession) async
    /// Brings up the video. A newer connect superseding this one is not an error.
    func startStream(_ session: ConsoleSession, to device: KVMDevice) async throws
    /// Hangs up the stream and tells the device the console has gone. Runs while the connection
    /// still holds the device and its client.
    func hangUp(_ session: ConsoleSession)
    /// Lets go of the HID socket (releasing anything held on the target) and stops capturing.
    func stopInput(_ session: ConsoleSession)
    /// Quiesces input — every held key and button released — and hangs up, for process exit.
    func shutDown(_ session: ConsoleSession) async
}

/// The app's link: everything here is what `ContentView` and `MenuBarAgent` each used to do
/// themselves, in the same order.
struct LiveSessionLink: ConsoleSessionLink {
    func signIn(_ session: ConsoleSession, to device: KVMDevice, password: String?, savePassword: Bool) async throws -> KVMDevice {
        do {
            return try await session.connection.connectToDevice(device, password: password, savePassword: savePassword)
        } catch {
            // A password prompt or a certificate question is the operator's next step, not a failure.
            switch error as? KVMError {
            case .authenticationFailed?, .certificateChanged?:
                break
            default:
                clog.error(.lifecycle, "Connect failed: \(error.localizedDescription)")
            }
            throw error
        }
    }

    func startInput(_ session: ConsoleSession) async {
        guard let client = session.connection.glkvmClient else { return }
        session.inputManager.setGLKVMClient(client)
        session.inputManager.startFullInputCapture()
        try? await client.setHidConnected(true)
    }

    func startStream(_ session: ConsoleSession, to device: KVMDevice) async throws {
#if canImport(WebRTC)
        do {
            try await session.webRTCManager.connect(to: device)
        } catch WebRTCError.superseded {
            // The operator's own later action replaced this attempt; nothing to report.
        } catch {
            clog.error(.lifecycle, "WebRTC connect failed, API still connected: \(error.localizedDescription)")
            throw error
        }
#endif
    }

    func hangUp(_ session: ConsoleSession) {
        session.webRTCManager.disconnect()
        let client = session.connection.glkvmClient
        Task {
            try? await client?.setHidConnected(false)
        }
    }

    func stopInput(_ session: ConsoleSession) {
        session.inputManager.setGLKVMClient(nil)
        session.inputManager.stopFullInputCapture()
    }

    func shutDown(_ session: ConsoleSession) async {
        await session.inputManager.shutdown()
        session.webRTCManager.disconnect()
    }
}

extension View {
    /// Hands a session's objects to the views of the window that shows it.
    @MainActor
    func consoleSession(_ session: ConsoleSession) -> some View {
        environmentObject(session)
            .environmentObject(session.connection)
            .environmentObject(session.webRTCManager)
            // Telemetry is a separate observable so only the views that render stats
            // re-evaluate when it ticks.
            .environmentObject(session.webRTCManager.telemetry)
            .environmentObject(session.inputManager)
            .environmentObject(session.ocrManager)
            .environmentObject(session.captureManager)
            .environmentObject(session.panels)
            // For the menus, which act on whichever window is key: the scene's focused objects
            // are that window's, and nil while no console window is key.
            .focusedSceneObject(session.panels)
            .focusedSceneObject(session.captureManager)
    }
}
