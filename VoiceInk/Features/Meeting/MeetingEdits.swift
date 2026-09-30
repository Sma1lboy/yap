import Foundation
import SwiftData

/// Changing a saved meeting from History or the meeting panel: naming its speakers and writing its notes again.
@MainActor
enum MeetingEdits {
    /// The meeting's `segments.json`; nil when its folder is gone (audio retention) or it has none.
    static func segments(of transcription: Transcription) -> [MeetingSegment]? {
        guard transcription.isMeeting, let string = transcription.audioFileURL, let mix = URL(string: string),
            let data = try? Data(contentsOf: mix.deletingLastPathComponent().appendingPathComponent("segments.json"))
        else { return nil }
        return try? JSONDecoder().decode([MeetingSegment].self, from: data)
    }

    /// The people in a meeting, in order of first appearance: key ("me", "others-2") and default label.
    static func speakers(in segments: [MeetingSegment]) -> [(key: String, label: String)] {
        var seen = Set<String>()
        return segments.sorted { $0.start < $1.start }.compactMap { segment in
            seen.insert(segment.speakerKey).inserted ? (segment.speakerKey, segment.label) : nil
        }
    }

    static func markdown(for transcription: Transcription) -> String {
        MeetingNotes.markdown(
            title: String(localized: "Meeting"), date: transcription.timestamp, duration: transcription.duration,
            notes: transcription.enhancedText, transcript: transcription.text)
    }

    /// Stores the names and rewrites the transcript with them; timestamps, pieces and `segments.json` stay as
    /// they are. The notes aren't touched (regenerate them for the new names). Returns why it couldn't be saved.
    static func rename(_ transcription: Transcription, names: MeetingSpeakerNames, in context: ModelContext) -> String? {
        guard let segments = segments(of: transcription) else {
            return String(localized: "This meeting's recording folder is gone, so its speakers can't be renamed.")
        }
        let names = names.cleaned()
        let (oldText, oldNames) = (transcription.text, transcription.meetingSpeakerNamesJSON)
        transcription.meetingSpeakerNamesJSON = names.json
        if !segments.isEmpty { transcription.text = MeetingNotes.transcript(segments, names: names) }
        do {
            try context.save()
            return nil
        } catch {
            (transcription.text, transcription.meetingSpeakerNamesJSON) = (oldText, oldNames)
            return error.localizedDescription
        }
    }

    /// Writes the notes again with the meeting prompt, the current mode's AI provider and the speakers' names.
    /// The old notes stay unless new ones were written and saved. Returns why there are no new notes.
    static func regenerateNotes(for transcription: Transcription, engine: VoiceInkEngine) async -> String? {
        let names = transcription.meetingSpeakerNames
        // Notes from what was understood, as when the meeting ended; without segments.json, the saved transcript.
        let transcript = segments(of: transcription).map { MeetingNotes.transcript($0.filter { !$0.isFailed }, names: names) }
            ?? transcription.text
        let summary = await MeetingSummarizer(engine: engine).notes(for: transcript, names: names)
        guard let notes = summary.notes else {
            if summary.problem == MeetingSummarizer.setupHint {
                return String(localized: "AI enhancement is off in the current mode, or the mode has no AI provider that can write notes (Yap Refine can't). Turn it on and choose a provider, then try again.")
            }
            return summary.problem ?? String(localized: "The AI provider returned no notes.")
        }
        let old = (transcription.enhancedText, transcription.aiEnhancementModelName, transcription.promptName,
            transcription.enhancementDuration, transcription.aiRequestSystemMessage, transcription.aiRequestUserMessage)
        transcription.enhancedText = notes
        transcription.aiEnhancementModelName = summary.modelName
        transcription.promptName = MeetingNotes.promptTitle
        transcription.enhancementDuration = summary.duration
        transcription.aiRequestSystemMessage = summary.systemMessage
        transcription.aiRequestUserMessage = summary.userMessage
        do {
            try engine.modelContext.save()
            return nil
        } catch {
            (transcription.enhancedText, transcription.aiEnhancementModelName, transcription.promptName,
                transcription.enhancementDuration, transcription.aiRequestSystemMessage,
                transcription.aiRequestUserMessage) = old
            return error.localizedDescription
        }
    }
}

#if DEBUG
    extension MeetingEdits {
        static func selfCheck() {
            let me = MeetingSegment.Speaker.me.label, others = MeetingSegment.Speaker.others.label
            let segments = [
                MeetingSegment(speaker: .me, start: 0, end: 5, text: "开始吧"),
                MeetingSegment(speaker: .others, start: 6, end: 9, text: "ok", remote: 2),
                MeetingSegment(speaker: .others, start: 10, end: 14, text: "", remote: 1, failed: true),
                MeetingSegment(speaker: .others, start: 15, end: 18, text: "Friday", remote: 2),
            ]
            assert(speakers(in: segments).map(\.key) == ["me", "others-2", "others-1"])

            // Names apply to every line of that speaker, failed ones too; unnamed speakers keep their label.
            let names: MeetingSpeakerNames = ["others-2": " Reed\n ", "others-1": "Shelley: PM", "me": ""]
            let clean = names.cleaned()
            assert(clean == ["others-2": "Reed", "others-1": "Shelley PM"])
            assert(MeetingNotes.transcript(segments, names: clean) == """
                [00:00] \(me): 开始吧
                [00:06] Reed: ok
                [00:10] Shelley PM: \(MeetingNotes.failedMarker)
                [00:15] Reed: Friday
                """)
            assert(MeetingNotes.transcript(segments, names: [:]) == MeetingNotes.transcript(segments))

            // Stored as JSON; a meeting without names (every meeting before this) reads as none.
            assert(MeetingSpeakerNames.decode(clean.json) == clean)
            assert(MeetingSpeakerNames.decode(nil).isEmpty && MeetingSpeakerNames.decode("junk").isEmpty)
            assert(MeetingSpeakerNames().json == nil)
            // segments.json from before remote numbers: plain "Others", renamed by the "others" key.
            let old = #"[{"speaker":"others","start":1,"end":4,"text":"hi"},{"speaker":"me","start":0,"end":1,"text":"yo"}]"#
            let decoded = try? JSONDecoder().decode([MeetingSegment].self, from: Data(old.utf8))
            assert(decoded.map { speakers(in: $0).map(\.key) } == ["me", "others"])
            assert(decoded.map { MeetingNotes.transcript($0, names: ["others": "Reed"]) } == "[00:00] \(me): yo\n[00:01] Reed: hi")
            assert(decoded.map { MeetingNotes.transcript($0) } == "[00:00] \(me): yo\n[00:01] \(others): hi")

            // The prompt: unchanged without names; with them, who the user is and who the others are.
            assert(MeetingNotes.named(MeetingNotes.prompt, names: [:]) == MeetingNotes.prompt)
            let named = MeetingNotes.named(MeetingNotes.prompt, names: ["me": "Jackson", "others-1": "Reed", "others-2": "Shelley"])
            assert(named.hasPrefix(MeetingNotes.prompt))
            assert(named.contains("\"Jackson\" is the person who recorded the meeting") && named.contains("\"Reed\", \"Shelley\""))
            let othersOnly = MeetingNotes.named(MeetingNotes.partPrompt, names: ["others": "Reed"])
            assert(!othersOnly.contains("recorded the meeting (the user)") && othersOnly.contains("\"Reed\""))
        }
    }
#endif
