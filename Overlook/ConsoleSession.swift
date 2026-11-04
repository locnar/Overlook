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
    /// scope, where a view's `@State` is out of reach, and the menu stays live with no window open.
    let panels: PanelPresentation

    private var cancellables = Set<AnyCancellable>()

    /// `defaults` is for tests, which pass a scratch suite; the app takes `.standard`.
    init(catalog: KVMDeviceManager, defaults: UserDefaults = .standard) {
        let connection = SessionConnection(catalog: catalog)
        let webRTCManager = WebRTCManager()
        self.connection = connection
        self.webRTCManager = webRTCManager
        inputManager = InputManager(defaults: defaults)
        ocrManager = OCRManager()
        captureManager = CaptureManager(webRTCManager: webRTCManager, connection: connection, defaults: defaults)
        panels = PanelPresentation(defaults: defaults)

        // Straight off the connection, not mirrored from `ContentView`: the menu-bar agent
        // connects and disconnects with no window open, and a view-scoped mirror would leave the
        // View menu's Settings item enabled over a dead session (or greyed out over a live one).
        connection.$connectedDevice
            .map { $0 != nil }
            .removeDuplicates()
            .assign(to: \.isSessionActive, on: panels)
            .store(in: &cancellables)
    }

    /// The quit path for this session. A running recording is finalized first — an unfinished MP4
    /// has no index and will not play — then held keys and buttons are released on the remote,
    /// and the video session is hung up rather than left to time out on the device.
    func shutDownForTermination() async {
        await captureManager.finishRecordingForTermination()
        await inputManager.shutdown()
        webRTCManager.disconnect()
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
    }
}
