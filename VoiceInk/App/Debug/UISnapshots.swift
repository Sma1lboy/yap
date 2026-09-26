#if DEBUG
    import AppKit
    import SwiftData
    import SwiftUI

    /// `make ui-snapshots`: renders key screens to PNGs with fake data and exits, without showing a window,
    /// taking focus or touching the network. Views are hosted in a never-ordered-in offscreen window and drawn
    /// with `cacheDisplay`, because `ImageRenderer` can't draw AppKit-backed controls (Form rows, toggles,
    /// pickers, text fields).
    @MainActor
    enum UISnapshots {
        static let argument = "--render-snapshots"
        static let outputDirectory = URL(fileURLWithPath: "/tmp/yap-ui/snapshots", isDirectory: true)
        /// The main window's minimum size.
        static let size = CGSize(width: AppWindowLayout.minimumWidth, height: AppWindowLayout.minimumHeight)

        /// Call first thing at launch; returns only when the argument isn't present.
        static func runIfRequested() {
            guard CommandLine.arguments.contains(argument) else { return }
            NSApplication.shared.setActivationPolicy(.prohibited)
            YapCloud.isSnapshotMode = true
            try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            // Rendering builds real managers that write UserDefaults (fake starter modes, shortcut migrations…).
            // Keep the dev app's own settings: save the whole domain now, put it back exactly before exiting.
            let defaultsGuard = DefaultsSnapshot()
            // A second run with -AppleLanguages (zh-Hans) writes <name>-zh-<appearance>.png next to the English set.
            let suffix = Bundle.main.preferredLocalizations.first?.hasPrefix("zh") == true ? "-zh" : ""

            let empty = inMemoryContainer()
            let history = inMemoryContainer()
            for (index, text) in fakeHistory.enumerated() {
                let item = Transcription(text: text.original, duration: Double(8 + index * 5), enhancedText: text.enhanced)
                item.timestamp = Date().addingTimeInterval(Double(-index) * 3_600 * 5)
                history.mainContext.insert(item)
            }
            let practiced = inMemoryContainer()
            practiced.mainContext.insert(Transcription(text: "Standup moved to Friday.", duration: 3))

            let app = SnapshotApp(container: empty)
            CloudConfigSync.shared.store = SnapshotConfigStore()
            StarterModeFactory.install(kinds: StarterModeKind.allCases, provider: .yapCloud, modelName: nil)

            var written: [String] = []
            func shot<V: View>(_ name: String, size: CGSize = size, @ViewBuilder _ content: () -> V) {
                written += render(name + suffix, size: size) { app.environment(content()) }
            }

            for state in YapCloud.SnapshotState.allCases {
                YapCloud.shared.applySnapshotState(state)
                shot("account-\(state.rawValue)") { AccountView() }
            }

            YapCloud.shared.applySnapshotState(.funded)
            shot("config-sync") {
                Form { ConfigSyncSettingsSection() }
                    .formStyle(.grouped)
                    .scrollContentBackground(.hidden)
            }
            shot("settings") { SettingsView() }
            shot("models") { ModelManagementView() }
            shot("modes") { ModeView() }
            shot("history") { HistoryView { EmptyView() }.modelContainer(history) }
            shot("home-empty") { HistoryView { EmptyView() } }

            YapCloud.shared.applySnapshotState(.signedOut)
            shot("onboarding-permissions", size: onboardingSize) { onboardingPermissions }
            shot("onboarding-model-yapcloud", size: onboardingSize) { onboardingModel(.yapCloud) }
            shot("onboarding-model-openrouter", size: onboardingSize) { onboardingModel(.recommended) }
            shot("onboarding-dictation", size: onboardingSize) { onboardingDictation }
            shot("onboarding-restore", size: CGSize(width: 440, height: 200)) {
                OnboardingCloudRestoreSheet { _ in }
            }
            shot("onboarding-final", size: onboardingSize) {
                OnboardingTrustScreen(contentMaxWidth: 700, onBack: {}, onContinue: {})
            }
            shot("onboarding-final-after-practice", size: onboardingSize) {
                OnboardingTrustScreen(contentMaxWidth: 700, onBack: {}, onContinue: {})
                    .modelContainer(practiced)
            }
            if let notes = ReleaseNotes.current {
                shot("whats-new", size: CGSize(width: 560, height: 620)) { ReleaseNotesSheet(notes: notes) }
            }

            defaultsGuard.restore()
            print("Wrote \(written.count) snapshots to \(outputDirectory.path)")
            exit(0)
        }

        /// Onboarding's window is a fixed 950pt wide (AppWindowLayout.defaultWidth), 750pt at its shortest.
        private static let onboardingSize = CGSize(width: AppWindowLayout.defaultWidth, height: AppWindowLayout.minimumHeight)

        private static let fakeHistory: [(original: String, enhanced: String?)] = [
            ("um so the standup 改到 Friday morning and uh send Chris the onboarding review",
             "Standup 改到 Friday morning. Send Chris the onboarding review."),
            ("remind me to renew the domain before the end of the month", nil),
            ("reply to Sam thanks for the notes I'll look at the pricing section tomorrow",
             "Thanks for the notes, Sam. I'll look at the pricing section tomorrow."),
            ("明天下午三点和设计组过一下 onboarding 的新流程", "明天下午三点和设计组过一下 onboarding 的新流程。"),
            ("add milk eggs and coffee beans to the shopping list", nil),
        ]

        private static func inMemoryContainer() -> ModelContainer {
            try! ModelContainer(for: Transcription.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        }

        private static var onboardingPermissions: some View {
            OnboardingPermissionsScreen(
                contentMaxWidth: 620, isComplete: false, activePermission: .accessibility,
                hasRequestedScreenRecording: false,
                stepNumber: { (OnboardingPermissionKind.allCases.firstIndex(of: $0) ?? 0) + 1 },
                status: { $0 == .microphone ? .granted : .needsAccess },
                isLocked: { _ in false },
                actionTitle: { _ in String(localized: "Allow") },
                onSelect: { _ in }, onAction: { _ in }, onQuit: {}, onRecheck: {}, onContinue: {},
                isRestoredFromCloud: false, onRestoreFromCloud: {})
        }

        private static func onboardingModel(_ kind: OnboardingTranscriptionSetupKind) -> some View {
            OnboardingModelScreen(
                contentMaxWidth: 620, localModel: nil, setupKind: kind,
                providerOptions: CloudProviderRegistry.allProviders, selectedProviderKey: .constant(""),
                isLocalDownloaded: false, isLocalDownloading: false, localDownloadStatus: nil,
                localDownloadError: nil, isSetupReady: false, isShowingSkipWarning: .constant(false),
                onSelectSetupKind: { _ in }, onDownload: { _ in }, onCancelDownload: { _ in },
                onVerificationChanged: {}, onBack: {}, onContinue: {},
                onContinueRecommended: { _ in nil }, onContinueYapCloud: { nil },
                onRequestSkip: {}, onConfirmSkip: {})
        }

        private static var onboardingDictation: some View {
            OnboardingExperienceScreen(
                step: OnboardingExperienceCatalog.steps[0], isInIntroPhase: false,
                shortcutAction: .primaryRecording, hasShortcut: true, text: .constant(""),
                isLastStep: false, isReady: true, isComplete: false,
                onBackFromIntro: {}, onContinueIntro: {}, onBackFromPractice: {}, onAdvance: {},
                onShortcutChanged: {}, onAppear: {})
        }

        private static func render<V: View>(
            _ name: String, size: CGSize = size, @ViewBuilder _ content: () -> V
        ) -> [String] {
            [NSAppearance.Name.aqua, .darkAqua].map { appearanceName in
                let isDark = appearanceName == .darkAqua
                let host = NSHostingView(
                    rootView: content()
                        .environment(\.colorScheme, isDark ? .dark : .light)
                        .frame(width: size.width, height: size.height)
                        .background(Color(nsColor: .windowBackgroundColor)))
                host.frame = CGRect(origin: .zero, size: size)
                let window = NSWindow(
                    contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: appearanceName)
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                // Forms and lists fill their rows on the next run-loop turns.
                RunLoop.main.run(until: Date().addingTimeInterval(0.5))
                host.layoutSubtreeIfNeeded()

                let url = outputDirectory.appendingPathComponent("\(name)-\(isDark ? "dark" : "light").png")
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: url)
                }
                window.contentView = nil
                return url.path
            }
        }
    }

    /// A signed-in, in-memory store so Config & Sync renders its enabled state.
    private final class SnapshotConfigStore: ConfigCloudStore {
        struct Document: CloudConfigDocument {
            let version: String
            let config: Data
        }

        var isSignedIn: Bool { true }
        func fetchConfig() async throws -> Document? { nil }
        func putConfig(_ data: Data, ifMatch: String?) async throws -> String { "1" }
    }

    /// The app's object graph for views that need it (Settings, Models, Modes), built the way VoiceInk.swift
    /// builds it but on an in-memory database. Nothing here records, registers hotkeys that can fire (the
    /// process exits right after rendering) or starts the updater (Sparkle's controller is lazy).
    @MainActor
    private struct SnapshotApp {
        let container: ModelContainer
        let aiService: AIService
        let enhancementService: AIEnhancementService
        let whisperModelManager: WhisperModelManager
        let fluidAudioModelManager: FluidAudioModelManager
        let transcriptionModelManager: TranscriptionModelManager
        let recorderUIManager: RecorderUIManager
        let engine: VoiceInkEngine
        let recordingShortcutManager: RecordingShortcutManager
        let menuBarManager: MenuBarManager
        let updaterViewModel: UpdaterViewModel

        init(container: ModelContainer) {
            self.container = container
            aiService = AIService()
            enhancementService = AIEnhancementService(aiService: aiService, modelContext: container.mainContext)
            whisperModelManager = WhisperModelManager(modelsDirectory: FileManager.default.temporaryDirectory)
            fluidAudioModelManager = FluidAudioModelManager()
            transcriptionModelManager = TranscriptionModelManager(
                whisperModelManager: whisperModelManager, fluidAudioModelManager: fluidAudioModelManager)
            transcriptionModelManager.refreshAllAvailableModels()
            recorderUIManager = RecorderUIManager()
            engine = VoiceInkEngine(
                modelContext: container.mainContext, whisperModelManager: whisperModelManager,
                transcriptionModelManager: transcriptionModelManager, enhancementService: enhancementService)
            recorderUIManager.configure(engine: engine, recorder: engine.recorder)
            engine.recorderUIManager = recorderUIManager
            recordingShortcutManager = RecordingShortcutManager(engine: engine, recorderUIManager: recorderUIManager)
            menuBarManager = MenuBarManager()
            menuBarManager.configure(engine: engine)
            updaterViewModel = UpdaterViewModel()
            // MenuBarManager applies its own activation policy; keep the snapshot process invisible.
            NSApplication.shared.setActivationPolicy(.prohibited)
        }

        func environment<V: View>(_ view: V) -> some View {
            view
                .modelContainer(container)
                .environmentObject(aiService)
                .environmentObject(enhancementService)
                .environmentObject(whisperModelManager)
                .environmentObject(fluidAudioModelManager)
                .environmentObject(transcriptionModelManager)
                .environmentObject(recorderUIManager)
                .environmentObject(engine)
                .environmentObject(recordingShortcutManager)
                .environmentObject(menuBarManager)
                .environmentObject(updaterViewModel)
                .environmentObject(MainWindowNavigation.shared)
        }
    }

    /// Saves this app's UserDefaults domain before the snapshot run and restores it afterwards. The copy is
    /// also written to disk first, so a run that crashed midway is undone at the start of the next one.
    /// (CFFIXED_USER_HOME doesn't isolate UserDefaults: writes still reach the real domain through cfprefsd.)
    @MainActor
    private struct DefaultsSnapshot {
        private static let backupURL = URL(fileURLWithPath: "/tmp/yap-ui/defaults-backup.plist")
        private let domain = Bundle.main.bundleIdentifier ?? ""
        private let saved: [String: Any]

        init() {
            let defaults = UserDefaults.standard
            if let data = try? Data(contentsOf: Self.backupURL),
                let previous = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            {
                defaults.setPersistentDomain(previous, forName: domain)
                defaults.synchronize()
            }
            saved = defaults.persistentDomain(forName: domain) ?? [:]
            if let data = try? PropertyListSerialization.data(fromPropertyList: saved, format: .binary, options: 0) {
                try? data.write(to: Self.backupURL, options: .atomic)
            }
        }

        func restore() {
            UserDefaults.standard.setPersistentDomain(saved, forName: domain)
            UserDefaults.standard.synchronize()
            try? FileManager.default.removeItem(at: Self.backupURL)
        }
    }
#endif
