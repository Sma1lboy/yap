import Foundation
import SwiftData

/// One-time move from VoiceInk (the app Yap forks) on the same Mac: its modes, prompts, dictionary, shortcuts and
/// general settings, turned into a v2 config and applied like config.json (merged by id). API keys, license
/// state, history and models are left behind. Only runs when the user asks, from Settings → Config & Sync.
enum VoiceInkImport {
    /// Upstream's bundle id (VoiceInk.xcodeproj). Not sandboxed, so its defaults live in
    /// ~/Library/Preferences/<id>.plist and its data in ~/Library/Application Support/<id>/.
    static let bundleID = "com.prakashjoshipax.VoiceInk"

    static var dataDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleID, isDirectory: true)
    }

    /// VoiceInk's stored defaults (its plist only: a UserDefaults suite would also answer with Yap's registered
    /// defaults), or nil when this Mac has never run it.
    static func installedDefaults() -> [String: Any]? {
        guard let domain = UserDefaults.standard.persistentDomain(forName: bundleID), !domain.isEmpty else {
            return nil
        }
        return domain
    }

    /// The settings found in `defaults` (VoiceInk's stored domain, or a test suite's) plus its dictionary, as a v2
    /// config. Settings VoiceInk never stored stay unset, so they don't overwrite Yap's.
    static func config(from defaults: [String: Any], dictionary: YapConfig.DictionarySection?) -> YapConfig {
        func decode<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
            (defaults[key] as? Data).flatMap { try? JSONDecoder().decode(type, from: $0) }
        }
        func shortcut(_ action: ShortcutAction) -> ShortcutBackup? {
            guard defaults["\(action.userDefaultsKey)_cleared"] as? Bool != true else { return nil }
            return decode(ShortcutBackup.self, action.userDefaultsKey)
        }
        func bool(_ key: String) -> Bool? { defaults[key] as? Bool }
        func int(_ key: String) -> Int? { defaults[key] as? Int }
        func double(_ key: String) -> Double? { defaults[key] as? Double }
        func string(_ key: String) -> String? { defaults[key] as? String }

        var config = YapConfig()
        config.version = YapConfig.currentVersion
        config.modes = decode([ModeConfig].self, "modeConfigurationsV2")
            ?? decode([ModeConfig].self, "powerModeConfigurationsV2")
        config.prompts = decode([CustomPrompt].self, "customPrompts")
        config.modeShortcuts = (config.modes ?? []).reduce(into: [String: ShortcutBackup]()) { result, mode in
            result[mode.id.uuidString] = shortcut(.mode(mode.id))
        }
        config.dictionary = dictionary
        let general = GeneralBackup(
            primaryRecordingShortcut: shortcut(.primaryRecording),
            secondaryRecordingShortcut: shortcut(.secondaryRecording),
            pasteLastTranscriptionShortcut: shortcut(.pasteLastTranscription),
            pasteLastEnhancementShortcut: shortcut(.pasteLastEnhancement),
            retryLastTranscriptionShortcut: shortcut(.retryLastTranscription),
            cancelRecorderShortcut: shortcut(.cancelRecorder),
            openHistoryWindowShortcut: shortcut(.openQuickHistory),
            quickAddToDictionaryShortcut: shortcut(.quickAddToDictionary),
            primaryRecordingShortcutRawValue: string("primaryRecordingShortcut"),
            secondaryRecordingShortcutRawValue: string("secondaryRecordingShortcut"),
            primaryRecordingShortcutModeRawValue: string("primaryRecordingShortcutMode"),
            secondaryRecordingShortcutModeRawValue: string("secondaryRecordingShortcutMode"),
            launchAtLoginEnabled: nil,  // a system login item, not a VoiceInk setting
            isMenuBarOnly: bool("IsMenuBarOnly"),
            recorderType: string("RecorderType"),
            appAppearancePreference: string(AppAppearancePreference.userDefaultsKey),
            appLanguagePreference: string(AppLanguagePreference.userDefaultsKey),
            isTranscriptionCleanupEnabled: bool(CleanupSettingsKeys.isTranscriptionCleanupEnabled),
            transcriptionRetentionMinutes: int(CleanupSettingsKeys.transcriptionRetentionMinutes),
            isAudioCleanupEnabled: bool(CleanupSettingsKeys.isAudioCleanupEnabled),
            audioRetentionPeriod: int(CleanupSettingsKeys.audioRetentionPeriod),
            isSystemMuteEnabled: bool("isSystemMuteEnabled"),
            isPauseMediaEnabled: bool("isPauseMediaEnabled"),
            audioResumptionDelay: double("audioResumptionDelay"),
            isTextFormattingEnabled: bool("IsTextFormattingEnabled"),
            restoreClipboardAfterPaste: bool("restoreClipboardAfterPaste"),
            clipboardRestoreDelay: double("clipboardRestoreDelay"),
            finishAndSendKey: string(FinishAndSendSettings.key),
            isAutoLearnDictionaryEnabled: bool(AutoLearnSettings.isEnabledKey),
            autoLearnReviewSchedule: string(AutoLearnSettings.reviewScheduleKey),
            autoLearnProvider: string(AutoLearnSettings.providerKey),
            autoLearnModel: string(AutoLearnSettings.modelKey))
        config.general = Self.isEmpty(general) ? nil : general
        return config.normalized()
    }

    /// VoiceInk's dictionary, read from a copy of its store so VoiceInk's own file is never opened for writing.
    /// Nil when there is none or it can't be read.
    static func readDictionary(in directory: URL = dataDirectory) -> YapConfig.DictionarySection? {
        let fileManager = FileManager.default
        let store = directory.appendingPathComponent("dictionary.store")
        guard fileManager.fileExists(atPath: store.path) else { return nil }
        let copyDirectory = fileManager.temporaryDirectory.appendingPathComponent("voiceink-import-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: copyDirectory) }
        do {
            try fileManager.createDirectory(at: copyDirectory, withIntermediateDirectories: true)
            for suffix in ["", "-shm", "-wal"] where fileManager.fileExists(atPath: store.path + suffix) {
                try fileManager.copyItem(
                    at: URL(fileURLWithPath: store.path + suffix),
                    to: copyDirectory.appendingPathComponent("dictionary.store" + suffix))
            }
            let schema = Schema([VocabularyWord.self, WordReplacement.self])
            let configuration = ModelConfiguration(
                "dictionary", schema: schema, url: copyDirectory.appendingPathComponent("dictionary.store"),
                cloudKitDatabase: .none)
            let context = ModelContext(try ModelContainer(for: schema, configurations: configuration))
            let words = try context.fetch(FetchDescriptor<VocabularyWord>()).map(\.word)
            let rules = try context.fetch(FetchDescriptor<WordReplacement>())
            return YapConfig.DictionarySection(
                vocabulary: words,
                replacements: Dictionary(rules.map { ($0.originalText, $0.replacementText) }) { _, last in last })
        } catch {
            return nil
        }
    }

    private static func isEmpty(_ general: GeneralBackup) -> Bool {
        (try? JSONEncoder().encode(general)).map { $0 == Data("{}".utf8) } ?? true
    }
}

#if DEBUG
    extension VoiceInkImport {
        static func selfCheck() {
            let suite = "yap.selfcheck.voiceink.\(UUID().uuidString)"
            guard let defaults = UserDefaults(suiteName: suite) else { return assertionFailure("no test suite") }
            defer { defaults.removePersistentDomain(forName: suite) }

            // An empty domain: nothing to import.
            let nothing = config(from: defaults.persistentDomain(forName: suite) ?? [:], dictionary: nil)
            assert(!nothing.hasSections && nothing.general == nil)

            let mode = ModeConfig(
                id: UUID(uuidString: "88888888-8888-4888-8888-888888888888")!, name: "Email",
                isAIEnhancementEnabled: true, selectedLanguage: "en")
            let prompt = CustomPrompt(title: "Tidy", promptText: "Tidy it.")
            let modeShortcut = Shortcut.key(keyCode: 3, modifierFlags: [.command, .option])
            let primary = Shortcut.modifierOnly(keyCode: 61, modifierFlags: [.option])
            defaults.set(try? JSONEncoder().encode([mode]), forKey: "modeConfigurationsV2")
            defaults.set(try? JSONEncoder().encode([prompt]), forKey: "customPrompts")
            defaults.set(try? JSONEncoder().encode(modeShortcut), forKey: ShortcutAction.mode(mode.id).userDefaultsKey)
            defaults.set(try? JSONEncoder().encode(primary), forKey: ShortcutAction.primaryRecording.userDefaultsKey)
            // A cleared shortcut stays cleared rather than importing the stale data behind it.
            defaults.set(try? JSONEncoder().encode(primary), forKey: ShortcutAction.cancelRecorder.userDefaultsKey)
            defaults.set(true, forKey: "\(ShortcutAction.cancelRecorder.userDefaultsKey)_cleared")
            defaults.set(true, forKey: "IsMenuBarOnly")
            defaults.set("notch", forKey: "RecorderType")
            // Things that must never come over.
            defaults.set("sk-secret", forKey: "OpenRouterAPIKey")
            defaults.set("LICENSE-KEY", forKey: "VoiceInkLicense")

            let imported = config(
                from: defaults.persistentDomain(forName: suite) ?? [:], dictionary: .init(vocabulary: ["VoiceInk"], replacements: ["voice ink": "VoiceInk"]))
            assert(imported.modes?.map(\.name) == ["Email"] && imported.prompts?.map(\.title) == ["Tidy"])
            assert(imported.modeShortcuts?[mode.id.uuidString]?.shortcut == modeShortcut)
            assert(imported.general?.primaryRecordingShortcut?.shortcut == primary)
            assert(imported.general?.cancelRecorderShortcut == nil)
            assert(imported.general?.isMenuBarOnly == true && imported.general?.recorderType == "notch")
            assert(imported.general?.restoreClipboardAfterPaste == nil)  // not set in VoiceInk → Yap's stays
            assert(imported.restoreSummary == .init(modes: 1, prompts: 1, dictionaryEntries: 2, shortcuts: 2))
            let written = (try? imported.encoded()).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            assert(!written.contains("sk-secret") && !written.contains("LICENSE") && imported.keys == nil)
        }
    }
#endif
