import Carbon.HIToolbox
import Foundation

/// A keyboard layout, as far as Overlook's own shortcuts need one: which character a key types.
/// `ShortcutKey.resolve` reads it; the app uses the Mac's layouts (`SystemShortcutLayouts`), and
/// the tests supply tables of their own.
protocol ShortcutKeyLayout {
    /// Whether the layout types Latin letters: U.S., Dvorak and AZERTY do; Russian and Greek do not.
    var isASCIICapable: Bool { get }

    /// The character `keyCode` types, with ⌘ held when `commandHeld` and no other modifier, or nil
    /// when it types nothing. Layouts such as "Dvorak – QWERTY ⌘" type different letters with ⌘ held.
    func character(keyCode: UInt16, commandHeld: Bool) -> Character?
}

/// Where the layouts come from: the one in use now, and the ASCII-capable one macOS keeps for
/// shortcuts while a layout without Latin letters is in use.
protocol ShortcutLayoutSource {
    func currentLayout() -> ShortcutKeyLayout?
    func asciiCapableLayout() -> ShortcutKeyLayout?
}

/// Which key of Overlook's shortcuts a ⌘ key-down is on.
enum ShortcutKey: Equatable {
    /// The character the key types with ⌘ held, lowercased (nil when it types nothing). A chord
    /// matches when this is its letter.
    case typed(Character?)
    /// No layout could be read, so chords are matched by key position (U.S. ANSI), as before.
    case position

    /// What `keyCode` is for the shortcuts, the way macOS matches menu key equivalents: by the
    /// character the key types on the layout in use, with ⌘ held. A layout without Latin letters
    /// (Russian, Greek) is passed over for the most recently used ASCII-capable one, which is
    /// what macOS falls back to for ⌘ shortcuts on those layouts.
    static func resolve(keyCode: UInt16, layouts: ShortcutLayoutSource) -> ShortcutKey {
        let layout: ShortcutKeyLayout?
        if let current = layouts.currentLayout(), current.isASCIICapable {
            layout = current
        } else {
            layout = layouts.asciiCapableLayout()
        }
        guard let layout else { return .position }
        // ⌘ alone: ⇧ and Caps Lock are left out, so a letter key gives its lowercase letter. The
        // result is lowercased all the same, in case a layout types a capital with ⌘.
        guard let typed = layout.character(keyCode: keyCode, commandHeld: true) else { return .typed(nil) }
        let lowercased = typed.lowercased()
        return .typed(lowercased.count == 1 ? Character(lowercased) : typed)
    }
}

// MARK: - The Mac's layouts

/// The Mac's keyboard layouts, read through Text Input Sources: `TISCopyCurrentKeyboardLayoutInputSource`
/// (the layout in use, also under an input method) and `TISCopyCurrentASCIICapableKeyboardLayoutInputSource`.
/// Nothing here selects or changes an input source.
struct SystemShortcutLayouts: ShortcutLayoutSource {
    func currentLayout() -> ShortcutKeyLayout? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else { return nil }
        return UnicodeKeyLayout(inputSource: source)
    }

    func asciiCapableLayout() -> ShortcutKeyLayout? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue() else { return nil }
        return UnicodeKeyLayout(inputSource: source)
    }
}

/// One keyboard layout's `uchr` data, translated with `UCKeyTranslate`.
struct UnicodeKeyLayout: ShortcutKeyLayout {
    let isASCIICapable: Bool
    private let layoutData: Data

    init?(inputSource: TISInputSource) {
        guard let dataPointer = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        layoutData = Unmanaged<CFData>.fromOpaque(dataPointer).takeUnretainedValue() as Data
        if let asciiPointer = TISGetInputSourceProperty(inputSource, kTISPropertyInputSourceIsASCIICapable) {
            isASCIICapable = CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(asciiPointer).takeUnretainedValue())
        } else {
            isASCIICapable = false
        }
    }

    /// An installed layout by its input source ID ("com.apple.keylayout.Dvorak"), whether or not
    /// it is enabled. Only read, never selected.
    init?(installedID: String) {
        let filter = [kTISPropertyInputSourceID as String: installedID] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource],
              let source = list.first else {
            return nil
        }
        self.init(inputSource: source)
    }

    func character(keyCode: UInt16, commandHeld: Bool) -> Character? {
        // Carbon modifier state: the event-record modifier bits shifted down by 8 (cmdKey → 1).
        let modifierState = commandHeld ? UInt32((cmdKey >> 8) & 0xFF) : 0
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = layoutData.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return OSStatus(paramErr) }
            return UCKeyTranslate(
                base.assumingMemoryBound(to: UCKeyboardLayout.self),
                keyCode,
                UInt16(kUCKeyActionDown),
                modifierState,
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysMask),
                &deadKeyState,
                characters.count,
                &length,
                &characters
            )
        }
        guard status == noErr, length > 0 else { return nil }
        let string = String(utf16CodeUnits: characters, count: length)
        return string.count == 1 ? string.first : nil
    }
}
