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
