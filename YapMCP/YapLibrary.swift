import Foundation
import SwiftData

/// Yap's history and dictionary, read from private copies of its stores: Yap's own files are only ever read, never
/// opened by SQLite, so they stay byte for byte the same while Yap keeps running and writing.
struct YapLibrary {
    let dataDirectory: URL
    /// `--log-timing`: each store read logs how long the copy, opening it and reading took (`scripts/mcp-perf.py`).
    var logsTiming = false
    /// The copies the calls read, kept between calls while Yap's files are unchanged.
    let copies = Copies()

    enum Failure: LocalizedError {
        case busy

        var errorDescription: String? {
            "Yap kept writing its data while it was being copied; try again in a moment."
        }
    }

    /// One meeting in `list_meetings`.
    struct Summary {
        let id: UUID
        let started: Date
        let duration: TimeInterval
        let speakers: [String]
        let hasNotes: Bool
        /// nil (done or not needed), `SpeakerSplitSkip.pendingStatus`, or why it failed.
        let speakerStatus: String?
        let untranscribedParts: Int?
    }

    /// One `search_history` result.
    struct Match {
        let id: UUID
        let timestamp: Date
        let isMeeting: Bool
        let appName: String?
        let modeName: String?
        /// The snippet comes from `enhancedText` (a dictation's cleaned-up text, a meeting's notes), else `text`.
        let inEnhancedText: Bool
        let snippet: String
        /// Characters in the whole field the snippet comes from.
        let fullLength: Int
    }

    struct Dictation {
        let id: UUID
        let timestamp: Date
        let duration: TimeInterval
        let appName: String?
        let modeName: String?
        let text: String
        let enhancedText: String?
        let status: String?
    }

    struct DictionaryEntries {
        var words: [(word: String, autoAdded: Bool)]
        var replacements: [(originals: [String], replacement: String, autoAdded: Bool)]
    }

    /// Meetings that started in `since...until`, newest first, at most `limit`; `more` when there are others.
    func meetings(since: Date?, until: Date?, limit: Int) throws -> (meetings: [Summary], more: Bool) {
        try withHistory { context in
            guard let context else { return ([], false) }
            let kind = Transcription.meetingKind
            let from = since ?? .distantPast, to = until ?? .distantFuture
            var descriptor = FetchDescriptor<Transcription>(
                predicate: #Predicate { $0.kind == kind && $0.timestamp >= from && $0.timestamp <= to },
                sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
            descriptor.fetchLimit = limit + 1
            let found = try context.fetch(descriptor)
            let meetings = found.prefix(limit).map { meeting in
                Summary(
                    id: meeting.id, started: meeting.timestamp, duration: meeting.duration,
                    speakers: MeetingNotes.speakers(inTranscript: meeting.text),
                    hasNotes: !(meeting.enhancedText ?? "").isEmpty, speakerStatus: meeting.meetingSpeakerStatus,
                    untranscribedParts: meeting.meetingFailedPieces)
            }
            return (Array(meetings), found.count > limit)
        }
    }

    /// The meeting as History's Export Markdown writes it, or nil when there's no meeting with that id.
    func markdown(id: UUID, includeTranscript: Bool) throws -> String? {
        try withHistory { context in
            guard let context else { return nil }
            let kind = Transcription.meetingKind
            var descriptor = FetchDescriptor<Transcription>(predicate: #Predicate { $0.id == id && $0.kind == kind })
            descriptor.fetchLimit = 1
            return try context.fetch(descriptor).first.map {
                MeetingNotes.markdown(for: $0, includeTranscript: includeTranscript, bundle: EnclosingApp.strings)
            }
        }
    }

    /// History entries containing `query` in their text or enhanced text, by History's own search
    /// (`HistoryQuery.predicate`), newest first, at most `limit`; `more` when there are others.
    func search(_ query: String, filter: HistoryFilter, limit: Int) throws -> (matches: [Match], more: Bool) {
        try withHistory { context in
            guard let context else { return ([], false) }
            var descriptor = FetchDescriptor<Transcription>(
                predicate: HistoryQuery.predicate(search: query, filter: filter),
                sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
            descriptor.fetchLimit = limit + 1
            let found = try context.fetch(descriptor)
            let matches = found.prefix(limit).map { entry in
                let enhanced = entry.enhancedText.flatMap { HistoryQuery.snippet(of: $0, matching: query) }
                // The database matched with its own folding rules; should Foundation's differ, show the text's start.
                let snippet = enhanced ?? HistoryQuery.snippet(of: entry.text, matching: query)
                    ?? String(entry.text.prefix(160)) + (entry.text.count > 160 ? "…" : "")
                return Match(
                    id: entry.id, timestamp: entry.timestamp, isMeeting: entry.isMeeting,
                    appName: entry.sourceAppName ?? entry.sourceAppBundleID, modeName: entry.modeName,
                    inEnhancedText: enhanced != nil, snippet: snippet,
                    fullLength: (enhanced != nil ? entry.enhancedText ?? "" : entry.text).count)
            }
            return (Array(matches), found.count > limit)
        }
    }

    /// One dictation (not a meeting), or nil when there's none with that id.
    func dictation(id: UUID) throws -> Dictation? {
        try withHistory { context in
            guard let context else { return nil }
            var descriptor = FetchDescriptor<Transcription>(predicate: #Predicate { $0.id == id && $0.kind == nil })
            descriptor.fetchLimit = 1
            return try context.fetch(descriptor).first.map {
                Dictation(
                    id: $0.id, timestamp: $0.timestamp, duration: $0.duration,
                    appName: $0.sourceAppName ?? $0.sourceAppBundleID, modeName: $0.modeName, text: $0.text,
                    enhancedText: $0.enhancedText, status: $0.transcriptionStatus)
            }
        }
    }

    /// Whether `id` is a meeting, so a get_dictation on it can point to get_meeting.
    func isMeeting(id: UUID) throws -> Bool {
        try withHistory { context in
            guard let context else { return false }
            let kind = Transcription.meetingKind
            var descriptor = FetchDescriptor<Transcription>(predicate: #Predicate { $0.id == id && $0.kind == kind })
            descriptor.fetchLimit = 1
            return try context.fetchCount(descriptor) > 0
        }
    }

    /// The dictionary's words and replacement rules, each sorted by its text, those containing `query` (in a
    /// word, a rule's original or its replacement) when given.
    func dictionary(matching query: String?) throws -> DictionaryEntries {
        try withStore("dictionary.store", { YapStores.dictionaryConfiguration(url: $0, cloudKitDatabase: .none) }) {
            context in
            guard let context else { return DictionaryEntries(words: [], replacements: []) }
            func keeps(_ texts: [String]) -> Bool {
                guard let query, !query.isEmpty else { return true }
                return texts.contains { $0.localizedStandardContains(query) }
            }
            func ordered(_ a: String, _ b: String) -> Bool { a.localizedStandardCompare(b) == .orderedAscending }
            let words = try context.fetch(FetchDescriptor<VocabularyWord>())
                .filter { keeps([$0.word]) }
                .map { (word: $0.word, autoAdded: $0.isAutoLearned) }
                .sorted { ordered($0.word, $1.word) }
            let replacements = try context.fetch(FetchDescriptor<WordReplacement>())
                .filter { keeps([$0.originalText, $0.replacementText]) }
                .map {
                    (originals: WordReplacementVariants.parse($0.originalText), replacement: $0.replacementText,
                     autoAdded: $0.isAutoLearned)
                }
                .sorted { ordered($0.originals.first ?? "", $1.originals.first ?? "") }
            return DictionaryEntries(words: words, replacements: replacements)
        }
    }

    private func withHistory<T>(_ body: (ModelContext?) throws -> T) throws -> T {
        try withStore("default.store", { YapStores.historyConfiguration(url: $0) }, body)
    }

    /// Runs `body` on a private copy of the store `name` (nil when Yap has none yet). The copy is made when Yap's
    /// store or its `-wal` has changed since the last one (`Copies`), so a long agent session sees what Yap
    /// recorded after it started and reads nothing older.
    private func withStore<T>(
        _ name: String, _ configuration: (URL) -> ModelConfiguration, _ body: (ModelContext?) throws -> T
    ) throws -> T {
        let fileManager = FileManager.default
        let store = dataDirectory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: store.path) else { return try body(nil) }
        let clock = ContinuousClock()
        let start = clock.now
        let container: ModelContainer
        var copied = start
        if let kept = copies.kept[name], kept.stamps == Self.stamps(of: store) {
            container = kept.container
        } else {
            copies.remove(name)
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("yap-mcp-\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let copy = folder.appendingPathComponent(name)
                let stamps = try Self.copyConsistently(store, to: copy)
                copied = clock.now
                // The app's whole model (YapStores). The copy may be migrated, which the original never is: the store
                // can come from another build of Yap (an update installed but not launched yet; a store last written
                // by Yap 1.9.0 has other entity hashes than later builds). Nothing here saves. A Release dictionary
                // store was written with CloudKit; its copy is opened without.
                container = try ModelContainer(for: YapStores.schema, configurations: configuration(copy))
                copies.kept[name] = Copies.Copy(stamps: stamps, folder: folder, container: container)
            } catch {
                try? FileManager.default.removeItem(at: folder)
                throw error
            }
        }
        let opened = clock.now
        // A new context each call: nothing read for an earlier call is kept.
        let result = try body(ModelContext(container))
        if logsTiming {
            func ms(_ duration: Duration) -> String { String(format: "%.1f", duration / .milliseconds(1)) }
            log("timing \(name): copy \(ms(copied - start)) ms, open \(ms(opened - copied)) ms, read \(ms(clock.now - opened)) ms"
                + (copied == start ? ", copy reused" : ""))
        }
        return result
    }

    /// Deletes the copies. The server calls it before it exits.
    func removeCopies() {
        for name in Array(copies.kept.keys) { copies.remove(name) }
    }

    /// The copy of each store and the container open on it, kept while Yap's files are unchanged: opening a copy
    /// makes SQLite rebuild the WAL's index (the `-shm`, which isn't copied), about 90 ms for a 4 MB WAL, and a
    /// session's calls usually come seconds apart while Yap writes nothing.
    final class Copies {
        struct Copy {
            let stamps: [String]
            let folder: URL
            let container: ModelContainer
        }

        var kept: [String: Copy] = [:]

        func remove(_ name: String) {
            guard let copy = kept.removeValue(forKey: name) else { return }
            try? FileManager.default.removeItem(at: copy.folder)
        }
    }

    /// The store's and its `-wal`'s file number, size and modification time (to the nanosecond): any write by Yap
    /// changes one of them.
    private static func stamps(of store: URL) -> [String] {
        [store.path, store.path + "-wal"].map { path in
            var info = stat()
            guard stat(path, &info) == 0 else { return "none" }
            return "\(info.st_ino) \(info.st_size) \(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)"
        }
    }

    /// The store is SQLite in WAL mode: the database and its `-wal` together are the data (`-shm` is only an index
    /// SQLite rebuilds from the WAL, and a live one can be ahead of the files). They're copied as a pair (clones on
    /// APFS), and again if Yap changed either meanwhile, so the copy is one moment's state. Returns that moment's
    /// stamps.
    private static func copyConsistently(_ store: URL, to copy: URL) throws -> [String] {
        let wal = URL(fileURLWithPath: store.path + "-wal"), walCopy = URL(fileURLWithPath: copy.path + "-wal")
        for _ in 0..<20 {
            let before = stamps(of: store)
            for file in [copy, walCopy] { try? fileManager.removeItem(at: file) }
            var copyError: Error?
            do {
                try fileManager.copyItem(at: store, to: copy)
                if before[1] != "none" { try fileManager.copyItem(at: wal, to: walCopy) }
            } catch {
                copyError = error
            }
            if stamps(of: store) == before {
                // Nothing changed meanwhile: either a good copy, or a failure that isn't Yap writing.
                if let copyError { throw copyError }
                return before
            }
            log("\(store.lastPathComponent) changed while it was copied; copying again")
            usleep(50_000)
        }
        throw Failure.busy
    }
}
