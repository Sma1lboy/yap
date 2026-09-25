import Foundation

/// The one-key setup onboarding offers by default: OpenRouter for both transcription and cleanup.
enum RecommendedSetup {
    static let provider = "openrouter"
    static let transcriptionModel = "microsoft/mai-transcribe-2"
    static let enhancementModel = "deepseek/deepseek-v4.1-flash"
    /// Mode/UserDefaults key for the transcription model, as the loader writes it.
    static let transcriptionSelectionKey =
        "OpenRouter:\(OpenRouterProvider.stableID(for: transcriptionModel).uuidString)"
    /// `enhancement.prompt` value in config.json that selects the bundled prompt.
    static let promptKeyword = "recommended"
    static let apiKeyURL = URL(string: "https://openrouter.ai/settings/keys")!

    /// Contents of the bundled `RecommendedPrompt.md` (also `setup/install.sh`'s `~/.config/yap/prompt.md`).
    static let prompt: String? = Bundle.main.url(forResource: "RecommendedPrompt", withExtension: "md")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
}

extension YapConfig {
    static func recommended(openRouterKey: String) -> YapConfig {
        YapConfig(
            keys: [RecommendedSetup.provider: openRouterKey],
            transcription: Transcription(
                provider: RecommendedSetup.provider, model: RecommendedSetup.transcriptionModel),
            enhancement: Enhancement(
                enabled: true, provider: RecommendedSetup.provider, model: RecommendedSetup.enhancementModel,
                prompt: RecommendedSetup.prompt),
            defaultMode: DefaultMode(screenContext: false, clipboardContext: false, selectedTextContext: false)
        )
    }
}

#if DEBUG
    extension RecommendedSetup {
        static func selfCheck() {
            let prompt = RecommendedSetup.prompt ?? ""
            assert(prompt.contains("<RULES>"), "RecommendedPrompt.md missing from the app bundle")
            assert(transcriptionSelectionKey == "OpenRouter:ECA8DB85-56DA-3FC6-6B4D-86D9215F15D1")
            let config = YapConfig.recommended(openRouterKey: "sk-or-test")
            assert(config.keys == ["openrouter": "sk-or-test"])
            assert(config.transcription == .init(provider: "openrouter", model: "microsoft/mai-transcribe-2"))
            assert(config.enhancement?.enabled == true && config.enhancement?.provider == "openrouter")
            assert(config.enhancement?.model == "deepseek/deepseek-v4.1-flash" && config.enhancement?.prompt == prompt)
            assert(config.defaultMode == .init(screenContext: false, clipboardContext: false, selectedTextContext: false))
        }
    }
#endif
