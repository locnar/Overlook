import Foundation
import Testing
@testable import Overlook

/// One preset and what applying it must send and store. The numbers are written out here, from
/// the KVM web UI (firmware 1.10.0), rather than read from `QualityPreset`, so a change there
/// fails a test.
struct PresetCase: Sendable, CustomTestStringConvertible {
    let tag: Int
    let is4K: Bool
    let bitrate: String
    let gop: String

    var params: [String: String] { ["h264_bitrate": bitrate, "h264_gop": gop] }
    var testDescription: String { "preset \(tag)\(is4K ? " on 4K" : "")" }

    static let normal: [PresetCase] = [
        PresetCase(tag: 0, is4K: false, bitrate: "500", gop: "30"),
        PresetCase(tag: 1, is4K: false, bitrate: "2000", gop: "30"),
        PresetCase(tag: 2, is4K: false, bitrate: "5000", gop: "60"),
        PresetCase(tag: 3, is4K: false, bitrate: "8000", gop: "60"),
        PresetCase(tag: 4, is4K: false, bitrate: "20000", gop: "60"),
    ]

    static let fourK: [PresetCase] = [
        PresetCase(tag: 0, is4K: true, bitrate: "500", gop: "15"),
        PresetCase(tag: 1, is4K: true, bitrate: "2000", gop: "15"),
        PresetCase(tag: 2, is4K: true, bitrate: "5000", gop: "30"),
        PresetCase(tag: 3, is4K: true, bitrate: "8000", gop: "30"),
        PresetCase(tag: 4, is4K: true, bitrate: "20000", gop: "30"),
    ]

    static let all = normal + fourK
}

@Suite("Quality presets")
struct QualityPresetTests {
    @Test func thePresetsAreTheWebUIsWithoutAuto() {
        #expect(QualityPreset.allCases.map(\.rawValue) == [0, 1, 2, 3, 4])
        #expect(QualityPreset.allCases.map(\.label) == ["Low", "Medium", "High", "Ultra-high", "Lossless"])
        #expect(QualityPreset(rawValue: 5) == nil)
        #expect(WebUISettingsPanelModel.videoQualityLosslessTag == 4)
    }

    @Test(arguments: PresetCase.all)
    func eachPresetSendsTheWebUIsParams(_ preset: PresetCase) throws {
        let quality = try #require(QualityPreset(rawValue: preset.tag))
        #expect(QualityPreset.params(for: quality, is4K: preset.is4K) == preset.params)
        #expect(quality.streamQuality == preset.tag)
    }

    @Test(arguments: [false, true])
    func losslessSendsNoQualityParam(is4K: Bool) {
        let params = QualityPreset.params(for: .lossless, is4K: is4K)
        #expect(params["quality"] == nil)
        #expect(Set(params.keys) == ["h264_bitrate", "h264_gop"])
    }

    @Test func the4KEDIDsAreTheWebUIs() {
        #expect(QualityPreset.is4K(edidCatalogID: "E3840x2160"))
        #expect(QualityPreset.is4K(edidCatalogID: "E3840x2160RM4PE"))
        #expect(!QualityPreset.is4K(edidCatalogID: "E1920x1080"))
        #expect(!QualityPreset.is4K(edidCatalogID: "E2560x1440"))
        #expect(!QualityPreset.is4K(edidCatalogID: EDIDCatalog.customOptionID))
        #expect(!QualityPreset.is4K(edidCatalogID: nil))
    }

    @Test func the4KIDIsInTheCatalog() {
        #expect(EDIDCatalog.resolvedEdid(forID: "E3840x2160") != nil)
    }

    @Test(arguments: 0...4)
    func aStoredPresetShowsThatPreset(_ streamQuality: Int) {
        #expect(WebUISettingsActions.videoQualityPresetTag(forStreamQuality: streamQuality) == streamQuality)
    }

    @Test(arguments: [5, 6, -1, 42])
    func anyOtherStoredValueShowsCustom(_ streamQuality: Int) {
        #expect(WebUISettingsActions.videoQualityPresetTag(forStreamQuality: streamQuality) == WebUISettingsPanelModel.videoQualityCustomTag)
    }

    @Test func noStoredValueShowsCustom() {
        #expect(WebUISettingsActions.videoQualityPresetTag(forStreamQuality: nil) == WebUISettingsPanelModel.videoQualityCustomTag)
    }

    /// A missing value, or one that is not a whole number, reads as none rather than as Medium.
    @Test(arguments: [nil, JSONValue.string("medium"), .string("1"), .double(2.5), .bool(true), .null])
    func aMissingOrUnreadableValueDecodesAsNone(_ stored: JSONValue?) throws {
        var file: GLKVMJSONObject = ["theme_mode": .string("0")]
        if let stored {
            file["stream_quality"] = stored
        }
        let config = try JSONDecoder().decode(GLKVMSystemConfig.self, from: JSONEncoder().encode(file))
        #expect(config.streamQuality == nil)
        // And is not written back as anything.
        #expect(try config.jsonObject()["stream_quality"] == nil)
    }

    @Test func aWholeNumberDecodesAsItself() throws {
        let file: GLKVMJSONObject = ["stream_quality": .int(3)]
        let config = try JSONDecoder().decode(GLKVMSystemConfig.self, from: JSONEncoder().encode(file))
        #expect(config.streamQuality == 3)
    }
}

/// A device for the settings panel: the user config, a streamer that reports `streamerParams`,
/// and an EDID; `set_params` is recorded and answered with nothing.
private func qualityPresetDevice(config: FakeUserConfig, edid: String = "", streamerParams: JSONValue = .object([:])) -> StubDevice {
    StubDevice { request in
        switch request.path {
        case "/api/streamer/set_params":
            return .ok()
        case "/api/streamer":
            return .ok(.object(["params": streamerParams]))
        case "/api/upgrade/get_edid":
            return .ok(.string(edid))
        case "/api/hid/keymaps":
            return .ok(.object(["keymaps": .object([
                "default": .string("en-us"),
                "available": .array([.string("en-us")]),
            ])]))
        case "/api/hid":
            return .ok(.object([:]))
        default:
            return try await config.handle(request)
        }
    }
}

private let fourKEdid = EDIDCatalog.resolvedEdid(forID: "E3840x2160")!
private let fullHDEdid = EDIDCatalog.resolvedEdid(forID: "E1920x1080")!

@MainActor
@Suite("Quality presets on the device")
struct QualityPresetApplyTests {
    let config = FakeUserConfig([
        "stream_quality": .int(1),
        "language": .string("de"),
    ])

    private func makeFixture(edid: String = "", streamerParams: JSONValue = .object([:])) throws -> SettingsPanelFixture {
        let device = qualityPresetDevice(config: config, edid: edid, streamerParams: streamerParams)
        return try SettingsPanelFixture(device: device, config: config.stored)
    }

    private func setParamsQueries(_ fixture: SettingsPanelFixture) -> [[String: String]] {
        fixture.device.requests(to: "/api/streamer/set_params").map(\.query)
    }

    @Test(arguments: PresetCase.all)
    func applyingAPresetSendsItsParamsAndStoresItsValue(_ preset: PresetCase) async throws {
        let fixture = try makeFixture()
        fixture.model.currentEdid = preset.is4K ? fourKEdid : ""

        await fixture.actions.applyVideoQualityPreset(preset.tag)

        #expect(setParamsQueries(fixture) == [preset.params])
        #expect(fixture.model.config?.streamQuality == preset.tag)
        #expect(await waitUntil { config.stored["stream_quality"] == .int(preset.tag) && !fixture.model.isApplying })
        #expect(config.stored["language"] == .string("de"))
        #expect(fixture.model.errorHistory.isEmpty)
    }

    @Test(arguments: [false, true])
    func losslessSendsNoQualityParam(is4K: Bool) async throws {
        let fixture = try makeFixture()
        fixture.model.currentEdid = is4K ? fourKEdid : ""

        await fixture.actions.applyVideoQualityPreset(WebUISettingsPanelModel.videoQualityLosslessTag)

        let queries = setParamsQueries(fixture)
        #expect(queries.count == 1)
        #expect(queries.first?["quality"] == nil)
        #expect(queries.first?["h264_bitrate"] == "20000")
        #expect(fixture.model.config?.streamQuality == 4)
    }

    @Test func anotherEDIDSendsTheNormalGOP() async throws {
        let fixture = try makeFixture()
        fixture.model.currentEdid = fullHDEdid
        #expect(fixture.actions.currentEdidCatalogID == "E1920x1080")
        #expect(!fixture.actions.isCurrentEdid4K)

        await fixture.actions.applyVideoQualityPreset(QualityPreset.high.rawValue)

        #expect(setParamsQueries(fixture) == [["h264_bitrate": "5000", "h264_gop": "60"]])
    }

    @Test func the4KCheckFollowsTheCurrentEDID() throws {
        let fixture = try makeFixture()
        let actions = fixture.actions

        // Not loaded yet: not 4K.
        fixture.model.currentEdid = ""
        #expect(actions.currentEdidCatalogID == nil)
        #expect(!actions.isCurrentEdid4K)

        fixture.model.currentEdid = fourKEdid
        #expect(actions.currentEdidCatalogID == "E3840x2160")
        #expect(actions.isCurrentEdid4K)

        fixture.model.currentEdid = fullHDEdid
        #expect(!actions.isCurrentEdid4K)

        // Bytes that match no catalog entry: not 4K.
        fixture.model.currentEdid = "00 ff ff ff ff ff ff 00 12 34"
        #expect(actions.currentEdidCatalogID == nil)
        #expect(!actions.isCurrentEdid4K)
    }

    @Test func the4KCheckIgnoresAnEDIDPickedButNotYetApplied() async throws {
        // The picker's selection moves before the device takes the EDID; the GOP follows the
        // EDID the device last reported.
        let fixture = try makeFixture()
        fixture.model.currentEdid = fullHDEdid
        fixture.model.selectedEdidOption = "E3840x2160"

        await fixture.actions.applyVideoQualityPreset(QualityPreset.medium.rawValue)

        #expect(setParamsQueries(fixture) == [["h264_bitrate": "2000", "h264_gop": "30"]])
    }

    @Test func autoAndCustomSendNothing() async throws {
        let fixture = try makeFixture()

        await fixture.actions.applyVideoQualityPreset(5)
        await fixture.actions.applyVideoQualityPreset(WebUISettingsPanelModel.videoQualityCustomTag)

        #expect(setParamsQueries(fixture).isEmpty)
        #expect(fixture.model.config?.streamQuality == 1)
        #expect(fixture.device.requests(to: "/api/system/set_config").isEmpty)
    }

    // MARK: - Loading

    @Test(arguments: 0...4)
    func loadingAStoredPresetSelectsIt(_ streamQuality: Int) async throws {
        config.stored["stream_quality"] = .int(streamQuality)
        let fixture = try makeFixture()
        fixture.model.selectedVideoQualityPreset = WebUISettingsPanelModel.videoQualityCustomTag

        await fixture.actions.load()

        #expect(fixture.model.selectedVideoQualityPreset == streamQuality)
        #expect(fixture.model.errorHistory.isEmpty)
    }

    @Test func loadingAutoSelectsCustomAndSendsNothing() async throws {
        config.stored["stream_quality"] = .int(5)
        let fixture = try makeFixture(streamerParams: .object(["h264_bitrate": .int(0)]))

        await fixture.actions.load()

        #expect(fixture.model.selectedVideoQualityPreset == WebUISettingsPanelModel.videoQualityCustomTag)
        #expect(fixture.model.errorHistory.isEmpty)
        // Nothing is sent to the streamer, and above all no zero bitrate.
        #expect(setParamsQueries(fixture).isEmpty)
        #expect(!fixture.device.requests.contains { $0.query["h264_bitrate"] == "0" })
        #expect(config.stored["stream_quality"] == .int(5))
    }

    @Test(arguments: [6, -1, 42])
    func loadingAnyOtherValueSelectsCustom(_ streamQuality: Int) async throws {
        config.stored["stream_quality"] = .int(streamQuality)
        let fixture = try makeFixture()

        await fixture.actions.load()

        #expect(fixture.model.selectedVideoQualityPreset == WebUISettingsPanelModel.videoQualityCustomTag)
    }

    @Test(arguments: [nil, JSONValue.string("medium"), .double(2.5)])
    func loadingAMissingOrUnreadableValueSelectsCustom(_ stored: JSONValue?) async throws {
        config.stored["stream_quality"] = stored
        let fixture = try makeFixture()
        fixture.model.selectedVideoQualityPreset = QualityPreset.medium.rawValue

        await fixture.actions.load()

        #expect(fixture.model.selectedVideoQualityPreset == WebUISettingsPanelModel.videoQualityCustomTag)
        #expect(fixture.model.errorHistory.isEmpty)
        #expect(setParamsQueries(fixture).isEmpty)
        #expect(fixture.device.requests(to: "/api/system/set_config").isEmpty)
    }

    @Test(arguments: [nil, JSONValue.string("medium"), .double(2.5)])
    func anotherSettingsWriteKeepsTheDevicesValue(_ stored: JSONValue?) async throws {
        config.stored["stream_quality"] = stored
        let fixture = try makeFixture()
        await fixture.actions.load()

        fixture.actions.updateConfig { $0.themeMode = "1" }

        #expect(await waitUntil { config.stored["theme_mode"] == .string("1") && !fixture.model.isApplying })
        #expect(config.stored["stream_quality"] == stored)
        #expect(config.stored["language"] == .string("de"))
    }

    @Test(arguments: [nil, JSONValue.string("medium")])
    func pickingAPresetReplacesAMissingOrUnreadableValue(_ stored: JSONValue?) async throws {
        config.stored["stream_quality"] = stored
        let fixture = try makeFixture()
        await fixture.actions.load()

        // Medium, which an unreadable value used to be shown as, and so was never written.
        await fixture.actions.applyVideoQualityPreset(QualityPreset.medium.rawValue)

        #expect(await waitUntil { config.stored["stream_quality"] == .int(1) && !fixture.model.isApplying })
        #expect(fixture.model.config?.streamQuality == 1)
    }

    @Test func streamerParamsNoLongerPickThePreset() async throws {
        // What Overlook's earlier 20000 kbit/s preset left on a device: stream_quality 3, with
        // 20000/60/quality 100 in the streamer. The stored value decides: Ultra-high.
        config.stored["stream_quality"] = .int(3)
        let fixture = try makeFixture(streamerParams: .object([
            "h264_bitrate": .int(20000),
            "h264_gop": .int(60),
            "quality": .int(100),
        ]))

        await fixture.actions.load()

        #expect(fixture.model.selectedVideoQualityPreset == QualityPreset.ultraHigh.rawValue)
    }

    @Test func aPresetAppliedAfterLoadingA4KEDIDHalvesTheGOP() async throws {
        config.stored["stream_quality"] = .int(2)
        let fixture = try makeFixture(edid: fourKEdid)

        await fixture.actions.load()
        #expect(fixture.model.selectedEdidOption == "E3840x2160")

        await fixture.actions.applyVideoQualityPreset(WebUISettingsPanelModel.videoQualityLosslessTag)

        #expect(setParamsQueries(fixture) == [["h264_bitrate": "20000", "h264_gop": "30"]])
        #expect(await waitUntil { config.stored["stream_quality"] == .int(4) && !fixture.model.isApplying })
    }
}
