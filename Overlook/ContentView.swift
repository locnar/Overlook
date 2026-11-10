import SwiftUI
import Foundation
import AppKit

struct ContentView: View {
    @EnvironmentObject var webRTCManager: WebRTCManager
    @EnvironmentObject var inputManager: InputManager
    @EnvironmentObject var ocrManager: OCRManager
    @EnvironmentObject var kvmDeviceManager: KVMDeviceManager
    @EnvironmentObject var connection: SessionConnection
    @EnvironmentObject var captureManager: CaptureManager
    @EnvironmentObject private var session: ConsoleSession
    
    /// The device chosen in the Connections panel, held by address: see `ConnectionsPopoverView`.
    @State private var selectedAddress: DeviceAddress?
    @State private var isConnected = false
    @State private var isOCRModeEnabled = false
    @State private var isShowingOCRResult = false
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
    /// The Edit… sheet's state while it is open.
    @State private var editingDevice: DeviceEditModel?
    /// "This is <device>": a new address whose certificate matches a saved device's.
    @State private var linkPrompt: DeviceLinkPrompt?

    @State private var didAutoOpenConnections = false

    /// The width the panels sit in. Read through a preference key rather than by wrapping the
    /// body in a `GeometryReader`, which would change the root layout.
    @State private var containerWidth: CGFloat = 0

    /// Which trailing-edge panel is open. Owned by the app so the View menu can drive it, and a
    /// single optional so two panels cannot be open at once.
    @EnvironmentObject private var panels: PanelPresentation

    /// Read-only views onto `panels`, so the places that only *ask* whether a panel is up read
    /// as before. Everything that *changes* one goes through `panels`.
    private var showingSettings: Bool { panels.isOpen(.settings) }
    private var showingConnections: Bool { panels.isOpen(.connections) }
    private var showingLog: Bool { panels.isOpen(.log) }

    /// The catalog's current entry for the chosen device. The connected device's entry when the
    /// address chosen is no longer any device's: the Edit sheet can remove the address a session
    /// is connected through, and the session carries on.
    private var selectedDevice: KVMDevice? {
        if let address = selectedAddress, let device = kvmDeviceManager.device(at: address) {
            return device
        }
        guard let connected = connection.connectedDevice else { return nil }
        return kvmDeviceManager.availableDevices.first { $0.id == connected.id }
    }

    private var availablePanelWidth: Double? {
        containerWidth > 0 ? Double(containerWidth) : nil
    }

    /// Clamped here, not only when the operator drags. A width saved on a wide display — or one
    /// left behind after the window was made narrower — would otherwise render a panel wider than
    /// the window, and since the resize handle sits on its leading edge, the handle itself is the
    /// part that gets clipped away. There would be no way back short of deleting the default.
    private var panelWidth: CGFloat {
        CGFloat(PanelPresentation.clampWidth(panels.width, available: availablePanelWidth))
    }

    /// The settings panel is unmounted while closed, so its survivable state (loaded config,
    /// keymaps, streamer state, section expansion, drafts) is owned here instead.
    @StateObject private var settingsPanelModel = WebUISettingsPanelModel()

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
    /// state, mouse mode. The live HID RTT / kbps / fps part is inserted by
    /// `WindowTitleTelemetryHost`, which observes `StreamTelemetryModel` on its own, so a stats
    /// tick never re-evaluates this view's body.
    private var windowTitlePrefix: String {
        Self.windowTitlePrefix(connectedDevice: connection.connectedDevice, selectedDevice: selectedDevice, isConnected: isConnected)
    }

    /// The device's name, not its type: with several windows open the title is what tells them
    /// apart (in the Window menu and Mission Control too), and every one of them is a GLKVM.
    /// - Connected: "Overlook - <device> / Connected".
    /// - Disconnected with a device chosen in this window: "Overlook - <device> / Disconnected".
    /// - Nothing chosen: "Overlook".
    static func windowTitlePrefix(connectedDevice: KVMDevice?, selectedDevice: KVMDevice?, isConnected: Bool) -> String {
        if isConnected, let device = connectedDevice ?? selectedDevice {
            return "Overlook - \(device.displayName) / Connected"
        }
        if let device = selectedDevice {
            return "Overlook - \(device.displayName) / Disconnected"
        }
        return "Overlook"
    }

    /// The whole title. The live HID round trip, kbps and fps follow the prefix only while
    /// connected; a disconnected window has no numbers to show.
    static func windowTitle(prefix: String, suffix: String, telemetry: StreamTelemetry, isConnected: Bool) -> String {
        guard isConnected else { return prefix + suffix }
        // The HID round trip takes the slot the guest resolution used to have: it is the number
        // that says whether typing will feel right, and the resolution is in the Connections panel.
        let rtt = telemetry.hidRoundTripMs.map { "\($0) ms RTT" } ?? "— ms RTT"
        let kbps = telemetry.videoKbps.map { "\($0) kbps" } ?? "— kbps"
        let fps = telemetry.videoFps.map { "\($0) fps dynamic" } ?? "— fps dynamic"
        return "\(prefix) / \(rtt) / \(kbps) / \(fps)\(suffix)"
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
                        guard let device = connection.connectedDevice else { return }
                        Task { @MainActor in
                            await webRTCManager.reconnect(to: device, reason: "Reconnect button")
                        }
                    }
                )
                .ignoresSafeArea()
                .allowsHitTesting(!panels.isAnyOpen)
            } else {
                VideoSurfaceView(
                    isOCRModeEnabled: $isOCRModeEnabled,
                    selectedText: $selectedText,
                    isShowingOCRResult: $isShowingOCRResult,
                    onReconnect: {
                        guard let device = connection.connectedDevice else { return }
                        Task { @MainActor in
                            await webRTCManager.reconnect(to: device, reason: "Reconnect button")
                        }
                    }
                )
                .allowsHitTesting(!panels.isAnyOpen)
            }

            if isFullscreen && !panels.isAnyOpen {
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
                            Button(action: { togglePanel(.connections) }) {
                                Image(systemName: "personalhotspot")
                            }
                            .help("Connections")

                            Button(action: { fitWindowToGuest() }) {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                            }
                            .disabled(webRTCManager.videoSize == nil)
                            .help("Fit window to guest")

                            Divider()
                                .frame(height: 18)

                            CaptureRegionToggle(isConnected: isConnected)

                            ScreenshotButton(isConnected: isConnected)

                            RecordingButton(isConnected: isConnected)

                            RecordingModePicker()

                            Divider()
                                .frame(height: 18)

                            Button(action: { toggleOCR() }) {
                                Image(systemName: isOCRModeEnabled
                                      ? "text.viewfinder"
                                      : "rectangle.and.text.magnifyingglass")
                            }
                            .disabled(!isConnected)
                            .help(isOCRModeEnabled ? "Disable OCR Selection" : "Enable OCR Selection")

                            Divider()
                                .frame(height: 18)

                            ConnectionLogToolbarButton(action: { togglePanel(.log) })

                            Button(action: { togglePanel(.settings) }) {
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

            // Capture feedback over the video: a flash per screenshot, a recording badge top-right
            // (the toolbar is hidden in fullscreen, so this is the indicator there), and the
            // saved/failed toast bottom-right. All sit under the panels and their dimming layer.
            ScreenshotFlash(trigger: captureManager.screenshotFlashCount)

            if captureManager.isRecording, let mode = captureManager.activeRecordingMode {
                RecordingBadge(clock: captureManager.clock, mode: mode, isCropped: captureManager.activeRecordingRegion != nil)
                    .padding(.top, isFullscreen ? 10 : 12)
                    .padding(.trailing, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .transition(.opacity)
            }

            if let notice = captureManager.notice {
                CaptureNoticeView(
                    notice: notice,
                    onShow: { url in captureManager.revealInFinder(url) },
                    onDismiss: { captureManager.dismissNotice() }
                )
                .padding(14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if panels.isAnyOpen {
                Color.black.opacity(0.18)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            panels.close()
                        }
                    }
            }

            // Both panels are mounted only while open. A closed panel used to sit off-screen at
            // full cost: its Picker-heavy body was re-evaluated on every ContentView pass and it
            // leaked SwiftUI observation state each time. Survivable settings state lives in
            // `settingsPanelModel`; the connections list comes from `KVMDeviceManager`.
            if showingSettings {
                WebUISettingsPanel(isPresented: panels.isPresented(.settings), model: settingsPanelModel)
                    .frame(width: panelWidth)
                    .resizablePanel(availableWidth: availablePanelWidth)
                    .transition(.move(edge: .trailing))
            }

            if showingLog {
                ConnectionLogPanel(isPresented: panels.isPresented(.log))
                    .frame(width: panelWidth)
                    .resizablePanel(availableWidth: availablePanelWidth)
                    .transition(.move(edge: .trailing))
            }

            if showingConnections {
                VStack(spacing: 0) {
                    ConnectionsPopoverView(
                        selection: $selectedAddress,
                        selectedDevice: selectedDevice,
                        isConnected: isConnected,
                        scanRow: ScanRowState(isScanning: kvmDeviceManager.isScanning, ranges: kvmDeviceManager.scanRanges),
                        devices: kvmDeviceManager.availableDevices,
                        connectedDeviceName: connection.connectedDevice?.displayName,
                        connectedVia: connection.connectedDevice?.address,
                        videoSize: webRTCManager.videoSize,
                        onScan: {
                            kvmDeviceManager.toggleScan()
                        },
                        onManualConnect: {
                            showingManualConnect = true
                        },
                        onToggleConnection: {
                            toggleConnection()
                        },
                        onConnectVia: { address in
                            guard let device = selectedDevice else { return }
                            connectToDevice(ConnectVia.pick(address, of: device, in: kvmDeviceManager))
                        },
                        onEditSelectedDevice: {
                            guard let device = selectedDevice else { return }
                            let catalog = kvmDeviceManager
                            editingDevice = DeviceEditModel(device: device) { address in
                                catalog.owner(of: address, excludingID: device.id)
                            }
                        },
                        onForgetSelectedDevice: {
                            guard let device = selectedDevice else { return }
                            guard device.id.hasPrefix("saved-") else { return }
                            // Forgetting a device another window is connected to would pull it out
                            // from under that session; show where it is open instead.
                            if let other = session.registry?.session(showing: device, excluding: session) {
                                other.bringWindowForward()
                                return
                            }
                            kvmDeviceManager.forgetDevice(device)
                            selectedAddress = nil
                        },
                        onOpenLog: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                panels.show(.log)
                            }
                        }
                    )
                    .frame(width: panelWidth)
                    .background(.ultraThinMaterial)
                    .padding(.top, 8)

                    Spacer(minLength: 0)
                }
                .frame(maxHeight: .infinity)
                // On the container, not the popover: the handle runs the full height of the
                // strip rather than stopping where the Connections card ends.
                .resizablePanel(availableWidth: availablePanelWidth)
                .transition(.move(edge: .trailing))
            }
        }
        // The slide-in/out is driven by these container animations plus each panel's transition,
        // which also covers call sites that flip the flags without `withAnimation`.
        .animation(.easeInOut(duration: 0.2), value: panels.openPanel)
        .animation(.easeInOut(duration: 0.2), value: captureManager.notice)
        .animation(.easeInOut(duration: 0.2), value: captureManager.isRecording)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: PanelContainerWidthKey.self, value: proxy.size.width)
            }
        )
        .onPreferenceChange(PanelContainerWidthKey.self) { width in
            containerWidth = width
        }
        .background(WindowAspectRatioSetter(videoSize: webRTCManager.videoSize))
        .background(WindowTitleTelemetryHost(titlePrefix: windowTitlePrefix, titleSuffix: windowTitleSuffix, isConnected: isConnected))
        .background(WindowReferenceSetter(window: $windowRef))
        .preferredColorScheme(preferredColorScheme)
        .onAppear {
            applyAppAppearance()
            inputManager.setGLKVMClient(connection.glkvmClient)

            updateInputCaptureForUIOverlays()

            if !didAutoOpenConnections, !isConnected {
                didAutoOpenConnections = true
                panels.show(.connections)
            }
        }
        .onChange(of: panels.openPanel) { _, _ in
            updateInputCaptureForUIOverlays()
        }
        .onChange(of: captureManager.isSelectingRegion) { _, selecting in
            if selecting {
                // The drag needs the video: close anything covering it and leave OCR mode.
                isOCRModeEnabled = false
                withAnimation(.easeInOut(duration: 0.2)) {
                    panels.close()
                }
            }
            updateInputCaptureForUIOverlays()
        }
        .onChange(of: isOCRModeEnabled) { _, enabled in
            if enabled {
                captureManager.cancelRegionSelection()
            }
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
        .onReceive(connection.$glkvmClient) { client in
            inputManager.setGLKVMClient(client)
        }
        .onReceive(connection.$connectedDevice) { device in
            Task { @MainActor in
                if let device {
                    selectedAddress = device.address
                    isConnected = true
                } else {
                    isConnected = false
                }
            }
        }
        .onReceive(session.copyModeRequests) { _ in
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
        .sheet(item: $editingDevice) { model in
            DeviceEditSheet(
                model: model,
                onSave: { nickname, addresses in
                    // The entry as it is now: a connect may have saved it while the sheet was open.
                    let current = kvmDeviceManager.availableDevices.first { $0.id == model.device.id }
                        ?? kvmDeviceManager.device(at: model.device.address)
                        ?? model.device
                    if let saved = kvmDeviceManager.saveEdits(of: current, nickname: nickname, addresses: addresses) {
                        selectedAddress = saved.address
                    }
                    editingDevice = nil
                },
                onCancel: {
                    editingDevice = nil
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
            linkPrompt?.title ?? "",
            isPresented: Binding(
                get: { linkPrompt != nil },
                set: { if !$0 { linkPrompt = nil } }
            ),
            presenting: linkPrompt
        ) { prompt in
            Button(DeviceLinkPrompt.keepTitle, role: .cancel) {
                prompt.answer(.keepSeparate, catalog: kvmDeviceManager)
                linkPrompt = nil
            }
            Button(DeviceLinkPrompt.addTitle) {
                if let linked = prompt.answer(.addAddress, catalog: kvmDeviceManager) {
                    selectedAddress = linked.address
                }
                linkPrompt = nil
            }
        } message: { prompt in
            Text(prompt.message)
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
        // Four groups: the session (where the video comes from, window size), capture, OCR, and
        // tools (log, settings). On macOS 26 each group is one glass pill and a pop-up button
        // always gets a pill of its own, so the groups are fenced with fixed spacers — the
        // capture pills (buttons, mode pop-up, elapsed time) then sit closer to each other than
        // to the neighbours. OCR is alone in the middle: it records nothing, so it does not
        // belong with capture, and it acts on the video rather than the app, so it does not
        // belong with tools.
        .toolbar {
            if isFullscreen == false {
                ToolbarItemGroup(placement: .automatic) {
                    Button(action: { togglePanel(.connections) }) {
                        Image(systemName: "personalhotspot")
                    }
                    .help("Connections")

                    Button(action: { fitWindowToGuest() }) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }
                    .disabled(webRTCManager.videoSize == nil)
                    .help("Fit window to guest")
                }

                if #available(macOS 26.0, *) {
                    ToolbarSpacer(.fixed)
                }

                // Region first: it frames what the next two capture; the mode pop-up belongs to
                // the record button, so it stays next to it.
                ToolbarItemGroup(placement: .automatic) {
                    CaptureRegionToggle(isConnected: isConnected)

                    ScreenshotButton(isConnected: isConnected)

                    RecordingButton(isConnected: isConnected)

                    RecordingModePicker()

                    if captureManager.isRecording {
                        RecordingElapsedLabel(clock: captureManager.clock)
                    }
                }

                if #available(macOS 26.0, *) {
                    ToolbarSpacer(.fixed)
                }

                // OCR gets an island of its own. It belongs to neither neighbour: it records
                // nothing, and it acts on the video rather than on the app.
                ToolbarItemGroup(placement: .automatic) {
                    Button(action: { toggleOCR() }) {
                        Image(systemName: isOCRModeEnabled
                              ? "text.viewfinder"
                              : "rectangle.and.text.magnifyingglass")
                    }
                    .disabled(!isConnected)
                    .help(isOCRModeEnabled ? "Disable OCR Selection" : "Enable OCR Selection")
                }

                if #available(macOS 26.0, *) {
                    ToolbarSpacer(.fixed)
                }

                ToolbarItemGroup(placement: .automatic) {
                    ConnectionLogToolbarButton(action: { togglePanel(.log) })

                    Button(action: { togglePanel(.settings) }) {
                        Image(systemName: "gearshape")
                    }
                    .disabled(!isConnected)
                    .help("Settings")
                }
            }
        }
    }

    /// The steps are the session's (`ConsoleSession.connect`), shared with the menu-bar agent;
    /// what this window adds is how each outcome is shown.
    private func connectToDevice(_ device: KVMDevice, password: String? = nil, savePassword: Bool = false) {
        // Before the connect saves it: the saved device the address belonged to, if any.
        let savedBefore = kvmDeviceManager.savedDevice(containing: device.address)
        Task { @MainActor in
            let outcome = await session.connect(to: device, password: password, savePassword: savePassword) { connected in
                selectedAddress = connected.address
                isConnected = true
                panels.closeIfOpen(.connections)
            }

            switch outcome {
            case .connected(let connected, _):
                // A stream that failed to come up is in the log; the API connection stands.
                linkPrompt = DeviceLinkPrompt.after(
                    connecting: connected,
                    savedBefore: savedBefore,
                    catalog: kvmDeviceManager
                )
            case .needsPassword:
                pendingPasswordDevice = device
                showingPasswordPrompt = true
            case .certificateChanged(let host, let port, let fingerprint):
                isConnected = false
                certificatePrompt = CertificateChangePrompt(
                    device: device,
                    host: host,
                    port: port,
                    fingerprint: fingerprint,
                    password: password,
                    savePassword: savePassword
                )
            case .failed(let error):
                isConnected = false
                connectionErrorMessage = ConnectVia.failureMessage(
                    address: device.address,
                    deviceHasOtherAddresses: device.addresses.contains { $0 != device.address },
                    error: error
                )
            case .openElsewhere(let other):
                // One window per device: this one stays disconnected.
                other.bringWindowForward()
            case .cancelled:
                break
            }
        }
    }

    private func manualConnect(password submittedPassword: String) {
        let address: DeviceAddress
        switch AddressInput.parse(manualHostPort, port: manualPort) {
        case .success(let parsed):
            address = parsed
        case .failure(let problem):
            connectionErrorMessage = problem.message
            return
        }

        // An address of a saved device connects as that device; any other gets a manual entry.
        let device = kvmDeviceManager.device(forTyped: address)

        selectedAddress = device.address

        let password = submittedPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        connectToDevice(device, password: password.isEmpty ? nil : password, savePassword: manualSavePassword)
    }

    private func toggleConnection() {
        if isConnected {
            session.disconnect()
            isConnected = false
            panels.show(.connections)
        } else if let device = selectedDevice {
            // The device's last-used address, or its first; one attempt, no fallback.
            connectToDevice(ConnectVia.plainConnect(device))
        }
    }
    
    @MainActor
    private func toggleOCR() {
        isOCRModeEnabled.toggle()
    }

    /// Only one panel can be open at a time — `PanelPresentation` holds a single optional, so
    /// that is a property of the state rather than something each button has to arrange.
    @MainActor
    private func togglePanel(_ panel: PanelPresentation.Panel) {
        withAnimation(.easeInOut(duration: 0.2)) {
            panels.toggle(panel)
        }
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
        // Drawing a capture region counts as an overlay: the drag must not reach the target, and
        // Esc has to reach the app.
        let overlayOpen = panels.isAnyOpen || captureManager.isSelectingRegion

        if overlayOpen {
            if panels.isInputCapturePaused == false {
                panels.pausedCaptureKeyboardWasEnabled = inputManager.isKeyboardCaptureEnabled
                panels.pausedCaptureMouseWasEnabled = inputManager.isMouseCaptureEnabled

                if inputManager.isKeyboardCaptureEnabled {
                    inputManager.stopKeyboardCapture()
                }
                if inputManager.isMouseCaptureEnabled {
                    inputManager.stopMouseCapture()
                }

                panels.isInputCapturePaused = true
            }
            return
        }

        guard panels.isInputCapturePaused else { return }

        if isConnected {
            if panels.pausedCaptureKeyboardWasEnabled == true {
                inputManager.startKeyboardCapture()
            }
            if panels.pausedCaptureMouseWasEnabled == true {
                inputManager.startMouseCapture()
            }
        }

        panels.pausedCaptureKeyboardWasEnabled = nil
        panels.pausedCaptureMouseWasEnabled = nil
        panels.isInputCapturePaused = false
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

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let window = nsView.window else { return }

        if context.coordinator.didConfigureWindow == false {
            context.coordinator.didConfigureWindow = true
            let coordinator = context.coordinator
            Task { @MainActor in
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

    /// Keeps resizes to the video's aspect ratio and swaps the chrome in and out of fullscreen,
    /// through the window's `WindowDelegateInterposer`, which `ConsoleWindowAttachment` registers
    /// with too.
    @MainActor
    final class Coordinator: NSObject {
        var lastAspect: NSSize?
        var didInitialResizeForAspect: Bool = false
        var didConfigureWindow: Bool = false

        weak var window: NSWindow?
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
            WindowDelegateInterposer.install(on: window).register(self)

            if storedWindowedTitlebarAppearsTransparent == nil {
                storedWindowedTitlebarAppearsTransparent = window.titlebarAppearsTransparent
                storedWindowedStyleMaskHadFullSizeContentView = window.styleMask.contains(.fullSizeContentView)
                storedWindowedTitleVisibility = window.titleVisibility
                storedWindowedToolbarIsVisible = window.toolbar?.isVisible
            }
        }

        /// The view has gone from the window; the delegate calls stop with it.
        func detach() {
            guard let window else { return }
            WindowDelegateInterposer.installed(on: window)?.unregister(self)
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

extension WindowAspectRatioSetter.Coordinator: WindowDelegateParticipant {
    func window(_ sender: NSWindow, willResizeTo frameSize: NSSize) -> NSSize {
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

        // SwiftUI's own delegate is asked after this, with the constrained size, by the interposer.
        return constrained
    }

    func windowDidEnterFullScreen(for window: NSWindow) {
        applyFullscreenChrome(window: window)
    }

    func windowDidExitFullScreen(for window: NSWindow) {
        restoreWindowedChrome(window: window)

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.adjustFrameToVideoAspect(window: window)
        }
    }
}

/// Appends the live kbps/fps to the window title while connected.
///
/// This is the only view in the window chrome that observes `StreamTelemetryModel`, so a stats
/// tick re-evaluates this leaf and writes the title — nothing above it.
private struct WindowTitleTelemetryHost: View {
    @EnvironmentObject private var telemetryModel: StreamTelemetryModel

    let titlePrefix: String
    let titleSuffix: String
    let isConnected: Bool

    var body: some View {
        WindowTitleSetter(title: ContentView.windowTitle(
            prefix: titlePrefix,
            suffix: titleSuffix,
            telemetry: telemetryModel.snapshot,
            isConnected: isConnected
        ))
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

/// The Connections panel's scan row, worked out from the catalog's scan state: the button's label
/// and whether it can be pressed, and the caption under the row.
struct ScanRowState: Equatable {
    static let scanTitle = "Scan"
    static let cancelTitle = "Cancel scan"

    let isScanning: Bool
    /// The networks the scan sweeps, as its start is logged (`KVMDeviceManager.scanRanges`).
    let ranges: [String]

    /// Scan while idle; Cancel scan while scanning, which stops the scan.
    var buttonTitle: String { isScanning ? Self.cancelTitle : Self.scanTitle }

    /// Pressable in both states: Scan starts a scan, Cancel scan stops it.
    var isButtonEnabled: Bool { true }

    /// What is being scanned, while a scan runs; nil when idle.
    var caption: String? {
        guard isScanning else { return nil }
        guard !ranges.isEmpty else { return "Scanning Bonjour services only…" }
        return "Scanning \(ranges.joined(separator: ", "))…"
    }
}

struct ConnectionsPopoverView: View {
    /// The chosen device, by address rather than as the list entry itself. Connecting saves a
    /// device under a new id (`manual-…` or `scanned-…` becomes `saved-…`) and re-sorts the list;
    /// a selection held as the entry, which compares by id, then matched nothing — in every other
    /// window showing the list as well as the one that connected.
    @Binding var selection: DeviceAddress?
    /// The catalog's current entry at `selection`.
    let selectedDevice: KVMDevice?

    let isConnected: Bool
    /// The Scan / Cancel scan button and the caption under it.
    let scanRow: ScanRowState
    let devices: [KVMDevice]
    let connectedDeviceName: String?
    /// The address the session is connected through.
    let connectedVia: DeviceAddress?

    /// Guest resolution, forwarded to the stats section. Telemetry itself is not passed in:
    /// `HIDRoundTripLabel`, `SessionHistoryLabel` and `StreamStatsSection` observe it themselves, so this body
    /// does not re-evaluate on every tick.
    let videoSize: CGSize?

    /// Scan when idle, Cancel scan while scanning.
    let onScan: () -> Void
    let onManualConnect: () -> Void
    let onToggleConnection: () -> Void
    /// An address picked from the Connect menu.
    let onConnectVia: (DeviceAddress) -> Void
    let onEditSelectedDevice: () -> Void
    let onForgetSelectedDevice: () -> Void
    let onOpenLog: () -> Void

    /// The Connect menu's rows, as one value that changes whenever any of them does.
    private var connectMenuIdentity: String {
        guard let selectedDevice else { return "none" }
        return ([selectedDevice.id] + ConnectVia.items(for: selectedDevice).map(\.title)).joined(separator: "|")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connections")
                .font(.headline)

            // Each device by its nickname, with its address after it; the address alone for a
            // device without one.
            DevicePopUpButton(devices: devices, selectedID: selectedDevice?.id) { device in
                selection = device?.address
            }
            .frame(maxWidth: .infinity)

            // Actions on the selected device. Selecting a device does not connect to it; this
            // row makes that second step visible (it used to be an unlabeled header icon).
            HStack {
                if isConnected {
                    Button("Disconnect") { onToggleConnection() }
                } else {
                    // Connect goes through the last-used address; the arrow lists every address.
                    Menu {
                        Section(ConnectVia.menuTitle) {
                            ForEach(selectedDevice.map(ConnectVia.items) ?? [], id: \.address) { item in
                                Toggle(isOn: Binding(
                                    get: { item.isLastUsed },
                                    set: { _ in onConnectVia(item.address) }
                                )) {
                                    Text(item.title)
                                }
                            }
                        }
                    } label: {
                        Text("Connect")
                    } primaryAction: {
                        onToggleConnection()
                    }
                    .fixedSize()
                    .disabled(selectedDevice == nil)
                    // A new identity whenever the rows change: AppKit keeps the menu it built
                    // for the first device chosen otherwise.
                    .id(connectMenuIdentity)
                }

                // Editable while connected: changing the addresses does not disconnect.
                Button("Edit…") { onEditSelectedDevice() }
                    .disabled(selectedDevice == nil)

                Button("Forget") { onForgetSelectedDevice() }
                    .disabled(isConnected || selectedDevice?.id.hasPrefix("saved-") != true)

                Spacer()
            }

            Divider()

            // Ways to add devices to the list.
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Button { onScan() } label: {
                        // Both labels are always laid out, so the button is as wide as the wider
                        // one ("Cancel scan") in both states and nothing beside it moves; only
                        // the active one is visible, and only it is read out.
                        ZStack {
                            Text(ScanRowState.scanTitle)
                                .opacity(scanRow.isScanning ? 0 : 1)
                                .accessibilityHidden(scanRow.isScanning)
                            Text(ScanRowState.cancelTitle)
                                .opacity(scanRow.isScanning ? 1 : 0)
                                .accessibilityHidden(!scanRow.isScanning)
                        }
                    }
                    .accessibilityLabel(scanRow.buttonTitle)
                    .disabled(!scanRow.isButtonEnabled)

                    Button("Manual Connect…") { onManualConnect() }

                    Spacer()

                    if scanRow.isScanning {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                if let caption = scanRow.caption {
                    Text(caption)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text(connectedDeviceName ?? (selectedDevice?.displayName ?? "No Device"))
                    .font(.caption)

                HStack {
                    Text(isConnected ? (connectedVia.map { ConnectVia.statusText(connectedThrough: $0) } ?? "Connected") : "Disconnected")
                        .font(.caption)
                        .foregroundColor(isConnected ? .green : .red)

                    Spacer()

                    HIDRoundTripLabel()
                        .foregroundColor(.secondary)
                }

                SessionHistoryLabel()
            }

            StreamStatsSection(videoSize: videoSize)

            ConnectionLogSummary(onOpenLog: onOpenLog)
        }
        .padding(14)
    }
}

#Preview {
    let kvmDeviceManager = KVMDeviceManager()
    return ContentView()
        .consoleSession(ConsoleSession(catalog: kvmDeviceManager))
        .environmentObject(kvmDeviceManager)
}


/// Carries the panel container's width up from a zero-cost background reader.
private struct PanelContainerWidthKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
