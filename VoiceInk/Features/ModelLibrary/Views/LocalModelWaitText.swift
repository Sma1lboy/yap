import Foundation

/// The words for a wait on a local model (the recorder's line under a queued dictation, the Quit panel): what it
/// waits for, the step that work is in, and whether that step can stop early. No percentages or time left: no
/// backend reports those.
extension LocalModelActivity.Snapshot {
    var waitTitle: String {
        switch kind {
        case .transcription(.dictation):
            return cancelled
                ? String(localized: "Waiting for a cancelled dictation")
                : String(localized: "Waiting for an earlier dictation")
        case .transcription(.fileImport):
            return cancelled
                ? String(localized: "Waiting for a cancelled audio import") : String(localized: "Waiting for the audio import")
        case .transcription(.meeting):
            return String(localized: "Waiting for a meeting piece")
        case .transcription(.other):
            return cancelled
                ? String(localized: "Waiting for a cancelled transcription")
                : String(localized: "Waiting for an earlier transcription")
        case .warmUp: return String(localized: "Waiting for the model's warm-up")
        case .load: return String(localized: "Waiting for the model to load")
        case .release: return String(localized: "Waiting for the model to unload")
        }
    }

    var stageText: String {
        switch stage {
        case .loading: return String(localized: "Loading the model")
        case .speechDetection: return String(localized: "Detecting speech")
        case .languageDetection: return String(localized: "Detecting the language")
        case .decoding: return String(localized: "Transcribing")
        case .unloading: return String(localized: "Unloading the model")
        }
    }

    /// "Detecting speech · 00:12", the time in this step so far.
    func stageLine(now: Date) -> String {
        "\(stageText) · \(MeetingNotes.timestamp(now.timeIntervalSince(stageStarted)))"
    }

    /// Cancelled, but in a step the backend can't stop: it ends on its own.
    var stopNote: String? {
        cancelled && !interruptible ? String(localized: "This step can't be stopped; it ends on its own.") : nil
    }
}

extension LocalModelActivity {
    /// What a dictation queued for a local model waits for, once it has waited a second (the usual hand-over from
    /// the work ahead is shorter and isn't worth a line): the oldest work in flight.
    @MainActor func dictationWait(at now: Date) -> Snapshot? {
        guard let since = waits.first(where: { $0.requester == .dictation })?.since,
            now.timeIntervalSince(since) >= 1
        else { return nil }
        return works.first
    }
}
