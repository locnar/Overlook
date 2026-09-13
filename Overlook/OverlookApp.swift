import SwiftUI
#if canImport(WebRTC)
import WebRTC
#endif
import Vision
import Network

@main
struct OverlookApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appDelegate.webRTCManager)
                // Telemetry is a separate observable so only the views that render stats
                // re-evaluate when it ticks.
                .environmentObject(appDelegate.webRTCManager.telemetry)
                .environmentObject(appDelegate.inputManager)
                .environmentObject(appDelegate.ocrManager)
                .environmentObject(appDelegate.kvmDeviceManager)
                .environmentObject(appDelegate.captureManager)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unifiedCompact)
        .windowResizability(.automatic)
        .commands {
            CaptureCommands(captureManager: appDelegate.captureManager)
        }
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var menuBarAgent: MenuBarAgent?

    let webRTCManager: WebRTCManager
    let inputManager = InputManager()
    let ocrManager = OCRManager()
    let kvmDeviceManager: KVMDeviceManager
    let captureManager: CaptureManager

    override init() {
        // How long the pointer rests on a control before its tooltip appears. AppKit reads this
        // from user defaults (milliseconds); registering it here shortens it for Overlook alone —
        // a value the user has set globally still wins. The system default is well over a second,
        // which is a long wait on a toolbar of bare icons.
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 500])

        let webRTCManager = WebRTCManager()
        let kvmDeviceManager = KVMDeviceManager()
        self.webRTCManager = webRTCManager
        self.kvmDeviceManager = kvmDeviceManager
        captureManager = CaptureManager(webRTCManager: webRTCManager, kvmDeviceManager: kvmDeviceManager)
        super.init()
    }

    private var isTerminating = false
    private var hasRepliedToTermination = false
    /// Longest the app waits for the HID release and socket close before quitting anyway.
    private static let terminationGraceNanoseconds: UInt64 = 3_000_000_000

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBarAgent = MenuBarAgent(
            kvmDeviceManager: kvmDeviceManager,
            webRTCManager: webRTCManager,
            inputManager: inputManager,
            captureManager: captureManager,
            showMainWindow: { [weak self] in
                self?.showMainWindow()
            }
        )
        menuBarAgent?.setup()
        
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
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateCancel }
        isTerminating = true
        menuBarAgent?.cleanup()
        kvmDeviceManager.cancelScan()

        Task { @MainActor [self] in
            await captureManager.finishRecordingForTermination()
            await inputManager.shutdown()
            webRTCManager.disconnect()
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
