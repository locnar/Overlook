import AudioUnit
import CoreAudio
import Foundation
import Testing
@testable import Overlook

/// Setting up `WebRTCAudioDevice`'s playout and recording units against stand-in hardware: no
/// audio unit is created and no device is opened. A unit that fails any step of its setup must be
/// disposed and not stored, so libwebrtc's next init really tries again instead of being told it
/// succeeded.
@Suite("Audio device setup")
struct AudioDeviceSetupTests {
    let fake = FakeAudioHardware()
    let log = RecordingConnectionLog()
    let delegate = FakeAudioDeviceDelegate()

    /// The device under test, already given its delegate as libwebrtc does first.
    private func makeDevice(initialized: Bool = true) -> WebRTCAudioDevice {
        let device = WebRTCAudioDevice(
            inputDeviceUID: nil,
            outputDeviceUID: nil,
            hardware: fake.hardware,
            log: log
        )
        if initialized {
            #expect(device.initialize(with: delegate))
        }
        return device
    }

    // MARK: - Playout

    @Test func successfulPlayoutSetupStoresTheUnit() {
        let device = makeDevice()
        #expect(device.initializePlayout())
        #expect(device.isPlayoutInitialized)
        #expect(device.hasPlayoutUnit)
        #expect(device.activeOutputDeviceID == FakeAudioHardware.outputDevice)
        #expect(device.deviceOutputSampleRate == 44_100)
        #expect(fake.created.count == 1)
        #expect(fake.initializeCalls == 1)
        #expect(fake.disposed.isEmpty)
        #expect(log.errors.isEmpty)
        #expect(log.messages.contains { $0.hasPrefix("Audio playout ready on device 41 \"Fake Speakers\" at 44100 Hz") })
    }

    @Test func aSecondPlayoutInitAfterSuccessIsANoOp() {
        let device = makeDevice()
        #expect(device.initializePlayout())
        #expect(device.initializePlayout())
        #expect(fake.created.count == 1)
        #expect(fake.initializeCalls == 1)
        #expect(device.isPlayoutInitialized)
    }

    @Test func aFailingPlayoutInitializeDisposesTheUnit() {
        fake.initializeStatus = kAudioUnitErr_FailedInitialization
        let device = makeDevice()
        #expect(device.initializePlayout() == false)
        #expect(device.isPlayoutInitialized == false)
        #expect(device.hasPlayoutUnit == false)
        #expect(device.activeOutputDeviceID == nil)
        #expect(fake.created.count == 1)
        #expect(fake.disposed == fake.created)
        #expect(fake.liveUnits.isEmpty)
        // Nothing to play with, so nothing starts.
        #expect(device.startPlayout() == false)
        #expect(fake.startCalls == 0)
        #expect(log.errors == ["Audio playout setup failed: AudioUnitInitialize returned -10875 (device 41 \"Fake Speakers\")"])
    }

    @Test func playoutSetupIsRetriedAfterAFailure() {
        fake.initializeStatus = kAudioUnitErr_FailedInitialization
        let device = makeDevice()
        #expect(device.initializePlayout() == false)
        #expect(device.initializePlayout() == false)
        #expect(fake.created.count == 2)
        #expect(fake.initializeCalls == 2)

        fake.initializeStatus = noErr
        #expect(device.initializePlayout())
        #expect(fake.created.count == 3)
        #expect(device.hasPlayoutUnit)
        #expect(fake.liveUnits == [fake.created[2]])
        #expect(device.startPlayout())
        #expect(device.isPlaying)
    }

    @Test(arguments: 0..<5)
    func aFailingPlayoutPropertyDisposesTheUnit(failingCall: Int) {
        fake.failingSetPropertyCall = failingCall
        fake.setPropertyFailure = kAudioUnitErr_InvalidProperty
        let device = makeDevice()
        #expect(device.initializePlayout() == false)
        #expect(device.hasPlayoutUnit == false)
        #expect(device.isPlayoutInitialized == false)
        #expect(fake.disposed == fake.created)
        #expect(fake.created.count == 1)
        // Setup stops at the step that failed.
        #expect(fake.setPropertyCalls.count == failingCall + 1)
        #expect(fake.initializeCalls == 0)
        let steps = ["enable output IO", "disable input IO", "set current device", "set stream format", "set render callback"]
        #expect(log.errors == ["Audio playout setup failed: \(steps[failingCall]) returned -10879 (device 41 \"Fake Speakers\")"])

        // And the next init starts over.
        fake.failingSetPropertyCall = nil
        #expect(device.initializePlayout())
        #expect(fake.created.count == 2)
    }

    @Test func aMissingAudioComponentStoresNothing() {
        fake.componentMissing = true
        let device = makeDevice()
        #expect(device.initializePlayout() == false)
        #expect(device.initializeRecording() == false)
        #expect(device.hasPlayoutUnit == false)
        #expect(device.hasRecordingUnit == false)
        #expect(fake.disposed.isEmpty)
        #expect(log.errors.count == 2)
        #expect(log.errors.allSatisfy { $0.contains("no HAL output audio component") })
    }

    @Test func aFailingInstanceNewStoresNothing() {
        fake.instanceNewStatus = kAudioHardwareBadDeviceError
        let device = makeDevice()
        #expect(device.initializePlayout() == false)
        #expect(device.hasPlayoutUnit == false)
        #expect(log.errors == ["Audio playout setup failed: AudioComponentInstanceNew returned '!dev' (560227702) (device 41 \"Fake Speakers\")"])
    }

    /// The calls a successful playout setup makes, in order, are the ones the unit was always
    /// set up with: output on, input off, the device, 16-bit stereo at the device's rate, the
    /// render callback.
    @Test func playoutSetupMakesTheSameCallsAsBefore() throws {
        let device = makeDevice()
        #expect(device.initializePlayout())
        let calls = fake.setPropertyCalls
        try #require(calls.count == 5)
        #expect(calls[0].key == .init(kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, 4))
        #expect(calls[0].word == 1)
        #expect(calls[1].key == .init(kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, 4))
        #expect(calls[1].word == 0)
        #expect(calls[2].key == .init(kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, 4))
        #expect(calls[2].word == FakeAudioHardware.outputDevice)
        #expect(calls[3].key == .init(
            kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        ))
        let format = try #require(calls[3].format)
        #expect(format.mSampleRate == 44_100)
        #expect(format.mFormatID == kAudioFormatLinearPCM)
        #expect(format.mFormatFlags == kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked)
        #expect(format.mChannelsPerFrame == 2)
        #expect(format.mBitsPerChannel == 16)
        #expect(format.mBytesPerFrame == 4)
        #expect(format.mBytesPerPacket == 4)
        #expect(format.mFramesPerPacket == 1)
        #expect(calls[4].key == .init(
            kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        ))
        #expect(calls.allSatisfy { $0.unit == fake.created[0] })
    }

    @Test func playoutNeedsTheDelegateFirst() {
        let device = makeDevice(initialized: false)
        #expect(device.initializePlayout() == false)
        #expect(device.initializeRecording() == false)
        #expect(fake.created.isEmpty)
    }

    @Test func withoutADeviceRateThePreferredRateIsKept() {
        fake.nominalRate = nil
        let device = makeDevice()
        #expect(device.initializePlayout())
        #expect(device.deviceOutputSampleRate == 48_000)
    }

    // MARK: - Recording

    @Test func successfulRecordingSetupStoresTheUnit() {
        let device = makeDevice()
        #expect(device.initializeRecording())
        #expect(device.initializeRecording())
        #expect(device.isRecordingInitialized)
        #expect(device.hasRecordingUnit)
        #expect(device.hasInputBuffer)
        #expect(device.activeInputDeviceID == FakeAudioHardware.inputDevice)
        #expect(device.deviceInputSampleRate == 44_100)
        #expect(fake.created.count == 1)
        #expect(fake.initializeCalls == 1)
        #expect(fake.maximumBufferQueries == [FakeAudioHardware.inputDevice])
        #expect(log.errors.isEmpty)
    }

    @Test func aFailingRecordingInitializeDisposesTheUnitAndItsBuffer() {
        fake.initializeStatus = kAudioUnitErr_FailedInitialization
        let device = makeDevice()
        #expect(device.initializeRecording() == false)
        #expect(device.isRecordingInitialized == false)
        #expect(device.hasRecordingUnit == false)
        #expect(device.hasInputBuffer == false)
        #expect(device.activeInputDeviceID == nil)
        #expect(fake.disposed == fake.created)
        #expect(device.startRecording() == false)
        #expect(log.errors == ["Audio recording setup failed: AudioUnitInitialize returned -10875 (device 42 \"Fake Microphone\")"])

        fake.initializeStatus = noErr
        #expect(device.initializeRecording())
        #expect(fake.created.count == 2)
        #expect(device.hasRecordingUnit)
        #expect(device.hasInputBuffer)
    }

    @Test(arguments: 0..<5)
    func aFailingRecordingPropertyDisposesTheUnit(failingCall: Int) {
        fake.failingSetPropertyCall = failingCall
        let device = makeDevice()
        #expect(device.initializeRecording() == false)
        #expect(device.hasRecordingUnit == false)
        #expect(device.hasInputBuffer == false)
        #expect(fake.disposed == fake.created)
        #expect(fake.setPropertyCalls.count == failingCall + 1)
        #expect(fake.initializeCalls == 0)
        let steps = ["enable input IO", "disable output IO", "set current device", "set stream format", "set input callback"]
        #expect(log.errors.count == 1)
        #expect(log.errors.first?.hasPrefix("Audio recording setup failed: \(steps[failingCall]) returned") == true)

        fake.failingSetPropertyCall = nil
        #expect(device.initializeRecording())
        #expect(fake.created.count == 2)
    }

    @Test func recordingSetupMakesTheSameCallsAsBefore() throws {
        let device = makeDevice()
        #expect(device.initializeRecording())
        let calls = fake.setPropertyCalls
        try #require(calls.count == 5)
        #expect(calls[0].key == .init(kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, 4))
        #expect(calls[0].word == 1)
        #expect(calls[1].key == .init(kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, 4))
        #expect(calls[1].word == 0)
        #expect(calls[2].key == .init(kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, 4))
        #expect(calls[2].word == FakeAudioHardware.inputDevice)
        #expect(calls[3].key == .init(
            kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        ))
        let format = try #require(calls[3].format)
        #expect(format.mSampleRate == 44_100)
        #expect(format.mChannelsPerFrame == 1)
        #expect(format.mBitsPerChannel == 16)
        #expect(format.mBytesPerFrame == 2)
        #expect(calls[4].key == .init(
            kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        ))
    }

    /// One direction failing leaves the other alone.
    @Test func aFailedRecordingLeavesPlayoutWorking() {
        let device = makeDevice()
        #expect(device.initializePlayout())
        fake.initializeStatus = kAudioUnitErr_FailedInitialization
        #expect(device.initializeRecording() == false)
        #expect(device.hasPlayoutUnit)
        #expect(device.isPlayoutInitialized)
        #expect(fake.liveUnits == [fake.created[0]])
    }

    // MARK: - Terminate

    @Test func terminateReleasesBothUnitsAndAllowsANewSetup() {
        let device = makeDevice()
        #expect(device.initializePlayout())
        #expect(device.initializeRecording())
        #expect(device.startPlayout())
        #expect(device.startRecording())

        #expect(device.terminateDevice())
        #expect(fake.stopCalls == 2)
        #expect(fake.uninitialized.count == 2)
        #expect(Set(fake.disposed) == Set(fake.created))
        #expect(device.hasPlayoutUnit == false)
        #expect(device.hasRecordingUnit == false)
        #expect(device.hasInputBuffer == false)
        #expect(device.isInitialized == false)
        #expect(device.isPlayoutInitialized == false)
        #expect(device.isRecordingInitialized == false)
        #expect(device.isPlaying == false)
        #expect(device.isRecording == false)
        #expect(device.initializePlayout() == false)

        #expect(device.initialize(with: delegate))
        #expect(device.initializePlayout())
        #expect(device.initializeRecording())
        #expect(fake.created.count == 4)
        #expect(fake.liveUnits.count == 2)
    }

    @Test func terminateAfterAFailedSetupDisposesNothingTwice() {
        fake.initializeStatus = kAudioUnitErr_FailedInitialization
        let device = makeDevice()
        #expect(device.initializePlayout() == false)
        #expect(device.initializeRecording() == false)
        #expect(device.terminateDevice())
        #expect(fake.disposed.count == 2)
        #expect(fake.uninitialized.isEmpty)
    }

    // MARK: - Status text

    @Test func statusesPrintAsCoreAudioDocumentsThem() {
        #expect(WebRTCAudioDevice.describe(status: kAudioHardwareBadDeviceError) == "'!dev' (560227702)")
        #expect(WebRTCAudioDevice.describe(status: kAudioUnitErr_FormatNotSupported) == "-10868")
        #expect(WebRTCAudioDevice.describe(status: 0x666D743F) == "'fmt?' (1718449215)")
    }
}

// MARK: - Stand-ins

/// Hardware that hands out made-up unit pointers and records every call made with them. The
/// pointers are never dereferenced or passed to CoreAudio.
final class FakeAudioHardware {
    static let outputDevice: AudioDeviceID = 41
    static let inputDevice: AudioDeviceID = 42

    struct PropertyKey: Equatable {
        let property: AudioUnitPropertyID
        let scope: AudioUnitScope
        let element: AudioUnitElement
        let size: UInt32

        init(_ property: AudioUnitPropertyID, _ scope: AudioUnitScope, _ element: AudioUnitElement, _ size: UInt32) {
            self.property = property
            self.scope = scope
            self.element = element
            self.size = size
        }
    }

    struct PropertyCall {
        let unit: AudioComponentInstance
        let key: PropertyKey
        /// The first four bytes, for the UInt32-valued properties.
        let word: UInt32
        /// The value, when it was a stream format.
        let format: AudioStreamBasicDescription?
    }

    var componentMissing = false
    var instanceNewStatus: OSStatus = noErr
    /// Which `setProperty` call (0-based, counted across the test) fails, if any.
    var failingSetPropertyCall: Int?
    var setPropertyFailure: OSStatus = kAudioUnitErr_InvalidProperty
    var initializeStatus: OSStatus = noErr
    var nominalRate: Double? = 44_100

    private(set) var created: [AudioComponentInstance] = []
    private(set) var disposed: [AudioComponentInstance] = []
    private(set) var uninitialized: [AudioComponentInstance] = []
    private(set) var setPropertyCalls: [PropertyCall] = []
    private(set) var initializeCalls = 0
    private(set) var startCalls = 0
    private(set) var stopCalls = 0
    private(set) var maximumBufferQueries: [AudioDeviceID] = []
    private var nextUnitAddress = 0x1000

    var liveUnits: [AudioComponentInstance] {
        created.filter { !disposed.contains($0) }
    }

    var hardware: AudioUnitHardware {
        AudioUnitHardware(
            resolveDevice: { _, isInput in isInput ? Self.inputDevice : Self.outputDevice },
            nominalSampleRate: { [unowned self] _ in self.nominalRate },
            maximumBufferFrames: { [unowned self] deviceID in
                self.maximumBufferQueries.append(deviceID)
                return 512
            },
            deviceName: { deviceID in deviceID == Self.inputDevice ? "Fake Microphone" : "Fake Speakers" },
            newHALUnit: { [unowned self] in
                if self.componentMissing { return (noErr, nil) }
                if self.instanceNewStatus != noErr { return (self.instanceNewStatus, nil) }
                let unit = AudioComponentInstance(bitPattern: self.nextUnitAddress)!
                self.nextUnitAddress += 0x10
                self.created.append(unit)
                return (noErr, unit)
            },
            setProperty: { [unowned self] unit, property, scope, element, data, size in
                let word = size >= 4 ? data.loadUnaligned(as: UInt32.self) : 0
                let format = size == UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
                    ? data.loadUnaligned(as: AudioStreamBasicDescription.self)
                    : nil
                let index = self.setPropertyCalls.count
                self.setPropertyCalls.append(PropertyCall(
                    unit: unit,
                    key: PropertyKey(property, scope, element, size),
                    word: word,
                    format: format
                ))
                return index == self.failingSetPropertyCall ? self.setPropertyFailure : noErr
            },
            initialize: { [unowned self] _ in
                self.initializeCalls += 1
                return self.initializeStatus
            },
            uninitialize: { [unowned self] unit in
                self.uninitialized.append(unit)
                return noErr
            },
            dispose: { [unowned self] unit in
                #expect(!self.disposed.contains(unit), "unit disposed twice")
                self.disposed.append(unit)
                return noErr
            },
            start: { [unowned self] _ in
                self.startCalls += 1
                return noErr
            },
            stop: { [unowned self] _ in
                self.stopCalls += 1
                return noErr
            }
        )
    }
}

/// What libwebrtc hands the audio device. Only the preferred rates and durations are read during
/// setup; the blocks are never called because no unit ever runs.
final class FakeAudioDeviceDelegate: NSObject, RTCAudioDeviceDelegate {
    var deliverRecordedData: RTCAudioDeviceDeliverRecordedDataBlock {
        { _, _, _, _, _, _, _ in noErr }
    }
    var getPlayoutData: RTCAudioDeviceGetPlayoutDataBlock {
        { _, _, _, _, _ in noErr }
    }
    var preferredInputSampleRate: Double { 48_000 }
    var preferredInputIOBufferDuration: TimeInterval { 0.01 }
    var preferredOutputSampleRate: Double { 48_000 }
    var preferredOutputIOBufferDuration: TimeInterval { 0.01 }
    func notifyAudioInputParametersChange() {}
    func notifyAudioOutputParametersChange() {}
    func notifyAudioInputInterrupted() {}
    func notifyAudioOutputInterrupted() {}
    func dispatchAsync(_ block: @escaping () -> Void) { block() }
    func dispatchSync(_ block: @escaping () -> Void) { block() }
}
