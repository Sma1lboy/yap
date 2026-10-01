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
    /// the names given in History, else Me / Others / Others 2. yap-mcp's list_meetings runs this on every meeting
    /// it lists, so it reads the UTF-8 bytes directly: a regular expression per line took half a second for 100
    /// hour-long meetings.
    static func speakers(inTranscript text: String) -> [String] {
        var text = text
        var seen = Set<String>()
        var names: [String] = []
        text.withUTF8 { bytes in
            var lineStart = 0
            while lineStart < bytes.count {
                let lineEnd = bytes[lineStart...].firstIndex(of: UInt8(ascii: "\n")) ?? bytes.count
                if let nameStart = afterTimestamp(bytes, lineStart, lineEnd),
                    let colon = (nameStart..<max(nameStart, lineEnd - 1)).first(where: {
                        bytes[$0] == UInt8(ascii: ":") && bytes[$0 + 1] == UInt8(ascii: " ")
                    })
                {
                    let name = String(decoding: UnsafeBufferPointer(rebasing: bytes[nameStart..<colon]), as: UTF8.self)
                    if seen.insert(name).inserted { names.append(name) }
                }
                lineStart = lineEnd + 1
            }
        }
        return names
    }

    /// Where the name starts in `bytes[start..<end]`, after its `[m:ss] ` / `[mm:ss] ` / `[h:mm:ss] ` timestamp; nil
    /// when the line doesn't start with one.
    private static func afterTimestamp(_ bytes: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int) -> Int? {
        var index = start
        func take(_ byte: UInt8) -> Bool {
            guard index < end, bytes[index] == byte else { return false }
            index += 1
            return true
        }
        func digits(exactly count: Int? = nil) -> Bool {
            let first = index
            while index < end, index - first != count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) {
                index += 1
            }
            return index > first && (count == nil || index - first == count)
        }
        guard take(UInt8(ascii: "[")), digits(), take(UInt8(ascii: ":")), digits(exactly: 2) else { return nil }
        if take(UInt8(ascii: ":")), !digits(exactly: 2) { return nil }
        guard take(UInt8(ascii: "]")), take(UInt8(ascii: " ")) else { return nil }
        return index
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
