import Foundation

/// The rules Auto Learn added in the last week, with the edit each came from, for the Dictionary's Recently Learned
/// list and its Undo. `auto-learn-recently-learned.json` in Yap's Application Support folder, on this Mac only; entries
/// older than `keptDays`, past the newest `maximumEntries`, or undone are dropped.
actor AutoLearnLearnedLog {
    static let keptDays = 7
    static let maximumEntries = 50

    private let fileURL: URL
    private var entries: [AutoLearnLearnedEntry] = []
    private var isLoaded = false

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppIdentity.supportDirectoryName, isDirectory: true)
            .appendingPathComponent("auto-learn-recently-learned.json")
    }

    /// Newest first.
    func recent(now: Date = Date()) throws -> [AutoLearnLearnedEntry] {
        try loadIfNeeded()
        let kept = Self.pruned(entries, now: now)
        if kept.count != entries.count {
            entries = kept
            try save()
        }
        return entries
    }

    @discardableResult
    func append(_ corrections: [AutoLearnAppliedCorrection], at date: Date = Date()) throws -> [AutoLearnLearnedEntry] {
        try loadIfNeeded()
        let added = corrections.map { AutoLearnLearnedEntry(id: UUID(), learnedAt: date, correction: $0) }
        entries = Self.pruned(added.reversed() + entries, now: date)
        try save()
        return added
    }

    func remove(_ ids: Set<UUID>) throws {
        try loadIfNeeded()
        entries.removeAll { ids.contains($0.id) }
        try save()
    }

    private static func pruned(_ entries: [AutoLearnLearnedEntry], now: Date) -> [AutoLearnLearnedEntry] {
        let cutoff = now.addingTimeInterval(-Double(keptDays) * 86_400)
        return Array(entries.filter { $0.learnedAt >= cutoff }.prefix(maximumEntries))
    }

    private func loadIfNeeded() throws {
        guard !isLoaded else { return }
        if let data = try? Data(contentsOf: fileURL) {
            entries = (try? JSONDecoder().decode([AutoLearnLearnedEntry].self, from: data)) ?? []
        }
        isLoaded = true
    }

    private func save() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(entries).write(to: fileURL, options: [.atomic])
    }
}

#if DEBUG
    extension AutoLearnLearnedLog {
        static func selfCheck() async throws {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("yap-learned-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: url) }
            func correction(_ from: String, _ to: String, vocabularyAt date: Date? = nil) -> AutoLearnAppliedCorrection {
                AutoLearnAppliedCorrection(
                    incorrectTextToReplace: from, correctedVocabularyTerm: to, replacementSourceWasAdded: true,
                    vocabularyCreationDate: date, sourceOriginal: "send it to \(from)", sourceCorrected: "send it to \(to)")
            }
            let now = Date()
            let log = AutoLearnLearnedLog(fileURL: url)
            try await log.append([correction("Jon", "John")], at: now.addingTimeInterval(-8 * 86_400))
            let batch = try await log.append(
                [correction("pay gate", "paygate"), correction("why app", "Yap", vocabularyAt: now)], at: now)

            // A fresh log reads the same file: what was learned survives a relaunch, newest first, a week at most.
            let reloaded = try await AutoLearnLearnedLog(fileURL: url).recent(now: now)
            assert(reloaded.map(\.correction.correctedVocabularyTerm) == ["Yap", "paygate"], "\(reloaded)")
            assert(reloaded.first?.correction == batch.last?.correction, "the vocabulary date round-trips for Undo")

            try await log.remove([batch[0].id])
            let afterUndo = try await log.recent(now: now)
            assert(afterUndo.map(\.correction.correctedVocabularyTerm) == ["Yap"])

            let many = (0..<(maximumEntries + 5)).map { correction("w\($0)", "W\($0)") }
            try await log.append(many, at: now)
            let capped = try await log.recent(now: now)
            assert(capped.count == maximumEntries)
        }
    }
#endif
