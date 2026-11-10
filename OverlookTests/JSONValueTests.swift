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

// MARK: - EDID labels match their data

/// The facts a catalog label is built from, read out of an EDID's base block.
struct DecodedEDID: Equatable {
    /// The three-letter PNP manufacturer code from bytes 8–9 (e.g. "AOC").
    let manufacturer: String
    /// The monitor name descriptor (tag 0xFC), trimmed, or nil when the EDID has none.
    let name: String?
    /// The preferred timing: the first detailed timing descriptor.
    let width: Int
    let height: Int
    let refreshHz: Double
    let interlaced: Bool

    /// Decodes `bytes` (at least the 128-byte base block), or nil when there is no detailed timing.
    init?(_ bytes: [UInt8]) {
        guard bytes.count >= 128 else { return nil }
        let code = UInt16(bytes[8]) << 8 | UInt16(bytes[9])
        manufacturer = String([10, 5, 0].map { shift in
            Character(UnicodeScalar(UInt8((code >> shift) & 0x1f) + 64))
        })

        var timing: (width: Int, height: Int, refresh: Double, interlaced: Bool)?
        var name: String?
        for offset in [54, 72, 90, 108] {
            let d = Array(bytes[offset..<(offset + 18)]) // swiftlint:disable:this identifier_name
            let pixelClock = Int(d[0]) | Int(d[1]) << 8 // in 10 kHz units; 0 means a text/other descriptor
            if pixelClock != 0 {
                guard timing == nil else { continue }
                let hActive = Int(d[2]) | Int(d[4] & 0xf0) << 4
                let hBlank = Int(d[3]) | Int(d[4] & 0x0f) << 8
                let vActive = Int(d[5]) | Int(d[7] & 0xf0) << 4
                let vBlank = Int(d[6]) | Int(d[7] & 0x0f) << 8
                let refresh = Double(pixelClock) * 10_000 / Double((hActive + hBlank) * (vActive + vBlank))
                timing = (hActive, vActive, refresh, d[17] & 0x80 != 0)
            } else if d[3] == 0xfc, name == nil {
                let text = d[5..<18].prefix { $0 != 0x0a }
                name = String(decoding: text, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            }
        }
        guard let timing else { return nil }
        self.name = name
        width = timing.width
        height = timing.height
        refreshHz = timing.refresh
        interlaced = timing.interlaced
    }
}

/// Readable vendor names for the PNP codes the catalog uses. Registry names are from the UEFI PNP ID
/// list (as mirrored in hwdata's pnp.ids); GLI, LTM and AOC are not in that list and are named after the
/// companies that ship them (GL.iNet's KVM, Lontium's bridge chips, AOC monitors). LTM shows as GLKVM,
/// not Lontium: Lontium makes the HDMI chip inside the GLKVM, and the entries carrying LTM are GL.iNet's
/// own presets, so GLKVM is the name a user recognizes. CHR is registered to christmann
/// informationstechnik, but the one entry using it names a Chrontel chip (CH7511B).
private let edidVendorNames: [String: String] = [
    "GLI": "GLKVM",
    "SEC": "Epson",
    "LTM": "GLKVM",
    "AOC": "AOC",
    "AUS": "ASUS",
    "AUO": "AUO",
    "VSC": "ViewSonic",
    "WAC": "Wacom",
    "CHR": "Chrontel",
]

/// The refresh as a label shows it: a whole number when it rounds to one at two decimals,
/// otherwise two decimals ("60", "59.95").
func edidRefreshText(_ hz: Double) -> String {
    let twoPlaces = String(format: "%.2f", hz)
    return twoPlaces.hasSuffix(".00") ? String(twoPlaces.dropLast(3)) : twoPlaces
}

@Suite("EDID labels")
struct EDIDLabelTests {
    /// What each entry's blob decodes to, written down so a changed blob (or decoder) shows up here
    /// as well as in the frozen hashes.
    private let decoded: [String: (code: String, name: String?, width: Int, height: Int, refresh: String)] = [
        "E2560x1440": ("GLI", "GLKVM", 2560, 1440, "59.95"),
        "E3840x2160": ("LTM", "Lontium semi", 3840, 2160, "30"),
        "E1920x1080": ("AUS", "ROG PG248Q", 1920, 1080, "60"),
        "E1920x1200": ("SEC", "EPSON PJ", 1920, 1200, "59.95"),
        "E1920x1280": ("AUO", nil, 1920, 1280, "59.98"),
        "E2560x1440VS": ("VSC", "VX2478-2", 2560, 1440, "59.95"),
        "E1600x1200": ("WAC", "Cintiq21UX", 1600, 1200, "60"),
        "E2560x1664AOC": ("AOC", "GLKVM", 2560, 1664, "49.95"),
        "E2560x1600LTM": ("LTM", "ASUS", 2560, 1600, "50"),
        "E3440x1440AOC": ("AOC", "AG352UCG", 3440, 1440, "49.99"),
        "E2560x1080AOC": ("AOC", "2963", 2560, 1080, "59.98"),
        "E1024x768AOC": ("AOC", "LM522", 1024, 768, "60"),
        "E800x600CHR": ("CHR", "CH7511B", 800, 600, "59.86"),
    ]

    @Test func everyBlobDecodesToTheRecordedFacts() throws {
        let withBlobs = EDIDCatalog.options.filter { $0.edid != nil }
        #expect(Set(withBlobs.map(\.id)) == Set(decoded.keys))
        for option in withBlobs {
            let edid = try #require(DecodedEDID(edidBytes(option.edid ?? "")), "\(option.id) has no detailed timing")
            let want = try #require(decoded[option.id], "\(option.id) is not recorded")
            #expect(edid.manufacturer == want.code, "\(option.id)")
            #expect(edid.name == want.name, "\(option.id)")
            #expect(edid.width == want.width && edid.height == want.height, "\(option.id)")
            #expect(edidRefreshText(edid.refreshHz) == want.refresh, "\(option.id)")
            #expect(!edid.interlaced, "\(option.id)")
        }
    }

    /// Every label is `WxH/Vendor/RefreshHz` from the entry's own EDID: the preferred timing's size
    /// and refresh, and the vendor named for the manufacturer code.
    @Test func everyLabelMatchesItsEDID() throws {
        for option in EDIDCatalog.options {
            guard let blob = option.edid else {
                #expect(option.label == "Custom", "\(option.id)")
                continue
            }
            let edid = try #require(DecodedEDID(edidBytes(blob)), "\(option.id)")
            let vendor = try #require(edidVendorNames[edid.manufacturer], "\(option.id): no vendor name for \(edid.manufacturer)")
            let expected = "\(edid.width)x\(edid.height)/\(vendor)/\(edidRefreshText(edid.refreshHz))Hz"
            #expect(option.label == expected, "\(option.id)")
        }
    }

    @Test func labelsAreUnique() {
        let labels = EDIDCatalog.options.map(\.label)
        #expect(Set(labels).count == labels.count)
    }

    @Test func refreshTextRoundsToTwoPlacesAndDropsAWholeNumbersDecimals() {
        #expect(edidRefreshText(60.0) == "60")
        #expect(edidRefreshText(60.0038) == "60")
        #expect(edidRefreshText(49.996) == "50")
        #expect(edidRefreshText(49.9868) == "49.99")
        #expect(edidRefreshText(59.9506) == "59.95")
        #expect(edidRefreshText(30) == "30")
    }

    @Test func theDecoderReadsAHandBuiltBaseBlock() throws {
        var block = [UInt8](repeating: 0, count: 128)
        block.replaceSubrange(0..<8, with: [0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00])
        block[8] = 0x1e // "GSM": G=7, S=19, M=13 in three 5-bit fields
        block[9] = 0x6d
        // 1920x1080, 148.5 MHz, totals 2200x1125: exactly 60 Hz.
        block.replaceSubrange(54..<72, with: [0x02, 0x3a, 0x80, 0x18, 0x71, 0x38, 0x2d, 0x40, 0x58, 0x2c,
                                              0x45, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x1e])
        block.replaceSubrange(72..<90, with: [0x00, 0x00, 0x00, 0xfc, 0x00] + Array("TEST NAME\n   ".utf8))
        let edid = try #require(DecodedEDID(block))
        #expect(edid.manufacturer == "GSM")
        #expect(edid.name == "TEST NAME")
        #expect(edid.width == 1920 && edid.height == 1080)
        #expect(abs(edid.refreshHz - 60) < 1e-9)
        #expect(!edid.interlaced)
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
