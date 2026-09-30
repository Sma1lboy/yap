import AppKit
import Foundation

/// One transcribed piece of a meeting: who (the microphone is "me", system audio is "others"), when, what.
struct MeetingSegment: Codable, Equatable {
    enum Speaker: String, Codable {
        case me, others

        var label: String {
            switch self {
            case .me: return String(localized: "Me")
            case .others: return String(localized: "Others")
            }
        }
    }

    let speaker: Speaker
    /// Seconds from the start of the recording.
    let start: TimeInterval
    let end: TimeInterval
    var text: String
    /// Which remote person this is ("Others 2"), when the meeting's system audio was diarized and had several.
    var remote: Int? = nil
    /// The piece couldn't be transcribed: `text` is empty and the transcript shows `MeetingNotes.failedMarker`.
    var failed: Bool? = nil
    /// A "Me" piece that is the other side's voice, picked up by the microphone from the speakers (MeetingEcho):
    /// kept here with its text, left out of the transcript and the notes.
    var echo: Bool? = nil
    /// A "Me" piece the other side's words were cut out of: its text as transcribed; `text` is what the user said.
    var textWithEcho: String? = nil

    var isFailed: Bool { failed == true }
    var isEcho: Bool { echo == true }
    /// Echo was taken out of it: the whole piece or some of its words.
    var hadEcho: Bool { isEcho || textWithEcho != nil }

    var label: String {
        guard speaker == .others, let remote else { return speaker.label }
        return String(format: String(localized: "Others %lld"), remote)
    }

    /// Which person this is, for `MeetingSpeakerNames`: "me", "others", "others-2".
    var speakerKey: String { remote.map { "\(speaker.rawValue)-\($0)" } ?? speaker.rawValue }

    /// The name the user gave this person, else "Me" / "Others" / "Others 2".
    func label(names: MeetingSpeakerNames) -> String { names[speakerKey] ?? label }
}

/// Real names the user gave a meeting's speakers, keyed by `MeetingSegment.speakerKey`. Stored as JSON on the
/// meeting's `Transcription` (`meetingSpeakerNamesJSON`); a meeting without it has no names.
typealias MeetingSpeakerNames = [String: String]

extension MeetingSpeakerNames {
    /// Trimmed, one line, no colons (a transcript line is "[00:12] Name: text"), empty ones dropped.
    func cleaned() -> MeetingSpeakerNames {
        compactMapValues { name in
            let clean = name.replacingOccurrences(of: ":", with: " ").replacingOccurrences(of: "：", with: " ")
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return clean.isEmpty ? nil : clean
        }
    }

    static func decode(_ json: String?) -> MeetingSpeakerNames {
        guard let data = json?.data(using: .utf8) else { return [:] }
        return (try? JSONDecoder().decode(MeetingSpeakerNames.self, from: data)) ?? [:]
    }

    var json: String? {
        guard !isEmpty, let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Turns a meeting's segments into the saved transcript, the notes request and the Markdown export.
enum MeetingNotes {
    static func timestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    /// `[00:12] Me: …` lines in time order (both channels interleaved), without the pieces that are echo. A piece
    /// that failed keeps its line, with `failedMarker` in place of the text.
    static func transcript(_ segments: [MeetingSegment], names: MeetingSpeakerNames = [:]) -> String {
        segments.filter { !$0.isEcho }.sorted { ($0.start, $0.speaker.rawValue) < ($1.start, $1.speaker.rawValue) }
            .map { "[\(timestamp($0.start))] \($0.label(names: names)): \($0.isFailed ? failedMarker : $0.text)" }
            .joined(separator: "\n")
    }

    static var failedMarker: String { String(localized: "(This part couldn't be transcribed.)") }

    /// A meeting's saved text is a transcript when it has timestamped lines; otherwise it's the "nothing was said"
    /// placeholder, or the reason a recovered meeting has its audio only. Doesn't depend on the app's language.
    static func hasLines(_ text: String) -> Bool {
        text.range(of: #"^\[\d+:\d{2}(:\d{2})?\] "#, options: .regularExpression) != nil
    }

    // MARK: - Notes

    static let promptTitle = "Meeting Notes"

    static let prompt = """
        You write meeting notes from a transcript. Lines start with [mm:ss] and a speaker: "Me" (or 我) is the \
        person who recorded the meeting, "Others" (or 对方) is everyone else on the call; \
        when the other people could be told apart they are "Others 1", "Others 2"… (对方 1, 对方 2…), each a different \
        person, and action-item owners use those labels unless a real name was said. The transcript comes from \
        speech recognition, so expect misheard words; fix them only when the meaning is clear.

        Write the notes in the language most of the meeting was spoken in. Keep English terms, product names, code \
        and numbers exactly as spoken; never translate them. Use these Markdown sections, with the headings in the \
        notes' language too (for Chinese notes: 摘要, 决定, 待办, 未决问题), and leave out a section only if the \
        meeting has nothing for it:
        - Summary: 3–5 bullets with the conclusions.
        - Decisions: what was agreed.
        - Action items: "- [ ] task — owner — due date"; write "unassigned" / "未指定" when nobody or no date was named.
        - Open questions: what is still undecided or needs follow-up.

        Use only what is in the transcript; don't invent names, dates or tasks. Output only the notes.
        """

    static let partPrompt = """
        This is one part of a longer meeting transcript (lines start with [mm:ss] and a speaker: "Me"/我 is the \
        person recording, "Others"/对方 everyone else, or "Others 1", "Others 2"… for different people). Write compact notes for this part only: key points, \
        decisions, action items with owners and due dates, open questions, with [mm:ss] where it helps. Keep the \
        language of the transcript and keep English terms as spoken. Output only the notes.
        """

    /// The notes prompt for a meeting whose speakers have names: the same prompt plus who is who. Without names
    /// it's `prompt` unchanged.
    static func named(_ prompt: String, names: MeetingSpeakerNames) -> String {
        guard !names.isEmpty else { return prompt }
        let me = names["me"].map { "\"\($0)\" is the person who recorded the meeting (the user), in place of \"Me\"." }
        let others = names.filter { $0.key != "me" }.sorted { $0.key < $1.key }.map { "\"\($0.value)\"" }
        let rest = others.isEmpty ? nil : "The other people on the call are named: \(others.joined(separator: ", "))."
        return prompt + "\n\nThe speakers in this transcript have real names. "
            + [me, rest].compactMap { $0 }.joined(separator: " ")
            + " Use these names, also as action-item owners."
    }

    /// Transcripts longer than this are summarized in parts first, then the part notes are merged.
    static let maximumCharactersPerRequest = 12_000

    /// Splits at line boundaries into parts of at most `limit` characters (a longer single line is cut).
    static func parts(of transcript: String, limit: Int = maximumCharactersPerRequest) -> [String] {
        var parts: [String] = [], current = ""
        for line in transcript.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            var line = line
            while line.count > limit {
                if !current.isEmpty { parts.append(current); current = "" }
                parts.append(String(line.prefix(limit)))
                line = String(line.dropFirst(limit))
            }
            if !current.isEmpty, current.count + 1 + line.count > limit {
                parts.append(current)
                current = ""
            }
            current += current.isEmpty ? line : "\n" + line
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    /// Per request: dictation cleanup's default 7 s is far too short for notes; about 1 s per 100 characters.
    static func timeout(forCharacters count: Int) -> TimeInterval {
        min(300, 30 + TimeInterval(count) / 100)
    }

    // MARK: - Export

    /// A meeting's notes, as the History tab and the Markdown heading call them ("纪要"). Its own key: the plain
    /// "Notes" key is the Notes app (备忘录).
    static var notesTitle: String { String(localized: "meeting.notesTitle", defaultValue: "Notes") }

    static func markdown(title: String, date: Date, duration: TimeInterval, notes: String?, transcript: String) -> String {
        let when = date.formatted(date: .abbreviated, time: .shortened)
        var sections = ["# \(title)", "\(when) · \(timestamp(duration))"]
        if let notes, !notes.isEmpty {
            sections.append("## \(notesTitle)\n\n\(notes)")
        }
        let lines = transcript.split(separator: "\n").map { line -> String in
            // "[00:12] Me: text" → "**[00:12] Me**: text"
            guard let colon = line.range(of: ": "), line.hasPrefix("[") else { return String(line) }
            return "**\(line[..<colon.lowerBound])**: \(line[colon.upperBound...])"
        }
        sections.append("## \(String(localized: "Transcript"))\n\n" + lines.joined(separator: "\n\n"))
        return sections.joined(separator: "\n\n") + "\n"
    }
}

#if DEBUG
    extension MeetingNotes {
        static func selfCheck() {
            assert(timestamp(0) == "00:00" && timestamp(75.9) == "01:15" && timestamp(3_661) == "1:01:01")
            let segments = [
                MeetingSegment(speaker: .others, start: 12, end: 20, text: "Can we ship Friday?"),
                MeetingSegment(speaker: .me, start: 3, end: 11, text: "先看一下 CI"),
                MeetingSegment(speaker: .me, start: 12, end: 18, text: "可以"),
            ]
            let text = transcript(segments)
            let me = MeetingSegment.Speaker.me.label, others = MeetingSegment.Speaker.others.label
            SpeakerLabels.selfCheck()
            assert(text == "[00:03] \(me): 先看一下 CI\n[00:12] \(me): 可以\n[00:12] \(others): Can we ship Friday?")

            // A failed piece keeps its line: time, speaker, the marker.
            let failed = MeetingSegment(speaker: .others, start: 61, end: 80, text: "", failed: true)
            assert(transcript(segments + [failed]).hasSuffix("\n[01:01] \(others): \(failedMarker)"))
            let decoded = try? JSONDecoder().decode([MeetingSegment].self, from: JSONEncoder().encode([failed, segments[0]]))
            assert(decoded?.map(\.isFailed) == [true, false])
            assert(hasLines(text) && hasLines("[1:01:01] x: y") && !hasLines(String(localized: "(Nothing was said in this meeting.)")))
            assert(!hasLines("") && !hasLines("Yap quit during this meeting [00:01] "))

            let named = [MeetingSegment(speaker: .others, start: 1, end: 5, text: "ok", remote: 2)]
            assert(transcript(named) == "[00:01] \(String(format: String(localized: "Others %lld"), 2)): ok")

            assert(parts(of: "a\nb\nc", limit: 3) == ["a\nb", "c"])
            assert(parts(of: String(repeating: "x", count: 7), limit: 3) == ["xxx", "xxx", "x"])
            assert(parts(of: "") == [] && parts(of: "short") == ["short"])
            assert(timeout(forCharacters: 0) == 30 && timeout(forCharacters: 12_000) == 150 && timeout(forCharacters: 99_999) == 300)

            let md = markdown(title: "Weekly", date: Date(timeIntervalSince1970: 0), duration: 65, notes: "- ok", transcript: text)
            assert(md.hasPrefix("# Weekly\n\n") && md.contains("· 01:05") && md.contains("- ok"))
            assert(md.contains("**[00:03] \(me)**: 先看一下 CI"))
            assert(md.contains("## \(notesTitle)\n\n- ok"))
            assert(!markdown(title: "T", date: Date(), duration: 1, notes: nil, transcript: "").contains("## \(notesTitle)"))

            // The default shortcut: right ⌘ + Space fires, left ⌘ + Space (Spotlight) doesn't.
            let command = NSEvent.ModifierFlags.command.rawValue
            let shortcut = Shortcut.rightCommandSpace
            assert(shortcut.matchesKeyEvent(keyCode: 49, modifierFlags: NSEvent.ModifierFlags(rawValue: command | 0x10)))
            assert(!shortcut.matchesKeyEvent(keyCode: 49, modifierFlags: NSEvent.ModifierFlags(rawValue: command | 0x08)))
            assert(shortcut.displayTokens.first == "Right ⌘" && !Shortcut.key(keyCode: 0, modifierFlags: [.command]).isCommandSpace)

            // Deleting a meeting's recording takes its whole folder; a dictation's, just the file.
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("yap-selfcheck-\(UUID().uuidString)")
            let meeting = root.appendingPathComponent("meetings/m1", isDirectory: true)
            try? FileManager.default.createDirectory(at: meeting, withIntermediateDirectories: true)
            for name in ["mix.wav", "mic.wav"] { FileManager.default.createFile(atPath: meeting.appendingPathComponent(name).path, contents: Data()) }
            let dictation = root.appendingPathComponent("d.wav")
            FileManager.default.createFile(atPath: dictation.path, contents: Data())
            assert(Transcription.isMeetingAudio(meeting.appendingPathComponent("mix.wav")) && !Transcription.isMeetingAudio(dictation))
            try? Transcription.removeAudio(at: meeting.appendingPathComponent("mix.wav"))
            try? Transcription.removeAudio(at: dictation)
            assert(!FileManager.default.fileExists(atPath: meeting.path) && !FileManager.default.fileExists(atPath: dictation.path))
            assert(FileManager.default.fileExists(atPath: root.appendingPathComponent("meetings").path))
            try? FileManager.default.removeItem(at: root)
        }
    }
#endif
