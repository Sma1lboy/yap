import AppKit
import Foundation
import SwiftData

class LastTranscriptionService: ObservableObject {

    static func getLastTranscription(from modelContext: ModelContext) -> Transcription? {
        var descriptor = FetchDescriptor<Transcription>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = 1

        do {
            let transcriptions = try modelContext.fetch(descriptor)
            return transcriptions.first
        } catch {
            print("Error fetching last transcription: \(error)")
            return nil
        }
    }

    static func copyLastTranscription(from modelContext: ModelContext) {
        guard let lastTranscription = getLastTranscription(from: modelContext) else {
            Task { @MainActor in
                NotificationManager.shared.showNotification(
                    title: String(localized: "No transcription available"),
                    type: .error
                )
            }
            return
        }

        // Prefer enhanced text; fallback to original text
        let textToCopy: String = {
            if let enhancedText = lastTranscription.enhancedText, !enhancedText.isEmpty {
                return enhancedText
            } else {
                return lastTranscription.text
            }
        }()

        let success = ClipboardManager.copyToClipboard(textToCopy)

        Task { @MainActor in
            if success {
                NotificationManager.shared.showNotification(
                    title: String(localized: "Last transcription copied"),
                    type: .success
                )
            } else {
                NotificationManager.shared.showNotification(
                    title: String(localized: "Failed to copy transcription"),
                    type: .error
                )
            }
        }
    }

    @MainActor
    static func pasteLastTranscription(from modelContext: ModelContext) {
        guard let lastTranscription = getLastTranscription(from: modelContext) else {
            Task { @MainActor in
                NotificationManager.shared.showNotification(
                    title: String(localized: "No transcription available"),
                    type: .error
                )
            }
            return
        }

        CursorPaster.paste(lastTranscription.text, into: pasteTarget(), activate: false, hold: shortcutHold)
    }

    @MainActor
    static func pasteLastEnhancement(from modelContext: ModelContext) {
        guard let lastTranscription = getLastTranscription(from: modelContext) else {
            Task { @MainActor in
                NotificationManager.shared.showNotification(
                    title: String(localized: "No transcription available"),
                    type: .error
                )
            }
            return
        }

        // Prefer enhanced text; if unavailable, fallback to original text (which may contain an error message)
        let textToPaste: String = {
            if let enhancedText = lastTranscription.enhancedText, !enhancedText.isEmpty {
                return enhancedText
            } else {
                return lastTranscription.text
            }
        }()

        CursorPaster.paste(textToPaste, into: pasteTarget(), activate: false, hold: shortcutHold)
    }

    /// The 0.15 s Paste Last always waited before pasting: its shortcut's keys coming up.
    private static let shortcutHold: TimeInterval = 0.15

    /// The app in front when the shortcut was pressed, Yap itself included: the paste goes there or nowhere.
    private static func pasteTarget() -> pid_t? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    static func retryLastTranscription(
        from modelContext: ModelContext, transcriptionModelManager: TranscriptionModelManager,
        serviceRegistry: TranscriptionServiceRegistry, enhancementService: AIEnhancementService?
    ) {
        Task { @MainActor in
            guard let lastTranscription = getLastTranscription(from: modelContext),
                let audioURLString = lastTranscription.audioFileURL,
                let audioURL = URL(string: audioURLString),
                FileManager.default.fileExists(atPath: audioURL.path)
            else {
                NotificationManager.shared.showNotification(
                    title: String(localized: "Cannot retry: Audio file not found"),
                    type: .error
                )
                return
            }

            guard
                let transcriptionConfiguration = ModeRuntimeResolver.transcriptionConfiguration(
                    transcriptionModelManager: transcriptionModelManager
                )
            else {
                NotificationManager.shared.showNotification(
                    title: String(localized: "No transcription model selected"),
                    type: .error
                )
                return
            }

            let transcriptionService = AudioTranscriptionService(
                modelContext: modelContext,
                serviceRegistry: serviceRegistry,
                enhancementService: enhancementService
            )
            do {
                let result = try await transcriptionService.retranscribeAudio(
                    from: audioURL,
                    using: transcriptionConfiguration.model
                )
                let newTranscription = result.transcription

                let textToCopy =
                    result.enhancementFailure == nil && newTranscription.enhancedText?.isEmpty == false
                    ? newTranscription.enhancedText! : newTranscription.text
                _ = ClipboardManager.copyToClipboard(textToCopy)

                if let enhancementFailure = result.enhancementFailure {
                    NotificationManager.shared.showNotification(
                        title: EnhancementFailureFormatter.transcriptionSavedMessage(
                            description: enhancementFailure
                        ),
                        type: .warning
                    )
                } else {
                    NotificationManager.shared.showNotification(
                        title: String(localized: "Copied to clipboard"),
                        type: .success
                    )
                }
            } catch {
                NotificationManager.shared.showNotification(
                    title: String(format: String(localized: "Retry failed: %@"), error.localizedDescription),
                    type: .error
                )
            }
        }
    }
}
