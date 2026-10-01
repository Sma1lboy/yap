import Foundation
import SwiftData

enum TranscriptionStatus: String, Codable {
    case pending
    case completed
    case failed
    case canceled
    /// The transcript was a known Whisper hallucination on near-silence; kept in History, never pasted.
    case filtered
}

@Model
final class Transcription {
    static let canceledTranscriptionText = "The transcription was canceled."

    var id: UUID = UUID()
    var text: String = ""
    var enhancedText: String?
    var timestamp: Date = Date()
    var duration: TimeInterval = 0
    var audioFileURL: String?
    var transcriptionModelName: String?
    var aiEnhancementModelName: String?
    /// True when a Yap Cloud call (transcription or cleanup) succeeded for this record; History tags it.
    var usedYapCloud: Bool?
    /// OpenRouter generation ids of this record's Yap Cloud calls, used to look up what they were charged.
    var yapCloudTranscriptionGenerationID: String?
    var yapCloudEnhancementGenerationID: String?
    /// Cached total charge of those calls (positive micros), filled the first time History shows the cost.
    var yapCloudCostMicros: Int64?
    var promptName: String?
    var transcriptionDuration: TimeInterval?
    var enhancementDuration: TimeInterval?
    var aiRequestSystemMessage: String?
    var aiRequestUserMessage: String?
    @Attribute(originalName: "powerModeName")
    var modeName: String?
    @Attribute(originalName: "powerModeEmoji")
    var modeEmoji: String?
    var transcriptionStatus: String?
    /// The app that was frontmost when the dictation started (nil for older rows, meetings and imported files).
    var sourceAppName: String?
    var sourceAppBundleID: String?
    /// Timed segments of a transcribed file (JSON `[TimedSegment]`), for subtitle export. Only local Whisper
    /// transcriptions of imported files have them.
    var segmentsJSON: String?

    /// nil for a dictation; `meetingKind` for a meeting recording (MeetingRecorder): notes in `enhancedText`,
    /// the timestamped transcript in `text`, the mix of both channels in `audioFileURL`.
    var kind: String?
    static let meetingKind = "meeting"
    var isMeeting: Bool { kind == Self.meetingKind }
    /// A meeting's pieces that couldn't be transcribed (each is a marked line in `text`); nil when none.
    var meetingFailedPieces: Int?
    /// A meeting's speaker names (JSON `MeetingSpeakerNames`, "Others 1" → "Reed"); nil when none were given.
    var meetingSpeakerNamesJSON: String?
    /// A meeting whose remote speakers are still being told apart in the background: "pending"
    /// (`SpeakerSplitSkip.pendingStatus`); why that failed (a `SpeakerSplitSkip` raw value); nil otherwise.
    var meetingSpeakerStatus: String?

    init(
        text: String,
        duration: TimeInterval,
        enhancedText: String? = nil,
        audioFileURL: String? = nil,
        transcriptionModelName: String? = nil,
        aiEnhancementModelName: String? = nil,
        promptName: String? = nil,
        transcriptionDuration: TimeInterval? = nil,
        enhancementDuration: TimeInterval? = nil,
        aiRequestSystemMessage: String? = nil,
        aiRequestUserMessage: String? = nil,
        modeName: String? = nil,
        modeEmoji: String? = nil,
        transcriptionStatus: TranscriptionStatus = .pending
    ) {
        self.id = UUID()
        self.text = text
        self.enhancedText = enhancedText
        self.timestamp = Date()
        self.duration = duration
        self.audioFileURL = audioFileURL
        self.transcriptionModelName = transcriptionModelName
        self.aiEnhancementModelName = aiEnhancementModelName
        self.promptName = promptName
        self.transcriptionDuration = transcriptionDuration
        self.enhancementDuration = enhancementDuration
        self.aiRequestSystemMessage = aiRequestSystemMessage
        self.aiRequestUserMessage = aiRequestUserMessage
        self.modeName = modeName
        self.modeEmoji = modeEmoji
        self.transcriptionStatus = transcriptionStatus.rawValue
    }

    func markAsCanceledTranscription(
        duration: TimeInterval? = nil,
        modelName: String? = nil
    ) {
        text = Self.canceledTranscriptionText
        enhancedText = nil
        transcriptionStatus = TranscriptionStatus.canceled.rawValue
        if let duration {
            self.duration = duration
        }
        if let modelName {
            transcriptionModelName = modelName
        }
        // Keep enhancement metadata when cancellation happens after an AI attempt.
        transcriptionDuration = nil
        aiRequestSystemMessage = nil
        aiRequestUserMessage = nil
    }
}

extension Transcription {
    /// Deletes a recording. A meeting's `audioFileURL` is the mix in its own folder (Recordings/meetings/<id>/);
    /// the whole folder goes, with both channels and the segments.
    static func removeAudio(at url: URL) throws {
        try FileManager.default.removeItem(at: isMeetingAudio(url) ? url.deletingLastPathComponent() : url)
    }

    /// A file in a meeting's own folder (Recordings/meetings/<id>/).
    static func isMeetingAudio(_ url: URL) -> Bool {
        url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "meetings"
    }
}
