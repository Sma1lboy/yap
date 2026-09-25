import AppKit
import Foundation
import os

/// The mode changes a config file asks for. Pure so it can be checked without UserDefaults.
struct YapModePatch: Equatable {
    var transcriptionModel: String?
    var aiProvider: String?
    var aiModel: String?
    var enhancementEnabled: Bool?
    var promptId: String?
    var defaultMode: YapConfig.DefaultMode?

    var isEmpty: Bool { self == YapModePatch() }

    /// Transcription model goes on every mode (it is what recording uses); the AI provider/model on
    /// enhancement modes and the default mode; enhancement toggle, prompt and contexts on the default mode only.
    /// Appends a default "Dictation" mode when none exists.
    func apply(to modes: [ModeConfig]) -> [ModeConfig] {
        guard !isEmpty else { return modes }
        var modes = modes
        if !modes.contains(where: \.isDefault) {
            modes.append(
                ModeConfig(
                    name: "Dictation", isAIEnhancementEnabled: false, selectedLanguage: "auto",
                    isEnabled: true, isDefault: true))
        }

        for index in modes.indices {
            if let transcriptionModel { modes[index].selectedTranscriptionModelName = transcriptionModel }

            let isDefault = modes[index].isDefault
            if isDefault {
                if let enhancementEnabled { modes[index].isAIEnhancementEnabled = enhancementEnabled }
                if let promptId { modes[index].selectedPrompt = promptId }
                if let value = defaultMode?.screenContext { modes[index].useScreenCapture = value }
                if let value = defaultMode?.clipboardContext { modes[index].useClipboardContext = value }
                if let value = defaultMode?.selectedTextContext { modes[index].useSelectedTextContext = value }
            }
            if isDefault || modes[index].isAIEnhancementEnabled {
                if let aiProvider { modes[index].selectedAIProvider = aiProvider }
                if let aiModel { modes[index].selectedAIModel = aiModel }
            }
        }
        return modes
    }
}

/// Applies `~/.config/yap/config.json` (or `$XDG_CONFIG_HOME/yap/config.json`) on top of in-app settings.
@MainActor
final class YapConfigLoader: ObservableObject {
    enum Status: Equatable {
        case notFound
        case loaded(date: Date, applied: [String], skipped: [String])
        case error(String)
    }

    static let shared = YapConfigLoader()

    @Published private(set) var status: Status = .notFound

    private weak var aiService: AIService?
    private weak var enhancementService: AIEnhancementService?
    private weak var transcriptionModelManager: TranscriptionModelManager?
    private var config: YapConfig?
    private let defaults = UserDefaults.standard
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "YapConfig")

    private init() {}

    var directoryURL: URL { YapConfig.configDirectory() }
    var fileURL: URL { directoryURL.appendingPathComponent("config.json") }

    func attach(
        aiService: AIService, enhancementService: AIEnhancementService,
        transcriptionModelManager: TranscriptionModelManager
    ) {
        self.aiService = aiService
        self.enhancementService = enhancementService
        self.transcriptionModelManager = transcriptionModelManager
    }

    /// Launch path: writes keys and UserDefaults before services read them at init.
    /// Modes are only patched once onboarding is done, because onboarding rebuilds the starter modes
    /// and re-applies the config when it completes.
    func applyAtLaunch() {
        #if DEBUG
            YapConfig.selfCheck()
            RecommendedSetup.selfCheck()
            Self.selfCheck()
        #endif
        guard let config = load() else { return }
        apply(config, source: .file, live: false, patchModes: defaults.bool(forKey: OnboardingSettings.completedV2Key))
    }

    enum Source {
        case file
        /// The onboarding preset; doesn't touch `status`, which only describes config.json.
        case recommended
    }

    /// Applies an in-memory config through the same path as config.json, live when services are attached.
    func apply(config: YapConfig, source: Source, patchModes: Bool) async {
        apply(config, source: source, live: aiService != nil, patchModes: patchModes)
        await resolveRemoteSelections(config)
    }

    /// Fetches the OpenRouter catalogs the configured selections depend on (not loaded at launch otherwise),
    /// then selects the configured models so catalog reconciliation doesn't replace them.
    func resolveRemoteSelections() async {
        guard let config else { return }
        await resolveRemoteSelections(config)
    }

    private func resolveRemoteSelections(_ config: YapConfig) async {

        if let key = transcriptionSelectionKey(config), let manager = transcriptionModelManager {
            if isOpenRouter(config.transcription?.provider) {
                await manager.refreshOpenRouterCatalog()
            } else {
                manager.refreshAllAvailableModels()
            }
            if let model = TranscriptionModelRegistry.model(forSelectionKey: key, in: manager.allAvailableModels) {
                manager.setDefaultTranscriptionModel(model)
            }
        }

        if let provider = enhancementProvider(config), provider == .openRouter, let aiService {
            await aiService.fetchOpenRouterModels()
            if let model = config.enhancement?.model {
                aiService.selectModel(model, for: .openRouter)
            }
        }
    }

    /// Live path for the Settings button and onboarding completion: also updates in-memory service state.
    func reload() async {
        guard let config = load() else { return }
        apply(config, source: .file, live: true, patchModes: true)
        await resolveRemoteSelections()
    }

    func openConfigFile() {
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                try Data(YapConfig.template.utf8).write(to: fileURL)
            }
            NSWorkspace.shared.open(fileURL)
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    func revealConfigFile() {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        } else {
            openConfigFolder()
        }
    }

    func openConfigFolder() {
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directoryURL)
    }

    // MARK: - Loading

    private func load() -> YapConfig? {
        config = nil
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            status = .notFound
            return nil
        }
        do {
            let loaded = try YapConfig.decode(Data(contentsOf: fileURL))
            config = loaded
            return loaded
        } catch {
            let message = YapConfig.describe(error)
            logger.error("config.json: \(message, privacy: .public)")
            status = .error(message)
            return nil
        }
    }

    // MARK: - Applying

    private func apply(_ config: YapConfig, source: Source, live: Bool, patchModes: Bool) {
        var applied: [String] = []
        var skipped: [String] = []

        // Keys
        var keysChanged = false
        let environment = ProcessInfo.processInfo.environment
        let dotEnvURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".env")
        for (name, raw) in (config.keys ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard
                let key = YapConfig.resolveSecret(
                    raw, environment: environment, dotEnv: { try? String(contentsOf: dotEnvURL, encoding: .utf8) })
            else {
                skipped.append("keys.\(name)")
                continue
            }
            if APIKeyManager.shared.getAPIKey(forProvider: name) != key {
                guard APIKeyManager.shared.saveAPIKey(key, forProvider: name) else {
                    skipped.append("keys.\(name)")
                    continue
                }
                keysChanged = true
            }
            applied.append("keys.\(name)")
        }

        // Prompt
        var promptId: String?
        if let raw = config.enhancement?.prompt,
            let text = raw.caseInsensitiveCompare(RecommendedSetup.promptKeyword) == .orderedSame
                ? RecommendedSetup.prompt
                : YapConfig.resolvePrompt(
                    raw, configDirectory: directoryURL, readFile: { try? String(contentsOf: $0, encoding: .utf8) })
        {
            let prompt = CustomPrompt(
                id: YapConfig.promptID, title: source == .file ? "config.json" : "Recommended", promptText: text,
                useSystemInstructions: false)
            if live, let enhancementService {
                enhancementService.customPrompts = Self.upserting(prompt, into: enhancementService.customPrompts)
            } else {
                let stored = defaults.data(forKey: "customPrompts")
                    .flatMap { try? JSONDecoder().decode([CustomPrompt].self, from: $0) } ?? []
                if let data = try? JSONEncoder().encode(Self.upserting(prompt, into: stored)) {
                    defaults.set(data, forKey: "customPrompts")
                }
            }
            promptId = prompt.id.uuidString
            applied.append("enhancement.prompt")
        }

        // Enhancement provider/model
        let provider = enhancementProvider(config)
        let model = config.enhancement?.model
        if config.enhancement?.provider != nil && provider == nil {
            skipped.append("enhancement.provider")
        } else if model != nil && provider == nil {
            skipped.append("enhancement.model")
        } else if let provider {
            if live, let aiService {
                if aiService.selectedProvider != provider { aiService.selectedProvider = provider }
                if let model { aiService.selectModel(model, for: provider) }
            } else {
                defaults.set(provider.rawValue, forKey: "selectedAIProvider")
                if let model { defaults.set(model, forKey: "\(provider.rawValue)SelectedModel") }
            }
            applied.append(model == nil ? "enhancement.provider" : "enhancement.model")
        }
        if config.enhancement?.enabled != nil { applied.append("enhancement.enabled") }

        // Transcription
        let transcriptionKey = transcriptionSelectionKey(config)
        if let transcriptionKey {
            defaults.set(transcriptionKey, forKey: "CurrentTranscriptionModel")
            applied.append("transcription")
        } else if config.transcription != nil {
            skipped.append("transcription.model")
        }
        if config.defaultMode != nil { applied.append("defaultMode") }

        // Modes
        let patch = YapModePatch(
            transcriptionModel: transcriptionKey,
            aiProvider: provider?.rawValue,
            aiModel: provider == nil ? nil : model,
            enhancementEnabled: config.enhancement?.enabled,
            promptId: promptId,
            defaultMode: config.defaultMode
        )
        if patchModes && !patch.isEmpty {
            if live {
                ModeManager.shared.replaceConfigurations(patch.apply(to: ModeManager.shared.configurations))
                enhancementService?.repairModePromptSelections()
            } else {
                let key = "modeConfigurationsV2"
                let modes = defaults.data(forKey: key)
                    .flatMap { try? JSONDecoder().decode([ModeConfig].self, from: $0) } ?? []
                if let data = try? JSONEncoder().encode(patch.apply(to: modes)) {
                    defaults.set(data, forKey: key)
                }
            }
            applied.append("modes")
        }

        if keysChanged && live {
            NotificationCenter.default.post(name: .aiProviderKeyChanged, object: nil)
        }
        if source == .file { status = .loaded(date: Date(), applied: applied, skipped: skipped) }
        logger.info("\(source == .file ? "config.json" : "recommended setup", privacy: .public) applied: \(applied.joined(separator: ", "), privacy: .public)")
    }

    // MARK: - Mapping

    private func isOpenRouter(_ name: String?) -> Bool {
        name?.caseInsensitiveCompare("openrouter") == .orderedSame
    }

    private func enhancementProvider(_ config: YapConfig) -> AIProvider? {
        guard let name = config.enhancement?.provider else { return nil }
        let normalized = name.replacingOccurrences(of: " ", with: "").lowercased()
        return AIProvider.allCases.first {
            $0.rawValue.replacingOccurrences(of: " ", with: "").lowercased() == normalized
        }
    }

    /// OpenRouter models use the same `OpenRouter:<UUID>` key the app writes; other providers use the model name.
    private func transcriptionSelectionKey(_ config: YapConfig) -> String? {
        guard let model = config.transcription?.model else { return nil }
        if isOpenRouter(config.transcription?.provider) {
            return "OpenRouter:\(OpenRouterProvider.stableID(for: model).uuidString)"
        }
        return model
    }

    private static func upserting(_ prompt: CustomPrompt, into prompts: [CustomPrompt]) -> [CustomPrompt] {
        var prompts = prompts
        if let index = prompts.firstIndex(where: { $0.id == prompt.id }) {
            prompts[index] = prompt
        } else {
            prompts.append(prompt)
        }
        return prompts
    }

    #if DEBUG
        private static func selfCheck() {
            let clean = ModeConfig(
                name: "Clean", isAIEnhancementEnabled: false, selectedTranscriptionModelName: "old",
                useSelectedTextContext: true, isDefault: true)
            let email = ModeConfig(name: "Email", isAIEnhancementEnabled: true, selectedAIProvider: "Groq")
            let plain = ModeConfig(name: "Plain", isAIEnhancementEnabled: false)
            let patch = YapModePatch(
                transcriptionModel: "OpenRouter:X", aiProvider: "OpenRouter", aiModel: "m", enhancementEnabled: true,
                promptId: "P", defaultMode: .init(screenContext: false, clipboardContext: nil, selectedTextContext: false))

            let patched = patch.apply(to: [clean, email, plain])
            assert(patched.count == 3 && patched.allSatisfy { $0.selectedTranscriptionModelName == "OpenRouter:X" })
            assert(patched[0].isAIEnhancementEnabled && patched[0].selectedPrompt == "P")
            assert(!patched[0].useSelectedTextContext && patched[0].selectedAIModel == "m")
            assert(patched[1].selectedAIProvider == "OpenRouter" && patched[1].selectedPrompt == nil)
            assert(patched[2].selectedAIProvider == nil)

            let created = patch.apply(to: [plain])
            assert(created.count == 2 && created[1].isDefault && created[1].name == "Dictation")
            assert(created[1].isAIEnhancementEnabled && created[1].selectedPrompt == "P")
            assert(YapModePatch().apply(to: []).isEmpty)
            assert(
                OpenRouterProvider.stableID(for: "microsoft/mai-transcribe-2").uuidString
                    == "ECA8DB85-56DA-3FC6-6B4D-86D9215F15D1")
        }
    #endif
}
