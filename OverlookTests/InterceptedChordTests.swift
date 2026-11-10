import AppKit
import Foundation
import Testing
@testable import Overlook

/// Which ⌘ chords keyboard capture keeps for Overlook: ⇧⌘C, ⇧⌘V, ⇧⌘S, ⇧⌘R, ⇧⌘T and ⌘Q. Each needs
/// exactly its own modifiers: with ⌥ or ⌃ held too, or ⇧ added to ⌘Q or missing from a ⇧⌘ chord,
/// the keystroke is the target's. Plain ⌘C and ⌘V are the target's. Caps Lock and Fn never count.
@MainActor
@Suite("Intercepted chords")
struct InterceptedChordTests {
    typealias Chord = InputManager.InterceptedChord

    /// Every chord, with its key: ⇧⌘C, ⇧⌘V, ⇧⌘S, ⇧⌘R, ⇧⌘T, ⌘Q.
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
        #expect(table == ["⇧⌘8", "⇧⌘9", "⇧⌘1", "⇧⌘15", "⇧⌘17", "⌘12"])
    }

    @Test(arguments: Chord.allCases)
    func eachChordFiresOnlyWithExactlyItsModifiers(chord: Chord) {
        for (extra, label, fires) in Self.extras {
            let modifiers = chord.modifiers.union(extra)
            let result = InputManager.interceptedChord(keyCode: chord.keyCode, modifiers: modifiers)
            #expect(result == (fires ? chord : nil), "\(chord) with \(label)")
        }
    }

    /// ⇧ on a ⌘-only chord (⇧⌘Q) is a different chord, the target's; ⇧ missing from a ⇧⌘ chord
    /// (⌘C, ⌘V, ⌘S, ⌘R) is the target's too.
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
        #expect(InputManager.interceptedChord(keyCode: 9, modifiers: leftCommand.union(leftShift)) == .paste)
        #expect(InputManager.interceptedChord(keyCode: 1, modifiers: leftCommand.union(leftShift)) == .saveScreenshot)
        #expect(InputManager.interceptedChord(keyCode: 12, modifiers: leftCommand) == .quit)
        #expect(InputManager.interceptedChord(keyCode: 9, modifiers: leftCommand) == nil)
    }

    /// Plain ⌘C and ⌘V are the target's: copy and paste inside the target's own apps.
    @Test func plainCommandCAndCommandVAreNotIntercepted() {
        #expect(InputManager.interceptedChord(keyCode: 8, modifiers: .command) == nil)
        #expect(InputManager.interceptedChord(keyCode: 9, modifiers: .command) == nil)
        #expect(InputManager.interceptedChord(keyCode: 8, modifiers: [.command, .shift]) == .copyMode)
        #expect(InputManager.interceptedChord(keyCode: 9, modifiers: [.command, .shift]) == .paste)
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

    @Test func commandCGoesToTheTarget() {
        let capture = Capture()
        capture.press(8, .command)
        #expect(capture.shortcuts.isEmpty)
        #expect(capture.sent == [.key(8, isDown: true), .key(8, isDown: false)])
    }

    /// ⌘V is a keystroke on the target: the Mac's clipboard is not read and nothing is typed.
    @Test func commandVGoesToTheTargetWithoutPasting() async throws {
        let capture = Capture()
        let device = StubDevice()
        capture.input.transportMode = .webRTC
        capture.input.setGLKVMClient(try device.makeClient())
        var reads = 0
        capture.input.readClipboardText = {
            reads += 1
            return "echo hello"
        }

        capture.press(9, .command)

        #expect(capture.shortcuts.isEmpty)
        #expect(capture.sent == [.key(9, isDown: true), .key(9, isDown: false)])
        #expect(reads == 0)
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(device.requests(to: "/api/hid/print").isEmpty)
    }

    @Test func shiftCommandCIsKeptForCopyMode() {
        let capture = Capture()
        capture.press(8, [.command, .shift])
        #expect(capture.shortcuts == [.toggleCopyMode])
        #expect(capture.sent.isEmpty)
    }

    @Test func controlShiftCommandCGoesToTheTarget() {
        let capture = Capture()
        capture.press(8, [.command, .shift, .control])
        #expect(capture.shortcuts.isEmpty)
        #expect(capture.sent == [.key(8, isDown: true), .key(8, isDown: false)])
    }

    @Test func optionShiftCommandVGoesToTheTarget() {
        let capture = Capture()
        var reads = 0
        capture.input.readClipboardText = {
            reads += 1
            return "echo hello"
        }
        capture.press(9, [.command, .shift, .option])
        #expect(capture.shortcuts.isEmpty)
        #expect(reads == 0)
        #expect(capture.sent == [.key(9, isDown: true), .key(9, isDown: false)])
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

    @Test func shiftCommandTIsKeptForTheOCRSnippet() {
        let capture = Capture()
        capture.press(17, [.command, .shift])
        #expect(capture.shortcuts == [.copyTextFromArea])
        #expect(capture.sent.isEmpty)
    }

    @Test func optionShiftCommandTGoesToTheTarget() {
        let capture = Capture()
        capture.press(17, [.command, .shift, .option])
        #expect(capture.shortcuts.isEmpty)
        #expect(capture.sent == [.key(17, isDown: true), .key(17, isDown: false)])
    }

    @Test func controlShiftCommandTGoesToTheTarget() {
        let capture = Capture()
        capture.press(17, [.command, .shift, .control])
        #expect(capture.shortcuts.isEmpty)
        #expect(capture.sent == [.key(17, isDown: true), .key(17, isDown: false)])
    }

    /// ⌘T (no ⇧) is the target's: a new tab in the target's browser, say.
    @Test func commandTGoesToTheTarget() {
        let capture = Capture()
        capture.press(17, .command)
        #expect(capture.shortcuts.isEmpty)
        #expect(capture.sent == [.key(17, isDown: true), .key(17, isDown: false)])
    }

    @Test func optionShiftCommandRGoesToTheTarget() {
        let capture = Capture()
        capture.press(15, [.command, .shift, .option])
        #expect(capture.shortcuts.isEmpty)
        #expect(capture.sent == [.key(15, isDown: true), .key(15, isDown: false)])
    }

    /// With keyboard capture off, ⌘C, ⌘V and the ⇧⌘ chords are handed back untouched, so the
    /// standard Edit menu copies and pastes in Overlook's own text fields (and the Edit menu's
    /// ⇧⌘C and ⇧⌘V items get theirs).
    @Test func withCaptureOffTheChordsGoToTheMenus() {
        let scratch = ScratchDefaults()
        let input = InputManager(defaults: scratch.defaults, log: SessionLog(destination: .inMemory()))
        var sent: [InputManager.SentInput] = []
        var shortcuts: [InputManager.LocalShortcut] = []
        var reads = 0
        input.sentInputObserver = { sent.append($0) }
        input.onLocalShortcut = { shortcuts.append($0) }
        input.readClipboardText = {
            reads += 1
            return "echo hello"
        }
        input.windowDidBecomeKey(windowNumber: Capture.window)

        let chords: [(UInt16, NSEvent.ModifierFlags)] = [(8, .command), (9, .command), (8, [.command, .shift]), (9, [.command, .shift])]
        for (code, flags) in chords {
            let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: flags,
                timestamp: 0,
                windowNumber: Capture.window,
                context: nil,
                characters: "x",
                charactersIgnoringModifiers: "x",
                isARepeat: false,
                keyCode: code
            )!
            #expect(input.routeMonitoredKeyEvent(event) === event, "key \(code)")
        }
        #expect(sent.isEmpty)
        #expect(shortcuts.isEmpty)
        #expect(reads == 0)
    }

    /// The Edit menu's Paste Clipboard to Target: the clipboard is read once and typed once.
    @Test func theMenusPasteTypesTheClipboardOnce() async throws {
        let scratch = ScratchDefaults()
        let input = InputManager(defaults: scratch.defaults, log: SessionLog(destination: .inMemory()))
        let device = StubDevice()
        input.transportMode = .webRTC
        input.setGLKVMClient(try device.makeClient())
        var reads = 0
        input.readClipboardText = {
            reads += 1
            return "echo hello"
        }

        input.pasteClipboardToRemote()

        #expect(reads == 1)
        #expect(await waitUntil { device.requests(to: "/api/hid/print").count == 1 })
        #expect(device.requests(to: "/api/hid/print").first?.bodyText == "echo hello")
    }

    // MARK: - Held chords act once

    @Test func aHeldShiftCommandCTogglesCopyModeOnce() {
        let capture = Capture()
        capture.hold(8, [.command, .shift], repeats: 5)
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

    @Test func aHeldShiftCommandTStartsOneSnippet() {
        let capture = Capture()
        capture.hold(17, [.command, .shift], repeats: 5)
        #expect(capture.shortcuts == [.copyTextFromArea])
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
        capture.hold(8, [.command, .shift], repeats: 3)
        capture.hold(8, [.command, .shift], repeats: 3)
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

    /// ⇧⌘V with a stubbed device and clipboard: one press held through its repeats reads the
    /// clipboard once and types it once.
    @Test func aHeldShiftCommandVPastesOnce() async throws {
        let capture = Capture()
        let device = StubDevice()
        capture.input.transportMode = .webRTC
        capture.input.setGLKVMClient(try device.makeClient())
        var reads = 0
        capture.input.readClipboardText = {
            reads += 1
            return "echo hello"
        }

        capture.hold(9, [.command, .shift], repeats: 6)

        #expect(reads == 1)
        #expect(capture.sent.isEmpty)
        #expect(await waitUntil { device.requests(to: "/api/hid/print").count == 1 })
        try await Task.sleep(nanoseconds: 200_000_000)
        let prints = device.requests(to: "/api/hid/print")
        #expect(prints.count == 1)
        #expect(prints.first?.bodyText == "echo hello")
    }
}

// MARK: - On the HID socket

/// Records which keys the HID socket had carried when the device was asked to type a paste.
private final class KeysAtPrint: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [[String]] = []

    var all: [[String]] { lock.withLock { seen } }

    func record(_ keys: [String]) {
        lock.withLock { seen.append(keys) }
    }
}

/// The copy and paste chords as the device sees them, with real modifier presses: ⌘ going down
/// is held back until the next key decides whether it is the target's, and ⇧ goes out at once.
@MainActor
@Suite("Copy and paste chords on the HID socket")
struct ClipboardChordSocketTests {
    private static let window = 9_102
    private static let leftCommand = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.command.rawValue | 0x0008)
    private static let leftShift = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.shift.rawValue | 0x0002)

    private let scratch = ScratchDefaults()
    private let sockets: FakeHIDSockets
    private let keysAtPrint: KeysAtPrint
    private let device: StubDevice
    private let input: InputManager

    init() throws {
        let sockets = FakeHIDSockets()
        let keysAtPrint = KeysAtPrint()
        self.sockets = sockets
        self.keysAtPrint = keysAtPrint
        device = StubDevice { request in
            if request.path == "/api/hid/print" {
                keysAtPrint.record(sockets.all.first?.keyFrames.compactMap(\.keyText) ?? [])
            }
            return .ok()
        }
        input = InputManager(defaults: scratch.defaults, log: SessionLog(destination: .inMemory()))
        input.readClipboardText = { "echo hello" }
        input.startKeyboardCapture()
        input.windowDidBecomeKey(windowNumber: Self.window)

        let client = try device.makeClient()
        client.hidSocketTiming = .testing()
        client.makeHIDSocket = { _ in sockets.make() }
        input.setGLKVMClient(client)
    }

    /// The socket, once it has opened and the keyboard resync after its greeting has gone out.
    private func openedSocket() async throws -> FakeHIDSocket {
        #expect(await waitUntil(timeout: .seconds(5)) {
            sockets.count > 0 && sockets.all[0].frames.contains(where: \.clearsKeyboard)
        })
        return try #require(sockets.all.first)
    }

    private func keys(on socket: FakeHIDSocket) -> [String] {
        socket.keyFrames.compactMap(\.keyText)
    }

    private func modifier(_ keyCode: UInt16, _ flags: NSEvent.ModifierFlags) {
        route(.flagsChanged, keyCode, flags)
    }

    private func key(_ keyCode: UInt16, down: Bool, _ flags: NSEvent.ModifierFlags, repeat isRepeat: Bool = false) {
        route(down ? .keyDown : .keyUp, keyCode, flags, isRepeat: isRepeat)
    }

    private func route(_ type: NSEvent.EventType, _ keyCode: UInt16, _ flags: NSEvent.ModifierFlags, isRepeat: Bool = false) {
        let isKey = type != .flagsChanged
        let event = NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: Self.window,
            context: nil,
            characters: isKey ? "x" : "",
            charactersIgnoringModifiers: isKey ? "x" : "",
            isARepeat: isRepeat,
            keyCode: keyCode
        )!
        #expect(input.routeMonitoredKeyEvent(event) == nil)
    }

    /// ⌘C reaches the target as Meta+C, like any other ⌘ keystroke.
    @Test func commandCIsMetaCOnTheTarget() async throws {
        let socket = try await openedSocket()
        let before = keys(on: socket).count

        modifier(55, Self.leftCommand)
        key(8, down: true, Self.leftCommand)
        key(8, down: false, Self.leftCommand)
        modifier(55, [])

        let expected = ["MetaLeft down", "KeyC down", "KeyC up", "MetaLeft up"]
        #expect(await waitUntil { Array(keys(on: socket).dropFirst(before)) == expected })
        await input.shutdown()
    }

    /// ⌘V reaches the target as Meta+V, and nothing is typed from the Mac's clipboard.
    @Test func commandVIsMetaVOnTheTargetAndPastesNothing() async throws {
        let socket = try await openedSocket()
        let before = keys(on: socket).count

        modifier(55, Self.leftCommand)
        key(9, down: true, Self.leftCommand)
        key(9, down: false, Self.leftCommand)
        modifier(55, [])

        let expected = ["MetaLeft down", "KeyV down", "KeyV up", "MetaLeft up"]
        #expect(await waitUntil { Array(keys(on: socket).dropFirst(before)) == expected })
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(device.requests(to: "/api/hid/print").isEmpty)
        await input.shutdown()
    }

    /// ⇧⌘V, held through its repeats, types the clipboard once. ⇧ went to the target when it was
    /// pressed, so it is let go there before the device types, and neither ⌘ nor V reaches it.
    @Test func shiftCommandVLetsGoOfShiftThenPastesOnce() async throws {
        let socket = try await openedSocket()
        let before = keys(on: socket).count
        let both = Self.leftCommand.union(Self.leftShift)

        modifier(56, Self.leftShift)
        modifier(55, both)
        key(9, down: true, both)
        for _ in 0..<4 {
            key(9, down: true, both, repeat: true)
        }

        #expect(await waitUntil { keysAtPrint.all.count == 1 })
        let atPrint = try #require(keysAtPrint.all.first)
        #expect(Array(atPrint.dropFirst(before)) == ["ShiftLeft down", "ShiftLeft up"])

        key(9, down: false, both)
        modifier(55, Self.leftShift)
        modifier(56, [])
        try await Task.sleep(nanoseconds: 200_000_000)

        let prints = device.requests(to: "/api/hid/print")
        #expect(prints.count == 1)
        #expect(prints.first?.bodyText == "echo hello")
        let sent = keys(on: socket).dropFirst(before)
        #expect(!sent.contains { $0.hasPrefix("Meta") || $0.hasPrefix("KeyV") })
        #expect(sent.last == "ShiftLeft up")
        await input.shutdown()
    }

    /// ⇧⌘C toggles copy mode once per press and sends neither ⌘ nor C.
    @Test func shiftCommandCTogglesCopyModeOnceAndSendsNoC() async throws {
        var shortcuts: [InputManager.LocalShortcut] = []
        input.onLocalShortcut = { shortcuts.append($0) }
        let socket = try await openedSocket()
        let before = keys(on: socket).count
        let both = Self.leftCommand.union(Self.leftShift)

        modifier(56, Self.leftShift)
        modifier(55, both)
        key(8, down: true, both)
        key(8, down: true, both, repeat: true)
        key(8, down: false, both)
        modifier(55, Self.leftShift)
        modifier(56, [])

        #expect(shortcuts == [.toggleCopyMode])
        #expect(await waitUntil { keys(on: socket).dropFirst(before).last == "ShiftLeft up" })
        #expect(Array(keys(on: socket).dropFirst(before)) == ["ShiftLeft down", "ShiftLeft up"])
        await input.shutdown()
    }
}
