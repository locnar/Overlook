import Foundation
import Testing
@testable import Overlook

/// Every Mac key code `InputManager` sends, against the name it must send it as. The table is the
/// whole mapping: a code missing here must map to nothing, so a mapping added or changed without
/// a line here fails.
@Suite("Key code table")
struct KeyCodeTableTests {
    /// Mac virtual key code (`kVK_*`) → kvmd key name, as on an ANSI or JIS keyboard.
    static let table: [UInt16: String] = [
        // Letters
        0: "KeyA", 11: "KeyB", 8: "KeyC", 2: "KeyD", 14: "KeyE", 3: "KeyF", 5: "KeyG", 4: "KeyH",
        34: "KeyI", 38: "KeyJ", 40: "KeyK", 37: "KeyL", 46: "KeyM", 45: "KeyN", 31: "KeyO",
        35: "KeyP", 12: "KeyQ", 15: "KeyR", 1: "KeyS", 17: "KeyT", 32: "KeyU", 9: "KeyV",
        13: "KeyW", 7: "KeyX", 16: "KeyY", 6: "KeyZ",
        // Digits
        18: "Digit1", 19: "Digit2", 20: "Digit3", 21: "Digit4", 23: "Digit5", 22: "Digit6",
        26: "Digit7", 28: "Digit8", 25: "Digit9", 29: "Digit0",
        // Punctuation
        50: "Backquote", 27: "Minus", 24: "Equal", 33: "BracketLeft", 30: "BracketRight",
        41: "Semicolon", 39: "Quote", 42: "Backslash", 43: "Comma", 47: "Period", 44: "Slash",
        // ISO and JIS extras
        10: "IntlBackslash", 93: "IntlYen", 94: "IntlRo",
        // Whitespace and editing
        49: "Space", 48: "Tab", 36: "Enter", 51: "Backspace", 53: "Escape",
        // Keypad
        82: "Numpad0", 83: "Numpad1", 84: "Numpad2", 85: "Numpad3", 86: "Numpad4",
        87: "Numpad5", 88: "Numpad6", 89: "Numpad7", 91: "Numpad8", 92: "Numpad9",
        65: "NumpadDecimal", 67: "NumpadMultiply", 69: "NumpadAdd", 78: "NumpadSubtract",
        75: "NumpadDivide", 76: "NumpadEnter", 81: "NumpadEqual",
        // Navigation
        114: "Help", 115: "Home", 119: "End", 116: "PageUp", 121: "PageDown", 117: "Delete",
        123: "ArrowLeft", 124: "ArrowRight", 125: "ArrowDown", 126: "ArrowUp",
        // Modifiers
        55: "MetaLeft", 54: "MetaRight", 56: "ShiftLeft", 60: "ShiftRight", 58: "AltLeft",
        61: "AltRight", 59: "ControlLeft", 62: "ControlRight", 57: "CapsLock",
        // Function keys
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12",
        105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]

    /// The names kvmd accepts: the keys of `WEB_TO_EVDEV` in pikvm/kvmd's
    /// `kvmd/keyboard/mappings.py`. A name outside it is dropped by the device's validator.
    static let kvmdNames: Set<String> = [
        "KeyA", "KeyB", "KeyC", "KeyD", "KeyE", "KeyF", "KeyG", "KeyH", "KeyI", "KeyJ", "KeyK",
        "KeyL", "KeyM", "KeyN", "KeyO", "KeyP", "KeyQ", "KeyR", "KeyS", "KeyT", "KeyU", "KeyV",
        "KeyW", "KeyX", "KeyY", "KeyZ", "Digit1", "Digit2", "Digit3", "Digit4", "Digit5",
        "Digit6", "Digit7", "Digit8", "Digit9", "Digit0", "Enter", "Escape", "Backspace", "Tab",
        "Space", "Minus", "Equal", "BracketLeft", "BracketRight", "Backslash", "Semicolon",
        "Quote", "Backquote", "Comma", "Period", "Slash", "CapsLock", "F1", "F2", "F3", "F4", "F5",
        "F6", "F7", "F8", "F9", "F10", "F11", "F12", "PrintScreen", "Insert", "Home", "PageUp",
        "Delete", "End", "PageDown", "ArrowRight", "ArrowLeft", "ArrowDown", "ArrowUp",
        "ControlLeft", "ShiftLeft", "AltLeft", "MetaLeft", "ControlRight", "ShiftRight",
        "AltRight", "MetaRight", "Pause", "ScrollLock", "NumLock", "ContextMenu", "NumpadDivide",
        "NumpadMultiply", "NumpadSubtract", "NumpadAdd", "NumpadEnter", "Numpad1", "Numpad2",
        "Numpad3", "Numpad4", "Numpad5", "Numpad6", "Numpad7", "Numpad8", "Numpad9", "Numpad0",
        "NumpadDecimal", "Power", "IntlBackslash", "IntlYen", "IntlRo", "KanaMode", "Convert",
        "NonConvert", "AudioVolumeMute", "AudioVolumeUp", "AudioVolumeDown", "F20", "F21", "F22",
        "F23", "F24", "F13", "F14", "F15", "F16", "F17", "F18", "F19",
    ]

    /// Names Overlook sends that kvmd has no entry for. They predate this table and are kept as
    /// they were; the device ignores them.
    static let namesKvmdDoesNotKnow: Set<String> = ["Help", "NumpadEqual"]

    @Test func everyKeyCodeMapsAsTheTableSays() {
        for code in UInt16(0)...UInt16(255) {
            #expect(
                InputManager.glkvmKey(forMacKeyCode: code, isISOKeyboard: false) == Self.table[code],
                "key code \(code)"
            )
        }
        #expect(Self.table.count == 111)
    }

    /// On an ISO keyboard macOS reports the key left of 1 as the section key and the key by left
    /// Shift as grave; the two are swapped back so each reaches the target at its position.
    @Test func anISOKeyboardSwapsTheSectionAndGraveKeys() {
        #expect(InputManager.glkvmKey(forMacKeyCode: 10, isISOKeyboard: true) == "Backquote")
        #expect(InputManager.glkvmKey(forMacKeyCode: 50, isISOKeyboard: true) == "IntlBackslash")
        for code in UInt16(0)...UInt16(255) where code != 10 && code != 50 {
            #expect(
                InputManager.glkvmKey(forMacKeyCode: code, isISOKeyboard: true) == Self.table[code],
                "key code \(code)"
            )
        }
    }

    @Test(arguments: [
        (UInt16(10), "IntlBackslash"), (93, "IntlYen"), (94, "IntlRo"),
        (79, "F18"), (80, "F19"), (90, "F20"),
    ])
    func newlyMappedKeys(code: UInt16, name: String) {
        #expect(InputManager.glkvmKey(forMacKeyCode: code, isISOKeyboard: false) == name)
    }

    /// JIS Eisu (102), Kana (104) and keypad comma (95) would be Lang2, Lang1 and NumpadComma,
    /// none of which kvmd has; Fn (63) never reaches the target.
    @Test func keysKvmdHasNoNameForStayUnmapped() {
        for code: UInt16 in [63, 95, 102, 104] {
            #expect(InputManager.glkvmKey(forMacKeyCode: code, isISOKeyboard: false) == nil, "key code \(code)")
            #expect(InputManager.glkvmKey(forMacKeyCode: code, isISOKeyboard: true) == nil, "key code \(code)")
        }
    }

    @Test func everyNameSentIsOneKvmdKnows() {
        for name in Set(Self.table.values).subtracting(Self.namesKvmdDoesNotKnow) {
            #expect(Self.kvmdNames.contains(name), "\(name)")
        }
        #expect(Self.namesKvmdDoesNotKnow.isSubset(of: Set(Self.table.values)))
    }
}
