import Foundation
import AudioToolbox
import CoreImage
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

// MARK: - Capture region

/// Where the capture region lands in a frame. The region is kept as fractions of the frame
/// (0…1, origin top-left) so a guest that changes resolution keeps the same part of its screen;
/// this turns it into pixels for one frame size: edges snapped to even coordinates (4:2:0 chroma
/// is shared between pixel pairs, and the encoders want even dimensions), at least `minimumSide`
/// on each side, and inside the frame.
enum CaptureRegionGeometry {
    static let minimumSide = 16

    static func pixelRect(for region: CGRect, in frameSize: CGSize) -> CGRect {
        let frameWidth = Int(frameSize.width) & ~1
        let frameHeight = Int(frameSize.height) & ~1
        guard frameWidth >= 2, frameHeight >= 2 else {
            return CGRect(origin: .zero, size: frameSize)
        }

        let clamped = region.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !clamped.isNull else {
            return CGRect(x: 0, y: 0, width: frameWidth, height: frameHeight)
        }

        func even(_ value: CGFloat) -> Int { Int(value.rounded()) & ~1 }
        let left = even(clamped.minX * CGFloat(frameWidth))
        let top = even(clamped.minY * CGFloat(frameHeight))
        let right = even(clamped.maxX * CGFloat(frameWidth))
        let bottom = even(clamped.maxY * CGFloat(frameHeight))

        let width = min(frameWidth, max(minimumSide, right - left))
        let height = min(frameHeight, max(minimumSide, bottom - top))
        let x = max(0, min(left, frameWidth - width))
        let y = max(0, min(top, frameHeight - height))
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// `1280 × 720`: the region's size in a frame of `frameSize`.
    static func sizeText(for region: CGRect, in frameSize: CGSize) -> String {
        let rect = pixelRect(for: region, in: frameSize)
        return "\(Int(rect.width)) × \(Int(rect.height))"
    }
}

/// Cuts the capture region out of decoded frames for a cropped recording.
///
/// Owned by one `SessionRecorder` and used only on its queue (the buffer pool is not shared). The
/// device's H.264 stream decodes to NV12 (`RTCCVPixelBuffer`) and software-decoded frames are
/// converted to NV12 by `VideoFrameConversion`, so the usual path is a row copy of the two planes
/// into a pooled buffer — no colour conversion and no GPU round trip per frame. BGRA gets the same
/// treatment; any other layout goes through Core Image.
final class FrameCropper {
    let region: CGRect

    private var pool: CVPixelBufferPool?
    private var poolFormat: OSType = 0
    private var poolWidth = 0
    private var poolHeight = 0
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    init(region: CGRect) {
        self.region = region
    }

    /// Size of the frames `crop` produces from frames of `frameSize`.
    func outputSize(forFrameSize frameSize: CGSize) -> CGSize {
        CaptureRegionGeometry.pixelRect(for: region, in: frameSize).size
    }

    /// The region of `source` in a new buffer, or `source` itself when the region covers all of it.
    /// Nil when the frame could not be copied; the caller skips the frame and tries the next.
    func crop(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let frameWidth = CVPixelBufferGetWidth(source)
        let frameHeight = CVPixelBufferGetHeight(source)
        let rect = CaptureRegionGeometry.pixelRect(for: region, in: CGSize(width: frameWidth, height: frameHeight))
        let x = Int(rect.minX)
        let y = Int(rect.minY)
        let width = Int(rect.width)
        let height = Int(rect.height)
        if x == 0, y == 0, width == frameWidth, height == frameHeight {
            return source
        }

        let format = CVPixelBufferGetPixelFormatType(source)
        switch format {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            guard CVPixelBufferGetPlaneCount(source) == 2 else { return nil }
            return copyBiPlanar(source, x: x, y: y, width: width, height: height, format: format)
        case kCVPixelFormatType_32BGRA, kCVPixelFormatType_32ARGB:
            guard CVPixelBufferGetPlaneCount(source) == 0 else { return nil }
            return copyPacked(source, x: x, y: y, width: width, height: height, format: format, bytesPerPixel: 4)
        default:
            return renderWithCoreImage(source, rect: rect, frameHeight: frameHeight)
        }
    }

    private func copyBiPlanar(_ source: CVPixelBuffer, x: Int, y: Int, width: Int, height: Int, format: OSType) -> CVPixelBuffer? {
        guard let destination = makeBuffer(format: format, width: width, height: height) else { return nil }
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(destination, [])
        defer {
            CVPixelBufferUnlockBaseAddress(destination, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        guard let sourceY = CVPixelBufferGetBaseAddressOfPlane(source, 0),
              let sourceUV = CVPixelBufferGetBaseAddressOfPlane(source, 1),
              let destinationY = CVPixelBufferGetBaseAddressOfPlane(destination, 0),
              let destinationUV = CVPixelBufferGetBaseAddressOfPlane(destination, 1) else {
            return nil
        }

        let sourceStrideY = CVPixelBufferGetBytesPerRowOfPlane(source, 0)
        let destinationStrideY = CVPixelBufferGetBytesPerRowOfPlane(destination, 0)
        for row in 0..<height {
            memcpy(destinationY + row * destinationStrideY, sourceY + (y + row) * sourceStrideY + x, width)
        }

        // Chroma: one row per two luma rows, and an interleaved Cb/Cr pair per two luma columns —
        // so the byte offset into a row equals the luma x and the byte count equals the width.
        // Both are even by construction (`CaptureRegionGeometry`).
        let sourceStrideUV = CVPixelBufferGetBytesPerRowOfPlane(source, 1)
        let destinationStrideUV = CVPixelBufferGetBytesPerRowOfPlane(destination, 1)
        for row in 0..<(height / 2) {
            memcpy(destinationUV + row * destinationStrideUV, sourceUV + (y / 2 + row) * sourceStrideUV + x, width)
        }

        CVBufferPropagateAttachments(source, destination)
        return destination
    }

    private func copyPacked(_ source: CVPixelBuffer, x: Int, y: Int, width: Int, height: Int, format: OSType, bytesPerPixel: Int) -> CVPixelBuffer? {
        guard let destination = makeBuffer(format: format, width: width, height: height) else { return nil }
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(destination, [])
        defer {
            CVPixelBufferUnlockBaseAddress(destination, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        guard let sourceBase = CVPixelBufferGetBaseAddress(source),
              let destinationBase = CVPixelBufferGetBaseAddress(destination) else {
            return nil
        }
        let sourceStride = CVPixelBufferGetBytesPerRow(source)
        let destinationStride = CVPixelBufferGetBytesPerRow(destination)
        for row in 0..<height {
            memcpy(
                destinationBase + row * destinationStride,
                sourceBase + (y + row) * sourceStride + x * bytesPerPixel,
                width * bytesPerPixel
            )
        }
        CVBufferPropagateAttachments(source, destination)
        return destination
    }

    /// Any other layout: let Core Image read it and write BGRA, which the encoders accept.
    private func renderWithCoreImage(_ source: CVPixelBuffer, rect: CGRect, frameHeight: Int) -> CVPixelBuffer? {
        guard let destination = makeBuffer(format: kCVPixelFormatType_32BGRA, width: Int(rect.width), height: Int(rect.height)) else {
            return nil
        }
        // Core Image's origin is bottom-left; the region's is top-left.
        let flipped = CGRect(x: rect.minX, y: CGFloat(frameHeight) - rect.maxY, width: rect.width, height: rect.height)
        let image = CIImage(cvPixelBuffer: source)
            .cropped(to: flipped)
            .transformed(by: CGAffineTransform(translationX: -flipped.minX, y: -flipped.minY))
        Self.context.render(image, to: destination)
        return destination
    }

    /// A buffer from a pool of the given format and size; the pool is rebuilt when either changes
    /// (the guest switched resolution, or the decoder changed layout).
    private func makeBuffer(format: OSType, width: Int, height: Int) -> CVPixelBuffer? {
        if pool == nil || poolFormat != format || poolWidth != width || poolHeight != height {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: format,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ]
            var created: CVPixelBufferPool?
            let status = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &created)
            guard status == kCVReturnSuccess, let created else { return nil }
            pool = created
            poolFormat = format
            poolWidth = width
            poolHeight = height
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) == kCVReturnSuccess else { return nil }
        return buffer
    }
}
