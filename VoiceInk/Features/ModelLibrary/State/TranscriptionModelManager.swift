import Foundation
import SwiftUI
import os

@MainActor
class TranscriptionModelManager: ObservableObject {
    @Published var currentTranscriptionModel: (any TranscriptionModel)?
    @Published var allAvailableModels: [any TranscriptionModel] = TranscriptionModelRegistry.models

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "TranscriptionModelManager")

    // MARK: - Computed: usable models

    var usableModels: [any TranscriptionModel] {
        allAvailableModels.filter { model in
            if model.provider == .custom { return true }
            guard let cloudProvider = CloudProviderRegistry.provider(for: model.provider) else { return false }
            return APIKeyManager.shared.hasAPIKey(forProvider: cloudProvider.providerKey)
        }
    }

    // MARK: - Model loading from UserDefaults

    func loadCurrentTranscriptionModel() {
        if let savedModelName = UserDefaults.standard.string(forKey: "CurrentTranscriptionModel"),
            let savedModel = TranscriptionModelRegistry.model(forSelectionKey: savedModelName, in: allAvailableModels)
        {
            currentTranscriptionModel = savedModel
            ensureSelectedLanguageIsSupported(by: savedModel)
        }
    }

    // MARK: - Set default model

    func setDefaultTranscriptionModel(_ model: any TranscriptionModel) {
        self.currentTranscriptionModel = model
        UserDefaults.standard.set(model.selectionKey, forKey: "CurrentTranscriptionModel")
        ensureSelectedLanguageIsSupported(by: model)

        NotificationCenter.default.post(name: .didChangeModel, object: nil, userInfo: ["modelName": model.name])
        NotificationCenter.default.post(name: .AppSettingsDidChange, object: nil)
    }

    private func ensureSelectedLanguageIsSupported(by model: any TranscriptionModel) {
        let currentLanguage = UserDefaults.standard.string(forKey: "SelectedLanguage")
        let compatibleLanguage = TranscriptionLanguageSupport.validLanguageOrFallback(currentLanguage, for: model)

        if currentLanguage != compatibleLanguage {
            UserDefaults.standard.set(compatibleLanguage, forKey: "SelectedLanguage")
            NotificationCenter.default.post(name: .languageDidChange, object: nil)
        }
    }

    // MARK: - Refresh all available models

    func refreshAllAvailableModels() {
        let currentSelection = currentTranscriptionModel?.selectionKey
            ?? UserDefaults.standard.string(forKey: "CurrentTranscriptionModel")
        allAvailableModels = TranscriptionModelRegistry.models

        if let currentSelection,
            let updatedModel = TranscriptionModelRegistry.model(forSelectionKey: currentSelection, in: allAvailableModels)
        {
            setDefaultTranscriptionModel(updatedModel)
        } else {
            currentTranscriptionModel = nil
        }
    }

    func refreshOpenRouterCatalog() async {
        do {
            try await OpenRouterTranscriptionCatalog.refresh()
            refreshAllAvailableModels()
        } catch {
            logger.error("Failed to refresh OpenRouter transcription models: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Clear current model

    func clearCurrentTranscriptionModel() {
        currentTranscriptionModel = nil
        UserDefaults.standard.removeObject(forKey: "CurrentTranscriptionModel")
    }
}
