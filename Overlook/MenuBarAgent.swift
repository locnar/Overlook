import SwiftUI
import AppKit
import Combine

@MainActor
class MenuBarAgent: NSObject, ObservableObject {
    private var statusItem: NSStatusItem?
    /// The status menu, built by `createMenu`.
    private(set) var menu: NSMenu?
    private var popover: NSPopover?

    private let kvmDeviceManager: KVMDeviceManager
    private let registry: SessionRegistry
    private let showMainWindow: () -> Void

    /// The console the status menu acts on: the active one (the key window's, or the last to have
    /// been key). Nil while no console window is open.
    private var session: ConsoleSession? { registry.activeSession }

    /// What the status menu lists about the sessions, kept current from the registry.
    private let menuState: StatusMenuState

    // The status menu's items that change with the sessions. The rest are fixed.
    private var connectedHeaderItem: NSMenuItem?
    /// The items under "Connected": one per connected session, or a placeholder.
    private var connectedItems: [NSMenuItem] = []
    private var screenshotItem: NSMenuItem?
    private var recordItem: NSMenuItem?
    private var disconnectItem: NSMenuItem?
    private var devicesItem: NSMenuItem?

    /// What the popover shows while no console window is open: a connection that is never
    /// connected, so every device row offers Connect.
    private lazy var idleConnection = SessionConnection(catalog: kvmDeviceManager)
    
    @Published var isConnected = false
    @Published var currentDevice: KVMDevice?
    @Published var availableDevices: [KVMDevice] = []
    
    private var cancellables = Set<AnyCancellable>()
    /// The subscriptions to the active session, replaced when another session becomes active.
    private var sessionCancellables = Set<AnyCancellable>()

    init(
        registry: SessionRegistry,
        showMainWindow: @escaping () -> Void
    ) {
        self.kvmDeviceManager = registry.catalog
        self.registry = registry
        self.showMainWindow = showMainWindow
        self.menuState = StatusMenuState(registry: registry)
        super.init()
    }
    
    func setup() {
        createStatusItem()
        createMenu()
        bindManagers()
    }

    private func bindManagers() {
        availableDevices = kvmDeviceManager.availableDevices
        updateDeviceMenu()

        kvmDeviceManager.$availableDevices
            .sink { [weak self] devices in
                guard let self else { return }
                self.availableDevices = devices
                self.updateDeviceMenu()
            }
            .store(in: &cancellables)

        // The popover follows whichever session is active. `@Published` fires in `willSet`, so the
        // new session is taken from the emitted value.
        registry.$activeSession
            .sink { [weak self] session in
                self?.bind(to: session)
            }
            .store(in: &cancellables)

        // The menu's session items, the action titles and the icon follow every session: one
        // connecting or disconnecting, starting or stopping a recording, or becoming active.
        // The model is published in `willSet` too, so it is applied as emitted.
        menuState.$model
            .sink { [weak self] model in
                self?.apply(model)
            }
            .store(in: &cancellables)
    }

    private func bind(to session: ConsoleSession?) {
        sessionCancellables.removeAll()
        if let popover {
            popover.contentViewController = makePopoverContent(connection: session?.connection ?? idleConnection)
        }

        guard let session else {
            currentDevice = nil
            updateDeviceMenu()
            return
        }

        session.connection.$connectedDevice
            .sink { [weak self] device in
                guard let self else { return }
                // `@Published` fires in `willSet`: the connection still holds the previous device
                // here, so the Devices checkmark takes the emitted value rather than reading it back.
                self.currentDevice = device
                self.updateDeviceMenu()
            }
            .store(in: &sessionCancellables)
    }

    /// Brings the status menu's session items, action titles and enabled states, and the icon, in
    /// line with `model`. Items are updated in place, so an open menu changes under the pointer
    /// rather than closing.
    private func apply(_ model: StatusMenuModel) {
        isConnected = model.isAnyConnected
        updateStatusIcon()

        screenshotItem?.isEnabled = model.canSaveScreenshot
        recordItem?.title = model.recordingTitle
        recordItem?.isEnabled = model.canToggleRecording
        disconnectItem?.title = model.disconnectTitle
        disconnectItem?.isEnabled = model.canDisconnect

        guard let menu, let connectedHeaderItem else { return }
        for item in connectedItems {
            menu.removeItem(item)
        }
        connectedItems = makeConnectedItems(model)
        var index = menu.index(of: connectedHeaderItem) + 1
        for item in connectedItems {
            menu.insertItem(item, at: index)
            index += 1
        }
    }

    /// One item per connected session: its device, a checkmark on the active one, and a trailing
    /// marker while it records. Choosing one brings its window forward, which makes it active.
    private func makeConnectedItems(_ model: StatusMenuModel) -> [NSMenuItem] {
        guard model.isAnyConnected else {
            let none = NSMenuItem(title: StatusMenuModel.noneConnectedTitle, action: nil, keyEquivalent: "")
            none.isEnabled = false
            return [none]
        }
        return model.connected.map { entry in
            let item = NSMenuItem(title: entry.title, action: #selector(bringSessionForward(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.id
            item.state = entry.isActive ? .on : .off
            if entry.isRecording {
                let title = NSMutableAttributedString(
                    string: entry.deviceName + "  ",
                    attributes: [.font: NSFont.menuFont(ofSize: 0)]
                )
                title.append(NSAttributedString(
                    string: StatusMenuModel.recordingMarker,
                    attributes: [
                        .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                        .foregroundColor: NSColor.systemRed,
                    ]
                ))
                item.attributedTitle = title
            }
            return item
        }
    }

    @objc private func bringSessionForward(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? ObjectIdentifier,
              let session = registry.sessions.first(where: { ObjectIdentifier($0) == id })
        else { return }
        session.bringWindowForward()
    }
    
    private func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "display.2", accessibilityDescription: "Overlook")
            button.action = #selector(statusItemClicked)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        
        updateStatusIcon()
    }
    
    /// Show Overlook; the connected sessions; the actions on the active one; then connecting and
    /// managing devices, OCR, Preferences and Quit. The session part is filled in by `apply`.
    ///
    /// Every item works by clicking it. None of the key equivalents is global: Overlook installs no
    /// system-wide key monitor, so they never act while another app is in front. (It once had one
    /// for ⇧⌘V, ⇧⌘O and ⇧⌘D; a global monitor cannot keep the keystroke from the frontmost app, so
    /// it fired alongside that app's own shortcuts.)
    func createMenu() {
        let menu = NSMenu()
        // Enabled states come from the model (`apply`), not from validation as the menu opens.
        menu.autoenablesItems = false
        self.menu = menu

        let showItem = NSMenuItem(title: StatusMenuModel.showTitle, action: #selector(showMainWindowAction), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)
        menu.addItem(NSMenuItem.separator())

        // Connected sessions
        let header = NSMenuItem.sectionHeader(title: StatusMenuModel.connectedHeader)
        connectedHeaderItem = header
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())

        // Actions on the active session. The key equivalents shown are the Capture menu's. This
        // menu is attached to the status item only while it is open (`statusItemClicked`) and is
        // never in the main menu, so ⇧⌘S and ⇧⌘R reach these items only while it is open (AppKit
        // matches an open menu's key equivalents); the rest of the time the chord is the Capture
        // menu's, for the key console window.
        let screenshotItem = NSMenuItem(title: StatusMenuModel.screenshotTitle, action: #selector(saveScreenshot), keyEquivalent: "s")
        screenshotItem.keyEquivalentModifierMask = [.command, .shift]
        screenshotItem.target = self
        self.screenshotItem = screenshotItem
        menu.addItem(screenshotItem)

        let recordItem = NSMenuItem(title: "Start Recording", action: #selector(toggleRecording), keyEquivalent: "r")
        recordItem.keyEquivalentModifierMask = [.command, .shift]
        recordItem.target = self
        self.recordItem = recordItem
        menu.addItem(recordItem)

        let disconnectItem = NSMenuItem(title: "Disconnect", action: #selector(disconnectAction), keyEquivalent: "")
        disconnectItem.target = self
        self.disconnectItem = disconnectItem
        menu.addItem(disconnectItem)

        menu.addItem(NSMenuItem.separator())

        // Devices: connecting (routed like every connect from here, `connectFromMenu`), adding,
        // forgetting and removing.
        let devicesItem = NSMenuItem(title: "Devices", action: nil, keyEquivalent: "")
        devicesItem.submenu = createDeviceMenu()
        self.devicesItem = devicesItem
        menu.addItem(devicesItem)

        let connectItem = NSMenuItem(title: "Quick Connect", action: #selector(showQuickConnect), keyEquivalent: "k")
        connectItem.target = self
        menu.addItem(connectItem)

        let scanItem = NSMenuItem(title: "Scan for Devices", action: #selector(scanForDevices), keyEquivalent: "d")
        scanItem.keyEquivalentModifierMask = [.command, .shift]
        scanItem.target = self
        menu.addItem(scanItem)

        menu.addItem(NSMenuItem.separator())

        // OCR toggle
        let ocrItem = NSMenuItem(title: "Enable OCR", action: #selector(toggleOCR), keyEquivalent: "o")
        ocrItem.target = self
        ocrItem.tag = 200
        menu.addItem(ocrItem)

        menu.addItem(NSMenuItem.separator())

        // Preferences
        let prefsItem = NSMenuItem(title: "Preferences...", action: #selector(showPreferences), keyEquivalent: ",")
        prefsItem.target = self
        menu.addItem(prefsItem)

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(title: "Quit Overlook", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        apply(menuState.model)
    }

    private func createDeviceMenu() -> NSMenu {
        let deviceMenu = NSMenu()
        
        let noDevicesItem = NSMenuItem(title: "No devices found", action: nil, keyEquivalent: "")
        noDevicesItem.tag = 300
        deviceMenu.addItem(noDevicesItem)
        
        return deviceMenu
    }
    
    private func updateDeviceMenu() {
        guard let deviceMenu = devicesItem?.submenu else { return }
        
        deviceMenu.removeAllItems()
        
        if availableDevices.isEmpty {
            let noDevicesItem = NSMenuItem(title: "No devices found", action: nil, keyEquivalent: "")
            noDevicesItem.tag = 300
            deviceMenu.addItem(noDevicesItem)
        } else {
            // As in the Connections panel: the nickname with the address after it, or the
            // address alone. Choosing one connects through its last-used address.
            let column = DeviceMenuTitle.column(for: availableDevices.map(DeviceMenuTitle.init))
            for device in availableDevices {
                let title = DeviceMenuTitle(device)
                let deviceItem = NSMenuItem(title: device.displayName, action: #selector(connectToDevice(_:)), keyEquivalent: "")
                deviceItem.attributedTitle = title.attributed(column: column)
                deviceItem.target = self
                deviceItem.representedObject = device
                
                // Checked when the active window shows it; choosing a device open in another
                // window brings that window forward instead.
                if let currentDevice, currentDevice.id == device.id || device.includes(currentDevice.address) {
                    deviceItem.state = .on
                }
                
                deviceMenu.addItem(deviceItem)
            }
        }
        
        deviceMenu.addItem(NSMenuItem.separator())

        // Forget saved devices
        let savedDevices = availableDevices.filter { $0.id.hasPrefix("saved-") }
        let forgetItem = NSMenuItem(title: "Forget Saved Device", action: nil, keyEquivalent: "")
        let forgetMenu = NSMenu()
        if savedDevices.isEmpty {
            forgetMenu.addItem(NSMenuItem(title: "No saved devices", action: nil, keyEquivalent: ""))
        } else {
            for device in savedDevices {
                let item = NSMenuItem(title: device.displayName, action: #selector(forgetDevice(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = device
                forgetMenu.addItem(item)
            }
        }
        forgetItem.submenu = forgetMenu
        deviceMenu.addItem(forgetItem)

        // Remove manual devices
        let manualDevices = availableDevices.filter { $0.id.hasPrefix("manual-") }
        let removeItem = NSMenuItem(title: "Remove Manual Device", action: nil, keyEquivalent: "")
        let removeMenu = NSMenu()
        if manualDevices.isEmpty {
            removeMenu.addItem(NSMenuItem(title: "No manual devices", action: nil, keyEquivalent: ""))
        } else {
            for device in manualDevices {
                let item = NSMenuItem(title: device.displayName, action: #selector(removeManualDevice(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = device
                removeMenu.addItem(item)
            }
        }
        removeItem.submenu = removeMenu
        deviceMenu.addItem(removeItem)
        
        deviceMenu.addItem(NSMenuItem.separator())
        
        let addDeviceItem = NSMenuItem(title: "Add Manual Device...", action: #selector(showAddDevice), keyEquivalent: "")
        addDeviceItem.target = self
        deviceMenu.addItem(addDeviceItem)
    }
    
    @objc private func statusItemClicked() {
        guard let event = NSApp.currentEvent else { return }
        
        if event.type == .rightMouseUp {
            // Show context menu
            statusItem?.menu = menu
            statusItem?.button?.performClick(nil)
            statusItem?.menu = nil
        } else {
            // Show popover
            togglePopover(nil)
        }
    }

    @objc private func saveScreenshot() {
        session?.perform(.saveScreenshot)
    }

    @objc private func toggleRecording() {
        session?.perform(.toggleRecording)
    }

    private func promptForPassword(deviceName: String) -> (password: String, save: Bool)? {
        let alert = NSAlert()
        alert.messageText = "Password Required"
        alert.informativeText = "Enter password for \(deviceName)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 46))

        let passwordField = NSSecureTextField(frame: NSRect(x: 0, y: 24, width: 240, height: 22))
        passwordField.placeholderString = "Password"

        let saveCheckbox = NSButton(checkboxWithTitle: "Save password for this device", target: nil, action: nil)
        saveCheckbox.frame = NSRect(x: 0, y: 0, width: 240, height: 18)

        view.addSubview(passwordField)
        view.addSubview(saveCheckbox)
        alert.accessoryView = view

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }

        let password = passwordField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !password.isEmpty else { return nil }
        return (password, saveCheckbox.state == .on)
    }

    /// "This is <device>": Add address, or Keep separate (also Escape).
    private func askToLink(_ prompt: DeviceLinkPrompt) -> DeviceLinkPrompt.Answer {
        let alert = NSAlert()
        alert.messageText = prompt.title
        alert.informativeText = prompt.message
        alert.alertStyle = .informational
        alert.addButton(withTitle: DeviceLinkPrompt.addTitle)
        let keep = alert.addButton(withTitle: DeviceLinkPrompt.keepTitle)
        keep.keyEquivalent = "\u{1b}"
        return alert.runModal() == .alertFirstButtonReturn ? .addAddress : DeviceLinkPrompt.escapeAnswer
    }

    private func showError(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
    
    @objc private func togglePopover(_ sender: Any?) {
        if let popover = popover, popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }
    
    private func showPopover() {
        guard let statusItem = statusItem else { return }
        
        if popover == nil {
            popover = NSPopover()
            popover?.contentSize = NSSize(width: 300, height: 400)
            popover?.behavior = .transient
            popover?.contentViewController = makePopoverContent(connection: session?.connection ?? idleConnection)
        }
        
        popover?.show(relativeTo: statusItem.button!.bounds, of: statusItem.button!, preferredEdge: .minY)
    }

    /// The popover's device list, showing `connection` — the active session's — as connected.
    private func makePopoverContent(connection: SessionConnection) -> NSViewController {
        NSHostingController(
            rootView: MenuBarView(
                kvmDeviceManager: kvmDeviceManager,
                connection: connection,
                onShowWindow: { [weak self] in self?.showMainWindow() },
                onScan: { [weak self] in self?.kvmDeviceManager.scanForDevices() },
                onConnect: { [weak self] device in
                    // Through the device's last-used address, as from the Devices menu.
                    self?.connectFromMenu(to: ConnectVia.plainConnect(device))
                },
                onDisconnect: { [weak self] in
                    guard let self else { return }
                    self.disconnectSession()
                },
                onForget: { [weak self] device in
                    self?.forget(device)
                },
                onRemoveManual: { [weak self] device in
                    self?.remove(device)
                }
            )
        )
    }
    
    private func closePopover() {
        popover?.performClose(nil)
    }
    
    @objc private func connectToDevice(_ sender: NSMenuItem) {
        guard let device = sender.representedObject as? KVMDevice else { return }
        // The catalog's entry now (its last-used address may have changed since the menu was
        // built), through its last-used address: one attempt, no fallback.
        let current = kvmDeviceManager.availableDevices.first { $0.id == device.id } ?? device
        connectFromMenu(to: ConnectVia.plainConnect(current))
    }

    /// A device open in a window already brings that window forward. Otherwise the connect goes to
    /// the active session if it is free, or to a new window if it is not (or none is open).
    private func connectFromMenu(to device: KVMDevice, password: String? = nil, savePassword: Bool = false) {
        let target: ConsoleSession
        switch registry.connectTarget(for: device) {
        case .bringForward(let open):
            open.bringWindowForward()
            closePopover()
            return
        case .connect(let active):
            target = active
        case .newWindow:
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
            guard let opened = registry.openWindow() else {
                showError(title: "Failed to connect", message: "Overlook could not open a window for \(device.displayName).")
                return
            }
            target = opened
        }
        Task { await connectSession(target, to: device, password: password, savePassword: savePassword) }
    }

    /// The steps are the session's (`ConsoleSession.connect`), shared with the window; what the
    /// agent adds is modal alerts for the outcomes. A connect without a password that the device
    /// refuses prompts once; one with a password reports the refusal instead.
    private func connectSession(
        _ session: ConsoleSession,
        to device: KVMDevice,
        password: String? = nil,
        savePassword: Bool = false
    ) async {
        // A window the agent has just asked for has not appeared yet; it comes forward on its own.
        NSApp.activate()
        session.bringWindowForward()
        // Before the connect saves it: the saved device the address belonged to, if any.
        let savedBefore = kvmDeviceManager.savedDevice(containing: device.address)

        let outcome = await session.connect(to: device, password: password, savePassword: savePassword) { _ in
            closePopover()
        }

        switch outcome {
        case .connected(let connected, let streamError):
            if streamError is NativeWebRTCVideoModeError {
                showError(title: "Video mode not supported", message: NativeWebRTCVideoModeError.message)
            } else if let streamError {
                // still consider ourselves connected at the API layer
                showError(title: "WebRTC connect failed", message: String(describing: streamError))
            }
            if let prompt = DeviceLinkPrompt.after(connecting: connected, savedBefore: savedBefore, catalog: kvmDeviceManager) {
                // Add address while the device is open in another window brings that window
                // forward and disconnects this one (`ConsoleSession.answerLink`).
                session.answerLink(prompt, askToLink(prompt))
            }
        case .needsPassword:
            guard password == nil else {
                showError(title: "Failed to connect", message: String(describing: KVMError.authenticationFailed))
                return
            }
            guard let entry = promptForPassword(deviceName: device.displayName) else { return }
            await connectSession(session, to: device, password: entry.password, savePassword: entry.save)
        case .certificateChanged(let host, let port, let fingerprint):
            let error = KVMError.certificateChanged(host: host, port: port, fingerprint: fingerprint)
            showError(title: "Failed to connect", message: String(describing: error))
        case .failed(let error):
            showError(
                title: "Failed to connect",
                message: ConnectVia.failureMessage(
                    address: device.address,
                    deviceHasOtherAddresses: device.addresses.contains { $0 != device.address },
                    error: error
                )
            )
        case .openElsewhere(let other):
            // Another window got there between choosing the target and connecting.
            other.bringWindowForward()
            closePopover()
        case .cancelled:
            break
        }
    }

    @objc private func disconnectAction() {
        disconnectSession()
    }

    private func disconnectSession() {
        session?.disconnect()
        closePopover()
    }
    
    @objc private func showQuickConnect() {
        let alert = NSAlert()
        alert.messageText = "Quick Connect"
        alert.informativeText = "Enter the IP/host and port of your KVM device"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")

        let view = NSView()
        view.frame = NSRect(x: 0, y: 0, width: 260, height: 110)

        let hostField = NSTextField(frame: NSRect(x: 0, y: 80, width: 260, height: 22))
        hostField.placeholderString = "Host or IP (optionally host:port)"

        let portField = NSTextField(frame: NSRect(x: 0, y: 52, width: 260, height: 22))
        portField.placeholderString = "Port"
        portField.stringValue = "443"
        portField.integerValue = 443

        let passwordField = NSSecureTextField(frame: NSRect(x: 0, y: 24, width: 260, height: 22))
        passwordField.placeholderString = "Password (optional)"

        let saveCheckbox = NSButton(checkboxWithTitle: "Save password for this device", target: nil, action: nil)
        saveCheckbox.frame = NSRect(x: 0, y: 0, width: 260, height: 18)

        view.addSubview(hostField)
        view.addSubview(portField)
        view.addSubview(passwordField)
        view.addSubview(saveCheckbox)
        alert.accessoryView = view

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        guard !hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let address: DeviceAddress
        switch AddressInput.parse(hostField.stringValue, port: portField.stringValue) {
        case .success(let parsed):
            address = parsed
        case .failure(let problem):
            showError(title: "Quick Connect", message: problem.message)
            return
        }
        // An address of a saved device connects as that device, through that address.
        let device = kvmDeviceManager.device(forTyped: address)
        let password = passwordField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let savePassword = saveCheckbox.state == .on

        connectFromMenu(to: device, password: password.isEmpty ? nil : password, savePassword: savePassword)
    }
    
    @objc private func scanForDevices() {
        kvmDeviceManager.scanForDevices()
    }
    
    @objc private func toggleOCR() {
        session?.perform(.toggleCopyMode)
        
        // Update menu item
        if let ocrItem = menu?.items.first(where: { $0.tag == 200 }) {
            ocrItem.title = ocrItem.title.contains("Enable") ? "Disable OCR" : "Enable OCR"
        }
    }
    
    @objc private func showPreferences() {
        showMainWindow()
    }
    
    @objc private func showAddDevice() {
        // Show add device dialog
        let alert = NSAlert()
        alert.messageText = "Add Manual Device"
        alert.informativeText = "Enter the IP address and port of your KVM device"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        
        // Add text fields for IP and port
        let view = NSView()
        view.frame = NSRect(x: 0, y: 0, width: 200, height: 60)
        
        let ipField = NSTextField(frame: NSRect(x: 0, y: 30, width: 200, height: 20))
        ipField.placeholderString = "IP Address"
        ipField.stringValue = ""
        
        let portField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 20))
        portField.placeholderString = "Port"
        portField.stringValue = "8443"
        portField.integerValue = 8443
        
        view.addSubview(ipField)
        view.addSubview(portField)
        
        alert.accessoryView = view
        
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            switch AddressInput.parse(ipField.stringValue, port: portField.stringValue) {
            case .success(let address):
                // An address a saved device already has is that device; nothing to add.
                if kvmDeviceManager.savedDevice(containing: address) == nil {
                    _ = kvmDeviceManager.addManualDevice(host: address.host, port: address.port, type: .glinetComet)
                }
            case .failure(let problem):
                showError(title: "Add Manual Device", message: problem.message)
            }
        }
    }

    @objc private func forgetDevice(_ sender: NSMenuItem) {
        guard let device = sender.representedObject as? KVMDevice else { return }
        forget(device)
    }

    @objc private func removeManualDevice(_ sender: NSMenuItem) {
        guard let device = sender.representedObject as? KVMDevice else { return }
        remove(device)
    }

    /// Refused while any window shows the device, not only the active one: the catalog would
    /// pull it out from under that window's session.
    private func forget(_ device: KVMDevice) {
        if registry.session(showing: device) != nil {
            showError(title: "Cannot forget", message: "Disconnect before forgetting this device.")
            return
        }
        kvmDeviceManager.forgetDevice(device)
    }

    private func remove(_ device: KVMDevice) {
        if registry.session(showing: device) != nil {
            showError(title: "Cannot remove", message: "Disconnect before removing this device.")
            return
        }
        kvmDeviceManager.removeDevice(device)
    }

    @objc private func showMainWindowAction() {
        showMainWindow()
    }
    
    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
    
    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        
        if isConnected {
            button.image = NSImage(systemSymbolName: "display.2", accessibilityDescription: "Overlook - Connected")
            button.contentTintColor = .systemGreen
        } else {
            button.image = NSImage(systemSymbolName: "display.2", accessibilityDescription: "Overlook - Disconnected")
            button.contentTintColor = .labelColor
        }
    }
    
    func updateAvailableDevices(_ devices: [KVMDevice]) {
        availableDevices = devices
        
        Task { @MainActor in
            updateDeviceMenu()
        }
    }
    
    func cleanup() {
        statusItem = nil
        menu = nil
        popover = nil
        cancellables.removeAll()
        sessionCancellables.removeAll()
    }
}

// MARK: - Menu Bar View
struct MenuBarView: View {
    @ObservedObject var kvmDeviceManager: KVMDeviceManager
    @ObservedObject var connection: SessionConnection

    let onShowWindow: () -> Void
    let onScan: () -> Void
    let onConnect: (KVMDevice) -> Void
    let onDisconnect: () -> Void
    let onForget: (KVMDevice) -> Void
    let onRemoveManual: (KVMDevice) -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "display.2")
                    .font(.title2)
                Text("Overlook")
                    .font(.headline)
                Spacer()
                Button("Show") {
                    onShowWindow()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding()
            
            Divider()
            
            // Device list
            ScrollView {
                LazyVStack(spacing: 8) {
                    if kvmDeviceManager.availableDevices.isEmpty {
                        Text("No devices found")
                            .foregroundColor(.secondary)
                            .padding()
                    } else {
                        ForEach(kvmDeviceManager.availableDevices) { device in
                            MenuBarDeviceRow(
                                device: device,
                                isConnected: connection.connectedDevice.map { $0.id == device.id || device.includes($0.address) } ?? false,
                                onConnect: {
                                    onConnect(device)
                                },
                                onDisconnect: {
                                    onDisconnect()
                                },
                                onForget: {
                                    onForget(device)
                                },
                                onRemoveManual: {
                                    onRemoveManual(device)
                                }
                            )
                        }
                    }
                }
                .padding()
            }
            
            Divider()
            
            // Actions
            HStack {
                Button("Scan") {
                    onScan()
                }
                .buttonStyle(.bordered)
                
                Spacer()
                
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(width: 300, height: 400)
    }
}

struct MenuBarDeviceRow: View {
    let device: KVMDevice

    let isConnected: Bool
    let onConnect: () -> Void
    let onDisconnect: () -> Void
    let onForget: () -> Void
    let onRemoveManual: () -> Void
    
    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(device.displayName)
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                Text(device.address.labelWithTag)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()

            if device.id.hasPrefix("saved-") {
                Button {
                    onForget()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Forget saved device")
                .disabled(isConnected)
            } else if device.id.hasPrefix("manual-") {
                Button {
                    onRemoveManual()
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .help("Remove manual device")
                .disabled(isConnected)
            }
            
            Button(isConnected ? "Disconnect" : "Connect") {
                if isConnected {
                    onDisconnect()
                } else {
                    onConnect()
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(6)
    }
}
