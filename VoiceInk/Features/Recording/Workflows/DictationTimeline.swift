import CoreGraphics
import Foundation

/// One dictation from the moment the user stopped it to the ⌘V that pasted it: what stopped it, when, and when each
/// step after that finished. Times are seconds of system uptime, the clock of `ProcessInfo.systemUptime` and of the
/// shortcut events (ShortcutMonitor). Stored only in this Mac's stats.store, on the dictation's SessionMetric
/// (docs/dictation-latency.md).
final class DictationTimeline: @unchecked Sendable {
    enum StopSource: String {
        /// Push-to-talk, a held hybrid press, the second tap of a double tap, Rewrite Last Dictation: the key went up.
        case shortcutRelease
        /// Toggle mode, or hybrid after a short tap: the second press.
        case shortcutPress
        /// The recorder's record button.
        case recorderButton
        /// The recorder's Finish and Send.
        case finishAndSend
        /// The menu bar, the Shortcuts app, anything else that toggles the recorder.
        case other
        /// DEBUG `make dictation-latency`: a file instead of a recording.
        case file
    }

    struct Stop {
        let time: TimeInterval
        let source: StopSource

        static func now(_ source: StopSource) -> Stop {
            Stop(time: ProcessInfo.processInfo.systemUptime, source: source)
        }
    }

    /// The steps after the stop, in the order they happen. Each one is optional: `modelReady` only when the
    /// transcription had to load the model first, `enhanced` only with AI cleanup, `pasteCommand` only when ⌘V was sent.
    enum Milestone: String, CaseIterable {
        /// The recorder has drained its buffers and closed the WAV file.
        case recorderStopped
        /// The transcription service finished loading the model it needed.
        case modelReady
        /// The model returned its text.
        case transcribed
        /// Output filter, Chinese cleanup, trigger words, paragraph formatting and word replacements are done.
        case processed
        /// AI cleanup returned (or failed).
        case enhanced
        /// ⌘V went to the frontmost app (the V key-down; AppleScript paste: the script returned).
        case pasteCommand
    }

    enum PasteOutcome: String {
        /// ⌘V was sent.
        case pasted
        /// No Accessibility permission: the text was left on the clipboard and a notification says so.
        case clipboardOnly
        /// The clipboard couldn't be set, or the key events / AppleScript couldn't be sent.
        case failed
    }

    let stop: Stop
    private let lock = NSLock()
    private var times: [Milestone: TimeInterval] = [:]
    private var outcome: PasteOutcome?

    init(stop: Stop) {
        self.stop = stop
    }

    func mark(_ milestone: Milestone, at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.withLock { times[milestone] = time }
    }

    func pasteFinished(_ outcome: PasteOutcome, commandAt time: TimeInterval?) {
        lock.withLock {
            self.outcome = outcome
            if let time { times[.pasteCommand] = time }
        }
    }

    var pasteOutcome: PasteOutcome? { lock.withLock { outcome } }

    /// Seconds from the stop to each step that happened.
    var offsets: [Milestone: TimeInterval] {
        lock.withLock { times.mapValues { $0 - stop.time } }
    }

    /// The dictation whose transcription is running in this task, for services to mark `modelReady`.
    @TaskLocal static var current: DictationTimeline?

    /// Transcription services call this right after loading a model inside a dictation's transcription; a preload
    /// while recording runs outside that scope and marks nothing.
    static func modelDidLoad() {
        current?.mark(.modelReady)
    }

    /// The time each step took: from the previous step that happened (or the stop) to this one. Each stage is named by
    /// the milestone that ends it, so the stages add up to the offset of the last step.
    static func stages(_ offsets: [Milestone: TimeInterval]) -> [(Milestone, TimeInterval)] {
        var previous: TimeInterval = 0
        return Milestone.allCases.compactMap { milestone in
            guard let offset = offsets[milestone] else { return nil }
            defer { previous = offset }
            return (milestone, offset - previous)
        }
    }
}

#if DEBUG
    extension DictationTimeline {
        static func selfCheck() {
            // Push-to-talk: stopped 40 ms after the key went up, model already loaded, no AI cleanup.
            let timeline = DictationTimeline(stop: Stop(time: 100, source: .shortcutRelease))
            timeline.mark(.recorderStopped, at: 100.04)
            timeline.mark(.transcribed, at: 101.0)
            timeline.mark(.processed, at: 101.01)
            timeline.pasteFinished(.pasted, commandAt: 101.2)
            let offsets = timeline.offsets
            let steps = stages(offsets)
            assert(steps.map(\.0) == [.recorderStopped, .transcribed, .processed, .pasteCommand])
            assert(steps.allSatisfy { $0.1 >= 0 }, "every stage is non-negative")
            let total = offsets[.pasteCommand] ?? 0
            assert(abs(steps.reduce(0) { $0 + $1.1 } - total) < 1e-9 && abs(total - 1.2) < 1e-9, "stages add up")
            assert(abs((steps.first { $0.0 == .transcribed }?.1 ?? 0) - 0.96) < 1e-9, "from the previous step")

            // A model loaded inside the transcription and AI cleanup show up as their own stages.
            let cold = DictationTimeline(stop: .now(.shortcutPress))
            cold.mark(.recorderStopped)
            $current.withValue(cold) { modelDidLoad() }
            modelDidLoad()  // outside a dictation: nothing to mark
            cold.mark(.transcribed)
            cold.mark(.processed)
            cold.mark(.enhanced)
            cold.pasteFinished(.pasted, commandAt: ProcessInfo.processInfo.systemUptime)
            let coldStages = stages(cold.offsets)
            assert(coldStages.map(\.0) == Milestone.allCases && coldStages.allSatisfy { $0.1 >= 0 })
            assert(cold.stop.source == .shortcutPress && current == nil)

            // Clipboard fallback: no ⌘V time, so no paste stage and no total.
            let fallback = DictationTimeline(stop: Stop(time: 5, source: .other))
            fallback.mark(.recorderStopped, at: 5.1)
            fallback.pasteFinished(.clipboardOnly, commandAt: nil)
            assert(fallback.pasteOutcome == .clipboardOnly && fallback.offsets[.pasteCommand] == nil)
            assert(stages(fallback.offsets).count == 1)

            // Shortcut events carry their own time: mach ticks on the systemUptime clock.
            let now = ProcessInfo.processInfo.systemUptime
            let ticks = CGEventTimestamp((now - 0.25) * ShortcutMonitor.machTicksPerSecond)
            assert(abs((ShortcutMonitor.uptime(ofEventTimestamp: ticks, now: now) ?? 0) - (now - 0.25)) < 1e-3)
            assert(ShortcutMonitor.uptime(ofEventTimestamp: 0, now: now) == nil, "synthetic events have none")
            let future = CGEventTimestamp((now + 1) * ShortcutMonitor.machTicksPerSecond)
            assert(ShortcutMonitor.uptime(ofEventTimestamp: future, now: now) == nil)
            let stale = CGEventTimestamp((now - 60) * ShortcutMonitor.machTicksPerSecond)
            assert(ShortcutMonitor.uptime(ofEventTimestamp: stale, now: now) == nil)
        }
    }
#endif
