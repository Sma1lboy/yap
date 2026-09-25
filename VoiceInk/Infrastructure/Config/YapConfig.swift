import Foundation

/// `~/.config/yap/config.json`. Every field is optional; empty strings, arrays and objects count as unset.
/// v2 adds whole-settings sections that reuse the backup export types, so both files share one JSON shape.
struct YapConfig: Codable, Equatable {
    struct Transcription: Codable, Equatable {
        var provider: String?
        var model: String?
    }

    struct Enhancement: Codable, Equatable {
        var enabled: Bool?
        var provider: String?
        var model: String?
        /// A file path (relative to the config dir, absolute, or `~/...`) or inline prompt text.
        var prompt: String?
    }

    struct DefaultMode: Codable, Equatable {
        var screenContext: Bool?
        var clipboardContext: Bool?
        var selectedTextContext: Bool?
    }

    struct DictionarySection: Codable, Equatable {
        var vocabulary: [String]?
        var replacements: [String: String]?
    }

    var keys: [String: String]?
    var transcription: Transcription?
    var enhancement: Enhancement?
    var defaultMode: DefaultMode?

    // v2
    var version: Int?
    var modes: [ModeConfig]?
    var modeShortcuts: [String: ShortcutBackup]?
    var prompts: [CustomPrompt]?
    var dictionary: DictionarySection?
    var general: GeneralBackup?

    var hasSections: Bool {
        modes != nil || prompts != nil || dictionary != nil || general != nil
    }

    static let currentVersion = 2

    /// True when the file was written by a newer Yap; its unknown fields were ignored.
    var isNewerVersion: Bool { (version ?? 1) > Self.currentVersion }

    /// Items in `overrides` replace the item with the same id in `base` in place; new ids are appended.
    static func mergedByID<T: Identifiable>(_ base: [T], _ overrides: [T]) -> [T] {
        var result = base
        for item in overrides {
            if let index = result.firstIndex(where: { $0.id == item.id }) {
                result[index] = item
            } else {
                result.append(item)
            }
        }
        return result
    }

    /// The v2 sections as a backup file plus the categories present, for `BackupImporter`. The importer replaces
    /// modes, prompts and mode shortcuts wholesale, so they are merged by id into the current ones here:
    /// entries in the file win, entries only in the app stay.
    func backupSections(
        currentModes: [ModeConfig], currentPrompts: [CustomPrompt], currentModeShortcuts: [String: ShortcutBackup]
    ) -> (file: BackupFile, categories: [BackupCategory])? {
        guard hasSections else { return nil }
        let categories: [BackupCategory] = [
            prompts.map { _ in .prompts }, modes.map { _ in .modes }, dictionary.map { _ in .dictionary },
            general.map { _ in .general },
        ].compactMap { $0 }
        let file = BackupFile(
            version: "config-v\(version ?? 1)",
            customPrompts: Self.mergedByID(currentPrompts, prompts ?? []),
            modeConfigs: Self.mergedByID(currentModes, modes ?? []),
            modeShortcuts: currentModeShortcuts.merging(modeShortcuts ?? [:]) { $1 }, vocabularyWords: dictionary?.vocabulary?.map(WordBackup.init(word:)),
            wordReplacements: dictionary?.replacements, generalSettings: general, customEmojis: nil,
            customCloudModels: nil)
        return (file, categories)
    }

    static let promptID = UUID(uuidString: "A1B2C3D4-0000-4000-8000-00000000C0DE")!

    static let template = """
        {
          "keys": { "openrouter": "" },
          "transcription": { "provider": "", "model": "" },
          "enhancement": { "provider": "", "model": "", "prompt": "" },
          "defaultMode": {}
        }

        """

    // MARK: - Locations

    static func configDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let xdg = environment["XDG_CONFIG_HOME"]?.nonEmpty {
            return URL(fileURLWithPath: (xdg as NSString).expandingTildeInPath).appendingPathComponent("yap")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/yap")
    }

    // MARK: - Parsing

    /// Decodes and drops empty strings/sections so callers only see fields that were actually set.
    static func decode(_ data: Data) throws -> YapConfig {
        try JSONDecoder().decode(YapConfig.self, from: data).normalized()
    }

    func normalized() -> YapConfig {
        var config = self
        config.keys = config.keys?.filter { $0.value.nonEmpty != nil }
        if config.keys?.isEmpty == true { config.keys = nil }
        if var transcription = config.transcription {
            transcription.provider = transcription.provider?.nonEmpty
            transcription.model = transcription.model?.nonEmpty
            config.transcription = transcription == Transcription() ? nil : transcription
        }
        if var enhancement = config.enhancement {
            enhancement.provider = enhancement.provider?.nonEmpty
            enhancement.model = enhancement.model?.nonEmpty
            enhancement.prompt = enhancement.prompt?.nonEmpty
            config.enhancement = enhancement == Enhancement() ? nil : enhancement
        }
        if config.defaultMode == DefaultMode() { config.defaultMode = nil }
        if config.modes?.isEmpty == true { config.modes = nil }
        if config.modeShortcuts?.isEmpty == true { config.modeShortcuts = nil }
        if config.prompts?.isEmpty == true { config.prompts = nil }
        if var dictionary = config.dictionary {
            dictionary.vocabulary = dictionary.vocabulary?.compactMap(\.nonEmpty)
            if dictionary.vocabulary?.isEmpty == true { dictionary.vocabulary = nil }
            if dictionary.replacements?.isEmpty == true { dictionary.replacements = nil }
            config.dictionary = dictionary == DictionarySection() ? nil : dictionary
        }
        return config
    }

    /// Stable bytes for config.json: sorted keys, so writing the same settings twice gives the same file.
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self) + Data("\n".utf8)
    }

    // MARK: - Export

    /// A v2 config describing `backup` (the current settings). From `existing` it keeps only the `env:` key
    /// references (never a literal key) and the v1 `transcription`, `enhancement` provider/model and
    /// `enhancement.prompt` groups that `isNoOp` says would change nothing when applied again, so reading the
    /// written file back leaves the settings as they are. `defaultMode` and `enhancement.enabled` are dropped:
    /// `modes` carries them.
    static func exported(from backup: BackupFile, existing: YapConfig?, isNoOp: (YapConfig) -> Bool) -> YapConfig {
        var config = YapConfig()
        config.version = currentVersion
        config.keys = existing?.keys?.filter { $0.value.trimmingCharacters(in: .whitespaces).hasPrefix("env:") }
        if let transcription = existing?.transcription, isNoOp(YapConfig(transcription: transcription)) {
            config.transcription = transcription
        }
        if let old = existing?.enhancement {
            var enhancement = Enhancement()
            let providerModel = Enhancement(provider: old.provider, model: old.model)
            if providerModel != Enhancement(), isNoOp(YapConfig(enhancement: providerModel)) {
                (enhancement.provider, enhancement.model) = (old.provider, old.model)
            }
            if let prompt = old.prompt, isNoOp(YapConfig(enhancement: Enhancement(prompt: prompt))) {
                enhancement.prompt = prompt
            }
            config.enhancement = enhancement
        }
        config.modes = backup.modeConfigs
        config.modeShortcuts = backup.modeShortcuts
        config.prompts = backup.customPrompts
        config.dictionary = DictionarySection(
            vocabulary: backup.vocabularyWords?.map(\.word).sorted(), replacements: backup.wordReplacements)
        config.general = backup.generalSettings
        return config.normalized()
    }

    // MARK: - Merge

    /// Content equality. `ModeConfig ==` compares only ids, so "did this change" checks compare JSON instead.
    static func sameContent<T: Encodable>(_ lhs: T, _ rhs: T) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(lhs)) == (try? encoder.encode(rhs))
    }

    /// Human-readable decoding error that names the JSON path, e.g. `enhancement.enabled: Expected Bool`.
    static func describe(_ error: Error) -> String {
        func path(_ codingPath: [CodingKey]) -> String {
            let joined = codingPath.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
            return joined.isEmpty ? "(root)" : joined
        }
        switch error as? DecodingError {
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            let underlying = (context.underlyingError as NSError?)?.userInfo[NSDebugDescriptionErrorKey] as? String
            return "\(path(context.codingPath)): \(underlying ?? context.debugDescription)"
        case .keyNotFound(let key, let context):
            return "\(path(context.codingPath + [key])): missing key"
        default:
            return error.localizedDescription
        }
    }

    /// Parses `KEY=VALUE` lines (optional `export `, `#` comments, surrounding quotes stripped).
    static func parseDotEnv(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)) }
            guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" {
                value = String(value.dropFirst().dropLast())
            }
            if !key.isEmpty { result[key] = value }
        }
        return result
    }

    /// Resolves a key value: `env:NAME` reads the environment, then `~/.env`; anything else is literal.
    /// Returns nil for empty or unresolved values.
    static func resolveSecret(_ value: String, environment: [String: String], dotEnv: () -> String?) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("env:") else { return trimmed.nonEmpty }
        let name = String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespaces)
        if let fromEnv = environment[name]?.nonEmpty { return fromEnv }
        return dotEnv().flatMap { parseDotEnv($0)[name]?.nonEmpty }
    }

    /// Reads the prompt from a file when `value` names an existing file, otherwise returns it as inline text.
    static func resolvePrompt(_ value: String, configDirectory: URL, readFile: (URL) -> String?) -> String? {
        guard let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        let url =
            expanded.hasPrefix("/")
            ? URL(fileURLWithPath: expanded) : configDirectory.appendingPathComponent(trimmed)
        if !trimmed.contains("\n"), let text = readFile(url) { return text }
        return trimmed
    }
}

extension String {
    fileprivate var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

#if DEBUG
    extension YapConfig {
        private struct Tag: Identifiable, Equatable {
            let id: Int
            var value = ""
            init(_ id: Int, _ value: String = "") { (self.id, self.value) = (id, value) }
        }

        static func selfCheck() {
            let env = parseDotEnv("# c\nexport A=\"x y\"\nB='z'\nC=plain=eq\n\nD=")
            assert(env == ["A": "x y", "B": "z", "C": "plain=eq", "D": ""])
            assert(resolveSecret("env:A", environment: ["A": "fromEnv"], dotEnv: { "A=fromFile" }) == "fromEnv")
            assert(resolveSecret("env:A", environment: [:], dotEnv: { "A=fromFile" }) == "fromFile")
            assert(resolveSecret("env:A", environment: [:], dotEnv: { nil }) == nil)
            assert(resolveSecret("  ", environment: [:], dotEnv: { nil }) == nil)
            assert(resolveSecret("sk-or-1", environment: [:], dotEnv: { nil }) == "sk-or-1")
            let dir = URL(fileURLWithPath: "/cfg")
            let files = ["/cfg/prompt.md": "FILE", "/abs/p.md": "ABS"]
            let read: (URL) -> String? = { files[$0.path] }
            assert(resolvePrompt("prompt.md", configDirectory: dir, readFile: read) == "FILE")
            assert(resolvePrompt("/abs/p.md", configDirectory: dir, readFile: read) == "ABS")
            assert(resolvePrompt("Fix grammar.", configDirectory: dir, readFile: read) == "Fix grammar.")
            assert(resolvePrompt("", configDirectory: dir, readFile: read) == nil)
            assert((try? decode(Data(template.utf8))) == YapConfig())
            let partial = try? decode(Data(#"{"transcription":{"provider":"openrouter","model":" "}}"#.utf8))
            assert(partial?.transcription == Transcription(provider: "openrouter", model: nil))
            do {
                _ = try decode(Data(#"{"enhancement":{"enabled":"yes"}}"#.utf8))
                assertionFailure("expected decoding error")
            } catch {
                assert(describe(error).hasPrefix("enhancement.enabled:"))
            }

            // v1 files read the same and carry no sections.
            let v1 = try? decode(Data(#"{"keys":{"openrouter":"env:K"},"defaultMode":{"screenContext":true}}"#.utf8))
            assert(v1?.keys == ["openrouter": "env:K"] && v1?.defaultMode?.screenContext == true)
            assert(v1?.version == nil && v1?.hasSections == false && v1?.isNewerVersion == false)
            assert(v1?.backupSections(currentModes: [], currentPrompts: [], currentModeShortcuts: [:]) == nil)

            let modeID = "11111111-1111-4111-8111-111111111111"
            let v2Text = """
                {
                  "version": 2,
                  "enhancement": { "prompt": "Fix grammar." },
                  "modes": [{ "id": "\(modeID)", "name": "Email", "isAIEnhancementEnabled": true, "isDefault": true }],
                  "modeShortcuts": { "\(modeID)": { "kind": "key", "keyCode": 0, "modifierFlagsRawValue": 1048576 } },
                  "prompts": [{ "id": "22222222-2222-4222-8222-222222222222", "title": "T", "promptText": "P" }],
                  "dictionary": { "vocabulary": ["Yap", " "], "replacements": {} },
                  "general": { "isMenuBarOnly": true, "recorderType": "notch" }
                }
                """
            guard let v2 = try? decode(Data(v2Text.utf8)) else { return assertionFailure("v2 should decode") }
            assert(v2.version == 2 && v2.enhancement?.prompt == "Fix grammar.")
            assert(v2.modes?.first?.name == "Email" && v2.modes?.first?.isDefault == true)
            assert(v2.modeShortcuts?[modeID]?.shortcut.keyCode == 0)
            assert(v2.prompts?.first?.useSystemInstructions == true)
            assert(v2.dictionary == DictionarySection(vocabulary: ["Yap"], replacements: nil))
            assert(v2.general?.isMenuBarOnly == true && v2.general?.recorderType == "notch")
            // Merge by id: the file's "Email" replaces the app's mode with that id, "Local" and its shortcut stay.
            let appEmail = ModeConfig(id: UUID(uuidString: modeID)!, name: "Old", isAIEnhancementEnabled: false)
            let local = ModeConfig(name: "Local", isAIEnhancementEnabled: false)
            let localShortcut = ShortcutBackup(Shortcut.key(keyCode: 1, modifierFlags: []))
            let sections = v2.backupSections(
                currentModes: [appEmail, local], currentPrompts: [],
                currentModeShortcuts: [local.id.uuidString: localShortcut])
            assert(sections?.categories == [.prompts, .modes, .dictionary, .general])
            assert(sections?.file.modeConfigs.map(\.name) == ["Email", "Local"])
            assert(sections?.file.modeShortcuts?[local.id.uuidString] == localShortcut)
            assert(sections?.file.modeShortcuts?[modeID]?.shortcut.keyCode == 0)
            assert(sections?.file.vocabularyWords?.map(\.word) == ["Yap"] && sections?.file.customPrompts.count == 1)
            assert(mergedByID([Tag(1), Tag(2)], [Tag(2, "b"), Tag(3)]) == [Tag(1), Tag(2, "b"), Tag(3)])
            assert((try? decode(Data(#"{"version":3,"future":{}}"#.utf8)))?.isNewerVersion == true)

            let empty = try? decode(Data(#"{"version":2,"modes":[],"prompts":[],"dictionary":{"vocabulary":[]}}"#.utf8))
            assert(empty?.hasSections == false)
        }
    }
#endif
