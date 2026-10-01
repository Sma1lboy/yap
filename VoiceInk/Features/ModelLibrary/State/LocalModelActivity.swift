import Combine
import Foundation

/// What the local models are busy with, for the waits a user can see: a dictation queued behind another
/// transcription (one that was cancelled but is still in a step that can't stop, an import, a meeting piece), and Quit
/// waiting for the work in flight. Backends report each piece of work (`begin`, `Work.stage`, `Work.end`) and each
/// request waiting for a model's turn (`beginWait`). Reporting is lock-based and never waits for the main actor; the
/// main-actor copies (`works`, `waits`) are what views read. While any work runs, Yap holds a user-initiated activity
/// so macOS doesn't App Nap it (`activityToken`).
final class LocalModelActivity: ObservableObject, @unchecked Sendable {
    static let shared = LocalModelActivity()

    /// Who asked for a transcription. Set by the callers that show a wait (`$requester.withValue`).
    enum Requester: Sendable, Equatable { case dictation, meeting, fileImport, other }
    @TaskLocal static var requester: Requester = .other
    /// The work the current task is doing, so the backend code below the turn can report its stage.
    @TaskLocal static var current: Work?

    enum Kind: Sendable, Equatable { case transcription(Requester), warmUp, load, release }
    enum Stage: Sendable, Equatable { case loading, speechDetection, languageDetection, decoding, unloading }

    struct Snapshot: Identifiable, Equatable, Sendable {
        let id: UInt64
        let kind: Kind
        var stage: Stage
        /// When this stage started (wall clock, for the elapsed time shown).
        var stageStarted: Date
        var cancelled: Bool
        /// False when the backend can't stop the current stage on a cancel: Whisper's language detection pass,
        /// FluidAudio's decode, a model load. A cancel then waits for the stage to end.
        var interruptible: Bool
    }

    final class Work: @unchecked Sendable {
        fileprivate let id: UInt64
        private weak var owner: LocalModelActivity?
        fileprivate init(id: UInt64, owner: LocalModelActivity) {
            self.id = id
            self.owner = owner
        }
        func stage(_ stage: Stage, interruptible: Bool = true) {
            owner?.update(id) {
                $0.stage = stage
                $0.stageStarted = Date()
                $0.interruptible = interruptible
            }
        }
        func markCancelled() { owner?.update(id) { $0.cancelled = true } }
        func end() { owner?.finish(id) }
    }

    final class Wait: @unchecked Sendable {
        private let id: UInt64
        private weak var owner: LocalModelActivity?
        fileprivate init(id: UInt64, owner: LocalModelActivity) {
            self.id = id
            self.owner = owner
        }
        func end() { owner?.finishWait(id) }
    }

    struct WaitSnapshot: Equatable, Sendable {
        let requester: Requester
        let since: Date
    }

    /// In the order they started; the first is the one everything else waits for.
    @MainActor @Published private(set) var works: [Snapshot] = []
    @MainActor @Published private(set) var waits: [WaitSnapshot] = []

    private let lock = NSLock()
    private var lastID: UInt64 = 0
    private var running: [Snapshot] = []
    private var waiting: [(id: UInt64, wait: WaitSnapshot)] = []
    private var publishQueued = false
    /// Held while any work runs (`ProcessInfo.beginActivity`, user-initiated, idle sleep still allowed). Without it,
    /// partway through a `make lifecycle-check` run (Yap in the background, no window in front) speech detection over
    /// 65 s of audio took 0.86-1.28 s instead of 0.15 s, and 22 minutes took 9-20 s instead of 3.8-4.0 s; the same
    /// work run as a background-QoS process slows down about as much, which is what App Nap does to an app.
    private var activityToken: NSObjectProtocol?

    func begin(_ kind: Kind, stage: Stage, interruptible: Bool = true) -> Work {
        let id = lock.withLock { () -> UInt64 in
            lastID &+= 1
            running.append(
                Snapshot(
                    id: lastID, kind: kind, stage: stage, stageStarted: Date(), cancelled: false,
                    interruptible: interruptible))
            if activityToken == nil {
                activityToken = ProcessInfo.processInfo.beginActivity(
                    options: .userInitiatedAllowingIdleSystemSleep, reason: "Transcribing with a local model")
            }
            return lastID
        }
        publish()
        return Work(id: id, owner: self)
    }

    /// `body` as one piece of work, its `current` while it runs; a cancel of the calling task marks it cancelled.
    func run<T>(_ kind: Kind, stage: Stage, interruptible: Bool, _ body: () async throws -> T) async rethrows -> T {
        let work = begin(kind, stage: stage, interruptible: interruptible)
        defer { work.end() }
        return try await withTaskCancellationHandler {
            try await Self.$current.withValue(work, operation: body)
        } onCancel: {
            work.markCancelled()
        }
    }

    func beginWait(_ requester: Requester) -> Wait {
        let id = lock.withLock { () -> UInt64 in
            lastID &+= 1
            waiting.append((lastID, WaitSnapshot(requester: requester, since: Date())))
            return lastID
        }
        publish()
        return Wait(id: id, owner: self)
    }

    private func update(_ id: UInt64, _ change: (inout Snapshot) -> Void) {
        lock.withLock {
            guard let index = running.firstIndex(where: { $0.id == id }) else { return }
            change(&running[index])
        }
        publish()
    }

    private func finish(_ id: UInt64) {
        lock.withLock {
            running.removeAll { $0.id == id }
            if running.isEmpty, let activityToken {
                ProcessInfo.processInfo.endActivity(activityToken)
                self.activityToken = nil
            }
        }
        publish()
    }

    private func finishWait(_ id: UInt64) {
        lock.withLock { waiting.removeAll { $0.id == id } }
        publish()
    }

    /// The main-actor copies follow the latest state; several changes in a row publish once.
    private func publish() {
        let queue = lock.withLock { () -> Bool in
            guard !publishQueued else { return false }
            publishQueued = true
            return true
        }
        guard queue else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let (works, waits) = self.lock.withLock { () -> ([Snapshot], [WaitSnapshot]) in
                    self.publishQueued = false
                    return (self.running, self.waiting.map(\.wait))
                }
                if self.works != works { self.works = works }
                if self.waits != waits { self.waits = waits }
            }
        }
    }

    #if DEBUG
        /// make ui-snapshots: the waits as they'd be, without running a model.
        @MainActor func setSnapshot(works: [Snapshot], waits: [WaitSnapshot]) {
            self.works = works
            self.waits = waits
        }

        /// make lifecycle-check: the work running right now, not waiting for the main-actor copy (read at
        /// willTerminate, after which nothing more runs on the main actor).
        var runningCount: Int { lock.withLock { running.count } }
    #endif
}
