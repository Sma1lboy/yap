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
    /// Custom transcription model definitions. Their API keys stay in each Mac's keychain, never in the config.
    var customModels: [CustomModelBackup]?
    /// Custom enhancement providers (name, base URL, model). Keys stay in each Mac's keychain; the type has none.
    var customProviders: [CustomAIProviderConfig]?

    /// Per-entry times, keyed by mode/prompt id, vocabulary word or replacement source. `modified` is when this
    /// entry's content last changed on some Mac; `deleted` holds tombstones. Both are written by export and sync.
    struct Stamps: Codable, Equatable {
        var modes: [String: Date]?
        var prompts: [String: Date]?
        var vocabulary: [String: Date]?
        var replacements: [String: Date]?
        var customModels: [String: Date]?
        var customProviders: [String: Date]?

        /// Nil when empty, and empty maps dropped, so a config without deletions has no `deleted` key.
        func normalized() -> Stamps? {
            func clean(_ times: [String: Date]?) -> [String: Date]? { times?.isEmpty == true ? nil : times }
            let result = Stamps(
                modes: clean(modes), prompts: clean(prompts), vocabulary: clean(vocabulary),
                replacements: clean(replacements), customModels: clean(customModels),
                customProviders: clean(customProviders))
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
                replacements: merge(lhs?.replacements, rhs?.replacements),
                customModels: merge(lhs?.customModels, rhs?.customModels),
                customProviders: merge(lhs?.customProviders, rhs?.customProviders)
            ).normalized()
        }
    }

    var modified: Stamps?
    var deleted: Stamps?

    var hasSections: Bool {
        modes != nil || prompts != nil || dictionary != nil || general != nil || customModels != nil
            || customProviders != nil
            || deleted != nil
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
        currentModes: [ModeConfig], currentPrompts: [CustomPrompt], currentModeShortcuts: [String: ShortcutBackup],
        currentCustomModels: [CustomModelBackup] = []
    ) -> (file: BackupFile, categories: [BackupCategory])? {
        guard hasSections else { return nil }
        let categories: [BackupCategory] = [
            prompts != nil || deleted?.prompts != nil ? .prompts : nil,
            modes != nil || deleted?.modes != nil ? .modes : nil,
            dictionary.map { _ in .dictionary }, general.map { _ in .general },
            customModels != nil || deleted?.customModels != nil ? .customModels : nil,
        ].compactMap { $0 }
        // Tombstoned entries the file doesn't carry (it would only carry them if edited after the delete).
        let deadModes = Set(deleted?.modes?.keys ?? [:].keys).subtracting((modes ?? []).map(\.id.uuidString))
        let deadPrompts = Set(deleted?.prompts?.keys ?? [:].keys).subtracting((prompts ?? []).map(\.id.uuidString))
        let deadModels = Set(deleted?.customModels?.keys ?? [:].keys)
            .subtracting((customModels ?? []).map(\.id.uuidString))
        let file = BackupFile(
            version: "config-v\(version ?? 1)",
            customPrompts: Self.mergedByID(
                currentPrompts.filter { !deadPrompts.contains($0.id.uuidString) }, prompts ?? []),
            modeConfigs: Self.mergedByID(currentModes.filter { !deadModes.contains($0.id.uuidString) }, modes ?? []),
            modeShortcuts: currentModeShortcuts.merging(modeShortcuts ?? [:]) { $1 },
            vocabularyWords: dictionary?.vocabulary?.map(WordBackup.init(word:)),
            wordReplacements: dictionary?.replacements, generalSettings: general, customEmojis: nil,
            customCloudModels: Self.mergedByID(
                currentCustomModels.filter { !deadModels.contains($0.id.uuidString) }, customModels ?? []))
        return (file, categories)
    }

    /// This Mac's custom enhancement providers after applying the file: merged by id, tombstoned ones removed.
    /// Nil when the file says nothing about them.
    func mergedCustomProviders(current: [CustomAIProviderConfig]) -> [CustomAIProviderConfig]? {
        guard customProviders != nil || deleted?.customProviders != nil else { return nil }
        let dead = Set(deleted?.customProviders?.keys ?? [:].keys)
            .subtracting((customProviders ?? []).map(\.id.uuidString))
        return Self.mergedByID(current.filter { !dead.contains($0.id.uuidString) }, customProviders ?? [])
    }

    static let promptID = UUID(uuidString: "A1B2C3D4-0000-4000-8000-00000000C0DE")!

    /// `$schema` value written into config.json: the schema Yap keeps next to it, for editor completion and
    /// validation. Reading ignores the key (like any unknown one).
    static let schemaReference = "./config.schema.json"
    static let schemaFileName = "config.schema.json"

    static let template = """
        {
          "$schema": "\(schemaReference)",
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
        if config.customModels?.isEmpty == true { config.customModels = nil }
        if config.customProviders?.isEmpty == true { config.customProviders = nil }
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
        return try encoder.encode(WithSchemaReference(config: self)) + Data("\n".utf8)
    }

    /// Encodes `"$schema"` alongside the config's own keys (sorted first, since `$` sorts before letters).
    private struct WithSchemaReference: Encodable {
        let config: YapConfig
        private enum Key: String, CodingKey { case schema = "$schema" }
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: Key.self)
            try container.encode(YapConfig.schemaReference, forKey: .schema)
            try config.encode(to: encoder)
        }
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
        config.customModels = backup.customCloudModels
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
        /// Custom transcription models plus custom enhancement providers.
        var customDefinitions = 0
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
            shortcuts: generalShortcuts.compactMap { $0 }.count + (modeShortcuts?.count ?? 0),
            customDefinitions: (customModels?.count ?? 0) + (customProviders?.count ?? 0))
    }

    /// True when the config already sets up what onboarding's model, AI key and practice steps would:
    /// modes, with a transcription model on the default one (or a `transcription` field).
    var coversOnboardingSetup: Bool {
        guard let modes, !modes.isEmpty else { return false }
        return transcription?.model != nil
            || modes.contains { $0.isDefault && $0.selectedTranscriptionModelName != nil }
    }

    /// Providers the config relies on, as written in it: transcription first (the `transcription` field, else the
    /// `Provider:` prefix of the default mode's model key), then enhancement (field, else the default mode's).
    var providerNames: [String] {
        let defaultMode = modes?.first(where: \.isDefault)
        let modeKey = defaultMode?.selectedTranscriptionModelName?.split(separator: ":", maxSplits: 1)
        let transcriptionProvider =
            transcription?.provider ?? (modeKey?.count == 2 ? modeKey.map { String($0[0]) } : nil)
        let enhancementProvider = enhancement?.provider ?? defaultMode?.selectedAIProvider
        var names: [String] = []
        for name in [transcriptionProvider, enhancementProvider].compactMap({ $0 }) where !names.contains(name) {
            names.append(name)
        }
        return names
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
        result.customModels = mergedByID(remote.customModels ?? [], edits(\.customModels))
        result.customProviders = mergedByID(remote.customProviders ?? [], edits(\.customProviders))
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
        let models = byID(self.customModels), oldModels = byID(baseline.customModels)
        let providers = byID(self.customProviders), oldProviders = byID(baseline.customProviders)
        let words = Dictionary(uniqueKeysWithValues: (dictionary?.vocabulary ?? []).map { ($0, true) })
        let oldWords = Dictionary(uniqueKeysWithValues: (baseline.dictionary?.vocabulary ?? []).map { ($0, true) })
        let rules = dictionary?.replacements ?? [:], oldRules = baseline.dictionary?.replacements ?? [:]

        var config = self
        config.modified = Stamps(
            modes: stamp(modes, oldModes, baseline.modified?.modes, same: Self.sameContent),
            prompts: stamp(prompts, oldPrompts, baseline.modified?.prompts, same: Self.sameContent),
            vocabulary: stamp(words, oldWords, baseline.modified?.vocabulary, same: ==),
            replacements: stamp(rules, oldRules, baseline.modified?.replacements, same: ==),
            customModels: stamp(models, oldModels, baseline.modified?.customModels, same: ==),
            customProviders: stamp(providers, oldProviders, baseline.modified?.customProviders, same: ==))
        config.deleted = Stamps(
            modes: tombstones(modes, oldModes, baseline.deleted?.modes),
            prompts: tombstones(prompts, oldPrompts, baseline.deleted?.prompts),
            vocabulary: tombstones(words, oldWords, baseline.deleted?.vocabulary),
            replacements: tombstones(rules, oldRules, baseline.deleted?.replacements),
            customModels: tombstones(models, oldModels, baseline.deleted?.customModels),
            customProviders: tombstones(providers, oldProviders, baseline.deleted?.customProviders))
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
        config.customModels = customModels?.filter {
            alive($0.id.uuidString, deleted?.customModels, modified?.customModels)
        }
        config.customProviders = customProviders?.filter {
            alive($0.id.uuidString, deleted?.customProviders, modified?.customProviders)
        }
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
            vocabulary: fresh(deleted?.vocabulary), replacements: fresh(deleted?.replacements),
            customModels: fresh(deleted?.customModels), customProviders: fresh(deleted?.customProviders))
        config.modified = Stamps(
            modes: present(modified?.modes, config.modes?.map(\.id.uuidString)),
            prompts: present(modified?.prompts, config.prompts?.map(\.id.uuidString)),
            vocabulary: present(modified?.vocabulary, config.dictionary?.vocabulary),
            replacements: present(modified?.replacements, (config.dictionary?.replacements).map { Array($0.keys) }),
            customModels: present(modified?.customModels, config.customModels?.map(\.id.uuidString)),
            customProviders: present(modified?.customProviders, config.customProviders?.map(\.id.uuidString)))
        return config.normalized()
    }

    // MARK: - Restoring an earlier version

    /// The keys each tombstone kind covers in this config (mode ids, words, replacement sources…).
    private var stampKeys: [(WritableKeyPath<Stamps, [String: Date]?>, Set<String>)] {
        [
            (\.modes, Set((modes ?? []).map(\.id.uuidString))),
            (\.prompts, Set((prompts ?? []).map(\.id.uuidString))),
            (\.vocabulary, Set(dictionary?.vocabulary ?? [])),
            (\.replacements, Set(dictionary?.replacements?.keys ?? [:].keys)),
            (\.customModels, Set((customModels ?? []).map(\.id.uuidString))),
            (\.customProviders, Set((customProviders ?? []).map(\.id.uuidString))),
        ]
    }

    /// Restoring `old` over `current` means "these contents, as of now", not "merge these in". Put back as-is,
    /// `old` goes wrong two ways: applying only merges by id, so a Mac that has an entry added since keeps it and
    /// its next export uploads it again; and tombstones written since `old` delete entries `old` brings back.
    /// So: every entry in `old` is stamped modified `now` (beating those tombstones), and every entry in `current`
    /// that `old` lacks gets a tombstone at `now`. Older tombstones for entries `old` doesn't have stay.
    static func restoring(_ old: YapConfig, over current: YapConfig, now: Date) -> YapConfig {
        let now = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970))
        var result = old
        result.version = currentVersion
        var modified = Stamps()
        var deleted = current.deleted ?? Stamps()
        let currentKeys = Dictionary(uniqueKeysWithValues: current.stampKeys.map { ($0.0, $0.1) })
        for (kind, oldKeys) in old.stampKeys {
            modified[keyPath: kind] = Dictionary(uniqueKeysWithValues: oldKeys.map { ($0, now) })
            var tombstones = (deleted[keyPath: kind] ?? [:]).filter { !oldKeys.contains($0.key) }
            for key in (currentKeys[kind] ?? []).subtracting(oldKeys) { tombstones[key] = now }
            deleted[keyPath: kind] = tombstones
        }
        result.modified = modified
        result.deleted = deleted
        return result.resolvingTombstones(now: now)
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
        /// A config with every field set (and every general setting), for checking config.schema.json covers what
        /// Yap writes. Adding a field to YapConfig or GeneralBackup without filling it here fails the check.
        static func fullyPopulated() -> YapConfig {
            let shortcut = ShortcutBackup(.key(keyCode: 49, modifierFlags: [.command, .shift]))
            let mode = ModeConfig(name: "Dictation", isAIEnhancementEnabled: true, isDefault: true)
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let stamps = Stamps(
                modes: [mode.id.uuidString: now], prompts: ["p": now], vocabulary: ["Yap": now],
                replacements: ["yep": now], customModels: ["m": now], customProviders: ["c": now])
            var config = YapConfig(
                keys: ["openrouter": "env:OPENROUTER_API_KEY"],
                transcription: .init(provider: "openrouter", model: "microsoft/mai-transcribe-2"),
                enhancement: .init(enabled: true, provider: "openrouter", model: "m", prompt: "prompt.md"),
                defaultMode: .init(screenContext: false, clipboardContext: false, selectedTextContext: true))
            config.version = currentVersion
            config.modes = [mode]
            config.modeShortcuts = [mode.id.uuidString: shortcut]
            config.prompts = [CustomPrompt(title: "Tidy", promptText: "Tidy it.")]
            config.dictionary = .init(vocabulary: ["Yap"], replacements: ["yep": "Yap"])
            config.general = GeneralBackup(
                primaryRecordingShortcut: shortcut, secondaryRecordingShortcut: shortcut,
                pasteLastTranscriptionShortcut: shortcut, pasteLastEnhancementShortcut: shortcut,
                retryLastTranscriptionShortcut: shortcut, cancelRecorderShortcut: shortcut,
                openHistoryWindowShortcut: shortcut, quickAddToDictionaryShortcut: shortcut,
                primaryRecordingShortcutRawValue: "custom", secondaryRecordingShortcutRawValue: "none",
                primaryRecordingShortcutModeRawValue: "hybrid", secondaryRecordingShortcutModeRawValue: "toggle",
                launchAtLoginEnabled: true, isMenuBarOnly: false, recorderType: "notch",
                appAppearancePreference: "system", appLanguagePreference: "system",
                isTranscriptionCleanupEnabled: false, transcriptionRetentionMinutes: 1440, isAudioCleanupEnabled: true,
                audioRetentionPeriod: 7, isSystemMuteEnabled: true, isPauseMediaEnabled: false,
                audioResumptionDelay: 0.5, isTextFormattingEnabled: true, restoreClipboardAfterPaste: true,
                clipboardRestoreDelay: 2, finishAndSendKey: "none", isAutoLearnDictionaryEnabled: false,
                autoLearnReviewSchedule: "manually", autoLearnProvider: "OpenRouter", autoLearnModel: "m")
            config.customModels = [
                CustomModelBackup(
                    model: CustomCloudModel(
                        id: UUID(), name: "w", displayName: "Whisper", description: "", apiEndpoint: "https://x/v1",
                        modelName: "whisper-1", isMultilingual: true, supportedLanguages: [:]))
            ]
            config.customProviders = [
                CustomAIProviderConfig(name: "Local", baseURL: "http://x/v1", models: ["m"], selectedModel: "m")
            ]
            config.modified = stamps
            config.deleted = stamps
            return config
        }

        /// No stored property is nil (one level deep).
        private static func allFieldsSet(_ value: Any) -> Bool {
            Mirror(reflecting: value).children.allSatisfy { child in
                let mirror = Mirror(reflecting: child.value)
                return mirror.displayStyle != .optional || !mirror.children.isEmpty
            }
        }

        /// Every key Yap writes at the top level (and inside `general`) is described in config.schema.json.
        static func schemaSelfCheck() {
            guard
                let url = Bundle.main.url(forResource: "config.schema", withExtension: "json"),
                let schema = (try? Data(contentsOf: url)).flatMap({ try? JSONSerialization.jsonObject(with: $0) })
                    as? [String: Any]
            else { return assertionFailure("config.schema.json is not in the app bundle") }
            let full = fullyPopulated()
            assert(allFieldsSet(full), "fullyPopulated() leaves a YapConfig field nil; fill it in")
            assert(full.general.map(allFieldsSet) == true, "fullyPopulated() leaves a GeneralBackup field nil")
            guard let data = try? full.encoded(),
                let written = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                let general = written["general"] as? [String: Any]
            else { return assertionFailure("fully populated config should encode") }

            func properties(_ object: Any?) -> Set<String> {
                Set(((object as? [String: Any])?["properties"] as? [String: Any] ?? [:]).keys)
            }
            let topLevel = Set(written.keys).subtracting(properties(schema))
            assert(topLevel.isEmpty, "config.schema.json has no properties for \(topLevel.sorted())")
            let generalSchema = (schema["$defs"] as? [String: Any])?["general"]
            let generalKeys = Set(general.keys).subtracting(properties(generalSchema))
            assert(generalKeys.isEmpty, "config.schema.json's general has no properties for \(generalKeys.sorted())")
        }

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

            // Providers a restored config relies on.
            var restoredModes = YapConfig()
            restoredModes.modes = [
                ModeConfig(
                    name: "D", isAIEnhancementEnabled: true, selectedTranscriptionModelName: "OpenRouter:ABC",
                    selectedAIProvider: "Groq", isDefault: true)
            ]
            assert(restoredModes.providerNames == ["OpenRouter", "Groq"])
            restoredModes.transcription = .init(provider: "yapcloud", model: "m")
            restoredModes.enhancement = .init(provider: "yapcloud")
            assert(restoredModes.providerNames == ["yapcloud"])
            restoredModes = YapConfig()
            restoredModes.modes = [
                ModeConfig(
                    name: "D", isAIEnhancementEnabled: false, selectedTranscriptionModelName: "whisper", isDefault: true)
            ]
            assert(restoredModes.providerNames.isEmpty)

            // Older backups and configs still carry the removed isExperimentalFeaturesEnabled; it's ignored.
            let legacyGeneral = try? decode(
                Data(#"{"general":{"isExperimentalFeaturesEnabled":false,"isMenuBarOnly":true}}"#.utf8))
            assert(legacyGeneral?.general?.isMenuBarOnly == true)

            // Custom model definitions: merged by id, never written with an API key.
            let modelJSON = #"""
                {"customModels":[{"id":"55555555-5555-4555-8555-555555555555","name":"m","displayName":"M",
                "description":"","apiEndpoint":"https://x/v1","modelName":"whisper","isMultilingualModel":true,
                "supportedLanguages":{},"apiKey":"sk-secret"}]}
                """#
            guard let withModel = try? decode(Data(modelJSON.utf8)), let model = withModel.customModels?.first else {
                return assertionFailure("customModels should decode")
            }
            assert(model.apiKey == "sk-secret" && withModel.hasSections)
            let written = (try? withModel.encoded()).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            assert(written.contains("whisper") && !written.contains("sk-secret") && !written.contains("apiKey"))
            let modelSections = withModel.backupSections(
                currentModes: [], currentPrompts: [], currentModeShortcuts: [:], currentCustomModels: [])
            assert(modelSections?.categories == [.customModels] && modelSections?.file.customCloudModels?.count == 1)
            let modelDeleted = YapConfig().stamped(baseline: withModel, now: Date(timeIntervalSince1970: 1_800_000_000))
            assert(modelDeleted.deleted?.customModels?[model.id.uuidString] != nil)
            // Custom enhancement providers: same merge and tombstones; the definition has no key to leak.
            let provider = CustomAIProviderConfig(
                id: UUID(uuidString: "66666666-6666-4666-8666-666666666666")!, name: "Local", baseURL: "http://x/v1",
                models: ["llama"], selectedModel: "llama")
            let otherProvider = CustomAIProviderConfig(name: "Other", baseURL: "http://y/v1", models: [], selectedModel: "m")
            var withProvider = YapConfig()
            withProvider.customProviders = [provider]
            assert(withProvider.hasSections && (try? decode(withProvider.encoded()))?.customProviders == [provider])
            assert(withProvider.mergedCustomProviders(current: [otherProvider]) == [otherProvider, provider])
            assert(YapConfig().mergedCustomProviders(current: [provider]) == nil)
            let providerDeleted = YapConfig().stamped(baseline: withProvider, now: Date(timeIntervalSince1970: 1_800_000_000))
            assert(providerDeleted.mergedCustomProviders(current: [provider, otherProvider]) == [otherProvider])

            let onOtherMac = modelDeleted.backupSections(
                currentModes: [], currentPrompts: [], currentModeShortcuts: [:], currentCustomModels: [model])
            assert(onOtherMac?.file.customCloudModels?.isEmpty == true)

            // Restoring an earlier version overwrites: entries added since then get tombstones.
            do {
                let (t1, t2) = (Date(timeIntervalSince1970: 1_800_000_000), Date(timeIntervalSince1970: 1_800_001_000))
                let id = { (n: Int) in UUID(uuidString: String(format: "77777777-7777-4777-8777-%012d", n))! }
                let mode = { (n: Int, name: String) in
                    ModeConfig(id: id(n), name: name, isAIEnhancementEnabled: false, selectedLanguage: "en")
                }
                // The old version had A (old text) and C; since then A was edited, B added, C deleted, "y" added.
                var old = YapConfig()
                old.modes = [mode(1, "A old"), mode(3, "C")]
                old.dictionary = .init(vocabulary: ["x"])
                var current = YapConfig()
                current.modes = [mode(1, "A new"), mode(2, "B")]
                current.dictionary = .init(vocabulary: ["x", "y"])
                current.modified = .init(modes: [id(1).uuidString: t1, id(2).uuidString: t1])
                current.deleted = .init(modes: [id(3).uuidString: t1])

                let restored = restoring(old, over: current, now: t2)
                assert(restored.modes?.map(\.name) == ["A old", "C"] && restored.dictionary?.vocabulary == ["x"])
                assert(restored.deleted?.modes == [id(2).uuidString: t2] && restored.deleted?.vocabulary == ["y": t2])
                assert(restored.modified?.modes?[id(3).uuidString] == t2)

                // Another Mac still on `current` pulls it: B and "y" go, C comes back, A has the old text.
                let merged = threeWayMerged(base: current, local: current, remote: restored, now: t2)
                assert(Set(merged.modes?.map(\.name) ?? []) == ["A old", "C"] && merged.dictionary?.vocabulary == ["x"])
                let applied = restored.backupSections(
                    currentModes: [mode(1, "A new"), mode(2, "B")], currentPrompts: [], currentModeShortcuts: [:])
                assert(applied?.file.modeConfigs.map(\.name) == ["A old", "C"])

                // Why not just put `old` back as-is: applying it on a Mac leaves B in the app (apply only merges),
                // so that Mac's next export uploads B again; and C's older tombstone deletes the restored C.
                var naive = old
                naive.version = currentVersion
                let naiveApplied = naive.backupSections(
                    currentModes: [mode(1, "A new"), mode(2, "B")], currentPrompts: [], currentModeShortcuts: [:])
                assert(naiveApplied?.file.modeConfigs.contains { $0.name == "B" } == true)
                let naiveMerge = threeWayMerged(base: current, local: current, remote: naive, now: t2)
                assert(naiveMerge.modes?.contains { $0.name == "C" } == false)
            }

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
