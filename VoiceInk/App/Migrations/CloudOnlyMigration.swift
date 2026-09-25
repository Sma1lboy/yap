import Foundation

/// One-time move off the on-device models and enhancement providers removed in the cloud-only build.
enum CloudOnlyMigration {
    private static let doneKey = "cloud-only-migrated"
    private static let modeKeys = ["modeConfigurationsV2", "powerModeConfigurationsV2"]
    static let removedAIProviders: Set<String> = ["VoiceInk Refine", "Ollama", "Local CLI"]
    static let replacementAIProvider = "OpenRouter"
    static let replacementAIModel = "deepseek/deepseek-v4.1-flash"

    static func runIfNeeded(defaults: UserDefaults = .standard) {
        #if DEBUG
            selfCheck()
        #endif
        guard !defaults.bool(forKey: doneKey) else { return }

        let knownModelNames = Set(TranscriptionModelRegistry.models.map(\.name))
        let replacementModel = StarterModeFactory.defaultTranscriptionModelName

        if let saved = defaults.string(forKey: "CurrentTranscriptionModel"),
            isRemovedLocalModel(saved, knownModelNames: knownModelNames)
        {
            defaults.set(replacementModel, forKey: "CurrentTranscriptionModel")
        }

        if let provider = defaults.string(forKey: "selectedAIProvider"), removedAIProviders.contains(provider) {
            defaults.set(replacementAIProvider, forKey: "selectedAIProvider")
            defaults.set(replacementAIModel, forKey: "\(replacementAIProvider)SelectedModel")
        }

        // JSONSerialization keeps fields this migration does not know about intact.
        for modeKey in modeKeys {
            guard let data = defaults.data(forKey: modeKey),
                var configs = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
            else { continue }

            var changed = false
            for index in configs.indices {
                if let model = configs[index]["selectedTranscriptionModelName"] as? String,
                    isRemovedLocalModel(model, knownModelNames: knownModelNames)
                {
                    configs[index]["selectedTranscriptionModelName"] = replacementModel
                    changed = true
                }
                if let provider = configs[index]["selectedAIProvider"] as? String,
                    removedAIProviders.contains(provider)
                {
                    configs[index]["selectedAIProvider"] = replacementAIProvider
                    configs[index]["selectedAIModel"] = replacementAIModel
                    changed = true
                }
            }
            if changed, let newData = try? JSONSerialization.data(withJSONObject: configs) {
                defaults.set(newData, forKey: modeKey)
            }
        }

        defaults.set(true, forKey: doneKey)
    }

    /// A saved selection key survives only if it can still name a cloud or custom model:
    /// routed keys (`OpenRouter:` / `Custom:`) or a model name the registry still knows.
    /// Everything else (ggml-*, parakeet-*, apple-speech, imported Whisper files, ...) was local.
    static func isRemovedLocalModel(_ key: String, knownModelNames: Set<String>) -> Bool {
        guard !key.isEmpty else { return false }
        if key.hasPrefix("OpenRouter:") || key.hasPrefix("Custom:") { return false }
        return !knownModelNames.contains(key)
    }

    #if DEBUG
        static func selfCheck() {
            let known: Set<String> = ["whisper-large-v3-turbo", "nova-3", "My Custom"]
            assert(isRemovedLocalModel("ggml-large-v3-turbo", knownModelNames: known))
            assert(isRemovedLocalModel("parakeet-tdt-0.6b-v3", knownModelNames: known))
            assert(isRemovedLocalModel("apple-speech", knownModelNames: known))
            assert(isRemovedLocalModel("cohere-transcribe", knownModelNames: known))
            assert(isRemovedLocalModel("my-imported-whisper", knownModelNames: known))
            assert(!isRemovedLocalModel("whisper-large-v3-turbo", knownModelNames: known))
            assert(!isRemovedLocalModel("nova-3", knownModelNames: known))
            assert(!isRemovedLocalModel("My Custom", knownModelNames: known))
            assert(!isRemovedLocalModel("OpenRouter:microsoft/mai-transcribe-2", knownModelNames: known))
            assert(!isRemovedLocalModel("Custom:\(UUID().uuidString)", knownModelNames: known))
            assert(!isRemovedLocalModel("", knownModelNames: known))
        }
    #endif
}
