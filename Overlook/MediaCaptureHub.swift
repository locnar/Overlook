import Foundation
import AudioToolbox
import CoreVideo
import QuartzCore
import os
#if canImport(WebRTC)
import WebRTC
#endif

/// Where the media pipeline hands decoded video and playout audio to the capture features.
///
/// `WebRTCManager.renderFrame` runs on libwebrtc's decoder thread and `WebRTCAudioDevice`'s
/// playout callback on the HAL output unit's real-time thread, while screenshots and recordings
/// start and stop on the main actor. This is the one object all three touch: it keeps the most
/// recent decoded frame (what a screenshot saves) and forwards frames and PCM to the active
/// `SessionRecorder`, if there is one. Nothing here blocks the media threads — the lock guards two
/// pointer swaps, and the recorder does its own work on its own queue.
final class MediaCaptureHub: @unchecked Sendable {
    private struct State {
        var latestFrame: RTCVideoFrame?
        var recorder: SessionRecorder?
    }

    // `uncheckedState`: the state holds an `RTCVideoFrame`, which is not Sendable.
    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    /// The most recently decoded frame, or nil before the first frame of a connection and after
    /// teardown (the video view goes black then too, so a screenshot has nothing to show).
    var latestFrame: RTCVideoFrame? {
        // `RTCVideoFrame` is not Sendable, so the checked `withLock` (which requires a Sendable
        // result) cannot hand it out; the frame is immutable once decoded, so this is safe.
        state.withLockUnchecked { $0.latestFrame }
    }

    /// Decoder thread. `hostTime` is `CACurrentMediaTime()` at delivery, the same clock the
    /// audio tap converts its `AudioTimeStamp.mHostTime` to.
    func handleVideoFrame(_ frame: RTCVideoFrame, hostTime: CFTimeInterval) {
        let recorder = state.withLockUnchecked { state -> SessionRecorder? in
            state.latestFrame = frame
            return state.recorder
        }
        recorder?.appendVideoFrame(frame, hostTime: hostTime)
    }

    /// HAL output unit's render thread, after WebRTC filled `bufferList` with what is about to be
    /// played: interleaved signed 16-bit PCM, `channels` per frame, `frameCount` frames.
    func handlePlayoutAudio(
        _ bufferList: UnsafePointer<AudioBufferList>,
        frameCount: UInt32,
        timestamp: UnsafePointer<AudioTimeStamp>,
        sampleRate: Double,
        channels: Int
    ) {
        guard let recorder = state.withLock({ $0.recorder }) else { return }
        recorder.appendPlayoutAudio(
            bufferList,
            frameCount: frameCount,
            timestamp: timestamp,
            sampleRate: sampleRate,
            channels: channels
        )
    }

    func setRecorder(_ recorder: SessionRecorder?) {
        state.withLock { $0.recorder = recorder }
    }

    func clearLatestFrame() {
        state.withLock { $0.latestFrame = nil }
    }
}

// MARK: - Host clock

/// Conversions onto the clock both media paths share: `CACurrentMediaTime()` is
/// `mach_absolute_time()` in seconds, and CoreAudio's `mHostTime` is `mach_absolute_time()` in ticks.
enum HostClock {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static var now: CFTimeInterval { CACurrentMediaTime() }

    static func seconds(fromHostTicks ticks: UInt64) -> CFTimeInterval {
        Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }

    /// The buffer's playout time in seconds on the shared clock, falling back to "now" when the
    /// HAL did not stamp it.
    static func seconds(from timestamp: AudioTimeStamp) -> CFTimeInterval {
        if timestamp.mFlags.contains(.hostTimeValid) {
            return seconds(fromHostTicks: timestamp.mHostTime)
        }
        return now
    }
}

// MARK: - Frame conversion

/// Turns a decoded `RTCVideoFrame` into a `CVPixelBuffer` the encoder and Core Image can consume.
///
/// H.264 (the device's stream) is decoded by VideoToolbox into an `RTCCVPixelBuffer`, whose
/// buffer is used as-is. Software-decoded codecs arrive as I420 planes and are copied into an
/// NV12 buffer, the layout every Apple encoder accepts.
enum VideoFrameConversion {
    static func pixelBuffer(for frame: RTCVideoFrame) -> CVPixelBuffer? {
        if let cvBuffer = frame.buffer as? RTCCVPixelBuffer, cvBuffer.requiresCropping() == false {
            return cvBuffer.pixelBuffer
        }
        return makeNV12PixelBuffer(from: frame.buffer.toI420())
    }

    /// `RTCI420BufferProtocol` is Swift's name for the ObjC `RTCI420Buffer` protocol (the concrete
    /// class of the same name keeps the plain name).
    static func makeNV12PixelBuffer(from i420: RTCI420BufferProtocol) -> CVPixelBuffer? {
        let width = Int(i420.width)
        let height = Int(i420.height)
        guard width > 0, height > 0 else { return nil }

        var created: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            attributes as CFDictionary,
            &created
        )
        guard status == kCVReturnSuccess, let pixelBuffer = created else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let yDestination = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              let uvDestination = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else {
            return nil
        }

        let yDestinationStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let ySourceStride = Int(i420.strideY)
        for row in 0..<height {
            memcpy(yDestination + row * yDestinationStride, i420.dataY + row * ySourceStride, width)
        }

        let chromaWidth = Int(i420.chromaWidth)
        let chromaHeight = Int(i420.chromaHeight)
        let uvDestinationStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        let uSourceStride = Int(i420.strideU)
        let vSourceStride = Int(i420.strideV)
        for row in 0..<chromaHeight {
            let destination = (uvDestination + row * uvDestinationStride).assumingMemoryBound(to: UInt8.self)
            let u = i420.dataU + row * uSourceStride
            let v = i420.dataV + row * vSourceStride
            for column in 0..<chromaWidth {
                destination[2 * column] = u[column]
                destination[2 * column + 1] = v[column]
            }
        }

        return pixelBuffer
    }
}
