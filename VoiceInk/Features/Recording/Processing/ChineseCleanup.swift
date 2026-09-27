import Foundation

/// Deterministic cleanup of Chinese transcripts, run after transcription and before AI enhancement, so a fully
/// offline setup (no enhancement) still gets readable text. No model involved; everything is a rule.
///
/// - Fillers: 嗯、呃、额 anywhere as standalone words; 啊, 哦 and 那个 only where they start a clause or stand between
///   commas, since mid-sentence they're a particle or a demonstrative ("那个文件"). Punctuation left orphaned by a
///   removal goes with it.
/// - Spoken layout: 换行 / 新的一行 / 下一行 → line break; 新段落 / 另起一段 / 新的一段 → blank line. "换行符" stays.
/// - Traditional → Simplified (Whisper sometimes answers Mandarin in Traditional characters).
/// - Optionally a space between Chinese and Latin letters or digits.
enum ChineseCleanup {
    struct Options: Equatable {
        var removeFillers = true
        var spokenLineBreaks = true
        var traditionalToSimplified = true
        var spaceBetweenChineseAndLatin = false
    }

    enum Keys {
        static let removeFillers = "ChineseCleanupRemoveFillers"
        static let spokenLineBreaks = "ChineseCleanupSpokenLineBreaks"
        static let traditionalToSimplified = "ChineseCleanupTraditionalToSimplified"
        static let spaceBetweenChineseAndLatin = "ChineseCleanupSpaceBetweenChineseAndLatin"
    }

    /// Registered defaults. Traditional → Simplified is off for users whose first Chinese preference is
    /// Traditional (Taiwan, Hong Kong), who would otherwise have their own writing converted.
    static func defaults(preferredLanguages: [String] = Locale.preferredLanguages) -> [String: Any] {
        let firstChinese = preferredLanguages.first { $0.hasPrefix("zh") }
        let prefersTraditional = firstChinese.map { $0.contains("Hant") || $0.hasSuffix("-TW") || $0.hasSuffix("-HK") } ?? false
        return [
            Keys.removeFillers: true,
            Keys.spokenLineBreaks: true,
            Keys.traditionalToSimplified: !prefersTraditional,
            Keys.spaceBetweenChineseAndLatin: false,
        ]
    }

    static var currentOptions: Options {
        let defaults = UserDefaults.standard
        return Options(
            removeFillers: defaults.bool(forKey: Keys.removeFillers),
            spokenLineBreaks: defaults.bool(forKey: Keys.spokenLineBreaks),
            traditionalToSimplified: defaults.bool(forKey: Keys.traditionalToSimplified),
            spaceBetweenChineseAndLatin: defaults.bool(forKey: Keys.spaceBetweenChineseAndLatin))
    }

    private static let clausePunctuation = "，。！？、；：,.!?;:"
    private static let han = "\\p{scx=Han}"

    static func apply(_ text: String, options: Options) -> String {
        var s = text
        if options.traditionalToSimplified {
            s = s.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? s
        }
        if options.removeFillers {
            s = removingFillers(s)
        }
        if options.spokenLineBreaks {
            s = applyingSpokenLineBreaks(s)
        }
        if options.spaceBetweenChineseAndLatin {
            s = replace(s, "(\(han))([A-Za-z0-9])", "$1 $2")
            s = replace(s, "([A-Za-z0-9%])(\(han))", "$1 $2")
        }
        return tidy(s)
    }

    private static func replace(_ s: String, _ pattern: String, _ template: String) -> String {
        s.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
    }

    private static func removingFillers(_ text: String) -> String {
        let p = NSRegularExpression.escapedPattern(for: clausePunctuation)
        var s = text
        // Always fillers, wherever they are, with the pause mark (comma) that follows them.
        s = replace(s, "(?:嗯|呃|额)+(?![度外头])[，,、]?\\s*", "")
        // Only at a clause start or set off by commas: 啊, 哦, 那个 (repeats included).
        s = replace(s, "(^|[\(p)\\n]\\s*)(?:(?:那个|啊|哦)[，,、]?\\s*)+", "$1")
        return s
    }

    private static func applyingSpokenLineBreaks(_ text: String) -> String {
        let p = NSRegularExpression.escapedPattern(for: clausePunctuation)
        var s = text
        s = replace(s, "[\(p)\\s]*(?:新段落|另起一段|新的一段)[\(p)\\s]*", "\n\n")
        s = replace(s, "[\(p)\\s]*(?:换行(?!符)|新的一行|下一行)[\(p)\\s]*", "\n")
        return s
    }

    /// Orphaned punctuation and spacing left behind by the removals.
    private static func tidy(_ text: String) -> String {
        let p = NSRegularExpression.escapedPattern(for: clausePunctuation)
        var s = text
        s = replace(s, "^[\(p)\\s]+", "")  // text starting with a comma
        s = replace(s, "(?m)^[ \\t]*[\(p)]+[ \\t]*", "")  // a line starting with one
        s = replace(s, "[，,、]+([。！？!?；;])", "$1")  // "，。" → "。"
        s = replace(s, "([，,、])[，,、]+", "$1")  // "，，" → "，"
        s = replace(s, "[ \\t]*\\n[ \\t]*", "\n")
        s = replace(s, "\\n{3,}", "\n\n")
        s = replace(s, "[ \\t]{2,}", " ")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    #if DEBUG
        static func selfCheck() {
            let on = Options()
            func check(_ input: String, _ expected: String, _ options: Options = Options()) {
                let output = apply(input, options: options)
                assert(output == expected, "ChineseCleanup: \(input) → \(output), expected \(expected)")
            }
            // Fillers anywhere, including mid-sentence where ICU's \b doesn't split two Han characters.
            check("我觉得嗯这个可以", "我觉得这个可以")
            check("嗯，我觉得这个方案，呃，还行", "我觉得这个方案，还行")
            check("嗯嗯嗯。", "")
            check("额度用完了", "额度用完了")
            // 那个 / 啊 only at a clause start; demonstratives and final particles stay.
            check("那个我今天想把那个 pipeline 改一下", "我今天想把那个 pipeline 改一下")
            check("好的，那个，明天再说啊", "好的，明天再说啊")
            check("啊，这样啊", "这样啊")
            // Spoken layout.
            check("第一点是速度换行第二点是成本", "第一点是速度\n第二点是成本")
            check("第一段写完了。新段落。第二段开始", "第一段写完了\n\n第二段开始")
            check("这里要加一个换行符", "这里要加一个换行符")
            check("标题，新的一行，正文", "标题\n正文")
            // Traditional → Simplified.
            check("我們明天開會討論這個問題", "我们明天开会讨论这个问题")
            check("我們明天開會", "我們明天開會", Options(traditionalToSimplified: false))
            // Optional spacing.
            check("我用React写了3个组件", "我用React写了3个组件")
            check("我用React写了3个组件", "我用 React 写了 3 个组件", Options(spaceBetweenChineseAndLatin: true))
            // Latin text is left alone.
            check("uh this is fine, OK", "uh this is fine, OK")
            assert(apply("", options: on) == "")

            assert(defaults(preferredLanguages: ["zh-Hant-TW", "en"])[Keys.traditionalToSimplified] as? Bool == false)
            assert(defaults(preferredLanguages: ["en-US", "zh-Hans-CN"])[Keys.traditionalToSimplified] as? Bool == true)
            assert(defaults(preferredLanguages: ["en-US"])[Keys.traditionalToSimplified] as? Bool == true)
        }
    #endif
}
