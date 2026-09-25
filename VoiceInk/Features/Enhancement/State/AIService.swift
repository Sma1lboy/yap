import Combine
import Foundation
import LLMkit

enum AIProvider: String, CaseIterable {
    case cerebras = "Cerebras"
    case groq = "Groq"
    case gemini = "Gemini"
    case anthropic = "Anthropic"
    case openAI = "OpenAI"
    case openRouter = "OpenRouter"
    case mistral = "Mistral"
    case elevenLabs = "ElevenLabs"
    case deepgram = "Deepgram"
    case soniox = "Soniox"
    case speechmatics = "Speechmatics"
    case assemblyAI = "AssemblyAI"
    case custom = "Custom"

    var baseURL: String {
        switch self {
        case .cerebras:
            return "https://api.cerebras.ai/v1/chat/completions"
        case .groq:
            return "https://api.groq.com/openai/v1/chat/completions"
        case .gemini:
            return "https://generativelanguage.googleapis.com/v1/interactions"
        case .anthropic:
            return "https://api.anthropic.com/v1/messages"
        case .openAI:
            return "https://api.openai.com/v1/chat/completions"
        case .openRouter:
            return "https://openrouter.ai/api/v1/chat/completions"
        case .mistral:
            return "https://api.mistral.ai/v1/chat/completions"
        case .elevenLabs:
            return "https://api.elevenlabs.io/v1/speech-to-text"
        case .deepgram:
            return "https://api.deepgram.com/v1/listen"
        case .soniox:
            return "https://api.soniox.com/v1"
        case .speechmatics:
            return "https://asr.api.speechmatics.com/v2"
        case .assemblyAI:
            return "https://api.assemblyai.com/v2/transcript"
        case .custom:
            return UserDefaults.standard.string(forKey: "customProviderBaseURL") ?? ""
        }
    }

    var defaultModel: String {
        switch self {
        case .cerebras:
            return "gpt-oss-120b"
        case .groq:
            return "openai/gpt-oss-120b"
        case .gemini:
            return "gemini-3.8-flash"
        case .anthropic:
            return "claude-sonnet-5"
        case .openAI:
            return "gpt-5.6-luna"
        case .mistral:
            return "mistral-small-latest"
        case .elevenLabs:
            return "scribe_v2"
        case .deepgram:
            return "whisper-1"
        case .soniox:
            return "stt-async-v5"
        case .speechmatics:
            return "speechmatics-enhanced"
        case .assemblyAI:
            return "universal-3-5-pro"
        case .custom:
            return CustomAIProviderManager.shared.defaultModelName
        case .openRouter:
            return "openai/gpt-oss-120b"
        }
    }

    var availableModels: [String] {
        switch self {
        case .cerebras:
            return [
                "gpt-oss-120b",
                "qwen-3.8-27b",
            ]
        case .groq:
            return [
                "openai/gpt-oss-120b",
                "openai/gpt-oss-20b",
                "qwen/qwen3.8-27b",
            ]
        case .gemini:
            return [
                "gemini-3.8-flash",
                "gemini-3.7-flash",
                "gemini-3.6-flash",
                "gemini-3.5-flash-lite",
                "gemini-3.5-flash",
                "gemini-3.1-pro-preview",
                "gemini-3.1-flash-lite",
                "gemini-2.5-flash-lite",
            ]
        case .anthropic:
            return [
                "claude-sonnet-5",
                "claude-haiku-4-5",
            ]
        case .openAI:
            return [
                "gpt-5.6-luna",
                "gpt-5.6-terra",
                "gpt-5.6-sol",
                "gpt-5.5",
                "gpt-5.4",
                "gpt-5.4-mini",
                "gpt-5.4-nano",
                "gpt-4.1",
                "gpt-4.1-mini",
                "gpt-4.1-nano",
            ]
        case .mistral:
            return [
                "mistral-small-latest",
                "mistral-medium-latest",
                "mistral-large-latest",
            ]
        case .elevenLabs:
            return ["scribe_v2"]
        case .deepgram:
            return ["whisper-1"]
        case .soniox:
            return ["stt-async-v5"]
        case .speechmatics:
            return ["speechmatics-enhanced"]
        case .assemblyAI:
            return ["universal-3-5-pro"]
        case .custom:
            return CustomAIProviderManager.shared.availableModelNames
        case .openRouter:
            return []
        }
    }

    var supportsEnhancement: Bool {
        switch self {
        case .elevenLabs, .deepgram, .soniox, .speechmatics, .assemblyAI:
            return false
        default:
            return true
        }
    }

    var supportsCustomModelID: Bool {
        switch self {
        case .cerebras, .groq, .gemini, .anthropic, .openAI, .mistral:
            return true
        default:
            return false
        }
    }
}

class AIService: ObservableObject {
    @Published var apiKey: String = ""
    @Published var isAPIKeyValid: Bool = false
    @Published var customBaseURL: String = UserDefaults.standard.string(forKey: "customProviderBaseURL") ?? "" {
        didSet {
            userDefaults.set(customBaseURL, forKey: "customProviderBaseURL")
        }
    }
    @Published var customModel: String = UserDefaults.standard.string(forKey: "customProviderModel") ?? "" {
        didSet {
            userDefaults.set(customModel, forKey: "customProviderModel")
        }
    }
    @Published var selectedProvider: AIProvider {
        didSet {
            userDefaults.set(selectedProvider.rawValue, forKey: "selectedAIProvider")
            if let savedKey = APIKeyManager.shared.getAPIKey(forProvider: selectedProvider.rawValue) {
                self.apiKey = savedKey
                self.isAPIKeyValid = true
            } else {
                self.apiKey = ""
                self.isAPIKeyValid = false
            }
            NotificationCenter.default.post(name: .AppSettingsDidChange, object: nil)
        }
    }

    @Published private var selectedModels: [AIProvider: String] = [:]
    private let userDefaults = UserDefaults.standard
    private var apiKeyChangeObserver: NSObjectProtocol?
    private var settingsChangeObserver: NSObjectProtocol?

    @Published private var openRouterModels: [String] = []
    @Published private var openRouterModelCatalog: [OpenRouterModel] = []
    private var isOpenRouterCatalogRefreshing = false

    var connectedProviders: [AIProvider] {
        AIProvider.allCases.filter { provider in
            guard provider.supportsEnhancement else {
                return false
            }

            if provider == .custom {
                return CustomAIProviderManager.shared.hasConfiguredModels
            }
            return APIKeyManager.shared.hasAPIKey(forProvider: provider.rawValue)
        }
    }

    var currentModel: String {
        if let selectedModel = selectedModels[selectedProvider],
            !selectedModel.isEmpty,
            (selectedProvider.supportsCustomModelID || availableModels.contains(selectedModel))
        {
            return selectedModel
        }
        return selectedProvider.defaultModel
    }

    func selectedModel(for provider: AIProvider) -> String {
        if let selectedModel = selectedModels[provider], !selectedModel.isEmpty {
            return selectedModel
        }
        return provider.defaultModel
    }

    func customModelID(for provider: AIProvider) -> String {
        guard provider.supportsCustomModelID else { return "" }
        let key = "\(provider.rawValue)CustomModelID"
        if let savedModel = userDefaults.string(forKey: key), !savedModel.isEmpty {
            return savedModel
        }
        let selectedModel = selectedModel(for: provider)
        return provider.availableModels.contains(selectedModel) ? "" : selectedModel
    }

    var availableModels: [String] {
        availableModels(for: selectedProvider)
    }

    func availableModels(for provider: AIProvider) -> [String] {
        if provider == .openRouter {
            return openRouterModels
        } else if provider == .custom {
            return CustomAIProviderManager.shared.availableModelNames
        }
        return provider.availableModels
    }

    init() {
        if userDefaults.string(forKey: "selectedAIProvider") == "GROQ" {
            userDefaults.set("Groq", forKey: "selectedAIProvider")
        }

        if let savedProvider = userDefaults.string(forKey: "selectedAIProvider"),
            let provider = AIProvider(rawValue: savedProvider)
        {
            self.selectedProvider = provider
        } else {
            self.selectedProvider = .gemini
        }

        if let savedKey = APIKeyManager.shared.getAPIKey(forProvider: selectedProvider.rawValue) {
            self.apiKey = savedKey
            self.isAPIKeyValid = true
        }

        loadSavedModelSelections()
        loadSavedOpenRouterModels()
        initializeAutoLearnSelectionIfNeeded()

        apiKeyChangeObserver = NotificationCenter.default.addObserver(
            forName: .aiProviderKeyChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.reloadSelectedProviderConfiguration()
                self.initializeAutoLearnSelectionIfNeeded()
            }
        }

        settingsChangeObserver = NotificationCenter.default.addObserver(
            forName: .AppSettingsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.initializeAutoLearnSelectionIfNeeded()
        }
    }

    deinit {
        if let apiKeyChangeObserver {
            NotificationCenter.default.removeObserver(apiKeyChangeObserver)
        }
        if let settingsChangeObserver {
            NotificationCenter.default.removeObserver(settingsChangeObserver)
        }
    }

    private func reloadSelectedProviderConfiguration() {
        if selectedProvider == .custom {
            customBaseURL = userDefaults.string(forKey: "customProviderBaseURL") ?? ""
            customModel = userDefaults.string(forKey: "customProviderModel") ?? ""
        }

        let selectedModelKey = "\(selectedProvider.rawValue)SelectedModel"
        if let savedModel = userDefaults.string(forKey: selectedModelKey), !savedModel.isEmpty {
            selectedModels[selectedProvider] = savedModel
        }

        if let savedKey = APIKeyManager.shared.getAPIKey(forProvider: selectedProvider.rawValue) {
            apiKey = savedKey
            isAPIKeyValid = true
        } else {
            apiKey = ""
            isAPIKeyValid = false
        }
    }

    private func initializeAutoLearnSelectionIfNeeded() {
        if let selectedProvider = AutoLearnSettings.selectedProvider,
            AutoLearnProviderPolicy.isSupported(selectedProvider)
        {
            return
        }

        let availableProviders = connectedProviders.filter(AutoLearnProviderPolicy.isSupported)
        let provider = availableProviders.contains(selectedProvider)
            ? selectedProvider
            : availableProviders.first
        guard let provider else { return }

        AutoLearnSettings.initializeSelectionIfNeeded(
            provider: provider,
            model: initialAutoLearnModel(for: provider)
        )
    }

    private func initialAutoLearnModel(for provider: AIProvider) -> String {
        let selectedModel = selectedModel(for: provider)
        let availableModels = availableModels(for: provider)
        return provider.supportsCustomModelID || availableModels.contains(selectedModel)
            ? selectedModel
            : availableModels.first ?? selectedModel
    }

    private func loadSavedModelSelections() {
        for provider in AIProvider.allCases {
            let key = "\(provider.rawValue)SelectedModel"
            if let savedModel = userDefaults.string(forKey: key), !savedModel.isEmpty {
                selectedModels[provider] = savedModel
            }
        }
    }

    private func loadSavedOpenRouterModels() {
        if let catalog = OpenRouterCatalogStore.shared.models(for: .enhancement) {
            openRouterModelCatalog = catalog
            openRouterModels = catalog.filter(isOpenRouterEnhancementModel).map(\.id)
            reconcileOpenRouterSelection(selectInitialIfNeeded: true)
            return
        }

        openRouterModels = OpenRouterCatalogStore.shared.legacyEnhancementModelIDs
    }

    private func saveOpenRouterModels() {
        OpenRouterCatalogStore.shared.saveLegacyEnhancementModelIDs(openRouterModels)
        try? OpenRouterCatalogStore.shared.save(openRouterModelCatalog, for: .enhancement)
    }

    private func isOpenRouterEnhancementModel(_ model: OpenRouterModel) -> Bool {
        guard let architecture = model.architecture else { return true }
        return architecture.inputModalities.contains("text")
            && architecture.outputModalities.contains("text")
    }

    @discardableResult
    private func reconcileOpenRouterSelection(selectInitialIfNeeded: Bool = false) -> Bool {
        let selected = selectedModels[.openRouter]
        if let selected, openRouterModels.contains(selected) { return false }
        guard selected != nil || (selectInitialIfNeeded && selectedProvider == .openRouter) else { return false }

        if let replacement = openRouterModels.first(where: { $0 == AIProvider.openRouter.defaultModel })
            ?? openRouterModels.first
        {
            selectedModels[.openRouter] = replacement
            userDefaults.set(replacement, forKey: "OpenRouterSelectedModel")
        } else {
            selectedModels.removeValue(forKey: .openRouter)
            userDefaults.removeObject(forKey: "OpenRouterSelectedModel")
        }
        return selected != selectedModels[.openRouter]
    }

    func selectModel(_ model: String) {
        selectModel(model, for: selectedProvider)
    }

    func selectModel(_ model: String, for provider: AIProvider) {
        let resolvedInput = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolvedInput.isEmpty else { return }

        if provider == .custom {
            guard CustomAIProviderManager.shared.applyConfiguration(forModel: resolvedInput) else { return }
        }

        let resolvedModel = resolvedInput
        selectedModels[provider] = resolvedModel
        let key = "\(provider.rawValue)SelectedModel"
        userDefaults.set(resolvedModel, forKey: key)
        if provider.supportsCustomModelID, !provider.availableModels.contains(resolvedModel) {
            userDefaults.set(resolvedModel, forKey: "\(provider.rawValue)CustomModelID")
        }

        if provider == .custom {
            reloadSelectedProviderConfiguration()
        }

        objectWillChange.send()
        NotificationCenter.default.post(name: .AppSettingsDidChange, object: nil)
    }

    func saveAPIKey(_ key: String, completion: @escaping (Bool, String?) -> Void) {
        verifyAPIKey(key) { [weak self] isValid, errorMessage in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if isValid {
                    self.apiKey = key
                    self.isAPIKeyValid = true
                    APIKeyManager.shared.saveAPIKey(key, forProvider: self.selectedProvider.rawValue)
                    NotificationCenter.default.post(name: .aiProviderKeyChanged, object: nil)
                    NotificationCenter.default.post(name: .AppSettingsDidChange, object: nil)
                } else {
                    self.isAPIKeyValid = false
                }
                completion(isValid, errorMessage)
            }
        }
    }

    func verifyAPIKey(_ key: String, completion: @escaping (Bool, String?) -> Void) {
        Task {
            let result = await verifyAPIKey(
                key,
                for: selectedProvider,
                model: currentModel
            )
            DispatchQueue.main.async {
                completion(result.isValid, result.errorMessage)
            }
        }
    }

    func verifyAPIKey(_ key: String, for provider: AIProvider, model: String? = nil) async -> (
        isValid: Bool, errorMessage: String?
    ) {
        let verificationModel = model ?? selectedModel(for: provider)
        let result: (isValid: Bool, errorMessage: String?)

        switch provider {
        case .anthropic:
            result = await AnthropicLLMClient.verifyAPIKey(key)
        case .elevenLabs:
            result = await ElevenLabsClient.verifyAPIKey(key)
        case .deepgram:
            result = await DeepgramClient.verifyAPIKey(key)
        case .mistral:
            result = await MistralTranscriptionClient.verifyAPIKey(key)
        case .soniox:
            result = await SonioxClient.verifyAPIKey(key)
        case .speechmatics:
            result = await SpeechmaticsClient.verifyAPIKey(key)
        case .assemblyAI:
            result = await AssemblyAIClient.verifyAPIKey(key)
        case .openRouter:
            result = await OpenRouterClient.verifyAPIKey(key)
        case .openAI:
            result = await OpenAILLMClient.verifyAPIKey(key)
        case .gemini:
            result = await GeminiLLMClient.verifyAPIKey(key)
        default:
            guard let baseURL = URL(string: provider.baseURL) else {
                return (false, "Invalid or missing base URL configuration")
            }
            result = await OpenAILLMClient.verifyAPIKey(
                baseURL: baseURL,
                apiKey: key,
                model: verificationModel
            )
        }

        return result
    }

    func clearAPIKey() {
        apiKey = ""
        isAPIKeyValid = false
        APIKeyManager.shared.deleteAPIKey(forProvider: selectedProvider.rawValue)
        NotificationCenter.default.post(name: .aiProviderKeyChanged, object: nil)
    }

    func reviewAutoLearnCandidates(
        payload: String,
        systemPrompt: String,
        provider: AIProvider,
        modelName: String?
    ) async throws -> String {
        guard AutoLearnProviderPolicy.isSupported(provider) else {
            throw EnhancementError.notConfigured
        }

        return try await performChatCompletion(
            provider: provider,
            modelName: modelName,
            messages: [.user(payload)],
            systemPrompt: systemPrompt,
            timeout: EnhancementRequestSettings.timeout
        ).text
    }

    func openRouterModelMetadata(for modelName: String) -> OpenRouterModel? {
        openRouterModelCatalog.first(where: { $0.id == modelName })
    }

    @MainActor
    func fetchOpenRouterModelsIfNeededForMigration() async {
        guard openRouterModelCatalog.isEmpty,
            APIKeyManager.shared.hasAPIKey(forProvider: AIProvider.openRouter.rawValue)
        else {
            return
        }

        await fetchOpenRouterModels()
    }

    @MainActor
    func fetchOpenRouterModels() async {
        guard !isOpenRouterCatalogRefreshing else { return }
        isOpenRouterCatalogRefreshing = true
        defer { isOpenRouterCatalogRefreshing = false }

        do {
            let catalog = try await OpenRouterClient.fetchModelCatalog()
            openRouterModelCatalog = catalog
            openRouterModels = catalog.filter(isOpenRouterEnhancementModel).map(\.id)
            saveOpenRouterModels()
            if reconcileOpenRouterSelection(selectInitialIfNeeded: true) {
                NotificationCenter.default.post(name: .AppSettingsDidChange, object: nil)
            }
            objectWillChange.send()
        } catch {
            // Keep the last successful catalog during transient OpenRouter failures.
        }
    }
}
