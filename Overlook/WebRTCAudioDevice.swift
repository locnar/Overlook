import Foundation
import AudioUnit
import CoreAudio

#if canImport(WebRTC)
@preconcurrency import WebRTC
#endif

/// The CoreAudio calls `WebRTCAudioDevice` makes to find its devices and to build, run and tear
/// down its HAL units, gathered in one place so tests can stand in for the hardware. `live` is
/// the real thing and is what the app always uses; each closure is a direct call to the CoreAudio
/// function it is named after.
struct AudioUnitHardware {
    /// The device a unit is bound to: the one with `uid` when it is set and present, otherwise
    /// the system default for the direction (0 when there is none).
    var resolveDevice: (_ uid: String?, _ isInput: Bool) -> AudioDeviceID
    var nominalSampleRate: (AudioDeviceID) -> Double?
    /// The largest IO buffer the device can be configured for.
    var maximumBufferFrames: (AudioDeviceID) -> UInt32?
    var deviceName: (AudioDeviceID) -> String?
    /// `AudioComponentFindNext` for Apple's HAL output unit, then `AudioComponentInstanceNew`.
    /// A nil unit with `noErr` means the component was not found.
    var newHALUnit: () -> (status: OSStatus, unit: AudioComponentInstance?)
    var setProperty: (
        _ unit: AudioComponentInstance,
        _ property: AudioUnitPropertyID,
        _ scope: AudioUnitScope,
        _ element: AudioUnitElement,
        _ data: UnsafeRawPointer,
        _ size: UInt32
    ) -> OSStatus
    var initialize: (AudioComponentInstance) -> OSStatus
    var uninitialize: (AudioComponentInstance) -> OSStatus
    var dispose: (AudioComponentInstance) -> OSStatus
    var start: (AudioComponentInstance) -> OSStatus
    var stop: (AudioComponentInstance) -> OSStatus

    static let live = AudioUnitHardware(
        resolveDevice: { uid, isInput in
            if let uid, let id = CoreAudioDevices.deviceID(forUID: uid) {
                return id
            }
            return WebRTCAudioDevice.systemDefaultDeviceID(
                selector: isInput ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice
            )
        },
        nominalSampleRate: { deviceID in
            guard deviceID != 0 else { return nil }
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyNominalSampleRate,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var rate: Double = 0
            var dataSize = UInt32(MemoryLayout<Double>.size)
            let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &rate)
            guard status == noErr, rate > 0 else { return nil }
            return rate
        },
        maximumBufferFrames: { deviceID in
            guard deviceID != 0 else { return nil }
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyBufferFrameSizeRange,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var range = AudioValueRange(mMinimum: 0, mMaximum: 0)
            var dataSize = UInt32(MemoryLayout<AudioValueRange>.size)
            let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &range)
            guard status == noErr, range.mMaximum > 0 else { return nil }
            return UInt32(range.mMaximum)
        },
        deviceName: { deviceID in
            deviceID == 0 ? nil : CoreAudioDevices.name(of: deviceID)
        },
        newHALUnit: {
            var desc = AudioComponentDescription(
                componentType: kAudioUnitType_Output,
                componentSubType: kAudioUnitSubType_HALOutput,
                componentManufacturer: kAudioUnitManufacturer_Apple,
                componentFlags: 0,
                componentFlagsMask: 0
            )
            guard let comp = AudioComponentFindNext(nil, &desc) else { return (noErr, nil) }
            var unit: AudioComponentInstance?
            let status = AudioComponentInstanceNew(comp, &unit)
            return (status, unit)
        },
        setProperty: { unit, property, scope, element, data, size in
            AudioUnitSetProperty(unit, property, scope, element, data, size)
        },
        initialize: { AudioUnitInitialize($0) },
        uninitialize: { AudioUnitUninitialize($0) },
        dispose: { AudioComponentInstanceDispose($0) },
        start: { AudioOutputUnitStart($0) },
        stop: { AudioOutputUnitStop($0) }
    )
}

final class WebRTCAudioDevice: NSObject, RTCAudioDevice {
    fileprivate var delegate: RTCAudioDeviceDelegate?

    private let inputDeviceUID: String?
    private let outputDeviceUID: String?

    /// Receives every playout buffer after WebRTC has filled it — the recorder's audio feed.
    /// Nil-able so the device can run without one, and read only on the HAL render thread.
    fileprivate let playoutTap: MediaCaptureHub?

    private let hardware: AudioUnitHardware
    /// Where a unit that fails to set up is reported. Called from libwebrtc's worker thread.
    private let log: ConnectionLogging?

    /// Set while this window is not one that plays its audio (`AudioRoute`). Read on the render
    /// thread after the recording tap has had the buffer, so a muted window still records what it
    /// receives. Written on the main thread with no lock: a Bool is written whole, and a stale read
    /// costs at most one buffer of sound or silence, which no lock on the render thread is worth.
    var isOutputMuted = false

    /// The CoreAudio devices the units were bound to at initialization. Following the system
    /// default means resolving it once, here; `WebRTCManager` compares these with the current
    /// defaults when they change and reconnects to move over. Set only once a unit is set up.
    private(set) var activeInputDeviceID: AudioDeviceID?
    private(set) var activeOutputDeviceID: AudioDeviceID?
    var isFollowingDefaultInput: Bool { inputDeviceUID == nil }
    var isFollowingDefaultOutput: Bool { outputDeviceUID == nil }

    /// Stored only once `AudioUnitInitialize` has succeeded, so a stored unit always means a
    /// working one: `initializePlayout`/`initializeRecording` treat a stored unit as done.
    fileprivate var inputUnit: AudioComponentInstance?
    fileprivate var outputUnit: AudioComponentInstance?

    fileprivate var inputBufferList: UnsafeMutablePointer<AudioBufferList>?
    private var inputBufferData: UnsafeMutableRawPointer?
    private var inputBufferCapacityFrames: UInt32 = 0

    private var _isInitialized: Bool = false
    private var _isPlayoutInitialized: Bool = false
    private var _isRecordingInitialized: Bool = false
    private var _isPlaying: Bool = false
    private var _isRecording: Bool = false

    private var inputSampleRate: Double = 48_000
    fileprivate var outputSampleRate: Double = 48_000

    private var inputIOBufferDurationValue: TimeInterval = 0.01
    private var outputIOBufferDurationValue: TimeInterval = 0.01

    // Mono capture (the device forwards one microphone channel), stereo playout: the stream is
    // stereo Opus once the answer asks for it, and a mono device here would fold it down.
    private var inputChannels: Int = 1
    fileprivate var outputChannels: Int = 2

    private var inputLatencyValue: TimeInterval = 0
    private var outputLatencyValue: TimeInterval = 0

    init(
        inputDeviceUID: String?,
        outputDeviceUID: String?,
        playoutTap: MediaCaptureHub? = nil,
        hardware: AudioUnitHardware = .live,
        log: ConnectionLogging? = nil
    ) {
        self.inputDeviceUID = inputDeviceUID?.isEmpty == true ? nil : inputDeviceUID
        self.outputDeviceUID = outputDeviceUID?.isEmpty == true ? nil : outputDeviceUID
        self.playoutTap = playoutTap
        self.hardware = hardware
        self.log = log
        super.init()
    }

    var deviceInputSampleRate: Double { inputSampleRate }
    var inputIOBufferDuration: TimeInterval { inputIOBufferDurationValue }
    var inputNumberOfChannels: Int { inputChannels }
    var inputLatency: TimeInterval { inputLatencyValue }

    var deviceOutputSampleRate: Double { outputSampleRate }
    var outputIOBufferDuration: TimeInterval { outputIOBufferDurationValue }
    var outputNumberOfChannels: Int { outputChannels }
    var outputLatency: TimeInterval { outputLatencyValue }

    var isInitialized: Bool { _isInitialized }
    var isPlayoutInitialized: Bool { _isPlayoutInitialized }
    var isPlaying: Bool { _isPlaying }
    var isRecordingInitialized: Bool { _isRecordingInitialized }
    var isRecording: Bool { _isRecording }

    /// Whether a playout or recording unit is stored. For tests: the protocol's
    /// `isPlayoutInitialized` is the flag libwebrtc reads, this is the unit behind it.
    var hasPlayoutUnit: Bool { outputUnit != nil }
    var hasRecordingUnit: Bool { inputUnit != nil }

    func initialize(with delegate: RTCAudioDeviceDelegate) -> Bool {
        self.delegate = delegate
        inputSampleRate = delegate.preferredInputSampleRate
        outputSampleRate = delegate.preferredOutputSampleRate
        inputIOBufferDurationValue = delegate.preferredInputIOBufferDuration
        outputIOBufferDurationValue = delegate.preferredOutputIOBufferDuration
        _isInitialized = true
        return true
    }

    func terminateDevice() -> Bool {
        _ = stopPlayout()
        _ = stopRecording()

        if let unit = outputUnit {
            _ = hardware.uninitialize(unit)
            _ = hardware.dispose(unit)
        }
        outputUnit = nil
        _isPlayoutInitialized = false

        if let unit = inputUnit {
            _ = hardware.uninitialize(unit)
            _ = hardware.dispose(unit)
        }
        inputUnit = nil
        _isRecordingInitialized = false

        releaseInputBuffer()

        delegate = nil
        _isInitialized = false
        return true
    }

    func initializePlayout() -> Bool {
        guard _isInitialized else { return false }
        guard outputUnit == nil else {
            _isPlayoutInitialized = true
            return true
        }

        let deviceID = hardware.resolveDevice(outputDeviceUID, false)

        // Run the client side of the HAL unit at the device's own rate and report that rate back:
        // WebRTC resamples to whatever we declare, while the HAL unit does not resample for us.
        // A 44.1 kHz DAC used to be asked for 48 kHz and fail to initialize.
        let sampleRate = hardware.nominalSampleRate(deviceID) ?? outputSampleRate
        let format = makeLinearPCMFormat(sampleRate: sampleRate, channels: outputChannels)
        let callback = AURenderCallbackStruct(
            inputProc: playoutRenderCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let unit = setUpUnit(
            "playout",
            deviceID: deviceID,
            steps: [
                ("enable output IO", { self.setProperty($0, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, UInt32(1)) }),
                ("disable input IO", { self.setProperty($0, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, UInt32(0)) }),
                ("set current device", { self.setProperty($0, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, deviceID) }),
                ("set stream format", { self.setProperty($0, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, format) }),
                ("set render callback", { self.setProperty($0, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, callback) }),
            ]
        ) else {
            return false
        }

        outputUnit = unit
        outputSampleRate = sampleRate
        activeOutputDeviceID = deviceID
        _isPlayoutInitialized = true
        log?.info(.stream, "Audio playout ready on \(describe(deviceID)) at \(Int(sampleRate)) Hz, \(outputChannels) ch")
        return true
    }

    func startPlayout() -> Bool {
        guard _isPlayoutInitialized, let unit = outputUnit else { return false }
        if _isPlaying { return true }
        let status = hardware.start(unit)
        guard status == noErr else { return false }
        _isPlaying = true
        return true
    }

    func stopPlayout() -> Bool {
        guard let unit = outputUnit else {
            _isPlaying = false
            return true
        }
        if !_isPlaying { return true }
        let status = hardware.stop(unit)
        guard status == noErr else { return false }
        _isPlaying = false
        return true
    }

    func initializeRecording() -> Bool {
        guard _isInitialized else { return false }
        guard inputUnit == nil else {
            _isRecordingInitialized = true
            return true
        }

        let deviceID = hardware.resolveDevice(inputDeviceUID, true)

        // Same as playout: capture at the device's native rate (Bluetooth headsets run at 16 or
        // 24 kHz, many USB microphones at 44.1) and let WebRTC resample.
        let sampleRate = hardware.nominalSampleRate(deviceID) ?? inputSampleRate
        let format = makeLinearPCMFormat(sampleRate: sampleRate, channels: inputChannels)
        let callback = AURenderCallbackStruct(
            inputProc: recordingInputCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )

        // No unit is stored, so nothing is reading the capture buffer: (re)size it for this device.
        if inputBufferList == nil {
            allocateInputBuffer(sampleRate: sampleRate, deviceID: deviceID)
        }

        guard let unit = setUpUnit(
            "recording",
            deviceID: deviceID,
            steps: [
                ("enable input IO", { self.setProperty($0, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, UInt32(1)) }),
                ("disable output IO", { self.setProperty($0, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, UInt32(0)) }),
                ("set current device", { self.setProperty($0, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, deviceID) }),
                ("set stream format", { self.setProperty($0, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, format) }),
                ("set input callback", { self.setProperty($0, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, callback) }),
            ]
        ) else {
            // The buffer was sized for a device that did not set up; a retry sizes it afresh.
            releaseInputBuffer()
            return false
        }

        inputUnit = unit
        inputSampleRate = sampleRate
        activeInputDeviceID = deviceID
        _isRecordingInitialized = true
        log?.info(.stream, "Audio capture ready on \(describe(deviceID)) at \(Int(sampleRate)) Hz, \(inputChannels) ch")
        return true
    }

    func startRecording() -> Bool {
        guard _isRecordingInitialized, let unit = inputUnit else { return false }
        if _isRecording { return true }
        let status = hardware.start(unit)
        guard status == noErr else { return false }
        _isRecording = true
        return true
    }

    func stopRecording() -> Bool {
        guard let unit = inputUnit else {
            _isRecording = false
            return true
        }
        if !_isRecording { return true }
        let status = hardware.stop(unit)
        guard status == noErr else { return false }
        _isRecording = false
        return true
    }

    // MARK: - Unit setup

    /// Creates a HAL unit, runs `steps` on it in order, then `AudioUnitInitialize`. Returns the
    /// unit only when every call succeeded. On any failure the unit is disposed, the step that
    /// failed is logged, and nil comes back, so the caller stores nothing and a later call tries
    /// again from scratch.
    private func setUpUnit(
        _ role: String,
        deviceID: AudioDeviceID,
        steps: [(name: String, run: (AudioComponentInstance) -> OSStatus)]
    ) -> AudioComponentInstance? {
        let created = hardware.newHALUnit()
        guard created.status == noErr, let unit = created.unit else {
            if created.status == noErr {
                log?.error(.stream, "Audio \(role) setup failed: no HAL output audio component (\(describe(deviceID)))")
            } else {
                log?.error(.stream, "Audio \(role) setup failed: AudioComponentInstanceNew returned \(Self.describe(status: created.status)) (\(describe(deviceID)))")
            }
            return nil
        }

        for step in steps {
            let status = step.run(unit)
            if status != noErr {
                _ = hardware.dispose(unit)
                log?.error(.stream, "Audio \(role) setup failed: \(step.name) returned \(Self.describe(status: status)) (\(describe(deviceID)))")
                return nil
            }
        }

        let status = hardware.initialize(unit)
        guard status == noErr else {
            _ = hardware.dispose(unit)
            log?.error(.stream, "Audio \(role) setup failed: AudioUnitInitialize returned \(Self.describe(status: status)) (\(describe(deviceID)))")
            return nil
        }
        return unit
    }

    /// `AudioUnitSetProperty` with `value`'s bytes, `MemoryLayout<T>.size` of them.
    private func setProperty<T>(
        _ unit: AudioComponentInstance,
        _ property: AudioUnitPropertyID,
        _ scope: AudioUnitScope,
        _ element: AudioUnitElement,
        _ value: T
    ) -> OSStatus {
        var value = value
        return withUnsafeBytes(of: &value) { bytes in
            hardware.setProperty(unit, property, scope, element, bytes.baseAddress!, UInt32(bytes.count))
        }
    }

    /// `device 73 "MacBook Pro Speakers"`, or `no device` for 0.
    private func describe(_ deviceID: AudioDeviceID) -> String {
        guard deviceID != 0 else { return "no device" }
        if let name = hardware.deviceName(deviceID) {
            return "device \(deviceID) \"\(name)\""
        }
        return "device \(deviceID)"
    }

    /// An OSStatus as CoreAudio documents it: its four-character code when it has one, and the
    /// number. `'!dev' (560227702)`, `-10851`.
    static func describe(status: OSStatus) -> String {
        let value = UInt32(bitPattern: status)
        let bytes = [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
        if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }), let code = String(bytes: bytes, encoding: .ascii) {
            return "'\(code)' (\(status))"
        }
        return "\(status)"
    }

    /// The current system default device for `kAudioHardwarePropertyDefaultInputDevice` or
    /// `kAudioHardwarePropertyDefaultOutputDevice`; 0 when there is none.
    static func systemDefaultDeviceID(selector: AudioObjectPropertySelector) -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceID)
        if status != noErr { return AudioDeviceID(0) }
        return deviceID
    }

    private func makeLinearPCMFormat(sampleRate: Double, channels: Int) -> AudioStreamBasicDescription {
        let bytesPerFrame = UInt32(channels * 2)
        return AudioStreamBasicDescription(
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
    }

    fileprivate var inputBytesPerFrame: Int { inputChannels * MemoryLayout<Int16>.size }
    fileprivate var inputBufferCapacityBytes: Int { Int(inputBufferCapacityFrames) * inputBytesPerFrame }

    /// Sizes the capture buffer to the largest IO buffer the device can be configured for (Audio
    /// MIDI Setup, DAWs), so no callback ever has more frames than fit.
    private func allocateInputBuffer(sampleRate: Double, deviceID: AudioDeviceID) {
        let framesPerBuffer = max(UInt32(sampleRate * inputIOBufferDurationValue), 256)
        let deviceMaximum = hardware.maximumBufferFrames(deviceID) ?? 0
        inputBufferCapacityFrames = max(framesPerBuffer, deviceMaximum, 4096)
        let bytes = Int(inputBufferCapacityFrames) * inputChannels * MemoryLayout<Int16>.size

        inputBufferData?.deallocate()
        inputBufferData = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: MemoryLayout<Int16>.alignment)

        inputBufferList?.deallocate()
        inputBufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
        inputBufferList?.pointee.mNumberBuffers = 1
        inputBufferList?.pointee.mBuffers.mNumberChannels = UInt32(inputChannels)
        inputBufferList?.pointee.mBuffers.mDataByteSize = UInt32(bytes)
        inputBufferList?.pointee.mBuffers.mData = inputBufferData
    }

    private func releaseInputBuffer() {
        inputBufferList?.deallocate()
        inputBufferList = nil
        inputBufferData?.deallocate()
        inputBufferData = nil
        inputBufferCapacityFrames = 0
    }

    /// Whether a capture buffer is allocated. For tests.
    var hasInputBuffer: Bool { inputBufferList != nil }
}

private func playoutRenderCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let device = Unmanaged<WebRTCAudioDevice>.fromOpaque(inRefCon).takeUnretainedValue()
    guard let delegate = device.delegate, let ioData else { return noErr }
    let status = delegate.getPlayoutData(ioActionFlags, inTimeStamp, Int(inBusNumber), inNumberFrames, ioData)

    // What WebRTC decoded is exactly what a recording should keep, so tap it here, after the
    // jitter buffer and decoder and before the HAL — and before a muted window's output is
    // silenced. The tap copies and returns.
    let tap = status == noErr ? device.playoutTap : nil
    WebRTCAudioDevice.finishPlayout(ioData, flags: ioActionFlags, isMuted: device.isOutputMuted) { buffers in
        tap?.handlePlayoutAudio(
            buffers,
            frameCount: inNumberFrames,
            timestamp: inTimeStamp,
            sampleRate: device.outputSampleRate,
            channels: device.outputChannels
        )
    }
    return status
}

extension WebRTCAudioDevice {
    /// The last step of every playout callback: the recording tap is handed the buffer as WebRTC
    /// filled it, and only then, if this window is muted, is it silenced on its way to the output
    /// device. In that order a window muted because another one is active still records its audio.
    static func finishPlayout(
        _ ioData: UnsafeMutablePointer<AudioBufferList>,
        flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        isMuted: Bool,
        tap: (UnsafePointer<AudioBufferList>) -> Void
    ) {
        tap(UnsafePointer(ioData))
        guard isMuted else { return }
        for buffer in UnsafeMutableAudioBufferListPointer(ioData) {
            if let data = buffer.mData {
                memset(data, 0, Int(buffer.mDataByteSize))
            }
        }
        flags.pointee.insert(.unitRenderAction_OutputIsSilence)
    }
}

private func recordingInputCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let device = Unmanaged<WebRTCAudioDevice>.fromOpaque(inRefCon).takeUnretainedValue()
    guard let unit = device.inputUnit, let delegate = device.delegate, let bufferList = device.inputBufferList else { return noErr }

    // AudioUnitRender reads the buffer size from the list and writes back what it produced, so
    // the capacity has to be restated on every callback or it shrinks to the last frame count.
    let needed = Int(inNumberFrames) * device.inputBytesPerFrame
    guard needed <= device.inputBufferCapacityBytes else { return kAudioUnitErr_TooManyFramesToProcess }
    bufferList.pointee.mBuffers.mDataByteSize = UInt32(device.inputBufferCapacityBytes)

    var flags = AudioUnitRenderActionFlags(rawValue: 0)
    let status = AudioUnitRender(unit, &flags, inTimeStamp, 1, inNumberFrames, bufferList)
    if status != noErr { return status }

    let inputPtr: UnsafePointer<AudioBufferList> = UnsafePointer(bufferList)
    return delegate.deliverRecordedData(ioActionFlags, inTimeStamp, Int(inBusNumber), inNumberFrames, inputPtr, nil, nil)
}
