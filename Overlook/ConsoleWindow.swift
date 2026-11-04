import SwiftUI
import AppKit

/// One console window: the `WindowGroup`'s content, with a session of its own.
///
/// The session is made with the window — from `SessionRegistry.sessionForNewWindow()`, which hands
/// over one the menu-bar agent has already started connecting when it asked for this window — and
/// lives as long as the window's state does.
struct ConsoleWindowRoot: View {
    /// The `WindowGroup`'s id, for `openWindow(id:)`.
    static let windowGroupID = "console"

    let registry: SessionRegistry

    @StateObject private var session: ConsoleSession
    @Environment(\.openWindow) private var openWindow

    init(registry: SessionRegistry) {
        self.registry = registry
        // Evaluated once per window: SwiftUI keeps the first object it was given.
        _session = StateObject(wrappedValue: registry.sessionForNewWindow())
    }

    var body: some View {
        ContentView()
            .consoleSession(session)
            .environmentObject(registry.catalog)
            .environmentObject(ConnectionLog.shared.store)
            .background(ConsoleWindowAttachment(session: session, registry: registry))
            .onAppear {
                // Any open window's action will do; the menu-bar agent needs one to open a window
                // with none in front of it.
                let openWindow = openWindow
                registry.openWindowAction = { openWindow(id: Self.windowGroupID) }
            }
    }
}

/// Connects a console window to its session and to the registry: the session learns its window,
/// the registry learns when the window appears, becomes key and closes, and a close goes through
/// the session first — a window that is recording asks before it closes.
///
/// Closing is intercepted as the window's delegate, in front of the one SwiftUI installed, to
/// which everything else is forwarded (the same arrangement as `WindowAspectRatioSetter`'s, which
/// may sit in front of or behind this one; each forwards what it does not handle).
private struct ConsoleWindowAttachment: NSViewRepresentable {
    let session: ConsoleSession
    let registry: SessionRegistry

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session, registry: registry)
    }

    func makeNSView(context: Context) -> WindowWatchingView {
        let view = WindowWatchingView(frame: .zero)
        let coordinator = context.coordinator
        view.onWindow = { window in
            // After the current pass, like the other window hooks here: SwiftUI finishes setting
            // the window up, its own delegate included, before anything is put in front of it.
            Task { @MainActor in
                coordinator.attach(to: window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: WindowWatchingView, context: Context) {}

    final class WindowWatchingView: NSView {
        var onWindow: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                onWindow?(window)
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        private let session: ConsoleSession
        private let registry: SessionRegistry
        private weak var window: NSWindow?
        /// Written once, on the main thread, before the window can ask anything of it; read from
        /// the forwarding overrides, which AppKit declares outside any actor.
        nonisolated(unsafe) private weak var forwardedDelegate: NSWindowDelegate?
        private var observers: [NSObjectProtocol] = []
        /// While a confirmed close finishes the recording, further close requests wait for it.
        private var isFinishingRecording = false

        init(session: ConsoleSession, registry: SessionRegistry) {
            self.session = session
            self.registry = registry
        }

        func attach(to window: NSWindow) {
            guard self.window == nil else { return }
            self.window = window

            // Windows, never tabs; `allowsAutomaticWindowTabbing` covers the rest of the app.
            window.tabbingMode = .disallowed

            forwardedDelegate = window.delegate
            window.delegate = self

            session.attach(to: window)
            registry.add(session)

            let center = NotificationCenter.default
            observers = [
                center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.registry.sessionDidBecomeKey(self.session)
                    }
                },
                center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.windowIsClosing()
                    }
                },
            ]
            if window.isKeyWindow {
                registry.sessionDidBecomeKey(session)
            }
        }

        private func windowIsClosing() {
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
            observers.removeAll()
            session.windowWillClose()
            registry.remove(session)
        }

        // MARK: Closing

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard !isFinishingRecording else { return false }
            switch session.closeDecision {
            case .close, .disconnectAndClose:
                // The disconnect itself happens as the window closes
                // (`ConsoleSession.windowWillClose`), so a close that skips this still gets it.
                return forwardedDelegate?.windowShouldClose?(sender) ?? true
            case .confirmStopRecording(let deviceName):
                askToStopRecording(deviceName: deviceName, in: sender)
                return false
            }
        }

        private func askToStopRecording(deviceName: String, in window: NSWindow) {
            guard window.attachedSheet == nil else { return }

            let alert = NSAlert()
            alert.messageText = "\(deviceName) is recording"
            alert.informativeText = "Closing this window stops the recording and disconnects from \(deviceName). The recording so far is saved."
            let cancel = alert.addButton(withTitle: "Cancel")
            let stop = alert.addButton(withTitle: "Stop recording and close")
            stop.hasDestructiveAction = true
            // Set rather than left to NSAlert: its "Cancel" title rule gives that button Escape in
            // place of the Return a first button would get, leaving no default button at all.
            // Cancel is the default here, so a stray Return keeps the recording going.
            cancel.keyEquivalent = "\r"

            alert.beginSheetModal(for: window) { [weak self, weak window] response in
                guard response == .alertSecondButtonReturn, let self, let window else { return }
                self.isFinishingRecording = true
                Task { @MainActor in
                    await self.session.stopRecordingAndDisconnect()
                    self.isFinishingRecording = false
                    // Asked again now that nothing is recording or connected, so it closes plainly.
                    window.performClose(nil)
                }
            }
        }

        // MARK: Forwarding

        nonisolated override func responds(to aSelector: Selector!) -> Bool {
            if super.responds(to: aSelector) {
                return true
            }
            return forwardedDelegate?.responds(to: aSelector) ?? false
        }

        nonisolated override func forwardingTarget(for aSelector: Selector!) -> Any? {
            forwardedDelegate
        }
    }
}
