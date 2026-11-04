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

    @Test func everyOverrideReplacesARealEntry() {
        let ids = Set(EDIDCatalog.options.map(\.id))
        for id in EDIDCatalog.overrides.keys {
            #expect(ids.contains(id), "override for unknown id \(id)")
        }
    }

    @Test func resolvingPrefersTheOverride() throws {
        let option = try #require(EDIDCatalog.options.first { $0.id == "E3840x2160" })
        #expect(EDIDCatalog.resolvedEdid(for: option) == EDIDCatalog.overrides["E3840x2160"])
        #expect(EDIDCatalog.resolvedEdid(for: option) != option.edid)

        let plain = try #require(EDIDCatalog.options.first { $0.id == "E2560x1440" })
        #expect(EDIDCatalog.overrides["E2560x1440"] == nil)
        #expect(EDIDCatalog.resolvedEdid(forID: "E2560x1440") == plain.edid)
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
