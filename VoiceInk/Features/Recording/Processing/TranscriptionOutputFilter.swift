import Foundation

/// Takes out the marker a model is known to write in place of speech, and the user's English filler words. Every
/// other bracket stays as recognized: `foo.bar(userId)`, `items[0]`, `[options]`, `(Tuesday)`, JSON, `<div>…</div>`.
/// Whisper can also write annotations (OpenAI's tokenizer names `( SPEAKING FOREIGN LANGUAGE )` and a `[DAVID]`
/// speaker tag as examples), but they're open-ended words in the same brackets a user dictates, so their shape doesn't
/// tell them apart from what was said; they stay.
struct TranscriptionOutputFilter {
    /// `[BLANK_AUDIO]`, what whisper.cpp writes for a window without speech (its own example strips it,
    /// examples/python/whisper_processor.py), with the spaces before it, or its whole line when it stands alone there.
    private static let noSpeech = try! NSRegularExpression(
        pattern: #"(?m)^[^\S\n]*\[BLANK_AUDIO\][^\S\n]*(?:\n|$)|[^\S\n]*\[BLANK_AUDIO\]"#)

    static func filter(_ text: String) -> String {
        var filteredText = replacing(noSpeech, in: text)

        // Configured filler words, as words of their own: not inside yyyy-mm-dd or a path. An empty list is a no-op.
        for fillerWord in FillerWordManager.shared.fillerWords {
            let escaped = NSRegularExpression.escapedPattern(for: fillerWord)
            let pattern = #"(?<![\w\-/.])"# + escaped + #"(?![\w\-/]|\.\w)[,.]?"#
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                filteredText = replacing(regex, in: filteredText)
            }
        }

        // Spaces left behind collapse; line breaks stay, three or more become a blank line.
        filteredText = filteredText.replacingOccurrences(of: #"[^\S\n]{2,}"#, with: " ", options: .regularExpression)
        filteredText = filteredText.replacingOccurrences(of: #"[^\S\n]*\n[^\S\n]*"#, with: "\n", options: .regularExpression)
        filteredText = filteredText.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return filteredText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replacing(_ regex: NSRegularExpression, in text: String) -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }

    // MARK: - Whole-transcript hallucinations

    /// Phrases Whisper makes up on near-silence (subtitle credits and channel outros from its training data).
    /// Compared against the entire transcript in `normalized` form, so a real sentence that contains one is safe.
    private static let hallucinatedPhrases: Set<String> = Set(
        [
            "Thanks for watching", "Thanks for watching!", "Thank you for watching", "Thank you so much for watching",
            "Please subscribe", "Please subscribe to my channel", "Subscribe to my channel", "Like and subscribe",
            "Please like and subscribe", "Don't forget to subscribe",
            "Subtitles by the Amara.org community", "Transcribed by ESO, translated by —",
            "请不吝点赞 订阅 转发 打赏支持明镜与点点栏目", "請不吝點贊 訂閱 轉發 打賞支持明鏡與點點欄目",
            "感谢观看", "感謝觀看", "谢谢观看", "謝謝觀看", "谢谢大家观看", "謝謝大家觀看", "感谢收看",
            "请订阅我的频道", "請訂閱我的頻道", "字幕由Amara.org社区提供", "字幕由Amara.org社群提供",
        ].map(normalized))

    /// Lowercased with everything but letters and digits removed, so punctuation, spacing and case don't matter.
    private static func normalized(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// True when the whole transcript is a known Whisper hallucination. Prefix rules cover the credit lines
    /// whose middle varies ("字幕由某某提供").
    static func isKnownHallucination(_ text: String) -> Bool {
        let key = normalized(text)
        guard !key.isEmpty else { return false }
        return hallucinatedPhrases.contains(key)
            || (key.hasPrefix("字幕由") && key.hasSuffix("提供"))
            || key.hasPrefix("subtitlesby") || key.hasPrefix("subtitledby")
    }

    #if DEBUG
        static func selfCheck() {
            assert(isKnownHallucination("Thank you for watching."))
            assert(isKnownHallucination("  THANK YOU FOR WATCHING!! "))
            assert(isKnownHallucination("Subscribe to my channel"))
            assert(isKnownHallucination("请不吝点赞 订阅 转发 打赏支持明镜与点点栏目"))
            assert(isKnownHallucination("字幕由 Amara.org 社区提供"))
            assert(isKnownHallucination("字幕由某某某提供"))
            assert(isKnownHallucination("Subtitles by the Amara.org community"))
            // Only the entire transcript counts; a phrase inside real dictation stays.
            assert(!isKnownHallucination("Thank you for watching the kids while I was out."))
            assert(!isKnownHallucination("Please subscribe me to the newsletter"))
            assert(!isKnownHallucination("Thank you"))
            assert(!isKnownHallucination(""))
            assert(!isKnownHallucination("..."))

            // whisper.cpp's no-speech marker goes, with its line when alone; any other bracket stays, since its shape
            // doesn't say whether it was said. Inputs hold no filler word, so the user's list doesn't matter here.
            func check(_ input: String, _ expected: String) {
                let output = filter(input)
                assert(output == expected, "TranscriptionOutputFilter: \(input) → \(output), expected \(expected)")
            }
            check("[BLANK_AUDIO]", "")
            check("Hello [BLANK_AUDIO] world", "Hello world")
            check("Okay.\n[BLANK_AUDIO]\nSo anyway", "Okay.\nSo anyway")
            check("[options]", "[options]")
            check("Use [projectName] here", "Use [projectName] here")
            check("Dates:\n(Tuesday)\nor Friday", "Dates:\n(Tuesday)\nor Friday")
            check("<div>hello</div>", "<div>hello</div>")
            check("foo.bar(userId)", "foo.bar(userId)")
            check("args[i] = map[key]", "args[i] = map[key]")
            check("{\"name\": \"yap\", \"tags\": [1, 2]}", "{\"name\": \"yap\", \"tags\": [1, 2]}")
            check("用 <b>粗体</b> 表示", "用 <b>粗体</b> 表示")
            check("The meeting (with Bob) is at 3pm.", "The meeting (with Bob) is at 3pm.")
            check("第一段。\n\n\n第二段  结束", "第一段。\n\n第二段 结束")
        }
    #endif
}
