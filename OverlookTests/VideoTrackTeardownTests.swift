import Foundation
import QuartzCore
import Testing
@testable import Overlook

/// Stands in for a connection's `RTCVideoTrack`, which only a peer connection factory can make
/// and which does not say which renderers it has. Records every renderer added and removed.
final class FakeVideoTrack: VideoRendererHost {
    private(set) var added: [RTCVideoRenderer] = []
    private(set) var removed: [RTCVideoRenderer] = []

    /// The renderers still on the track.
    var current: [RTCVideoRenderer] {
        added.filter { renderer in !removed.contains { $0 === renderer } }
    }

    /// The manager's relay among the renderers added.
    var relay: VideoFrameRelay? {
        added.lazy.compactMap { $0 as? VideoFrameRelay }.first
    }

    func add(_ renderer: RTCVideoRenderer) {
        added.append(renderer)
    }

    func remove(_ renderer: RTCVideoRenderer) {
        removed.append(renderer)
    }
}

private func makeFrame() -> RTCVideoFrame {
    RTCVideoFrame(buffer: RTCI420Buffer(width: 2, height: 2), rotation: ._0, timeStampNs: 0)
}

/// What the manager hangs on a connection's video track, and what a late frame from an old
/// track can still do. The track is a stand-in; frames are real `RTCVideoFrame`s delivered the
/// way libwebrtc delivers them, through the renderer the manager added.
@MainActor
@Suite("Video track teardown")
struct VideoTrackTeardownTests {
    let scratch = ScratchDefaults()
    let manager: WebRTCManager

    init() {
        manager = WebRTCManager(
            audioPreferences: AudioPreferences(defaults: scratch.defaults),
            log: SessionLog(destination: .inMemory())
        )
    }

    @Test func aTrackGetsTheVideoViewAndTheManagersRelay() throws {
        let track = FakeVideoTrack()
        manager.attachVideoTrack(track)

        #expect(track.current.count == 2)
        #expect(track.relay != nil)
        let view = try #require(manager.videoView)
        #expect(track.current.contains { $0 === view })
    }

    @Test func replacingTheTrackTakesEveryRendererOffTheOldOne() {
        let old = FakeVideoTrack()
        let new = FakeVideoTrack()
        manager.attachVideoTrack(old)
        let addedToOld = old.added

        manager.attachVideoTrack(new)

        #expect(old.current.isEmpty)
        #expect(old.removed.count == addedToOld.count)
        #expect(new.current.count == 2)
        #expect(new.relay !== old.relay)
    }

    @Test func aTeardownTakesEveryRendererOffTheTrack() {
        // The bug this guards: the manager and the video view stayed on the old track for good.
        let track = FakeVideoTrack()
        manager.attachVideoTrack(track)

        manager.disconnect()

        #expect(track.current.isEmpty)
        #expect(track.removed.count == 2)
    }

    @Test func aFrameFromTheOldTrackDoesNotCountForTheNextConnection() throws {
        let old = FakeVideoTrack()
        manager.attachVideoTrack(old)
        let oldRelay = try #require(old.relay)
        oldRelay.renderFrame(makeFrame())
        #expect(manager.lastVideoFrameTimestamp != nil)
        #expect(manager.captureHub.latestFrame != nil)

        manager.disconnect()
        #expect(manager.lastVideoFrameTimestamp == nil)

        let new = FakeVideoTrack()
        manager.attachVideoTrack(new)  // the next connection's track
        oldRelay.renderFrame(makeFrame())
        oldRelay.setSize(CGSize(width: 1920, height: 1080))

        #expect(manager.lastVideoFrameTimestamp == nil)
        #expect(manager.captureHub.latestFrame == nil)

        let newRelay = try #require(new.relay)
        newRelay.renderFrame(makeFrame())
        #expect(manager.lastVideoFrameTimestamp != nil)
    }

    @Test func aFrameRateFromBeforeATeardownIsNotPublishedAfterIt() async throws {
        // A frame handled just before the teardown queues its frame rate for the main actor; that
        // work runs after the teardown has cleared the stats.
        let track = FakeVideoTrack()
        manager.attachVideoTrack(track)
        let relay = try #require(track.relay)
        relay.renderFrame(makeFrame())
        try await Task.sleep(for: .milliseconds(550))
        relay.renderFrame(makeFrame())  // a rate is due: queued for the main actor
        manager.disconnect()            // before the main actor gets to it

        try await Task.sleep(for: .milliseconds(100))
        #expect(manager.telemetry.snapshot.videoFps == nil)
    }

    @Test func aCurrentTracksFrameRateIsPublished() async throws {
        let track = FakeVideoTrack()
        manager.attachVideoTrack(track)
        let relay = try #require(track.relay)
        relay.renderFrame(makeFrame())
        try await Task.sleep(for: .milliseconds(550))
        relay.renderFrame(makeFrame())

        #expect(await waitUntil { manager.telemetry.snapshot.videoFps != nil })
    }

    @Test func theSizeOfACurrentTracksVideoIsPublished() async throws {
        let track = FakeVideoTrack()
        manager.attachVideoTrack(track)
        try #require(track.relay).setSize(CGSize(width: 1280, height: 720))
        #expect(await waitUntil { manager.videoSize == CGSize(width: 1280, height: 720) })
    }
}

/// Frame arrivals, counted for one connection at a time.
@Suite("Video frame meter")
struct VideoFrameMeterTests {
    @Test func aFrameFromAnotherConnectionIsNotCounted() {
        let meter = VideoFrameMeter()
        meter.reset(generation: 1)
        #expect(meter.record(at: 10, generation: 1) != nil)
        #expect(meter.lastFrameTime == 10)

        meter.reset(generation: 2)
        #expect(meter.lastFrameTime == nil)
        // In flight from connection 1's track when connection 2 took over.
        #expect(meter.record(at: 11, generation: 1) == nil)
        #expect(meter.lastFrameTime == nil)

        #expect(meter.record(at: 12, generation: 2) != nil)
        #expect(meter.lastFrameTime == 12)
    }

    @Test func theFrameRateIsPublishedAboutEveryHalfSecond() {
        let meter = VideoFrameMeter()
        meter.reset(generation: 1)
        var published: [Int] = []
        for index in 0...30 {
            let tick = meter.record(at: 100 + Double(index) / 30, generation: 1)
            if let fps = tick?.fps { published.append(fps) }
        }
        // 31 frames at 30 fps over one second: a rate at 0.5 s and at 1.0 s.
        #expect(published.count == 2)
        #expect(published.allSatisfy { (28...32).contains($0) })
    }

    @Test func framesAreKeptOnlyWhenAskedAndAtMostTwelveASecond() {
        let meter = VideoFrameMeter()
        meter.reset(generation: 1)
        #expect(meter.record(at: 1, generation: 1)?.keepsFrame == false)

        meter.setKeepsFrames(true)
        var kept = 0
        for index in 0..<60 {
            if meter.record(at: 2 + Double(index) / 60, generation: 1)?.keepsFrame == true { kept += 1 }
        }
        #expect((11...13).contains(kept))

        meter.reset(generation: 2)  // the setting outlives a reconnect
        #expect(meter.record(at: 5, generation: 2)?.keepsFrame == true)
    }
}
