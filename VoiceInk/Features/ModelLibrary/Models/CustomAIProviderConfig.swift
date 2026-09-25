import Foundation

struct CustomAIProviderConfig: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var baseURL: String
    var models: [String]
    var selectedModel: String

    init(id: UUID = UUID(), name: String, baseURL: String, models: [String], selectedModel: String) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.models = models
        self.selectedModel = selectedModel
    }

    var trimmedModels: [String] {
        models
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var modelName: String {
        let trimmedSelectedModel = selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSelectedModel.isEmpty {
            return trimmedSelectedModel
        }
        return trimmedModels.first ?? ""
    }

    var normalizedForStorage: CustomAIProviderConfig {
        let resolvedModelName = self.modelName
        return CustomAIProviderConfig(
            id: id,
            name: name,
            baseURL: baseURL,
            models: resolvedModelName.isEmpty ? [] : [resolvedModelName],
            selectedModel: resolvedModelName
        )
    }
}
