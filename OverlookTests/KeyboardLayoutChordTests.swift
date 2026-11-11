import AppKit
import Foundation
import Testing
@testable import Overlook

/// Overlook's chords follow the letters of the keyboard layout, as macOS menu shortcuts do: ⇧⌘C is
/// whichever key types C with ⌘ held. A layout without Latin letters uses the ASCII-capable layout
/// macOS keeps for shortcuts. Keys that are not chords still go to the target by position.
@MainActor
@Suite("Chords on other keyboard layouts")
struct KeyboardLayoutChordTests {
    typealias Chord = InputManager.InterceptedChord
    typealias Layouts = TestKeyboardLayouts

    private func chord(_ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags, on layouts: ShortcutLayoutSource) -> Chord? {
        InputManager.interceptedChord(keyCode: keyCode, modifiers: modifiers, layouts: layouts)
    }

    /// The key that types `letter` on `layout` with ⌘ held.
    private func key(typing letter: Character, on layout: TableKeyLayout) -> UInt16? {
        (UInt16(0)...UInt16(127)).first { layout.character(keyCode: $0, commandHeld: true) == letter }
    }

    @Test func eachChordHasItsLetter() {
        #expect(Chord.allCases.map(\.letter) == ["c", "v", "s", "r", "t", "q"])
    }

    /// On every Latin layout, each chord is on the key that types its letter, and no other key with
    /// ⌘ or ⇧⌘ is one of Overlook's.
    @Test(arguments: [
        ("U.S.", Layouts.us),
        ("Dvorak", Layouts.dvorak),
        ("Dvorak – QWERTY ⌘", Layouts.dvorakQWERTYCommand),
        ("AZERTY", Layouts.azerty),
    ])
    func eachChordIsOnTheKeyThatTypesItsLetter(name: String, layout: TableKeyLayout) throws {
        let layouts = FakeShortcutLayouts.using(layout)
        var chordKeys: Set<UInt16> = []
        for expected in Chord.allCases {
            let code = try #require(key(typing: expected.letter, on: layout), "\(name) types \(expected.letter)")
            chordKeys.insert(code)
            #expect(chord(code, expected.modifiers, on: layouts) == expected, "\(name) \(expected) on key \(code)")
        }
        for code in UInt16(0)...UInt16(127) where !chordKeys.contains(code) {
            #expect(chord(code, .command, on: layouts) == nil, "\(name) ⌘ key \(code)")
            #expect(chord(code, [.command, .shift], on: layouts) == nil, "\(name) ⇧⌘ key \(code)")
        }
    }

    // MARK: - Dvorak

    @Test func onDvorakShiftCommandCIsTheKeyThatTypesC() {
        let layouts = FakeShortcutLayouts.using(Layouts.dvorak)
        #expect(chord(34, [.command, .shift], on: layouts) == .copyMode)   // labelled I, types C
        #expect(chord(47, [.command, .shift], on: layouts) == .paste)      // labelled ., types V
        #expect(chord(7, .command, on: layouts) == .quit)                  // labelled X, types Q
        #expect(chord(8, [.command, .shift], on: layouts) == nil)          // labelled C, types J
        #expect(chord(9, [.command, .shift], on: layouts) == nil)          // labelled V, types K
        #expect(chord(12, .command, on: layouts) == nil)                   // labelled Q, types '
    }

    /// Through the input manager: the key that types C toggles copy mode and sends nothing; the key
    /// labelled C goes to the target as its own key code, where the target applies its layout.
    @Test func onDvorakThePhysicalCKeyGoesToTheTarget() {
        let capture = LayoutCapture(FakeShortcutLayouts.using(Layouts.dvorak))
        capture.press(34, [.command, .shift])
        #expect(capture.shortcuts == [.toggleCopyMode])
        #expect(capture.sent.isEmpty)

        capture.press(8, [.command, .shift])
        #expect(capture.shortcuts == [.toggleCopyMode])
        #expect(capture.sent == [.key(8, isDown: true), .key(8, isDown: false)])
    }

    @Test func onDvorakAHeldChordStillActsOnce() {
        let capture = LayoutCapture(FakeShortcutLayouts.using(Layouts.dvorak))
        capture.hold(31, [.command, .shift], repeats: 4)   // labelled O, types R
        #expect(capture.shortcuts == [.toggleRecording])
        #expect(capture.sent.isEmpty)
    }

    // MARK: - Dvorak – QWERTY ⌘

    /// With ⌘ held the layout is QWERTY, so the chords are back on the keys labelled with their letters.
    @Test func dvorakQWERTYCommandUsesQWERTYPositionsWithCommandHeld() {
        let layouts = FakeShortcutLayouts.using(Layouts.dvorakQWERTYCommand)
        #expect(chord(8, [.command, .shift], on: layouts) == .copyMode)
        #expect(chord(9, [.command, .shift], on: layouts) == .paste)
        #expect(chord(12, .command, on: layouts) == .quit)
        #expect(chord(34, [.command, .shift], on: layouts) == nil)   // types C without ⌘, I with it
        #expect(chord(7, .command, on: layouts) == nil)
    }

    @Test func dvorakQWERTYCommandThroughTheInputManager() {
        let capture = LayoutCapture(FakeShortcutLayouts.using(Layouts.dvorakQWERTYCommand))
        var quits = 0
        capture.input.terminateApp = { quits += 1 }
        capture.press(12, .command)
        capture.press(34, [.command, .shift])
        #expect(quits == 1)
        #expect(capture.shortcuts.isEmpty)
        #expect(capture.sent == [.key(34, isDown: true), .key(34, isDown: false)])
    }

    // MARK: - AZERTY

    /// ⌘Q is on the key that types Q, the key labelled A on a U.S. keyboard; the key there labelled
    /// Q types A, so ⌘ with it is the target's (Select All).
    @Test func onAZERTYCommandQIsOnThePhysicalAKey() {
        let layouts = FakeShortcutLayouts.using(Layouts.azerty)
        #expect(chord(0, .command, on: layouts) == .quit)
        #expect(chord(12, .command, on: layouts) == nil)
        #expect(chord(8, [.command, .shift], on: layouts) == .copyMode)   // C stays put
    }

    @Test func onAZERTYThroughTheInputManager() {
        let capture = LayoutCapture(FakeShortcutLayouts.using(Layouts.azerty))
        var quits = 0
        capture.input.terminateApp = { quits += 1 }
        capture.press(12, .command)
        #expect(quits == 0)
        #expect(capture.sent == [.key(12, isDown: true), .key(12, isDown: false)])
        capture.press(0, .command)
        #expect(quits == 1)
        #expect(capture.sent.count == 2)
    }

    // MARK: - Layouts without Latin letters

    /// Russian types С (Cyrillic) on the key labelled C: the chords come from the ASCII-capable layout.
    @Test func aNonLatinLayoutUsesTheASCIICapableLayout() {
        let overUS = FakeShortcutLayouts(current: Layouts.russian, asciiCapable: Layouts.us)
        #expect(chord(8, [.command, .shift], on: overUS) == .copyMode)
        #expect(chord(12, .command, on: overUS) == .quit)

        // Whatever that layout is: with Dvorak as the last Latin layout, C is the Dvorak C.
        let overDvorak = FakeShortcutLayouts(current: Layouts.russian, asciiCapable: Layouts.dvorak)
        #expect(chord(34, [.command, .shift], on: overDvorak) == .copyMode)
        #expect(chord(8, [.command, .shift], on: overDvorak) == nil)
    }

    /// With no layout to read, the chords are on their U.S. positions, as before.
    @Test func withNoLayoutTheChordsAreMatchedByPosition() {
        let none = FakeShortcutLayouts(current: nil, asciiCapable: nil)
        #expect(ShortcutKey.resolve(keyCode: 8, layouts: none) == .position)
        for expected in Chord.allCases {
            #expect(chord(expected.keyCode, expected.modifiers, on: none) == expected)
        }
        #expect(chord(34, [.command, .shift], on: none) == nil)

        let russianOnly = FakeShortcutLayouts(current: Layouts.russian, asciiCapable: nil)
        #expect(chord(8, [.command, .shift], on: russianOnly) == .copyMode)
    }

    // MARK: - Shift and Caps Lock

    /// The layout is read with ⌘ alone, and what it types is compared without case: a layout that
    /// gives a capital still matches, and ⇧ or Caps Lock in the event never changes the letter.
    @Test func caseDoesNotMatter() {
        let capitals = TableKeyLayout(plain: Layouts.usTable.mapValues { Character($0.uppercased()) })
        let layouts = FakeShortcutLayouts.using(capitals)
        #expect(ShortcutKey.resolve(keyCode: 8, layouts: layouts) == .typed("c"))
        #expect(chord(8, [.command, .shift], on: layouts) == .copyMode)
        #expect(chord(12, .command, on: layouts) == .quit)
    }

    @Test func shiftAndCapsLockOnOtherLayouts() {
        let dvorak = FakeShortcutLayouts.using(Layouts.dvorak)
        #expect(chord(34, [.command, .shift, .capsLock], on: dvorak) == .copyMode)
        #expect(chord(7, [.command, .capsLock], on: dvorak) == .quit)
        #expect(chord(7, [.command, .shift], on: dvorak) == nil)        // ⇧⌘Q is the target's
        #expect(chord(34, .command, on: dvorak) == nil)                 // ⌘C is the target's
        #expect(chord(34, [.command, .shift, .option], on: dvorak) == nil)

        let azerty = FakeShortcutLayouts.using(Layouts.azerty)
        #expect(chord(0, [.command, .capsLock, .function], on: azerty) == .quit)
        #expect(chord(0, [.command, .shift], on: azerty) == nil)
    }

    @Test func shiftAndCapsLockThroughTheInputManager() {
        let capture = LayoutCapture(FakeShortcutLayouts.using(Layouts.dvorak))
        capture.press(41, [.command, .shift, .capsLock])   // labelled ;, types S
        #expect(capture.shortcuts == [.saveScreenshot])
        #expect(capture.sent.isEmpty)
    }

    /// Without ⌘ the layout is never read: plain keys and ⇧ keys cost nothing.
    @Test func theLayoutIsReadOnlyForCommandChords() {
        let counting = CountingLayouts()
        _ = InputManager.interceptedChord(keyCode: 8, modifiers: [.shift], layouts: counting)
        _ = InputManager.interceptedChord(keyCode: 8, modifiers: [.command, .option], layouts: counting)
        #expect(counting.reads == 0)
        _ = InputManager.interceptedChord(keyCode: 8, modifiers: [.command, .shift], layouts: counting)
        #expect(counting.reads == 1)
    }

    // MARK: - The Mac's own layouts

    /// The installed layouts, read (never selected) through `UCKeyTranslate`: the same tables the
    /// fakes above stand for.
    @Test func theInstalledLayoutsTypeWhatTheFakesSay() throws {
        let us = try #require(UnicodeKeyLayout(installedID: "com.apple.keylayout.US"))
        #expect(us.isASCIICapable)
        #expect(us.character(keyCode: 8, commandHeld: true) == "c")
        #expect(us.character(keyCode: 12, commandHeld: true) == "q")

        let dvorak = try #require(UnicodeKeyLayout(installedID: "com.apple.keylayout.Dvorak"))
        #expect(dvorak.isASCIICapable)
        #expect(dvorak.character(keyCode: 34, commandHeld: true) == "c")
        #expect(dvorak.character(keyCode: 8, commandHeld: true) == "j")
        #expect(dvorak.character(keyCode: 7, commandHeld: true) == "q")

        let dvorakQWERTY = try #require(UnicodeKeyLayout(installedID: "com.apple.keylayout.DVORAK-QWERTYCMD"))
        #expect(dvorakQWERTY.character(keyCode: 8, commandHeld: false) == "j")
        #expect(dvorakQWERTY.character(keyCode: 8, commandHeld: true) == "c")
        #expect(dvorakQWERTY.character(keyCode: 34, commandHeld: true) == "i")

        let french = try #require(UnicodeKeyLayout(installedID: "com.apple.keylayout.French"))
        #expect(french.isASCIICapable)
        #expect(french.character(keyCode: 0, commandHeld: true) == "q")
        #expect(french.character(keyCode: 12, commandHeld: true) == "a")

        let russian = try #require(UnicodeKeyLayout(installedID: "com.apple.keylayout.Russian"))
        #expect(!russian.isASCIICapable)
        #expect(russian.character(keyCode: 8, commandHeld: false) == "с")
    }

    /// Reading the Mac's current layouts works and gives a Latin layout for the fallback.
    @Test func theMacsLayoutsCanBeRead() throws {
        let system = SystemShortcutLayouts()
        #expect(system.currentLayout() != nil)
        let ascii = try #require(system.asciiCapableLayout())
        #expect(ascii.isASCIICapable)
    }
}

/// Counts how often the layouts are read.
private final class CountingLayouts: ShortcutLayoutSource {
    var reads = 0
    func currentLayout() -> ShortcutKeyLayout? {
        reads += 1
        return TestKeyboardLayouts.us
    }
    func asciiCapableLayout() -> ShortcutKeyLayout? { TestKeyboardLayouts.us }
}

/// A captured window typing on the given layouts, with no device attached.
@MainActor
private final class LayoutCapture {
    static let window = 9_103
    let scratch = ScratchDefaults()
    let input: InputManager
    var sent: [InputManager.SentInput] = []
    var shortcuts: [InputManager.LocalShortcut] = []

    init(_ layouts: ShortcutLayoutSource) {
        input = InputManager(defaults: scratch.defaults, log: SessionLog(destination: .inMemory()))
        input.shortcutLayouts = layouts
        input.sentInputObserver = { [unowned self] in self.sent.append($0) }
        input.onLocalShortcut = { [unowned self] in self.shortcuts.append($0) }
        input.readClipboardText = { nil }
        input.terminateApp = {}
        input.startKeyboardCapture()
        input.windowDidBecomeKey(windowNumber: Self.window)
    }

    func press(_ keyCode: UInt16, _ flags: NSEvent.ModifierFlags) {
        hold(keyCode, flags, repeats: 0)
    }

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
