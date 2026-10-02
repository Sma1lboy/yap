import Foundation

struct AudioInputFailurePresentation {
    let title: String
    let actionLabel: String
    let action: () -> Void

    /// A closed lid comes first (opening it is the quickest way back); else, when only inputs Yap doesn't switch to
    /// on its own are connected (virtual, aggregate), it says so, since they're still in the input list.
    @MainActor
    static func noUsableMicrophone(
        internalMicrophoneBlockedByClosedLid: Bool, onlyUnchosenInputsLeft: Bool
    ) -> AudioInputFailurePresentation {
        let title: String
        if internalMicrophoneBlockedByClosedLid {
            title = String(localized: "No usable microphone is available. Open the lid or connect an external microphone.")
        } else if onlyUnchosenInputsLeft {
            title = String(localized: "Your microphone isn't connected, and Yap doesn't switch to a virtual or aggregate input you haven't chosen. Choose a microphone in Audio Settings.")
        } else {
            title = String(localized: "No usable microphone is available. Choose a microphone in Audio Settings.")
        }

        return AudioInputFailurePresentation(
            title: title,
            actionLabel: String(localized: "Audio Settings"),
            action: AudioSetupNavigator.openAudioSettings
        )
    }
}

extension VoiceInkEngine {
    @MainActor
    func recordingAudioFailure(
        for error: Error
    ) -> (title: String, actionLabel: String, action: () -> Void)? {
        guard let recorderError = error as? Recorder.RecorderError,
            case .noUsableMicrophone(let internalMicrophoneBlockedByClosedLid, let onlyUnchosenInputsLeft) = recorderError
        else {
            return nil
        }

        let presentation = AudioInputFailurePresentation.noUsableMicrophone(
            internalMicrophoneBlockedByClosedLid: internalMicrophoneBlockedByClosedLid,
            onlyUnchosenInputsLeft: onlyUnchosenInputsLeft
        )
        return (presentation.title, presentation.actionLabel, presentation.action)
    }
}
