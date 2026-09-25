// Stand-ins for the one app type CloudConfigSync.swift names but sync-e2e doesn't use (its `shared` instance is
// wired to the real app's loader; sync-e2e builds its own instances). Everything else is the real app code.
import Foundation

@MainActor final class YapConfigLoader {
    static let shared = YapConfigLoader()
    func makeCloudConfigData() async -> Data? { nil }
    func applyConfigData(_ data: Data) async throws {}
    func writePulledConfig(_ data: Data) throws {}
}

/// RecommendedSetup (for its prompt keyword) builds one constant from this; the value doesn't matter to sync.
enum OpenRouterProvider {
    static func stableID(for model: String) -> UUID { UUID() }
}

/// BackupTypes' CustomModelBackup converts to and from this; sync-e2e never makes one.
struct CustomCloudModel {
    let id: UUID
    let name: String
    let displayName: String
    let description: String
    let apiEndpoint: String
    let modelName: String
    let isMultilingualModel: Bool
    let supportedLanguages: [String: String]

    init(
        id: UUID, name: String, displayName: String, description: String, apiEndpoint: String, modelName: String,
        isMultilingual: Bool, supportedLanguages: [String: String]
    ) {
        (self.id, self.name, self.displayName, self.description) = (id, name, displayName, description)
        (self.apiEndpoint, self.modelName) = (apiEndpoint, modelName)
        (self.isMultilingualModel, self.supportedLanguages) = (isMultilingual, supportedLanguages)
    }
}

/// Keys never take part in config sync; these are here only so the model/provider types compile.
final class APIKeyManager {
    static let shared = APIKeyManager()
    @discardableResult func saveCustomModelAPIKey(_ key: String, forModelId id: UUID) -> Bool { false }
    @discardableResult func saveCustomAIProviderAPIKey(_ key: String, forProviderId id: UUID) -> Bool { false }
    func getCustomAIProviderAPIKey(forProviderId id: UUID) -> String? { nil }
    func deleteCustomAIProviderAPIKey(forProviderId id: UUID) {}
    @discardableResult func saveAPIKey(_ key: String, forProvider provider: String) -> Bool { false }
    func getAPIKey(forProvider provider: String) -> String? { nil }
    func deleteAPIKey(forProvider provider: String) {}
}

/// CustomPrompt.finalPromptText formats with this; sync-e2e never calls it.
enum AIPrompts {
    static let enhancementSystemTemplate = "%@"
}
