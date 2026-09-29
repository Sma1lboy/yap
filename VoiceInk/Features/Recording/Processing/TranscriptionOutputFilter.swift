import Foundation

struct TranscriptionOutputFilter {
    private static let hallucinationPatterns = [
        #"\[.*?\]"#,  // []
        #"\(.*?\)"#,  // ()
        #"\{.*?\}"#,  // {}
    ]

    static func filter(_ text: String) -> String {
        var filteredText = text

        // Remove <TAG>...</TAG> blocks
        let tagBlockPattern = #"<([A-Za-z][A-Za-z0-9:_-]*)[^>]*>[\s\S]*?</\1>"#
        if let regex = try? NSRegularExpression(pattern: tagBlockPattern) {
            let range = NSRange(filteredText.startIndex..., in: filteredText)
            filteredText = regex.stringByReplacingMatches(in: filteredText, options: [], range: range, withTemplate: "")
        }

        // Remove bracketed hallucinations
        for pattern in hallucinationPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(filteredText.startIndex..., in: filteredText)
                filteredText = regex.stringByReplacingMatches(
                    in: filteredText, options: [], range: range, withTemplate: "")
            }
        }

        // Remove configured filler words. An empty list is naturally a no-op.
        for fillerWord in FillerWordManager.shared.fillerWords {
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: fillerWord))\\b[,.]?"
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(filteredText.startIndex..., in: filteredText)
                filteredText = regex.stringByReplacingMatches(
                    in: filteredText, options: [], range: range, withTemplate: "")
            }
        }

        // Clean whitespace
        filteredText = filteredText.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        filteredText = filteredText.trimmingCharacters(in: .whitespacesAndNewlines)

        return filteredText
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
        }
    #endif
}
