import Foundation

enum TranscriptionModelRegistry {

    static var models: [any TranscriptionModel] {
        let cloudModels: [any TranscriptionModel] = CloudProviderRegistry.allProviders.flatMap { $0.models }
        return cloudModels + CustomCloudModelManager.shared.customModels
    }

    static func model(forSelectionKey key: String, in models: [any TranscriptionModel]) -> (any TranscriptionModel)? {
        if let model = models.first(where: { $0.selectionKey == key }) {
            return model
        }

        // Earlier versions stored OpenRouter by slug and custom models by name.
        // If that old key could identify either, require an explicit selection.
        if let openRouter = models.first(where: { $0.provider == .openRouter && "OpenRouter:\($0.name)" == key }) {
            guard !models.contains(where: { $0.provider == .custom && $0.name == key }) else { return nil }
            return openRouter
        }

        return models.first { $0.name == key && $0.provider != .openRouter }
    }
}
