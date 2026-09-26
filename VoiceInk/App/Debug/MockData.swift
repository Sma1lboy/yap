#if DEBUG
    import AppKit
    import SwiftData
    import SwiftUI

    /// Fake data shared by `make ui-snapshots` (UISnapshots) and `make mock` (MockEnvironment).
    @MainActor
    enum MockData {
        static let enhancementModel = "deepseek/deepseek-v4.1-flash"
        static let transcriptionModel = "microsoft/mai-transcribe-2"

        /// 20 transcripts, newest first, mixing English and Chinese the way Yap's users talk.
        static let history: [(original: String, enhanced: String?)] = [
            ("um so the standup 改到 Friday morning and uh send Chris the onboarding review",
             "Standup 改到 Friday morning. Send Chris the onboarding review."),
            ("remind me to renew the domain before the end of the month", nil),
            ("reply to Sam thanks for the notes I'll look at the pricing section tomorrow",
             "Thanks for the notes, Sam. I'll look at the pricing section tomorrow."),
            ("明天下午三点和设计组过一下 onboarding 的新流程", "明天下午三点和设计组过一下 onboarding 的新流程。"),
            ("add milk eggs and coffee beans to the shopping list", nil),
            ("那个 PR 我看了 整体没问题 就是 error handling 那块再补一下 test",
             "那个 PR 我看了，整体没问题，error handling 那块再补一下 test。"),
            ("let's push the release to Thursday so QA has two full days",
             "Let's push the release to Thursday so QA has two full days."),
            ("帮我写个邮件给 Lisa 说 invoice 已经发了 麻烦她确认一下",
             "Hi Lisa，invoice 已经发出，麻烦确认一下，谢谢。"),
            ("the API returns a 402 when the balance is zero we should show add funds",
             "The API returns a 402 when the balance is zero; we should show Add Funds."),
            ("周五之前把 landing page 的中文文案 review 完", "周五之前把 landing page 的中文文案 review 完。"),
            ("book a table for four at seven thirty on Saturday", nil),
            ("这个 bug 只在 external monitor 上出现 内置屏幕没问题",
             "这个 bug 只在 external monitor 上出现，内置屏幕没问题。"),
            ("can you summarize the last three customer calls in bullet points",
             "Can you summarize the last three customer calls in bullet points?"),
            ("下周一 one on one 的时候聊一下 Q4 的 roadmap", "下周一 one-on-one 的时候聊一下 Q4 的 roadmap。"),
            ("note to self the parakeet model is faster but whisper handles accents better",
             "Note to self: the Parakeet model is faster, but Whisper handles accents better."),
            ("把 staging 的 database 先 snapshot 一下 再跑 migration",
             "先把 staging 的 database snapshot 一下，再跑 migration。"),
            ("thanks everyone great demo today", "Thanks, everyone. Great demo today!"),
            ("设计稿里的 button 圆角和 app 里的不一致 需要统一",
             "设计稿里的 button 圆角和 app 里的不一致，需要统一。"),
            ("schedule a dentist appointment next Tuesday afternoon", nil),
            ("OK 那就这么定了 我今晚把 changelog 更新好", "OK，那就这么定了，我今晚把 changelog 更新好。"),
        ]

        static let vocabulary = ["Yap", "paygate", "OpenRouter", "Parakeet", "SwiftUI", "周报", "standup"]
        static let replacements = [("open router", "OpenRouter"), ("pay gate", "paygate"), ("why app", "Yap")]

        static let customProvider = CustomAIProviderConfig(
            name: "LM Studio", baseURL: "http://localhost:1234/v1", models: ["qwen3-8b", "gemma-3-12b"],
            selectedModel: "qwen3-8b")

        static var yapCloudTranscriptionKey: String {
            "YapCloud:\(YapCloudProvider.stableID(for: transcriptionModel).uuidString)"
        }

        static func insertHistory(into context: ModelContext, count: Int = history.count) {
            for (index, text) in history.prefix(count).enumerated() {
                let item = Transcription(
                    text: text.original, duration: Double(6 + (index * 7) % 40), enhancedText: text.enhanced)
                item.timestamp = Date().addingTimeInterval(Double(-index) * 3_600 * 3)
                context.insert(item)
            }
        }

        static func insertDictionary(into context: ModelContext) {
            vocabulary.forEach { context.insert(VocabularyWord(word: $0)) }
            replacements.forEach { context.insert(WordReplacement(originalText: $0.0, replacementText: $0.1)) }
        }

        /// Five starter modes on Yap Cloud (transcription and enhancement).
        static func installModes() {
            StarterModeFactory.install(
                kinds: StarterModeKind.allCases, provider: .yapCloud, modelName: enhancementModel,
                transcriptionModelName: yapCloudTranscriptionKey)
        }
    }

    /// A signed-in, in-memory Yap Cloud config store with a few earlier versions, so Config & Sync renders its
    /// enabled state and Version History has rows.
    final class MockConfigStore: ConfigCloudStore, ConfigVersionHistoryStore {
        struct Document: CloudConfigDocument {
            let version: String
            let config: Data
        }

        private let config = Data(#"{"dictionary":{"words":["Yap","paygate"]}}"#.utf8)

        var isSignedIn: Bool { true }
        func fetchConfig() async throws -> Document? { Document(version: "7", config: config) }
        func putConfig(_ data: Data, ifMatch: String?) async throws -> String { "8" }

        func listConfigVersions() async throws -> [CloudConfigVersionInfo] {
            [
                CloudConfigVersionInfo(
                    version: "6", updatedAt: Date().addingTimeInterval(-3_600 * 5), deviceName: "Jamie's MacBook Pro",
                    bytes: 2_140),
                CloudConfigVersionInfo(
                    version: "5", updatedAt: Date().addingTimeInterval(-86_400 * 2), deviceName: "Studio Mac mini",
                    bytes: 1_980),
                CloudConfigVersionInfo(
                    version: "4", updatedAt: Date().addingTimeInterval(-86_400 * 6), deviceName: nil, bytes: 1_502),
            ]
        }

        func fetchConfigVersion(_ version: String) async throws -> Data { config }
    }

    /// `make mock`: the Debug app, copied and re-identified as me.sma1lboy.yap.mock (AppIdentity.isMock), started
    /// under a sandbox profile that denies network access. Its defaults domain, support directory and keychain
    /// service start empty (the Makefile wipes them before and after), and are seeded here on every launch.
    @MainActor
    enum MockEnvironment {
        /// Before any manager reads settings, after the onboarding migration (it clears modes on fresh installs).
        static func seedSettings() {
            guard AppIdentity.isMock else { return }
            YapCloud.isSnapshotMode = true
            YapCloud.shared.applySnapshotState(.funded)
            UserDefaults.standard.set(true, forKey: OnboardingSettings.completedV2Key)
            MockData.installModes()
            // No API key: the re-signed copy can't write the keychain, and the provider only needs to be listed.
            CustomAIProviderManager.shared.replaceProviders([MockData.customProvider])
        }

        /// After the stores exist: history and dictionary, once per launch (the stores start empty).
        static func seedStores(_ container: ModelContainer) {
            guard AppIdentity.isMock else { return }
            let context = container.mainContext
            guard (try? context.fetchCount(FetchDescriptor<Transcription>())) == 0 else { return }
            MockData.insertHistory(into: context)
            MockData.insertDictionary(into: context)
            try? context.save()
        }

        static func attachCloudStore() {
            guard AppIdentity.isMock else { return }
            CloudConfigSync.shared.store = MockConfigStore()
        }
    }
#endif
