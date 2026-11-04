import AppKit

/// A feature of a console window that needs calls the window makes to its delegate: closing
/// through the session (`ConsoleWindowAttachment`), and keeping the video's aspect ratio and the
/// fullscreen chrome (`WindowAspectRatioSetter`). Each has a do-nothing default, so a participant
/// implements only what it handles.
@MainActor
protocol WindowDelegateParticipant: AnyObject {
    /// Whether the window may close now. Any participant answering no keeps it open.
    func windowShouldClose(for window: NSWindow) -> Bool
    /// The size a resize is heading for, adjusted as this participant needs.
    func window(_ window: NSWindow, willResizeTo size: NSSize) -> NSSize
    func windowDidEnterFullScreen(for window: NSWindow)
    func windowDidExitFullScreen(for window: NSWindow)
}

extension WindowDelegateParticipant {
    func windowShouldClose(for window: NSWindow) -> Bool { true }
    func window(_ window: NSWindow, willResizeTo size: NSSize) -> NSSize { size }
    func windowDidEnterFullScreen(for window: NSWindow) {}
    func windowDidExitFullScreen(for window: NSWindow) {}
}

/// Stands in front of the delegate SwiftUI gives a window, once per window, on behalf of every
/// `WindowDelegateParticipant`, and forwards everything else to SwiftUI's delegate.
///
/// Each feature used to put itself in front of whatever delegate it found and forward the rest
/// through a weak reference that nothing ever detached. Two of them chained in whichever order
/// they installed. When the front one went away the window's own delegate reference went nil, and
/// SwiftUI's delegate stopped hearing anything; when the back one went away the front one's
/// forwarding reference did, and since AppKit decides once, as a delegate is set, which messages
/// that delegate answers, it went on sending them — to a `forwardingTarget` that now returned nil,
/// which raises an unrecognized-selector exception.
///
/// Here there is one stand-in per window, kept alive by the window. It holds SwiftUI's delegate
/// strongly while it is installed, so whatever it forwards has somewhere to go, and it holds the
/// participants weakly, calling each only for what it handles and skipping any that have gone.
/// When the last participant unregisters, or the window closes, it puts SwiftUI's delegate back
/// and lets go of everything.
@MainActor
final class WindowDelegateInterposer: NSObject, NSWindowDelegate {
    private static var associationKey: UInt8 = 0

    /// The window's interposer, put in front of the window's delegate if it is not there already.
    static func install(on window: NSWindow) -> WindowDelegateInterposer {
        if let existing = installed(on: window) {
            existing.takeFrontPlaceAgainIfNeeded()
            return existing
        }
        let interposer = WindowDelegateInterposer(window: window)
        objc_setAssociatedObject(window, &associationKey, interposer, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return interposer
    }

    /// The window's interposer, if one is installed.
    static func installed(on window: NSWindow) -> WindowDelegateInterposer? {
        objc_getAssociatedObject(window, &associationKey) as? WindowDelegateInterposer
    }

    private weak var window: NSWindow?
    /// The delegate this one stands in front of: SwiftUI's. Strong while installed, so nothing is
    /// ever forwarded to an object that has gone. Read from the forwarding overrides, which
    /// AppKit declares outside any actor; written only on the main thread.
    nonisolated(unsafe) private(set) var forwardedDelegate: NSWindowDelegate?
    private var participants: [WeakParticipant] = []

    private struct WeakParticipant {
        weak var value: WindowDelegateParticipant?
    }

    private init(window: NSWindow) {
        self.window = window
        super.init()
        forwardedDelegate = window.delegate
        window.delegate = self
    }

    /// Something else became the window's delegate since this was installed (SwiftUI setting its
    /// own again, say). Stand in front of that one instead.
    private func takeFrontPlaceAgainIfNeeded() {
        guard let window, window.delegate !== self else { return }
        forwardedDelegate = window.delegate
        window.delegate = self
    }

    var registeredParticipants: [WindowDelegateParticipant] {
        participants.compactMap(\.value)
    }

    func register(_ participant: WindowDelegateParticipant) {
        participants.removeAll { $0.value == nil || $0.value === participant }
        participants.append(WeakParticipant(value: participant))
    }

    /// The participant's view has gone. With none left, the window gets SwiftUI's delegate back.
    func unregister(_ participant: WindowDelegateParticipant) {
        participants.removeAll { $0.value == nil || $0.value === participant }
        if participants.isEmpty {
            uninstall()
        }
    }

    /// Puts back the delegate this stood in front of, unless something has replaced this one
    /// since, and lets go of it and of the window.
    func uninstall() {
        if let window {
            if window.delegate === self {
                window.delegate = forwardedDelegate
            }
            if Self.installed(on: window) === self {
                objc_setAssociatedObject(window, &Self.associationKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            }
        }
        forwardedDelegate = nil
        participants.removeAll()
        window = nil
    }

    // MARK: What the participants handle

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        for participant in registeredParticipants where !participant.windowShouldClose(for: sender) {
            return false
        }
        return forwardedDelegate?.windowShouldClose?(sender) ?? true
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        var size = frameSize
        for participant in registeredParticipants {
            size = participant.window(sender, willResizeTo: size)
        }
        return forwardedDelegate?.windowWillResize?(sender, to: size) ?? size
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        if let window = notification.object as? NSWindow {
            for participant in registeredParticipants {
                participant.windowDidEnterFullScreen(for: window)
            }
        }
        forwardedDelegate?.windowDidEnterFullScreen?(notification)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        if let window = notification.object as? NSWindow {
            for participant in registeredParticipants {
                participant.windowDidExitFullScreen(for: window)
            }
        }
        forwardedDelegate?.windowDidExitFullScreen?(notification)
    }

    /// SwiftUI's delegate hears of the close first, as it would without this in front. Putting
    /// it back waits until the close has been delivered: AppKit registers a delegate for the
    /// window's notifications as it is set, and swapping delegates while this one is being posted
    /// could leave SwiftUI's with it twice or not at all.
    func windowWillClose(_ notification: Notification) {
        forwardedDelegate?.windowWillClose?(notification)
        Task { @MainActor in
            self.uninstall()
        }
    }

    // MARK: Everything else goes to SwiftUI's delegate

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
