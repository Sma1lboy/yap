import Foundation
import os

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

    @MainActor
    static func audioSystemNotRunning() -> AudioInputFailurePresentation {
        AudioInputFailurePresentation(
            title: String(localized: "macOS audio stopped responding. Restart audio, then try recording again."),
            actionLabel: String(localized: "Restart Audio"),
            action: restartCoreAudio
        )
    }

    private static let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "AudioInputFailure")

    private static func restartCoreAudio() {
        let prompt = String(localized: "Yap needs to restart macOS audio. Sound in all apps will cut out for a moment.")
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e", "do shell script \"killall coreaudiod\" with administrator privileges with prompt \"\(prompt)\"",
        ]
        process.terminationHandler = { process in
            guard process.terminationStatus != 0 else { return }
            logger.error("Restarting coreaudiod failed or was cancelled, osascript exit \(process.terminationStatus, privacy: .public)")
        }
        do {
            try process.run()
        } catch {
            logger.error("Could not launch osascript to restart coreaudiod: \(error, privacy: .public)")
        }
    }
}

extension VoiceInkEngine {
    @MainActor
    func recordingAudioFailure(
        for error: Error
    ) -> (title: String, actionLabel: String, action: () -> Void)? {
        guard let recorderError = error as? Recorder.RecorderError else {
            return nil
        }

        let presentation: AudioInputFailurePresentation
        switch recorderError {
        case .noUsableMicrophone(let internalMicrophoneBlockedByClosedLid, let onlyUnchosenInputsLeft):
            presentation = .noUsableMicrophone(
                internalMicrophoneBlockedByClosedLid: internalMicrophoneBlockedByClosedLid,
                onlyUnchosenInputsLeft: onlyUnchosenInputsLeft
            )
        case .audioSystemNotRunning:
            presentation = .audioSystemNotRunning()
        case .couldNotStartRecording:
            return nil
        }
        return (presentation.title, presentation.actionLabel, presentation.action)
    }
}
