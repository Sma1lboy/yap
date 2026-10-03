import AppKit
import Foundation
import os

@MainActor
final class TranscriptionDelivery {
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "TranscriptionDelivery")

    struct Request {
        let transcription: Transcription
        let text: String?
        let output: OutputRuntimeConfiguration
        let responseConfig: EnhancementRuntimeConfiguration?
        let responseError: String?
        let isAssistantFollowUp: Bool
        let sendAfterPaste: Bool
        let timeline: DictationTimeline?
    }

    struct Actions {
        let setState: (RecordingState) -> Void
        let dismiss: () async -> Void
        let sendFollowUp: (String, Transcription) async -> Void
        let showResponse: (String, String?) async -> Void
        let failResponse: (String) async -> Void
    }

    /// Returns, for a paste, the task that finishes once the paste has sent ⌘V or failed; the request's timeline has
    /// its paste time and outcome by then.
    @discardableResult
    func deliver(_ request: Request, actions: Actions) async -> Task<Void, Never>? {
        guard request.transcription.transcriptionStatus == TranscriptionStatus.completed.rawValue else {
            await actions.dismiss()
            return nil
        }

        if request.isAssistantFollowUp {
            await deliverFollowUp(request, actions: actions)
            return nil
        }

        if request.output.outputMode == .respond,
            request.responseConfig != nil || request.responseError != nil
        {
            await deliverResponse(request, actions: actions)
            return nil
        }

        if request.output.outputMode == .customCommand {
            await deliverCustomCommand(request, actions: actions)
            return nil
        }

        // "Scratch that" / 删掉刚才那句 on its own takes back the last paste (checked before cleanup reworded it).
        if LastPasteEditor.isScratchPhrase(request.transcription.text) || request.text.map(LastPasteEditor.isScratchPhrase) == true {
            SoundManager.shared.playStopSound()
            await actions.dismiss()
            await LastPasteEditor.shared.undoLastPaste()
            return nil
        }

        if let text = request.text {
            return await paste(
                text, dictationID: request.transcription.id, sendAfterPaste: request.sendAfterPaste,
                timeline: request.timeline, actions: actions)
        } else {
            await actions.dismiss()
            return nil
        }
    }

    private func deliverFollowUp(_ item: Request, actions: Actions) async {
        SoundManager.shared.playStopSound()

        guard let text = item.text?.trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
        else {
            return
        }

        actions.setState(.enhancing)
        await actions.sendFollowUp(text, item.transcription)
    }

    private func deliverResponse(_ item: Request, actions: Actions) async {
        SoundManager.shared.playStopSound()

        if let responseError = item.responseError {
            await actions.failResponse(EnhancementFailureFormatter.message(description: responseError))
        } else if let text = item.text,
            item.responseConfig != nil
        {
            await actions.showResponse(text, item.transcription.aiRequestSystemMessage)
        } else {
            await actions.failResponse("No response was generated.")
        }
    }

    private func deliverCustomCommand(_ item: Request, actions: Actions) async {
        guard let text = item.text else {
            notifyCustomCommandFailure(CustomCommandDeliveryError.noTextToDeliver)
            SoundManager.shared.playStopSound()
            await actions.dismiss()
            return
        }

        guard let customCommand = item.output.customCommand,
            let command = customCommand.trimmedCommand
        else {
            notifyCustomCommandFailure(CustomCommandDeliveryError.commandNotConfigured)
            SoundManager.shared.playStopSound()
            await actions.dismiss()
            return
        }

        let commandText = text
        SoundManager.shared.playStopSound()
        await actions.dismiss()

        Task {
            await runCustomCommand(command: command, commandText: commandText)
        }
    }

    private func runCustomCommand(command: String, commandText: String) async {
        let startTime = Date()
        logger.notice("Custom command started")

        do {
            let result = try await CustomCommandDeliveryRunner.run(
                command: command,
                timeout: 10,
                context: CustomCommandDeliveryContext(transcript: commandText)
            )

            let duration = Date().timeIntervalSince(startTime)
            let stdoutBytes = result.stdout.utf8.count
            let stderrBytes = result.stderr.utf8.count

            if !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                logger.notice(
                    "Custom command stdout bytes=\(stdoutBytes, privacy: .public): \(result.stdout, privacy: .public)")
            }

            if !result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                logger.notice(
                    "Custom command succeeded with stderr duration=\(Self.formattedDuration(duration), privacy: .public)s stdoutBytes=\(stdoutBytes, privacy: .public) stderrBytes=\(stderrBytes, privacy: .public): \(result.stderr, privacy: .public)"
                )
            } else {
                logger.notice(
                    "Custom command succeeded duration=\(Self.formattedDuration(duration), privacy: .public)s stdoutBytes=\(stdoutBytes, privacy: .public) stderrBytes=\(stderrBytes, privacy: .public)"
                )
            }
        } catch {
            notifyCustomCommandFailure(error, duration: Date().timeIntervalSince(startTime))
        }
    }

    private func notifyCustomCommandFailure(_ error: Error, duration: TimeInterval? = nil) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        if let duration {
            logger.error(
                "Custom command failed duration=\(Self.formattedDuration(duration), privacy: .public)s: \(message, privacy: .public)"
            )
        } else {
            logger.error("Custom command failed: \(message, privacy: .public)")
        }
        NotificationManager.shared.showNotification(
            title: message,
            type: .error,
            duration: 7,
            actionButton: (String(localized: "Manage Modes"), ModeSetupNavigator.openModesSettings)
        )
    }

    private static func formattedDuration(_ duration: TimeInterval) -> String {
        String(format: "%.3f", duration)
    }

    private func paste(
        _ text: String, dictationID: UUID, sendAfterPaste: Bool, timeline: DictationTimeline?, actions: Actions
    ) async -> Task<Void, Never> {
        let textToPaste = text
        let appendSpace = UserDefaults.standard.bool(forKey: "AppendTrailingSpace")
        let pastedText = textToPaste + (appendSpace ? " " : "")
        SoundManager.shared.playStopSound()
        // Read before the recorder is dismissed: a Yap window with keyboard focus (the recorder clicked during the
        // recording, or Yap's own window in front) means focus has to come back before ⌘V.
        let lead = timeline?.stop.source.pasteLead(yapWindowIsKey: NSApp.keyWindow != nil) ?? .other
        await actions.dismiss()

        let pasteTask = CursorPaster.startPasteAtCursor(pastedText, lead: lead, dictationID: dictationID)

        let selectedKey = FinishAndSendSettings.selectedKey
        let finishAndSendKey: FinishAndSendKey = sendAfterPaste ? selectedKey : .none
        return Task { @MainActor in
            let pasteOutcome = await pasteTask.value
            timeline?.pasteFinished(pasteOutcome.result.timelineOutcome, commandAt: pasteOutcome.commandTime)
            if pasteOutcome.result.didPostPasteCommand { DictationAnnouncer.pasted() }

            if finishAndSendKey.isEnabled && pasteOutcome.result.didPostPasteCommand {
                try? await Task.sleep(nanoseconds: 150_000_000)
                if let generation = pasteOutcome.autoLearnGeneration {
                    await AutoLearnService.shared.cancelForAutoSend(generation: generation)
                }
                CursorPaster.performSendKey(finishAndSendKey)
            }
        }
    }
}

extension CursorPaster.PasteResult {
    fileprivate var timelineOutcome: DictationTimeline.PasteOutcome {
        switch self {
        case .commandPosted: return .pasted
        case .leftOnClipboard: return .clipboardOnly
        case .sentToScratchpad: return .scratchpad
        case .commandNotPosted: return .failed
        case .clipboardChanged: return .clipboardChanged
        }
    }
}

extension DictationTimeline.StopSource {
    /// A stop with the keyboard shortcut leaves focus in the app in front, unless a Yap window had it; a click in Yap's
    /// recorder or menu bar may have moved it. `file` is `make dictation-latency`, which measures the shortcut path
    /// into another app (the mock app's own window doesn't count).
    fileprivate func pasteLead(yapWindowIsKey: Bool) -> CursorPaster.Lead {
        switch self {
        case .file: return .shortcut
        case .shortcutRelease, .shortcutPress: return yapWindowIsKey ? .other : .shortcut
        case .recorderButton, .finishAndSend, .other: return .other
        }
    }
}

#if DEBUG
    extension TranscriptionDelivery {
        static func selfCheck() {
            for source in [DictationTimeline.StopSource.shortcutRelease, .shortcutPress] {
                assert(source.pasteLead(yapWindowIsKey: false) == .shortcut)
                assert(source.pasteLead(yapWindowIsKey: true) == .other, "focus has to come back from Yap first")
            }
            for source in [DictationTimeline.StopSource.recorderButton, .finishAndSend, .other] {
                assert(source.pasteLead(yapWindowIsKey: false) == .other, "a click may have moved focus")
            }
        }
    }
#endif
