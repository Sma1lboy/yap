import AVFoundation
import AudioToolbox
import CoreAudio
import os

/// What every other app plays (the other side of a call), as 16 kHz mono Int16 samples. A Core Audio process tap
/// on all processes except Yap (macOS 14.2+) inside a private aggregate device, read with an IOProc; nothing
/// about the user's output device changes. Needs "System Audio Recording Only" (NSAudioCaptureUsageDescription):
/// macOS asks when the tap is first used, and there's no API to ask whether it was granted. When it's denied the
/// tap still runs but delivers only zeros, which MeetingRecorder notices. When the output device changes
/// (AirPods connect) the aggregate device is rebuilt around the new one.
final class SystemAudioTap: @unchecked Sendable {
    enum TapError: LocalizedError {
        case coreAudio(String, OSStatus)
        var errorDescription: String? {
            switch self {
            case .coreAudio(let step, let status): return "\(step) failed (\(status))"
            }
        }
    }

    /// 16 kHz mono PCM16, from the tap's IO queue.
    var onSamples: (([Int16]) -> Void)?

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "SystemAudioTap")
    private let queue = DispatchQueue(label: "me.sma1lboy.yap.meeting.system-audio", qos: .userInitiated)
    private let resampler = PCMResampler()
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var format = AudioStreamBasicDescription()
    private var outputListener: AudioObjectPropertyListenerBlock?

    func start() throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: Self.ownProcessObject().map { [$0] } ?? [])
        description.name = "Yap meeting"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try check("AudioHardwareCreateProcessTap", AudioHardwareCreateProcessTap(description, &tapID))
        format = try Self.property(tapID, kAudioTapPropertyFormat, AudioStreamBasicDescription())
        try startAggregate(tapUID: description.uuid.uuidString)
        listenForOutputChanges(tapUID: description.uuid.uuidString)
    }

    func stop() {
        if let outputListener {
            var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, outputListener)
            self.outputListener = nil
        }
        stopAggregate()
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        queue.sync {
            if let tail = resampler.flush() { deliver(tail) }
        }
    }

    // MARK: - Aggregate device

    private func startAggregate(tapUID: String) throws {
        let outputID = try Self.property(
            AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, AudioObjectID(0))
        let outputUID = try Self.property(outputID, kAudioDevicePropertyDeviceUID, "" as CFString) as String
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Yap Meeting Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: tapUID]],
        ]
        try check("AudioHardwareCreateAggregateDevice",
            AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID))
        try check("AudioDeviceCreateIOProcIDWithBlock",
            AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) { [weak self] _, input, _, _, _ in
                self?.handle(input)
            })
        try check("AudioDeviceStart", AudioDeviceStart(aggregateID, ioProcID))
        logger.notice("System audio tap running on output \(outputUID, privacy: .public), \(self.format.mSampleRate, privacy: .public) Hz")
    }

    private func stopAggregate() {
        guard aggregateID != kAudioObjectUnknown else { return }
        if let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            self.ioProcID = nil
        }
        AudioHardwareDestroyAggregateDevice(aggregateID)
        aggregateID = AudioObjectID(kAudioObjectUnknown)
    }

    /// AirPods connecting or the user picking another output: the aggregate device follows the new default output.
    /// The samples missing during the switch are filled in by MeetingRecorder, which keeps both channels on the
    /// wall clock.
    private func listenForOutputChanges(tapUID: String) {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.tapID != kAudioObjectUnknown else { return }
            self.logger.notice("Default output changed; rebuilding the system audio tap")
            self.stopAggregate()
            do { try self.startAggregate(tapUID: tapUID) } catch {
                self.logger.error("Rebuilding the system audio tap failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
        outputListener = listener
    }

    // MARK: - Samples

    private func handle(_ input: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = buffers.first, let data = first.mData, format.mSampleRate > 0 else { return }
        // The tap delivers Float32; interleaved buffers carry all channels, otherwise the first channel is used.
        let channels = max(1, first.mNumberChannels)
        let frames = UInt32(first.mDataByteSize) / (4 * channels)
        guard frames > 0,
            let converted = resampler.process(
                data.assumingMemoryBound(to: Float32.self), frameCount: frames, channels: channels,
                sampleRate: format.mSampleRate)
        else { return }
        deliver(converted)
    }

    private func deliver(_ buffer: AVAudioPCMBuffer) {
        guard let pointer = buffer.int16ChannelData?[0], buffer.frameLength > 0 else { return }
        onSamples?(Array(UnsafeBufferPointer(start: pointer, count: Int(buffer.frameLength))))
    }

    // MARK: - Core Audio helpers

    private func check(_ step: String, _ status: OSStatus) throws {
        guard status == noErr else {
            logger.error("\(step, privacy: .public) failed: \(status, privacy: .public)")
            throw TapError.coreAudio(step, status)
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private static func property<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T) throws -> T {
        var address = address(selector)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0) }
        guard status == noErr else { throw TapError.coreAudio("AudioObjectGetPropertyData(\(selector))", status) }
        return value
    }

    /// Yap's own Core Audio process object, so the tap leaves out Yap's sounds.
    private static func ownProcessObject() -> AudioObjectID? {
        var address = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = getpid()
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }
}
