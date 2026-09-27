import Foundation
import os

/// Encapsulates a single recording-to-transcription lifecycle (streaming or file-based).
@MainActor
protocol TranscriptionSession: AnyObject {
    /// Prepares the session. Returns an audio chunk callback for streaming, or nil for file-based.
    func prepare(configuration: TranscriptionRuntimeConfiguration) async throws -> ((Data) -> Void)?

    /// Called after recording stops. Returns the final transcribed text.
    func transcribe(audioURL: URL) async throws -> String

    /// Cancel the session and clean up resources.
    func cancel()
}

// MARK: - File-Based Session

/// File-based session: records to file, uploads after stop.
@MainActor
final class FileTranscriptionSession: TranscriptionSession {
    private let service: TranscriptionService
    private var model: (any TranscriptionModel)?
    private var context: TranscriptionRequestContext = .currentDefaults

    init(service: TranscriptionService) {
        self.service = service
    }

    func prepare(configuration: TranscriptionRuntimeConfiguration) async throws -> ((Data) -> Void)? {
        self.model = configuration.model
        self.context = configuration.requestContext.scoped(to: configuration.model)
        return nil
    }

    func transcribe(audioURL: URL) async throws -> String {
        guard let model = model else {
            throw VoiceInkEngineError.transcriptionFailed
        }
        return try await service.transcribe(audioURL: audioURL, model: model, context: context)
    }

    func cancel() {
        // No-op for file-based transcription
    }
}

// MARK: - Streaming Session

/// Streaming session with automatic fallback to file-based upload on failure.
@MainActor
final class StreamingTranscriptionSession: TranscriptionSession {
    private let streamingService: StreamingTranscriptionService
    private let fallbackService: TranscriptionService
    private var model: (any TranscriptionModel)?
    private var context: TranscriptionRequestContext = .currentDefaults
    private var streamingFailed = false
    private var startupTask: Task<Void, Never>?
    private var startupTaskID: UUID?
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "StreamingTranscriptionSession")

    init(streamingService: StreamingTranscriptionService, fallbackService: TranscriptionService) {
        self.streamingService = streamingService
        self.fallbackService = fallbackService
    }

    func prepare(configuration: TranscriptionRuntimeConfiguration) async throws -> ((Data) -> Void)? {
        let model = configuration.model
        let context = configuration.requestContext.scoped(to: model)

        self.model = model
        self.context = context
        logger.notice("Streaming session prepare model=\(model.displayName, privacy: .public)")

        // Return callback immediately; WebSocket connects in background
        let service = streamingService
        let callback: (Data) -> Void = { [weak service] data in
            service?.sendAudioChunk(data)
        }

        startupTask?.cancel()
        let taskID = UUID()
        startupTaskID = taskID
        startupTask = Task { [weak self] in
            guard let self = self else { return }
            defer {
                if self.startupTaskID == taskID {
                    self.startupTask = nil
                    self.startupTaskID = nil
                }
            }
            guard !Task.isCancelled else { return }

            do {
                let start = Date()
                try await self.streamingService.startStreaming(model: model, context: context)
                guard !Task.isCancelled else {
                    self.streamingService.cancel()
                    return
                }
                self.logger.notice(
                    "Streaming session connected model=\(model.displayName, privacy: .public) elapsed=\(Date().timeIntervalSince(start), format: .fixed(precision: 3), privacy: .public)s"
                )
            } catch is CancellationError {
                self.streamingService.cancel()
            } catch {
                guard !Task.isCancelled else { return }
                let desc = error.localizedDescription
                self.logger.error("❌ Failed to start streaming, will fall back to batch: \(desc, privacy: .public)")
                self.streamingFailed = true
            }
        }

        return callback
    }

    func transcribe(audioURL: URL) async throws -> String {
        guard let model = model else {
            throw VoiceInkEngineError.transcriptionFailed
        }

        if !streamingFailed {
            do {
                let start = Date()
                logger.notice("Streaming stop/transcribe started model=\(model.displayName, privacy: .public)")
                let result = try await streamingService.stopAndFinalize()
                switch result {
                case .finalized(let text):
                    logger.notice(
                        "Streaming transcript received elapsed=\(Date().timeIntervalSince(start), format: .fixed(precision: 3), privacy: .public)s chars=\(text.count, privacy: .public)"
                    )
                    return text
                case .requiresBatchFallback:
                    logger.notice("Streaming provider requested full batch transcription")
                }
            } catch {
                logger.error("❌ Streaming failed, falling back to batch: \(error, privacy: .public)")
                startupTask?.cancel()
                startupTask = nil
                startupTaskID = nil
                streamingService.cancel()
            }
        } else {
            startupTask?.cancel()
            startupTask = nil
            startupTaskID = nil
            streamingService.cancel()
        }

        let fallbackStart = Date()
        logger.notice(
            "Using batch fallback for \(model.displayName, privacy: .public) file=\(audioURL.lastPathComponent, privacy: .public)"
        )
        let text = try await fallbackService.transcribe(audioURL: audioURL, model: model, context: context)
        logger.notice(
            "Batch fallback completed elapsed=\(Date().timeIntervalSince(fallbackStart), format: .fixed(precision: 3), privacy: .public)s chars=\(text.count, privacy: .public)"
        )
        return text
    }

    func cancel() {
        startupTask?.cancel()
        startupTask = nil
        startupTaskID = nil
        streamingService.cancel()
    }
}

// MARK: - Local Whisper Preview Session

/// Local Whisper with text in the recorder while recording (WhisperLivePreview). The preview is display only:
/// transcribe(audioURL:) stops it (aborting a decode in flight) and returns the normal whole-file result.
@MainActor
final class WhisperPreviewSession: TranscriptionSession {
    private let service: TranscriptionService
    private weak var modelProvider: (any WhisperModelProvider)?
    private let onPartialTranscript: ((String) -> Void)?
    private var model: (any TranscriptionModel)?
    private var context: TranscriptionRequestContext = .currentDefaults
    private var preview: WhisperLivePreview?
    private var startTask: Task<Void, Never>?

    init(
        service: TranscriptionService, modelProvider: (any WhisperModelProvider)?,
        onPartialTranscript: ((String) -> Void)?
    ) {
        self.service = service
        self.modelProvider = modelProvider
        self.onPartialTranscript = onPartialTranscript
    }

    func prepare(configuration: TranscriptionRuntimeConfiguration) async throws -> ((Data) -> Void)? {
        model = configuration.model
        context = configuration.requestContext.scoped(to: configuration.model)
        let language = context.language.flatMap { $0 == "auto" || $0.isEmpty ? nil : $0 }
        let modelName = configuration.model.name
        let onPartial = onPartialTranscript
        let preview = WhisperLivePreview(language: language) { text in
            Task { @MainActor in onPartial?(text) }
        }
        self.preview = preview
        // The engine loads the model into the shared context as recording starts; decode once it's there.
        startTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let provider = self?.modelProvider else { return }
                if provider.loadedWhisperModel?.name == modelName, let whisperContext = provider.whisperContext {
                    preview.start(context: whisperContext)
                    return
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        return { data in preview.append(pcm16: data) }
    }

    func transcribe(audioURL: URL) async throws -> String {
        stopPreview()
        guard let model else { throw VoiceInkEngineError.transcriptionFailed }
        return try await service.transcribe(audioURL: audioURL, model: model, context: context)
    }

    func cancel() {
        stopPreview()
    }

    private func stopPreview() {
        startTask?.cancel()
        startTask = nil
        preview?.stop()
        preview = nil
    }
}
