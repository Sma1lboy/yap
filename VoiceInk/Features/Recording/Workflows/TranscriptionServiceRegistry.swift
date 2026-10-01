import Foundation
import SwiftData
import SwiftUI
import os

@MainActor
class TranscriptionServiceRegistry {
    private weak var modelProvider: (any WhisperModelProvider)?
    private let modelsDirectory: URL
    private let modelContext: ModelContext
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "TranscriptionServiceRegistry")

    private lazy var localTranscriptionService = WhisperTranscriptionService(
        modelsDirectory: modelsDirectory,
        modelProvider: modelProvider,
        modelContext: modelContext
    )
    private(set) lazy var cloudTranscriptionService = CloudTranscriptionService(modelContext: modelContext)
    private(set) lazy var nativeAppleTranscriptionService = NativeAppleTranscriptionService()
    private(set) lazy var fluidAudioTranscriptionService = FluidAudioTranscriptionService()
    private var cachedTranscribeCppTranscriptionService: TranscribeCppTranscriptionService?

    var transcribeCppTranscriptionService: TranscribeCppTranscriptionService {
        if let cachedTranscribeCppTranscriptionService {
            return cachedTranscribeCppTranscriptionService
        }
        let service = TranscribeCppTranscriptionService()
        cachedTranscribeCppTranscriptionService = service
        return service
    }

    init(modelProvider: any WhisperModelProvider, modelsDirectory: URL, modelContext: ModelContext) {
        self.modelProvider = modelProvider
        self.modelsDirectory = modelsDirectory
        self.modelContext = modelContext
    }

    func service(for provider: ModelProvider) -> TranscriptionService {
        switch provider {
        case .whisper:
            return localTranscriptionService
        case .fluidAudio:
            return fluidAudioTranscriptionService
        case .transcribeCpp:
            return transcribeCppTranscriptionService
        case .nativeApple:
            return nativeAppleTranscriptionService
        default:
            return cloudTranscriptionService
        }
    }

    func transcribe(
        audioURL: URL, model: any TranscriptionModel, context: TranscriptionRequestContext = .currentDefaults
    ) async throws -> String {
        try await transcribeWithSegments(audioURL: audioURL, model: model, context: context).text
    }

    /// As `transcribe`, plus the timed segments of the same decode: local Whisper's; empty for other providers.
    func transcribeWithSegments(
        audioURL: URL, model: any TranscriptionModel, context: TranscriptionRequestContext
    ) async throws -> (text: String, segments: [TimedSegment]) {
        let service = service(for: model.provider)
        logger.debug(
            "Transcribing with \(model.displayName, privacy: .public) using \(String(describing: type(of: service)), privacy: .public)"
        )
        let context = context.scoped(to: model)
        return try await ModelResidency.shared.withUse {
            if model.provider == .whisper {
                return try await localTranscriptionService.transcribeWithSegments(
                    audioURL: audioURL, model: model, context: context)
            }
            return (try await service.transcribe(audioURL: audioURL, model: model, context: context), [])
        }
    }

    /// Creates a streaming or file-based session for the resolved transcription configuration.
    func createSession(
        for configuration: TranscriptionRuntimeConfiguration, onPartialTranscript: ((String) -> Void)? = nil
    ) -> TranscriptionSession {
        let model = configuration.model

        if usesWhisperLivePreview(for: configuration) {
            return WhisperPreviewSession(
                service: localTranscriptionService, modelProvider: modelProvider,
                onPartialTranscript: onPartialTranscript)
        }
        if shouldUseRealtimeTranscription(for: configuration) {
            let streamingService = StreamingTranscriptionService(
                modelContext: modelContext,
                fluidAudioService: model.provider == .fluidAudio ? fluidAudioTranscriptionService : nil,
                onPartialTranscript: onPartialTranscript
            )
            let fallback = service(for: model.provider)
            return StreamingTranscriptionSession(streamingService: streamingService, fallbackService: fallback)
        } else {
            return FileTranscriptionSession(service: service(for: model.provider))
        }
    }

    /// Whether the resolved transcription configuration should use real-time transcription.
    func shouldUseRealtimeTranscription(for configuration: TranscriptionRuntimeConfiguration) -> Bool {
        configuration.isRealtimeEnabled || usesWhisperLivePreview(for: configuration)
    }

    /// Local Whisper has no streaming mode; with "show live transcript" on it gets WhisperLivePreview's text instead.
    /// About 2.5 CPU-seconds and 6 J more per minute of recording on an M4 Pro; final text unchanged, final time
    /// within 5% (docs/local-models.md).
    private func usesWhisperLivePreview(for configuration: TranscriptionRuntimeConfiguration) -> Bool {
        configuration.model.provider == .whisper
            && UserDefaults.standard.bool(forKey: RecorderDisplaySettingsKeys.showLiveTranscript)
    }

    /// The idle or memory-pressure release of FluidAudio and transcribe.cpp. Each waits for its transcription in
    /// flight (FluidAudio's turn; transcribe.cpp unloads after its last running transcription).
    func releaseAll() async {
        await fluidAudioTranscriptionService.releaseAll()
        cachedTranscribeCppTranscriptionService?.cleanup()
    }

    /// Quit: as `releaseAll`, but nothing starts after it, and it returns once each backend's transcription in flight
    /// has ended and its model is freed (transcribe.cpp links its own ggml, which asserts at exit() while a Metal
    /// buffer is allocated).
    func closeForQuit() async {
        await fluidAudioTranscriptionService.close()
        await cachedTranscribeCppTranscriptionService?.close()
    }
}
