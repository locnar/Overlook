import Foundation
import QuartzCore
#if canImport(WebRTC)
@preconcurrency import WebRTC
#endif

/// When a connection's frames arrive: the last one's time (what freeze detection reads), the frame
/// rate the stats panel shows, and when a frame was last kept for OCR.
///
/// Frames are counted on libwebrtc's decoder thread and the counts are read and reset on the main
/// actor, hence the lock. The counts belong to one connection, named by its generation: a frame
/// from any other connection's track, such as one still in flight from a track a teardown has
/// let go of, is not counted, so it can neither refresh the next connection's last-frame time
/// (hiding a freeze) nor feed its frame rate.
final class VideoFrameMeter: @unchecked Sendable {
    /// What one counted frame calls for.
    struct Tick: Equatable {
        /// A frame rate to publish, about every half second.
        var fps: Int?
        /// Whether to keep this frame for OCR (at most 12 a second, and only while asked for).
        var keepsFrame: Bool
    }

    static let fpsPublishInterval: CFTimeInterval = 0.5
    static let keptFrameInterval: CFTimeInterval = 1.0 / 12.0

    private let lock = NSLock()
    private var generation = 0
    private var lastFrame: CFTimeInterval?
    private var fpsWindowStart: CFTimeInterval = 0
    private var fpsFrameCount = 0
    private var lastFpsPublish: CFTimeInterval = 0
    private var keepsFrames = false
    private var lastKeptFrame: CFTimeInterval = 0

    /// When the current connection's last frame arrived, or nil before its first.
    var lastFrameTime: CFTimeInterval? {
        lock.withLock { lastFrame }
    }

    /// Counts from nothing for `generation`'s frames; frames from every other generation are
    /// ignored from now on.
    func reset(generation: Int) {
        lock.withLock {
            self.generation = generation
            lastFrame = nil
            fpsWindowStart = 0
            fpsFrameCount = 0
            lastFpsPublish = 0
            lastKeptFrame = 0
        }
    }

    /// Whether frames are kept for OCR. Left alone by `reset`: the setting outlives a reconnect.
    func setKeepsFrames(_ keeps: Bool) {
        lock.withLock { keepsFrames = keeps }
    }

    /// Counts a frame from `generation`'s track that arrived at `now`; nil, and nothing counted,
    /// when that connection is no longer the current one.
    func record(at now: CFTimeInterval, generation: Int) -> Tick? {
        lock.withLock {
            guard generation == self.generation else { return nil }
            lastFrame = now
            if fpsWindowStart == 0 {
                fpsWindowStart = now
                lastFpsPublish = now
            }
            fpsFrameCount += 1

            var tick = Tick(fps: nil, keepsFrame: false)
            if now - lastFpsPublish >= Self.fpsPublishInterval {
                let elapsed = now - fpsWindowStart
                if elapsed > 0 {
                    tick.fps = Int((Double(fpsFrameCount) / elapsed).rounded())
                }
                fpsWindowStart = now
                fpsFrameCount = 0
                lastFpsPublish = now
            }
            if keepsFrames, now - lastKeptFrame >= Self.keptFrameInterval {
                lastKeptFrame = now
                tick.keepsFrame = true
            }
            return tick
        }
    }
}

#if canImport(WebRTC)
/// What the manager hangs renderers on: an `RTCVideoTrack` in the app, and in tests a stand-in
/// that records them (a real track can only be made by a peer connection factory, and does not
/// say which renderers it has).
protocol VideoRendererHost: AnyObject {
    func add(_ renderer: RTCVideoRenderer)
    func remove(_ renderer: RTCVideoRenderer)
}

extension RTCVideoTrack: VideoRendererHost {}

/// The manager's renderer on one connection's video track, in place of the manager itself, so
/// the track can be let go of cleanly.
///
/// The manager used to add itself to each track and never take itself off, so an old track kept
/// delivering frames into it after a teardown. Each track now gets a relay of its own, made for
/// the connection the track belongs to. `retire()` stops it: it waits for a frame being handed on
/// at that moment, so once it returns nothing from this track reaches the manager.
final class VideoFrameRelay: NSObject, RTCVideoRenderer, @unchecked Sendable {
    private let lock = NSLock()
    private var isRetired = false
    private let onFrame: @Sendable (RTCVideoFrame) -> Void
    private let onSize: @Sendable (CGSize) -> Void

    /// `onFrame` and `onSize` are called on libwebrtc's decoder thread.
    init(onFrame: @escaping @Sendable (RTCVideoFrame) -> Void, onSize: @escaping @Sendable (CGSize) -> Void) {
        self.onFrame = onFrame
        self.onSize = onSize
        super.init()
    }

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !isRetired else { return }
        onFrame(frame)
    }

    func setSize(_ size: CGSize) {
        lock.lock()
        defer { lock.unlock() }
        guard !isRetired else { return }
        onSize(size)
    }

    func retire() {
        lock.withLock { isRetired = true }
    }
}
#endif
