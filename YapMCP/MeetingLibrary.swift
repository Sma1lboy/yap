import Foundation
import SwiftData

/// Yap's meetings, read from a private copy of its history store: Yap's own files are only ever read, never
/// opened by SQLite, so they stay byte for byte the same while Yap keeps running and writing.
struct MeetingLibrary {
    let dataDirectory: URL

    enum Failure: LocalizedError {
        case busy

        var errorDescription: String? {
            "Yap kept writing its history while it was being copied; try again in a moment."
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

    /// Meetings that started in `since...until`, newest first, at most `limit`; `more` when there are others.
    func meetings(since: Date?, until: Date?, limit: Int) throws -> (meetings: [Summary], more: Bool) {
        try withStore { context in
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
        try withStore { context in
            guard let context else { return nil }
            let kind = Transcription.meetingKind
            var descriptor = FetchDescriptor<Transcription>(predicate: #Predicate { $0.id == id && $0.kind == kind })
            descriptor.fetchLimit = 1
            return try context.fetch(descriptor).first.map {
                MeetingNotes.markdown(for: $0, includeTranscript: includeTranscript, bundle: EnclosingApp.strings)
            }
        }
    }

    /// Runs `body` on a fresh copy of `default.store` (nil when Yap has none yet), deleted afterwards. A copy per
    /// call, so a long agent session sees meetings recorded after it started.
    private func withStore<T>(_ body: (ModelContext?) throws -> T) throws -> T {
        let fileManager = FileManager.default
        let store = dataDirectory.appendingPathComponent("default.store")
        guard fileManager.fileExists(atPath: store.path) else { return try body(nil) }
        let folder = fileManager.temporaryDirectory.appendingPathComponent("yap-mcp-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: folder) }
        let copy = folder.appendingPathComponent("default.store")
        try Self.copyConsistently(store, to: copy)
        // The app's whole model (YapStores). The copy may be migrated, which the original never is: the store can
        // come from another build of Yap (an update installed but not launched yet; a store last written by Yap
        // 1.9.0 has other entity hashes than later builds). Nothing here saves.
        let container = try ModelContainer(
            for: YapStores.schema, configurations: YapStores.historyConfiguration(url: copy))
        return try body(ModelContext(container))
    }

    /// The store is SQLite in WAL mode: the database and its `-wal` together are the data (`-shm` is only an index
    /// SQLite rebuilds from the WAL, and a live one can be ahead of the files). They're copied as a pair (clones on
    /// APFS), and again if Yap changed either meanwhile, so the copy is one moment's state.
    private static func copyConsistently(_ store: URL, to copy: URL) throws {
        let fileManager = FileManager.default
        let wal = URL(fileURLWithPath: store.path + "-wal"), walCopy = URL(fileURLWithPath: copy.path + "-wal")
        func stamps() -> [String] {
            [store, wal].map { url in
                guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else { return "none" }
                let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
                return "\(attributes[.size] ?? 0) \(modified)"
            }
        }
        for _ in 0..<20 {
            let before = stamps()
            for file in [copy, walCopy] { try? fileManager.removeItem(at: file) }
            var copyError: Error?
            do {
                try fileManager.copyItem(at: store, to: copy)
                if before[1] != "none" { try fileManager.copyItem(at: wal, to: walCopy) }
            } catch {
                copyError = error
            }
            if stamps() == before {
                // Nothing changed meanwhile: either a good copy, or a failure that isn't Yap writing.
                if let copyError { throw copyError }
                return
            }
            usleep(50_000)
        }
        throw Failure.busy
    }
}
