import Foundation
import SwiftData

@Model
final class SessionMetric {
    var id: UUID = UUID()
    var transcriptionId: UUID = UUID()
    var timestamp: Date = Date()
    var source: String?
    var wordCount: Int = 0
    var audioDuration: TimeInterval = 0
    var transcriptionModelName: String?
    var transcriptionDuration: TimeInterval?
    var speedFactor: Double?
    @Attribute(originalName: "powerModeName")
    var modeName: String?
    var aiEnhancementModelName: String?
    var enhancementDuration: TimeInterval?
    var enhancementEstimatedTokenCount: Int?

    // DictationTimeline: how the dictation was stopped and, in seconds after that, when each step finished. Nil on
    // metrics recorded before these fields existed and for steps that didn't happen (no model load, no AI cleanup,
    // no ⌘V). Optional, so SwiftData adds the columns by lightweight migration.
    /// DictationTimeline.StopSource raw value.
    var stopSource: String?
    var stopToRecorderStopped: TimeInterval?
    var stopToModelReady: TimeInterval?
    var stopToTranscribed: TimeInterval?
    var stopToProcessed: TimeInterval?
    var stopToEnhanced: TimeInterval?
    var stopToPasteCommand: TimeInterval?
    /// DictationTimeline.PasteOutcome raw value; nil when the text wasn't pasted (a response, a custom command).
    var pasteOutcome: String?

    // The mode whose language setting the transcription used, and, with that set to auto on local Whisper, the
    // languages Whisper decoded the dictation in (comma-separated, in order, e.g. "zh" or "en,zh") and how long
    // detecting them took. Nil on older metrics, a set language, and every other model. Never leaves the Mac.
    var modeID: UUID?
    var detectedLanguages: String?
    var languageDetectionDuration: TimeInterval?

    // What Auto Learn saw become of the pasted text (docs/auto-learn.md, "Correction rate"). All nil when it didn't
    // watch: Auto Learn off, the text wasn't pasted with ⌘V, or metrics recorded before these fields existed.
    /// Auto Learn could tell whether the pasted text was changed.
    var editObserved: Bool?
    /// AutoLearnUnobservableReason raw value, when it couldn't.
    var editUnobservableReason: String?
    /// editDistance > 0.
    var editChanged: Bool?
    /// AutoLearnEditMeasure.distance: 0 untouched … 1 deleted or rewritten.
    var editDistance: Double?

    init(
        transcriptionId: UUID,
        timestamp: Date = Date(),
        source: String? = "recorder",
        wordCount: Int,
        audioDuration: TimeInterval,
        transcriptionModelName: String?,
        transcriptionDuration: TimeInterval?,
        speedFactor: Double?,
        modeName: String?,
        aiEnhancementModelName: String?,
        enhancementDuration: TimeInterval?,
        enhancementEstimatedTokenCount: Int? = nil
    ) {
        self.id = UUID()
        self.transcriptionId = transcriptionId
        self.timestamp = timestamp
        self.source = source
        self.wordCount = wordCount
        self.audioDuration = audioDuration
        self.transcriptionModelName = transcriptionModelName
        self.transcriptionDuration = transcriptionDuration
        self.speedFactor = speedFactor
        self.modeName = modeName
        self.aiEnhancementModelName = aiEnhancementModelName
        self.enhancementDuration = enhancementDuration
        self.enhancementEstimatedTokenCount = enhancementEstimatedTokenCount
    }
}

/// Which metrics count as a real dictation pasted with ⌘V, and its measured stop → ⌘V time. Home's week panel and
/// Insights' time saved both filter through this (docs/dictation-latency.md, "On Home").
extension SessionMetric {
    /// A dictation recorded with its timeline (not older metrics, recovered recordings or a `make dictation-latency`
    /// file) whose text went out with ⌘V. Not proof the app in front inserted it. Raw values of
    /// DictationTimeline.StopSource and PasteOutcome: this file is also built into yap-mcp, which doesn't have them.
    static func isRealPaste(source: String?, stopSource: String?, pasteOutcome: String?) -> Bool {
        let stops: Set = ["shortcutRelease", "shortcutPress", "recorderButton", "finishAndSend", "other"]
        guard source == "recorder", let stopSource, stops.contains(stopSource) else { return false }
        return pasteOutcome == "pasted"
    }

    /// Seconds from the stop to ⌘V for a real paste; nil when it isn't one or the time is missing, negative or not
    /// finite. Never 0 in place of a missing time.
    static func measuredPasteWait(
        source: String?, stopSource: String?, pasteOutcome: String?, stopToPasteCommand: TimeInterval?
    ) -> TimeInterval? {
        guard isRealPaste(source: source, stopSource: stopSource, pasteOutcome: pasteOutcome),
            let seconds = stopToPasteCommand, seconds.isFinite, seconds >= 0
        else { return nil }
        return seconds
    }

    var measuredPasteWait: TimeInterval? {
        Self.measuredPasteWait(
            source: source, stopSource: stopSource, pasteOutcome: pasteOutcome, stopToPasteCommand: stopToPasteCommand)
    }
}
