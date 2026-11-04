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
        WindowGroup {
            ContentView()
                .consoleSession(appDelegate.session)
                .environmentObject(appDelegate.kvmDeviceManager)
                .environmentObject(ConnectionLog.shared.store)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unifiedCompact)
        .windowResizability(.automatic)
        .commands {
            // The View menu's Show/Hide Toolbar pair. Useful in its own right on a console
            // window, and `PanelCommands` anchors to the group it contributes.
            ToolbarCommands()

            PanelCommands()

            // One window: the panel state, `showMainWindow()` and `MenuBarAgent` all assume a
            // single console, and a second window would fight the first over which panel is open.
            CommandGroup(replacing: .newItem) { }

            CaptureCommands()
        }
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var menuBarAgent: MenuBarAgent?

    /// The devices every console chooses from.
    let kvmDeviceManager: KVMDeviceManager
    /// The one console window's session. See `sessions`.
    let session: ConsoleSession

    /// Every live session. One window means one session; code that has to reach all of them —
    /// quitting, for one — goes through this rather than `session`.
    private var sessions: [ConsoleSession] { [session] }

    override init() {
        // How long the pointer rests on a control before its tooltip appears. AppKit reads this
        // from user defaults (milliseconds); registering it here shortens it for Overlook alone —
        // a value the user has set globally still wins. The system default is well over a second,
        // which is a long wait on a toolbar of bare icons.
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 500])

        let kvmDeviceManager = KVMDeviceManager()
        self.kvmDeviceManager = kvmDeviceManager
        session = ConsoleSession(catalog: kvmDeviceManager)
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
                kvmDeviceManager: kvmDeviceManager,
                session: session,
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

    private func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let windows = NSApp.windows
        let candidate = windows.first(where: { $0.canBecomeKey && $0.isVisible }) ?? windows.first(where: { $0.canBecomeKey })
        candidate?.makeKeyAndOrderFront(nil)
    }
    
    /// Quitting while keys or buttons are held on the remote would leave them held, and a video
    /// session abandoned without a hangup lingers on the device until its keepalive times out.
    /// So the app defers termination, releases HID state, hangs up, and only then lets AppKit exit.
    /// A running recording is finalized first — an unfinished MP4 has no index and will not play.
    /// (`ConsoleSession.shutDownForTermination` does those steps for one session.)
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateCancel }
        isTerminating = true
        menuBarAgent?.cleanup()
        kvmDeviceManager.cancelScan()

        let sessions = self.sessions
        Task { @MainActor [self] in
            // Side by side rather than one after another, so a session whose HID socket is slow
            // to close does not use up the grace period the others need to hang up.
            await withTaskGroup(of: Void.self) { group in
                for session in sessions {
                    group.addTask { await session.shutDownForTermination() }
                }
            }
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
