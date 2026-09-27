import Foundation
import os

/// Manages API keys using secure Keychain storage.
final class APIKeyManager {
    static let shared = APIKeyManager()

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "APIKeyManager")
    private let keychain = KeychainService.shared

    /// Provider to Keychain identifier mapping (iOS compatible for iCloud sync).
    private static let providerToKeychainKey: [String: String] = [
        "groq": "groqAPIKey",
        "deepgram": "deepgramAPIKey",
        "cerebras": "cerebrasAPIKey",
        "gemini": "geminiAPIKey",
        "mistral": "mistralAPIKey",
        "elevenlabs": "elevenLabsAPIKey",
        "soniox": "sonioxAPIKey",
        "speechmatics": "speechmaticsAPIKey",
        "assemblyai": "assemblyAIAPIKey",
        "xai": "xaiAPIKey",
        "cartesia": "cartesiaAPIKey",
        "openai": "openAIAPIKey",
        "anthropic": "anthropicAPIKey",
        "openrouter": "openRouterAPIKey",
    ]

    private init() {}

    // MARK: - Standard Provider API Keys

    /// Saves an API key for a provider.
    @discardableResult
    func saveAPIKey(_ key: String, forProvider provider: String) -> Bool {
        let keyIdentifier = keychainIdentifier(forProvider: provider)
        let success = keychain.save(key, forKey: keyIdentifier)
        if success {
            logger.info(
                "Saved API key for provider: \(provider, privacy: .public) with key: \(keyIdentifier, privacy: .public)"
            )
        }
        return success
    }

    /// Retrieves an API key for a provider. Yap Cloud's "key" is the signed-in device token.
    func getAPIKey(forProvider provider: String) -> String? {
        if isYapCloud(provider) { return YapCloud.shared.token }
        if let key = Self.mockEnvironmentKey(forProvider: provider) { return key }
        let keyIdentifier = keychainIdentifier(forProvider: provider)
        return keychain.getString(forKey: keyIdentifier)
    }

    /// Deletes an API key for a provider.
    @discardableResult
    func deleteAPIKey(forProvider provider: String) -> Bool {
        let keyIdentifier = keychainIdentifier(forProvider: provider)
        let success = keychain.delete(forKey: keyIdentifier)
        if success {
            logger.info("Deleted API key for provider: \(provider, privacy: .public)")
        }
        return success
    }

    /// Checks if an API key exists for a provider.
    func hasAPIKey(forProvider provider: String) -> Bool {
        if isYapCloud(provider) { return YapCloud.shared.token != nil }
        if Self.mockEnvironmentKey(forProvider: provider) != nil { return true }
        let keyIdentifier = keychainIdentifier(forProvider: provider)
        return keychain.exists(forKey: keyIdentifier)
    }

    /// The mock identity only (make mock, scripts/meeting-files-check.sh): its re-signed copy can't write the
    /// keychain, so a key can come from YAP_MOCK_API_KEY_<PROVIDER> (e.g. YAP_MOCK_API_KEY_OPENROUTER). Never
    /// read by the dev or release app.
    private static func mockEnvironmentKey(forProvider provider: String) -> String? {
        #if DEBUG
            guard AppIdentity.isMock else { return nil }
            let name = "YAP_MOCK_API_KEY_" + provider.uppercased().filter { $0.isLetter || $0.isNumber }
            return ProcessInfo.processInfo.environment[name].flatMap { $0.isEmpty ? nil : $0 }
        #else
            return nil
        #endif
    }

    // MARK: - Custom Model API Keys

    /// Saves an API key for a custom model.
    @discardableResult
    func saveCustomModelAPIKey(_ key: String, forModelId modelId: UUID) -> Bool {
        let keyIdentifier = customModelKeyIdentifier(for: modelId)
        let success = keychain.save(key, forKey: keyIdentifier)
        if success {
            logger.info("Saved API key for custom model: \(modelId.uuidString, privacy: .public)")
        }
        return success
    }

    /// Retrieves an API key for a custom model.
    func getCustomModelAPIKey(forModelId modelId: UUID) -> String? {
        let keyIdentifier = customModelKeyIdentifier(for: modelId)
        return keychain.getString(forKey: keyIdentifier)
    }

    /// Deletes an API key for a custom model.
    @discardableResult
    func deleteCustomModelAPIKey(forModelId modelId: UUID) -> Bool {
        let keyIdentifier = customModelKeyIdentifier(for: modelId)
        let success = keychain.delete(forKey: keyIdentifier)
        if success {
            logger.info("Deleted API key for custom model: \(modelId.uuidString, privacy: .public)")
        }
        return success
    }

    // MARK: - Custom AI Provider API Keys

    @discardableResult
    func saveCustomAIProviderAPIKey(_ key: String, forProviderId providerId: UUID) -> Bool {
        let keyIdentifier = customAIProviderKeyIdentifier(for: providerId)
        let success = keychain.save(key, forKey: keyIdentifier)
        if success {
            logger.info("Saved API key for custom AI provider: \(providerId.uuidString, privacy: .public)")
        }
        return success
    }

    func getCustomAIProviderAPIKey(forProviderId providerId: UUID) -> String? {
        let keyIdentifier = customAIProviderKeyIdentifier(for: providerId)
        return keychain.getString(forKey: keyIdentifier)
    }

    @discardableResult
    func deleteCustomAIProviderAPIKey(forProviderId providerId: UUID) -> Bool {
        let keyIdentifier = customAIProviderKeyIdentifier(for: providerId)
        let success = keychain.delete(forKey: keyIdentifier)
        if success {
            logger.info("Deleted API key for custom AI provider: \(providerId.uuidString, privacy: .public)")
        }
        return success
    }

    // MARK: - Key Identifier Helpers

    /// Yap Cloud is signed into from Account, never given a pasted key.
    private func isYapCloud(_ provider: String) -> Bool {
        provider.replacingOccurrences(of: " ", with: "").lowercased() == "yapcloud"
    }

    /// Returns Keychain identifier for a provider (case-insensitive).
    private func keychainIdentifier(forProvider provider: String) -> String {
        let lowercased = provider.lowercased()
        if let mapped = Self.providerToKeychainKey[lowercased] {
            return mapped
        }
        return "\(lowercased)APIKey"
    }

    /// Generates Keychain identifier for custom model API key.
    private func customModelKeyIdentifier(for modelId: UUID) -> String {
        "customModel_\(modelId.uuidString)_APIKey"
    }

    private func customAIProviderKeyIdentifier(for providerId: UUID) -> String {
        "customAIProvider_\(providerId.uuidString)_APIKey"
    }
}
