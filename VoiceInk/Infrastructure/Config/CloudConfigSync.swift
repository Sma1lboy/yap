import Foundation
import os

/// One stored config in the cloud: an opaque server version (used as If-Match) and the config.json bytes.
protocol CloudConfigDocument {
    var version: String { get }
    var config: Data { get }
}

/// Where the synced config lives: Yap Cloud (see YapCloud+ConfigSync.swift), or a fake in the selfCheck.
protocol ConfigCloudStore: AnyObject {
    associatedtype Document: CloudConfigDocument
    var isSignedIn: Bool { get }
    /// Nil when nothing has been stored yet (404).
    func fetchConfig() async throws -> Document?
    /// Stores `data` if the stored version still equals `ifMatch` (nil: only if nothing is stored yet);
    /// returns the new version. Throws on a version conflict.
    func putConfig(_ data: Data, ifMatch: String?) async throws -> String
}

/// One stored version of the synced config, as listed by the server.
struct CloudConfigVersionInfo: Equatable, Identifiable {
    let version: String
    let updatedAt: Date?
    /// The Mac that wrote it, when the server knows.
    let deviceName: String?
    let bytes: Int?

    var id: String { version }
}

/// Earlier versions of the synced config (paygate `GET /v1/config/versions[/{v}]`). Optional: a store without it
/// just has no Version History. Restoring is a normal `putConfig` with If-Match, so it needs nothing more.
protocol ConfigVersionHistoryStore: AnyObject {
    /// Versions replaced by later writes, newest first. The current version isn't in the list.
    func listConfigVersions() async throws -> [CloudConfigVersionInfo]
    /// The config bytes stored as `version` (one from the list).
    func fetchConfigVersion(_ version: String) async throws -> Data
}

/// Keeps config.json in sync across Macs through a `ConfigCloudStore`, when "Sync via Yap Cloud" is on.
/// Pulls at launch, pushes after local changes (via `YapConfigLoader`'s change observer).
/// A failed put is re-read: if the stored version moved, the two sides are merged by id and put once more;
/// a second failure is shown as a conflict for the user to resolve, never overwritten silently.
@MainActor
final class CloudConfigSync: ObservableObject {
    enum Status: Equatable {
        case idle
        case synced(Date)
        case conflict
        case error(String)
    }

    struct ConflictError: Error {}

    static let enabledKey = "configCloudSyncEnabled"
    static let versionKey = "configCloudSyncedVersion"
    static let dataKey = "configCloudSyncedData"

    static let shared = CloudConfigSync(
        defaults: .standard,
        localConfig: { await YapConfigLoader.shared.makeCloudConfigData() },
        applyRemote: { data in
            try await YapConfigLoader.shared.applyConfigData(data)
            // The server re-serializes the JSON; this writes config.json's stable form (and a prompt file, if used).
            try YapConfigLoader.shared.writePulledConfig(data)
        })

    /// Set once the Yap Cloud client is available; nil means cloud sync is unavailable.
    var store: (any ConfigCloudStore)?
    @Published private(set) var status: Status = .idle

    private let defaults: UserDefaults
    private let localConfig: () async -> Data?
    private let applyRemote: (Data) async throws -> Void
    private var isSyncing = false
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "CloudConfigSync")

    init(
        defaults: UserDefaults, localConfig: @escaping () async -> Data?,
        applyRemote: @escaping (Data) async throws -> Void
    ) {
        self.defaults = defaults
        self.localConfig = localConfig
        self.applyRemote = applyRemote
    }

    var isAvailable: Bool { store?.isSignedIn == true }

    /// Signed in and the store keeps earlier versions.
    var supportsHistory: Bool { isAvailable && historyStore != nil }
    private var historyStore: (any ConfigVersionHistoryStore)? { store as? any ConfigVersionHistoryStore }

    // MARK: - Version history

    /// The earlier versions (newest first) plus the current one, which the list doesn't include.
    func loadHistory() async throws -> (
        versions: [CloudConfigVersionInfo], current: YapConfig?, currentVersion: String?
    ) {
        guard let historyStore, let store else { return ([], nil, nil) }
        let versions = try await historyStore.listConfigVersions()
        let current = try await store.fetchConfig()
        return (versions, try current.map { try YapConfig.decode($0.config) }, current?.version)
    }

    /// Makes `version`'s contents the current synced config: PUT as a new version with If-Match on the current
    /// one, then apply here. Entries added since `version` get tombstones (`YapConfig.restoring`), so other Macs
    /// delete them instead of merging them back. If another Mac wrote in between, this throws ConflictError
    /// instead of merging: the user looks at the history again and decides.
    func restoreVersion(_ version: String) async throws {
        guard let store, let historyStore else { throw CocoaError(.featureUnsupported) }
        isSyncing = true
        defer { isSyncing = false }
        let old = try YapConfig.decode(try await historyStore.fetchConfigVersion(version))
        let current = try await store.fetchConfig()
        let restored = try YapConfig.restoring(
            old, over: current.map { try YapConfig.decode($0.config) } ?? YapConfig(), now: Date()
        ).encoded()
        let newVersion: String
        do {
            newVersion = try await store.putConfig(restored, ifMatch: current?.version)
        } catch {
            if let latest = try? await store.fetchConfig(), latest.version != current?.version { throw ConflictError() }
            throw error
        }
        try await applyRemote(restored)
        record(version: newVersion, data: await localConfig() ?? restored)
        status = .synced(Date())
    }

    func config(atVersion version: String) async throws -> YapConfig {
        guard let historyStore else { throw CocoaError(.featureUnsupported) }
        return try YapConfig.decode(try await historyStore.fetchConfigVersion(version))
    }
    var isEnabled: Bool { isAvailable && defaults.bool(forKey: Self.enabledKey) }

    func sync() async {
        await run { store, local in try await self.sync(store: store, local: local) }
    }

    /// New-Mac restore, step 1: what the account has stored (nil: never synced). Works before sync is turned on.
    func fetchStored() async throws -> (any CloudConfigDocument)? {
        guard let store, store.isSignedIn else { return nil }
        return try await store.fetchConfig()
    }

    /// New-Mac restore, step 2: applies `document`, turns sync on and records it as the last synced state, so the
    /// next sync pushes only what changes from here.
    func restore(_ document: any CloudConfigDocument) async throws {
        isSyncing = true
        defer { isSyncing = false }
        defaults.set(true, forKey: Self.enabledKey)
        try await pull(document)
        status = .synced(Date())
    }

    /// Conflict resolution from Settings: take the cloud copy, or put this Mac's settings over it.
    func resolveConflict(keepLocal: Bool) async {
        await run { store, local in
            let remote = try await store.fetchConfig()
            if keepLocal {
                try await self.put(local, ifMatch: remote?.version, store: store, retryOnConflict: false)
            } else if let remote {
                try await self.pull(remote)
            }
        }
    }

    private func run(_ body: @escaping (any ConfigCloudStore, Data) async throws -> Void) async {
        guard isEnabled, !isSyncing, let store, let local = await localConfig() else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            try await body(store, local)
            status = .synced(Date())
        } catch is ConflictError {
            status = .conflict
        } catch {
            logger.error("cloud config sync: \(error.localizedDescription, privacy: .public)")
            status = .error(error.localizedDescription)
        }
    }

    private func sync(store: any ConfigCloudStore, local: Data) async throws {
        let syncedVersion = defaults.string(forKey: Self.versionKey)
        let syncedData = defaults.data(forKey: Self.dataKey)
        guard let remote = try await store.fetchConfig() else {
            try await put(local, ifMatch: nil, store: store)
            return
        }
        if remote.version == syncedVersion {
            if local != syncedData { try await put(local, ifMatch: remote.version, store: store) }
            return
        }
        // The cloud moved on since our last sync.
        if local == syncedData || syncedData == nil {
            try await pull(remote)
        } else {
            try await mergeAndPut(local: local, remote: remote, store: store, retryOnConflict: true)
        }
    }

    private func pull(_ remote: some CloudConfigDocument) async throws {
        try await applyRemote(remote.config)
        // Remember this Mac's view of the result, so per-Mac differences don't look like local edits.
        record(version: remote.version, data: await localConfig() ?? remote.config)
    }

    private func mergeAndPut(
        local: Data, remote: some CloudConfigDocument, store: any ConfigCloudStore, retryOnConflict: Bool
    ) async throws {
        let base = defaults.data(forKey: Self.dataKey).flatMap { try? YapConfig.decode($0) }
        let merged = try YapConfig.threeWayMerged(
            base: base, local: YapConfig.decode(local), remote: YapConfig.decode(remote.config)
        ).encoded()
        try await applyRemote(merged)
        try await put(merged, ifMatch: remote.version, store: store, retryOnConflict: retryOnConflict)
    }

    private func put(_ data: Data, ifMatch: String?, store: any ConfigCloudStore, retryOnConflict: Bool = true)
        async throws
    {
        do {
            record(version: try await store.putConfig(data, ifMatch: ifMatch), data: data)
        } catch {
            // Only a conflict if the stored version really moved; other errors (offline, 5xx) pass through.
            guard let remote = try? await store.fetchConfig(), remote.version != ifMatch else { throw error }
            guard retryOnConflict else { throw ConflictError() }
            // A second version move surfaces as ConflictError from the inner put; a network or server error
            // during the retry passes through as itself, so Settings offers Retry instead of conflict choices.
            try await mergeAndPut(local: data, remote: remote, store: store, retryOnConflict: false)
        }
    }

    private func record(version: String, data: Data) {
        defaults.set(version, forKey: Self.versionKey)
        defaults.set(data, forKey: Self.dataKey)
    }
}

#if DEBUG
    extension CloudConfigSync {
        private final class FakeStore: ConfigCloudStore, ConfigVersionHistoryStore {
            struct Document: CloudConfigDocument {
                let version: String
                let config: Data
            }
            var document: Document? {
                didSet { if let oldValue { history.insert(oldValue, at: 0) } }
            }
            /// Replaced versions, newest first (the current one isn't in it, like paygate).
            var history: [Document] = []
            var isSignedIn: Bool { true }
            /// Each put first lets "another Mac" write the next of these.
            var interleavedWrites: [Data] = []
            /// Puts (1-based, counted from the last reset) that fail as if offline.
            var offlinePuts: Set<Int> = []
            var putCount = 0

            func fetchConfig() async throws -> Document? { document }

            func listConfigVersions() async throws -> [CloudConfigVersionInfo] {
                history.map { CloudConfigVersionInfo(version: $0.version, updatedAt: nil, deviceName: nil, bytes: nil) }
            }

            func fetchConfigVersion(_ version: String) async throws -> Data {
                guard let document = history.first(where: { $0.version == version }) else {
                    throw URLError(.fileDoesNotExist)
                }
                return document.config
            }

            func putConfig(_ data: Data, ifMatch: String?) async throws -> String {
                putCount += 1
                if offlinePuts.contains(putCount) { throw URLError(.notConnectedToInternet) }
                if !interleavedWrites.isEmpty {
                    let other = interleavedWrites.removeFirst()
                    document = Document(version: String((Int(document?.version ?? "0") ?? 0) + 1), config: other)
                }
                guard ifMatch == document?.version else { throw URLError(.badServerResponse) }
                let version = String((Int(document?.version ?? "0") ?? 0) + 1)
                document = Document(version: version, config: data)
                return version
            }
        }

        static func selfCheck() async {
            func config(_ modes: [String], words: [String] = []) -> Data {
                var config = YapConfig()
                config.version = YapConfig.currentVersion
                // Stable ids per name, so the same mode on two "Macs" merges.
                let ids = ["Dictation": 1, "Email": 2, "Notes": 3, "Code": 4]
                config.modes = modes.map { name in
                    let id = UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", ids[name]!))!
                    return ModeConfig(id: id, name: name, isAIEnhancementEnabled: false, selectedLanguage: "en")
                }
                config.dictionary = .init(vocabulary: words.isEmpty ? nil : words)
                return try! config.normalized().encoded()
            }
            func names(_ data: Data?) -> [String] {
                (data.flatMap { try? YapConfig.decode($0) }?.modes ?? []).map(\.name)
            }

            let suite = "yap.selfcheck.cloudsync.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set(true, forKey: enabledKey)
            var local = config(["Dictation"])
            let store = FakeStore()
            let sync = CloudConfigSync(
                defaults: defaults, localConfig: { local }, applyRemote: { local = $0 })
            sync.store = store

            // 1. First write: nothing stored yet.
            await sync.sync()
            assert(store.document?.config == local && store.document?.version == "1")
            assert(defaults.string(forKey: versionKey) == "1" && sync.status != .conflict)

            // 2. Pull: another Mac stored a newer version, nothing changed here.
            store.document = .init(version: "2", config: config(["Dictation", "Email"]))
            await sync.sync()
            assert(names(local) == ["Dictation", "Email"] && defaults.string(forKey: versionKey) == "2")

            // 3. Conflict: this Mac adds "Notes" while another Mac adds "Code" just before our put;
            //    the put fails, both sides merge by id and the retry succeeds with both modes.
            local = config(["Dictation", "Email", "Notes"])
            store.interleavedWrites = [config(["Dictation", "Email", "Code"], words: ["Yap"])]
            await sync.sync()
            assert(Set(names(store.document?.config)) == ["Dictation", "Email", "Code", "Notes"])
            assert(names(local) == names(store.document?.config))
            assert((try? YapConfig.decode(local))?.dictionary?.vocabulary == ["Yap"])
            assert(defaults.string(forKey: versionKey) == store.document?.version && sync.status != .conflict)

            // 4. #34: going offline during the merge retry is an error with a reason, not a conflict.
            local = config(["Dictation", "Email", "Code", "Notes"], words: ["Yap", "Rove"])
            store.interleavedWrites = [config(["Dictation"], words: ["Yap"])]
            (store.putCount, store.offlinePuts) = (0, [2])
            await sync.sync()
            guard case .error = sync.status else { return assertionFailure("offline retry should be .error") }

            // 5. A real conflict: the cloud moves on both the merged put and its retry.
            store.interleavedWrites = [config(["Dictation"]), config(["Dictation", "Email"])]
            (store.putCount, store.offlinePuts) = (0, [])
            local = config(["Dictation", "Notes"])
            await sync.sync()
            assert(sync.status == .conflict)

            // 6. Restoring version 1 ("Dictation" only) over the current one: the cloud gets it as a new version
            //    with tombstones for everything added since, and this Mac applies it.
            store.interleavedWrites = []
            (store.putCount, store.offlinePuts) = (0, [])
            let firstVersion = store.history.last!.version
            let beforeRestore = store.document!.version
            let addedSince = (try? YapConfig.decode(store.document!.config))?.modes?
                .filter { $0.name != "Dictation" }.map(\.id.uuidString) ?? []
            try? await sync.restoreVersion(firstVersion)
            let restored = try? YapConfig.decode(store.document!.config)
            assert(store.document!.version != beforeRestore && restored?.modes?.map(\.name) == ["Dictation"])
            assert(!addedSince.isEmpty && Set(restored?.deleted?.modes?.keys ?? [:].keys) == Set(addedSince))
            assert(names(local) == ["Dictation"] && defaults.string(forKey: versionKey) == store.document?.version)
            let history = try? await sync.loadHistory()
            assert(history?.currentVersion == store.document?.version)
            assert(history?.versions.first?.version == beforeRestore && history?.versions.last?.version == firstVersion)

            // 7. Another Mac wrote between reading the current version and the restore's put: a conflict, no merge.
            store.interleavedWrites = [config(["Dictation", "Email"])]
            let versionBefore = store.document!.version
            do {
                try await sync.restoreVersion(firstVersion)
                assertionFailure("restore over a newer version should conflict")
            } catch {
                assert(error is ConflictError && store.document!.version == String(Int(versionBefore)! + 1))
            }
        }
    }
#endif
