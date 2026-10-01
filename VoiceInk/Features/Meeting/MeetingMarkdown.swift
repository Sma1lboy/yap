import Foundation

/// Turns a meeting's segments into the saved transcript, the notes request (MeetingNotes.swift) and the Markdown
/// export (here). This file is also compiled into yap-mcp, so its `get_meeting` returns the same bytes as History's
/// Export Markdown: it may use only Foundation and Transcription, and its words come from `bundle` (yap-mcp passes
/// Yap.app's, since its own has no translations).
enum MeetingNotes {
    static func timestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    /// The speakers of a saved transcript, in order of first appearance, as its `[00:12] Name: …` lines call them:
    /// the names given in History, else Me / Others / Others 2.
    static func speakers(inTranscript text: String) -> [String] {
        var seen = Set<String>()
        return text.split(separator: "\n").compactMap { line -> String? in
            guard let time = line.range(of: #"^\[\d+:\d{2}(:\d{2})?\] "#, options: .regularExpression),
                let colon = line.range(of: ": ", range: time.upperBound..<line.endIndex)
            else { return nil }
            let name = String(line[time.upperBound..<colon.lowerBound])
            return seen.insert(name).inserted ? name : nil
        }
    }

    /// A meeting's notes, as the History tab and the Markdown heading call them ("纪要"). Its own key: the plain
    /// "Notes" key is the Notes app (备忘录).
    static func notesTitle(bundle: Bundle = .main) -> String {
        String(localized: "meeting.notesTitle", defaultValue: "Notes", bundle: bundle)
    }

    /// A saved meeting as History's Export Markdown writes it: the saved transcript, so speaker names are in it.
    /// Without the transcript (yap-mcp's `include_transcript: false`) it ends after the notes.
    static func markdown(for transcription: Transcription, includeTranscript: Bool = true, bundle: Bundle = .main) -> String {
        markdown(
            date: transcription.timestamp, duration: transcription.duration, notes: transcription.enhancedText,
            transcript: includeTranscript ? transcription.text : nil, bundle: bundle)
    }

    static func markdown(date: Date, duration: TimeInterval, notes: String?, transcript: String?, bundle: Bundle = .main) -> String {
        let when = date.formatted(date: .abbreviated, time: .shortened)
        var sections = ["# \(String(localized: "Meeting", bundle: bundle))", "\(when) · \(timestamp(duration))"]
        if let notes, !notes.isEmpty {
            sections.append("## \(notesTitle(bundle: bundle))\n\n\(notes)")
        }
        if let transcript {
            let lines = transcript.split(separator: "\n").map { line -> String in
                // "[00:12] Me: text" → "**[00:12] Me**: text"
                guard let colon = line.range(of: ": "), line.hasPrefix("[") else { return String(line) }
                return "**\(line[..<colon.lowerBound])**: \(line[colon.upperBound...])"
            }
            sections.append("## \(String(localized: "Transcript", bundle: bundle))\n\n" + lines.joined(separator: "\n\n"))
        }
        return sections.joined(separator: "\n\n") + "\n"
    }
}
