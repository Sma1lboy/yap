#if DEBUG
    import Foundation
    import OSLog
    import SwiftData

    /// Data folders for judging yap-mcp beyond `make mcp-check`'s small fixture (docs/mcp.md › Verify):
    ///
    /// `--mcp-fixture-month <data folder>`: a month of someone's Yap, dated back from today so "last Thursday" is the
    /// same meeting on any day: about 300 dictations in Chinese, English and both, into Slack, Mail, Cursor,
    /// Terminal and WeChat; six meetings (most with renamed speakers, notes with decisions and action items); 30
    /// dictionary words and 10 replacement rules. `scripts/mcp-agent-eval.sh` asks agents about it; the facts its
    /// questions check (who, which day, what was decided) are written here.
    ///
    /// `--mcp-fixture-large <data folder>`: two years of heavy use for timing (`scripts/mcp-perf.py`): 20,000
    /// dictations, most of them cleaned up and keeping the prompt Yap sent, as Yap stores them, and 200 hour-long
    /// meetings.
    ///
    /// Both use the app's own `createPersistentContainer`, leave default.store with its `-wal` as a running Yap does,
    /// and quit. `mcp-fixture: <what> <value>` lines go to stdout.
    @MainActor
    enum MCPEvalFixture {
        static let monthArgument = "--mcp-fixture-month"
        static let largeArgument = "--mcp-fixture-large"

        static func runIfRequested() {
            let arguments = CommandLine.arguments
            if let index = arguments.firstIndex(of: monthArgument), arguments.indices.contains(index + 1) {
                finish { try writeMonth(URL(fileURLWithPath: arguments[index + 1], isDirectory: true)) }
            }
            if let index = arguments.firstIndex(of: largeArgument), arguments.indices.contains(index + 1) {
                finish { try writeLarge(URL(fileURLWithPath: arguments[index + 1], isDirectory: true)) }
            }
        }

        private static func finish(_ write: () throws -> ModelContainer) -> Never {
            let container: ModelContainer
            do {
                container = try write()
            } catch {
                print("mcp-fixture: failed \(error)")
                fflush(stdout)
                exit(1)
            }
            fflush(stdout)
            // Kept open until exit, as a running Yap keeps it: closing the store would fold the -wal into it.
            withExtendedLifetime(container) { exit(0) }
        }

        // MARK: - Dates

        private static let calendar: Calendar = {
            var calendar = Calendar(identifier: .gregorian)
            calendar.firstWeekday = 2
            return calendar
        }()

        private static let today = calendar.startOfDay(for: Date())

        /// `days` before today, at `hour`:`minute` local time.
        private static func day(_ days: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            let date = calendar.date(byAdding: .day, value: -days, to: today)!
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: date)!
        }

        /// Days back to last week's Thursday ("上周四"), weeks starting on Monday.
        private static var lastThursday: Int {
            let monday = calendar.dateInterval(of: .weekOfYear, for: today)!.start
            return calendar.dateComponents([.day], from: monday, to: today).day! + 4
        }

        private static func localISO(_ date: Date) -> String {
            let formatter = ISO8601DateFormatter()
            formatter.timeZone = .current
            return formatter.string(from: date)
        }

        // MARK: - Month

        private struct Line {
            let speaker: String
            let text: String
        }

        private static func me(_ text: String) -> Line { Line(speaker: "me", text: text) }
        private static func o(_ remote: Int, _ text: String) -> Line { Line(speaker: "others-\(remote)", text: text) }

        private static func writeMonth(_ data: URL) throws -> ModelContainer {
            let container = try container(in: data)
            let context = ModelContext(container)
            let thursday = lastThursday
            // This week's Monday; when that's today, last Friday instead (a meeting must be in the past).
            let monday = thursday - 4 >= 1 ? thursday - 4 : thursday - 1
            print("mcp-fixture: today \(localISO(today).prefix(10))")

            try meeting(
                "planning", at: day(26, 14), in: data, context: context,
                names: ["me": "Tingting", "others-1": "Reed", "others-2": "Shelley"],
                lines: [
                    me("OK, let's start. This is Q4 planning, I want us out of here with three goals."),
                    o(1, "First one is obvious: the billing migration has to be done before Black Friday."),
                    o(2, "Second, onboarding. Activation dropped to 41% last month, the setup tour is too long."),
                    me("Third is infra. Postgres 16 upgrade and the Kubernetes 1.31 upgrade."),
                    o(1, "Postgres can wait until November, after billing is stable. I don't want two migrations at once."),
                    me("Agreed. Postgres 16 in November, after billing."),
                    o(2, "I'll write the Q4 roadmap doc by next Friday and share it in #product."),
                    me("Great. Reed, you own billing, Shelley onboarding, I'll take infra."),
                ],
                notes: """
                    ## Summary
                    Q4 planning: three goals — billing migration before Black Friday, onboarding activation, infra upgrades.

                    ## Decisions
                    - Postgres 16 upgrade moves to November, after the billing migration is stable.
                    - Owners: Reed billing, Shelley onboarding, Tingting infra.

                    ## Action items
                    - [ ] Write the Q4 roadmap doc and share it in #product — Shelley — next Friday
                    """)

            try meeting(
                "rollout-1", at: day(16, 11), in: data, context: context,
                names: ["me": "Tingting", "others-1": "Reed", "others-2": "Marco"],
                lines: [
                    me("Rollout review. Marco, where are we on Kubernetes 1.31?"),
                    o(2, "Staging cluster is ready. 我建议先在 staging 跑一周，再动 prod。"),
                    o(1, "For checkout I want a canary, not a big bang."),
                    me("OK: staging first, and checkout starts as a 10% canary."),
                    o(2, "I'll set up the canary dashboards in Grafana this week."),
                ],
                notes: """
                    ## Summary
                    Rollout review for the Kubernetes 1.31 upgrade.

                    ## Decisions
                    - Kubernetes 1.31 goes to staging first, for a week, before prod.
                    - Checkout rolls out as a 10% canary.

                    ## Action items
                    - [ ] Canary dashboards in Grafana — Marco — this week
                    """)

            try meeting(
                "design", at: day(thursday + 2, 15), in: data, context: context,
                names: ["others-1": "Shelley", "others-2": "陈静"],
                lines: [
                    o(1, "So the data is clear: people drop off in the three-step setup tour."),
                    o(1, "I want to drop the three-step tour and keep only the microphone permission screen."),
                    me("What about the shortcut step? People need to know the shortcut."),
                    o(1, "We show the shortcut on Home instead. And I'd like this in 1.12, not later."),
                    o(2, "新的权限页插画我下周三给，配色按 design token 来。"),
                    me("好，那就 1.12，只保留麦克风权限那一页。"),
                ],
                notes: """
                    ## 摘要
                    新手引导设计评审：设置向导流失严重，决定精简。

                    ## 决定
                    - 去掉三步设置向导，只保留麦克风权限页；快捷键改在首页展示。
                    - 在 1.12 上线。

                    ## 待办
                    - [ ] 新的权限页插画 — 陈静 — 下周三
                    """)

            try meeting(
                "billing", at: day(thursday, 14), in: data, context: context,
                names: ["me": "Tingting", "others-1": "Reed", "others-2": "Shelley", "others-3": "Marco"],
                lines: [
                    me("今天主要过一下 billing migration 的情况。Reed 你先说。"),
                    o(1, "上周有 37 个客户的扣款失败了，原因是 Stripe webhook 超时之后我们没有重试。"),
                    o(3, "我建议 rollout 先停，等 webhook retry 上线了再继续。"),
                    me("同意，billing migration 的 rollout 先暂停，webhook 重试上线后再恢复。"),
                    o(1, "Webhook retry 我来做，10 月 2 号之前上线。"),
                    o(2, "我写一封给受影响客户的邮件，周一前给大家看草稿。"),
                    o(3, "我加一个 failed charge 的告警，超过 5 次就 page oncall。"),
                    o(2, "要不要给这些客户退款？"),
                    me("这个下次再定，先把邮件发了。"),
                ],
                notes: """
                    ## 摘要
                    Billing migration 同步：37 个客户扣款失败，原因是 Stripe webhook 超时后没有重试。

                    ## 决定
                    - Billing migration 的 rollout 暂停，等 webhook 重试上线后再恢复。

                    ## 待办
                    - [ ] Stripe webhook 重试 — Reed — 10 月 2 日前上线
                    - [ ] 给受影响客户的邮件草稿 — Shelley — 周一前
                    - [ ] Failed charge 告警（超过 5 次 page oncall）— Marco

                    ## 未决问题
                    - 是否给受影响的客户退款。
                    """)

            try meeting(
                "rollout-2", at: day(monday, 10), in: data, context: context,
                names: ["others-1": "Reed", "others-2": "Marco"],
                lines: [
                    me("Second rollout review. Staging soak for Kubernetes 1.31 is done?"),
                    o(2, "Yes, a full week on staging, no regressions."),
                    o(1, "Checkout canary has been at 10% for five days. Error rate is 0.3%."),
                    o(2, "I propose we go to 50% on October 6, and roll back if the error rate is above 1% for 10 minutes."),
                    me("Decided: 50% on October 6, rollback if errors stay above 1% for 10 minutes."),
                ],
                notes: """
                    ## Summary
                    Second rollout review: the Kubernetes 1.31 staging soak passed; the checkout canary is healthy at 10%.

                    ## Decisions
                    - Checkout canary goes to 50% on October 6.
                    - Roll back if the error rate stays above 1% for 10 minutes (Marco's proposal).

                    ## Action items
                    - [ ] Move the canary to 50% — Marco — October 6
                    """)

            try meeting(
                "one-on-one", at: day(1, 16), in: data, context: context, names: [:],
                lines: [
                    me("最近怎么样？oncall 压力大吗？"),
                    o(1, "还行，就是上周 billing 那次半夜被叫起来两次。"),
                    me("rollout 那边你不用管了，Marco 在盯。你专心把 webhook retry 做完。"),
                    o(1, "好。另外我想明年试试带一个小组。"),
                    me("可以，我们下个月的 1:1 具体聊一下。"),
                ],
                notes: """
                    ## 摘要
                    和 Reed 的 1:1：oncall 压力、职业发展。

                    ## 待办
                    - [ ] 下个月 1:1 聊带小组的计划 — 我
                    """)

            // The facts the questions ask about, and the older message the newer one replaces.
            let facts = [
                Dictated("Slack", "Kubernetes 升级先往后推，等 billing migration 稳定了再说", mode: "Chat", at: day(20, 17, 12)),
                Dictated(
                    "Slack", "Kubernetes 升级定在 10 月 8 号周四晚上十点，先 staging 再 prod，@Marco 帮忙盯一下 dashboard",
                    mode: "Chat", at: day(8, 11, 40)),
                Dictated("Terminal", "kubectl rollout status deployment/checkout -n prod", at: day(6, 22, 5)),
                Dictated(
                    "Mail", """
                    Hi Jenny, attached is invoice INV-2026-0917 for September, total ¥12,800, due October 15. \
                    Let me know if finance needs a PO number. Best regards, Tingting
                    """, mode: "Email", at: day(thursday - 1, 9, 20)),
                Dictated(
                    "Cursor", "// rate limiter: 每个 token 每分钟最多 600 次请求，超过返回 429，并在 Retry-After 里写要等几秒",
                    mode: "Code", at: day(3, 15, 33)),
                Dictated("微信", "妈，我周六下午三点左右到，坐高铁 G1234，不用来接", at: day(2, 21, 8)),
                Dictated("Slack", "Postgres 16 的升级 window 我们放在 11 月，billing 稳定之后", mode: "Chat", at: day(25, 10, 2)),
            ]
            for fact in facts { context.insert(fact.transcription(systemMessage: nil)) }

            var random = SplitMix(seed: 7)
            for index in 0..<293 {
                let when = day(random.next(30), 8 + random.next(13), random.next(60))
                guard when < Date() else { continue }
                context.insert(Filler.all[index % Filler.all.count].filled(&random, at: when).transcription(systemMessage: nil))
            }

            for (word, auto) in Lexicon.words { context.insert(vocabulary(word, auto: auto)) }
            for (originals, replacement, auto) in Lexicon.rules {
                let rule = WordReplacement(originalText: originals, replacementText: replacement)
                rule.isAutoLearned = auto
                context.insert(rule)
            }
            try context.save()
            print("mcp-fixture: entries \(try context.fetchCount(FetchDescriptor<Transcription>()))")
            return container
        }

        // MARK: - Large

        private static func writeLarge(_ data: URL) throws -> ModelContainer {
            let container = try container(in: data)
            let context = ModelContext(container)
            var random = SplitMix(seed: 2026)
            let prompts = PromptTemplates.seedPrompts
            let dictionaryContext = "\n<DICTIONARY_CONTEXT>\n" + Lexicon.words.map(\.0).joined(separator: ", ")
                + "\n</DICTIONARY_CONTEXT>"
            let started = Date()

            for index in 0..<20_000 {
                // Two years, newest first, never two at the same moment.
                let when = Date().addingTimeInterval(-Double(index) * 3_150 - Double(random.next(600)))
                var dictation = Filler.all[random.next(Filler.all.count)].filled(&random, at: when)
                // Real dictations run from a few words to a few paragraphs.
                for _ in 0..<random.next(4) {
                    dictation.text += " " + Filler.all[random.next(Filler.all.count)].filled(&random, at: when).text
                }
                let cleaned = random.next(10) < 7
                if cleaned, dictation.mode == nil { dictation.mode = ["Chat", "Email", "Default"][random.next(3)] }
                let prompt = prompts.first { $0.title == dictation.mode } ?? prompts[0]
                context.insert(
                    dictation.transcription(systemMessage: cleaned ? prompt.text + dictionaryContext : nil, cleaned: cleaned))
                if index % 500 == 499 { try context.save() }
            }

            let pool = Filler.meetingLines
            for index in 0..<200 {
                var lines: [Line] = []
                for turn in 0..<(420 + random.next(160)) {
                    let text = pool[random.next(pool.count)]
                    lines.append(turn % 3 == 0 ? me(text) : o(1 + random.next(3), text))
                }
                let segments = timed(lines)
                let transcript = MeetingNotes.transcript(segments)
                let entry = Transcription(
                    text: transcript, duration: segments.last!.end,
                    enhancedText: "## Summary\n" + Array(repeating: pool[index % pool.count], count: 12).joined(separator: " ")
                        + "\n\n## Action items\n- [ ] Follow up — Me — Friday",
                    aiRequestSystemMessage: MeetingNotes.prompt, aiRequestUserMessage: transcript,
                    transcriptionStatus: .completed)
                entry.kind = Transcription.meetingKind
                entry.timestamp = Date().addingTimeInterval(-Double(index) * 3.6 * 86_400 - 3_600 * Double(1 + random.next(8)))
                context.insert(entry)
                if index % 50 == 49 { try context.save() }
            }
            for (word, auto) in Lexicon.words { context.insert(vocabulary(word, auto: auto)) }
            try context.save()
            print("mcp-fixture: entries \(try context.fetchCount(FetchDescriptor<Transcription>()))")
            print("mcp-fixture: seconds \(Int(Date().timeIntervalSince(started)))")
            return container
        }

        // MARK: - Pieces

        private static func container(in data: URL) throws -> ModelContainer {
            try VoiceInkApp.createPersistentContainer(
                schema: YapStores.schema, logger: Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MCPEvalFixture"),
                directory: data)
        }

        private static func vocabulary(_ word: String, auto: Bool) -> VocabularyWord {
            let entry = VocabularyWord(word: word)
            entry.isAutoLearned = auto
            return entry
        }

        /// Lines one after another, `gap` seconds apart, each as long as it takes to say.
        private static func timed(_ lines: [Line], gap: TimeInterval = 2) -> [MeetingSegment] {
            var clock: TimeInterval = 3
            return lines.map { line in
                let length = max(3, Double(line.text.count) / 6)
                defer { clock += length + gap }
                let remote = line.speaker.hasPrefix("others-") ? Int(line.speaker.dropFirst("others-".count)) : nil
                return MeetingSegment(
                    speaker: remote == nil ? .me : .others, start: clock, end: clock + length, text: line.text, remote: remote)
            }
        }

        /// A meeting saved the way MeetingRecorder saves one, its speakers then renamed the way History's Speaker
        /// Names… does it.
        private static func meeting(
            _ role: String, at timestamp: Date, in data: URL, context: ModelContext, names: MeetingSpeakerNames,
            lines: [Line], notes: String
        ) throws {
            // A few lines of what was said, standing for half an hour or so of meeting.
            let segments = timed(lines, gap: 200)
            let folder = data.appendingPathComponent("Recordings/meetings/\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONEncoder().encode(segments).write(to: folder.appendingPathComponent("segments.json"))
            let entry = Transcription(
                text: MeetingNotes.transcript(segments), duration: segments.last!.end + 20, enhancedText: notes,
                transcriptionStatus: .completed)
            entry.kind = Transcription.meetingKind
            entry.timestamp = timestamp
            entry.audioFileURL = folder.appendingPathComponent("mix.wav").absoluteString
            context.insert(entry)
            try context.save()
            if !names.isEmpty, let problem = MeetingEdits.rename(entry, names: names, in: context) {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: problem])
            }
            print("mcp-fixture: meeting \(role) \(entry.id.uuidString) \(localISO(timestamp))")
        }

        /// One dictation: the app it went into, what was said, and the mode that cleaned it up, if any.
        private struct Dictated {
            static let bundles = [
                "Slack": "com.tinyspeck.slackmacgap", "Mail": "com.apple.mail", "Cursor": "com.todesktop.230313mzl4w4u92",
                "Terminal": "com.apple.Terminal", "微信": "com.tencent.xinWeChat", "Notes": "com.apple.Notes",
            ]

            let app: String
            var text: String
            var mode: String?
            let at: Date

            init(_ app: String, _ text: String, mode: String? = nil, at: Date) {
                self.app = app
                self.text = text
                self.mode = mode
                self.at = at
            }

            /// With a mode (or `cleaned`), a cleaned-up text too: a capital at the start, punctuation at the end.
            func transcription(systemMessage: String?, cleaned: Bool = false) -> Transcription {
                var enhanced: String?
                if mode != nil || cleaned {
                    let ends = ".。！？!?;；".contains(text.last!) || app == "Terminal"
                    let chinese = text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
                    enhanced = text.prefix(1).uppercased() + text.dropFirst() + (ends ? "" : chinese ? "。" : ".")
                }
                let entry = Transcription(
                    text: text, duration: max(1.5, Double(text.count) / 5), enhancedText: enhanced,
                    transcriptionModelName: "ggml-large-v3-turbo",
                    aiEnhancementModelName: enhanced == nil ? nil : "gpt-4o-mini",
                    aiRequestSystemMessage: enhanced == nil ? nil : systemMessage,
                    aiRequestUserMessage: enhanced == nil || systemMessage == nil ? nil : "<TRANSCRIPT>\n\(text)\n</TRANSCRIPT>",
                    modeName: mode, transcriptionStatus: .completed)
                entry.timestamp = at
                entry.sourceAppName = app
                entry.sourceAppBundleID = Self.bundles[app]
                return entry
            }
        }

        /// Everyday dictations that make up the rest of the history. `{p}` becomes a colleague, `{n}` a number.
        private struct Filler {
            let app: String
            let text: String
            let mode: String?

            func filled(_ random: inout SplitMix, at date: Date) -> Dictated {
                let people = ["Reed", "Shelley", "Marco", "王磊", "陈静", "Priya"]
                let text = text.replacingOccurrences(of: "{p}", with: people[random.next(people.count)])
                    .replacingOccurrences(of: "{n}", with: String(2 + random.next(40)))
                return Dictated(app, text, mode: mode, at: date)
            }

            private static let raw: [(String, String, String?)] = [
                ("Slack", "好的我看一下，十分钟后回你", "Chat"),
                ("Slack", "PR 已经提了，麻烦 {p} review 一下", "Chat"),
                ("Slack", "今天的 standup 我晚到五分钟", nil),
                ("Slack", "staging 上的 build 又挂了，我看看是不是 flaky test", "Chat"),
                ("Slack", "can someone take a look at the failing CI on main", "Chat"),
                ("Slack", "thanks {p}, merged", nil),
                ("Slack", "我下午三点有个会，之后再 sync", nil),
                ("Slack", "the dashboard looks good now, error rate back under 0.2%", "Chat"),
                ("Slack", "{p} 你那边 design 稿有更新吗", "Chat"),
                ("Slack", "OOO tomorrow morning, dentist appointment", nil),
                ("Slack", "Kubernetes 的 node pool 今天自动扩了一次，看起来正常", "Chat"),
                ("Slack", "I'll pair with {p} on the flaky test this afternoon", "Chat"),
                ("Slack", "deploy 完成了，大家可以在 staging 上验一下", nil),
                ("Mail", "hi {p}, thanks for the update. I'll review it by end of day", "Email"),
                ("Mail", "hi team, quick reminder that the retro is moved to Friday at 4pm", "Email"),
                ("Mail", "您好，附件是本周的周报，请查收", "Email"),
                ("Mail", "hi {p}, could we push our call to next week? something came up", "Email"),
                ("Mail", "thanks for the intro, happy to chat next Tuesday", "Email"),
                ("Mail", "hi {p}, the contract looks fine to me, I've signed and sent it back", "Email"),
                ("Cursor", "// TODO: 这里的 cache key 要加上 locale", "Code"),
                ("Cursor", "refactor this function to return early when the list is empty", nil),
                ("Cursor", "write a test for the retry logic with three failures then a success", nil),
                ("Cursor", "把这个 enum 改成 String raw value，方便存到 SwiftData", nil),
                ("Cursor", "// 注意：这个 timeout 是秒不是毫秒", "Code"),
                ("Cursor", "add a doc comment explaining why we copy the store before reading it", nil),
                ("Cursor", "rename this variable to something that says what it holds", nil),
                ("Terminal", "git rebase -i origin/main", nil),
                ("Terminal", "kubectl get pods -n checkout", nil),
                ("Terminal", "make build && make mcp-check", nil),
                ("Terminal", "brew upgrade && brew cleanup", nil),
                ("Terminal", "tail -f /var/log/system.log | grep yap", nil),
                ("Terminal", "git log --oneline -{n}", nil),
                ("微信", "好的，晚上见", nil),
                ("微信", "周末一起吃饭吗？{p}也来", nil),
                ("微信", "收到，谢谢！", nil),
                ("微信", "我到楼下了", nil),
                ("微信", "今天加班，晚点回家", nil),
                ("微信", "这个周末天气不错，要不要去爬山", nil),
                ("微信", "生日快乐！礼物已经寄出了，大概 {n} 号到", nil),
                ("Notes", "买牛奶、鸡蛋、咖啡豆", nil),
                ("Notes", "下周要准备 Q4 的 OKR，先列一下 infra 的目标", nil),
                ("Notes", "idea: let people pin a dictation to the top of History", nil),
            ]
            static let all = raw.map { Filler(app: $0.0, text: $0.1, mode: $0.2) }

            static let meetingLines = [
                "Let's go through the open items from last week.",
                "我这边的进度基本按计划，下周可以联调。",
                "Can you share your screen? I want to see the dashboard.",
                "这个问题我们之前讨论过，结论是先不做。",
                "The error rate went up a little after the deploy, but it's back to normal now.",
                "我觉得这个需求的优先级可以往后放一放。",
                "Who owns the follow-up on this?",
                "我来跟进，周五前给大家一个结论。",
                "Let's take this offline and come back to it on Thursday.",
                "设计稿已经更新了，链接我发在群里。",
                "We should write this down in the doc so we don't forget.",
                "下一个议题是 oncall 的轮值安排。",
            ]
        }

        private enum Lexicon {
            static let words: [(String, Bool)] = [
                ("Tingting", false), ("Reed", false), ("Shelley", false), ("Marco", false), ("王磊", false),
                ("陈静", false), ("Priya", true), ("Kubernetes", false), ("kubectl", false), ("PostgreSQL", false),
                ("Stripe", false), ("webhook", true), ("canary", false), ("rollout", true), ("staging", true),
                ("Grafana", false), ("Datadog", false), ("SwiftData", false), ("SwiftUI", false), ("Xcode", false),
                ("Cursor", false), ("Yap", false), ("OpenRouter", false), ("Sentry", true), ("Figma", false),
                ("Linear", false), ("Notion", false), ("Redis", false), ("gRPC", false), ("飞书", true),
            ]
            static let rules: [(String, String, Bool)] = [
                ("postgres, post gress, postgre", "PostgreSQL", false),
                ("k8s, kates", "Kubernetes", false),
                ("cube cuddle, cube control", "kubectl", false),
                ("graph ana", "Grafana", true),
                ("先看下", "先看一下", true),
                ("web hook", "webhook", false),
                ("open router", "OpenRouter", false),
                ("庭庭", "Tingting", true),
                ("swift data", "SwiftData", false),
                ("my email sig", "Best regards, Tingting", false),
            ]
        }

        /// The same numbers on every run.
        private struct SplitMix {
            var state: UInt64
            init(seed: UInt64) { state = seed }
            mutating func next(_ bound: Int) -> Int {
                state &+= 0x9E37_79B9_7F4A_7C15
                var z = state
                z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
                z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
                return Int((z ^ (z >> 31)) % UInt64(bound))
            }
        }
    }
#endif
