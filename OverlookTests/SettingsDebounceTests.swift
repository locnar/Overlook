import Foundation
import Testing
@testable import Overlook

/// Settings changes are debounced: a burst of changes (stepper clicks, slider ticks) writes once,
/// with the last value, after the burst ends.
@MainActor
@Suite("Settings debounce")
struct SettingsDebounceTests {
    let config = FakeUserConfig(["theme_mode": .string("0"), "scroll_rate": .int(5)])
    let fixture: SettingsPanelFixture

    init() throws {
        fixture = try SettingsPanelFixture(device: StubDevice(config: config), config: config.stored)
    }

    private var device: StubDevice { fixture.device }
    private var model: WebUISettingsPanelModel { fixture.model }
    private var actions: WebUISettingsActions { fixture.actions }

    private var writes: [StubDevice.Request] {
        device.requests(to: "/api/system/set_config")
    }

    /// Longer than the debounce window and a stubbed write together.
    private func settle() async throws {
        try await Task.sleep(nanoseconds: 500_000_000)
    }

    @Test func aBurstOfChangesWritesOnceWithTheLastValue() async throws {
        for rate in 6...10 {
            actions.updateConfig { $0.scrollRate = rate }
        }

        #expect(await waitUntil { writes.count == 1 && !model.isApplying })
        try await settle()
        #expect(writes.count == 1)
        #expect(config.stored["scroll_rate"] == .int(10))
        #expect(model.errorHistory.isEmpty)
    }

    @Test func changesSpacedInsideTheWindowStillWriteOnce() async throws {
        for rate in 6...10 {
            actions.updateConfig { $0.scrollRate = rate }
            try await Task.sleep(nanoseconds: 40_000_000)
        }

        #expect(await waitUntil { writes.count == 1 && !model.isApplying })
        try await settle()
        #expect(writes.count == 1)
        #expect(config.stored["scroll_rate"] == .int(10))
    }

    @Test func aCancelledApplySendsNothing() async throws {
        actions.updateConfig { $0.scrollRate = 7 }
        model.applyTask?.cancel()

        try await settle()
        #expect(device.requests.isEmpty)
        #expect(model.errorHistory.isEmpty)
    }

    @Test func aChangeMadeWhileAWriteIsOnItsWayDoesNotCancelIt() async throws {
        let latch = Latch()
        config.writeLatch = latch

        actions.updateConfig { $0.scrollRate = 7 }
        #expect(await waitUntil { writes.count == 1 })
        // The first write is held open by the device; a second change now must leave it alone.
        actions.updateConfig { $0.themeMode = "1" }
        try await Task.sleep(nanoseconds: 300_000_000)
        await latch.open()

        #expect(await waitUntil { writes.count == 2 })
        try await settle()
        #expect(device.cancelledRequests.isEmpty)
        #expect(model.errorHistory.isEmpty)
        #expect(!model.isApplying)
        // Writes take turns, and each merges over a fresh read, so both changes are kept.
        #expect(config.stored["scroll_rate"] == .int(7))
        #expect(config.stored["theme_mode"] == .string("1"))
    }

    @Test func aBurstOfStreamerChangesSetsTheParamsOnce() async throws {
        device.setHandler { _ in .ok() }
        model.streamerState = try JSONDecoder().decode(GLKVMStreamerState.self, from: Data("{}".utf8))

        for bitrate in [3000, 4000, 5000, 6000] {
            model.streamerH264Bitrate = bitrate
            actions.scheduleStreamerApply()
        }

        let setParams = { device.requests(to: "/api/streamer/set_params") }
        #expect(await waitUntil { setParams().count == 1 && !model.isApplyingStreamer })
        try await Task.sleep(nanoseconds: 600_000_000)
        #expect(setParams().count == 1)
        #expect(setParams().first?.query["h264_bitrate"] == "6000")
    }
}
