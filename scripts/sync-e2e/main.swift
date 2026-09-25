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
if let url = env["YAP_CLOUD_SMOKE_URL"], !url.isEmpty {
    UserDefaults.standard.set(url, forKey: YapCloud.baseURLDefaultsKey)
}

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

/// A Mac's settings (modes only) with the app's export/apply steps: export stamps against the last written or
/// applied config (YapConfigLoader.makeConfigData), apply merges by id and drops tombstoned modes
/// (YapConfigLoader.applyConfigData → applySections).
@MainActor final class Mac {
    let name: String
    var modes: [ModeConfig] = []
    private var baseline: YapConfig?
    let store: DeviceStore
    private(set) var sync: CloudConfigSync!
    private let suite: String

    init(name: String, token: String) {
        self.name = name
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
            version: "sync-e2e", customPrompts: [], modeConfigs: modes, modeShortcuts: nil, vocabularyWords: nil,
            wordReplacements: nil, generalSettings: nil, customEmojis: nil, customCloudModels: nil)
        let config = YapConfig.exported(from: backup, existing: nil) { _ in true }
            .normalized().stamped(baseline: baseline, now: Date())
        guard let data = try? config.encoded() else { return nil }
        baseline = config
        return data
    }

    func apply(_ data: Data) throws {
        let config = try YapConfig.decode(data)
        baseline = config
        if let sections = config.backupSections(currentModes: modes, currentPrompts: [], currentModeShortcuts: [:]) {
            modes = sections.file.modeConfigs
        }
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

    await deleteAccount()
    print(failures == 0 ? "sync-e2e: all scenarios passed" : "sync-e2e: \(failures) scenario(s) failed")
    exit(failures == 0 ? 0 : 1)
}
RunLoop.main.run()
