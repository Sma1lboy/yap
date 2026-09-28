import Foundation

#if canImport(FoundationModels)
    import FoundationModels
#endif

/// Cleanup with the on-device model of macOS 26 (Foundation Models): no download, no key, nothing leaves the Mac.
/// It takes the mode's prompt like the cloud models (Yap Refine ignores it). Where the system can't run it
/// (before macOS 26, Apple Intelligence off or not ready, unsupported Mac), the provider isn't offered at all.
enum AppleIntelligenceService {
    /// `setup/apple_bench.swift` on the 25 cleanup cases decides this (docs/cloud-models.md, "On-device"). Until it
    /// scores at least Yap Refine, the provider is only offered after the Models > Advanced toggle.
    static let passesBench = false
    static let enabledKey = "AppleIntelligenceEnhancementEnabled"

    static var isSupported: Bool {
        #if canImport(FoundationModels)
            if #available(macOS 26, *) { return SystemLanguageModel.default.isAvailable }
        #endif
        return false
    }

    /// Offered in modes: supported, and either benched good enough or turned on under Models > Advanced.
    static var isOffered: Bool {
        isSupported && (passesBench || UserDefaults.standard.bool(forKey: enabledKey))
    }

    /// Same request as the bench: the prompt as instructions, the transcript as the prompt, temperature 0.3.
    /// ponytail: no timeout of its own (on-device, no network); add one if a slow first load shows up in use.
    static func enhance(systemPrompt: String, userPrompt: String) async throws -> String {
        #if canImport(FoundationModels)
            if #available(macOS 26, *) {
                guard SystemLanguageModel.default.isAvailable else { throw EnhancementError.notConfigured }
                let session = LanguageModelSession(instructions: systemPrompt)
                let response = try await session.respond(to: userPrompt, options: GenerationOptions(temperature: 0.3))
                return response.content
            }
        #endif
        throw EnhancementError.notConfigured
    }
}
