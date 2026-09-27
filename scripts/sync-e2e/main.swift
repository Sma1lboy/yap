// `make sync-e2e`: the real config sync (CloudConfigSync, YapConfig merge/tombstones/restore, YapCloud client)
// against live paygate, with two simulated Macs signed in to one throwaway account. run.sh creates the account;
// this deletes it when done, whether the scenarios passed or not. One PASS/FAIL line per scenario.
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)
let env = ProcessInfo.processInfo.environment
guard let email = env["SYNC_E2E_EMAIL"], let tokenA = env["SYNC_E2E_TOKEN_A"], let tokenB = env["SYNC_E2E_TOKEN_B"]
else {
    print("Run through `make sync-e2e` (scripts/sync-e2e/run.sh creates the throwaway account).")
    exit(2)
}
usePaygateURL(from: env)

/// One Mac's sign-in, on top of the shared real client: the token is switched in before every call.
final class DeviceStore: ConfigCloudStore, ConfigVersionHistoryStore {
    let token: String
    /// Runs once right before the next put, to land another Mac's write in between (a real 409).
    var beforeNextPut: (() async -> Void)?
    private(set) var conflicts = 0

    init(token: String) { self.token = token }
    private func use() { KeychainService.shared.save(token, forKey: "yapCloudToken", syncable: false) }

    var isSignedIn: Bool { true }
    func fetchConfig() async throws -> YapCloudConfigDocument? {
        use()
        return try await YapCloud.shared.fetchConfig()
    }
    func fetchConfigIfChanged(since version: String?) async throws -> CloudConfigFetch<YapCloudConfigDocument> {
        use()
        return try await YapCloud.shared.fetchConfigIfChanged(since: version)
    }
    func putConfig(_ data: Data, ifMatch: String?) async throws -> String {
        if let hook = beforeNextPut {
            beforeNextPut = nil
            await hook()
        }
        use()
        do {
            return try await YapCloud.shared.putConfig(data, ifMatch: ifMatch)
        } catch YapCloudError.versionConflict {
            conflicts += 1
            throw YapCloudError.versionConflict(current: nil)
        }
    }
    func listConfigVersions() async throws -> [CloudConfigVersionInfo] {
        use()
        return try await YapCloud.shared.listConfigVersions()
    }
    func fetchConfigVersion(_ version: String) async throws -> Data {
        use()
        return try await YapCloud.shared.fetchConfigVersion(version)
    }
}

/// A Mac's settings (modes and prompts) with the app's export/apply steps: export stamps against the last written
/// or applied config (YapConfigLoader.makeConfigData), apply merges by id and drops tombstoned entries
/// (YapConfigLoader.applyConfigData → applySections). A `legacy` Mac is a Yap from before `followsRecommended`:
/// like that version's CustomPrompt decoder, it ignores the key, so it keeps (and writes back) only the text.
@MainActor final class Mac {
    let name: String
    var modes: [ModeConfig] = []
    var prompts: [CustomPrompt] = []
    private var baseline: YapConfig?
    let store: DeviceStore
    private(set) var sync: CloudConfigSync!
    private let suite: String
    private let legacy: Bool

    init(name: String, token: String, legacy: Bool = false) {
        self.name = name
        self.legacy = legacy
        store = DeviceStore(token: token)
        suite = "sync-e2e.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: CloudConfigSync.enabledKey)
        sync = CloudConfigSync(
            defaults: defaults, localConfig: { [unowned self] in self.export() },
            applyRemote: { [unowned self] in try self.apply($0) })
        sync.store = store
    }

    func export() -> Data? {
        let backup = BackupFile(
            version: "sync-e2e", customPrompts: prompts, modeConfigs: modes, modeShortcuts: nil, vocabularyWords: nil,
            wordReplacements: nil, generalSettings: nil, customEmojis: nil, customCloudModels: nil)
        let config = YapConfig.exported(from: backup, existing: nil) { _ in true }
            .normalized().stamped(baseline: baseline, now: Date())
        guard let data = try? config.encoded() else { return nil }
        baseline = config
        return data
    }

    func apply(_ data: Data) throws {
        let config = try YapConfig.decode(legacy ? withoutFollowsRecommended(data) : data)
        baseline = config
        if let sections = config.backupSections(currentModes: modes, currentPrompts: prompts, currentModeShortcuts: [:]) {
            modes = sections.file.modeConfigs
            prompts = sections.file.customPrompts
        }
    }

    private func withoutFollowsRecommended(_ data: Data) throws -> Data {
        guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return data }
        if let prompts = json["prompts"] as? [[String: Any]] {
            json["prompts"] = prompts.map { $0.filter { $0.key != "followsRecommended" } }
        }
        return try JSONSerialization.data(withJSONObject: json)
    }

    var names: [String] { modes.map(\.name).sorted() }

    func rename(_ id: UUID, to name: String) { modes = modes.map { $0.id == id ? renamed($0, name) : $0 } }
    func remove(_ id: UUID) { modes.removeAll { $0.id == id } }

    /// A full sync that must end synced (not a conflict or error).
    func syncOK() async throws {
        await sync.sync()
        guard case .synced = sync.status else { throw Failed("\(name) sync ended \(sync.status)") }
    }

    deinit { UserDefaults.standard.removePersistentDomain(forName: suite) }
}

func renamed(_ mode: ModeConfig, _ name: String) -> ModeConfig {
    var mode = mode
    mode.name = name
    return mode
}
func mode(_ name: String) -> ModeConfig {
    ModeConfig(name: name, isAIEnhancementEnabled: false, selectedLanguage: "en")
}

struct Failed: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
func expect(_ condition: Bool, _ message: @autoclosure () -> String) throws {
    if !condition { throw Failed(message()) }
}

var failures = 0
@MainActor func scenario(_ name: String, _ body: () async throws -> String) async {
    do {
        let detail = try await body()
        print("PASS \(name.padding(toLength: 34, withPad: " ", startingAt: 0)) \(detail)")
    } catch {
        failures += 1
        print("FAIL \(name.padding(toLength: 34, withPad: " ", startingAt: 0)) \(error)")
    }
}

/// Deletes the throwaway account (all devices, the config and its history).
func deleteAccount() async {
    var request = URLRequest(url: URL(string: "/v1/me", relativeTo: YapCloud.shared.baseURL)!)
    request.httpMethod = "DELETE"
    request.setValue("Bearer \(tokenA)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONSerialization.data(withJSONObject: ["confirm": email])
    let status = ((try? await URLSession.shared.data(for: request))?.1 as? HTTPURLResponse)?.statusCode
    print("     account deleted             \(status == 204 ? "yes" : "NO (HTTP \(status.map(String.init) ?? "?"))")")
}

/// Second-granular stamps: wait so the next change is strictly later than the last one.
func tick() async { try? await Task.sleep(for: .milliseconds(1100)) }

Task { @MainActor in
    let a = Mac(name: "A", token: tokenA)
    let b = Mac(name: "B", token: tokenB)
    let dictation = mode("Dictation"), email = mode("Email"), notes = mode("Notes"), code = mode("Code")
    var versionWithNotes: String?

    await scenario("first write, other Mac restores") {
        a.modes = [dictation, email]
        try await a.syncOK()
        guard let stored = try await b.sync.fetchStored() else { throw Failed("nothing stored after A's write") }
        try await b.sync.restore(stored)
        try expect(b.names == a.names, "B \(b.names) != A \(a.names)")
        return "A wrote v\(stored.version), B restored \(b.names)"
    }

    await scenario("concurrent edits, 409, merge") {
        await tick()
        a.rename(email.id, to: "Email A")
        b.modes.append(notes)
        let conflictsBefore = a.store.conflicts
        a.store.beforeNextPut = { try? await b.syncOK() }  // B's write lands between A's read and A's put
        try await a.syncOK()
        try await b.syncOK()
        try expect(a.store.conflicts == conflictsBefore + 1, "A saw \(a.store.conflicts - conflictsBefore) conflicts, expected 1")
        try expect(a.names == ["Dictation", "Email A", "Notes"], "A \(a.names)")
        try expect(b.names == a.names, "B \(b.names) != A \(a.names)")
        versionWithNotes = try await a.store.fetchConfig()?.version
        return "A got a real 409, merged, retried; both \(a.names)"
    }

    await scenario("delete syncs") {
        await tick()
        a.remove(notes.id)
        try await a.syncOK()
        try await b.syncOK()
        try expect(!b.names.contains("Notes"), "B still has Notes: \(b.names)")
        try expect(b.names == a.names, "B \(b.names) != A \(a.names)")
        return "A deleted Notes; B now \(b.names)"
    }

    await scenario("edit after delete wins") {
        await tick()
        a.remove(email.id)
        try await a.syncOK()  // tombstone for Email at t1
        await tick()
        b.rename(email.id, to: "Email B")  // B hasn't pulled the delete; its edit is at t2 > t1
        try await b.syncOK()
        try await a.syncOK()
        try expect(a.names == ["Dictation", "Email B"], "A \(a.names)")
        try expect(b.names == a.names, "B \(b.names) != A \(a.names)")
        return "A deleted Email, B edited it later; both \(a.names)"
    }

    await scenario("restore version, no resurrection") {
        guard let versionWithNotes else { throw Failed("no version recorded from the 409 scenario") }
        await tick()
        b.modes.append(code)  // added after that version
        try await b.syncOK()
        try await a.syncOK()
        try expect(a.names.contains("Code"), "A didn't get Code: \(a.names)")
        let history = try await a.sync.loadHistory()
        try expect(history.versions.contains { $0.version == versionWithNotes }, "v\(versionWithNotes) not in history")
        await tick()
        try await a.sync.restoreVersion(versionWithNotes)
        let expected = ["Dictation", "Email A", "Notes"]
        try expect(a.names == expected, "A after restore \(a.names)")
        // B syncs twice (pull, then a round with nothing new); A once more. Code must not come back.
        try await b.syncOK()
        try await b.syncOK()
        try await a.syncOK()
        try expect(b.names == expected, "B \(b.names)")
        try expect(a.names == expected, "A \(a.names)")
        guard let stored = try await a.store.fetchConfig() else { throw Failed("no config stored") }
        let cloud = try YapConfig.decode(stored.config)
        try expect(cloud.modes?.contains { $0.id == code.id } == false, "Code is back in the cloud")
        try expect(cloud.deleted?.modes?[code.id.uuidString] != nil, "no tombstone for Code")
        return "restored v\(versionWithNotes); Code tombstoned, both \(expected)"
    }

    // The recommended prompt as a reference (CustomPrompt.followsRecommended): the one-time migration of an
    // untouched copy syncs as its own version, restoring the version before it undoes it, and a Yap from before
    // the field reads the full text.
    let shipped = (try? String(contentsOfFile: "VoiceInk/Resources/RecommendedPrompt.md", encoding: .utf8)) ?? ""
    let copy = CustomPrompt(title: "Cleanup", promptText: shipped)
    var versionBeforeMigration: String?

    await scenario("prompt migration syncs") {
        try expect(RecommendedSetup.isShippedPrompt(shipped), "RecommendedPrompt.md isn't in shippedPromptHashes")
        await tick()
        a.prompts = [copy]
        try await a.syncOK()
        try await b.syncOK()
        versionBeforeMigration = try await a.store.fetchConfig()?.version
        await tick()
        a.prompts = RecommendedSetup.followingRecommended(a.prompts)  // what YapConfigLoader runs once per Mac
        try await a.syncOK()
        try await b.syncOK()
        let migratedVersion = try await a.store.fetchConfig()?.version
        try expect(migratedVersion != versionBeforeMigration, "the migration didn't make a new version")
        try expect(b.prompts.first?.followsRecommended == true, "B doesn't follow: \(b.prompts)")
        try expect(b.prompts.first?.promptText == shipped, "B's stored copy changed")
        return "copy → reference in v\(migratedVersion ?? "?"); B follows, stored copy kept"
    }

    await scenario("restore undoes the migration") {
        guard let versionBeforeMigration else { throw Failed("no version from before the migration") }
        await tick()
        try await a.sync.restoreVersion(versionBeforeMigration)
        try await b.syncOK()
        try expect(a.prompts.first?.followsRecommended == false && a.prompts.first?.promptText == shipped, "A \(a.prompts)")
        try expect(b.prompts == a.prompts, "B \(b.prompts) != A \(a.prompts)")
        return "restored v\(versionBeforeMigration): both back to the plain copy"
    }

    await scenario("old Yap reads a reference") {
        await tick()
        a.prompts = RecommendedSetup.followingRecommended(a.prompts)
        try await a.syncOK()
        let old = Mac(name: "Old", token: tokenB, legacy: true)
        guard let stored = try await old.sync.fetchStored() else { throw Failed("nothing stored") }
        try await old.sync.restore(stored)
        try expect(old.prompts.count == 1 && old.prompts[0].promptText == shipped, "old Mac got \(old.prompts)")
        // The old Mac changes something else and syncs: it writes the prompt back without the field.
        await tick()
        old.rename(dictation.id, to: "Dictation (old Mac)")
        try await old.syncOK()
        try await a.syncOK()
        try expect(a.names.contains("Dictation (old Mac)"), "A \(a.names)")
        try expect(a.prompts.first?.promptText == shipped, "A's prompt text changed")
        return "old Mac got the full text; after its write A follows=\(a.prompts.first?.followsRecommended ?? false), text intact"
    }

    await deleteAccount()
    print(failures == 0 ? "sync-e2e: all scenarios passed" : "sync-e2e: \(failures) scenario(s) failed")
    exit(failures == 0 ? 0 : 1)
}
RunLoop.main.run()
