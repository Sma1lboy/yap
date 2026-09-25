import AppKit
import Foundation
import SwiftData
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

extension AIProvider {
    /// Config spelling: case and spaces don't matter ("openrouter", "Yap Cloud", "yapcloud").
    init?(configName: String) {
        let normalized = configName.replacingOccurrences(of: " ", with: "").lowercased()
        guard
            let provider = AIProvider.allCases.first(where: {
                $0.rawValue.replacingOccurrences(of: " ", with: "").lowercased() == normalized
            })
        else { return nil }
        self = provider
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
    /// The loaded file has a `version` newer than this build understands.
    @Published private(set) var fileIsNewerVersion = false
    @Published private(set) var lastWritten: Date?
    @Published private(set) var writeError: String?

    private weak var aiService: AIService?
    private weak var enhancementService: AIEnhancementService?
    private weak var transcriptionModelManager: TranscriptionModelManager?
    private weak var recordingShortcutManager: RecordingShortcutManager?
    private weak var menuBarManager: MenuBarManager?
    private weak var recorderUIManager: RecorderUIManager?
    private var modelContext: ModelContext?
    private var config: YapConfig?
    private let defaults = UserDefaults.standard
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "YapConfig")

    private init() {}

    var directoryURL: URL { YapConfig.configDirectory() }
    var fileURL: URL { directoryURL.appendingPathComponent("config.json") }

    func attach(
        aiService: AIService, enhancementService: AIEnhancementService,
        transcriptionModelManager: TranscriptionModelManager, recordingShortcutManager: RecordingShortcutManager,
        menuBarManager: MenuBarManager, recorderUIManager: RecorderUIManager, modelContext: ModelContext
    ) {
        self.aiService = aiService
        self.enhancementService = enhancementService
        self.transcriptionModelManager = transcriptionModelManager
        self.recordingShortcutManager = recordingShortcutManager
        self.menuBarManager = menuBarManager
        self.recorderUIManager = recorderUIManager
        self.modelContext = modelContext
    }

    /// Second half of launch, once services are attached: v2 sections need them, so they apply here
    /// (after onboarding, like the mode patch), then the v1 fields again on top.
    func finishLaunch() async {
        if let config, config.hasSections, defaults.bool(forKey: OnboardingSettings.completedV2Key) {
            let sections = await applySections(config)
            apply(config, source: .file, live: true, patchModes: true, sections: sections)
        }
        await resolveRemoteSelections()
        await CloudConfigSync.shared.sync()
        CloudConfigSync.shared.startAutomaticPulls()
        observeSettingsChanges()
    }

    /// Launch path: writes keys and UserDefaults before services read them at init.
    /// Modes are only patched once onboarding is done, because onboarding rebuilds the starter modes
    /// and re-applies the config when it completes.
    func applyAtLaunch() {
        #if DEBUG
            YapConfig.selfCheck()
            RecommendedSetup.selfCheck()
            Shortcut.configStringSelfCheck()
            Self.selfCheck()
            Task { await CloudConfigSync.selfCheck() }
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

        if let key = Self.transcriptionSelectionKey(config), let manager = transcriptionModelManager {
            if Self.isOpenRouter(config.transcription?.provider) {
                await manager.refreshOpenRouterCatalog()
            } else {
                manager.refreshAllAvailableModels()
            }
            if let model = TranscriptionModelRegistry.model(forSelectionKey: key, in: manager.allAvailableModels) {
                manager.setDefaultTranscriptionModel(model)
            }
        }

        if let provider = Self.enhancementProvider(config), provider == .openRouter, let aiService {
            await aiService.fetchOpenRouterModels()
            if let model = config.enhancement?.model {
                aiService.selectModel(model, for: .openRouter)
            }
        }
    }

    /// Live path for the Settings button and onboarding completion: also updates in-memory service state.
    func reload() async {
        guard let config = load() else { return }
        let sections = await applySections(config)
        apply(config, source: .file, live: true, patchModes: true, sections: sections)
        await resolveRemoteSelections()
    }

    // MARK: - Entry points

    /// The current settings as config.json bytes (schema v2). Nil until services are attached.
    func makeConfigData() async -> Data? {
        guard let enhancementService, let recordingShortcutManager, let menuBarManager, let recorderUIManager,
            let modelContext
        else { return nil }
        let backup = await ImportExportService.shared.makeBackup(
            enhancementService: enhancementService, recordingShortcutManager: recordingShortcutManager,
            menuBarManager: menuBarManager, mediaController: .shared, playbackController: .shared,
            recorderUIManager: recorderUIManager, modelContext: modelContext)
        let existing = (try? Data(contentsOf: fileURL)).flatMap { try? YapConfig.decode($0) }
        var config = YapConfig.exported(from: backup, existing: existing) {
            Self.isNoOp(
                $0, modes: backup.modeConfigs, prompts: backup.customPrompts, promptText: self.promptText)
        }
        // Not part of the backup format, so added here.
        config.customProviders = CustomAIProviderManager.shared.providers
        config = config.normalized().stamped(baseline: baseline, now: Date())
        guard let data = try? config.encoded() else { return nil }
        defaults.set(data, forKey: Self.baselineKey)
        return data
    }

    /// Writes a config pulled from Yap Cloud to config.json. If this Mac keeps its prompt in a file, the pulled
    /// text goes into that file (previous one kept as `<name>.bak`) and config.json keeps the reference.
    func writePulledConfig(_ data: Data) throws {
        let existing = (try? Data(contentsOf: fileURL)).flatMap { try? YapConfig.decode($0) }
        let (config, promptFile) = try YapConfig.decode(data).keepingPromptFile(
            localPrompt: existing?.enhancement?.prompt
        ) { reference in
            YapConfig.promptFileURL(reference, configDirectory: directoryURL)
                .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        }
        if let promptFile, (try? String(contentsOf: promptFile.url, encoding: .utf8)) != promptFile.text {
            let backupURL = promptFile.url.appendingPathExtension("bak")
            try? FileManager.default.removeItem(at: backupURL)
            try FileManager.default.copyItem(at: promptFile.url, to: backupURL)
            try Data(promptFile.text.utf8).write(to: promptFile.url, options: .atomic)
        }
        try writeConfigFile(config.encoded())
    }

    /// `makeConfigData` for Yap Cloud: a prompt kept in a file next to config.json is sent as its text,
    /// because the other Macs don't have that file.
    func makeCloudConfigData() async -> Data? {
        guard let data = await makeConfigData(), let config = try? YapConfig.decode(data) else { return nil }
        return try? config.inliningPromptFile(promptText).encoded()
    }

    /// The last config this Mac exported or applied; export compares against it to stamp changes and deletions.
    static let baselineKey = "configBaseline"
    private var baseline: YapConfig? {
        defaults.data(forKey: Self.baselineKey).flatMap { try? YapConfig.decode($0) }
    }

    /// Applies config.json bytes to the running app: v2 sections first, then the v1 fields on top.
    /// Doesn't touch the file; see `writeConfigFile`.
    func applyConfigData(_ data: Data) async throws {
        let config = try YapConfig.decode(data)
        self.config = config
        fileIsNewerVersion = config.isNewerVersion
        defaults.set(data, forKey: Self.baselineKey)
        let sections = await applySections(config)
        apply(config, source: .file, live: true, patchModes: true, sections: sections)
        await resolveRemoteSelections(config)
    }

    /// Writes config.json, keeping the previous file as config.json.bak. Returns false if the bytes are unchanged.
    @discardableResult
    func writeConfigFile(_ data: Data) throws -> Bool {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        if let old = try? Data(contentsOf: fileURL) {
            if old == data { return false }
            let backupURL = directoryURL.appendingPathComponent("config.json.bak")
            try? fileManager.removeItem(at: backupURL)
            try old.write(to: backupURL)
        }
        try data.write(to: fileURL, options: .atomic)
        return true
    }

    /// The "Write current settings to config" button, and auto-sync.
    func writeCurrentSettings() async {
        guard let data = await makeConfigData() else { return }
        do {
            try writeConfigFile(data)
            lastWritten = Date()
            writeError = nil
        } catch {
            writeError = error.localizedDescription
        }
    }

    // MARK: - Keeping the file in sync

    static let keepInSyncKey = "configFileKeepInSync"
    private var changeObservers: [NSObjectProtocol] = []
    private var pendingSync: Task<Void, Never>?

    /// Settings live in UserDefaults (modes, prompts, general) and SwiftData (dictionary); any change there
    /// schedules a write. The write is a no-op when the bytes match, so the app's own writes don't loop.
    private func observeSettingsChanges() {
        guard changeObservers.isEmpty else { return }
        for name in [UserDefaults.didChangeNotification, ModelContext.didSave] {
            changeObservers.append(
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.settingsDidChange() }
                })
        }
    }

    private func settingsDidChange() {
        guard defaults.bool(forKey: Self.keepInSyncKey) || CloudConfigSync.shared.isEnabled else { return }
        pendingSync?.cancel()
        pendingSync = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            if self.defaults.bool(forKey: Self.keepInSyncKey) { await self.writeCurrentSettings() }
            await CloudConfigSync.shared.sync()
        }
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
        fileIsNewerVersion = false
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            status = .notFound
            return nil
        }
        do {
            let loaded = try YapConfig.decode(Data(contentsOf: fileURL))
            config = loaded
            fileIsNewerVersion = loaded.isNewerVersion
            return loaded
        } catch {
            let message = YapConfig.describe(error)
            logger.error("config.json: \(message, privacy: .public)")
            status = .error(message)
            return nil
        }
    }

    // MARK: - Applying

    /// Imports the v2 sections through the backup importer, one category at a time so one failure doesn't
    /// block the rest. Returns (applied, skipped) section names for the status line.
    private func applySections(_ config: YapConfig) async -> (applied: [String], skipped: [String]) {
        guard config.hasSections else { return ([], []) }
        guard let enhancementService, let recordingShortcutManager, let menuBarManager, let recorderUIManager,
            let modelContext, let transcriptionModelManager
        else { return ([], ["sections"]) }
        let currentModes = ModeManager.shared.configurations
        let currentModeShortcuts = Dictionary(
            uniqueKeysWithValues: currentModes.compactMap { mode in
                ShortcutStore.shortcut(for: .mode(mode.id)).map { (mode.id.uuidString, ShortcutBackup($0)) }
            })
        guard
            let (file, categories) = config.backupSections(
                currentModes: currentModes, currentPrompts: enhancementService.customPrompts,
                currentModeShortcuts: currentModeShortcuts,
                currentCustomModels: CustomCloudModelManager.shared.customModels.map(CustomModelBackup.init(model:)))
        else { return ([], []) }
        var result: (applied: [String], skipped: [String]) = ([], [])
        if config.deleted?.vocabulary != nil || config.deleted?.replacements != nil {
            do {
                try deleteDictionaryEntries(tombstonedIn: config, modelContext: modelContext)
                result.applied.append("deleted")
            } catch {
                logger.error("config.json deleted: \(error.localizedDescription, privacy: .public)")
                result.skipped.append("deleted")
            }
        }
        if let providers = config.mergedCustomProviders(current: CustomAIProviderManager.shared.providers) {
            CustomAIProviderManager.shared.replaceProviders(providers)
            result.applied.append("customProviders")
        }
        for category in categories {
            do {
                try await BackupImporter.apply(
                    file, categories: [category], enhancementService: enhancementService,
                    recordingShortcutManager: recordingShortcutManager, menuBarManager: menuBarManager,
                    mediaController: .shared, playbackController: .shared, recorderUIManager: recorderUIManager,
                    modelContext: modelContext, transcriptionModelManager: transcriptionModelManager)
                result.applied.append(category.rawValue)
            } catch {
                logger.error("config.json \(category.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
                result.skipped.append(category.rawValue)
            }
        }
        return result
    }

    /// The backup importer only adds dictionary entries, so tombstoned ones the file doesn't carry are deleted here.
    private func deleteDictionaryEntries(tombstonedIn config: YapConfig, modelContext: ModelContext) throws {
        let deadWords = Set(config.deleted?.vocabulary?.keys ?? [:].keys)
            .subtracting(config.dictionary?.vocabulary ?? [])
        let deadRules = Set(config.deleted?.replacements?.keys ?? [:].keys)
            .subtracting(config.dictionary?.replacements?.keys ?? [:].keys)
        guard !deadWords.isEmpty || !deadRules.isEmpty else { return }
        for word in try modelContext.fetch(FetchDescriptor<VocabularyWord>()) where deadWords.contains(word.word) {
            modelContext.delete(word)
        }
        for rule in try modelContext.fetch(FetchDescriptor<WordReplacement>())
        where deadRules.contains(rule.originalText) {
            modelContext.delete(rule)
        }
        try modelContext.save()
    }

    private func apply(
        _ config: YapConfig, source: Source, live: Bool, patchModes: Bool,
        sections: (applied: [String], skipped: [String]) = ([], [])
    ) {
        var applied = sections.applied
        var skipped = sections.skipped

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
        if let raw = config.enhancement?.prompt, let text = promptText(raw) {
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
        let provider = Self.enhancementProvider(config)
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
        let transcriptionKey = Self.transcriptionSelectionKey(config)
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

    private static func isOpenRouter(_ name: String?) -> Bool {
        name?.caseInsensitiveCompare("openrouter") == .orderedSame
    }

    private static func enhancementProvider(_ config: YapConfig) -> AIProvider? {
        config.enhancement?.provider.flatMap(AIProvider.init(configName:))
    }

    /// OpenRouter models use the same `OpenRouter:<UUID>` key the app writes; other providers use the model name.
    private static func transcriptionSelectionKey(_ config: YapConfig) -> String? {
        guard let model = config.transcription?.model else { return nil }
        if isOpenRouter(config.transcription?.provider) {
            return "OpenRouter:\(OpenRouterProvider.stableID(for: model).uuidString)"
        }
        if config.transcription?.provider?.replacingOccurrences(of: " ", with: "").lowercased() == "yapcloud" {
            return "YapCloud:\(YapCloudProvider.stableID(for: model).uuidString)"
        }
        return model
    }

    private func promptText(_ raw: String) -> String? {
        raw.caseInsensitiveCompare(RecommendedSetup.promptKeyword) == .orderedSame
            ? RecommendedSetup.prompt
            : YapConfig.resolvePrompt(
                raw, configDirectory: directoryURL, readFile: { try? String(contentsOf: $0, encoding: .utf8) })
    }

    /// Whether applying the v1 fields of `partial` would leave `modes` and `prompts` as they are.
    private static func isNoOp(
        _ partial: YapConfig, modes: [ModeConfig], prompts: [CustomPrompt], promptText: (String) -> String?
    ) -> Bool {
        let provider = enhancementProvider(partial)
        let patch = YapModePatch(
            transcriptionModel: transcriptionSelectionKey(partial),
            aiProvider: provider?.rawValue,
            aiModel: provider == nil ? nil : partial.enhancement?.model,
            enhancementEnabled: partial.enhancement?.enabled,
            promptId: partial.enhancement?.prompt == nil ? nil : YapConfig.promptID.uuidString,
            defaultMode: partial.defaultMode)
        if !YapConfig.sameContent(patch.apply(to: modes), modes) { return false }
        if let raw = partial.enhancement?.prompt {
            return prompts.first { $0.id == YapConfig.promptID }?.promptText == promptText(raw)
        }
        return true
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

            // Export is idempotent: the written file, read back, changes nothing.
            let promptID = YapConfig.promptID
            let current = ModeConfig(
                name: "Dictation", isAIEnhancementEnabled: true, selectedPrompt: promptID.uuidString,
                selectedTranscriptionModelName: "whisper-x", selectedAIProvider: "OpenRouter", selectedAIModel: "m",
                isDefault: true)
            let prompts = [CustomPrompt(id: promptID, title: "config.json", promptText: "Fix.")]
            let backup = BackupFile(
                version: "1", customPrompts: prompts, modeConfigs: [current], modeShortcuts: nil,
                vocabularyWords: [WordBackup(word: "Yap")], wordReplacements: ["yep": "Yap"], generalSettings: nil,
                customEmojis: nil, customCloudModels: nil)
            var existing = YapConfig(
                keys: ["openrouter": "env:OPENROUTER_API_KEY", "groq": "gsk-literal"],
                transcription: .init(provider: "local", model: "whisper-x"),
                enhancement: .init(enabled: true, provider: "openrouter", model: "other", prompt: "Fix."),
                defaultMode: .init(screenContext: true))
            let noOp: (YapConfig) -> Bool = {
                Self.isNoOp($0, modes: [current], prompts: prompts, promptText: { $0 })
            }
            let exported = YapConfig.exported(from: backup, existing: existing, isNoOp: noOp)
            assert(exported.version == 2 && exported.keys == ["openrouter": "env:OPENROUTER_API_KEY"])
            assert(exported.transcription?.model == "whisper-x")
            // The file's model "other" no longer matches the mode's "m", so provider/model are dropped.
            assert(exported.enhancement == .init(prompt: "Fix.") && exported.defaultMode == nil)
            guard let data = try? exported.encoded(), let reread = try? YapConfig.decode(data) else {
                return assertionFailure("exported config should round-trip")
            }
            assert(reread == exported && (try? reread.encoded()) == data)
            assert(noOp(reread) && YapConfig.sameContent(YapConfig.mergedByID([current], reread.modes ?? []), [current]))
            assert(YapConfig.mergedByID(prompts, reread.prompts ?? []) == prompts)
            existing.enhancement?.prompt = "Changed in the file."
            assert(YapConfig.exported(from: backup, existing: existing, isNoOp: noOp).enhancement == nil)
            assert(
                OpenRouterProvider.stableID(for: "microsoft/mai-transcribe-2").uuidString
                    == "ECA8DB85-56DA-3FC6-6B4D-86D9215F15D1")
        }
    #endif
}
