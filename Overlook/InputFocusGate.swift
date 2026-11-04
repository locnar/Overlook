import Foundation

/// Which keyboard and mouse events one console session may send to its target.
///
/// `NSEvent.addLocalMonitorForEvents` sees every event the app receives, whichever window it is
/// for, and every connected console installs one. So a session takes an event only when it is for
/// the session's own window and that window is key, and leaves everything else to the window it
/// belongs to — another console's, a sheet's.
///
/// A key or button can go down while one window is key and come up after another has become key:
/// macOS delivers the release to whichever window is key by then. The window that lost key status
/// releases everything it had pressed on its target at that moment (`InputManager` does the
/// sending), and from then on neither session sends anything for that key: the first has already
/// released it, and the second never pressed it. That is what `pressedKeys` and `pressedButtons`
/// are for — a release, or a key repeat, goes out only for a press this session took.
///
/// No AppKit state lives here, so the decisions can be tested without windows or real events.
struct InputFocusGate {
    /// The session's window, as `NSWindow.windowNumber` and `NSEvent.windowNumber` report it.
    private(set) var windowNumber: Int?
    /// Whether that window is the key window. False until it is first reported key.
    private(set) var isWindowKey = false
    /// Keys whose key-down this session took and whose key-up it has not yet seen.
    private(set) var pressedKeys: Set<UInt16> = []
    /// The same for mouse buttons pressed on the video.
    private(set) var pressedButtons: Set<MouseButton> = []

    mutating func windowDidBecomeKey(windowNumber: Int) {
        self.windowNumber = windowNumber
        isWindowKey = true
    }

    /// Forgets every press. The caller releases on the target whatever it had sent.
    mutating func windowDidResignKey() {
        isWindowKey = false
        pressedKeys.removeAll()
        pressedButtons.removeAll()
    }

    /// Whether an event for the window numbered `eventWindowNumber` is this session's at all.
    func owns(eventWindowNumber: Int) -> Bool {
        isWindowKey && eventWindowNumber == windowNumber
    }

    /// For a key event this session owns: whether it may go to the target. A press is taken and
    /// remembered; a release, or a repeat, only for a key this session saw go down.
    mutating func admitKey(_ keyCode: UInt16, isDown: Bool, isRepeat: Bool = false) -> Bool {
        guard isWindowKey else { return false }
        if isDown {
            if isRepeat { return pressedKeys.contains(keyCode) }
            pressedKeys.insert(keyCode)
            return true
        }
        return pressedKeys.remove(keyCode) != nil
    }

    /// Records keys pressed on the target by something other than a key event — the modifiers
    /// pressed again when a new HID socket comes up — so their releases are let through.
    mutating func notePressed(_ keyCodes: [UInt16]) {
        guard isWindowKey else { return }
        pressedKeys.formUnion(keyCodes)
    }

    /// For a mouse button on the video: a press only while the window is key, a release only for a
    /// press this session took.
    mutating func admitButton(_ button: MouseButton, isDown: Bool) -> Bool {
        if isDown {
            guard isWindowKey else { return false }
            pressedButtons.insert(button)
            return true
        }
        return pressedButtons.remove(button) != nil
    }

    /// Movement and scrolling carry no press to pair up, so they go out only while the window is key.
    var admitsPointerMotion: Bool { isWindowKey }
}
