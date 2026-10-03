import CoreAudio
import Foundation
import os

struct RecordingDeviceResolution {
    let deviceID: AudioDeviceID?
    let internalMicrophoneBlockedByClosedLid: Bool
    let fellBackFromClosedInternalMicrophone: Bool
    /// Nothing to record from, though inputs are connected that Yap never switches to on its own (virtual, aggregate,
    /// unknown transport); the user can still choose one.
    let onlyUnchosenInputsLeft: Bool
}

struct RecordingDeviceSession {
    var isActive = false
    var activeDeviceID: AudioDeviceID?
    var isDeviceChangePending = false
}

enum RecordingDeviceChangeReason: Equatable {
    case closedLid
    case deviceUnavailable
}

struct RecordingDeviceChangeRequest {
    let fallbackDeviceID: AudioDeviceID?
    let reason: RecordingDeviceChangeReason
    let onlyUnchosenInputsLeft: Bool
}

extension AudioDeviceManager {
    func setupRecordingDeviceRouting() {
        clamshellStateMonitor = ClamshellStateMonitor { [weak self] isClosed in
            self?.handleClamshellChange(isClosed: isClosed)
        }
    }

    func beginRecordingSetup(deviceID: AudioDeviceID) {
        recordingDeviceSession.isActive = true
        recordingDeviceSession.activeDeviceID = deviceID
    }

    func recordingDidStart(deviceID: AudioDeviceID) {
        recordingDeviceSession.isActive = true
        recordingDeviceSession.activeDeviceID = deviceID
    }

    func recordingDeviceChangeFinished(activeDeviceID: AudioDeviceID? = nil) {
        if let activeDeviceID {
            recordingDeviceSession.activeDeviceID = activeDeviceID
        }
        recordingDeviceSession.isDeviceChangePending = false
    }

    func recordingDidStop() {
        recordingDeviceSession = RecordingDeviceSession()
    }

    /// What a recording uses: the user's choice for the mode (custom device, priority list, or the system default,
    /// whatever kind of input it is), else an automatic fallback (`fallbackRecordingDeviceIDs`), never one that's
    /// excluded or blocked by a closed lid.
    func resolveCurrentRecordingDevice(
        excluding excludedDeviceID: AudioDeviceID? = nil
    ) -> RecordingDeviceResolution {
        let preferredCandidates = preferredRecordingDeviceIDs()
        let preferredAvailableDevice = preferredCandidates.first(where: isOperationalInputDevice)

        var seen = Set<AudioDeviceID>()
        let candidates = (preferredCandidates + fallbackRecordingDeviceIDs()).filter { deviceID in
            guard deviceID != excludedDeviceID else { return false }
            return seen.insert(deviceID).inserted
        }
        let resolvedDeviceID = candidates.first(where: isDeviceUsableForRecording)
        let remaining = availableDevices.map(\.id).filter { $0 != excludedDeviceID }
        // The closed lid is why: the chosen device is the internal microphone, or nothing is left but it.
        let internalMicrophoneBlockedByClosedLid = isClamshellClosed
            && (preferredAvailableDevice.map(isInternalMicrophone) == true
                || (resolvedDeviceID == nil && remaining.contains(where: isInternalMicrophone)))

        return RecordingDeviceResolution(
            deviceID: resolvedDeviceID,
            internalMicrophoneBlockedByClosedLid: internalMicrophoneBlockedByClosedLid,
            fellBackFromClosedInternalMicrophone: internalMicrophoneBlockedByClosedLid
                && resolvedDeviceID != nil && resolvedDeviceID != preferredAvailableDevice,
            onlyUnchosenInputsLeft: resolvedDeviceID == nil && remaining.contains { !isAutomaticFallbackInput($0) }
        )
    }

    func getCurrentDevice() -> AudioDeviceID {
        resolveCurrentRecordingDevice().deviceID ?? 0
    }

    /// Selected Microphone mode: the connected device the user chose, which Audio Settings' menu shows. nil when it
    /// isn't connected or nothing was chosen; `selectedDeviceID` is then a fallback (or nil), not a choice.
    var chosenCustomDeviceUID: String? {
        guard !selectedDeviceIsFallback, let selectedDeviceID else { return nil }
        return availableDevices.first { $0.id == selectedDeviceID }?.uid
    }

    func findBestAvailableDevice() -> AudioDeviceID? {
        fallbackRecordingDeviceIDs().first(where: isDeviceUsableForRecording)
    }

    func isDeviceUsableForRecording(_ deviceID: AudioDeviceID) -> Bool {
        isOperationalInputDevice(deviceID)
            && !(isClamshellClosed && isInternalMicrophone(deviceID))
    }

    /// Whether Yap may record from this input without the user having chosen it, when their choice isn't there.
    /// Every transport except: virtual (BlackHole, Loopback, a meeting app's own), aggregate and auto-aggregate (Yap's
    /// private system-audio tap during a meeting is one), which carry other sounds than the user's voice, and unknown
    /// or unreported, which can't be told apart from them. Any other transport counts, including ones Core Audio adds
    /// later. Decided by transport type, not by name; a virtual driver that reports a physical transport isn't caught.
    func isAutomaticFallbackInput(_ deviceID: AudioDeviceID) -> Bool {
        Self.isAutomaticFallbackTransport(
            getUInt32DeviceProperty(deviceID: deviceID, selector: kAudioDevicePropertyTransportType))
    }

    static func isAutomaticFallbackTransport(_ transport: UInt32?) -> Bool {
        switch transport {
        case nil, kAudioDeviceTransportTypeUnknown, kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate,
            kAudioDeviceTransportTypeAutoAggregate:
            return false
        default:
            return true
        }
    }

    private func preferredRecordingDeviceIDs() -> [AudioDeviceID] {
        switch inputMode {
        case .systemDefault:
            return getSystemDefaultDevice().map { [$0] } ?? []
        case .custom:
            let savedUID = UserDefaults.standard.selectedAudioDeviceUID ?? ""
            let savedModelUID = UserDefaults.standard.selectedAudioDeviceModelUID
            var candidates = findAvailableDevice(uid: savedUID, modelUID: savedModelUID).map { [$0.id] } ?? []
            // A device picked by fallback isn't a choice: it stays subject to the fallback rules.
            if let selectedDeviceID, !selectedDeviceIsFallback, !candidates.contains(selectedDeviceID) {
                candidates.append(selectedDeviceID)
            }
            return candidates
        case .prioritized:
            return prioritizedDevices.sorted { $0.priority < $1.priority }.compactMap { device in
                findAvailableDevice(uid: device.id, modelUID: device.modelUID)?.id
            }
        }
    }

    /// Inputs Yap may switch to on its own, built-in microphone first (last with the lid closed).
    private func fallbackRecordingDeviceIDs() -> [AudioDeviceID] {
        let allowed = availableDevices.map(\.id).filter(isAutomaticFallbackInput)
        let internalMicrophones = allowed.filter(isInternalMicrophone)
        let otherInputs = allowed.filter { !isInternalMicrophone($0) }
        return isClamshellClosed ? otherInputs + internalMicrophones : internalMicrophones + otherInputs
    }

    func isOperationalInputDevice(_ deviceID: AudioDeviceID) -> Bool {
        availableDevices.contains { $0.id == deviceID }
    }

    private func handleClamshellChange(isClosed: Bool) {
        logger.notice("Clamshell state changed: \(isClosed ? "closed" : "open", privacy: .public)")

        guard isRecordingActive else {
            notifyDeviceChange()
            return
        }
        guard isClosed,
            let activeRecordingDeviceID,
            isInternalMicrophone(activeRecordingDeviceID)
        else {
            return
        }

        requestRecordingDeviceChange(reason: .closedLid)
    }

    func requestRecordingDeviceChange(reason: RecordingDeviceChangeReason) {
        guard let activeDeviceID = activeRecordingDeviceID,
            !recordingDeviceSession.isDeviceChangePending
        else {
            return
        }

        recordingDeviceSession.isDeviceChangePending = true
        let resolution = resolveCurrentRecordingDevice(excluding: activeDeviceID)
        let request = RecordingDeviceChangeRequest(
            fallbackDeviceID: resolution.deviceID,
            reason: reason,
            onlyUnchosenInputsLeft: resolution.onlyUnchosenInputsLeft
        )
        NotificationCenter.default.post(
            name: .recordingDeviceChangeRequired,
            object: request
        )
    }
}

#if DEBUG
    extension AudioDeviceManager {
        /// Which transports Yap falls back to on its own. The selection around it is checked on device lists by
        /// make mic-fallback-check.
        static func fallbackSelfCheck() {
            for physical in [kAudioDeviceTransportTypeBuiltIn, kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeBluetooth,
                kAudioDeviceTransportTypeBluetoothLE, kAudioDeviceTransportTypeThunderbolt, kAudioDeviceTransportTypePCI,
                kAudioDeviceTransportTypeFireWire, kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort,
                kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless] {
                assert(isAutomaticFallbackTransport(physical), "\(physical)")
            }
            for unchosen in [kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate,
                kAudioDeviceTransportTypeAutoAggregate, kAudioDeviceTransportTypeUnknown] {
                assert(!isAutomaticFallbackTransport(unchosen), "\(unchosen)")
            }
            assert(!isAutomaticFallbackTransport(nil), "a device that doesn't say isn't a fallback")
        }
    }
#endif
