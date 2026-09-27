import CryptoKit
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

    /// Contents of the bundled `RecommendedPrompt.md`.
    static let prompt: String? = Bundle.main.url(forResource: "RecommendedPrompt", withExtension: "md")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }

    /// SHA-256 of every version of the recommended prompt that has shipped (text trimmed of surrounding whitespace),
    /// from `git log --all -- VoiceInk/Resources/RecommendedPrompt.md setup/prompt.md`. Add the new hash whenever
    /// RecommendedPrompt.md changes; selfCheck fails until it's here. A prompt whose text is exactly one of these is
    /// an untouched copy, which `followingRecommended` turns into a reference.
    static let shippedPromptHashes: Set<String> = [
        "f37a9a93199dbe14e818f7190ee5151185d7aba8ac8a7ef2c49973a7a1a84c3c",  // 1a71a13 2026-09-24 (setup/prompt.md)
        "c92a8f9e851cb58c9c68fed1bfb24c0030d7d13490a7600a181d18d1db5df60d",  // 00bbde0 2026-09-26
    ]

    static func isShippedPrompt(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let hash = SHA256.hash(data: Data(trimmed.utf8)).map { String(format: "%02x", $0) }.joined()
        return shippedPromptHashes.contains(hash)
    }

    /// Untouched copies of any shipped recommended prompt become references to the current one. The stored text
    /// is kept, so turning `followsRecommended` off (or restoring an earlier synced version) gives it back.
    static func followingRecommended(_ prompts: [CustomPrompt]) -> [CustomPrompt] {
        prompts.map { prompt in
            guard !prompt.followsRecommended, isShippedPrompt(prompt.promptText) else { return prompt }
            return CustomPrompt(
                id: prompt.id, title: prompt.title, promptText: prompt.promptText,
                useSystemInstructions: prompt.useSystemInstructions, followsRecommended: true)
        }
    }
}

extension YapConfig {
    static func recommended(openRouterKey: String) -> YapConfig {
        YapConfig(
            keys: [RecommendedSetup.provider: openRouterKey],
            transcription: Transcription(
                provider: RecommendedSetup.provider, model: RecommendedSetup.transcriptionModel),
            enhancement: Enhancement(
                enabled: true, provider: RecommendedSetup.provider, model: RecommendedSetup.enhancementModel,
                prompt: RecommendedSetup.promptKeyword),
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
            assert(config.enhancement?.model == "deepseek/deepseek-v4.1-flash" && config.enhancement?.prompt == "recommended")
            assert(isShippedPrompt(prompt), "RecommendedPrompt.md changed: add its hash to shippedPromptHashes")
            assert(isShippedPrompt("\n" + prompt + "\n") && !isShippedPrompt(prompt + "x"))
            let copy = CustomPrompt(title: "Mine", promptText: prompt, useSystemInstructions: false)
            let edited = CustomPrompt(title: "Edited", promptText: prompt.replacingOccurrences(of: "<RULES>", with: "<RULE>"))
            let migrated = followingRecommended([copy, edited])
            assert(migrated[0].followsRecommended && migrated[0].promptText == prompt && migrated[0].title == "Mine")
            assert(!migrated[0].useSystemInstructions && migrated[1] == edited)
            assert(followingRecommended(migrated) == migrated)
            let following = CustomPrompt(title: "R", promptText: "old copy", followsRecommended: true)
            assert(following.text == prompt && CustomPrompt(title: "P", promptText: "p").text == "p")
            let encoded = try! JSONEncoder().encode([following, edited])
            let json = String(decoding: encoded, as: UTF8.self)
            assert(json.components(separatedBy: "followsRecommended").count == 2, "written only when true")
            assert(try! JSONDecoder().decode([CustomPrompt].self, from: encoded) == [following, edited])
            assert(config.defaultMode == .init(screenContext: false, clipboardContext: false, selectedTextContext: false))
        }
    }
#endif
