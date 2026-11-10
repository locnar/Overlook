import Foundation
import Cocoa
import CoreGraphics
import Combine
import SwiftUI
import Carbon.HIToolbox

@MainActor
class InputManager: ObservableObject {
    /// The app's own chords that keyboard capture keeps rather than sends: ⇧⌘S, ⇧⌘R, and ⌘C for
    /// OCR copy mode. Capture swallows every key before the menus can see it, so it reproduces
    /// them itself.
    enum LocalShortcut: Equatable {
        case saveScreenshot
        case toggleRecording
        case toggleCopyMode
    }

    /// Where those chords go: this input manager's own session (`ConsoleSession` sets it), never
    /// another window's.
    var onLocalShortcut: ((LocalShortcut) -> Void)?

    /// The chords keyboard capture keeps for Overlook instead of sending them to the target:
    /// - ⌘C toggles OCR copy mode;
    /// - ⌘V types the Mac's clipboard on the target;
    /// - ⇧⌘S saves a screenshot and ⇧⌘R starts or stops a recording (the Capture menu's
    ///   shortcuts, reproduced because capture swallows every key event before the menu sees it);
    /// - ⌘Q quits Overlook, as in every other Mac app.
    enum InterceptedChord: Equatable, CaseIterable {
        case copyMode
        case paste
        case saveScreenshot
        case toggleRecording
        case quit

        /// The Mac key code the chord is on (by position, as `NSEvent.keyCode` reports it).
        var keyCode: UInt16 {
            switch self {
            case .copyMode: return 8
            case .paste: return 9
            case .saveScreenshot: return 1
            case .toggleRecording: return 15
            case .quit: return 12
            }
        }

        /// The exact modifiers the chord needs; any other of ⌘ ⇧ ⌥ ⌃ held as well makes the
        /// keystroke the target's.
        var modifiers: NSEvent.ModifierFlags {
            switch self {
            case .copyMode, .paste, .quit: return [.command]
            case .saveScreenshot, .toggleRecording: return [.command, .shift]
            }
        }
    }

    /// The modifiers a chord is matched on. Caps Lock, Fn and the keypad flag are left out, so
    /// they never keep a chord from being Overlook's.
    nonisolated static let chordModifiers: NSEvent.ModifierFlags = [.command, .shift, .option, .control]

    /// Which of Overlook's chords a key-down is, or nil when it goes to the target. A chord needs
    /// exactly its own modifiers among ⌘ ⇧ ⌥ ⌃: ⌃⌘V, ⌥⌘C or ⇧⌘C, for example, are the target's.
    nonisolated static func interceptedChord(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> InterceptedChord? {
        let held = modifiers.intersection(chordModifiers)
        return InterceptedChord.allCases.first { $0.keyCode == keyCode && $0.modifiers == held }
    }

    /// What one input event became on its way to the target, before the transport.
    enum SentInput: Equatable {
        case key(UInt16, isDown: Bool)
        case button(MouseButton, isDown: Bool)
        /// In the target's direction: positive X pans right, positive Y scrolls up.
        case scroll(deltaX: CGFloat, deltaY: CGFloat)
    }

    /// Sees every key, button and scroll event this manager decides to send. Only the tests set
    /// it: with no device attached, it is the one place a send can be observed.
    var sentInputObserver: ((SentInput) -> Void)?

    /// Where ⌘V reads the Mac's clipboard, and what ⌘Q does. Only the tests replace them, so a
    /// chord can be driven without touching the real pasteboard or quitting the test host.
    var readClipboardText: () -> String? = { NSPasteboard.general.string(forType: .string) }
    var terminateApp: () -> Void = { NSApp.terminate(nil) }

    /// Whether this session's window is key, and which presses it took; see `InputFocusGate`.
    /// Every keyboard and mouse path checks it before anything goes to the target.
    private(set) var focusGate = InputFocusGate()
    /// The session's own window. Pointer lock is tied to it, never to whatever `NSApp.keyWindow`
    /// happens to be.
    private weak var window: NSWindow?
    private var windowObservers: [NSObjectProtocol] = []

    private var webRTCManager: WebRTCManager?
    private var glkvmClient: GLKVMClient?
    private var glkvmWebSocketClient: GLKVMClient.WebSocketClient?
    private var keyEventMonitor: Any?
    private var mouseEventMonitor: Any?
    private var isCapturing = false
    private var mouseModeRefreshTask: Task<Void, Never>?

    // HID transport: every send is chained on `hidCommandTail` so key and mouse events reach the
    // device in the order they happened; a failed send schedules a socket reconnect.
    private var hidCommandTail: Task<Void, Never>?
    /// ⌘V pastes, typed one at a time through the device's `hid/print`.
    private let remotePaste = RemotePasteQueue()
    /// True when no paste is queued or being typed.
    var isPasteIdle: Bool { remotePaste.isIdle }
    private var hidReconnectTask: Task<Void, Never>?
    private var acceptsHIDCommands = true
    /// Commands queued on `hidCommandTail` and not yet sent; sampled into telemetry with each pong.
    private var hidQueueDepth = 0
    /// Reconnect rounds started because the socket dropped on its own (no input involved). Bounded,
    /// so a device that keeps refusing is not hammered forever; the next keystroke tries again.
    private var hidDropReconnectRounds = 0
    private static let maxHIDDropReconnectRounds = 3
    /// The mouse mode the device itself last reported in a `hid` event. When present it wins over
    /// the WebUI config value: relative reports sent to a device in absolute mode are dropped.
    private var deviceReportedAbsoluteMouse: Bool?

    private struct PendingAbsoluteMouseMove {
        let toX: Int
        let toY: Int
    }

    private struct PendingRelativeMouseMove {
        var deltaX: Int
        var deltaY: Int
    }

    /// Scales trackpad and Magic Mouse scrolling down to wheel steps; see `ScrollAccumulator`.
    private var scrollAccumulator = ScrollAccumulator()

    private var pendingAbsoluteMouseMove: PendingAbsoluteMouseMove?
    private var pendingRelativeMouseMove: PendingRelativeMouseMove?
    private var mouseMoveSenderTask: Task<Void, Never>?
    private static let mouseMoveSendIntervalNs: UInt64 = 8_333_333

    // Relative mouse mode: fractional delta carried between HID reports, and the
    // remote-pixels-per-view-point scale last measured from the video surface.
    private var relativeResidual = CGSize.zero
    private var relativeDeltaScale: CGFloat = 1.0

    // Pointer lock (relative mode only).
    private var captureClickButton: MouseButton?
    private var heldRelativeButtons: Set<MouseButton> = []
    private var pointerLockObservers: [NSObjectProtocol] = []
    private var isCursorHidden = false
    private var deviceEventTask: Task<Void, Never>?
    private var deviceMouseModeRefreshDebounce: Task<Void, Never>?

    private static let relativeSensitivityDefaultsKey = "overlook.relativeMouseSensitivity"
    private static let unacceleratedInputDefaultsKey = "overlook.relativeMouseUnacceleratedInput"
    /// Holding exactly Control+Option releases a captured pointer (VMware / Parallels convention).
    static let pointerReleaseChord: NSEvent.ModifierFlags = [.control, .option]

    private var pendingCommandKeyCode: UInt16?
    private var activeCommandKeyCode: UInt16?
    private var commandKeySentToRemote: Bool = false
    private var suppressedKeyUps: Set<UInt16> = []

    /// Keys pressed on the target and not yet released, by kvmd key name. Released when capture
    /// stops or Overlook loses focus: the key-up would otherwise go to another app and the key
    /// would stay down on the target.
    private var remoteHeldKeys: Set<String> = []
    private var keyboardFocusObservers: [NSObjectProtocol] = []
    /// Mouse buttons pressed on the target and not yet released, in either mouse mode. Released
    /// when this window stops being key, for the same reason as `remoteHeldKeys`.
    private var remoteHeldButtons: Set<MouseButton> = []

    /// Caps Lock as the target last reported it through its keyboard LEDs; nil until reported.
    private var remoteCapsLockLED: Bool?
    /// Cleared when a corrective tap did not move the LED. Some targets (firmware setup screens,
    /// some BIOSes) never drive the keyboard LEDs, and correcting against a stale report would
    /// toggle Caps Lock every time the window came forward.
    private var remoteCapsLockLEDIsLive = true
    private var capsLockVerifyTask: Task<Void, Never>?

    @Published var isKeyboardCaptureEnabled = false
    @Published var isMouseCaptureEnabled = false

    enum TransportMode: String, CaseIterable {
        case webRTC
        case glkvmWebSocket
    }

    @Published var transportMode: TransportMode = .glkvmWebSocket
    @Published private(set) var isGLKVMAbsoluteMouseMode = true
    /// The device's mouse jiggler as the device last reported it: in a `hid` event on the HID
    /// socket, or read by the settings panel. Nil until the device has said.
    @Published private(set) var deviceJiggler: GLKVMJigglerState?
    @Published private(set) var isPointerLocked = false

    /// Multiplier applied to relative mouse movement. With accelerated input it sits on top of the
    /// view-to-remote scale; with unaccelerated input it is the only factor. Persisted on this Mac.
    @Published var relativeSensitivity: Double {
        didSet { defaults.set(relativeSensitivity, forKey: Self.relativeSensitivityDefaultsKey) }
    }

    /// Send the mouse's raw movement counts (kCGEventUnacceleratedPointerMovementX/Y) instead of
    /// macOS-accelerated deltas, so the target applies its own pointer settings once. Falls back
    /// to accelerated deltas per event when the system does not provide counts.
    @Published var useUnacceleratedRelativeInput: Bool {
        didSet { defaults.set(useUnacceleratedRelativeInput, forKey: Self.unacceleratedInputDefaultsKey) }
    }

    var isRelativeMouseMode: Bool {
        transportMode == .glkvmWebSocket && !isGLKVMAbsoluteMouseMode
    }

    private let defaults: UserDefaults
    /// The session's handle on the connection log; every line from here names its device.
    let log: SessionLog

    /// `defaults` is for tests, which pass a scratch suite; the app takes `AppEnvironment.defaults`. `log` is
    /// the session's (tests pass one on a log kept in memory); an input manager on its own logs to
    /// the app's log under a session of its own.
    init(defaults: UserDefaults = AppEnvironment.defaults, log: SessionLog? = nil) {
        self.defaults = defaults
        self.log = log ?? SessionLog(destination: .shared)
        relativeSensitivity = (defaults.object(forKey: Self.relativeSensitivityDefaultsKey) as? Double) ?? 1.0
        useUnacceleratedRelativeInput = defaults.bool(forKey: Self.unacceleratedInputDefaultsKey)
    }
    
    func setup(with webRTCManager: WebRTCManager) {
        self.webRTCManager = webRTCManager
    }

    /// The panel's telemetry model; the device group of it is ours to write.
    private var telemetry: StreamTelemetryModel? { webRTCManager?.telemetry }

    /// The last link state written to the log, so a per-pong publish doesn't log per pong.
    private var lastLoggedHIDLink: StreamTelemetry.HIDLink?

    private func publishHIDLink(_ link: StreamTelemetry.HIDLink) {
        if lastLoggedHIDLink != link {
            lastLoggedHIDLink = link
            switch link {
            case .connected:
                self.log.info(.hid, "HID link connected")
            case .connecting:
                self.log.info(.hid, "HID link connecting")
            case .reconnecting:
                self.log.warning(.hid, "HID link reconnecting")
            case .disconnected:
                self.log.notice(.hid, "HID link disconnected")
            }
        }
        telemetry?.update { snapshot in
            snapshot.hidLink = link
            snapshot.hidQueueDepth = hidQueueDepth
            if link != .connected {
                snapshot.hidRoundTripMs = nil
            }
        }
    }

    func setGLKVMClient(_ client: GLKVMClient?) {
        // The connect path hands the client over, and the window passes on every change of it
        // too (it is the one that hears about a forgotten device). The second hand-over of the
        // same client must not reset what the first set up — above all the mouse mode the device
        // has since reported over the socket.
        if let client, client === glkvmClient { return }
        // A paste belongs to the device it was started on. It must not go on typing after a
        // disconnect, or into a target this window no longer shows.
        remotePaste.cancelAll()
        mouseModeRefreshTask?.cancel()
        mouseModeRefreshTask = nil
        unlockPointer()
        if client !== glkvmClient {
            // The HID socket belongs to the previous device; a still-connected one would otherwise
            // be kept, sending input to the old device while the video shows the new one.
            disconnectGLKVMWebSocket()
        }
        glkvmClient = client
        resetRemoteKeyboardState()
        deviceReportedAbsoluteMouse = nil
        deviceJiggler = nil
        hidDropReconnectRounds = 0
        isGLKVMAbsoluteMouseMode = true
        pendingAbsoluteMouseMove = nil
        pendingRelativeMouseMove = nil
        relativeResidual = .zero
        if client == nil {
            disconnectGLKVMWebSocket()
            return
        }
        Task { [weak self] in
            await self?.reconnectGLKVMWebSocketIfNeeded()
        }
        refreshMouseModeFromDevice()
    }

    /// Re-reads `is_absolute_mouse` from the WebUI config. Runs on connect and on every
    /// mouse-capture start. It is the fallback: once the device has reported its live mouse mode
    /// over the HID socket (`hid` event), that report is authoritative and this read is ignored.
    /// Until either arrives the mode stays absolute.
    func refreshMouseModeFromDevice() {
        guard let client = glkvmClient else { return }
        mouseModeRefreshTask?.cancel()
        mouseModeRefreshTask = Task { [weak self, weak client] in
            guard let client else { return }
            guard let config = try? await client.getSystemConfig() else { return }
            await MainActor.run {
                guard let self, self.glkvmClient === client else { return }
                self.applyConfiguredMouseMode(isAbsolute: config.isAbsoluteMouse)
            }
        }
    }

    /// The WebUI config's mouse mode. Applied only until the device has reported its live mode
    /// over the HID socket; from then on the report is authoritative.
    func applyConfiguredMouseMode(isAbsolute: Bool) {
        guard deviceReportedAbsoluteMouse == nil else { return }
        setGLKVMAbsoluteMouseMode(isAbsolute)
    }

    /// The jiggler state the device reported. `hid` events come with every LED or link change, so
    /// an unchanged state is not published again.
    func applyDeviceJigglerState(_ state: GLKVMJigglerState) {
        guard deviceJiggler != state else { return }
        deviceJiggler = state
    }

    func setGLKVMAbsoluteMouseMode(_ isAbsolute: Bool) {
        guard isGLKVMAbsoluteMouseMode != isAbsolute else { return }
        if isAbsolute {
            unlockPointer()
        }
        isGLKVMAbsoluteMouseMode = isAbsolute
        pendingAbsoluteMouseMove = nil
        pendingRelativeMouseMove = nil
        relativeResidual = .zero
    }

    func handleVideoMouseMove(pointInView: CGPoint, deltaInView: CGSize = .zero, viewSize: CGSize, videoSize: CGSize?) {
        guard isMouseCaptureEnabled, focusGate.admitsPointerMotion else { return }
        if isRelativeMouseMode {
            // Relative mode forwards movement only while the pointer is locked, and the locked path
            // reads deltas from the event monitor. Here we just keep the remote-pixels-per-point
            // scale current so a capture that starts later uses the right value.
            relativeDeltaScale = computeRelativeDeltaScale(viewSize: viewSize, videoSize: videoSize)
            return
        }
        let normalized = normalizePointInViewToVideo(pointInView: pointInView, viewSize: viewSize, videoSize: videoSize)
        let moveEvent = MouseMoveEvent(position: normalized, delta: deltaInView, timestamp: CACurrentMediaTime())
        if transportMode == .glkvmWebSocket {
            enqueueAbsoluteMouseMoveEvent(moveEvent)
        } else {
            sendMouseMoveEvent(moveEvent)
        }
    }

    private func enqueueAbsoluteMouseMoveEvent(_ event: MouseMoveEvent) {
        guard isNormalized(event.position) else { return }
        let (toX, toY) = glkvmAbsolutePoint(fromNormalized: event.position)
        pendingAbsoluteMouseMove = PendingAbsoluteMouseMove(toX: toX, toY: toY)
        if mouseMoveSenderTask == nil {
            startMouseMoveSender()
        }
    }

    /// Accumulates a scaled relative delta and queues whole-count movement for the sender.
    /// The fractional remainder is carried forward so slow movement is not rounded away.
    private func accumulateRelativeDelta(_ delta: CGSize) {
        relativeResidual.width += delta.width
        relativeResidual.height += delta.height

        let deltaX = Int(relativeResidual.width.rounded(.towardZero))
        let deltaY = Int(relativeResidual.height.rounded(.towardZero))
        relativeResidual.width -= CGFloat(deltaX)
        relativeResidual.height -= CGFloat(deltaY)
        guard deltaX != 0 || deltaY != 0 else { return }

        if var pending = pendingRelativeMouseMove {
            pending.deltaX += deltaX
            pending.deltaY += deltaY
            pendingRelativeMouseMove = pending
        } else {
            pendingRelativeMouseMove = PendingRelativeMouseMove(deltaX: deltaX, deltaY: deltaY)
        }

        if mouseMoveSenderTask == nil {
            startMouseMoveSender()
        }
    }

    private func startMouseMoveSender() {
        guard mouseMoveSenderTask == nil else { return }

        let sendIntervalNs = Self.mouseMoveSendIntervalNs

        mouseMoveSenderTask = Task.detached(priority: .userInitiated) { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }

                let snapshot: (
                    absoluteMove: PendingAbsoluteMouseMove?,
                    relativeMove: PendingRelativeMouseMove?,
                    isAbsoluteMouseMode: Bool,
                    mode: TransportMode,
                    ws: GLKVMClient.WebSocketClient?
                ) = await MainActor.run {
                    let absoluteMove = self.pendingAbsoluteMouseMove
                    let relativeMove = self.pendingRelativeMouseMove
                    self.pendingAbsoluteMouseMove = nil
                    self.pendingRelativeMouseMove = nil
                    return (
                        absoluteMove,
                        relativeMove,
                        self.isGLKVMAbsoluteMouseMode,
                        self.transportMode,
                        self.glkvmWebSocketClient
                    )
                }

                let hasMove = snapshot.isAbsoluteMouseMode ? snapshot.absoluteMove != nil : snapshot.relativeMove != nil
                guard hasMove else {
                    await MainActor.run {
                        self.mouseMoveSenderTask = nil
                    }
                    return
                }

                if snapshot.mode == .glkvmWebSocket, let ws = snapshot.ws {
                    // Wait for the move to go out before taking the next snapshot: on a slow link
                    // the moves coalesce in `pending…` instead of piling up in the queue.
                    let sent: Task<Void, Never>?
                    if snapshot.isAbsoluteMouseMode, let move = snapshot.absoluteMove {
                        sent = await MainActor.run {
                            self.enqueueHIDCommand(label: "mouse move") {
                                try await ws.sendHidMouseMove(toX: move.toX, toY: move.toY)
                            }
                        }
                    } else if let move = snapshot.relativeMove {
                        sent = await MainActor.run {
                            self.enqueueHIDCommand(label: "relative mouse move") {
                                try await Self.sendRelativeMouseMove(move, through: ws)
                            }
                        }
                    } else {
                        sent = nil
                    }
                    await sent?.value
                }

                try? await Task.sleep(nanoseconds: sendIntervalNs)
            }
        }
    }

    private func stopMouseMoveSender() {
        pendingAbsoluteMouseMove = nil
        pendingRelativeMouseMove = nil
        relativeResidual = .zero
        mouseMoveSenderTask?.cancel()
        mouseMoveSenderTask = nil
    }

    func handleVideoMouseButton(button: MouseButton, isDown: Bool, pointInView: CGPoint, viewSize: CGSize, videoSize: CGSize?) {
        guard isMouseCaptureEnabled else { return }
        // A click on a window that is not key only brings it forward. A release goes out only for
        // a press made here, while this window was key; one already released when the window
        // lost key status is not sent again.
        guard focusGate.admitButton(button, isDown: isDown) else { return }

        if isRelativeMouseMode {
            if !isPointerLocked {
                // The click that captures the pointer is not forwarded: the remote cursor is not
                // where the local click landed.
                if isDown {
                    relativeDeltaScale = computeRelativeDeltaScale(viewSize: viewSize, videoSize: videoSize)
                    if lockPointer() {
                        captureClickButton = button
                    }
                }
                return
            }
            if let captureButton = captureClickButton, button == captureButton, !isDown {
                captureClickButton = nil
                return
            }
            if isDown {
                heldRelativeButtons.insert(button)
            } else {
                heldRelativeButtons.remove(button)
            }
        }

        let normalized = normalizePointInViewToVideo(pointInView: pointInView, viewSize: viewSize, videoSize: videoSize)
        let buttonEvent = MouseButtonEvent(button: button, isDown: isDown, position: normalized, timestamp: CACurrentMediaTime())
        sendMouseButtonEvent(buttonEvent)
    }

    /// The only way scrolling reaches the target, in absolute mode and with the pointer locked
    /// in relative mode alike: the locked cursor stays frozen over the video view, so its
    /// `scrollWheel` keeps receiving the events.
    func handleVideoMouseScroll(_ input: ScrollWheelInput) {
        // Scrolling reaches the window under the pointer whether or not it is key.
        guard isMouseCaptureEnabled, focusGate.admitsPointerMotion else { return }
        if isRelativeMouseMode, !isPointerLocked { return }
        guard let steps = scrollAccumulator.add(input) else { return }
        // From here on the steps are in the target's direction, not the Mac's.
        let target = Self.targetScrollSteps(macDeltaX: steps.deltaX, macDeltaY: steps.deltaY)
        let scrollEvent = MouseScrollEvent(deltaX: target.deltaX, deltaY: target.deltaY, timestamp: CACurrentMediaTime())
        sendMouseScrollEvent(scrollEvent)
    }

    /// Turns wheel steps in the Mac's direction into the target's, the one place this happens.
    ///
    /// Vertically the two agree: a positive `scrollingDeltaY` scrolls up on the Mac, and a
    /// positive USB HID Wheel value scrolls up on the target. Horizontally they are opposite: a
    /// positive `scrollingDeltaX` scrolls left on the Mac, but a positive HID AC Pan value scrolls
    /// right (Windows `WM_MOUSEHWHEEL` and Linux `REL_HWHEEL` are positive-right too). kvmd puts
    /// the wheel numbers into the USB report unchanged, so X is negated here and Y is not.
    ///
    /// Natural Scrolling needs nothing extra: macOS flips both signs before Overlook sees the
    /// event, so the target scrolls the way the Mac's own apps do, on both axes. This runs after
    /// `ScrollAccumulator` has turned lines or points into steps, so it applies once to every
    /// path: notched wheel and trackpad, absolute mode and locked relative mode.
    nonisolated static func targetScrollSteps(macDeltaX: CGFloat, macDeltaY: CGFloat) -> (deltaX: CGFloat, deltaY: CGFloat) {
        (-macDeltaX, macDeltaY)
    }

    func setTransportMode(_ mode: TransportMode) {
        // A lock can only exist on the GLKVM transport; release it (and any held buttons) while
        // that transport is still selected so the releases reach the device.
        unlockPointer()
        transportMode = mode
        switch mode {
        case .webRTC:
            stopMouseMoveSender()
            disconnectGLKVMWebSocket()
        case .glkvmWebSocket:
            Task { [weak self] in
                await self?.reconnectGLKVMWebSocketIfNeeded()
            }
        }
    }

    func disconnectGLKVMWebSocket() {
        unlockPointer()
        stopMouseMoveSender()
        deviceEventTask?.cancel()
        deviceEventTask = nil
        hidReconnectTask?.cancel()
        hidReconnectTask = nil
        let ws = glkvmWebSocketClient
        glkvmWebSocketClient = nil
        telemetry?.update { $0.clearDevice() }
        if let ws {
            enqueueHIDCommand(label: "release inputs") {
                // A socket whose handshake never completed has nothing held on the device, and a
                // send on it would sit in the queue until URLSession gives up on the connect.
                guard await ws.isConnected else { return }
                try await ws.releaseAllHIDInputs()
            }
        }
        Task { [weak self] in
            await self?.hidCommandTail?.value
            await ws?.disconnect()
        }
    }

    /// Quiesces input for process exit: stops capturing, lets queued HID commands drain, releases
    /// every key and button still held on the remote, then closes the HID socket. Nothing is
    /// accepted for sending afterwards. A stuck socket cannot hold this up for long: the first
    /// frame it does not take times out (see `WebSocketClient.Timing`) and closes it, and
    /// everything queued behind fails at once.
    func shutdown() async {
        remotePaste.cancelAll()
        stopFullInputCapture()  // unlocks the pointer, which queues releases for held buttons
        stopMouseMoveSender()
        mouseModeRefreshTask?.cancel()
        mouseModeRefreshTask = nil
        deviceMouseModeRefreshDebounce?.cancel()
        deviceMouseModeRefreshDebounce = nil
        deviceEventTask?.cancel()
        deviceEventTask = nil
        hidReconnectTask?.cancel()
        hidReconnectTask = nil

        let ws = glkvmWebSocketClient
        glkvmWebSocketClient = nil
        telemetry?.update { $0.clearDevice() }
        if let ws {
            enqueueHIDCommand(label: "release inputs") {
                guard await ws.isConnected else { return }
                try await ws.releaseAllHIDInputs()
            }
        }
        acceptsHIDCommands = false

        await hidCommandTail?.value
        hidCommandTail = nil
        await ws?.disconnect()
    }

    func startKeyboardCapture() {
        guard keyEventMonitor == nil else {
            isCapturing = true
            isKeyboardCaptureEnabled = true
            syncRemoteCapsLock()
            return
        }

        isCapturing = true
        isKeyboardCaptureEnabled = true

        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            return self.routeMonitoredKeyEvent(event)
        }

        // A local monitor sees nothing while another app is active, so a key held when focus
        // leaves never gets its key-up, and Caps Lock can be toggled behind our back.
        let center = NotificationCenter.default
        keyboardFocusObservers = [
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.releaseRemoteHeldKeys()
                }
            },
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.syncRemoteCapsLock()
                }
            },
        ]
        syncRemoteCapsLock()
    }

    func stopKeyboardCapture() {
        isKeyboardCaptureEnabled = false

        if let monitor = keyEventMonitor {
            NSEvent.removeMonitor(monitor)
            keyEventMonitor = nil
        }
        for observer in keyboardFocusObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        keyboardFocusObservers.removeAll()
        releaseRemoteHeldKeys()

        if !isMouseCaptureEnabled {
            isCapturing = false
        }
    }
    
    func startMouseCapture() {
        isCapturing = true
        isMouseCaptureEnabled = true
        refreshMouseModeFromDevice()
    }
    
    func stopMouseCapture() {
        unlockPointer()
        isMouseCaptureEnabled = false
        
        if let monitor = mouseEventMonitor {
            NSEvent.removeMonitor(monitor)
            mouseEventMonitor = nil
        }
        
        if !isKeyboardCaptureEnabled {
            isCapturing = false
        }
    }
    
    /// What the key monitor does with an event: handle it and keep it from the window while
    /// capture is on, or return it untouched. A local monitor sees every window's events, so one
    /// for another window — another console's, or a sheet's — is returned untouched for that
    /// window's own handling. Internal so the tests can drive it with synthesized events.
    func routeMonitoredKeyEvent(_ event: NSEvent) -> NSEvent? {
        guard focusGate.owns(eventWindowNumber: event.windowNumber) else { return event }
        handleKeyEvent(event)
        return isKeyboardCaptureEnabled ? nil : event
    }

    // MARK: - The session's window

    /// Follows the session's window: which one it is, and when it becomes and stops being key.
    /// `ConsoleSession` calls this once the window exists, and with nil when it closes.
    func attach(to window: NSWindow?) {
        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        windowObservers.removeAll()
        if focusGate.isWindowKey {
            windowDidResignKey()
        }
        self.window = window
        guard let window else { return }

        let center = NotificationCenter.default
        windowObservers = [
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let window = note.object as? NSWindow else { return }
                    self?.windowDidBecomeKey(windowNumber: window.windowNumber)
                }
            },
            // Also posted when Overlook stops being the active app, so this covers that too.
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.windowDidResignKey()
                }
            },
        ]
        if window.isKeyWindow {
            windowDidBecomeKey(windowNumber: window.windowNumber)
        }
    }

    /// The window came forward: from now on its events are this session's. Caps Lock may have
    /// been toggled while another window or app had the keyboard, so it is brought back into line
    /// as when Overlook itself comes forward. Modifiers are not pressed on the target here: one
    /// held across the switch was pressed for the other window, and its release is not ours.
    func windowDidBecomeKey(windowNumber: Int) {
        focusGate.windowDidBecomeKey(windowNumber: windowNumber)
        syncRemoteCapsLock()
    }

    /// The window stopped being key, to another console, a sheet, or another app. Its keys'
    /// and buttons' releases will go elsewhere, so everything held on this target is released now
    /// and a captured pointer is let go.
    func windowDidResignKey() {
        focusGate.windowDidResignKey()
        releaseRemoteHeldKeys()
        unlockPointer()
        releaseRemoteHeldButtons()
    }

    private func handleKeyEvent(_ event: NSEvent) {
        guard isKeyboardCaptureEnabled else { return }

        switch event.type {
        case .keyDown, .keyUp:
            let keyCode = event.keyCode
            let isKeyDown = event.type == .keyDown
            let modifiers = event.modifierFlags

            // A release (or repeat) of a key pressed while another window was key belongs to
            // nobody: that window has already released it on its own target.
            guard focusGate.admitKey(keyCode, isDown: isKeyDown, isRepeat: event.isARepeat) else { return }

            if !isKeyDown, suppressedKeyUps.contains(keyCode) {
                suppressedKeyUps.remove(keyCode)
                return
            }

            if isKeyDown, modifiers.contains(.command) {
                // Overlook's own chords, kept rather than sent; see `InterceptedChord`.
                if let chord = Self.interceptedChord(keyCode: keyCode, modifiers: modifiers) {
                    // Once per physical press: the auto-repeats of a held chord are swallowed
                    // here, so a held ⌘V pastes once, ⌘C toggles copy mode once and ⇧⌘R cannot
                    // toggle twice. They still never reach the target.
                    guard !event.isARepeat else { return }
                    prepareForLocalCommandShortcut()
                    suppressedKeyUps.insert(keyCode)
                    switch chord {
                    case .copyMode:
                        onLocalShortcut?(.toggleCopyMode)
                    case .paste:
                        pasteClipboardToRemote()
                    case .saveScreenshot:
                        onLocalShortcut?(.saveScreenshot)
                    case .toggleRecording:
                        onLocalShortcut?(.toggleRecording)
                    // The termination path releases held keys and hangs up before the process
                    // exits.
                    case .quit:
                        terminateApp()
                    }
                    return
                }

                if let pending = pendingCommandKeyCode,
                   commandKeySentToRemote == false,
                   transportMode == .glkvmWebSocket,
                   let ws = glkvmWebSocketClient,
                   let metaKey = glkvmKeyForMacKeyCode(pending),
                   let keyName = glkvmKeyForMacKeyCode(keyCode) {
                    activeCommandKeyCode = pending
                    pendingCommandKeyCode = nil
                    commandKeySentToRemote = true
                    remoteHeldKeys.insert(metaKey)
                    remoteHeldKeys.insert(keyName)

                    enqueueHIDCommand(label: "key combination") {
                        try await ws.sendHidKey(key: metaKey, state: true)
                        try await ws.sendHidKey(key: keyName, state: true)
                    }
                    return
                }

                flushPendingCommandKeyIfNeeded(timestamp: event.timestamp, modifiers: modifiers)
            }

            let keyEvent = KeyEvent(
                keyCode: keyCode,
                isKeyDown: isKeyDown,
                modifiers: modifiers,
                timestamp: event.timestamp
            )

            sendKeyEvent(keyEvent)

        case .flagsChanged:
            releasePointerLockIfChordHeld(event.modifierFlags)
            let keyCode = event.keyCode
            guard let keyName = glkvmKeyForMacKeyCode(keyCode) else { return }

            let flags = event.modifierFlags
            let isDown: Bool
            switch keyName {
            case "ShiftLeft", "ShiftRight", "ControlLeft", "ControlRight", "AltLeft", "AltRight":
                isDown = Self.isModifierSideDown(keyName, flags: flags)
                guard focusGate.admitKey(keyCode, isDown: isDown) else { return }
            case "MetaLeft", "MetaRight":
                isDown = Self.isModifierSideDown(keyName, flags: flags)
                guard focusGate.admitKey(keyCode, isDown: isDown) else { return }
                if isDown {
                    pendingCommandKeyCode = keyCode
                    activeCommandKeyCode = nil
                    commandKeySentToRemote = false
                    return
                }

                if commandKeySentToRemote {
                    let keyEvent = KeyEvent(
                        keyCode: activeCommandKeyCode ?? keyCode,
                        isKeyDown: false,
                        modifiers: flags,
                        timestamp: event.timestamp
                    )
                    sendKeyEvent(keyEvent)
                }

                clearPendingCommandKey()
                return
            case "CapsLock":
                // macOS reports a lock *toggle*, one event per press, never the key's release.
                // Forwarding that as down-then-(next press)-up made the target toggle on every
                // other press. Each toggle here is a full press on the target.
                sendCapsLockTap(timestamp: event.timestamp)
                return
            default:
                return
            }

            let keyEvent = KeyEvent(
                keyCode: keyCode,
                isKeyDown: isDown,
                modifiers: flags,
                timestamp: event.timestamp
            )
            sendKeyEvent(keyEvent)

        default:
            break
        }
    }

    /// Device-dependent modifier bits (IOKit's `NX_DEVICE…KEYMASK`) in `modifierFlags.rawValue`,
    /// as (this side, other side). The device-independent flags (`.shift`, …) stay set while
    /// *either* side is down, so releasing Left Shift with Right Shift held read as a press and
    /// Left Shift stayed down on the target.
    private static let modifierSideMasks: [String: (family: NSEvent.ModifierFlags, mask: UInt, other: UInt)] = [
        "ControlLeft": (.control, 0x0001, 0x2000),
        "ControlRight": (.control, 0x2000, 0x0001),
        "ShiftLeft": (.shift, 0x0002, 0x0004),
        "ShiftRight": (.shift, 0x0004, 0x0002),
        "MetaLeft": (.command, 0x0008, 0x0010),
        "MetaRight": (.command, 0x0010, 0x0008),
        "AltLeft": (.option, 0x0020, 0x0040),
        "AltRight": (.option, 0x0040, 0x0020),
    ]

    /// The Mac key codes of the modifiers `resyncRemoteKeys` can press again.
    private static let modifierKeyCodes: [String: UInt16] = [
        "MetaLeft": 55, "MetaRight": 54,
        "ShiftLeft": 56, "ShiftRight": 60,
        "AltLeft": 58, "AltRight": 61,
        "ControlLeft": 59, "ControlRight": 62,
    ]

    static func isModifierSideDown(_ keyName: String, flags: NSEvent.ModifierFlags) -> Bool {
        guard let side = modifierSideMasks[keyName] else { return false }
        guard flags.contains(side.family) else { return false }
        let raw = flags.rawValue
        if raw & side.mask != 0 { return true }
        if raw & side.other != 0 { return false }
        // No side bits at all (some remappers and synthesized events): the family flag is all
        // there is to go on.
        return true
    }

    private func sendCapsLockTap(timestamp: TimeInterval = CACurrentMediaTime()) {
        let capsLockKeyCode: UInt16 = 57
        sendKeyEvent(KeyEvent(keyCode: capsLockKeyCode, isKeyDown: true, modifiers: [], timestamp: timestamp))
        sendKeyEvent(KeyEvent(keyCode: capsLockKeyCode, isKeyDown: false, modifiers: [], timestamp: timestamp))
    }

    /// Releases every key still held on the target. Runs when capture stops and when Overlook
    /// loses focus; the keys' real key-ups will go to whichever app is active instead.
    private func releaseRemoteHeldKeys() {
        let held = remoteHeldKeys
        remoteHeldKeys.removeAll()
        clearPendingCommandKey()
        suppressedKeyUps.removeAll()
        guard !held.isEmpty, transportMode == .glkvmWebSocket, let ws = glkvmWebSocketClient else { return }
        self.log.info(.hid, "Releasing keys held on the target: \(held.sorted().joined(separator: ", "))")
        enqueueHIDCommand(label: "release held keys") {
            for key in held {
                try await ws.sendHidKey(key: key, state: false)
            }
        }
    }

    /// Releases every mouse button still held on the target, when this window stops being key.
    private func releaseRemoteHeldButtons() {
        for button in remoteHeldButtons {
            sendMouseButtonEvent(MouseButtonEvent(
                button: button,
                isDown: false,
                position: CGPoint(x: -1, y: -1),
                timestamp: CACurrentMediaTime()
            ))
        }
    }

    /// Brings the target's Caps Lock into line with this Mac's, using the keyboard LED state
    /// kvmd reports. Runs when capture starts, when Overlook or this window comes forward, and when
    /// the first LED report arrives on a new socket — the moments a toggle may have happened unseen.
    /// Only while this window is key: the keyboard is another window's otherwise.
    private func syncRemoteCapsLock() {
        guard isKeyboardCaptureEnabled, NSApp.isActive, focusGate.isWindowKey, remoteCapsLockLEDIsLive, capsLockVerifyTask == nil,
              transportMode == .glkvmWebSocket, glkvmWebSocketClient != nil,
              let remote = remoteCapsLockLED else { return }
        let local = NSEvent.modifierFlags.contains(.capsLock)
        guard local != remote else { return }

        self.log.info(.hid, "Caps Lock is \(local ? "on" : "off") here but \(remote ? "on" : "off") on the target; toggling it")
        sendCapsLockTap()
        capsLockVerifyTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, !Task.isCancelled else { return }
            self.capsLockVerifyTask = nil
            if self.remoteCapsLockLED == remote {
                self.remoteCapsLockLEDIsLive = false
                self.log.notice(.hid, "Target's Caps Lock LED did not follow; not syncing Caps Lock on this connection")
            }
        }
    }

    /// Puts the target's keyboard in a known state when a new HID socket comes up. Whatever was
    /// held when the previous socket went away is cleared — after a drop its key-ups failed, and
    /// after a crash nothing sent them — and the modifiers physically held right now are pressed
    /// again. Caps Lock is handled separately, by `syncRemoteCapsLock` on the first LED report.
    private func resyncRemoteKeys(through ws: GLKVMClient.WebSocketClient) {
        var toPress: [String] = []
        // Only the key window's session presses what is physically held: in any other window
        // those keys belong to the console in front.
        if isKeyboardCaptureEnabled, NSApp.isActive, focusGate.isWindowKey {
            let flags = NSEvent.modifierFlags
            for (left, right) in [("ShiftLeft", "ShiftRight"), ("ControlLeft", "ControlRight"), ("AltLeft", "AltRight")] {
                guard let leftSide = Self.modifierSideMasks[left], flags.contains(leftSide.family) else { continue }
                let leftDown = flags.rawValue & leftSide.mask != 0
                let rightDown = flags.rawValue & leftSide.other != 0
                // No side bits at all: one of them is down, and which one rarely matters.
                if leftDown || !rightDown { toPress.append(left) }
                if rightDown { toPress.append(right) }
            }
            // Command is only on the target once it has been combined with another key; a
            // still-pending Command stays pending.
            if commandKeySentToRemote {
                if flags.contains(.command), let code = activeCommandKeyCode, let metaKey = glkvmKeyForMacKeyCode(code) {
                    toPress.append(metaKey)
                } else {
                    clearPendingCommandKey()
                }
            }
        } else {
            clearPendingCommandKey()
        }

        let pressAgain = toPress
        remoteHeldKeys = Set(pressAgain)
        remoteHeldButtons.removeAll()
        // Pressed without a key-down of their own, so their key-ups have to be let through.
        focusGate.notePressed(pressAgain.compactMap { Self.modifierKeyCodes[$0] })
        self.log.info(.hid, pressAgain.isEmpty
            ? "Cleared held keys on the target"
            : "Cleared held keys on the target; pressing again: \(pressAgain.joined(separator: ", "))")
        enqueueHIDCommand(label: "resync keyboard") {
            try await ws.releaseAllHIDInputs()
            for key in pressAgain {
                try await ws.sendHidKey(key: key, state: true)
            }
        }
    }

    private func resetRemoteKeyboardState() {
        remoteHeldKeys.removeAll()
        remoteHeldButtons.removeAll()
        remoteCapsLockLED = nil
        remoteCapsLockLEDIsLive = true
        capsLockVerifyTask?.cancel()
        capsLockVerifyTask = nil
    }

    private func prepareForLocalCommandShortcut() {
        if commandKeySentToRemote,
           transportMode == .glkvmWebSocket,
           let ws = glkvmWebSocketClient,
           let code = activeCommandKeyCode,
           let metaKey = glkvmKeyForMacKeyCode(code) {
            remoteHeldKeys.remove(metaKey)
            enqueueHIDCommand(label: "modifier release") {
                try await ws.sendHidKey(key: metaKey, state: false)
            }
        }

        pendingCommandKeyCode = activeCommandKeyCode ?? pendingCommandKeyCode
        activeCommandKeyCode = nil
        commandKeySentToRemote = false
    }

    private func clearPendingCommandKey() {
        pendingCommandKeyCode = nil
        activeCommandKeyCode = nil
        commandKeySentToRemote = false
    }

    private func flushPendingCommandKeyIfNeeded(timestamp: TimeInterval, modifiers: NSEvent.ModifierFlags) {
        guard let pendingCommandKeyCode, commandKeySentToRemote == false else { return }
        activeCommandKeyCode = pendingCommandKeyCode
        self.pendingCommandKeyCode = nil
        commandKeySentToRemote = true

        let keyEvent = KeyEvent(
            keyCode: activeCommandKeyCode ?? pendingCommandKeyCode,
            isKeyDown: true,
            modifiers: modifiers,
            timestamp: timestamp
        )
        sendKeyEvent(keyEvent)
    }

    private func pasteClipboardToRemote() {
        guard glkvmClient != nil else { return }
        guard let text = readClipboardText() else { return }
        pasteToRemote(text)
    }

    /// Types `text` into the target, after any paste still under way. Internal so tests can paste
    /// without going through the pasteboard.
    @discardableResult
    func pasteToRemote(_ text: String) -> Task<Void, Never>? {
        guard let client = glkvmClient else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return remotePaste.enqueue(trimmed, to: client, log: log)
    }
    
    func sendClick(at location: CGPoint, in geometry: GeometryProxy, videoSize: CGSize? = nil) {
        let normalizedPosition = normalizePointInViewToVideo(
            pointInView: location,
            viewSize: geometry.size,
            videoSize: videoSize
        )
        
        let clickEvent = MouseButtonEvent(
            button: .left,
            isDown: true,
            position: normalizedPosition,
            timestamp: CACurrentMediaTime()
        )
        
        sendMouseButtonEvent(clickEvent)
        
        // Send release event after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            let releaseEvent = MouseButtonEvent(
                button: .left,
                isDown: false,
                position: normalizedPosition,
                timestamp: CACurrentMediaTime()
            )
            self.sendMouseButtonEvent(releaseEvent)
        }
    }
    
    private func sendKeyEvent(_ event: KeyEvent) {
        sentInputObserver?(.key(event.keyCode, isDown: event.isKeyDown))
        if transportMode == .glkvmWebSocket,
           let key = glkvmKeyForMacKeyCode(event.keyCode),
           let ws = glkvmWebSocketClient {
            if event.isKeyDown {
                remoteHeldKeys.insert(key)
            } else {
                remoteHeldKeys.remove(key)
            }
            enqueueHIDCommand(label: event.isKeyDown ? "key down" : "key up") {
                try await ws.sendHidKey(key: key, state: event.isKeyDown)
            }
            return
        }

        let inputEvent = InputEvent(
            type: "keyboard",
            data: [
                "keyCode": .int(Int(event.keyCode)),
                "isKeyDown": .bool(event.isKeyDown),
                "modifiers": .int(Int(event.modifiers.rawValue)),
                "timestamp": .double(event.timestamp)
            ]
        )
        
        webRTCManager?.sendInputEvent(inputEvent)
    }
    
    private func sendMouseButtonEvent(_ event: MouseButtonEvent) {
        sentInputObserver?(.button(event.button, isDown: event.isDown))
        if event.isDown {
            remoteHeldButtons.insert(event.button)
        } else {
            remoteHeldButtons.remove(event.button)
        }
        if transportMode == .glkvmWebSocket,
           let button = glkvmMouseButtonName(event.button),
           let ws = glkvmWebSocketClient {
            let shouldMove = isGLKVMAbsoluteMouseMode && isNormalized(event.position)
            let absolutePoint = shouldMove ? glkvmAbsolutePoint(fromNormalized: event.position) : nil
            enqueueHIDCommand(label: event.isDown ? "mouse down" : "mouse up") {
                if let absolutePoint {
                    try await ws.sendHidMouseMove(toX: absolutePoint.0, toY: absolutePoint.1)
                }
                try await ws.sendHidMouseButton(button: button, state: event.isDown)
            }
            return
        }

        let inputEvent = InputEvent(
            type: "mouse-button",
            data: [
                "button": .int(event.button.rawValue),
                "isDown": .bool(event.isDown),
                "x": .double(event.position.x),
                "y": .double(event.position.y),
                "timestamp": .double(event.timestamp)
            ]
        )
        
        webRTCManager?.sendInputEvent(inputEvent)
    }
    
    /// WebRTC data-channel transport only; GLKVM movement goes through the pending-move sender.
    private func sendMouseMoveEvent(_ event: MouseMoveEvent) {
        let inputEvent = InputEvent(
            type: "mouse-move",
            data: [
                "x": .double(event.position.x),
                "y": .double(event.position.y),
                "timestamp": .double(event.timestamp)
            ]
        )
        
        webRTCManager?.sendInputEvent(inputEvent)
    }
    
    /// The wheel report the HID socket sends for a scroll event: each axis rounded to a whole
    /// step and clamped to the report's signed byte. The deltas are already in the target's
    /// direction (`targetScrollSteps`): positive X pans right, positive Y scrolls up.
    nonisolated static func glkvmWheelDeltas(deltaX: CGFloat, deltaY: CGFloat) -> (x: Int, y: Int) {
        func wheel(_ delta: CGFloat) -> Int {
            min(max(Int(delta.rounded()), -127), 127)
        }
        return (wheel(deltaX), wheel(deltaY))
    }

    private func sendMouseScrollEvent(_ event: MouseScrollEvent) {
        sentInputObserver?(.scroll(deltaX: event.deltaX, deltaY: event.deltaY))
        if transportMode == .glkvmWebSocket, let ws = glkvmWebSocketClient {
            let (dx, dy) = Self.glkvmWheelDeltas(deltaX: event.deltaX, deltaY: event.deltaY)
            // A report that moves neither axis scrolls nothing; do not queue it.
            guard dx != 0 || dy != 0 else { return }
            enqueueHIDCommand(label: "mouse wheel") {
                try await ws.sendHidMouseWheel(deltaX: dx, deltaY: dy)
            }
            return
        }

        // The data-channel event carries the same values as the HID report, in the target's
        // direction: positive deltaX pans right, positive deltaY scrolls up.
        let inputEvent = InputEvent(
            type: "mouse-scroll",
            data: [
                "deltaX": .double(event.deltaX),
                "deltaY": .double(event.deltaY),
                "timestamp": .double(event.timestamp)
            ]
        )
        
        webRTCManager?.sendInputEvent(inputEvent)
    }
    
    func sendKeyCombination(_ keys: [UInt16], modifiers: NSEvent.ModifierFlags) {
        for keyCode in keys {
            let keyDownEvent = KeyEvent(
                keyCode: keyCode,
                isKeyDown: true,
                modifiers: modifiers,
                timestamp: CACurrentMediaTime()
            )
            sendKeyEvent(keyDownEvent)
        }
        
        // Send key up events after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            for keyCode in keys.reversed() {
                let keyUpEvent = KeyEvent(
                    keyCode: keyCode,
                    isKeyDown: false,
                    modifiers: modifiers,
                    timestamp: CACurrentMediaTime()
                )
                self.sendKeyEvent(keyUpEvent)
            }
        }
    }
    
    func sendText(_ text: String) {
        for character in text {
            let keyCode = self.keyCodeForCharacter(character)
            let keyEvent = KeyEvent(
                keyCode: keyCode,
                isKeyDown: true,
                modifiers: [],
                timestamp: CACurrentMediaTime()
            )
            sendKeyEvent(keyEvent)
            
            // Send key up event
            let keyUpEvent = KeyEvent(
                keyCode: keyCode,
                isKeyDown: false,
                modifiers: [],
                timestamp: CACurrentMediaTime()
            )
            sendKeyEvent(keyUpEvent)
        }
    }
    
    func keyCodeForCharacter(_ character: Character) -> UInt16 {
        // Basic mapping for common characters
        // In a real implementation, you'd want a more comprehensive mapping
        switch character {
        case "a": return 0
        case "b": return 11
        case "c": return 8
        case "d": return 2
        case "e": return 14
        case "f": return 3
        case "g": return 5
        case "h": return 4
        case "i": return 34
        case "j": return 38
        case "k": return 40
        case "l": return 37
        case "m": return 46
        case "n": return 45
        case "o": return 31
        case "p": return 35
        case "q": return 12
        case "r": return 15
        case "s": return 1
        case "t": return 17
        case "u": return 32
        case "v": return 9
        case "w": return 13
        case "x": return 7
        case "y": return 16
        case "z": return 6
        case " ": return 49
        case "\n": return 36
        case ",": return 43
        case ".": return 47
        case "/": return 44
        case ";": return 41
        case "'": return 39
        case "[": return 33
        case "]": return 30
        case "\\": return 42
        case "`": return 50
        case "-": return 27
        case "=": return 24
        default: return 0
        }
    }
    
    deinit {
        if let monitor = keyEventMonitor {
            NSEvent.removeMonitor(monitor)
            keyEventMonitor = nil
        }

        if let monitor = mouseEventMonitor {
            NSEvent.removeMonitor(monitor)
            mouseEventMonitor = nil
        }

        mouseModeRefreshTask?.cancel()
        mouseModeRefreshTask = nil

        for observer in pointerLockObservers + keyboardFocusObservers + windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        deviceEventTask?.cancel()
        capsLockVerifyTask?.cancel()
        deviceMouseModeRefreshDebounce?.cancel()

        // isCursorHidden is a plain stored Bool that mirrors the lock state (set in lockPointer,
        // cleared in unlockPointer); the @Published lock flag is not accessible from deinit.
        if isCursorHidden {
            Task { @MainActor in
                NSCursor.unhide()
                _ = CGAssociateMouseAndMouseCursorPosition(1)
            }
        }
    }

    private func reconnectGLKVMWebSocketIfNeeded() async {
        guard transportMode == .glkvmWebSocket, let client = glkvmClient else { return }

        let existing = glkvmWebSocketClient
        let connected = await existing?.isConnected ?? false
        let connecting = await existing?.isConnecting ?? false
        guard !connected, !connecting else { return }
        // The state checks suspended; make sure nobody swapped the client or the socket meanwhile,
        // and install the replacement before closing the old one so no second caller can race in.
        guard !Task.isCancelled, glkvmClient === client, glkvmWebSocketClient === existing else { return }

        let ws = try? client.makeWebSocketClient(stream: false)
        glkvmWebSocketClient = ws
        await ws?.connect()  // now `isConnecting`, so a concurrent caller backs off
        await existing?.disconnect()
        if let ws {
            startDeviceEventListener(ws)
            publishHIDLink(.connecting)
        } else {
            publishHIDLink(.disconnected)
        }
        refreshMouseModeFromDevice()
    }

    /// Runs `operation` after every previously queued HID command. A failure schedules a socket
    /// reconnect; the command itself is not retried (input is time-sensitive). Returns the queued
    /// task so a caller can wait for it, or nil if input is no longer accepted.
    @discardableResult
    private func enqueueHIDCommand(
        label: String,
        operation: @escaping @Sendable () async throws -> Void
    ) -> Task<Void, Never>? {
        guard acceptsHIDCommands else { return nil }
        let predecessor = hidCommandTail
        hidQueueDepth += 1
        // Taken now: the line is still worth logging if the manager is gone by the time it fails.
        let log = self.log
        let task = Task { [weak self] in
            defer { self?.hidQueueDepth -= 1 }
            await predecessor?.value
            guard !Task.isCancelled else { return }
            do {
                try await operation()
            } catch {
                log.warning(.hid, "HID \(label) failed: \(error.localizedDescription)")
                self?.scheduleHIDReconnect()
            }
        }
        hidCommandTail = task
        return task
    }

    private func scheduleHIDReconnect() {
        guard acceptsHIDCommands, hidReconnectTask == nil, glkvmClient != nil else { return }
        self.log.warning(.hid, "HID socket dropped; starting reconnect")
        publishHIDLink(.reconnecting)
        hidReconnectTask = Task { [weak self] in
            let delays: [UInt64] = [250_000_000, 500_000_000, 1_000_000_000, 2_000_000_000]
            for delay in delays {
                guard !Task.isCancelled, let self else { return }
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else { return }
                await self.reconnectGLKVMWebSocketIfNeeded()
                if await self.glkvmWebSocketClient?.isConnected == true {
                    self.hidReconnectTask = nil
                    return
                }
            }
            self?.hidReconnectTask = nil
        }
    }

    // MARK: - Pointer lock (relative mouse mode)

    /// Captures the pointer: the hardware cursor is frozen in place and hidden while movement
    /// deltas keep flowing to the remote. Requires relative mode, mouse capture, and this session's
    /// own window being key — not merely some window of the app.
    @discardableResult
    func lockPointer() -> Bool {
        guard !isPointerLocked, isMouseCaptureEnabled, isRelativeMouseMode else { return false }
        guard NSApp.isActive, focusGate.isWindowKey, let window, window.isKeyWindow else { return false }

        relativeResidual = .zero
        pendingRelativeMouseMove = nil

        _ = CGAssociateMouseAndMouseCursorPosition(0)
        if !isCursorHidden {
            NSCursor.hide()
            isCursorHidden = true
        }

        if let monitor = mouseEventMonitor {
            NSEvent.removeMonitor(monitor)
        }
        mouseEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .flagsChanged]
        ) { [weak self] event in
            guard let self else { return event }
            return self.handlePointerLockEvent(event)
        }

        // Observers run on the main queue; unlock synchronously so the cursor is restored before
        // the app has fully left the foreground.
        let center = NotificationCenter.default
        pointerLockObservers = [
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.unlockPointer()
                }
            },
            center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.unlockPointer()
                }
            },
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.unlockPointer()
                }
            },
        ]

        isPointerLocked = true
        return true
    }

    /// Releases a captured pointer and restores the cursor where it was. Safe to call when unlocked.
    func unlockPointer() {
        captureClickButton = nil
        guard isPointerLocked else { return }
        isPointerLocked = false

        // A button still held on the remote would otherwise stay down: its release arrives after
        // unlock and is dropped by handleVideoMouseButton.
        for button in heldRelativeButtons {
            sendMouseButtonEvent(MouseButtonEvent(
                button: button,
                isDown: false,
                position: CGPoint(x: -1, y: -1),
                timestamp: CACurrentMediaTime()
            ))
        }
        heldRelativeButtons.removeAll()

        if let monitor = mouseEventMonitor {
            NSEvent.removeMonitor(monitor)
            mouseEventMonitor = nil
        }
        for observer in pointerLockObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        pointerLockObservers.removeAll()

        _ = CGAssociateMouseAndMouseCursorPosition(1)
        if isCursorHidden {
            NSCursor.unhide()
            isCursorHidden = false
        }
        relativeResidual = .zero
    }

    private func releasePointerLockIfChordHeld(_ flags: NSEvent.ModifierFlags) {
        guard isPointerLocked else { return }
        let held = flags.intersection([.control, .option, .shift, .command])
        if held == Self.pointerReleaseChord {
            unlockPointer()
        }
    }

    private func handlePointerLockEvent(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .flagsChanged:
            releasePointerLockIfChordHeld(event.modifierFlags)
            return event
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            guard isPointerLocked, isMouseCaptureEnabled, focusGate.admitsPointerMotion else { return event }
            handleLockedPointerMove(event)
            return nil
        default:
            return event
        }
    }

    private func handleLockedPointerMove(_ event: NSEvent) {
        // NSEvent deltas for mouse-moved / dragged events are in display space (y grows downward),
        // which is also the HID relative-report convention, so no axis flip is applied.
        let sensitivity = CGFloat(relativeSensitivity)

        if useUnacceleratedRelativeInput, let counts = unacceleratedMovement(of: event) {
            // Raw counts go out as counts — no view-to-remote scaling, which only makes sense for
            // on-screen distances. At 1.00× the target sees what a directly attached mouse would
            // send and applies its own pointer settings once.
            accumulateRelativeDelta(CGSize(width: counts.width * sensitivity, height: counts.height * sensitivity))
            return
        }

        let scale = relativeDeltaScale * sensitivity
        accumulateRelativeDelta(CGSize(width: event.deltaX * scale, height: event.deltaY * scale))
    }

    /// The event's unaccelerated pointer movement in device counts, or nil when it should not be
    /// used: macOS reports no accelerated motion (an idle trackpad emits raw sensor residual with a
    /// zero delta — the dead-zone rule Firefox applies), or the system left the fields empty
    /// (synthesized events, some devices), in which case the caller falls back to accelerated
    /// deltas. Read as doubles: the fields carry fractional movement, and an integer read would
    /// drop slow movement entirely.
    private func unacceleratedMovement(of event: NSEvent) -> CGSize? {
        guard event.deltaX != 0 || event.deltaY != 0, let cgEvent = event.cgEvent else { return nil }
        let rawX = cgEvent.getDoubleValueField(.eventUnacceleratedPointerMovementX)
        let rawY = cgEvent.getDoubleValueField(.eventUnacceleratedPointerMovementY)
        guard rawX.isFinite, rawY.isFinite, rawX != 0 || rawY != 0 else { return nil }
        return CGSize(width: rawX, height: rawY)
    }

    /// Refreshes the remote-pixels-per-point scale used by accelerated relative input. The video
    /// surface calls this on size changes because its mouse-move path is silent while the pointer
    /// is locked (the lock monitor swallows those events).
    func updateRelativeDeltaScale(viewSize: CGSize, videoSize: CGSize?) {
        relativeDeltaScale = computeRelativeDeltaScale(viewSize: viewSize, videoSize: videoSize)
    }

    /// Remote pixels per view point for the letterboxed video, so a captured pointer travels the
    /// same on-screen distance the local cursor would have.
    func computeRelativeDeltaScale(viewSize: CGSize, videoSize: CGSize?) -> CGFloat {
        guard viewSize.width > 0, viewSize.height > 0,
              let videoSize, videoSize.width > 0, videoSize.height > 0 else { return 1.0 }
        let content = videoContentRect(viewSize: viewSize, videoSize: videoSize)
        guard content.width > 0 else { return 1.0 }
        return videoSize.width / content.width
    }

    // MARK: - Device events

    private func startDeviceEventListener(_ ws: GLKVMClient.WebSocketClient) {
        deviceEventTask?.cancel()
        // The new socket opens with kvmd's full state; take the LED state fresh from it.
        remoteCapsLockLED = nil
        capsLockVerifyTask?.cancel()
        capsLockVerifyTask = nil
        deviceEventTask = Task { @MainActor [weak self] in
            var isFirstEvent = true
            for await event in ws.events {
                if Task.isCancelled { break }
                guard let self else { return }
                if isFirstEvent {
                    // The device answered: the socket is up. (kvmd sends its full state on open.)
                    isFirstEvent = false
                    self.hidDropReconnectRounds = 0
                    self.publishHIDLink(.connected)
                    if self.glkvmWebSocketClient === ws {
                        self.resyncRemoteKeys(through: ws)
                    }
                }
                self.handleDeviceEvent(event)
            }
            // The stream ends when the socket drops (receive error, or the ping loop noticing a
            // dead connection). Only the current socket's listener may react; a replaced socket's
            // listener ends too, and must not touch its successor.
            guard !Task.isCancelled, let self, self.glkvmWebSocketClient === ws else { return }
            self.publishHIDLink(.disconnected)
            if self.hidDropReconnectRounds < Self.maxHIDDropReconnectRounds {
                self.hidDropReconnectRounds += 1
                self.scheduleHIDReconnect()
            }
        }
    }

    /// Events kvmd pushes over the HID socket. Besides the pong that answers our ping, the ones
    /// used here are the full/partial state of the `hid` and `streamer` subsystems, which arrive
    /// once on connect and then whenever something in them changes.
    /// Internal so tests can hand it events without a socket.
    func handleDeviceEvent(_ event: GLKVMWebSocketEvent) {
        switch event.eventType {
        case "pong":
            telemetry?.update { snapshot in
                if let roundTripMs = event.roundTripMs {
                    snapshot.hidRoundTripMs = roundTripMs
                }
                snapshot.hidQueueDepth = hidQueueDepth
            }
        case "hid", "hid_state":
            applyDeviceHIDState(event.event)
        case "streamer":
            applyDeviceStreamerState(event.event)
        default:
            break
        }
    }

    /// `hid` event: `mouse.absolute` is the mode the device's HID gadget is actually in;
    /// `connected` is its USB link to the target.
    private func applyDeviceHIDState(_ state: JSONValue?) {
        guard let state else { return }
        if let absolute = state["mouse"]?["absolute"]?.boolValue {
            deviceReportedAbsoluteMouse = absolute
            setGLKVMAbsoluteMouseMode(absolute)
        } else if deviceMouseModeRefreshDebounce == nil {
            // Older firmware: the event says the HID state changed but not which mode it is in.
            // Re-read the config, debounced so a burst costs one request.
            deviceMouseModeRefreshDebounce = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                self.deviceMouseModeRefreshDebounce = nil
                self.refreshMouseModeFromDevice()
            }
        }
        if let usbConnected = state["connected"]?.boolValue {
            telemetry?.update { $0.hidUSBConnected = usbConnected }
        }
        if let jiggler = GLKVMJigglerState(hidState: state) {
            applyDeviceJigglerState(jiggler)
        }
        // `keyboard.leds` is the LED state the target's OS last set on the HID gadget.
        if let caps = state["keyboard"]?["leds"]?["caps"]?.boolValue {
            let isFirstReport = remoteCapsLockLED == nil
            remoteCapsLockLED = caps
            if isFirstReport {
                syncRemoteCapsLock()
            }
        }
    }

    /// `streamer` event: partial — only the keys that changed are present. `streamer` carries the
    /// capture pipeline's own state (ustreamer's `/state`); its `source` is the HDMI input.
    private func applyDeviceStreamerState(_ state: JSONValue?) {
        guard let state, let streamer = state["streamer"] else { return }
        telemetry?.update { snapshot in
            guard let source = streamer["source"] else {
                // `streamer: null` — the capture pipeline is not running, so nothing is known.
                snapshot.hdmiOnline = nil
                snapshot.hdmiResolution = nil
                snapshot.hdmiCapturedFps = nil
                snapshot.hdmiDesiredFps = nil
                return
            }
            snapshot.hdmiOnline = source["online"]?.boolValue
            if let width = source["resolution"]?["width"]?.intValue,
               let height = source["resolution"]?["height"]?.intValue,
               width > 0, height > 0 {
                snapshot.hdmiResolution = "\(width)x\(height)"
            } else {
                snapshot.hdmiResolution = nil
            }
            snapshot.hdmiCapturedFps = source["captured_fps"]?.intValue
            snapshot.hdmiDesiredFps = source["desired_fps"]?.intValue
        }
    }

    private func isNormalized(_ point: CGPoint) -> Bool {
        point.x >= 0 && point.x <= 1 && point.y >= 0 && point.y <= 1
    }

    func glkvmAbsolutePoint(fromNormalized point: CGPoint) -> (Int, Int) {
        let clampedX = max(0, min(1, point.x))
        let clampedY = max(0, min(1, point.y))
        let maxAxis = 32767.0

        let signedX = (clampedX * 2.0 - 1.0) * maxAxis
        let signedY = (clampedY * 2.0 - 1.0) * maxAxis

        return (Int(signedX.rounded()), Int(signedY.rounded()))
    }

    func normalizePointInViewToVideo(pointInView: CGPoint, viewSize: CGSize, videoSize: CGSize?) -> CGPoint {
        guard viewSize.width > 0, viewSize.height > 0 else {
            return .zero
        }

        guard let videoSize, videoSize.width > 0, videoSize.height > 0 else {
            let clampedX = max(0, min(1, pointInView.x / viewSize.width))
            let clampedY = max(0, min(1, pointInView.y / viewSize.height))
            return CGPoint(x: clampedX, y: clampedY)
        }

        let contentRect = videoContentRect(viewSize: viewSize, videoSize: videoSize)

        let clampedX = max(contentRect.minX, min(contentRect.maxX, pointInView.x))
        let clampedY = max(contentRect.minY, min(contentRect.maxY, pointInView.y))

        let normalizedX = (clampedX - contentRect.minX) / contentRect.width
        let normalizedY = (clampedY - contentRect.minY) / contentRect.height

        return CGPoint(x: max(0, min(1, normalizedX)), y: max(0, min(1, normalizedY)))
    }

    /// The letterboxed rect the video occupies inside a view of `viewSize`.
    func videoContentRect(viewSize: CGSize, videoSize: CGSize) -> CGRect {
        let viewAspect = viewSize.width / viewSize.height
        let videoAspect = videoSize.width / videoSize.height

        if viewAspect > videoAspect {
            let contentWidth = viewSize.height * videoAspect
            let xOffset = (viewSize.width - contentWidth) / 2.0
            return CGRect(x: xOffset, y: 0, width: contentWidth, height: viewSize.height)
        } else {
            let contentHeight = viewSize.width / videoAspect
            let yOffset = (viewSize.height - contentHeight) / 2.0
            return CGRect(x: 0, y: yOffset, width: viewSize.width, height: contentHeight)
        }
    }

    private func glkvmMouseButtonName(_ button: MouseButton) -> String? {
        switch button {
        case .left:
            return "left"
        case .right:
            return "right"
        case .middle:
            return "middle"
        }
    }

    /// The kvmd key name (a Web `KeyboardEvent.code`) for a Mac virtual key code, for the keyboard
    /// that was typed on last.
    func glkvmKeyForMacKeyCode(_ keyCode: UInt16) -> String? {
        Self.glkvmKey(forMacKeyCode: keyCode, isISOKeyboard: Self.lastKeyboardIsISO())
    }

    /// Whether the keyboard macOS saw last is an ISO one (the type macOS asked about, or was told,
    /// when it was first plugged in).
    nonisolated static func lastKeyboardIsISO() -> Bool {
        KBGetLayoutType(Int16(LMGetKbdType())) == PhysicalKeyboardLayoutType(kKeyboardISO)
    }

    /// The kvmd key name for a Mac virtual key code, or nil for a key kvmd has no name for.
    ///
    /// The names are kvmd's `WEB_TO_EVDEV` keys (`kvmd/keyboard/mappings.py`), which are Web
    /// `KeyboardEvent.code` values; a name kvmd does not know is dropped by the device.
    ///
    /// On an ISO keyboard macOS swaps two codes: the key left of 1 (§ on Apple's ISO layouts)
    /// arrives as `kVK_ISO_Section` and the key between left Shift and Z as `kVK_ANSI_Grave`.
    /// They are swapped back here, as browsers do for `KeyboardEvent.code`, so the target gets
    /// the key at the same position: `Backquote` for the one left of 1, `IntlBackslash` for the
    /// extra one by Shift.
    nonisolated static func glkvmKey(forMacKeyCode keyCode: UInt16, isISOKeyboard: Bool) -> String? {
        var keyCode = keyCode
        if isISOKeyboard {
            if keyCode == 10 {
                keyCode = 50
            } else if keyCode == 50 {
                keyCode = 10
            }
        }

        switch keyCode {
        case 0: return "KeyA"
        case 11: return "KeyB"
        case 8: return "KeyC"
        case 2: return "KeyD"
        case 14: return "KeyE"
        case 3: return "KeyF"
        case 5: return "KeyG"
        case 4: return "KeyH"
        case 34: return "KeyI"
        case 38: return "KeyJ"
        case 40: return "KeyK"
        case 37: return "KeyL"
        case 46: return "KeyM"
        case 45: return "KeyN"
        case 31: return "KeyO"
        case 35: return "KeyP"
        case 12: return "KeyQ"
        case 15: return "KeyR"
        case 1: return "KeyS"
        case 17: return "KeyT"
        case 32: return "KeyU"
        case 9: return "KeyV"
        case 13: return "KeyW"
        case 7: return "KeyX"
        case 16: return "KeyY"
        case 6: return "KeyZ"

        case 18: return "Digit1"
        case 19: return "Digit2"
        case 20: return "Digit3"
        case 21: return "Digit4"
        case 23: return "Digit5"
        case 22: return "Digit6"
        case 26: return "Digit7"
        case 28: return "Digit8"
        case 25: return "Digit9"
        case 29: return "Digit0"

        case 50: return "Backquote"
        case 27: return "Minus"
        case 24: return "Equal"
        case 33: return "BracketLeft"
        case 30: return "BracketRight"
        case 41: return "Semicolon"
        case 39: return "Quote"
        case 42: return "Backslash"
        case 43: return "Comma"
        case 47: return "Period"
        case 44: return "Slash"
        // kVK_ISO_Section: the extra ISO key (see above for the swap on ISO keyboards).
        case 10: return "IntlBackslash"
        // JIS: ¥ left of Backspace, and _ / ろ left of right Shift.
        case 93: return "IntlYen"
        case 94: return "IntlRo"

        case 49: return "Space"
        case 48: return "Tab"
        case 36: return "Enter"
        case 51: return "Backspace"
        case 53: return "Escape"

        case 82: return "Numpad0"
        case 83: return "Numpad1"
        case 84: return "Numpad2"
        case 85: return "Numpad3"
        case 86: return "Numpad4"
        case 87: return "Numpad5"
        case 88: return "Numpad6"
        case 89: return "Numpad7"
        case 91: return "Numpad8"
        case 92: return "Numpad9"
        case 65: return "NumpadDecimal"
        case 67: return "NumpadMultiply"
        case 69: return "NumpadAdd"
        case 78: return "NumpadSubtract"
        case 75: return "NumpadDivide"
        case 76: return "NumpadEnter"
        case 81: return "NumpadEqual"

        // kVK_Help sits where a PC keyboard has Insert, and browsers report it as Insert;
        // kvmd has no "Help".
        case 114: return "Insert"

        case 115: return "Home"
        case 119: return "End"
        case 116: return "PageUp"
        case 121: return "PageDown"
        case 117: return "Delete"

        case 123: return "ArrowLeft"
        case 124: return "ArrowRight"
        case 125: return "ArrowDown"
        case 126: return "ArrowUp"

        case 55: return "MetaLeft"
        case 54: return "MetaRight"
        case 56: return "ShiftLeft"
        case 60: return "ShiftRight"
        case 58: return "AltLeft"
        case 61: return "AltRight"
        case 59: return "ControlLeft"
        case 62: return "ControlRight"
        case 57: return "CapsLock"

        case 122: return "F1"
        case 120: return "F2"
        case 99: return "F3"
        case 118: return "F4"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 100: return "F8"
        case 101: return "F9"
        case 109: return "F10"
        case 103: return "F11"
        case 111: return "F12"

        case 105: return "F13"
        case 107: return "F14"
        case 113: return "F15"
        case 106: return "F16"
        case 64: return "F17"
        case 79: return "F18"
        case 80: return "F19"
        case 90: return "F20"

        default:
            return nil
        }
    }

    private static func sendRelativeMouseMove(_ move: PendingRelativeMouseMove, through ws: GLKVMClient.WebSocketClient) async throws {
        var remainingX = move.deltaX
        var remainingY = move.deltaY

        while remainingX != 0 || remainingY != 0 {
            let dx = clampInt(remainingX, min: -127, max: 127)
            let dy = clampInt(remainingY, min: -127, max: 127)
            try await ws.sendHidMouseRelative(deltaX: dx, deltaY: dy)
            remainingX -= dx
            remainingY -= dy
        }
    }

    private static func clampInt(_ value: Int, min: Int, max: Int) -> Int {
        if value < min { return min }
        if value > max { return max }
        return value
    }
}

// MARK: - Input Event Types
struct KeyEvent {
    let keyCode: UInt16
    let isKeyDown: Bool
    let modifiers: NSEvent.ModifierFlags
    let timestamp: CFTimeInterval
}

struct MouseButtonEvent {
    let button: MouseButton
    let isDown: Bool
    let position: CGPoint
    let timestamp: CFTimeInterval
}

struct MouseMoveEvent {
    let position: CGPoint
    let delta: CGSize
    let timestamp: CFTimeInterval
}

/// Whole wheel steps in the target's direction (see `InputManager.targetScrollSteps`):
/// positive X pans right and positive Y scrolls up, as in a USB HID mouse report.
struct MouseScrollEvent {
    let deltaX: CGFloat
    let deltaY: CGFloat
    let timestamp: CFTimeInterval
}

enum MouseButton: Int, Codable {
    case left = 0
    case right = 1
    case middle = 2
}

// MARK: - Input Capture Extensions
extension InputManager {
    func toggleKeyboardCapture() {
        if isKeyboardCaptureEnabled {
            stopKeyboardCapture()
        } else {
            startKeyboardCapture()
        }
    }
    
    func toggleMouseCapture() {
        if isMouseCaptureEnabled {
            stopMouseCapture()
        } else {
            startMouseCapture()
        }
    }
    
    func startFullInputCapture() {
        startKeyboardCapture()
        startMouseCapture()
    }
    
    func stopFullInputCapture() {
        stopKeyboardCapture()
        stopMouseCapture()
    }
}

// MARK: - Accessibility Permissions Helper
extension InputManager {
    func checkAccessibilityPermissions() -> Bool {
        return AXIsProcessTrusted()
    }
    
    func requestAccessibilityPermissions() {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true]
        AXIsProcessTrustedWithOptions(options as CFDictionary)
    }
    
    func showAccessibilityPermissionDialog() {
        let alert = NSAlert()
        alert.messageText = "Accessibility Permissions Required"
        alert.informativeText = "Overlook needs accessibility permissions to capture keyboard and mouse input for remote control. Please grant permissions in System Preferences > Security & Privacy > Privacy > Accessibility."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Preferences")
        alert.addButton(withTitle: "Cancel")
        
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            // Open System Preferences to Accessibility section
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Input Validation and Filtering
extension InputManager {
    private func shouldCaptureKeyEvent(_ event: NSEvent) -> Bool {
        // Filter out system key combinations that should remain local
        let systemKeyCombinations: [UInt16] = [
            55, // Command
            56, // Shift
            57, // Option
            58, // Control
            59, // Caps Lock
            60, // Function
        ]
        
        return !systemKeyCombinations.contains(event.keyCode)
    }
    
    private func shouldCaptureMouseEvent(_ event: NSEvent) -> Bool {
        // Filter out mouse events that should remain local
        // This is a basic implementation - you might want to add more sophisticated filtering
        return true
    }
}

