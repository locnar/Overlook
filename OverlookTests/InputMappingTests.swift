import AppKit
import Foundation
import Testing
@testable import Overlook

/// The pure parts of `InputManager`: which kvmd key a Mac key code becomes, which side of a
/// modifier is down, and where a point in the view lands on the guest screen. Nothing here sends
/// anything; the manager is never given a client.
@MainActor
@Suite("Input mapping")
struct InputMappingTests {
    let scratch = ScratchDefaults()
    let input: InputManager

    init() {
        input = InputManager(defaults: scratch.defaults, log: SessionLog(destination: .inMemory()))
    }

    // MARK: - Key codes

    @Test func mapsRepresentativeKeyCodes() {
        let expected: [UInt16: String] = [
            0: "KeyA", 6: "KeyZ", 18: "Digit1", 29: "Digit0",
            36: "Enter", 48: "Tab", 49: "Space", 51: "Backspace", 53: "Escape", 117: "Delete",
            55: "MetaLeft", 54: "MetaRight", 56: "ShiftLeft", 60: "ShiftRight",
            58: "AltLeft", 61: "AltRight", 59: "ControlLeft", 62: "ControlRight", 57: "CapsLock",
            123: "ArrowLeft", 126: "ArrowUp", 115: "Home", 121: "PageDown",
            122: "F1", 111: "F12", 64: "F17",
            82: "Numpad0", 76: "NumpadEnter", 81: "NumpadEqual",
        ]
        for (code, name) in expected {
            #expect(input.glkvmKeyForMacKeyCode(code) == name, "key code \(code)")
        }
    }

    @Test func leavesUnmappedKeyCodesUnmapped() {
        // 10 is the ISO section key, 63 is Fn, 999 is not a key code at all.
        #expect(input.glkvmKeyForMacKeyCode(10) == nil)
        #expect(input.glkvmKeyForMacKeyCode(63) == nil)
        #expect(input.glkvmKeyForMacKeyCode(999) == nil)
    }

    @Test func noTwoKeyCodesShareAName() {
        var seen: [String: UInt16] = [:]
        for code in UInt16(0)...UInt16(255) {
            guard let name = input.glkvmKeyForMacKeyCode(code) else { continue }
            #expect(seen[name] == nil, "\(name) from both \(seen[name] ?? 0) and \(code)")
            seen[name] = code
        }
        #expect(seen.count == 105)
    }

    @Test func typedLettersBecomeTheirKeys() {
        for scalar in "abcdefghijklmnopqrstuvwxyz".unicodeScalars {
            let character = Character(scalar)
            let name = input.glkvmKeyForMacKeyCode(input.keyCodeForCharacter(character))
            #expect(name == "Key" + String(character).uppercased())
        }
    }

    @Test func typedPunctuationBecomesItsKey() {
        let expected: [Character: String] = [
            " ": "Space", "\n": "Enter", ",": "Comma", ".": "Period", "/": "Slash",
            ";": "Semicolon", "'": "Quote", "[": "BracketLeft", "]": "BracketRight",
            "\\": "Backslash", "`": "Backquote", "-": "Minus", "=": "Equal",
        ]
        for (character, name) in expected {
            #expect(input.glkvmKeyForMacKeyCode(input.keyCodeForCharacter(character)) == name)
        }
    }

    @Test func untypeableCharactersFallBackToKeyCodeZero() {
        #expect(input.keyCodeForCharacter("é") == 0)
        #expect(input.keyCodeForCharacter("A") == 0)
    }

    // MARK: - Modifier sides

    private func flags(_ family: NSEvent.ModifierFlags, sideBits: UInt) -> NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: family.rawValue | sideBits)
    }

    @Test func readsWhichSideOfAModifierIsDown() {
        let leftShift = flags(.shift, sideBits: 0x0002)
        #expect(InputManager.isModifierSideDown("ShiftLeft", flags: leftShift))
        #expect(InputManager.isModifierSideDown("ShiftRight", flags: leftShift) == false)

        let rightCommand = flags(.command, sideBits: 0x0010)
        #expect(InputManager.isModifierSideDown("MetaRight", flags: rightCommand))
        #expect(InputManager.isModifierSideDown("MetaLeft", flags: rightCommand) == false)

        let rightControl = flags(.control, sideBits: 0x2000)
        #expect(InputManager.isModifierSideDown("ControlRight", flags: rightControl))
        #expect(InputManager.isModifierSideDown("ControlLeft", flags: rightControl) == false)
    }

    @Test func bothSidesCanBeDown() {
        let both = flags(.option, sideBits: 0x0020 | 0x0040)
        #expect(InputManager.isModifierSideDown("AltLeft", flags: both))
        #expect(InputManager.isModifierSideDown("AltRight", flags: both))
    }

    @Test func withNoSideBitsTheFamilyFlagDecides() {
        let bare = NSEvent.ModifierFlags.shift
        #expect(InputManager.isModifierSideDown("ShiftLeft", flags: bare))
        #expect(InputManager.isModifierSideDown("ShiftRight", flags: bare))
    }

    @Test func aSideBitWithoutItsFamilyIsNotDown() {
        #expect(InputManager.isModifierSideDown("ShiftLeft", flags: NSEvent.ModifierFlags(rawValue: 0x0002)) == false)
        #expect(InputManager.isModifierSideDown("KeyA", flags: .shift) == false)
    }

    // MARK: - Geometry

    @Test func absolutePointsSpanTheSignedRange() {
        let origin = input.glkvmAbsolutePoint(fromNormalized: CGPoint(x: 0, y: 0))
        #expect(origin.0 == -32767)
        #expect(origin.1 == -32767)

        let centre = input.glkvmAbsolutePoint(fromNormalized: CGPoint(x: 0.5, y: 0.5))
        #expect(centre.0 == 0)
        #expect(centre.1 == 0)

        let clamped = input.glkvmAbsolutePoint(fromNormalized: CGPoint(x: -1, y: 2))
        #expect(clamped.0 == -32767)
        #expect(clamped.1 == 32767)
    }

    @Test func videoIsLetterboxedInTheView() {
        let wide = input.videoContentRect(viewSize: CGSize(width: 200, height: 100), videoSize: CGSize(width: 100, height: 100))
        #expect(wide == CGRect(x: 50, y: 0, width: 100, height: 100))

        let tall = input.videoContentRect(viewSize: CGSize(width: 100, height: 200), videoSize: CGSize(width: 100, height: 100))
        #expect(tall == CGRect(x: 0, y: 50, width: 100, height: 100))
    }

    @Test func pointsNormalizeAgainstTheVideoNotTheView() {
        let view = CGSize(width: 200, height: 100)
        let video = CGSize(width: 100, height: 100)
        #expect(input.normalizePointInViewToVideo(pointInView: CGPoint(x: 50, y: 0), viewSize: view, videoSize: video) == CGPoint(x: 0, y: 0))
        #expect(input.normalizePointInViewToVideo(pointInView: CGPoint(x: 100, y: 50), viewSize: view, videoSize: video) == CGPoint(x: 0.5, y: 0.5))
        #expect(input.normalizePointInViewToVideo(pointInView: CGPoint(x: 150, y: 100), viewSize: view, videoSize: video) == CGPoint(x: 1, y: 1))
        // A point in the letterbox bar lands on the nearest edge of the video.
        #expect(input.normalizePointInViewToVideo(pointInView: CGPoint(x: 10, y: 50), viewSize: view, videoSize: video) == CGPoint(x: 0, y: 0.5))
    }

    @Test func withoutAVideoSizeTheWholeViewIsUsed() {
        let view = CGSize(width: 100, height: 50)
        #expect(input.normalizePointInViewToVideo(pointInView: CGPoint(x: 50, y: 25), viewSize: view, videoSize: nil) == CGPoint(x: 0.5, y: 0.5))
        #expect(input.normalizePointInViewToVideo(pointInView: CGPoint(x: 500, y: -5), viewSize: view, videoSize: nil) == CGPoint(x: 1, y: 0))
        #expect(input.normalizePointInViewToVideo(pointInView: CGPoint(x: 5, y: 5), viewSize: .zero, videoSize: nil) == .zero)
    }

    @Test func relativeScaleIsGuestPixelsPerViewPoint() {
        #expect(input.computeRelativeDeltaScale(viewSize: CGSize(width: 960, height: 540), videoSize: CGSize(width: 1920, height: 1080)) == 2)
        // Letterboxed top and bottom: the 2:1 video uses the view's full width, so the scale
        // comes from that width.
        #expect(input.computeRelativeDeltaScale(viewSize: CGSize(width: 1000, height: 1000), videoSize: CGSize(width: 2000, height: 1000)) == 2)
        #expect(input.computeRelativeDeltaScale(viewSize: CGSize(width: 500, height: 1000), videoSize: nil) == 1)
    }

    // MARK: - Settings

    @Test func relativeMouseSettingsDefaultAndPersist() {
        #expect(input.relativeSensitivity == 1.0)
        #expect(input.useUnacceleratedRelativeInput == false)

        input.relativeSensitivity = 1.5
        input.useUnacceleratedRelativeInput = true
        #expect(scratch.defaults.double(forKey: "overlook.relativeMouseSensitivity") == 1.5)
        #expect(scratch.defaults.bool(forKey: "overlook.relativeMouseUnacceleratedInput"))

        let reloaded = InputManager(defaults: scratch.defaults, log: SessionLog(destination: .inMemory()))
        #expect(reloaded.relativeSensitivity == 1.5)
        #expect(reloaded.useUnacceleratedRelativeInput)
    }
}
