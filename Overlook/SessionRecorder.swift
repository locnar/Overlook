import Foundation
import AVFoundation
import AudioToolbox
import CoreMedia
import CoreVideo
import VideoToolbox
import os
#if canImport(WebRTC)
import WebRTC
#endif

/// What a recording keeps. The container follows the content: anything with video is an `.mp4`,
/// audio alone is an `.m4a`.
enum RecordingMode: String, CaseIterable, Identifiable {
    case videoAndAudio
    case videoOnly
    case audioOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .videoAndAudio: return "Video and Audio"
        case .videoOnly: return "Video Only"
        case .audioOnly: return "Audio Only"
        }
    }

    /// For the toolbar pop-up, where width matters.
    var shortTitle: String {
        switch self {
        case .videoAndAudio: return "Video + Audio"
        case .videoOnly: return "Video"
        case .audioOnly: return "Audio"
        }
    }

    var systemImage: String {
        switch self {
        case .videoAndAudio: return "video.badge.waveform"
        case .videoOnly: return "video"
        case .audioOnly: return "waveform"
        }
    }

    var recordsVideo: Bool { self != .audioOnly }
    var recordsAudio: Bool { self != .videoOnly }

    var fileExtension: String { recordsVideo ? "mp4" : "m4a" }
    var fileType: AVFileType { recordsVideo ? .mp4 : .m4a }
}

enum RecordingVideoCodec: String, CaseIterable, Identifiable {
    case h264
    case hevc

    var id: String { rawValue }

    var title: String {
        switch self {
        case .h264: return "H.264 (plays everywhere)"
        case .hevc: return "HEVC (smaller files)"
        }
    }

    var shortTitle: String {
        switch self {
        case .h264: return "H.264"
        case .hevc: return "HEVC"
        }
    }

    var avCodecType: AVVideoCodecType {
        switch self {
        case .h264: return .h264
        case .hevc: return .hevc
        }
    }
}

struct RecordingResult {
    let url: URL
    let mode: RecordingMode
    let duration: TimeInterval
    let videoFrameCount: Int
}

enum RecordingError: LocalizedError {
    /// Stop came before any frame or sample reached the file; the empty file is removed.
    case nothingRecorded
    case writerFailed(Error?)

    var errorDescription: String? {
        switch self {
        case .nothingRecorded:
            return "Nothing was recorded — no video or audio arrived while recording."
        case .writerFailed(let error):
            if let error {
                return "Recording failed: \(error.localizedDescription)"
            }
            return "Recording failed."
        }
    }
}

/// One recording: an `AVAssetWriter` fed decoded frames from the decoder thread and playout PCM
/// from the HAL render thread, with everything serialized on the recorder's own queue.
///
/// Timing: both feeds are stamped on the shared host clock (`HostClock`) and made relative to
/// the moment Record was pressed, so the movie's clock starts at the press. Video keeps libwebrtc's
/// render time for each frame (the jitter buffer's intended display time — smoother than arrival)
/// when that is plausibly on the host clock, else the arrival time. Audio is anchored once, on the
/// first buffer, and then runs on its sample count: the HAL pulls at a fixed rate, so counting
/// samples is exact and keeps the AAC encoder's input gapless. A real discontinuity (the output
/// unit was stopped and restarted around a reconnect) shows up as a buffer whose playout time is
/// more than `audioGapThreshold` past the end of the previous one; that much silence is inserted so
/// video and audio stay in step across the gap. Slow drift between the audio device's clock and
/// the host clock is left alone (tens of ms per hour on typical hardware).
///
/// The video input needs the frame size up front and `AVAssetWriter` cannot take new inputs once
/// writing, so a recording whose size is not yet known waits for its first frame before
/// `startWriting()`; audio that arrives before then is dropped.
final class SessionRecorder: @unchecked Sendable {
    let url: URL
    let mode: RecordingMode
    let codec: RecordingVideoCodec

    private let queue = DispatchQueue(label: "com.overlook.session-recorder", qos: .userInitiated)
    private let writer: AVAssetWriter
    private let startHostTime: CFTimeInterval
    private let audioChannels: Int
    private let audioSampleRate: Double

    private var videoInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var audioInput: AVAssetWriterInput?

    private var isWriting = false
    private var isStopping = false
    private var failure: Error?

    private var lastVideoPTS: CMTime = .invalid
    private var videoFrameCount = 0
    /// Frames dispatched to the queue but not yet appended. Beyond `maxPendingVideoFrames` the
    /// encoder is behind and new frames are dropped rather than queued without bound.
    private let pendingVideoFrames = OSAllocatedUnfairLock(initialState: 0)
    private static let maxPendingVideoFrames = 6

    private struct AudioTimeline {
        /// Movie-clock seconds where the next buffer goes; advances by the samples written.
        var nextSampleTime: Double
        /// Host-clock seconds (relative to the press) the next buffer should carry if the stream
        /// is continuous: previous buffer's playout time plus its length. Compared per buffer, so
        /// slow clock drift never reads as a gap — only a real hole does.
        var expectedNextPlayoutTime: Double
    }
    private var audio: AudioTimeline?
    private var audioFrameCount: Int64 = 0
    /// The track's PCM format is frozen at init (`audioSampleRate` / `audioChannels`); a device
    /// that comes back at another rate after a reconnect is resampled to it here first.
    private var audioFormatDescription: CMAudioFormatDescription?
    private var audioConverter: AVAudioConverter?
    private static let audioGapThreshold: Double = 0.25
    private static let videoTimescale: CMTimeScale = 90_000

    init(
        url: URL,
        mode: RecordingMode,
        codec: RecordingVideoCodec,
        initialVideoSize: CGSize?,
        audioChannels: Int,
        audioSampleRate: Double
    ) throws {
        self.url = url
        self.mode = mode
        self.codec = codec
        self.audioChannels = max(1, min(2, audioChannels))
        // AAC takes 8–96 kHz; anything else (or a missing rate) gets 48 kHz and a resample.
        self.audioSampleRate = (8_000...96_000).contains(audioSampleRate) ? audioSampleRate : 48_000
        self.startHostTime = HostClock.now

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        writer = try AVAssetWriter(outputURL: url, fileType: mode.fileType)
        writer.shouldOptimizeForNetworkUse = true

        if mode.recordsAudio {
            audioFormatDescription = Self.makeFormatDescription(sampleRate: self.audioSampleRate, channels: self.audioChannels)
            addAudioInput()
        }
        if mode.recordsVideo, let size = initialVideoSize, size.width >= 16, size.height >= 16 {
            addVideoInput(size: size)
        }
        startWritingIfReady()
        if let failure {
            removeFile()
            throw failure
        }
    }

    // MARK: Feeds (media threads)

    func appendVideoFrame(_ frame: RTCVideoFrame, hostTime: CFTimeInterval) {
        guard mode.recordsVideo else { return }

        let accepted = pendingVideoFrames.withLock { pending -> Bool in
            guard pending < Self.maxPendingVideoFrames else { return false }
            pending += 1
            return true
        }
        guard accepted else { return }

        // libwebrtc stamps received frames with their render time on rtc::TimeNanos, which is
        // mach_absolute_time on Apple platforms — the same clock as `hostTime`. Trust it only when
        // the two agree to within a couple of seconds, so a build with a different clock source
        // degrades to arrival time instead of producing a movie with a wild timeline.
        let renderTime = Double(frame.timeStampNs) / 1_000_000_000
        let frameTime = abs(renderTime - hostTime) < 2.0 ? renderTime : hostTime

        queue.async { [self] in
            defer { pendingVideoFrames.withLock { $0 -= 1 } }
            appendVideoFrameOnQueue(frame, frameTime: frameTime)
        }
    }

    func appendPlayoutAudio(
        _ bufferList: UnsafePointer<AudioBufferList>,
        frameCount: UInt32,
        timestamp: UnsafePointer<AudioTimeStamp>,
        sampleRate: Double,
        channels: Int
    ) {
        guard mode.recordsAudio, frameCount > 0, sampleRate > 0, channels > 0 else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        guard let first = buffers.first, let source = first.mData else { return }

        // Interleaved int16 is what `WebRTCAudioDevice` declares to the HAL unit; a
        // non-interleaved layout would arrive as one buffer per channel and is not expected here.
        let bytesPerFrame = channels * MemoryLayout<Int16>.size
        let byteCount = min(Int(first.mDataByteSize), Int(frameCount) * bytesPerFrame)
        guard byteCount >= bytesPerFrame else { return }
        let frames = byteCount / bytesPerFrame

        // The copy has to happen here: the HAL reuses `bufferList` as soon as this returns.
        let data = Data(bytes: source, count: frames * bytesPerFrame)
        let playoutTime = HostClock.seconds(from: timestamp.pointee)

        queue.async { [self] in
            appendAudioOnQueue(data, frames: frames, playoutTime: playoutTime, sampleRate: sampleRate, channels: channels)
        }
    }

    // MARK: Stop

    /// Finalizes the file. `completion` runs on a background queue; hop to the main actor for UI.
    func stop(completion: @escaping (Result<RecordingResult, Error>) -> Void) {
        queue.async { [self] in
            guard !isStopping else { return }
            isStopping = true

            // `cancelWriting` is only legal while writing; a writer that never started or has
            // already failed just needs its file removed.
            if let failure {
                if writer.status == .writing {
                    writer.cancelWriting()
                }
                removeFile()
                completion(.failure(failure))
                return
            }

            guard isWriting, videoFrameCount > 0 || audioFrameCount > 0 else {
                if writer.status == .writing {
                    writer.cancelWriting()
                }
                removeFile()
                completion(.failure(RecordingError.nothingRecorded))
                return
            }

            // Audio was negotiated but never played (nothing on the target's HDMI audio, say):
            // an audio track with no samples confuses players, so it gets silence for the length
            // of the video instead. The input cannot be removed at this point.
            if let audioInput, audioFrameCount == 0, lastVideoPTS.isValid, lastVideoPTS.seconds > 0 {
                var timeline = AudioTimeline(nextSampleTime: 0, expectedNextPlayoutTime: 0)
                appendSilence(seconds: lastVideoPTS.seconds, into: &timeline, input: audioInput)
                audio = timeline
            }

            videoInput?.markAsFinished()
            audioInput?.markAsFinished()

            let duration = max(
                lastVideoPTS.isValid ? lastVideoPTS.seconds : 0,
                audio?.nextSampleTime ?? 0
            )
            let result = RecordingResult(
                url: url,
                mode: mode,
                duration: duration,
                videoFrameCount: videoFrameCount
            )

            writer.finishWriting { [self] in
                if writer.status == .completed {
                    completion(.success(result))
                } else {
                    removeFile()
                    completion(.failure(RecordingError.writerFailed(writer.error)))
                }
            }
        }
    }

    // MARK: Queue-confined internals

    private func addVideoInput(size: CGSize) {
        // Encoders want even dimensions.
        let width = max(16, Int(size.width) & ~1)
        let height = max(16, Int(size.height) & ~1)

        // Screen content at 30 fps: ~0.12 bits per pixel per frame for H.264 (1080p ≈ 7.5 Mbps,
        // 4K ≈ 30 Mbps), HEVC at roughly 60% of that.
        let bitsPerPixelPerFrame = codec == .h264 ? 0.12 : 0.075
        let bitrate = Int(Double(width * height) * 30 * bitsPerPixelPerFrame)
        let clampedBitrate = min(max(bitrate, 2_000_000), 40_000_000)

        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: clampedBitrate,
            AVVideoExpectedSourceFrameRateKey: 60,
            AVVideoMaxKeyFrameIntervalKey: 120,
        ]
        switch codec {
        case .h264:
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        case .hevc:
            compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main_AutoLevel as String
        }

        let settings: [String: Any] = [
            AVVideoCodecKey: codec.avCodecType,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            // A guest that changes resolution mid-recording is letterboxed into the original frame
            // rather than stretched; the input cannot be resized once writing has begun.
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
            AVVideoCompressionPropertiesKey: compression,
        ]

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            failure = RecordingError.writerFailed(writer.error)
            return
        }
        writer.add(input)
        videoInput = input
        pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: nil
        )
    }

    private func addAudioInput() {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: audioSampleRate,
            AVNumberOfChannelsKey: audioChannels,
            AVEncoderBitRateKey: audioChannels == 1 ? 96_000 : 160_000,
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            failure = RecordingError.writerFailed(writer.error)
            return
        }
        writer.add(input)
        audioInput = input
    }

    /// Both inputs the mode calls for exist: start the file with its clock at zero (= the press).
    private func startWritingIfReady() {
        guard !isWriting, failure == nil else { return }
        if mode.recordsVideo && videoInput == nil { return }
        if mode.recordsAudio && audioInput == nil { return }

        guard writer.startWriting() else {
            failure = RecordingError.writerFailed(writer.error)
            return
        }
        writer.startSession(atSourceTime: .zero)
        isWriting = true
    }

    private func appendVideoFrameOnQueue(_ frame: RTCVideoFrame, frameTime: CFTimeInterval) {
        guard !isStopping, failure == nil else { return }

        if videoInput == nil {
            addVideoInput(size: CGSize(width: Int(frame.width), height: Int(frame.height)))
            startWritingIfReady()
        }
        guard isWriting, let videoInput, let pixelBufferAdaptor else { return }

        let seconds = frameTime - startHostTime
        guard seconds >= 0 else { return }   // decoded before the press
        let pts = CMTime(seconds: seconds, preferredTimescale: Self.videoTimescale)
        // Presentation times must strictly increase per track.
        if lastVideoPTS.isValid, pts <= lastVideoPTS { return }

        guard videoInput.isReadyForMoreMediaData else { return }   // encoder behind: drop
        guard let pixelBuffer = VideoFrameConversion.pixelBuffer(for: frame) else { return }

        if pixelBufferAdaptor.append(pixelBuffer, withPresentationTime: pts) {
            lastVideoPTS = pts
            videoFrameCount += 1
        } else if writer.status == .failed {
            failure = RecordingError.writerFailed(writer.error)
        }
    }

    private func appendAudioOnQueue(
        _ data: Data,
        frames: Int,
        playoutTime: CFTimeInterval,
        sampleRate: Double,
        channels: Int
    ) {
        guard !isStopping, failure == nil, isWriting, let audioInput, let format = audioFormatDescription else { return }

        let playoutSeconds = playoutTime - startHostTime
        guard playoutSeconds >= 0 else { return }   // queued for the speakers before the press
        let sourceDuration = Double(frames) / sampleRate

        // Bring a foreign format (the output unit came back on a device with another rate after a
        // reconnect) to the track's format; the writer's own converter is set up by the first
        // buffer and is not relied on to follow a change.
        var pcm = data
        var frameCount = frames
        if sampleRate != audioSampleRate || channels != audioChannels {
            guard let converted = convertAudio(data, frames: frames, sampleRate: sampleRate, channels: channels) else { return }
            pcm = converted.data
            frameCount = converted.frames
        } else {
            audioConverter = nil
        }

        var timeline = audio ?? AudioTimeline(nextSampleTime: playoutSeconds, expectedNextPlayoutTime: playoutSeconds)

        // A buffer that plays well after the previous one ended means samples went missing (the
        // unit was stopped around a reconnect): fill the hole with silence so what follows stays
        // aligned with the video.
        let gap = playoutSeconds - timeline.expectedNextPlayoutTime
        if gap > Self.audioGapThreshold {
            appendSilence(seconds: gap, into: &timeline, input: audioInput)
        }
        timeline.expectedNextPlayoutTime = playoutSeconds + sourceDuration

        guard frameCount > 0 else {
            audio = timeline
            return
        }
        guard audioInput.isReadyForMoreMediaData else {
            // Dropped while the encoder was busy: leave a hole of its length rather than pulling
            // everything after it earlier than it played.
            timeline.nextSampleTime += sourceDuration
            audio = timeline
            return
        }
        guard let sampleBuffer = Self.makeSampleBuffer(
            pcm: pcm,
            frames: frameCount,
            channels: audioChannels,
            format: format,
            presentationTime: CMTime(seconds: timeline.nextSampleTime, preferredTimescale: CMTimeScale(audioSampleRate))
        ) else {
            audio = timeline
            return
        }

        if audioInput.append(sampleBuffer) {
            timeline.nextSampleTime += Double(frameCount) / audioSampleRate
            audioFrameCount += Int64(frameCount)
        } else if writer.status == .failed {
            failure = RecordingError.writerFailed(writer.error)
        }
        audio = timeline
    }

    /// Zeros from `timeline.nextSampleTime` for `seconds`, in one-second buffers.
    private func appendSilence(seconds: Double, into timeline: inout AudioTimeline, input: AVAssetWriterInput) {
        guard let format = audioFormatDescription else { return }
        var remaining = Int(seconds * audioSampleRate)
        let bytesPerFrame = audioChannels * MemoryLayout<Int16>.size
        let chunkFrames = Int(audioSampleRate)
        while remaining > 0, input.isReadyForMoreMediaData {
            let frames = min(remaining, chunkFrames)
            let silence = Data(count: frames * bytesPerFrame)
            guard let sampleBuffer = Self.makeSampleBuffer(
                pcm: silence,
                frames: frames,
                channels: audioChannels,
                format: format,
                presentationTime: CMTime(seconds: timeline.nextSampleTime, preferredTimescale: CMTimeScale(audioSampleRate))
            ), input.append(sampleBuffer) else { return }
            timeline.nextSampleTime += Double(frames) / audioSampleRate
            audioFrameCount += Int64(frames)
            remaining -= frames
        }
    }

    /// Resamples/remaps interleaved int16 PCM to the track's rate and channel count. One converter
    /// is kept across buffers so the resampler's internal state carries over (its priming latency
    /// is paid once, not per buffer).
    private func convertAudio(_ data: Data, frames: Int, sampleRate: Double, channels: Int) -> (data: Data, frames: Int)? {
        if audioConverter == nil
            || audioConverter?.inputFormat.sampleRate != sampleRate
            || audioConverter?.inputFormat.channelCount != AVAudioChannelCount(channels) {
            guard let source = AVAudioFormat(
                    commonFormat: .pcmFormatInt16,
                    sampleRate: sampleRate,
                    channels: AVAudioChannelCount(channels),
                    interleaved: true
                  ),
                  let target = AVAudioFormat(
                    commonFormat: .pcmFormatInt16,
                    sampleRate: audioSampleRate,
                    channels: AVAudioChannelCount(audioChannels),
                    interleaved: true
                  ),
                  let converter = AVAudioConverter(from: source, to: target) else { return nil }
            audioConverter = converter
        }
        guard let converter = audioConverter else { return nil }

        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: converter.inputFormat, frameCapacity: AVAudioFrameCount(frames)),
              let inputChannel = inputBuffer.int16ChannelData?[0] else { return nil }
        inputBuffer.frameLength = AVAudioFrameCount(frames)
        let inputBytes = frames * channels * MemoryLayout<Int16>.size
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            memcpy(inputChannel, base, min(bytes.count, inputBytes))
        }

        let capacity = AVAudioFrameCount(Double(frames) * audioSampleRate / sampleRate) + 64
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else { return nil }

        var handedOver = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
            if handedOver {
                inputStatus.pointee = .noDataNow
                return nil
            }
            handedOver = true
            inputStatus.pointee = .haveData
            return inputBuffer
        }
        guard status != .error, let outputChannel = outputBuffer.int16ChannelData?[0] else { return nil }

        let outputFrames = Int(outputBuffer.frameLength)
        let outputBytes = outputFrames * audioChannels * MemoryLayout<Int16>.size
        return (Data(bytes: outputChannel, count: outputBytes), outputFrames)
    }

    private func removeFile() {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: CoreMedia plumbing

    private static func makeFormatDescription(sampleRate: Double, channels: Int) -> CMAudioFormatDescription? {
        let bytesPerFrame = UInt32(channels * MemoryLayout<Int16>.size)
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var description: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &description
        )
        return status == noErr ? description : nil
    }

    private static func makeSampleBuffer(
        pcm: Data,
        frames: Int,
        channels: Int,
        format: CMAudioFormatDescription,
        presentationTime: CMTime
    ) -> CMSampleBuffer? {
        let byteCount = pcm.count
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let blockBuffer else { return nil }

        status = pcm.withUnsafeBytes { bytes -> OSStatus in
            guard let base = bytes.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: byteCount
            )
        }
        guard status == kCMBlockBufferNoErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: presentationTime.timescale),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var sampleSize = channels * MemoryLayout<Int16>.size
        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleCount: CMItemCount(frames),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        return status == noErr ? sampleBuffer : nil
    }
}
