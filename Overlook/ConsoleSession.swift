import SwiftUI
import Combine

/// Everything one console window drives: its connection, the stream, keyboard and mouse, OCR,
/// screenshots and recordings, and which side panel is open.
///
/// Each console window has one (`ConsoleWindowRoot` makes it), and `SessionRegistry` lists them
/// for the app delegate. They share only the device catalog (`KVMDeviceManager`); none of these
/// objects knows about another window's.
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

    /// This session's handle on the connection log, which tags every line with the session and
    /// its device. Each of its objects that logs is handed this one.
    let log: SessionLog

    /// Asks this session's window to toggle OCR copy mode. OCR mode is that window's view state;
    /// the chord that toggles it, and the menu-bar item, reach it through here.
    let copyModeRequests = PassthroughSubject<Void, Never>()

    /// The registry listing this session, which a connect asks whether another window already
    /// shows the device.
    weak var registry: SessionRegistry?
    /// The window showing this session, once it exists.
    private(set) weak var window: NSWindow?
    /// The device a connect is signing in to, from the moment it starts until the device has
    /// accepted or refused it. After that `connection.connectedDevice` says where the session is.
    @Published private(set) var connectingAddress: DeviceAddress?
    /// The device a connect is signing in to, as the catalog listed it then, so that a connect to
    /// another of its addresses finds this window.
    private var connectingDevice: KVMDevice?
    /// Set as the window closes. A connect still signing in then is undone when it lands.
    private(set) var isClosed = false
    /// Whether a connect has started since the operator last disconnected, so the next teardown
    /// is theirs to log. Quitting tears the connection down without letting go of the device, and
    /// the window then closes over it and tears it down again; the operator disconnected once, so
    /// only the first of these clears this and logs it.
    private var hasConnectionToEnd = false

    private let link: ConsoleSessionLink
    private var cancellables = Set<AnyCancellable>()

    /// `defaults` is for tests, which pass a scratch suite; the app takes `.standard`. `link` is
    /// for tests too: the app's reaches the device, the stream and the connection log. So are
    /// `audioPreferences` (the app's sessions all share `AudioPreferences.shared`) and
    /// `connectionLog` (the app's is `ConnectionLog.shared`, which writes the file).
    init(
        catalog: KVMDeviceManager,
        defaults: UserDefaults = .standard,
        link: ConsoleSessionLink? = nil,
        audioPreferences: AudioPreferences? = nil,
        connectionLog: ConnectionLog? = nil
    ) {
        // Made here rather than as the default argument, which is evaluated outside the main actor.
        self.link = link ?? LiveSessionLink()
        let log = SessionLog(destination: connectionLog ?? .shared)
        self.log = log
        let connection = SessionConnection(catalog: catalog, log: log)
        let webRTCManager = WebRTCManager(audioPreferences: audioPreferences, log: log)
        self.connection = connection
        self.webRTCManager = webRTCManager
        inputManager = InputManager(defaults: defaults, log: log)
        ocrManager = OCRManager()
        captureManager = CaptureManager(webRTCManager: webRTCManager, connection: connection, defaults: defaults)
        panels = PanelPresentation(defaults: defaults)
        // Here rather than in the window's `onAppear`: the menu-bar agent can connect a session
        // before its window has appeared.
        inputManager.setup(with: webRTCManager)

        // Straight off the connection, not mirrored from `ContentView`: the menu-bar agent can
        // connect a session before its window has appeared, and a view-scoped mirror would leave
        // the View menu's Settings item enabled over a dead session (or greyed out over a live one).
        // A weak sink rather than `assign(to:on:)`, which holds its target strongly for as long as
        // the subscription lives.
        let panels = self.panels
        connection.$connectedDevice
            .map { $0 != nil }
            .removeDuplicates()
            .sink { [weak panels] isActive in
                panels?.isSessionActive = isActive
            }
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
        /// Another window already shows this device, or is connecting to it. Nothing was done
        /// here; the caller brings that window forward.
        case openElsewhere(ConsoleSession)
        /// The window closed while the connect was under way, and the connect was undone.
        case cancelled
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
        // One window per device, across all of its addresses: the device's id changes once it is
        // saved, and the same device may be reached through another of its addresses.
        if let other = registry?.session(showing: device, excluding: self) {
            return .openElsewhere(other)
        }

        // From here on this session's lines name this device, the hang-up of a previous one
        // included: the device it is talking to now is the one an operator would look for.
        log.deviceLabel = SessionLog.label(host: device.host, port: device.port)
        connectingAddress = device.address
        connectingDevice = device
        hasConnectionToEnd = true
        let connected: KVMDevice
        do {
            connected = try await link.signIn(self, to: device, password: password, savePassword: savePassword)
            connectingAddress = nil
            connectingDevice = nil
        } catch KVMError.authenticationFailed {
            signInDidNotLand()
            return .needsPassword
        } catch KVMError.certificateChanged(let host, let port, let fingerprint) {
            signInDidNotLand()
            return .certificateChanged(host: host, port: port, fingerprint: fingerprint)
        } catch {
            signInDidNotLand()
            return .failed(error)
        }

        // Nobody is left to use a connection that lands after its window has gone.
        guard !isClosed else {
            disconnect()
            return .cancelled
        }

        onSignedIn(connected)

        if connection.glkvmClient != nil {
            await link.startInput(self)
        }
        // Closing the window while input started has already disconnected; no stream for it.
        guard !isClosed else { return .cancelled }

        do {
            try await link.startStream(self, to: connected)
        } catch {
            return .connected(connected, streamError: error)
        }
        return .connected(connected, streamError: nil)
    }

    /// A sign-in the device did not accept leaves the session as it was: still connected to
    /// whatever it had before, or with nothing for a later teardown to log as a disconnect.
    private func signInDidNotLand() {
        connectingAddress = nil
        connectingDevice = nil
        if connection.connectedDevice == nil {
            hasConnectionToEnd = false
        }
    }

    /// Logs the operator's disconnect for the first teardown since the last connect started, and
    /// nothing for any after it or for a session that never connected.
    private func logOperatorDisconnect() {
        guard hasConnectionToEnd else { return }
        hasConnectionToEnd = false
        log.notice(.lifecycle, "Operator disconnect")
    }

    /// The operator's disconnect, from the window or the menu bar: hang up the stream, tell the
    /// device the console has gone, forget the device, and release whatever is still held on it.
    func disconnect() {
        logOperatorDisconnect()
        link.hangUp(self)
        connection.disconnectFromDevice()
        link.stopInput(self)
    }

    /// Whether this session shows, or is signing in to, the device at `address`: through that
    /// address, or through another address of the same device.
    func isShowing(_ address: DeviceAddress) -> Bool {
        if let connected = connection.connectedDevice, connected.includes(address) {
            return true
        }
        if let connectingDevice, connectingDevice.includes(address) {
            return true
        }
        return connectingAddress == address
    }

    /// Whether this session shows, or is signing in to, `device` through any of its addresses.
    func isShowing(_ device: KVMDevice) -> Bool {
        if let connected = connection.connectedDevice {
            if connected.id == device.id || device.includes(connected.address) || connected.includes(device.address) {
                return true
            }
        }
        if let connectingDevice {
            if connectingDevice.id == device.id || device.includes(connectingDevice.address) || connectingDevice.includes(device.address) {
                return true
            }
        }
        return false
    }

    /// Neither connected nor connecting, so a connect from the menu bar can use this window.
    var isIdle: Bool {
        connection.connectedDevice == nil && connectingAddress == nil
    }

    // MARK: - The window

    /// Tells the session which window shows it. Keyboard and mouse follow that window's key
    /// status from here on (`InputManager.attach(to:)`).
    func attach(to window: NSWindow?) {
        self.window = window
        inputManager.attach(to: window)
    }

    /// Brings this session's window to the front, and the app with it.
    func bringWindowForward() {
        guard let window else { return }
        NSApp.activate()
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
    }

    /// What closing the window involves, worked out when the operator asks to close it.
    enum CloseDecision: Equatable {
        /// Nothing connected: the window just closes.
        case close
        /// Connected, or connecting: the session disconnects as the window closes.
        case disconnectAndClose
        /// A recording is running. Closing would end it, so the operator is asked first.
        case confirmStopRecording(deviceName: String)
    }

    static func closeDecision(device: KVMDevice?, isConnecting: Bool, isRecording: Bool) -> CloseDecision {
        if isRecording {
            return .confirmStopRecording(deviceName: device?.displayName ?? "Overlook")
        }
        if device != nil || isConnecting {
            return .disconnectAndClose
        }
        return .close
    }

    var closeDecision: CloseDecision {
        Self.closeDecision(
            device: connection.connectedDevice,
            isConnecting: connectingAddress != nil,
            isRecording: captureManager.isRecording
        )
    }

    /// The operator confirmed closing a window that is recording. The recording is finished first
    /// — an MP4 that is never finalized has no index and will not play — and then the session
    /// disconnects; the window closes after that.
    func stopRecordingAndDisconnect() async {
        await captureManager.finishRecordingForTermination()
        disconnect()
    }

    /// The window is closing; it has already agreed to. A connected session disconnects, which is
    /// the same release of held keys and buttons and the same hang-up as quitting, and input stops
    /// following the window. Anything still recording at this point (a close that skipped the
    /// question) is finished by the disconnect.
    func windowWillClose() {
        isClosed = true
        if connection.connectedDevice != nil || connectingAddress != nil {
            disconnect()
        }
        attach(to: nil)
    }

    /// The quit path for this session. A running recording is finalized first — an unfinished MP4
    /// has no index and will not play — then held keys and buttons are released on the remote,
    /// and the video session is hung up rather than left to time out on the device.
    func shutDownForTermination() async {
        await captureManager.finishRecordingForTermination()
        logOperatorDisconnect()
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
                session.log.error(.lifecycle, "Connect failed: \(error.localizedDescription)")
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
            session.log.error(.lifecycle, "WebRTC connect failed, API still connected: \(error.localizedDescription)")
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
            .environmentObject(session.webRTCManager.audioPreferences)
            // The log every window shares, and which session's lines are this window's.
            .environmentObject(session.log.store)
            .environment(\.connectionLogSessionID, session.log.sessionID)
            // For the menus, which act on whichever window is key: the scene's focused objects
            // are that window's, and nil while no console window is key.
            .focusedSceneObject(session.panels)
            .focusedSceneObject(session.captureManager)
    }
}
