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
            ConsoleWindowRoot(registry: appDelegate.sessionRegistry)
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
        }
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
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

        let kvmDeviceManager = KVMDeviceManager()
        self.kvmDeviceManager = kvmDeviceManager
        let sessionRegistry = SessionRegistry(catalog: kvmDeviceManager)
        self.sessionRegistry = sessionRegistry
        audioRouter = SessionAudioRouter(registry: sessionRegistry, preferences: .shared)
        super.init()
    }

    private var isTerminating = false
    private var hasRepliedToTermination = false
    /// Longest the app waits for the HID release and socket close before quitting anyway.
    private static let terminationGraceNanoseconds: UInt64 = 3_000_000_000

    /// True when this process is hosting the unit tests. The test bundle is loaded into the app,
    /// so a test run launches it like any other; nothing in the tests needs the menu-bar agent, and
    /// without this the run would add a status item and a system-wide key monitor (⇧⌘V opens a
    /// modal Quick Connect) for its duration.
    static let isHostingUnitTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !Self.isHostingUnitTests {
            menuBarAgent = MenuBarAgent(
                registry: sessionRegistry,
                showMainWindow: { [weak self] in
                    self?.showMainWindow()
                }
            )
            menuBarAgent?.setup()
        }
        
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
