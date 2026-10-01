import Foundation

/// Routes catalog-backed models through the shared transcribe.cpp runtime.
final class TranscribeCppTranscriptionService: TranscriptionService, @unchecked Sendable {
    private let offlineService = OfflineTranscribeCppService()

    func loadModel(for model: TranscribeCppModel) async throws {
        guard TranscribeCppModelCatalog.artifact(for: model.name) != nil else {
            throw unsupportedModelError(model.name)
        }
        try await offlineService.loadModel(for: model)
    }

    func transcribe(
        audioURL: URL,
        model: any TranscriptionModel,
        context: TranscriptionRequestContext
    ) async throws -> String {
        guard let transcribeCppModel = model as? TranscribeCppModel else {
            throw NSError(
                domain: "TranscribeCppTranscriptionService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Unsupported transcription model"]
            )
        }

        guard TranscribeCppModelCatalog.artifact(for: transcribeCppModel.name) != nil else {
            throw unsupportedModelError(transcribeCppModel.name)
        }
        return try await offlineService.transcribe(
            audioURL: audioURL,
            model: transcribeCppModel,
            context: context
        )
    }

    /// The idle or memory-pressure release: now, or after the last running transcription.
    func cleanup() {
        offlineService.cleanup()
    }

    /// Quit: aborts running transcriptions and returns once the model is freed.
    func close() async {
        await offlineService.close()
    }

    #if DEBUG
        /// `make lifecycle-check`: whether a model is loaded.
        var isModelLoaded: Bool { offlineService.isModelLoaded }
    #endif

    private func unsupportedModelError(_ modelName: String) -> NSError {
        NSError(
            domain: "TranscribeCppTranscriptionService",
            code: -2,
            userInfo: [NSLocalizedDescriptionKey: "No transcribe.cpp service is registered for \(modelName)"]
        )
    }
}
