import SwiftUI
#if canImport(WebRTC)
import WebRTC
#endif
import Vision
import Network
import Combine

@main
struct OverlookApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        // Every window is a console with a session of its own; File › New Window (⌘N) opens
        // another one, disconnected.
        WindowGroup(id: ConsoleWindowRoot.windowGroupID) {
            if AppEnvironment.isHostingTests {
                // No console, so no session: nothing that connects, scans or reads settings.
                TestHostWindow()
            } else {
                ConsoleWindowRoot(registry: appDelegate.sessionRegistry)
            }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unifiedCompact)
        .windowResizability(.automatic)
        .commands {
            // The View menu's Show/Hide Toolbar pair. Useful in its own right on a console
            // window, and `PanelCommands` anchors to the group it contributes.
            ToolbarCommands()

            PanelCommands()

            CaptureCommands()

            RemoteClipboardCommands()
        }
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    /// The app's delegate once it exists. `NSApp.delegate` is SwiftUI's own object, which forwards
    /// to this one, so a test that checks what the app built at launch finds it here.
    private(set) static weak var launched: AppDelegate?

    var menuBarAgent: MenuBarAgent?

    /// The devices every console chooses from.
    let kvmDeviceManager: KVMDeviceManager
    /// Every console window's session, and which one is active.
    let sessionRegistry: SessionRegistry
    /// Plays the active window's audio, or every window's, and gives the microphone to the active
    /// window, following the shared audio settings.
    private let audioRouter: SessionAudioRouter

    override init() {
        // How long the pointer rests on a control before its tooltip appears. AppKit reads this
        // from user defaults (milliseconds); registering it here shortens it for Overlook alone —
        // a value the user has set globally still wins. The system default is well over a second,
        // which is a long wait on a toolbar of bare icons.
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 500])

        // Separate windows, never tabs. Set before the first window exists, so macOS neither
        // offers a tab bar nor opens a new window as a tab (as it does under "Prefer tabs").
        NSWindow.allowsAutomaticWindowTabbing = false

        // `.standard` and the login keychain, or under the test host stand-ins that keep the
        // operator's saved devices, tokens and pins out of reach (`AppEnvironment`).
        let kvmDeviceManager = KVMDeviceManager(
            defaults: AppEnvironment.defaults,
            credentials: AppEnvironment.makeCredentialStore(),
            trustStore: .shared
        )
        self.kvmDeviceManager = kvmDeviceManager
        let sessionRegistry = SessionRegistry(catalog: kvmDeviceManager)
        self.sessionRegistry = sessionRegistry
        audioRouter = SessionAudioRouter(registry: sessionRegistry, preferences: .shared)
        super.init()
        Self.launched = self
    }

    private var isTerminating = false
    private var hasRepliedToTermination = false
    /// Longest the app waits for the HID release and socket close before quitting anyway.
    private static let terminationGraceNanoseconds: UInt64 = 3_000_000_000

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hosting the tests, the app adds no status item and no system-wide key monitor (⇧⌘V
        // opens a modal Quick Connect), and leaves Xcode in front.
        guard !AppEnvironment.isHostingTests else { return }

        menuBarAgent = MenuBarAgent(
            registry: sessionRegistry,
            showMainWindow: { [weak self] in
                self?.showMainWindow()
            }
        )
        menuBarAgent?.setup()
        
        // Configure app for KVM control
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Brings the active session's window forward, or opens a console window when none is open.
    private func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        if let active = sessionRegistry.activeSession {
            active.bringWindowForward()
            return
        }
        if sessionRegistry.openWindow() != nil {
            return
        }
        let windows = NSApp.windows
        let candidate = windows.first(where: { $0.canBecomeKey && $0.isVisible }) ?? windows.first(where: { $0.canBecomeKey })
        candidate?.makeKeyAndOrderFront(nil)
    }
    
    /// Quitting while keys or buttons are held on the remote would leave them held, and a video
    /// session abandoned without a hangup lingers on the device until its keepalive times out.
    /// So the app defers termination, releases HID state, hangs up, and only then lets AppKit exit.
    /// A running recording is finalized first — an unfinished MP4 has no index and will not play.
    /// (`ConsoleSession.shutDownForTermination` does those steps for one session, and
    /// `SessionRegistry.shutDownAll` runs them for every session.)
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateCancel }
        isTerminating = true
        menuBarAgent?.cleanup()
        kvmDeviceManager.cancelScan()

        let registry = sessionRegistry
        Task { @MainActor [self] in
            await registry.shutDownAll()
            finishTermination(sender)
        }
        // Don't let a wedged HID socket hold the process open.
        Task { @MainActor [self] in
            try? await Task.sleep(nanoseconds: Self.terminationGraceNanoseconds)
            finishTermination(sender)
        }
        return .terminateLater
    }

    private func finishTermination(_ app: NSApplication) {
        guard !hasRepliedToTermination else { return }
        hasRepliedToTermination = true
        app.reply(toApplicationShouldTerminate: true)
    }
}

/// The one window the app shows while it hosts the tests, in place of a console. It has no
/// session, and macOS neither restores it at the next launch nor saves its frame, so a test run
/// leaves the operator's windows as they were.
private struct TestHostWindow: View {
    var body: some View {
        Text("Overlook is hosting the unit tests.")
            .foregroundStyle(.secondary)
            .padding(40)
            .background(NonRestorableWindow())
    }

    private struct NonRestorableWindow: NSViewRepresentable {
        func makeNSView(context: Context) -> NSView {
            let view = NSView()
            DispatchQueue.main.async {
                guard let window = view.window else { return }
                window.isRestorable = false
                window.setFrameAutosaveName("")
            }
            return view
        }

        func updateNSView(_ nsView: NSView, context: Context) {}
    }
}
