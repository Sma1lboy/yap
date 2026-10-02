#if DEBUG
    import Foundation
    import SwiftData

    /// `scripts/text-fidelity-check.sh`: `--text-fidelity-check`, then quits. Each case is text as if a model had just
    /// recognized it, run through `DictationText.clean` and `DictationText.finish` (the functions the dictation pipeline
    /// calls) with the case's Chinese cleanup options, English filler words, paragraph setting and replacement rules.
    /// Prints one `text-check: {json}` line per case with every step's output and whether the cleaned text counts as a
    /// whole-transcript hallucination. No model, recording, clipboard or text field is involved; replacement rules live
    /// in an in-memory store. scripts/text-fidelity-check.py holds what each case should give.
    @MainActor
    enum TextFidelityCheck {
        static let argument = "--text-fidelity-check"

        struct Case {
            let name: String
            let input: String
            var chinese = ChineseCleanup.Options()
            var paragraphs = false
            /// nil: the default list.
            var fillerWords: [String]? = nil
            /// original(s) → replacement, as typed in the Dictionary.
            var rules: [(String, String)] = []
        }

        static let cases: [Case] = [
            // Paths, dotfiles, flags.
            Case(name: "path-dot", input: "./scripts/build.sh"),
            Case(name: "path-dotdot", input: "../src/main.swift"),
            Case(name: "paths-in-chinese", input: "运行 ./scripts/build.sh 然后看 ../src/main.swift"),
            Case(name: "path-after-spoken-line-break", input: "先运行换行./configure --prefix=/usr/local"),
            Case(name: "path-on-second-line", input: "Steps:\n../build/run.sh"),
            Case(name: "dotfile", input: ".env"),
            Case(name: "dotfile-dir", input: ".github/workflows/ci.yml"),
            Case(name: "dotfile-in-chinese", input: "打开 .gitignore 文件"),
            Case(name: "vim-command", input: ":wq"),
            Case(name: "flag", input: "--flag"),
            Case(name: "git-flags", input: "git commit --amend --no-edit"),
            Case(name: "short-flag", input: "-v"),
            // Calls, indexes, JSON, tags, code.
            Case(name: "call", input: "foo.bar(userId)"),
            Case(name: "call-in-chinese", input: "调用 foo.bar(userId) 拿到结果"),
            Case(name: "call-two-args", input: "f(x, y)"),
            Case(name: "call-string-arg", input: "console.log(\"hi\")"),
            Case(name: "index", input: "items[0]"),
            Case(name: "index-names", input: "args[i] = map[key]"),
            Case(name: "json", input: "{\"name\": \"yap\", \"tags\": [1, 2]}"),
            Case(name: "inline-tag", input: "用 <b>粗体</b> 表示"),
            Case(name: "generic", input: "Map<String, Int>"),
            Case(name: "code-if", input: "if (a > b) { return a }"),
            Case(name: "date-format", input: "date format yyyy-mm-dd"),
            // Ordinary speech.
            Case(name: "mixed-prose", input: "我用 React 写了 3 个组件, 然后 deploy 到 Vercel."),
            Case(name: "aside-chinese", input: "我明天(周三)有空"),
            Case(name: "aside-english", input: "The meeting (with Bob) is at 3pm."),
            Case(name: "aside-laugh-inline", input: "我觉得(笑)可以"),
            // Spacing and lines.
            Case(name: "repeated-spaces", input: "a  b   c"),
            Case(name: "line-break", input: "第一行\n第二行"),
            Case(name: "paragraph-break", input: "第一段。\n\n第二段。"),
            Case(name: "many-line-breaks", input: "a\n\n\n\nb"),
            // Noise and hallucinations, which stay handled.
            Case(name: "noise-music", input: "[Music]"),
            Case(name: "noise-blank-audio", input: "[BLANK_AUDIO]"),
            Case(name: "noise-paren-alone", input: "(upbeat music)"),
            Case(name: "noise-inline-square", input: "Hello [inaudible] world"),
            Case(name: "noise-leading-square", input: "[Music] Hello there"),
            Case(name: "noise-own-line", input: "Okay.\n(laughs)\nSo anyway"),
            Case(name: "noise-tag-alone", input: "<noise>static</noise>"),
            Case(name: "hallucination-outro", input: "Thank you for watching."),
            Case(name: "hallucination-in-sentence", input: "Thank you for watching the kids while I was out."),
            Case(name: "orphan-punctuation", input: "。。好的"),
            Case(name: "only-dots", input: "..."),
            Case(name: "english-filler", input: "um, so the plan is fine"),
            Case(name: "english-filler-off", input: "um, so the plan is fine", fillerWords: []),
            // The user's Chinese cleanup choices.
            Case(name: "chinese-fillers", input: "嗯，我觉得这个方案，呃，还行"),
            Case(name: "chinese-fillers-off", input: "嗯，我觉得这个方案，呃，还行", chinese: .init(removeFillers: false)),
            Case(name: "spoken-line-break", input: "标题换行正文"),
            Case(name: "spoken-line-break-off", input: "标题换行正文", chinese: .init(spokenLineBreaks: false)),
            Case(name: "traditional", input: "我們明天開會"),
            Case(name: "traditional-kept", input: "我們明天開會", chinese: .init(traditionalToSimplified: false)),
            Case(name: "spacing-on", input: "调用foo.bar(userId)拿到3个结果", chinese: .init(spaceBetweenChineseAndLatin: true)),
            Case(name: "spacing-off", input: "调用foo.bar(userId)拿到3个结果"),
            // Paragraphs (a mode setting).
            Case(name: "paragraphs-keep-spoken-line-break", input: "第一点是速度换行第二点是成本", paragraphs: true),
            Case(name: "paragraphs-keep-line-break", input: "Line one.\nLine two.", paragraphs: true),
            Case(
                name: "paragraphs-long", input: longEnglish, paragraphs: true),
            Case(name: "paragraphs-code", input: "Run ./scripts/build.sh first. Then call foo.bar(userId) again.", paragraphs: true),
            // The user's replacement rules.
            Case(name: "replace-word", input: "deploy to k8s now, not k8sctl", rules: [("k8s, kates", "Kubernetes")]),
            Case(name: "replace-longest-first", input: "yap cloud and yap", rules: [("yap", "Yap"), ("yap cloud", "Yap Cloud")]),
            Case(name: "replace-inside-path", input: "open ./api/index.ts", rules: [("api", "API")]),
            Case(name: "replace-line-break", input: "hello new paragraph world", rules: [("new paragraph", "\\n\\n")]),
            Case(name: "replace-chinese", input: "我们先看下日志", rules: [("先看下", "先看一下")]),
            Case(name: "replace-to-dotfile", input: "打开 dot env", rules: [("dot env", ".env")]),
            Case(name: "replace-after-paragraphs", input: "Use k8s here.", paragraphs: true, rules: [("k8s", "Kubernetes")]),
        ]

        static let longEnglish = """
            We tried the new build on three machines this morning and it started fine on all of them. The settings page \
            loaded quickly and the shortcuts worked the way we expected them to. One tester noticed that the menu bar icon \
            was hard to see in dark mode. Another one asked whether the history could be exported to a folder. We should \
            look at both before the next release. The rest of the feedback was about wording in the onboarding screens and \
            can wait until the week after.
            """

        static func runIfRequested() {
            guard CommandLine.arguments.contains(argument) else { return }
            let fillers = FillerWordManager.shared
            let defaultFillers = fillers.fillerWords
            for testCase in cases {
                fillers.fillerWords = testCase.fillerWords ?? defaultFillers
                let container = try! ModelContainer(
                    for: WordReplacement.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
                let context = ModelContext(container)
                for (original, replacement) in testCase.rules {
                    context.insert(WordReplacement(originalText: original, replacementText: replacement))
                }
                try! context.save()

                var line: [String: Any] = ["case": testCase.name, "input": testCase.input]
                let record: (DictationText.Step, String) -> Void = { line[$0.rawValue] = $1 }
                let cleaned = DictationText.clean(testCase.input, chinese: testCase.chinese, step: record)
                line["hallucination"] = TranscriptionOutputFilter.isKnownHallucination(cleaned)
                line["output"] = DictationText.finish(
                    cleaned, paragraphs: testCase.paragraphs, replacementsIn: context, step: record)
                let json = try! JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])
                print("text-check: \(String(decoding: json, as: UTF8.self))")
            }
            fillers.fillerWords = defaultFillers
            TranscriptionOutputFilter.selfCheck()
            ChineseCleanup.selfCheck()
            ParagraphFormatter.selfCheck()
            ReplacementText.selfCheck()
            print("text-check-selfchecks: TranscriptionOutputFilter ChineseCleanup ParagraphFormatter ReplacementText ok")
            fflush(stdout)
            exit(0)
        }
    }
#endif
