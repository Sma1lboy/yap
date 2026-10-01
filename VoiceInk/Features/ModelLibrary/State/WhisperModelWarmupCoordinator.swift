import Combine
import Foundation

@MainActor
final class WhisperModelWarmupCoordinator: ObservableObject {
    static let shared = WhisperModelWarmupCoordinator()

    @Published private(set) var warmingModels: Set<String> = []

    private init() {}

    func isWarming(modelNamed name: String) -> Bool {
        warmingModels.contains(name)
    }

    func scheduleWarmup(for model: WhisperModel, whisperModelManager: WhisperModelManager) {
        // Every model, quantized included: besides the Core ML encoder (non-quantized only), the first run of
        // whisper.cpp compiles its Metal shaders, 16 s on an M4 Pro. Paid here, right after the download, instead of
        // in the user's first dictation.
        guard !warmingModels.contains(model.name) else { return }

        warmingModels.insert(model.name)

        Task {
            do {
                try await runWarmup(for: model, whisperModelManager: whisperModelManager)
            } catch {
                whisperModelManager.logger.error(
                    "❌ Warmup failed for \(model.name, privacy: .public): \(error, privacy: .public)")
            }

            _ = warmingModels.remove(model.name)
        }
    }

    private func runWarmup(for model: WhisperModel, whisperModelManager: WhisperModelManager) async throws {
        guard let sampleURL = warmupSampleURL(),
            let file = whisperModelManager.availableModels.first(where: { $0.name == model.name }),
            whisperModelManager.whisperContext == nil || whisperModelManager.loadedWhisperModel?.name != model.name
        else { return }
        // A context of its own, freed right after: the model just downloaded must not replace the one dictation uses.
        try await whisperModelManager.warmUp(file, samples: try WhisperTranscriptionService.readAudioSamples(sampleURL))
    }

    private func warmupSampleURL() -> URL? {
        let bundle = Bundle.main
        let candidates: [URL?] = [
            bundle.url(forResource: "sound7", withExtension: "wav", subdirectory: "Resources/Sounds"),
            bundle.url(forResource: "sound7", withExtension: "wav", subdirectory: "Sounds"),
            bundle.url(forResource: "sound7", withExtension: "wav"),
        ]

        for candidate in candidates {
            if let url = candidate {
                return url
            }
        }

        return nil
    }

}
