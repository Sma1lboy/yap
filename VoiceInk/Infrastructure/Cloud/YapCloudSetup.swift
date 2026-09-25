import Foundation

extension YapConfig {
    /// Onboarding's "Use Yap Cloud" preset: the Recommended models and prompt, billed through the signed-in account.
    static func yapCloud(transcriptionModel: String) -> YapConfig {
        YapConfig(
            keys: nil,
            transcription: Transcription(provider: "yapcloud", model: transcriptionModel),
            enhancement: Enhancement(
                enabled: true, provider: "yapcloud", model: RecommendedSetup.enhancementModel,
                prompt: RecommendedSetup.prompt),
            defaultMode: DefaultMode(screenContext: false, clipboardContext: false, selectedTextContext: false)
        )
    }
}
