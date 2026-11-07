import Foundation
import os
import Testing
@testable import Overlook

/// A config with keys Overlook models and keys it does not, in every JSON kind.
private let deviceConfig: GLKVMJSONObject = [
    "theme_mode": .string("0"),
    "scroll_rate": .int(5),
    "keymap": .string("en-us"),
    "is_absolute_mouse": .bool(true),
    // Kept as a string by this device; the model reads it as a number and falls back to 10.
    "relative_sense": .string("12"),
    // Not modeled.
    "language": .string("de"),
    "tab_title": .string("Lab rack"),
    "fec_packets": .int(20),
    "bitrate_scale": .double(0.75),
    "port_label": .string("8443"),
    "swap_cmd_ctrl": .bool(false),
    "beta_channel": .null,
    "recent_hosts": .array([.string("a"), .int(2), .bool(true), .null]),
    "video_layout": .object([
        "mode": .string("fit_screen"),
        "zoom": .double(1.5),
        "pinned": .array([.object(["id": .int(1)])]),
        "overlay": .object(["visible": .bool(false), "note": .null]),
    ]),
]

@Suite("Settings writes keep the device's config")
struct SystemConfigWriteTests {
    @Test func unknownKeysAndTheirTypesSurviveAWrite() async throws {
        let config = FakeUserConfig(deviceConfig)
        let device = StubDevice(config: config)
        let client = try device.makeClient()

        let written = try await client.updateSystemConfig(["theme_mode": .string("1")])

        var expected = deviceConfig
        expected["theme_mode"] = .string("1")
        #expect(config.stored == expected)
        #expect(written.themeMode == "1")
        // Read, then write; nothing else.
        #expect(device.requests.map(\.path) == ["/api/system/get_config", "/api/system/set_config"])
    }

    @Test func aWriteMergesOverAFreshReadNotAnEarlierOne() async throws {
        let config = FakeUserConfig(deviceConfig)
        let device = StubDevice(config: config)
        let client = try device.makeClient()

        _ = try await client.getSystemConfigObject()
        // The web UI changes the config after Overlook read it.
        var changedElsewhere = config.stored
        changedElsewhere["language"] = .string("fr")
        changedElsewhere["scroll_rate"] = .int(9)
        changedElsewhere["added_by_firmware"] = .bool(true)
        config.stored = changedElsewhere

        _ = try await client.updateSystemConfig(["theme_mode": .string("1")])

        #expect(config.stored["language"] == .string("fr"))
        #expect(config.stored["scroll_rate"] == .int(9))
        #expect(config.stored["added_by_firmware"] == .bool(true))
        #expect(config.stored["theme_mode"] == .string("1"))
        let paths = device.requests.map(\.path)
        #expect(paths.suffix(2) == ["/api/system/get_config", "/api/system/set_config"])
    }

    @Test func overlappingWritesTakeTurnsAndKeepBothChanges() async throws {
        let config = FakeUserConfig(deviceConfig)
        // Long enough that, without turns, both writes would read before either wrote.
        config.readDelay = .milliseconds(150)
        let device = StubDevice(config: config)
        let client = try device.makeClient()

        async let first = client.updateSystemConfig(["theme_mode": .string("1")])
        async let second = client.updateSystemConfig(["scroll_rate": .int(7)])
        _ = try await (first, second)

        #expect(config.stored["theme_mode"] == .string("1"))
        #expect(config.stored["scroll_rate"] == .int(7))
        #expect(config.stored["language"] == .string("de"))
        #expect(device.requests.map(\.path) == [
            "/api/system/get_config", "/api/system/set_config",
            "/api/system/get_config", "/api/system/set_config",
        ])
    }

    @Test func aFailedReadWritesNothing() async throws {
        let device = StubDevice { request in
            request.path == "/api/system/get_config" ? StubDevice.Response(status: 502, body: Data()) : .ok()
        }
        let client = try device.makeClient()

        await #expect(throws: GLKVMClient.ClientError.self) {
            _ = try await client.updateSystemConfig(["theme_mode": .string("1")])
        }
        #expect(device.requests(to: "/api/system/set_config").isEmpty)
    }

    @Test func aWriteAfterAFailedOneStillGoesThrough() async throws {
        let config = FakeUserConfig(deviceConfig)
        let failNextRead = OSAllocatedUnfairLock(initialState: true)
        let device = StubDevice { request in
            if request.path == "/api/system/get_config", failNextRead.withLock({ fail in
                defer { fail = false }
                return fail
            }) {
                return StubDevice.Response(status: 502, body: Data())
            }
            return try await config.handle(request)
        }
        let client = try device.makeClient()

        _ = try? await client.updateSystemConfig(["theme_mode": .string("1")])
        _ = try await client.updateSystemConfig(["scroll_rate": .int(3)])

        #expect(config.stored["scroll_rate"] == .int(3))
    }

    @Test func onlyChangedKeysCountAsChanges() throws {
        let data = try JSONEncoder().encode(deviceConfig)
        let loaded = try JSONDecoder().decode(GLKVMSystemConfig.self, from: data)
        var edited = loaded
        edited.themeMode = "1"
        edited.scrollRate = 8

        // Not relative_sense, which the model filled with a default, nor any other default.
        #expect(edited.changes(from: loaded) == ["theme_mode": .string("1"), "scroll_rate": .int(8)])
        #expect(loaded.changes(from: loaded).isEmpty)
    }
}

/// The settings panel's side: what a change in the panel sends.
@MainActor
@Suite("Settings panel writes")
struct SettingsPanelWriteTests {
    let config = FakeUserConfig(deviceConfig)
    let fixture: SettingsPanelFixture

    init() throws {
        fixture = try SettingsPanelFixture(device: StubDevice(config: config), config: deviceConfig)
    }

    private var device: StubDevice { fixture.device }
    private var model: WebUISettingsPanelModel { fixture.model }
    private var actions: WebUISettingsActions { fixture.actions }

    private var writes: [StubDevice.Request] {
        device.requests(to: "/api/system/set_config")
    }

    @Test func aChangeWritesThatKeyOverTheDevicesConfig() async {
        actions.updateConfig { $0.themeMode = "1" }

        #expect(await waitUntil { writes.count == 1 && !model.isApplying })
        var expected = deviceConfig
        expected["theme_mode"] = .string("1")
        #expect(config.stored == expected)
        // relative_sense is still the device's string, not the model's default number.
        #expect(config.stored["relative_sense"] == .string("12"))
        #expect(model.config?.themeMode == "1")
        #expect(model.errorHistory.isEmpty)
    }

    @Test func changesToDifferentKeysInOneWindowGoOutInOneWrite() async throws {
        actions.updateConfig { $0.themeMode = "1" }
        actions.updateConfig { $0.scrollRate = 9 }

        #expect(await waitUntil { writes.count == 1 && !model.isApplying })
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(writes.count == 1)
        #expect(config.stored["theme_mode"] == .string("1"))
        #expect(config.stored["scroll_rate"] == .int(9))
        #expect(config.stored["language"] == .string("de"))
    }

    @Test func aChangeMadeInTheWebUISinceThePanelLoadedIsKept() async {
        // The panel loaded the config earlier; since then the web UI changed scroll_rate.
        var changedElsewhere = config.stored
        changedElsewhere["scroll_rate"] = .int(2)
        config.stored = changedElsewhere

        actions.updateConfig { $0.themeMode = "1" }

        #expect(await waitUntil { writes.count == 1 && !model.isApplying })
        #expect(config.stored["scroll_rate"] == .int(2))
        #expect(config.stored["theme_mode"] == .string("1"))
    }

    @Test func aChangeThatChangesNothingWritesNothing() async throws {
        actions.updateConfig { $0.themeMode = "0" }

        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(device.requests.isEmpty)
    }

    @Test func aMouseModeChangeAlsoSwitchesTheGadget() async {
        actions.updateConfig { $0.isAbsoluteMouse = false }

        #expect(await waitUntil { !device.requests(to: "/api/hid/set_params").isEmpty && !model.isApplying })
        #expect(device.requests(to: "/api/hid/set_params").first?.query["mouse_output"] == "usb_rel")
        #expect(config.stored["is_absolute_mouse"] == .bool(false))
    }
}
