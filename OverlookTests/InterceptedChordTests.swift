import AppKit
import Foundation
import Testing
@testable import Overlook

/// Which ⌘ chords keyboard capture keeps for Overlook. Each needs exactly its own modifiers:
/// with ⌥ or ⌃ held too, or ⇧ added to a ⌘-only chord, the keystroke is the target's. Caps Lock
/// and Fn never count.
@MainActor
@Suite("Intercepted chords")
struct InterceptedChordTests {
    typealias Chord = InputManager.InterceptedChord

    /// Every chord, with its key: ⌘C, ⌘V, ⌘Q, ⇧⌘S, ⇧⌘R.
    static let chords: [Chord] = Chord.allCases

    /// Modifier combinations to add to a chord's own, and whether the chord should still fire.
    static let extras: [(NSEvent.ModifierFlags, String, Bool)] = [
        ([], "nothing", true),
        (.capsLock, "Caps Lock", true),
        (.function, "Fn", true),
        ([.capsLock, .function], "Caps Lock and Fn", true),
        (.option, "⌥", false),
        (.control, "⌃", false),
        ([.option, .control], "⌥⌃", false),
        ([.option, .capsLock], "⌥ with Caps Lock", false),
        ([.control, .function], "⌃ with Fn", false),
    ]

    @Test func theChordsAreTheOnesOverlookDocuments() {
        let table = Self.chords.map { "\($0.modifiers == [.command, .shift] ? "⇧⌘" : "⌘")\($0.keyCode)" }
        #expect(table == ["⌘8", "⌘9", "⇧⌘1", "⇧⌘15", "⌘12"])
    }

    @Test(arguments: Chord.allCases)
    func eachChordFiresOnlyWithExactlyItsModifiers(chord: Chord) {
        for (extra, label, fires) in Self.extras {
            let modifiers = chord.modifiers.union(extra)
            let result = InputManager.interceptedChord(keyCode: chord.keyCode, modifiers: modifiers)
            #expect(result == (fires ? chord : nil), "\(chord) with \(label)")
        }
    }

    /// ⇧ on a ⌘-only chord (⇧⌘C, ⇧⌘V, ⇧⌘Q) is a different chord, the target's; ⇧ missing from
    /// a ⇧⌘ chord (⌘S, ⌘R) is the target's too.
    @Test(arguments: Chord.allCases)
    func shiftMustMatch(chord: Chord) {
        let toggled = chord.modifiers.symmetricDifference(.shift)
        #expect(InputManager.interceptedChord(keyCode: chord.keyCode, modifiers: toggled) == nil)
        #expect(InputManager.interceptedChord(keyCode: chord.keyCode, modifiers: toggled.union(.capsLock)) == nil)
    }

    @Test(arguments: Chord.allCases)
    func withoutCommandNothingIsIntercepted(chord: Chord) {
        let noCommand = chord.modifiers.subtracting(.command)
        #expect(InputManager.interceptedChord(keyCode: chord.keyCode, modifiers: noCommand) == nil)
        #expect(InputManager.interceptedChord(keyCode: chord.keyCode, modifiers: noCommand.union(.option)) == nil)
    }

    @Test func otherKeysWithCommandAreNotIntercepted() {
        let chordKeys = Set(Self.chords.map(\.keyCode))
        for code in UInt16(0)...UInt16(127) where !chordKeys.contains(code) {
            #expect(InputManager.interceptedChord(keyCode: code, modifiers: .command) == nil, "⌘ key \(code)")
            #expect(InputManager.interceptedChord(keyCode: code, modifiers: [.command, .shift]) == nil, "⇧⌘ key \(code)")
        }
    }

    /// The device-dependent bits macOS sets (which side a modifier is on) do not disturb the match.
    @Test func sideBitsAreIgnored() {
        let leftCommand = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.command.rawValue | 0x0008)
        let leftShift = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.shift.rawValue | 0x0002)
        #expect(InputManager.interceptedChord(keyCode: 9, modifiers: leftCommand) == .paste)
        #expect(InputManager.interceptedChord(keyCode: 1, modifiers: leftCommand.union(leftShift)) == .saveScreenshot)
    }

    // MARK: - Through the input manager

    /// A captured key-down for this window, with no device attached: what would be sent shows up
    /// in `sentInputObserver`, and a chord kept for Overlook in `onLocalShortcut`.
    @MainActor
    private final class Capture {
        static let window = 9_101
        let scratch = ScratchDefaults()
        let input: InputManager
        var sent: [InputManager.SentInput] = []
        var shortcuts: [InputManager.LocalShortcut] = []

        init() {
            input = InputManager(defaults: scratch.defaults, log: SessionLog(destination: .inMemory()))
            input.sentInputObserver = { [unowned self] in self.sent.append($0) }
            input.onLocalShortcut = { [unowned self] in self.shortcuts.append($0) }
            input.startKeyboardCapture()
            input.windowDidBecomeKey(windowNumber: Self.window)
        }

        func press(_ keyCode: UInt16, _ flags: NSEvent.ModifierFlags) {
            hold(keyCode, flags, repeats: 0)
        }

        /// A key-down, `repeats` auto-repeats of it (as macOS sends while the key is held), and
        /// the key-up. Every one of them must be kept from the window.
        func hold(_ keyCode: UInt16, _ flags: NSEvent.ModifierFlags, repeats: Int) {
            send(.keyDown, keyCode, flags, isARepeat: false)
            for _ in 0..<repeats {
                send(.keyDown, keyCode, flags, isARepeat: true)
            }
            send(.keyUp, keyCode, flags, isARepeat: false)
        }

        private func send(_ type: NSEvent.EventType, _ keyCode: UInt16, _ flags: NSEvent.ModifierFlags, isARepeat: Bool) {
            let event = NSEvent.keyEvent(
                with: type,
                location: .zero,
                modifierFlags: flags,
                timestamp: 0,
                windowNumber: Self.window,
                context: nil,
                characters: "x",
                charactersIgnoringModifiers: "x",
                isARepeat: isARepeat,
                keyCode: keyCode
            )!
            #expect(input.routeMonitoredKeyEvent(event) == nil)
        }
    }

    @Test func commandCIsKeptForCopyMode() {
        let capture = Capture()
        capture.press(8, .command)
        #expect(capture.shortcuts == [.toggleCopyMode])
        #expect(capture.sent.isEmpty)
    }

    @Test func optionCommandCGoesToTheTarget() {
        let capture = Capture()
        capture.press(8, [.command, .option])
        #expect(capture.shortcuts.isEmpty)
        #expect(capture.sent == [.key(8, isDown: true), .key(8, isDown: false)])
    }

    @Test func controlCommandVGoesToTheTarget() {
        let capture = Capture()
        capture.press(9, [.command, .control])
        #expect(capture.shortcuts.isEmpty)
        #expect(capture.sent == [.key(9, isDown: true), .key(9, isDown: false)])
    }

    @Test func shiftCommandSIsKeptEvenWithCapsLock() {
        let capture = Capture()
        capture.press(1, [.command, .shift, .capsLock])
        #expect(capture.shortcuts == [.saveScreenshot])
        #expect(capture.sent.isEmpty)
    }

    @Test func optionShiftCommandRGoesToTheTarget() {
        let capture = Capture()
        capture.press(15, [.command, .shift, .option])
        #expect(capture.shortcuts.isEmpty)
        #expect(capture.sent == [.key(15, isDown: true), .key(15, isDown: false)])
    }

    // MARK: - Held chords act once

    @Test func aHeldCommandCTogglesCopyModeOnce() {
        let capture = Capture()
        capture.hold(8, .command, repeats: 5)
        #expect(capture.shortcuts == [.toggleCopyMode])
        #expect(capture.sent.isEmpty)
    }

    @Test func aHeldShiftCommandSSavesOneScreenshot() {
        let capture = Capture()
        capture.hold(1, [.command, .shift], repeats: 5)
        #expect(capture.shortcuts == [.saveScreenshot])
        #expect(capture.sent.isEmpty)
    }

    @Test func aHeldShiftCommandRTogglesRecordingOnce() {
        let capture = Capture()
        capture.hold(15, [.command, .shift], repeats: 5)
        #expect(capture.shortcuts == [.toggleRecording])
        #expect(capture.sent.isEmpty)
    }

    @Test func aHeldCommandQQuitsOnce() {
        let capture = Capture()
        var quits = 0
        capture.input.terminateApp = { quits += 1 }
        capture.hold(12, .command, repeats: 5)
        #expect(quits == 1)
        #expect(capture.sent.isEmpty)
    }

    /// Two separate presses are two actions: only the repeats in between are dropped.
    @Test func eachPressStillCounts() {
        let capture = Capture()
        capture.hold(8, .command, repeats: 3)
        capture.hold(8, .command, repeats: 3)
        #expect(capture.shortcuts == [.toggleCopyMode, .toggleCopyMode])
    }

    /// A held key that is not one of Overlook's chords still repeats on the target.
    @Test func aHeldOrdinaryKeyStillRepeatsOnTheTarget() {
        let capture = Capture()
        capture.hold(0, [], repeats: 3)
        #expect(capture.sent == [
            .key(0, isDown: true), .key(0, isDown: true), .key(0, isDown: true), .key(0, isDown: true),
            .key(0, isDown: false),
        ])
        #expect(capture.shortcuts.isEmpty)
    }

    /// ⌘V with a stubbed device and clipboard: one press held through its repeats reads the
    /// clipboard once and types it once.
    @Test func aHeldCommandVPastesOnce() async throws {
        let capture = Capture()
        let device = StubDevice()
        capture.input.transportMode = .webRTC
        capture.input.setGLKVMClient(try device.makeClient())
        var reads = 0
        capture.input.readClipboardText = {
            reads += 1
            return "echo hello"
        }

        capture.hold(9, .command, repeats: 6)

        #expect(reads == 1)
        #expect(capture.sent.isEmpty)
        #expect(await waitUntil { device.requests(to: "/api/hid/print").count == 1 })
        try await Task.sleep(nanoseconds: 200_000_000)
        let prints = device.requests(to: "/api/hid/print")
        #expect(prints.count == 1)
        #expect(prints.first?.bodyText == "echo hello")
    }
}
