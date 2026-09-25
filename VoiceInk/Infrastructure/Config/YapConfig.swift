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

    /// Per-entry times, keyed by mode/prompt id, vocabulary word or replacement source. `modified` is when this
    /// entry's content last changed on some Mac; `deleted` holds tombstones. Both are written by export and sync.
    struct Stamps: Codable, Equatable {
        var modes: [String: Date]?
        var prompts: [String: Date]?
        var vocabulary: [String: Date]?
        var replacements: [String: Date]?

        /// Nil when empty, and empty maps dropped, so a config without deletions has no `deleted` key.
        func normalized() -> Stamps? {
            func clean(_ times: [String: Date]?) -> [String: Date]? { times?.isEmpty == true ? nil : times }
            let result = Stamps(
                modes: clean(modes), prompts: clean(prompts), vocabulary: clean(vocabulary),
                replacements: clean(replacements))
            return result == Stamps() ? nil : result
        }

        /// Per key, the later of the two times.
        static func newest(_ lhs: Stamps?, _ rhs: Stamps?) -> Stamps? {
            func merge(_ a: [String: Date]?, _ b: [String: Date]?) -> [String: Date]? {
                guard a != nil || b != nil else { return nil }
                return (a ?? [:]).merging(b ?? [:]) { max($0, $1) }
            }
            return Stamps(
                modes: merge(lhs?.modes, rhs?.modes), prompts: merge(lhs?.prompts, rhs?.prompts),
                vocabulary: merge(lhs?.vocabulary, rhs?.vocabulary),
                replacements: merge(lhs?.replacements, rhs?.replacements)
            ).normalized()
        }
    }

    var modified: Stamps?
    var deleted: Stamps?

    var hasSections: Bool {
        modes != nil || prompts != nil || dictionary != nil || general != nil || deleted != nil
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
            prompts != nil || deleted?.prompts != nil ? .prompts : nil,
            modes != nil || deleted?.modes != nil ? .modes : nil,
            dictionary.map { _ in .dictionary }, general.map { _ in .general },
        ].compactMap { $0 }
        // Tombstoned entries the file doesn't carry (it would only carry them if edited after the delete).
        let deadModes = Set(deleted?.modes?.keys ?? [:].keys).subtracting((modes ?? []).map(\.id.uuidString))
        let deadPrompts = Set(deleted?.prompts?.keys ?? [:].keys).subtracting((prompts ?? []).map(\.id.uuidString))
        let file = BackupFile(
            version: "config-v\(version ?? 1)",
            customPrompts: Self.mergedByID(
                currentPrompts.filter { !deadPrompts.contains($0.id.uuidString) }, prompts ?? []),
            modeConfigs: Self.mergedByID(currentModes.filter { !deadModes.contains($0.id.uuidString) }, modes ?? []),
            modeShortcuts: currentModeShortcuts.merging(modeShortcuts ?? [:]) { $1 },
            vocabularyWords: dictionary?.vocabulary?.map(WordBackup.init(word:)),
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
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(YapConfig.self, from: data).normalized()
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
        config.modified = config.modified?.normalized()
        config.deleted = config.deleted?.normalized()
        return config
    }

    /// Stable bytes for config.json: sorted keys, so writing the same settings twice gives the same file.
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
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

    // MARK: - Restore on a new Mac

    /// What restoring this config brings over, for the onboarding summary.
    struct RestoreSummary: Equatable {
        var modes = 0
        var prompts = 0
        var dictionaryEntries = 0
        var shortcuts = 0
    }

    var restoreSummary: RestoreSummary {
        let generalShortcuts: [ShortcutBackup?] = [
            general?.primaryRecordingShortcut, general?.secondaryRecordingShortcut,
            general?.pasteLastTranscriptionShortcut, general?.pasteLastEnhancementShortcut,
            general?.retryLastTranscriptionShortcut, general?.cancelRecorderShortcut,
            general?.openHistoryWindowShortcut, general?.quickAddToDictionaryShortcut,
        ]
        return RestoreSummary(
            modes: modes?.count ?? 0, prompts: prompts?.count ?? 0,
            dictionaryEntries: (dictionary?.vocabulary?.count ?? 0) + (dictionary?.replacements?.count ?? 0),
            shortcuts: generalShortcuts.compactMap { $0 }.count + (modeShortcuts?.count ?? 0))
    }

    /// True when the config already sets up what onboarding's model, AI key and practice steps would:
    /// modes, with a transcription model on the default one (or a `transcription` field).
    var coversOnboardingSetup: Bool {
        guard let modes, !modes.isEmpty else { return false }
        return transcription?.model != nil
            || modes.contains { $0.isDefault && $0.selectedTranscriptionModelName != nil }
    }

    /// The copy for another Mac: a prompt that names a local file (`"prompt.md"`) becomes the file's text, which
    /// `resolvePrompt` reads back as inline text. `"recommended"` stays, since every Yap bundles that prompt.
    func inliningPromptFile(_ resolve: (String) -> String?) -> YapConfig {
        guard let raw = enhancement?.prompt,
            raw.caseInsensitiveCompare(RecommendedSetup.promptKeyword) != .orderedSame,
            let text = resolve(raw)
        else { return self }
        var config = self
        config.enhancement?.prompt = text
        return config
    }

    // MARK: - Merge

    /// Content equality. `ModeConfig ==` compares only ids, so "did this change" checks compare JSON instead.
    static func sameContent<T: Encodable>(_ lhs: T, _ rhs: T) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(lhs)) == (try? encoder.encode(rhs))
    }

    /// Three-way merge for cloud sync: starts from `remote` and re-applies what changed in `local` since `base`
    /// (the last synced state). Modes, prompts, shortcuts and dictionary entries merge by id/key, so two Macs
    /// editing different modes both keep their edit; other fields take local only when it changed. Without a
    /// base (first sync on this Mac) remote wins and only local entries remote doesn't have are added.
    static func threeWayMerged(
        base: YapConfig?, local: YapConfig, remote: YapConfig, now: Date = Date()
    ) -> YapConfig {
        func edits<T: Identifiable & Encodable>(_ path: KeyPath<YapConfig, [T]?>) -> [T] {
            let items = local[keyPath: path] ?? []
            guard let base else {
                let remoteIDs = Set((remote[keyPath: path] ?? []).map(\.id))
                return items.filter { !remoteIDs.contains($0.id) }
            }
            let baseItems = base[keyPath: path] ?? []
            return items.filter { item in
                baseItems.first { $0.id == item.id }.map { !sameContent($0, item) } ?? true
            }
        }
        func merged<V: Equatable>(_ path: KeyPath<YapConfig, [String: V]?>) -> [String: V]? {
            let edits = (local[keyPath: path] ?? [:]).filter { key, value in
                base.map { $0[keyPath: path]?[key] != value } ?? (remote[keyPath: path]?[key] == nil)
            }
            return (remote[keyPath: path] ?? [:]).merging(edits) { $1 }
        }
        func pick<T: Equatable>(_ path: KeyPath<YapConfig, T?>) -> T? {
            if let base, local[keyPath: path] != base[keyPath: path] { return local[keyPath: path] }
            return remote[keyPath: path] ?? (base == nil ? local[keyPath: path] : nil)
        }

        var result = remote
        result.version = currentVersion
        result.keys = pick(\.keys)
        result.transcription = pick(\.transcription)
        result.enhancement = pick(\.enhancement)
        result.defaultMode = pick(\.defaultMode)
        result.general = pick(\.general)
        result.modes = mergedByID(remote.modes ?? [], edits(\.modes))
        result.prompts = mergedByID(remote.prompts ?? [], edits(\.prompts))
        result.modeShortcuts = merged(\.modeShortcuts)
        let remoteWords = remote.dictionary?.vocabulary ?? []
        let baseWords = Set(base.map { $0.dictionary?.vocabulary ?? [] } ?? remoteWords)
        let newWords = (local.dictionary?.vocabulary ?? []).filter { !baseWords.contains($0) }
        result.modified = Stamps.newest(local.modified, remote.modified)
        result.deleted = Stamps.newest(local.deleted, remote.deleted)
        result.dictionary = DictionarySection(
            vocabulary: remoteWords + newWords.filter { !remoteWords.contains($0) },
            replacements: merged(\.dictionary?.replacements))
        // An entry deleted on one Mac stays deleted unless the other edited it after the delete.
        return result.resolvingTombstones(now: now)
    }

    // MARK: - Tombstones

    static let tombstoneLifetime: TimeInterval = 90 * 24 * 3600

    /// Fills `modified` and `deleted` for an exported snapshot by comparing it with `baseline`, the last config
    /// this Mac wrote or applied: entries whose content is unchanged keep the baseline's time, changed or new ones
    /// get `now`, and entries in the baseline that are gone get a tombstone at `now`. Without a baseline nothing
    /// is stamped, so this Mac's entries lose to any tombstone.
    func stamped(baseline: YapConfig?, now: Date) -> YapConfig {
        guard let baseline else { return resolvingTombstones(now: now) }
        let now = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970))  // ISO 8601 keeps whole seconds
        func stamp<T>(_ current: [String: T], _ old: [String: T], _ times: [String: Date]?, same: (T, T) -> Bool)
            -> [String: Date]
        {
            current.reduce(into: [:]) { result, entry in
                if let before = old[entry.key], same(before, entry.value) {
                    if let time = times?[entry.key] { result[entry.key] = time }
                } else {
                    result[entry.key] = now
                }
            }
        }
        func tombstones<T>(_ current: [String: T], _ old: [String: T], _ times: [String: Date]?) -> [String: Date] {
            var result = times ?? [:]
            for key in old.keys where current[key] == nil { result[key] = now }
            for key in current.keys { result[key] = nil }
            return result
        }
        let modes = byID(self.modes), oldModes = byID(baseline.modes)
        let prompts = byID(self.prompts), oldPrompts = byID(baseline.prompts)
        let words = Dictionary(uniqueKeysWithValues: (dictionary?.vocabulary ?? []).map { ($0, true) })
        let oldWords = Dictionary(uniqueKeysWithValues: (baseline.dictionary?.vocabulary ?? []).map { ($0, true) })
        let rules = dictionary?.replacements ?? [:], oldRules = baseline.dictionary?.replacements ?? [:]

        var config = self
        config.modified = Stamps(
            modes: stamp(modes, oldModes, baseline.modified?.modes, same: Self.sameContent),
            prompts: stamp(prompts, oldPrompts, baseline.modified?.prompts, same: Self.sameContent),
            vocabulary: stamp(words, oldWords, baseline.modified?.vocabulary, same: ==),
            replacements: stamp(rules, oldRules, baseline.modified?.replacements, same: ==))
        config.deleted = Stamps(
            modes: tombstones(modes, oldModes, baseline.deleted?.modes),
            prompts: tombstones(prompts, oldPrompts, baseline.deleted?.prompts),
            vocabulary: tombstones(words, oldWords, baseline.deleted?.vocabulary),
            replacements: tombstones(rules, oldRules, baseline.deleted?.replacements))
        return config.resolvingTombstones(now: now)
    }

    /// Drops every entry whose tombstone is newer than its last modification (or that has no modification time),
    /// then forgets tombstones older than 90 days and times of entries that no longer exist.
    func resolvingTombstones(now: Date) -> YapConfig {
        var config = self
        func alive(_ key: String, _ tombstones: [String: Date]?, _ modified: [String: Date]?) -> Bool {
            guard let tombstone = tombstones?[key] else { return true }
            return modified?[key].map { $0 > tombstone } ?? false
        }
        config.modes = modes?.filter { alive($0.id.uuidString, deleted?.modes, modified?.modes) }
        config.prompts = prompts?.filter { alive($0.id.uuidString, deleted?.prompts, modified?.prompts) }
        config.modeShortcuts = modeShortcuts?.filter { alive($0.key, deleted?.modes, modified?.modes) }
        config.dictionary?.vocabulary = dictionary?.vocabulary?.filter {
            alive($0, deleted?.vocabulary, modified?.vocabulary)
        }
        config.dictionary?.replacements = dictionary?.replacements?.filter {
            alive($0.key, deleted?.replacements, modified?.replacements)
        }

        let cutoff = now.addingTimeInterval(-Self.tombstoneLifetime)
        func fresh(_ times: [String: Date]?) -> [String: Date]? { times?.filter { $0.value > cutoff } }
        func present(_ times: [String: Date]?, _ keys: [String]?) -> [String: Date]? {
            let keys = Set(keys ?? [])
            return times?.filter { keys.contains($0.key) }
        }
        config.deleted = Stamps(
            modes: fresh(deleted?.modes), prompts: fresh(deleted?.prompts),
            vocabulary: fresh(deleted?.vocabulary), replacements: fresh(deleted?.replacements))
        config.modified = Stamps(
            modes: present(modified?.modes, config.modes?.map(\.id.uuidString)),
            prompts: present(modified?.prompts, config.prompts?.map(\.id.uuidString)),
            vocabulary: present(modified?.vocabulary, config.dictionary?.vocabulary),
            replacements: present(modified?.replacements, (config.dictionary?.replacements).map { Array($0.keys) }))
        return config.normalized()
    }

    private func byID<T: Identifiable>(_ items: [T]?) -> [String: T] where T.ID == UUID {
        Dictionary((items ?? []).map { ($0.id.uuidString, $0) }, uniquingKeysWith: { $1 })
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
        if let url = promptFileURL(trimmed, configDirectory: configDirectory), let text = readFile(url) { return text }
        return trimmed
    }

    /// Where `value` would point as a prompt file: relative to the config dir, absolute, or `~/...`.
    /// Nil for multi-line text, which is always inline. Whether the file exists is up to the caller.
    static func promptFileURL(_ value: String, configDirectory: URL) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\n") else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        return expanded.hasPrefix("/")
            ? URL(fileURLWithPath: expanded) : configDirectory.appendingPathComponent(trimmed)
    }

    /// A config pulled from the cloud carries its prompt as text. When this Mac's config.json keeps the prompt in
    /// a file (`localPrompt` names an existing file, per `existingFile`), the text goes into that file and the
    /// reference stays; otherwise the text stays inline. `"recommended"` never goes into a file.
    func keepingPromptFile(localPrompt: String?, existingFile: (String) -> URL?) -> (
        config: YapConfig, promptFile: (url: URL, text: String)?
    ) {
        guard let text = enhancement?.prompt,
            text.caseInsensitiveCompare(RecommendedSetup.promptKeyword) != .orderedSame,
            let reference = localPrompt, reference != text, let url = existingFile(reference)
        else { return (self, nil) }
        var config = self
        config.enhancement?.prompt = reference
        return (config, (url, text))
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

            // A prompt file is inlined for the cloud copy; inline text and "recommended" pass through.
            let resolve: (String) -> String? = { resolvePrompt($0, configDirectory: dir, readFile: read) }
            let withFile = YapConfig(enhancement: .init(prompt: "prompt.md"))
            assert(withFile.inliningPromptFile(resolve).enhancement?.prompt == "FILE")
            let inline = YapConfig(enhancement: .init(prompt: "Fix grammar."))
            assert(inline.inliningPromptFile(resolve) == inline)
            let keyword = YapConfig(enhancement: .init(prompt: "Recommended"))
            assert(keyword.inliningPromptFile(resolve) == keyword)
            assert(YapConfig().inliningPromptFile(resolve) == YapConfig())

            // Restore summary and onboarding coverage.
            assert(v2.restoreSummary == RestoreSummary(modes: 1, prompts: 1, dictionaryEntries: 1, shortcuts: 1))
            assert(!v2.coversOnboardingSetup && !YapConfig().coversOnboardingSetup)
            var covered = v2
            covered.transcription = .init(provider: "yapcloud", model: "m")
            assert(covered.coversOnboardingSetup)

            // Pulled prompt text goes into this Mac's prompt file when config.json references one.
            let promptFile: (String) -> URL? = { $0 == "prompt.md" ? URL(fileURLWithPath: "/cfg/prompt.md") : nil }
            let pulled = YapConfig(enhancement: .init(provider: "openrouter", prompt: "Pulled text."))
            let intoFile = pulled.keepingPromptFile(localPrompt: "prompt.md", existingFile: promptFile)
            assert(intoFile.config.enhancement == .init(provider: "openrouter", prompt: "prompt.md"))
            assert(intoFile.promptFile?.url.path == "/cfg/prompt.md" && intoFile.promptFile?.text == "Pulled text.")
            for local in [nil, "Old inline text.", "missing.md"] {
                let inline = pulled.keepingPromptFile(localPrompt: local, existingFile: promptFile)
                assert(inline.config == pulled && inline.promptFile == nil)
            }
            let pulledKeyword = YapConfig(enhancement: .init(prompt: "recommended"))
            assert(pulledKeyword.keepingPromptFile(localPrompt: "prompt.md", existingFile: promptFile).promptFile == nil)
            assert(promptFileURL("prompt.md", configDirectory: dir)?.path == "/cfg/prompt.md")
            assert(promptFileURL("line one\nline two", configDirectory: dir) == nil)

            // Tombstones. Base state as both Macs last synced it, every entry modified at t0.
            let t0 = Date(timeIntervalSince1970: 1_800_000_000)
            let (t1, t2) = (t0.addingTimeInterval(60), t0.addingTimeInterval(120))
            let dictation = ModeConfig(
                id: UUID(uuidString: "33333333-3333-4333-8333-333333333333")!, name: "Dictation",
                isAIEnhancementEnabled: false, selectedLanguage: "en", isDefault: true)
            let email = ModeConfig(
                id: UUID(uuidString: "44444444-4444-4444-8444-444444444444")!, name: "Email",
                isAIEnhancementEnabled: false, selectedLanguage: "en")
            var synced = YapConfig()
            synced.modes = [dictation, email]
            synced.dictionary = .init(vocabulary: ["Rove", "Yap"])
            let base = synced.stamped(baseline: YapConfig(), now: t0)
            assert(base.modified?.modes?[email.id.uuidString] == t0 && base.deleted == nil)

            // 1. A deletes Email and "Rove"; B changed nothing: both end up without them.
            var aState = base
            aState.modes = [dictation]
            aState.dictionary = .init(vocabulary: ["Yap"])
            let a = aState.stamped(baseline: base, now: t1)
            assert(a.deleted?.modes?[email.id.uuidString] == t1 && a.deleted?.vocabulary?["Rove"] == t1)
            assert((try? decode(a.encoded())) == a)
            for merged in [
                threeWayMerged(base: base, local: a, remote: base, now: t1),
                threeWayMerged(base: base, local: base, remote: a, now: t1),
            ] {
                assert(merged.modes?.map(\.name) == ["Dictation"] && merged.dictionary?.vocabulary == ["Yap"])
                let onB = merged.backupSections(
                    currentModes: [dictation, email], currentPrompts: [], currentModeShortcuts: [:])
                assert(onB?.file.modeConfigs.map(\.name) == ["Dictation"])
            }

            // 2. A deletes Email at t1, B renames it at t2: the later edit wins on both sides.
            var renamed = email
            renamed.name = "Email 2"
            var bState = base
            bState.modes = [dictation, renamed]
            let b = bState.stamped(baseline: base, now: t2)
            assert(b.modified?.modes?[email.id.uuidString] == t2 && b.modified?.modes?[dictation.id.uuidString] == t0)
            for merged in [
                threeWayMerged(base: base, local: a, remote: b, now: t2),
                threeWayMerged(base: base, local: b, remote: a, now: t2),
            ] {
                assert(merged.modes?.map(\.name).sorted() == ["Dictation", "Email 2"])
            }

            // An entry without a modification time loses to any tombstone.
            var unstamped = a
            unstamped.modes = [dictation, email]
            unstamped.modified = nil
            assert(unstamped.resolvingTombstones(now: t1).modes?.map(\.name) == ["Dictation"])

            // 3. Tombstones are forgotten after 90 days.
            assert(a.resolvingTombstones(now: t1.addingTimeInterval(89 * 24 * 3600)).deleted != nil)
            assert(a.resolvingTombstones(now: t1.addingTimeInterval(91 * 24 * 3600)).deleted == nil)
        }
    }
#endif
