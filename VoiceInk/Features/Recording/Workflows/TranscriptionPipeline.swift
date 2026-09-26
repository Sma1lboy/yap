import Foundation
import SwiftData
import os

/// Handles the full post-recording pipeline:
/// transcribe → filter → format → word-replace → AI enhance → deliver → save
@MainActor
class TranscriptionPipeline {
    struct AssistantHooks {
        let isFollowUp: Bool
        let sendFollowUp: (String, Transcription) async -> Void
        let startResponse: (String, EnhancementRuntimeConfiguration) async -> Void
        let showResponse: (String, String?) async -> Void
        let failResponse: (String) async -> Void

        static let inactive = AssistantHooks(
            isFollowUp: false,
            sendFollowUp: { _, _ in },
            startResponse: { _, _ in },
            showResponse: { _, _ in },
            failResponse: { _ in }
        )
    }

    private let modelContext: ModelContext
    private let serviceRegistry: TranscriptionServiceRegistry
    private let enhancementService: AIEnhancementService?
    private let transcriptionModelManager: TranscriptionModelManager
    private let delivery = TranscriptionDelivery()
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "TranscriptionPipeline")

    init(
        modelContext: ModelContext,
        serviceRegistry: TranscriptionServiceRegistry,
        enhancementService: AIEnhancementService?,
        transcriptionModelManager: TranscriptionModelManager
    ) {
        self.modelContext = modelContext
        self.serviceRegistry = serviceRegistry
        self.enhancementService = enhancementService
        self.transcriptionModelManager = transcriptionModelManager
    }

    /// Run the full pipeline for a given transcription record.
    /// - Parameters:
    ///   - transcription: The pending Transcription SwiftData object to populate and save.
    ///   - audioURL: The recorded audio file.
    ///   - transcriptionConfiguration: Mode-resolved transcription engine settings for this phase.
    ///   - session: An active streaming session if one was prepared, otherwise nil.
    ///   - onStateChange: Called when the pipeline moves to a new recording state (e.g. `.enhancing`).
    ///   - shouldCancel: Returns true if the user requested cancellation.
    ///   - onCancel: Called when cancellation is detected to cancel active session state.
    ///   - onDismiss: Called when delivery should close the recorder panel.
    func run(
        transcription: Transcription,
        audioURL: URL,
        transcriptionConfiguration: TranscriptionRuntimeConfiguration,
        formattingConfiguration resolveFormattingConfiguration: @escaping () -> TranscriptionFormattingConfiguration,
        session: TranscriptionSession?,
        triggerWordModeSelection: @escaping (String) -> String? = { _ in nil },
        enhancementConfiguration: @escaping () -> EnhancementRuntimeConfiguration?,
        recordingContextSnapshot: @escaping () async -> RecordingContextSnapshot? = { nil },
        outputConfiguration: @escaping () -> OutputRuntimeConfiguration,
        sendAfterPaste: Bool = false,
        onStateChange: @escaping (RecordingState) -> Void,
        shouldCancel: () -> Bool,
        onCancel: @escaping () async -> Void,
        onDismiss: @escaping () async -> Void,
        assistant: AssistantHooks = .inactive
    ) async {
        let model = transcriptionConfiguration.model
        var finalText: String?
        var responseError: String?
        var outputForDelivery: OutputRuntimeConfiguration?
        var responseConfig: EnhancementRuntimeConfiguration?
        var transcriptionFailure: String?

        func finishCanceledTranscription() async {
            await onCancel()

            let canceledDuration: TimeInterval?
            if transcription.duration > 0 {
                canceledDuration = nil
            } else {
                let duration = await AudioFileMetadata.duration(for: audioURL)
                canceledDuration = duration > 0 ? duration : nil
            }

            transcription.markAsCanceledTranscription(
                duration: canceledDuration,
                modelName: transcription.transcriptionModelName ?? model.displayName
            )

            do {
                try modelContext.save()
            } catch {
                logger.error("Failed to save canceled transcription: \(error, privacy: .public)")
            }
        }

        if shouldCancel() {
            await finishCanceledTranscription()
            return
        }

        do {
            if let issue = RecordedAudioIssue.check(audioURL) {
                session?.cancel()
                throw issue
            }
            let transcriptionStart = Date()
            var text: String
            if let session {
                text = try await session.transcribe(audioURL: audioURL)
            } else {
                let billed = YapCloud.GenerationCollector()
                text = try await YapCloud.$generationCollector.withValue(billed) {
                    try await serviceRegistry.transcribe(
                        audioURL: audioURL,
                        model: model,
                        context: transcriptionConfiguration.requestContext
                    )
                }
                transcription.yapCloudTranscriptionGenerationID = billed.last
            }
            text = TranscriptionOutputFilter.filter(text)
            let transcriptionDuration = Date().timeIntervalSince(transcriptionStart)

            if shouldCancel() {
                await finishCanceledTranscription()
                return
            }

            text = text.trimmingCharacters(in: .whitespacesAndNewlines)

            if !assistant.isFollowUp,
                let processedText = triggerWordModeSelection(text)
            {
                text = processedText
            }

            let formattingConfiguration = resolveFormattingConfiguration()
            let resolvedEnhancementConfiguration = enhancementConfiguration()
            let resolvedOutputConfiguration = outputConfiguration()
            let modeMetadata = metadata(
                for: formattingConfiguration.mode ?? resolvedEnhancementConfiguration?.mode
                    ?? resolvedOutputConfiguration.mode ?? transcriptionConfiguration.mode
            )

            if formattingConfiguration.isTextFormattingEnabled {
                text = ParagraphFormatter.format(text)
            }

            text = WordReplacementService.shared.applyReplacements(to: text, using: modelContext)
            let cleanedText = text

            let actualDuration = await AudioFileMetadata.duration(for: audioURL)

            transcription.text = cleanedText
            transcription.duration = actualDuration
            transcription.transcriptionModelName = model.displayName
            if model.provider == .yapCloud { transcription.usedYapCloud = true }
            transcription.transcriptionDuration = transcriptionDuration
            transcription.modeName = modeMetadata.name
            transcription.modeEmoji = modeMetadata.emoji
            finalText = cleanedText

            if !assistant.isFollowUp {
                let shouldRespondInRecorder =
                    resolvedOutputConfiguration.outputMode == .respond
                    && resolvedEnhancementConfiguration?.isEnabled == true
                    && resolvedEnhancementConfiguration.map { configuration in
                        enhancementService?.isConfigured(for: configuration) == true
                    } == true
                outputForDelivery = resolvedOutputConfiguration
                responseConfig = shouldRespondInRecorder ? resolvedEnhancementConfiguration : nil

                let isSkipShortEnhancementEnabled = UserDefaults.standard.bool(forKey: "SkipShortEnhancement")
                let savedThreshold = UserDefaults.standard.integer(forKey: "ShortEnhancementWordThreshold")
                let shortEnhancementWordThreshold = savedThreshold > 0 ? savedThreshold : 3
                let contextSnapshot = await recordingContextSnapshot()
                // With selected text captured, a short utterance is an instruction for that text
                // ("make it formal"), not a transcript too short to clean up (upstream #968).
                let hasSelectedTextContext =
                    resolvedEnhancementConfiguration?.useSelectedTextContext == true
                    && contextSnapshot?.selectedText?.isEmpty == false
                let shouldSkipEnhancement =
                    !shouldRespondInRecorder && !hasSelectedTextContext && isSkipShortEnhancementEnabled
                    && WordCounter.count(in: text) <= shortEnhancementWordThreshold

                if let enhancementService,
                    let resolvedEnhancementConfiguration,
                    resolvedEnhancementConfiguration.isEnabled,
                    enhancementService.isConfigured(for: resolvedEnhancementConfiguration),
                    !shouldSkipEnhancement
                {
                    if shouldCancel() {
                        await finishCanceledTranscription()
                        return
                    }

                    onStateChange(.enhancing)
                    let textForAI = text
                    if shouldRespondInRecorder {
                        await assistant.startResponse(textForAI, resolvedEnhancementConfiguration)
                    }

                    do {
                        transcription.aiEnhancementModelName =
                            resolvedEnhancementConfiguration.modelName
                            ?? resolvedEnhancementConfiguration.provider?.defaultModel
                        transcription.promptName = resolvedEnhancementConfiguration.prompt?.title
                        let billed = YapCloud.GenerationCollector()
                        let enhancementResult = try await YapCloud.$generationCollector.withValue(billed) {
                            try await enhancementService.enhance(
                                textForAI,
                                configuration: resolvedEnhancementConfiguration,
                                contextSnapshot: contextSnapshot
                            )
                        }
                        transcription.yapCloudEnhancementGenerationID = billed.last
                        transcription.enhancedText = enhancementResult.text
                        if resolvedEnhancementConfiguration.provider == .yapCloud { transcription.usedYapCloud = true }
                        transcription.promptName =
                            enhancementResult.promptName ?? resolvedEnhancementConfiguration.prompt?.title
                        transcription.enhancementDuration = enhancementResult.duration
                        transcription.aiRequestSystemMessage = enhancementResult.systemMessage
                        transcription.aiRequestUserMessage = enhancementResult.userMessage
                        finalText = enhancementResult.text
                    } catch {
                        let errorDescription = EnhancementFailureFormatter.description(for: error)
                        let failureMessage = EnhancementFailureFormatter.message(description: errorDescription)
                        transcription.enhancedText = failureMessage
                        responseError = errorDescription
                        await MainActor.run {
                            if !YapCloud.notifyIfAccountProblem(error) {
                                NotificationManager.shared.showNotification(
                                    title: failureMessage,
                                    type: .warning
                                )
                            }
                        }
                        if shouldCancel() {
                            await finishCanceledTranscription()
                            return
                        }
                    }
                }
            }

            transcription.transcriptionStatus = TranscriptionStatus.completed.rawValue
        } catch {
            let errorDescription = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            // A Yap Cloud 402/401 gets its own toast (Add Funds / Open Account); a generic one would replace it.
            let didNotifyAccount = YapCloud.notifyIfAccountProblem(error)

            let isHiddenNativeAppleError =
                (error as? NativeAppleTranscriptionService.ServiceError).map { !$0.shouldShowNotification } ?? false
            if let issue = error as? RecordedAudioIssue {
                // Nothing to retry: say what happened instead of showing a provider error.
                NotificationManager.shared.showNotification(
                    title: errorDescription,
                    type: .warning,
                    duration: 5,
                    actionButton: issue == .noSound
                        ? (String(localized: "Audio Settings"), AudioSetupNavigator.openAudioSettings) : nil
                )
            } else if !didNotifyAccount && !(error is CancellationError) && !isHiddenNativeAppleError {
                transcriptionFailure = errorDescription
            }

            transcription.text = String(format: String(localized: "Transcription Failed: %@"), errorDescription)
            transcription.transcriptionStatus = TranscriptionStatus.failed.rawValue
        }

        func saveTranscriptionAndPostCompletion() {
            var didInsertSessionMetric = false

            if transcription.transcriptionStatus == TranscriptionStatus.completed.rawValue {
                do {
                    didInsertSessionMetric = try SessionMetricRecorder.recordRecorderSession(
                        transcription: transcription,
                        model: model,
                        in: modelContext
                    )
                } catch {
                    logger.error("Failed to record session metric: \(error, privacy: .public)")
                }
            }

            do {
                try modelContext.save()
                if didInsertSessionMetric {
                    NotificationCenter.default.post(name: .sessionMetricsDidChange, object: nil)
                }
                NotificationCenter.default.post(name: .transcriptionCompleted, object: transcription)
            } catch {
                logger.error("Failed to save transcription: \(error, privacy: .public)")
            }
        }

        if shouldCancel() {
            await finishCanceledTranscription()
            return
        }

        await delivery.deliver(
            TranscriptionDelivery.Request(
                transcription: transcription,
                text: finalText,
                output: outputForDelivery ?? outputConfiguration(),
                responseConfig: responseConfig,
                responseError: responseError,
                isAssistantFollowUp: assistant.isFollowUp,
                sendAfterPaste: sendAfterPaste
            ),
            actions: TranscriptionDelivery.Actions(
                setState: onStateChange,
                dismiss: onDismiss,
                sendFollowUp: assistant.sendFollowUp,
                showResponse: assistant.showResponse,
                failResponse: assistant.failResponse
            )
        )

        saveTranscriptionAndPostCompletion()

        if let transcriptionFailure {
            showTranscriptionFailure(transcriptionFailure)
        }
    }

    /// The recording stays on disk with the failed History entry, so Retry re-runs it.
    private func showTranscriptionFailure(_ description: String) {
        NotificationManager.shared.showNotification(
            title: String(format: String(localized: "Transcription failed: %@"), description),
            type: .error,
            duration: 10,
            actionButton: (
                String(localized: "Retry"),
                { [self] in
                    LastTranscriptionService.retryLastTranscription(
                        from: modelContext,
                        transcriptionModelManager: transcriptionModelManager,
                        serviceRegistry: serviceRegistry,
                        enhancementService: enhancementService
                    )
                }
            )
        )
    }

    private func metadata(for mode: ModeConfig?) -> (name: String?, emoji: String?) {
        guard let mode, mode.isEnabled else {
            return (nil, nil)
        }

        return (mode.name, mode.icon.value)
    }
}
