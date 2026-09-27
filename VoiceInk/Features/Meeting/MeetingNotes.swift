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
    let text: String
}

/// Turns a meeting's segments into the saved transcript, the notes request and the Markdown export.
enum MeetingNotes {
    static func timestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    /// `[00:12] Me: …` lines in time order (both channels interleaved).
    static func transcript(_ segments: [MeetingSegment]) -> String {
        segments.sorted { ($0.start, $0.speaker.rawValue) < ($1.start, $1.speaker.rawValue) }
            .map { "[\(timestamp($0.start))] \($0.speaker.label): \($0.text)" }
            .joined(separator: "\n")
    }

    // MARK: - Notes

    static let promptTitle = "Meeting Notes"

    static let prompt = """
        You write meeting notes from a transcript. Lines start with [mm:ss] and a speaker: "Me" (or 我) is the \
        person who recorded the meeting, "Others" (or 对方) is everyone else on the call. The transcript comes from \
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
        person recording, "Others"/对方 everyone else). Write compact notes for this part only: key points, \
        decisions, action items with owners and due dates, open questions, with [mm:ss] where it helps. Keep the \
        language of the transcript and keep English terms as spoken. Output only the notes.
        """

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

    static func markdown(title: String, date: Date, duration: TimeInterval, notes: String?, transcript: String) -> String {
        let when = date.formatted(date: .abbreviated, time: .shortened)
        var sections = ["# \(title)", "\(when) · \(timestamp(duration))"]
        if let notes, !notes.isEmpty {
            sections.append("## \(String(localized: "Notes"))\n\n\(notes)")
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
            assert(text == "[00:03] \(me): 先看一下 CI\n[00:12] \(me): 可以\n[00:12] \(others): Can we ship Friday?")

            assert(parts(of: "a\nb\nc", limit: 3) == ["a\nb", "c"])
            assert(parts(of: String(repeating: "x", count: 7), limit: 3) == ["xxx", "xxx", "x"])
            assert(parts(of: "") == [] && parts(of: "short") == ["short"])
            assert(timeout(forCharacters: 0) == 30 && timeout(forCharacters: 12_000) == 150 && timeout(forCharacters: 99_999) == 300)

            let md = markdown(title: "Weekly", date: Date(timeIntervalSince1970: 0), duration: 65, notes: "- ok", transcript: text)
            assert(md.hasPrefix("# Weekly\n\n") && md.contains("· 01:05") && md.contains("- ok"))
            assert(md.contains("**[00:03] \(me)**: 先看一下 CI"))
            assert(!markdown(title: "T", date: Date(), duration: 1, notes: nil, transcript: "").contains("## \(String(localized: "Notes"))"))

            // The default shortcut: right ⌘ + Space fires, left ⌘ + Space (Spotlight) doesn't.
            let command = NSEvent.ModifierFlags.command.rawValue
            let shortcut = Shortcut.rightCommandSpace
            assert(shortcut.matchesKeyEvent(keyCode: 49, modifierFlags: NSEvent.ModifierFlags(rawValue: command | 0x10)))
            assert(!shortcut.matchesKeyEvent(keyCode: 49, modifierFlags: NSEvent.ModifierFlags(rawValue: command | 0x08)))
            assert(shortcut.displayTokens.first == "Right ⌘" && !Shortcut.key(keyCode: 0, modifierFlags: [.command]).isCommandSpace)
        }
    }
#endif
