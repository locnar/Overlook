import CryptoKit
import Foundation
import Testing
@testable import Overlook

@Suite("JSONValue")
struct JSONValueTests {
    private func decode(_ json: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }

    @Test func decodesEachKindOfValue() throws {
        let value = try decode("""
        {"null": null, "flag": true, "count": 3, "ratio": 1.5, "name": "kvm",
         "list": [1, "two"], "nested": {"inner": false}}
        """)

        #expect(value["null"] == .null)
        #expect(value["flag"] == .bool(true))
        #expect(value["count"] == .int(3))
        #expect(value["ratio"] == .double(1.5))
        #expect(value["name"] == .string("kvm"))
        #expect(value["list"] == .array([.int(1), .string("two")]))
        #expect(value["nested"]?["inner"] == .bool(false))
        #expect(value["missing"] == nil)
    }

    @Test func booleansStayBooleansAndWholeNumbersStayInts() throws {
        // Order matters in the decoder: `true` must not become 1, and `2` must not become 2.0.
        #expect(try decode("true") == .bool(true))
        #expect(try decode("2") == .int(2))
        #expect(try decode("2.5") == .double(2.5))
    }

    @Test func readersConvertBetweenNumberKinds() {
        #expect(JSONValue.int(4).doubleValue == 4)
        #expect(JSONValue.double(4.0).intValue == 4)
        // Rounded, so a reported 29.97 fps reads as 30.
        #expect(JSONValue.double(29.97).intValue == 30)
        #expect(JSONValue.string("4").intValue == nil)
        #expect(JSONValue.bool(true).boolValue == true)
        #expect(JSONValue.int(1).boolValue == nil)
        #expect(JSONValue.string("x").stringValue == "x")
        #expect(JSONValue.null.isNull)
        #expect(JSONValue.int(0).isNull == false)
        #expect(JSONValue.array([.int(1)])["key"] == nil)
    }

    @Test func roundTripsThroughJSON() throws {
        let original = JSONValue.object([
            "a": .array([.null, .bool(false), .int(-7), .double(0.25), .string("é")]),
            "b": .object(["c": .int(1)]),
        ])
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(JSONValue.self, from: data) == original)
    }
}

@Suite("EDID catalog")
struct EDIDCatalogTests {
    @Test func optionIDsAreUnique() {
        let ids = EDIDCatalog.options.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func customIsTheOnlyEntryWithoutABlob() {
        let blobless = EDIDCatalog.options.filter { $0.edid == nil }
        #expect(blobless.map(\.id) == [EDIDCatalog.customOptionID])
        #expect(EDIDCatalog.options.last?.id == EDIDCatalog.customOptionID)
        #expect(EDIDCatalog.resolvedEdid(forID: EDIDCatalog.customOptionID) == nil)
    }

    /// Each entry's own blob is what gets pushed, so each must be a whole EDID: a 128-byte base
    /// block (plus one 128-byte extension when byte 126 says so), the fixed header, and every
    /// block summing to 0 mod 256. No entry is exempt today.
    @Test func everyEntrysBlobIsAWellFormedEDID() {
        for option in EDIDCatalog.options {
            guard let blob = option.edid else { continue }
            let tokens = blob.split(whereSeparator: { $0.isWhitespace })
            let bytes = tokens.compactMap { $0.count == 2 ? UInt8($0, radix: 16) : nil }
            #expect(bytes.count == tokens.count, "\(option.id) has a token that is not one hex byte")
            #expect(bytes.count == 128 || bytes.count == 256, "\(option.id) has \(bytes.count) bytes")
            guard bytes.count >= 128 else { continue }
            #expect(bytes.prefix(8) == [0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00], "\(option.id) header")
            #expect((Int(bytes[126]) + 1) * 128 == bytes.count, "\(option.id) says \(bytes[126]) extensions")
            #expect(bytes[0..<128].reduce(UInt8(0), &+) == 0, "\(option.id) base block checksum")
            if bytes.count == 256 {
                #expect(bytes[128..<256].reduce(UInt8(0), &+) == 0, "\(option.id) extension checksum")
            }
        }
    }

    @Test func anEntryResolvesToItsOwnBlob() {
        for option in EDIDCatalog.options {
            #expect(EDIDCatalog.resolvedEdid(for: option) == option.edid, "\(option.id)")
        }
    }

    @Test func anUnknownIDResolvesToNothing() {
        #expect(EDIDCatalog.resolvedEdid(forID: "E0x0") == nil)
    }

    @Test func everyBlobIsWholeHexBytesStartingWithTheEDIDHeader() {
        for option in EDIDCatalog.options {
            guard let blob = EDIDCatalog.resolvedEdid(for: option) else { continue }
            let bytes = blob.split(whereSeparator: { $0 == " " || $0 == "\n" })
            #expect(bytes.allSatisfy { $0.count == 2 && UInt8($0, radix: 16) != nil }, "\(option.id)")
            #expect(bytes.prefix(8).joined(separator: " ") == "00 ff ff ff ff ff ff 00", "\(option.id)")
            // A base block is 128 bytes; extension blocks add 128 each.
            #expect(bytes.count % 128 == 0, "\(option.id) has \(bytes.count) bytes")
        }
    }

    @Test func everyBlockOfEveryBlobHasAZeroChecksum() {
        // Each 128-byte block ends with a checksum byte that makes the block sum to 0 mod 256.
        // A missing or extra byte anywhere shifts the checksum out of place and fails here.
        for option in EDIDCatalog.options {
            guard let blob = EDIDCatalog.resolvedEdid(for: option) else { continue }
            let bytes = blob.split(whereSeparator: { $0 == " " || $0 == "\n" }).compactMap { UInt8($0, radix: 16) }
            for start in stride(from: 0, to: bytes.count, by: 128) {
                let block = bytes[start..<min(start + 128, bytes.count)]
                let sum = block.reduce(UInt8(0), &+)
                #expect(sum == 0, "\(option.id) block \(start / 128) sums to \(sum)")
            }
        }
    }
}

// MARK: - Frozen EDID output

/// What `EDIDCatalog.resolvedEdid(forID:)` returns for each entry, frozen from the catalog as it
/// stood before the built-in/override cleanup, so tidying the catalog cannot change what Overlook
/// sends to a device. `bytes` is the SHA-256 of the decoded EDID bytes; `text` is the SHA-256 of
/// the exact string returned (spacing and line breaks included), which `applyEdid` trims and puts
/// in the form body; `count` is the EDID's length in bytes. `nil` means the entry has no blob.
private struct FrozenEDID {
    let bytes: String
    let text: String
    let count: Int
}

private let frozenResolvedEDIDs: [(id: String, frozen: FrozenEDID?)] = [
    ("E2560x1440", FrozenEDID(bytes: "b4522b9afa6bfade6226b6677b1888968ee392cd24e71f151d4847ff1d95b9e2", text: "e1fd7dc7720b9cc5e0d554f0b3492f77072197ded3b3b730984da101a07f3b03", count: 256)),
    ("E3840x2160", FrozenEDID(bytes: "33dea309ab142d98173fd198e615636c760f6eeee475f524d517388d994d7878", text: "94f1abbcbdcdbc388b8d171e152dd625d33d6a1e886848e924904a0b646585f1", count: 256)),
    ("E1920x1080", FrozenEDID(bytes: "00b70d377bc82b796ac705fb3d8872f116d3ce211a88ad4c20a463bf53404ace", text: "5007771f19fc9675451219dcd0edf1de019259c6178e27c2542037b70a42e466", count: 256)),
    ("E1920x1200", FrozenEDID(bytes: "551256cd235fe2f8644d641ebe109e85d966faf4673ab1eef63fca072894b736", text: "fc4f88509a516635e0dc1c6ecbb2fdf926b28cf567828829922b118cd7bcc805", count: 256)),
    ("E1920x1280", FrozenEDID(bytes: "aec3854ce4805cd60e5b92ec9f7c55dcb60f3b28eb35dde44a7a7d89a24843b8", text: "c80552759113a9c2993a14a83e29fe594c37d69570ac20db37d6caa2f030dc0d", count: 128)),
    ("E2560x1440VS", FrozenEDID(bytes: "7d1aab092a5959232eab8eb43b25b5a0d490f699f3620a55fcc04e35757ca32a", text: "f44eaa4f90fa2817aa470355c770ac852cd180bf5dcfa61894c824220ecd31fb", count: 256)),
    ("E1600x1200", FrozenEDID(bytes: "f76738e5429bfc7aaa05272744a3abcbcc22d04d9cf9f39670bd87684953b855", text: "0ed5b1df44ea278732cf9a12dfdd5af19a51b2953d7a5918932f26bae2b0d66a", count: 128)),
    ("E2560x1664AOC", FrozenEDID(bytes: "c0fb76738547419911aafbcaf6014fcf25f6e8dc77fb61d8e741686ff074d04a", text: "00ac40188197ff9f001e419c29f9b242b7879254726afffad40597e3904fdae4", count: 256)),
    ("E2560x1600LTM", FrozenEDID(bytes: "1cb9150844acd73eab79aec0daa71248e64ce41ae4cfe881cf5f6eee628e7bbf", text: "9f1a9bb333e045a0e464274598b6a34db15af5d4208c8aeeb5f20123733e8553", count: 256)),
    ("E3440x1440AOC", FrozenEDID(bytes: "d54b80f3910aa71a41e5470f5abc412cb45212ec9ab0da7168e58a8bd97bcc37", text: "8ad9661cc418f90f92ffd2a4841846a4c4b59619866659804530769326298905", count: 256)),
    ("E2560x1080AOC", FrozenEDID(bytes: "d37da0e3f311271dad5da8166a168ef88da3468a30d1810a9056842cae74f86b", text: "01e74ec6760a9c9ac5282a8233076a3fd7e5f7bdf7c9e05b4adb85522edbe66d", count: 256)),
    ("E1024x768AOC", FrozenEDID(bytes: "41eb4f820794eeaf2c6534490a868dc662f9ac19ddf6102828ceda7829bbbf0f", text: "7fa56d466ef981d36d0612585b2d592ee530a602ed292129497e898df099a980", count: 256)),
    ("E800x600CHR", FrozenEDID(bytes: "5d09431bdc6004ffc60c29b55110aa309c69bdf7be521efa7e14a08492363d25", text: "7c7fb69faa0507624949744aebfa3ab74d2ed672b8588121c7464c8a19dbd739", count: 128)),
    ("CUSTOMIZE", nil),
]

private func sha256Hex(_ data: some DataProtocol) -> String {
    SHA256.hash(data: Data(data)).map { String(format: "%02x", $0) }.joined()
}

/// The bytes of a hex blob in the catalog's format: two-digit hex bytes separated by whitespace.
private func edidBytes(_ blob: String) -> [UInt8] {
    blob.split(whereSeparator: { $0.isWhitespace }).compactMap { UInt8($0, radix: 16) }
}

@Suite("EDID catalog output is frozen")
struct EDIDFrozenOutputTests {
    @Test func theCatalogListsTheSameEntriesInTheSameOrder() {
        #expect(EDIDCatalog.options.map(\.id) == frozenResolvedEDIDs.map(\.id))
    }

    @Test func everyEntryResolvesToItsFrozenBlob() {
        for (id, frozen) in frozenResolvedEDIDs {
            let resolved = EDIDCatalog.resolvedEdid(forID: id)
            guard let frozen else {
                #expect(resolved == nil, "\(id) should have no blob")
                continue
            }
            guard let resolved else {
                Issue.record("\(id) resolves to nothing")
                continue
            }
            let bytes = edidBytes(resolved)
            #expect(bytes.count == frozen.count, "\(id) has \(bytes.count) bytes")
            #expect(sha256Hex(bytes) == frozen.bytes, "\(id) bytes changed")
            #expect(sha256Hex(Data(resolved.utf8)) == frozen.text, "\(id) text changed")
        }
    }

    @Test func resolvingAnOptionAndItsIDAgree() {
        for option in EDIDCatalog.options {
            #expect(EDIDCatalog.resolvedEdid(for: option) == EDIDCatalog.resolvedEdid(forID: option.id), "\(option.id)")
        }
    }
}

/// Remembers the last EDID posted to a stubbed device and reports it back from `get_edid`, as
/// kvmd does.
private final class EchoingEDIDDevice: @unchecked Sendable {
    private let lock = NSLock()
    private var current = ""

    /// The `edid` field of a `multipart/form-data` body as `setEDID` writes it.
    static func edidField(of body: String) -> String? {
        let start = "Content-Disposition: form-data; name=\"edid\"\r\n\r\n"
        guard let open = body.range(of: start),
              let close = body.range(of: "\r\n--", range: open.upperBound..<body.endIndex) else { return nil }
        return String(body[open.upperBound..<close.lowerBound])
    }

    func handle(_ request: StubDevice.Request) -> StubDevice.Response {
        switch request.path {
        case "/api/upgrade/edid":
            lock.withLock { current = Self.edidField(of: request.bodyText) ?? "" }
            return .ok()
        case "/api/upgrade/get_edid":
            return .ok(.string(lock.withLock { current }))
        default:
            return .ok()
        }
    }
}

/// The settings panel's two uses of the catalog: pushing an entry's blob when it is picked, and
/// working out which entry (if any) the device's current EDID is, to show it in the picker.
@MainActor
@Suite("EDID picker")
struct EDIDPickerTests {
    let fixture: SettingsPanelFixture

    init() throws {
        let echo = EchoingEDIDDevice()
        fixture = try SettingsPanelFixture(
            device: StubDevice { request in echo.handle(request) },
            config: ["theme_mode": .string("0"), "scroll_rate": .int(5)]
        )
    }

    private var model: WebUISettingsPanelModel { fixture.model }
    private var actions: WebUISettingsActions { fixture.actions }

    /// The catalog's old built-in copy of 3840x2160 (211 bytes, never sent: an override won, and
    /// the entry now holds that override's blob).
    private let oldBuiltIn3840x2160 = """
        00 ff ff ff ff ff ff 00 32 8d 32 31 00 88 88 88
        20 1e 01 03 80 0c 07 78 0a 0d c9 a0 57 47 98 27
        12 48 4c 00 00 00 01 01 01 01 01 01 01 01 01 01
        01 01 01 01 01 01 02 3a 80 18 71 38 2d 40 58 2c
        45 00 13 2b 21 00 00 1e 00 00 00 ff 00 30 30 30
        30 30 30 30 30 30 30 30 30 30 30 30 0a 00 00 00
        fd 00 18 3c 1e 53 11 00 0a 20 20 20 20 20 20 00
        00 00 fc 00 47 4c 4b 56 4d 0a 20 20 20 20 20 20
        20 01 10 02 03 18 c1 48 90 1f 04 13 03 12 01 23
        09 07 01 83 01 00 00 65 03 0c 00 10 00 8c 0a d0
        8a 20 e0 2d 10 10 3e 96 00 13 2b 21 00 00 18 00
        00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
        00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
        00 00 62
        """

    @Test func pickingAnEntrySendsItsBlobAndThePickerThenShowsIt() async throws {
        for option in EDIDCatalog.options {
            guard let blob = EDIDCatalog.resolvedEdid(forID: option.id) else { continue }
            let before = fixture.device.requests(to: "/api/upgrade/edid").count

            await actions.applyEdid(blob)

            let posts = fixture.device.requests(to: "/api/upgrade/edid")
            #expect(posts.count == before + 1, "\(option.id)")
            let sent = try #require(posts.last.flatMap { EchoingEDIDDevice.edidField(of: $0.bodyText) })
            #expect(sent == blob.trimmingCharacters(in: .whitespacesAndNewlines), "\(option.id)")
            #expect(model.selectedEdidOption == option.id, "\(option.id)")
        }
        #expect(model.errorHistory.isEmpty)
    }

    @Test func theDevicesCurrentEDIDSelectsTheMatchingEntry() {
        for option in EDIDCatalog.options {
            guard let blob = EDIDCatalog.resolvedEdid(for: option) else { continue }
            model.currentEdid = blob
            actions.syncEdidSelectionFromCurrent()
            #expect(model.selectedEdidOption == option.id, "\(option.id)")
            #expect(model.customEdidDraft == blob, "\(option.id)")
        }
    }

    @Test func matchingIgnoresCaseAndSpacing() {
        for option in EDIDCatalog.options {
            guard let blob = EDIDCatalog.resolvedEdid(for: option) else { continue }
            let reformatted = edidBytes(blob).map { String(format: "%02X", $0) }.joined()
            model.currentEdid = reformatted
            actions.syncEdidSelectionFromCurrent()
            #expect(model.selectedEdidOption == option.id, "\(option.id)")
        }
    }

    @Test func noCurrentEDIDSelectsCustomWithAnEmptyDraft() {
        model.currentEdid = "  \n "
        actions.syncEdidSelectionFromCurrent()
        #expect(model.selectedEdidOption == EDIDCatalog.customOptionID)
        #expect(model.customEdidDraft == "")
    }

    @Test func anUnlistedEDIDSelectsCustomAndFillsTheDraft() {
        model.currentEdid = "00 ff ff ff ff ff ff 00 12 34"
        actions.syncEdidSelectionFromCurrent()
        #expect(model.selectedEdidOption == EDIDCatalog.customOptionID)
        #expect(model.customEdidDraft == "00 ff ff ff ff ff ff 00 12 34")
    }

    /// A device reporting the old built-in 3840x2160 text was never recognised as that entry:
    /// matching compared against the override's blob then, and against the entry's (same) blob now.
    @Test func theOldBuiltIn3840x2160CopySelectsCustom() {
        #expect(edidBytes(oldBuiltIn3840x2160).count == 211)
        model.currentEdid = oldBuiltIn3840x2160
        actions.syncEdidSelectionFromCurrent()
        #expect(model.selectedEdidOption == EDIDCatalog.customOptionID)
    }
}
