import SwiftUI
import Foundation
import AppKit

struct ContentView: View {
    @EnvironmentObject var webRTCManager: WebRTCManager
    @EnvironmentObject var inputManager: InputManager
    @EnvironmentObject var ocrManager: OCRManager
    @EnvironmentObject var kvmDeviceManager: KVMDeviceManager
    
    @State private var selectedDevice: KVMDevice?
    @State private var isConnected = false
    @State private var isOCRModeEnabled = false
    @State private var isShowingOCRResult = false
    @State private var showingSettings = false
    @State private var selectedText = ""

    @State private var showingManualConnect = false
    @State private var manualHostPort = ""
    @State private var manualPort = "443"

    @State private var manualPassword = ""
    @State private var manualSavePassword = false

    @State private var showingPasswordPrompt = false
    @State private var pendingPasswordDevice: KVMDevice?
    @State private var pendingPassword = ""
    @State private var pendingSavePassword = false
    @State private var connectionErrorMessage: String?
    @State private var certificatePrompt: CertificateChangePrompt?

    @State private var suppressDeviceAutoConnect = false

    @State private var showingConnections = false
    @State private var didAutoOpenConnections = false

    /// The settings panel is unmounted while closed, so its survivable state (loaded config,
    /// keymaps, streamer state, section expansion, drafts) is owned here instead.
    @StateObject private var settingsPanelModel = WebUISettingsPanelModel()

    @State private var pausedCaptureKeyboardWasEnabled: Bool?
    @State private var pausedCaptureMouseWasEnabled: Bool?
    @State private var isInputCapturePausedForUI: Bool = false

    @State private var windowRef: NSWindow?

    @State private var isFullscreen: Bool = false
    @State private var showFullscreenControls: Bool = false
    @State private var fullscreenHoverTask: Task<Void, Never>?

    @AppStorage("overlook.appAppearance") private var appAppearance: String = "system"

    private var preferredColorScheme: ColorScheme? {
        switch appAppearance {
        case "light":
            return .light
        case "dark":
            return .dark
        default:
            return nil
        }
    }

    /// Everything in the window title that changes at connection-level frequency: device,
    /// state, guest resolution, mouse mode. The live kbps/fps half is appended by
    /// `WindowTitleTelemetryHost`, which observes `StreamTelemetryModel` on its own, so a stats
    /// tick never re-evaluates this view's body.
    private var windowTitlePrefix: String {
        let device = kvmDeviceManager.connectedDevice

        let deviceLabel: String
        if let device {
            if device.type == .glinetComet {
                deviceLabel = "GLKVM"
            } else {
                deviceLabel = device.type.displayName
            }
        } else {
            deviceLabel = "Overlook"
        }

        let connectionState: String
        if device == nil || isConnected == false {
            connectionState = "Disconnected"
        } else {
            connectionState = "Connected"
        }

        let resolution: String
        if let size = webRTCManager.videoSize {
            resolution = "\(Int(size.width))x\(Int(size.height))"
        } else {
            resolution = "—"
        }

        return "Overlook - \(deviceLabel) / \(connectionState) / \(resolution)"
    }

    /// Trailing mouse-mode segment of the window title; empty when not connected.
    private var windowTitleSuffix: String {
        guard isConnected, inputManager.transportMode == .glkvmWebSocket else { return "" }
        if inputManager.isGLKVMAbsoluteMouseMode {
            return " / Mouse: Absolute"
        }
        return inputManager.isPointerLocked ? " / Mouse: Relative (captured)" : " / Mouse: Relative"
    }

    private func applyAppAppearance() {
        switch appAppearance {
        case "light":
            NSApp.appearance = NSAppearance(named: .aqua)
        case "dark":
            NSApp.appearance = NSAppearance(named: .darkAqua)
        default:
            NSApp.appearance = nil
        }
    }
    
    var body: some View {
        ZStack(alignment: .trailing) {
            if isFullscreen {
                VideoSurfaceView(
                    isOCRModeEnabled: $isOCRModeEnabled,
                    selectedText: $selectedText,
                    isShowingOCRResult: $isShowingOCRResult,
                    onReconnect: {
                        guard let device = kvmDeviceManager.connectedDevice else { return }
                        Task { @MainActor in
                            await webRTCManager.reconnect(to: device, reason: "Reconnect button")
                        }
                    }
                )
                .ignoresSafeArea()
                .allowsHitTesting(!showingSettings)
            } else {
                VideoSurfaceView(
                    isOCRModeEnabled: $isOCRModeEnabled,
                    selectedText: $selectedText,
                    isShowingOCRResult: $isShowingOCRResult,
                    onReconnect: {
                        guard let device = kvmDeviceManager.connectedDevice else { return }
                        Task { @MainActor in
                            await webRTCManager.reconnect(to: device, reason: "Reconnect button")
                        }
                    }
                )
                .allowsHitTesting(!showingSettings)
            }

            if isFullscreen && !showingSettings && !showingConnections {
                VStack(spacing: 0) {
                    Color.clear
                        .frame(height: 28)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .onHover { hovering in
                            fullscreenHoverTask?.cancel()
                            if hovering {
                                fullscreenHoverTask = Task { @MainActor in
                                    try? await Task.sleep(nanoseconds: 350_000_000)
                                    if isFullscreen {
                                        withAnimation(.easeInOut(duration: 0.15)) {
                                            showFullscreenControls = true
                                        }
                                    }
                                }
                            } else {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    showFullscreenControls = false
                                }
                            }
                        }

                    if showFullscreenControls {
                        HStack(spacing: 10) {
                            Button(action: { showingConnections.toggle() }) {
                                Image(systemName: "personalhotspot")
                            }
                            .help("Connections")

                            Button(action: { fitWindowToGuest() }) {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                            }
                            .disabled(webRTCManager.videoSize == nil)
                            .help("Fit window to guest")

                            Button(action: { toggleOCR() }) {
                                Image(systemName: isOCRModeEnabled ? "text.viewfinder" : "doc.text")
                            }
                            .disabled(!isConnected)
                            .help(isOCRModeEnabled ? "Disable OCR Selection" : "Enable OCR Selection")

                            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { showingSettings.toggle() } }) {
                                Image(systemName: "gearshape")
                            }
                            .disabled(!isConnected)
                            .help("Settings")
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .padding(.top, 6)
                        .padding(.leading, 12)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .transition(.opacity)
                    }

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if showingSettings || showingConnections {
                Color.black.opacity(0.18)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showingSettings = false
                            showingConnections = false
                        }
                    }
            }

            // Both panels are mounted only while open. A closed panel used to sit off-screen at
            // full cost: its Picker-heavy body was re-evaluated on every ContentView pass and it
            // leaked SwiftUI observation state each time. Survivable settings state lives in
            // `settingsPanelModel`; the connections list comes from `KVMDeviceManager`.
            if showingSettings {
                WebUISettingsPanel(isPresented: $showingSettings, model: settingsPanelModel)
                    .frame(width: 360)
                    .transition(.move(edge: .trailing))
            }

            if showingConnections {
                VStack(spacing: 0) {
                    ConnectionsPopoverView(
                        selectedDevice: $selectedDevice,
                        isConnected: isConnected,
                        isScanning: kvmDeviceManager.isScanning,
                        devices: kvmDeviceManager.availableDevices,
                        connectedDeviceName: kvmDeviceManager.connectedDevice?.name,
                        videoSize: webRTCManager.videoSize,
                        onScan: {
                            kvmDeviceManager.scanForDevices()
                        },
                        onManualConnect: {
                            showingManualConnect = true
                        },
                        onToggleConnection: {
                            toggleConnection()
                        },
                        onForgetSelectedDevice: {
                            guard let device = selectedDevice else { return }
                            guard device.id.hasPrefix("saved-") else { return }
                            kvmDeviceManager.forgetDevice(device)
                            selectedDevice = nil
                        }
                    )
                    .frame(width: 360)
                    .background(.ultraThinMaterial)
                    .padding(.top, 8)

                    Spacer(minLength: 0)
                }
                .frame(maxHeight: .infinity)
                .transition(.move(edge: .trailing))
            }
        }
        // The slide-in/out is driven by these container animations plus each panel's transition,
        // which also covers call sites that flip the flags without `withAnimation`.
        .animation(.easeInOut(duration: 0.2), value: showingSettings)
        .animation(.easeInOut(duration: 0.2), value: showingConnections)
        .background(WindowAspectRatioSetter(videoSize: webRTCManager.videoSize))
        .background(WindowTitleTelemetryHost(titlePrefix: windowTitlePrefix, titleSuffix: windowTitleSuffix))
        .background(WindowReferenceSetter(window: $windowRef))
        .preferredColorScheme(preferredColorScheme)
        .onAppear {
            applyAppAppearance()
            inputManager.setup(with: webRTCManager)
            inputManager.setGLKVMClient(kvmDeviceManager.glkvmClient)

            updateInputCaptureForUIOverlays()

            if !didAutoOpenConnections, !isConnected {
                didAutoOpenConnections = true
                showingConnections = true
            }
        }
        .onChange(of: showingSettings) { _, _ in
            updateInputCaptureForUIOverlays()
        }
        .onChange(of: showingConnections) { _, _ in
            updateInputCaptureForUIOverlays()
        }
        .onChange(of: windowRef) { _, newValue in
            isFullscreen = newValue?.styleMask.contains(.fullScreen) ?? false
            showFullscreenControls = false
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { note in
            guard let window = note.object as? NSWindow else { return }
            guard windowRef === window else { return }
            isFullscreen = true
            showFullscreenControls = false
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { note in
            guard let window = note.object as? NSWindow else { return }
            guard windowRef === window else { return }
            isFullscreen = false
            showFullscreenControls = false
        }
        .onReceive(kvmDeviceManager.$glkvmClient) { client in
            inputManager.setGLKVMClient(client)
        }
        .onReceive(kvmDeviceManager.$connectedDevice) { device in
            Task { @MainActor in
                if let device {
                    suppressDeviceAutoConnect = true
                    selectedDevice = device
                    isConnected = true
                    DispatchQueue.main.async {
                        suppressDeviceAutoConnect = false
                    }
                } else {
                    isConnected = false
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .overlookToggleCopyMode)) { _ in
            Task { @MainActor in
                isOCRModeEnabled.toggle()
            }
        }
        .onChange(of: appAppearance) { _, _ in
            applyAppAppearance()
        }
        .sheet(isPresented: $isShowingOCRResult) {
            OCRResultView(selectedText: $selectedText)
        }
        .sheet(isPresented: $showingManualConnect) {
            ManualConnectSheet(
                isPresented: $showingManualConnect,
                hostPort: $manualHostPort,
                port: $manualPort,
                password: $manualPassword,
                savePassword: $manualSavePassword,
                onConnect: { password in
                    manualConnect(password: password)
                }
            )
        }
        .sheet(isPresented: $showingPasswordPrompt) {
            PasswordPromptSheet(
                isPresented: $showingPasswordPrompt,
                password: $pendingPassword,
                savePassword: $pendingSavePassword,
                onCancel: {
                    pendingPasswordDevice = nil
                },
                onConnect: { password in
                    if let device = pendingPasswordDevice {
                        connectToDevice(device, password: password, savePassword: pendingSavePassword)
                    }
                    pendingPasswordDevice = nil
                }
            )
        }
        .alert(
            "Connection Failed",
            isPresented: Binding(
                get: { connectionErrorMessage != nil },
                set: { if !$0 { connectionErrorMessage = nil } }
            )
        ) {
            Button("OK") {
                connectionErrorMessage = nil
            }
        } message: {
            Text(connectionErrorMessage ?? "")
        }
        .alert(
            "Certificate Changed",
            isPresented: Binding(
                get: { certificatePrompt != nil },
                set: { if !$0 { certificatePrompt = nil } }
            ),
            presenting: certificatePrompt
        ) { prompt in
            Button("Cancel", role: .cancel) {
                certificatePrompt = nil
            }
            Button("Trust New Certificate", role: .destructive) {
                kvmDeviceManager.trustNewCertificate(host: prompt.host, port: prompt.port)
                certificatePrompt = nil
                connectToDevice(prompt.device, password: prompt.password, savePassword: prompt.savePassword)
            }
        } message: { prompt in
            Text(prompt.message)
        }
        .toolbar {
            if isFullscreen == false {
                ToolbarItemGroup(placement: .automatic) {
                    Button(action: { showingConnections.toggle() }) {
                        Image(systemName: "personalhotspot")
                    }
                    .help("Connections")

                    Button(action: { fitWindowToGuest() }) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }
                    .disabled(webRTCManager.videoSize == nil)
                    .help("Fit window to guest")

                    Button(action: { toggleOCR() }) {
                        Image(systemName: isOCRModeEnabled ? "text.viewfinder" : "doc.text")
                    }
                    .disabled(!isConnected)
                    .help(isOCRModeEnabled ? "Disable OCR Selection" : "Enable OCR Selection")

                    Button(action: { withAnimation(.easeInOut(duration: 0.2)) { showingSettings.toggle() } }) {
                        Image(systemName: "gearshape")
                    }
                    .disabled(!isConnected)
                    .help("Settings")
                }
            }
        }
    }

    private func connectToDevice(_ device: KVMDevice, password: String? = nil, savePassword: Bool = false) {
        Task {
            do {
                let connectedDevice = try await kvmDeviceManager.connectToDevice(
                    device,
                    password: password,
                    savePassword: savePassword
                )
                await MainActor.run {
                    suppressDeviceAutoConnect = true
                    selectedDevice = connectedDevice
                    isConnected = true
                    showingConnections = false
                }
                DispatchQueue.main.async {
                    suppressDeviceAutoConnect = false
                }

                if let client = kvmDeviceManager.glkvmClient {
                    await MainActor.run {
                        inputManager.setGLKVMClient(client)
                        inputManager.startFullInputCapture()
                    }
                    try? await client.setHidConnected(true)
                }

 #if canImport(WebRTC)
                do {
                    try await webRTCManager.connect(to: connectedDevice)
                } catch WebRTCError.superseded {
                    // The operator's own later action replaced this attempt; nothing to report.
                } catch {
                    print("WebRTC connect failed (API is still connected): \(error)")
                }
 #endif
            } catch {
                if let kvmError = error as? KVMError, kvmError == .authenticationFailed {
                    await MainActor.run {
                        pendingPasswordDevice = device
                        showingPasswordPrompt = true
                    }
                } else if let kvmError = error as? KVMError,
                          case .certificateChanged(let host, let port, let fingerprint) = kvmError {
                    await MainActor.run {
                        isConnected = false
                        certificatePrompt = CertificateChangePrompt(
                            device: device,
                            host: host,
                            port: port,
                            fingerprint: fingerprint,
                            password: password,
                            savePassword: savePassword
                        )
                    }
                } else {
                    print("Failed to connect: \(error)")
                    await MainActor.run {
                        isConnected = false
                        connectionErrorMessage = describeConnectionError(error)
                    }
                }
                return
            }
        }
    }

    private func manualConnect(password submittedPassword: String) {
        let trimmed = manualHostPort.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        var host = trimmed
        var portString = manualPort.trimmingCharacters(in: .whitespacesAndNewlines)

        if let schemeRange = host.range(of: "://") {
            host = String(host[schemeRange.upperBound...])
        }

        if let colonIndex = host.lastIndex(of: ":") {
            let maybeHost = String(host[..<colonIndex])
            let maybePort = String(host[host.index(after: colonIndex)...])
            if !maybeHost.isEmpty, !maybePort.isEmpty {
                host = maybeHost
                portString = maybePort
            }
        }

        let port = Int(portString) ?? 443
        let device = kvmDeviceManager.addManualDevice(host: host, port: port, type: .glinetComet)

        suppressDeviceAutoConnect = true
        selectedDevice = device
        DispatchQueue.main.async {
            suppressDeviceAutoConnect = false
        }

        let password = submittedPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        connectToDevice(device, password: password.isEmpty ? nil : password, savePassword: manualSavePassword)
    }

    private func describeConnectionError(_ error: Error) -> String {
        if let describable = error as? CustomStringConvertible {
            return describable.description
        }
        return error.localizedDescription
    }

    private func toggleConnection() {
        if isConnected {
            webRTCManager.disconnect()

            let client = kvmDeviceManager.glkvmClient
            Task {
                try? await client?.setHidConnected(false)
            }

            kvmDeviceManager.disconnectFromDevice()
            inputManager.setGLKVMClient(nil)
            inputManager.stopFullInputCapture()
            isConnected = false
            showingConnections = true
        } else if let device = selectedDevice {
            connectToDevice(device)
        }
    }
    
    @MainActor
    private func toggleOCR() {
        isOCRModeEnabled.toggle()
    }

    @MainActor
    private func fitWindowToGuest() {
        guard let videoSize = webRTCManager.videoSize,
              videoSize.width > 0,
              videoSize.height > 0 else { return }
        guard let window = windowRef ?? NSApp.keyWindow else { return }

        let currentFrame = window.frame
        let currentLayout = window.contentLayoutRect

        let deltaW = currentFrame.size.width - currentLayout.size.width
        let deltaH = currentFrame.size.height - currentLayout.size.height

        var desiredLayoutW = CGFloat(videoSize.width)
        var desiredLayoutH = CGFloat(videoSize.height)

        if let screen = window.screen ?? NSScreen.main {
            let maxLayoutW = max(100, screen.visibleFrame.size.width - deltaW)
            let maxLayoutH = max(100, screen.visibleFrame.size.height - deltaH)
            let scale = min(1.0, maxLayoutW / desiredLayoutW, maxLayoutH / desiredLayoutH)
            desiredLayoutW = floor(desiredLayoutW * scale)
            desiredLayoutH = floor(desiredLayoutH * scale)
        }

        var newFrame = currentFrame
        newFrame.size = NSSize(width: desiredLayoutW + deltaW, height: desiredLayoutH + deltaH)
        newFrame.origin.y += currentFrame.size.height - newFrame.size.height
        window.setFrame(newFrame, display: true, animate: true)
    }

    @MainActor
    private func updateInputCaptureForUIOverlays() {
        let overlayOpen = showingSettings || showingConnections

        if overlayOpen {
            if isInputCapturePausedForUI == false {
                pausedCaptureKeyboardWasEnabled = inputManager.isKeyboardCaptureEnabled
                pausedCaptureMouseWasEnabled = inputManager.isMouseCaptureEnabled

                if inputManager.isKeyboardCaptureEnabled {
                    inputManager.stopKeyboardCapture()
                }
                if inputManager.isMouseCaptureEnabled {
                    inputManager.stopMouseCapture()
                }

                isInputCapturePausedForUI = true
            }
            return
        }

        guard isInputCapturePausedForUI else { return }

        if isConnected {
            if let wasKeyboard = pausedCaptureKeyboardWasEnabled {
                if wasKeyboard {
                    inputManager.startKeyboardCapture()
                }
            }
            if let wasMouse = pausedCaptureMouseWasEnabled {
                if wasMouse {
                    inputManager.startMouseCapture()
                }
            }
        }

        pausedCaptureKeyboardWasEnabled = nil
        pausedCaptureMouseWasEnabled = nil
        isInputCapturePausedForUI = false
    }
}

/// A device presented a certificate other than the one pinned on first connection.
private struct CertificateChangePrompt: Identifiable {
    let device: KVMDevice
    let host: String
    let port: Int
    let fingerprint: String
    /// Password (and whether to save it) from the attempt that hit the mismatch, so the retry
    /// after trusting does not prompt again.
    let password: String?
    let savePassword: Bool

    var id: String { "\(host):\(port):\(fingerprint)" }

    var message: String {
        "\(host):\(port) presented a certificate that does not match the one recorded when you first connected.\n\n"
            + "New fingerprint (SHA-256):\n\(DeviceTrustStore.display(fingerprint))\n\n"
            + "If you reset or re-flashed the KVM, trust the new certificate. Otherwise stop here — the connection may be intercepted."
    }
}

private struct WindowReferenceSetter: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let w = nsView.window else { return }
        if window !== w {
            DispatchQueue.main.async {
                window = w
            }
        }
    }
}

private struct WindowAspectRatioSetter: NSViewRepresentable {
    let videoSize: CGSize?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let window = nsView.window else { return }

        if context.coordinator.didConfigureWindow == false {
            context.coordinator.didConfigureWindow = true
            let coordinator = context.coordinator
            DispatchQueue.main.async {
                window.titlebarAppearsTransparent = false
                window.styleMask.remove(.fullSizeContentView)
                coordinator.attach(to: window)
            }
        }

        guard let videoSize, videoSize.width > 0, videoSize.height > 0 else {
            if context.coordinator.lastAspect != nil {
                context.coordinator.lastAspect = nil
                context.coordinator.didInitialResizeForAspect = false
                context.coordinator.videoAspect = nil
            }
            return
        }

        let aspect = NSSize(width: videoSize.width, height: videoSize.height)
        if let last = context.coordinator.lastAspect {
            let dw = abs(last.width - aspect.width)
            let dh = abs(last.height - aspect.height)
            if dw < 1, dh < 1 {
                return
            }
        }

        context.coordinator.lastAspect = aspect
        context.coordinator.videoAspect = Double(aspect.width / aspect.height)

        if context.coordinator.didInitialResizeForAspect == false {
            context.coordinator.didInitialResizeForAspect = true

            let currentFrame = window.frame
            let currentLayout = window.contentLayoutRect.size
            let deltaH = currentFrame.size.height - currentLayout.height

            if currentLayout.width > 0 {
                let desiredLayoutHeight = currentLayout.width * (aspect.height / aspect.width)
                if desiredLayoutHeight.isFinite, desiredLayoutHeight > 0 {
                    var newFrame = currentFrame
                    newFrame.size.height = desiredLayoutHeight + deltaH
                    DispatchQueue.main.async {
                        window.setFrame(newFrame, display: true)
                    }
                }
            }
        }
    }

    final class Coordinator: NSObject {
        var lastAspect: NSSize?
        var didInitialResizeForAspect: Bool = false
        var didConfigureWindow: Bool = false

        weak var window: NSWindow?
        weak var forwardedDelegate: NSWindowDelegate?
        var videoAspect: Double?

        private var storedWindowedTitlebarAppearsTransparent: Bool?
        private var storedWindowedStyleMaskHadFullSizeContentView: Bool?
        private var storedWindowedTitleVisibility: NSWindow.TitleVisibility?
        private var storedWindowedToolbarIsVisible: Bool?

        func attach(to window: NSWindow) {
            if self.window === window {
                return
            }

            self.window = window
            forwardedDelegate = window.delegate
            window.delegate = self

            if storedWindowedTitlebarAppearsTransparent == nil {
                storedWindowedTitlebarAppearsTransparent = window.titlebarAppearsTransparent
                storedWindowedStyleMaskHadFullSizeContentView = window.styleMask.contains(.fullSizeContentView)
                storedWindowedTitleVisibility = window.titleVisibility
                storedWindowedToolbarIsVisible = window.toolbar?.isVisible
            }
        }

        private func applyFullscreenChrome(window: NSWindow) {
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.toolbar?.isVisible = false
            if #available(macOS 11.0, *) {
                window.titlebarSeparatorStyle = .none
            }
        }

        private func restoreWindowedChrome(window: NSWindow) {
            if let stored = storedWindowedTitlebarAppearsTransparent {
                window.titlebarAppearsTransparent = stored
            }
            if let hadFullSize = storedWindowedStyleMaskHadFullSizeContentView {
                if hadFullSize {
                    window.styleMask.insert(.fullSizeContentView)
                } else {
                    window.styleMask.remove(.fullSizeContentView)
                }
            }
            if let stored = storedWindowedTitleVisibility {
                window.titleVisibility = stored
            }
            if let stored = storedWindowedToolbarIsVisible {
                window.toolbar?.isVisible = stored
            }
            if #available(macOS 11.0, *) {
                window.titlebarSeparatorStyle = .automatic
            }
        }

        private func adjustFrameToVideoAspect(window: NSWindow) {
            guard let aspect = videoAspect, aspect.isFinite, aspect > 0 else { return }

            let currentFrame = window.frame
            let currentLayout = window.contentLayoutRect.size

            let deltaH = currentFrame.size.height - currentLayout.height

            guard currentLayout.width > 0 else { return }

            let desiredLayoutH = currentLayout.width / aspect
            guard desiredLayoutH.isFinite, desiredLayoutH > 0 else { return }

            var newFrame = currentFrame
            newFrame.size.height = desiredLayoutH + deltaH
            newFrame.origin.y += currentFrame.size.height - newFrame.size.height
            window.setFrame(newFrame, display: true, animate: false)
        }
    }
}

extension WindowAspectRatioSetter.Coordinator: NSWindowDelegate {
    override func responds(to aSelector: Selector!) -> Bool {
        if super.responds(to: aSelector) {
            return true
        }
        return forwardedDelegate?.responds(to: aSelector) ?? false
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        forwardedDelegate
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard let aspect = videoAspect else { return frameSize }

        let currentFrame = sender.frame.size
        let currentLayout = sender.contentLayoutRect.size

        let deltaW = currentFrame.width - currentLayout.width
        let deltaH = currentFrame.height - currentLayout.height

        let proposedLayoutW = frameSize.width - deltaW
        let proposedLayoutH = frameSize.height - deltaH

        guard proposedLayoutW > 0, proposedLayoutH > 0 else { return frameSize }

        let dw = abs(frameSize.width - currentFrame.width)
        let dh = abs(frameSize.height - currentFrame.height)

        let constrained: NSSize
        if dw >= dh {
            let desiredLayoutH = proposedLayoutW / aspect
            constrained = NSSize(width: frameSize.width, height: desiredLayoutH + deltaH)
        } else {
            let desiredLayoutW = proposedLayoutH * aspect
            constrained = NSSize(width: desiredLayoutW + deltaW, height: frameSize.height)
        }

        if let forwardedDelegate,
           forwardedDelegate.responds(to: #selector(NSWindowDelegate.windowWillResize(_:to:))) {
            return forwardedDelegate.windowWillResize?(sender, to: constrained) ?? constrained
        }

        return constrained
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else {
            forwardedDelegate?.windowDidEnterFullScreen?(notification)
            return
        }
        applyFullscreenChrome(window: window)
        forwardedDelegate?.windowDidEnterFullScreen?(notification)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else {
            forwardedDelegate?.windowDidExitFullScreen?(notification)
            return
        }
        restoreWindowedChrome(window: window)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.adjustFrameToVideoAspect(window: window)
        }

        forwardedDelegate?.windowDidExitFullScreen?(notification)
    }
}

/// Appends the live kbps/fps to the window title.
///
/// This is the only view in the window chrome that observes `StreamTelemetryModel`, so a stats
/// tick re-evaluates this leaf and writes the title — nothing above it.
private struct WindowTitleTelemetryHost: View {
    @EnvironmentObject private var telemetryModel: StreamTelemetryModel

    let titlePrefix: String
    let titleSuffix: String

    var body: some View {
        let telemetry = telemetryModel.snapshot
        let kbps = telemetry.videoKbps.map { "\($0) kbps" } ?? "— kbps"
        let fps = telemetry.videoFps.map { "\($0) fps dynamic" } ?? "— fps dynamic"
        WindowTitleSetter(title: "\(titlePrefix) / \(kbps) / \(fps)\(titleSuffix)")
    }
}

private struct WindowTitleSetter: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let window = nsView.window else { return }
        DispatchQueue.main.async {
            if window.title != title {
                window.title = title
            }
            // Compare before writing: an unconditional set here relaid out the titlebar on
            // every pass.
            if window.styleMask.contains(.fullScreen) == false, window.titleVisibility != .visible {
                window.titleVisibility = .visible
            }
        }
    }
}

struct ConnectionsPopoverView: View {
    @Binding var selectedDevice: KVMDevice?

    let isConnected: Bool
    let isScanning: Bool
    let devices: [KVMDevice]
    let connectedDeviceName: String?

    /// Guest resolution, forwarded to the stats section. Telemetry itself is not passed in:
    /// `HIDRoundTripLabel`, `SessionHistoryLabel` and `StreamStatsSection` observe it themselves, so this body
    /// does not re-evaluate on every tick.
    let videoSize: CGSize?

    let onScan: () -> Void
    let onManualConnect: () -> Void
    let onToggleConnection: () -> Void
    let onForgetSelectedDevice: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connections")
                .font(.headline)

            Picker("Device", selection: $selectedDevice) {
                Text("Select Device").tag(nil as KVMDevice?)
                ForEach(devices) { device in
                    Text(device.name).tag(device as KVMDevice?)
                }
            }
            .frame(maxWidth: .infinity)

            // Actions on the selected device. Selecting a device does not connect to it; this
            // row makes that second step visible (it used to be an unlabeled header icon).
            HStack {
                Button(isConnected ? "Disconnect" : "Connect") { onToggleConnection() }
                    .disabled(!isConnected && selectedDevice == nil)

                Button("Forget") { onForgetSelectedDevice() }
                    .disabled(isConnected || selectedDevice?.id.hasPrefix("saved-") != true)

                Spacer()
            }

            Divider()

            // Ways to add devices to the list.
            HStack {
                Button("Scan") { onScan() }
                    .disabled(isScanning)

                Button("Manual Connect…") { onManualConnect() }

                Spacer()

                if isScanning {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text(connectedDeviceName ?? (selectedDevice?.name ?? "No Device"))
                    .font(.caption)

                HStack {
                    Text(isConnected ? "Connected" : "Disconnected")
                        .font(.caption)
                        .foregroundColor(isConnected ? .green : .red)

                    Spacer()

                    HIDRoundTripLabel()
                        .foregroundColor(.secondary)
                }

                SessionHistoryLabel()
            }

            StreamStatsSection(videoSize: videoSize)
        }
        .padding(14)
    }
}

#Preview {
    let webRTCManager = WebRTCManager()
    return ContentView()
        .environmentObject(webRTCManager)
        .environmentObject(webRTCManager.telemetry)
        .environmentObject(InputManager())
        .environmentObject(OCRManager())
        .environmentObject(KVMDeviceManager())
}
