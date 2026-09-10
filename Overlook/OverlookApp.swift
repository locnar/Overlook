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
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unifiedCompact)
        .windowResizability(.automatic)
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var menuBarAgent: MenuBarAgent?

    let webRTCManager = WebRTCManager()
    let inputManager = InputManager()
    let ocrManager = OCRManager()
    let kvmDeviceManager = KVMDeviceManager()

    private var isTerminating = false
    private var hasRepliedToTermination = false
    /// Longest the app waits for the HID release and socket close before quitting anyway.
    private static let terminationGraceNanoseconds: UInt64 = 3_000_000_000

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBarAgent = MenuBarAgent(
            kvmDeviceManager: kvmDeviceManager,
            webRTCManager: webRTCManager,
            inputManager: inputManager,
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
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateCancel }
        isTerminating = true
        menuBarAgent?.cleanup()
        kvmDeviceManager.cancelScan()

        Task { @MainActor [self] in
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
