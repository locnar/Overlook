import AppKit
import Foundation
import Testing
@testable import Overlook

/// Input reaches a target only from its own window, and only while that window is key.
///
/// The gate's decisions are checked on their own first, then through `InputManager` with
/// synthesized events. No manager here has a device: what it would send is read from
/// `sentInputObserver`, and windows are stood in for by window numbers.
@MainActor
@Suite("Input focus")
struct InputFocusTests {
    private static let windowA = 9_001
    private static let windowB = 9_002

    // MARK: - The gate

    @Test func aGateOwnsNothingUntilItsWindowIsKey() {
        var gate = InputFocusGate()
        let admitted = [gate.admitKey(0, isDown: true), gate.admitButton(.left, isDown: true)]

        #expect(gate.owns(eventWindowNumber: Self.windowA) == false)
        #expect(admitted == [false, false])
        #expect(gate.admitsPointerMotion == false)
    }

    @Test func aKeyWindowOwnsOnlyItsOwnEvents() {
        var gate = InputFocusGate()
        gate.windowDidBecomeKey(windowNumber: Self.windowA)

        #expect(gate.owns(eventWindowNumber: Self.windowA))
        #expect(gate.owns(eventWindowNumber: Self.windowB) == false)
        #expect(gate.admitsPointerMotion)

        gate.windowDidResignKey()
        #expect(gate.owns(eventWindowNumber: Self.windowA) == false)
        #expect(gate.admitsPointerMotion == false)
    }

    @Test func aReleaseOrRepeatIsAdmittedOnlyForAPressTakenHere() {
        var gate = InputFocusGate()
        gate.windowDidBecomeKey(windowNumber: Self.windowA)

        let neverPressed = [
            gate.admitKey(12, isDown: false),
            gate.admitKey(12, isDown: true, isRepeat: true),
        ]
        let pressed = [
            gate.admitKey(0, isDown: true),
            gate.admitKey(0, isDown: true, isRepeat: true),
            gate.admitKey(0, isDown: false),
            // Each press is released once.
            gate.admitKey(0, isDown: false),
        ]

        #expect(neverPressed == [false, false])
        #expect(pressed == [true, true, true, false])
    }

    @Test func losingKeyStatusForgetsEveryPress() {
        var gate = InputFocusGate()
        gate.windowDidBecomeKey(windowNumber: Self.windowA)
        _ = gate.admitKey(0, isDown: true)
        _ = gate.admitButton(.right, isDown: true)

        gate.windowDidResignKey()
        gate.windowDidBecomeKey(windowNumber: Self.windowA)

        #expect(gate.pressedKeys.isEmpty)
        #expect(gate.pressedButtons.isEmpty)
        // The releases that arrive afterwards were already made on the target.
        let releases = [gate.admitKey(0, isDown: false), gate.admitButton(.right, isDown: false)]
        #expect(releases == [false, false])
    }

    @Test func aKeyHeldAcrossAWindowSwitchBelongsToNeitherWindowAfterward() {
        var a = InputFocusGate()
        var b = InputFocusGate()
        a.windowDidBecomeKey(windowNumber: Self.windowA)

        // Key down in A.
        #expect(a.owns(eventWindowNumber: Self.windowA))
        #expect(b.owns(eventWindowNumber: Self.windowA) == false)
        let pressedInA = a.admitKey(0, isDown: true)
        #expect(pressedInA)

        // B is clicked: A loses key status first, then B gains it.
        a.windowDidResignKey()
        b.windowDidBecomeKey(windowNumber: Self.windowB)

        // The repeats and the key-up now arrive for B's window.
        #expect(a.owns(eventWindowNumber: Self.windowB) == false)
        #expect(b.owns(eventWindowNumber: Self.windowB))
        let inB = [b.admitKey(0, isDown: true, isRepeat: true), b.admitKey(0, isDown: false)]
        #expect(inB == [false, false])
    }

    @Test func aButtonIsPressedOnlyWhileTheWindowIsKey() {
        var gate = InputFocusGate()
        let notKey = [gate.admitButton(.left, isDown: true), gate.admitButton(.left, isDown: false)]

        gate.windowDidBecomeKey(windowNumber: Self.windowA)
        let key = [gate.admitButton(.left, isDown: true), gate.admitButton(.left, isDown: false)]

        #expect(notKey == [false, false])
        #expect(key == [true, true])
    }

    @Test func modifiersPressedAgainOnANewSocketCanBeReleased() {
        var gate = InputFocusGate()
        gate.notePressed([56])
        #expect(gate.pressedKeys.isEmpty)

        gate.windowDidBecomeKey(windowNumber: Self.windowA)
        gate.notePressed([56, 59])
        let releases = [gate.admitKey(56, isDown: false), gate.admitKey(59, isDown: false)]
        #expect(releases == [true, true])
    }

    // MARK: - Through the input manager

    @MainActor
    private final class Capture {
        let scratch = ScratchDefaults()
        let input: InputManager
        var sent: [InputManager.SentInput] = []

        init(capturing: Bool = true) {
            input = InputManager(defaults: scratch.defaults, log: SessionLog(destination: .inMemory()))
            input.sentInputObserver = { [unowned self] in self.sent.append($0) }
            if capturing {
                input.startKeyboardCapture()
                input.startMouseCapture()
            }
        }
    }

    private func key(
        _ keyCode: UInt16,
        down: Bool,
        window: Int,
        repeat isRepeat: Bool = false,
        flags: NSEvent.ModifierFlags = []
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: down ? .keyDown : .keyUp,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: window,
            context: nil,
            characters: "a",
            charactersIgnoringModifiers: "a",
            isARepeat: isRepeat,
            keyCode: keyCode
        )!
    }

    /// Left Shift going down or up, with the device-dependent side bit macOS sets for it.
    private func leftShift(down: Bool, window: Int) -> NSEvent {
        let flags: NSEvent.ModifierFlags = down
            ? NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.shift.rawValue | 0x0002)
            : []
        return NSEvent.keyEvent(
            with: .flagsChanged,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: window,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 56
        )!
    }

    @Test func anotherWindowsKeysArePassedOnUntouched() {
        let a = Capture()
        a.input.windowDidBecomeKey(windowNumber: Self.windowA)

        let elsewhere = key(0, down: true, window: Self.windowB)
        #expect(a.input.routeMonitoredKeyEvent(elsewhere) === elsewhere)
        #expect(a.sent.isEmpty)

        let own = key(0, down: true, window: Self.windowA)
        #expect(a.input.routeMonitoredKeyEvent(own) == nil)
        #expect(a.sent == [.key(0, isDown: true)])
    }

    @Test func aSessionWhoseWindowIsNotKeySendsNoKeys() {
        let a = Capture()
        // Attached to window A, which has lost key status (to a sheet, say).
        a.input.windowDidBecomeKey(windowNumber: Self.windowA)
        a.input.windowDidResignKey()

        let event = key(0, down: true, window: Self.windowA)
        #expect(a.input.routeMonitoredKeyEvent(event) === event)
        #expect(a.sent.isEmpty)
    }

    /// Fork review #12: what is typed into a sheet over a console window (the connect and
    /// password sheets, an alert) never reaches that window's target, with keyboard capture on.
    /// The window and the sheet are real windows, never shown; key status changes are posted as
    /// AppKit posts them when a sheet takes the keyboard and gives it back.
    @Test func typingIntoASheetOverTheConsoleSendsNothingToTheTarget() throws {
        let console = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let sheet = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        console.isReleasedWhenClosed = false
        sheet.isReleasedWhenClosed = false
        try #require(console.windowNumber > 0 && sheet.windowNumber > 0)
        try #require(console.windowNumber != sheet.windowNumber)

        let a = Capture()
        #expect(a.input.isKeyboardCaptureEnabled)
        a.input.attach(to: console)
        let center = NotificationCenter.default
        center.post(name: NSWindow.didBecomeKeyNotification, object: console)
        #expect(a.input.focusGate.isWindowKey)

        // Typing in the console goes to the target.
        _ = a.input.routeMonitoredKeyEvent(key(0, down: true, window: console.windowNumber))
        _ = a.input.routeMonitoredKeyEvent(key(0, down: false, window: console.windowNumber))
        #expect(a.sent == [.key(0, isDown: true), .key(0, isDown: false)])
        a.sent.removeAll()

        // The password sheet comes up and takes the keyboard. Every key typed into it, Return
        // included, is handed back to AppKit for the sheet, and none is sent.
        center.post(name: NSWindow.didResignKeyNotification, object: console)
        #expect(a.input.focusGate.isWindowKey == false)
        for keyCode: UInt16 in [35, 0, 1, 1, 36] {   // p, a, s, s, Return
            let down = key(keyCode, down: true, window: sheet.windowNumber)
            let up = key(keyCode, down: false, window: sheet.windowNumber)
            #expect(a.input.routeMonitoredKeyEvent(down) === down)
            #expect(a.input.routeMonitoredKeyEvent(up) === up)
        }
        // Nor does anything addressed to the console itself go out while the sheet is up.
        let stray = key(2, down: true, window: console.windowNumber)
        #expect(a.input.routeMonitoredKeyEvent(stray) === stray)
        #expect(a.sent.isEmpty)

        // The sheet goes; the console has the keyboard again.
        center.post(name: NSWindow.didBecomeKeyNotification, object: console)
        _ = a.input.routeMonitoredKeyEvent(key(3, down: true, window: console.windowNumber))
        #expect(a.sent == [.key(3, isDown: true)])

        a.input.attach(to: nil)
    }

    @Test func switchingWindowsWithAKeyHeldSendsTheKeyUpNowhere() {
        let a = Capture()
        let b = Capture()
        a.input.windowDidBecomeKey(windowNumber: Self.windowA)

        // Key down in A: A takes it, B leaves it alone.
        let down = key(0, down: true, window: Self.windowA)
        #expect(b.input.routeMonitoredKeyEvent(down) === down)
        #expect(a.input.routeMonitoredKeyEvent(down) == nil)

        // Click B. A releases what it holds as it loses key status.
        a.input.windowDidResignKey()
        b.input.windowDidBecomeKey(windowNumber: Self.windowB)
        #expect(a.input.focusGate.pressedKeys.isEmpty)

        // The key repeats, then comes up, all delivered to B's window.
        let repeated = key(0, down: true, window: Self.windowB, repeat: true)
        let up = key(0, down: false, window: Self.windowB)
        #expect(a.input.routeMonitoredKeyEvent(repeated) === repeated)
        #expect(a.input.routeMonitoredKeyEvent(up) === up)
        #expect(b.input.routeMonitoredKeyEvent(repeated) == nil)
        #expect(b.input.routeMonitoredKeyEvent(up) == nil)

        #expect(a.sent == [.key(0, isDown: true)])
        #expect(b.sent.isEmpty)
    }

    @Test func aKeyUpAfterComingBackIsNotSentTwice() {
        let a = Capture()
        a.input.windowDidBecomeKey(windowNumber: Self.windowA)
        _ = a.input.routeMonitoredKeyEvent(key(0, down: true, window: Self.windowA))

        a.input.windowDidResignKey()
        a.input.windowDidBecomeKey(windowNumber: Self.windowA)
        _ = a.input.routeMonitoredKeyEvent(key(0, down: false, window: Self.windowA))

        #expect(a.sent == [.key(0, isDown: true)])
    }

    @Test func aModifierHeldAcrossAWindowSwitchIsNotReleasedByTheOtherWindow() {
        let a = Capture()
        let b = Capture()
        a.input.windowDidBecomeKey(windowNumber: Self.windowA)

        _ = a.input.routeMonitoredKeyEvent(leftShift(down: true, window: Self.windowA))
        a.input.windowDidResignKey()
        b.input.windowDidBecomeKey(windowNumber: Self.windowB)
        _ = b.input.routeMonitoredKeyEvent(leftShift(down: false, window: Self.windowB))

        #expect(a.sent == [.key(56, isDown: true)])
        #expect(b.sent.isEmpty)
    }

    @Test func capturedChordsGoToTheSessionWhoseWindowIsKey() {
        let a = Capture()
        let b = Capture()
        var shortcuts: [String] = []
        a.input.onLocalShortcut = { shortcuts.append("a \($0)") }
        b.input.onLocalShortcut = { shortcuts.append("b \($0)") }
        b.input.windowDidBecomeKey(windowNumber: Self.windowB)

        let chord = key(1, down: true, window: Self.windowB, flags: [.command, .shift])
        _ = a.input.routeMonitoredKeyEvent(chord)
        _ = b.input.routeMonitoredKeyEvent(chord)

        #expect(shortcuts == ["b saveScreenshot"])
        #expect(a.sent.isEmpty)
        #expect(b.sent.isEmpty)
    }

    @Test func aClickOnAWindowThatIsNotKeyIsNotSent() {
        let a = Capture()

        a.input.handleVideoMouseButton(button: .left, isDown: true, pointInView: CGPoint(x: 5, y: 5), viewSize: CGSize(width: 10, height: 10), videoSize: nil)
        a.input.handleVideoMouseButton(button: .left, isDown: false, pointInView: CGPoint(x: 5, y: 5), viewSize: CGSize(width: 10, height: 10), videoSize: nil)
        a.input.handleVideoMouseScroll(deltaX: 0, deltaY: 3)

        #expect(a.sent.isEmpty)
    }

    @Test func aButtonHeldWhenTheWindowLosesKeyIsReleasedThenAndOnlyThen() {
        let a = Capture()
        let point = CGPoint(x: 5, y: 5)
        let size = CGSize(width: 10, height: 10)
        a.input.windowDidBecomeKey(windowNumber: Self.windowA)

        a.input.handleVideoMouseButton(button: .left, isDown: true, pointInView: point, viewSize: size, videoSize: nil)
        a.input.windowDidResignKey()
        // The real release arrives later, at the view that took the press.
        a.input.handleVideoMouseButton(button: .left, isDown: false, pointInView: point, viewSize: size, videoSize: nil)

        #expect(a.sent == [.button(.left, isDown: true), .button(.left, isDown: false)])
    }

    @Test func scrollingGoesOutOnlyWhileTheWindowIsKey() {
        let a = Capture()
        a.input.handleVideoMouseScroll(deltaX: 0, deltaY: 3)
        a.input.windowDidBecomeKey(windowNumber: Self.windowA)
        a.input.handleVideoMouseScroll(deltaX: 0, deltaY: 3)

        #expect(a.sent == [.scroll])
    }

    @Test func thePointerLocksOnlyToTheSessionsOwnKeyWindow() {
        let a = Capture()
        a.input.setGLKVMAbsoluteMouseMode(false)
        #expect(a.input.isRelativeMouseMode)

        // Not key: no lock, whatever window the app has in front.
        #expect(a.input.lockPointer() == false)

        // Reported key, but with no window of its own attached there is nothing to lock to;
        // in particular not `NSApp.keyWindow`.
        a.input.windowDidBecomeKey(windowNumber: Self.windowA)
        #expect(a.input.lockPointer() == false)
        #expect(a.input.isPointerLocked == false)
    }
}
