import Foundation
import SwiftData
import os

/// Settings › Meetings › Save Meetings to a Folder: off until the user picks a folder and turns it on. Then every
/// time a meeting is saved in History (a new meeting, its speakers arriving later, new speaker names, new notes),
/// its Export Markdown goes to that folder through `MeetingArchive`, under the same rules as Save Meetings to
/// Folder…: one file per meeting and content version, nothing replaced or deleted, the same bytes never twice.
///
/// Only saves that happen while it's on: turning it on doesn't copy History, and a save missed while it was off or
/// queued when Yap quit isn't caught up later (the meeting's next change, or Save Meetings to Folder…, writes it).
///
/// The snapshot (`MeetingArchive.Entry`, plain bytes) is taken on the main actor right after the save succeeded,
/// before anything else hears of it, so a retention cleanup or a deletion right after can't take it away; the
/// files are written one at a time on a serial queue. Turning it off or choosing another folder bumps
/// `generation`: queued saves for the old destination don't start, and the switch waits for the file being written
/// right now before it shows the new state, so nothing more is written after the switch shows off.
///
/// The folder and the switch are this Mac's only (UserDefaults keys that no backup, config.json or Yap Cloud
/// sync carries), so importing someone's settings can't turn it on or point it elsewhere.
@MainActor
final class MeetingAutoArchive: ObservableObject {
    static let shared = MeetingAutoArchive(defaults: .standard)

    static let enabledKey = "meetingAutoArchiveEnabled"
    static let folderKey = "meetingAutoArchiveFolder"

    /// What the last automatic save did; in memory only, since the folder itself shows what's there.
    struct Result: Equatable {
        let item: MeetingArchive.Item
        let date: Date
    }

    @Published private(set) var isEnabled: Bool
    @Published private(set) var folder: URL?
    @Published private(set) var lastResult: Result?
    /// Saved meetings waiting for their file, for this destination.
    @Published private(set) var queued = 0
    /// Turning off or changing the folder waits for the file being written; meanwhile the switch is disabled.
    @Published private(set) var isSwitching = false

    private let defaults: UserDefaults
    private let queue = DispatchQueue(label: "me.sma1lboy.yap.meeting.auto-archive")
    private let generation = OSAllocatedUnfairLock(initialState: 0)
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MeetingAutoArchive")

    #if DEBUG
        /// make meeting-archive-check: each file waits this long after it was allowed to start, so a switch can
        /// land while one is being written and others are queued.
        nonisolated(unsafe) static var writerDelay: TimeInterval = 0
    #endif

    init(defaults: UserDefaults) {
        self.defaults = defaults
        let folder = defaults.string(forKey: Self.folderKey).map { URL(fileURLWithPath: $0, isDirectory: true) }
        self.folder = folder
        isEnabled = folder != nil && defaults.bool(forKey: Self.enabledKey)
    }

    /// Called by `MeetingEdits.save` right after a meeting's change was saved, before any notification about it.
    func saved(_ transcription: Transcription) {
        guard isEnabled, !isSwitching, let folder,
            let entry = MeetingArchive.entries(for: [transcription]).first
        else { return }
        let current = generation.withLock { $0 }
        queued += 1
        let generation = self.generation
        queue.async { [weak self] in
            // Off or another folder since this was queued: it doesn't start.
            guard generation.withLock({ $0 }) == current else { return }
            #if DEBUG
                if Self.writerDelay > 0 { Thread.sleep(forTimeInterval: Self.writerDelay) }
            #endif
            let item = MeetingArchive.export([entry], to: folder).items[0]
            // On the main queue, in order: `drain()` resumes after this has run.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.finished(item, generation: current) } }
        }
    }

    private func finished(_ item: MeetingArchive.Item, generation finished: Int) {
        switch item.outcome {
        case .written, .alreadyThere: break
        default: logger.error("Meeting not saved to the folder: \(String(describing: item.outcome), privacy: .public)")
        }
        guard generation.withLock({ $0 }) == finished else { return }
        queued = max(queued - 1, 0)
        lastResult = Result(item: item, date: Date())
    }

    /// Turns it on with `folder` (a folder the user just chose), or with the folder chosen before.
    func turnOn(folder chosen: URL? = nil) async {
        await switchDestination {
            if let chosen {
                self.folder = chosen
                self.defaults.set(chosen.path, forKey: Self.folderKey)
            }
            self.isEnabled = self.folder != nil
            self.defaults.set(self.isEnabled, forKey: Self.enabledKey)
        }
    }

    func turnOff() async {
        await switchDestination {
            self.isEnabled = false
            self.defaults.set(false, forKey: Self.enabledKey)
        }
    }

    /// Stops queued saves for the current destination, waits for the file being written, then applies `change`.
    private func switchDestination(_ change: @escaping () -> Void) async {
        generation.withLock { $0 += 1 }
        isSwitching = true
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
        change()
        queued = 0
        lastResult = nil
        isSwitching = false
    }

    /// Waits until every save queued so far is done or dropped.
    func drain() async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
        await Task.yield()
    }

    #if DEBUG
        /// make ui-snapshots: the settings rows in a given state.
        func setSnapshotState(enabled: Bool, folder: URL?, queued: Int = 0, last: MeetingArchive.Outcome?) {
            isEnabled = enabled
            self.folder = folder
            self.queued = queued
            lastResult = last.map {
                Result(item: MeetingArchive.Item(
                    id: UUID(), fileName: "2026-09-30 1405 meeting-3f2c8a10-6b1e-4d2a-9c3e-0a1b2c3d4e5f-8e1f4a2b9c0d.md",
                    outcome: $0), date: Date(timeIntervalSince1970: 1_790_000_000))
            }
        }

        /// Real files in a temporary folder, with a settings suite of its own.
        static func selfCheck() async {
            let suite = "me.sma1lboy.yap.auto-archive-check"
            let defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("yap-auto-archive-\(UUID().uuidString)")
            try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            defer {
                defaults.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: root)
            }
            func files() -> [String] { (try? FileManager.default.contentsOfDirectory(atPath: root.path))?.sorted() ?? [] }

            // Off by default; "on" without a folder is off.
            defaults.set(true, forKey: enabledKey)
            let archive = MeetingAutoArchive(defaults: defaults)
            assert(!archive.isEnabled)
            let meeting = Transcription(text: "[00:00] Me: hi", duration: 5, enhancedText: "- hi", transcriptionStatus: .completed)
            meeting.kind = Transcription.meetingKind
            archive.saved(meeting)
            await archive.drain()
            assert(files().isEmpty && archive.lastResult == nil, "off: nothing written")

            // On: a meeting is written once; the same save again finds it; a dictation is never written.
            await archive.turnOn(folder: root)
            assert(archive.isEnabled && defaults.string(forKey: folderKey) == root.path && defaults.bool(forKey: enabledKey))
            archive.saved(meeting)
            archive.saved(meeting)
            archive.saved(Transcription(text: "a dictation", duration: 1, transcriptionStatus: .completed))
            await archive.drain()
            assert(files().count == 1 && archive.lastResult?.item.outcome == .alreadyThere && archive.queued == 0, "\(files())")

            // Turned off while a save is queued behind a slow file: the queued one never starts, and once turnOff
            // returns nothing more is written.
            archive.queue.async { Thread.sleep(forTimeInterval: 0.3) }
            meeting.enhancedText = "- hi again"
            archive.saved(meeting)
            assert(archive.queued == 1)
            await archive.turnOff()
            assert(!archive.isEnabled && !defaults.bool(forKey: enabledKey) && archive.queued == 0 && archive.lastResult == nil)
            await archive.drain()
            assert(files().count == 1, "a queued save ran after turning off: \(files())")
            archive.saved(meeting)
            await archive.drain()
            assert(files().count == 1, "saved while off")

            // On again with the folder chosen before: the next save is a new version next to the first.
            await archive.turnOn()
            assert(archive.folder?.path == root.path)
            archive.saved(meeting)
            await archive.drain()
            assert(files().count == 2 && archive.lastResult?.item.outcome == .written)
        }
    #endif
}
