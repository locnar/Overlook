import Foundation
import Testing
@testable import Overlook

/// Statistics polling ticks, run on reports made here rather than read from a peer connection:
/// a tick whose reports come back after the connection was replaced must leave the new
/// connection's numbers alone, and a current tick's numbers must reach the panel.
@MainActor
@Suite("Stream stats")
struct StreamStatsTests {
    let scratch = ScratchDefaults()
    let manager: WebRTCManager

    init() {
        manager = WebRTCManager(
            audioPreferences: AudioPreferences(defaults: scratch.defaults),
            log: SessionLog(destination: .inMemory())
        )
    }

    /// Lets a report read wait until the test has done something in the middle of the tick.
    @MainActor
    final class HeldRead {
        let latch = Latch()
        private(set) var hasStarted = false

        func read(_ report: [String: StatsEntry]) async -> [String: StatsEntry] {
            hasStarted = true
            await latch.wait()
            return report
        }
    }

    private func video(bytes: Int64, packetsLost: Int) -> [String: StatsEntry] {
        ["IT01V": StatsEntry(type: "inbound-rtp", values: [
            "kind": "video",
            "bytesReceived": NSNumber(value: bytes),
            "packetsLost": NSNumber(value: packetsLost),
        ])]
    }

    private func audio(bytes: Int64, packetsLost: Int) -> [String: StatsEntry] {
        ["IT01A": StatsEntry(type: "inbound-rtp", values: [
            "kind": "audio",
            "bytesReceived": NSNumber(value: bytes),
            "packetsLost": NSNumber(value: packetsLost),
        ])]
    }

    private var snapshot: StreamTelemetry { manager.telemetry.snapshot }

    @Test func aCurrentTicksNumbersReachThePanel() async throws {
        await manager.measureStreamStats(
            readVideo: { video(bytes: 0, packetsLost: 2) },
            readAudio: { audio(bytes: 0, packetsLost: 1) }
        )
        #expect(snapshot.videoPacketsLost == 2)
        #expect(snapshot.audioPacketsLost == 1)
        // The first tick has nothing to compare with.
        #expect(snapshot.videoKbps == nil)

        try await Task.sleep(for: .milliseconds(100))
        await manager.measureStreamStats(
            readVideo: { video(bytes: 125_000, packetsLost: 3) },
            readAudio: { audio(bytes: 4_000, packetsLost: 1) }
        )
        #expect(snapshot.videoPacketsLost == 3)
        #expect((snapshot.videoKbps ?? 0) > 0)
        #expect((snapshot.audioKbps ?? 0) > 0)
    }

    @Test func aVideoReportFromBeforeAReconnectIsDropped() async throws {
        // The bug this guards: the old peer's report came back after the teardown and became the
        // new connection's baseline and numbers.
        let held = HeldRead()
        let staleTick = Task {
            await manager.measureStreamStats(
                readVideo: { await held.read(video(bytes: 1_000, packetsLost: 99)) },
                readAudio: nil
            )
        }
        #expect(await waitUntil { held.hasStarted })

        manager.disconnect()  // the teardown every reconnect starts with
        await held.latch.open()
        await staleTick.value

        #expect(snapshot.videoPacketsLost == nil)

        // The new connection's first tick. Had the old report been kept as the baseline, this
        // would compare 5 MB with 1 kB and show a burst of tens of thousands of kbps.
        await manager.measureStreamStats(readVideo: { video(bytes: 5_000_000, packetsLost: 3) }, readAudio: nil)
        #expect(snapshot.videoPacketsLost == 3)
        #expect(snapshot.videoKbps == nil)
    }

    @Test func aTeardownDuringTheAudioReadDropsTheWholeTick() async throws {
        // The second of the tick's two reads: the video report is already in, and must not be
        // applied either.
        let held = HeldRead()
        let staleTick = Task {
            await manager.measureStreamStats(
                readVideo: { video(bytes: 1_000, packetsLost: 99) },
                readAudio: { await held.read(audio(bytes: 1_000, packetsLost: 98)) }
            )
        }
        #expect(await waitUntil { held.hasStarted })

        manager.disconnect()
        await held.latch.open()
        await staleTick.value

        #expect(snapshot.videoPacketsLost == nil)
        #expect(snapshot.audioPacketsLost == nil)

        await manager.measureStreamStats(
            readVideo: { video(bytes: 5_000_000, packetsLost: 3) },
            readAudio: { audio(bytes: 900_000, packetsLost: 4) }
        )
        #expect(snapshot.videoPacketsLost == 3)
        #expect(snapshot.audioPacketsLost == 4)
        #expect(snapshot.videoKbps == nil)
        #expect(snapshot.audioKbps == nil)
    }
}

/// Two ticks of one connection whose reads overlap: the one that started first and finished last
/// is dropped, not applied over the newer numbers.
@MainActor
@Suite("Stream stats tick order")
struct StreamStatsTickOrderTests {
    let scratch = ScratchDefaults()
    let manager: WebRTCManager

    init() {
        manager = WebRTCManager(
            audioPreferences: AudioPreferences(defaults: scratch.defaults),
            log: SessionLog(destination: .inMemory())
        )
    }

    private func video(bytes: Int64, packetsLost: Int) -> [String: StatsEntry] {
        ["IT01V": StatsEntry(type: "inbound-rtp", values: [
            "kind": "video",
            "bytesReceived": NSNumber(value: bytes),
            "packetsLost": NSNumber(value: packetsLost),
        ])]
    }

    private var snapshot: StreamTelemetry { manager.telemetry.snapshot }

    @Test func aSlowTickOvertakenByTheNextIsDropped() async throws {
        let held = StreamStatsTests.HeldRead()
        // `statistics()` taking more than the 1 s interval: this tick is still reading when the
        // next one starts.
        let slowTick = Task {
            await manager.measureStreamStats(
                readVideo: { await held.read(video(bytes: 1_000, packetsLost: 7)) },
                readAudio: nil
            )
        }
        #expect(await waitUntil { held.hasStarted })

        await manager.measureStreamStats(readVideo: { video(bytes: 9_000_000, packetsLost: 8) }, readAudio: nil)
        #expect(snapshot.videoPacketsLost == 8)

        await held.latch.open()
        await slowTick.value
        #expect(snapshot.videoPacketsLost == 8, "the older numbers did not replace the newer")

        // The baseline is still the newer tick's: had the slow tick's 1 kB become it, this would
        // show a burst of tens of thousands of kbps.
        try await Task.sleep(for: .milliseconds(200))
        await manager.measureStreamStats(readVideo: { video(bytes: 9_025_000, packetsLost: 8) }, readAudio: nil)
        let kbps = try #require(snapshot.videoKbps)
        #expect(kbps < 10_000)
    }

    @Test func ticksThatFinishInOrderAreAllApplied() async {
        await manager.measureStreamStats(readVideo: { video(bytes: 0, packetsLost: 1) }, readAudio: nil)
        #expect(snapshot.videoPacketsLost == 1)
        await manager.measureStreamStats(readVideo: { video(bytes: 1_000, packetsLost: 2) }, readAudio: nil)
        #expect(snapshot.videoPacketsLost == 2)
    }
}
