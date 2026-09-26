#if DEBUG
    import AppKit
    import SwiftData
    import SwiftUI

    /// `make ui-snapshots`: renders every page, Settings group, onboarding screen and sheet to PNGs with fake data
    /// (MockData) and exits, without showing a window, taking focus or touching the network. Views are hosted in a
    /// never-ordered-in offscreen window and drawn with `cacheDisplay`, because `ImageRenderer` can't draw
    /// AppKit-backed controls (Form rows, toggles, pickers, text fields). Scrolling pages are captured whole: the
    /// window is grown by however much the page's scroll view overflows.
    ///
    /// File names start with their group (page, account, settings, onboarding, sheet, recorder), which the review
    /// page (scripts/ui-review.py) groups by. The Chinese run (-AppleLanguages (zh-Hans)) renders only `main` shots.
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
            let isChinese = Bundle.main.preferredLocalizations.first?.hasPrefix("zh") == true
            let suffix = isChinese ? "-zh" : ""

            let empty = inMemoryContainer()
            let full = inMemoryContainer()
            MockData.insertHistory(into: full.mainContext)
            MockData.insertDictionary(into: full.mainContext)
            let practiced = inMemoryContainer()
            practiced.mainContext.insert(Transcription(text: "Standup moved to Friday.", duration: 3))

            // Before the managers: the Yap Cloud catalog decides which transcription models exist.
            YapCloud.shared.applySnapshotState(.funded)
            let app = SnapshotApp(container: full)
            CloudConfigSync.shared.store = MockConfigStore()
            MockData.installModes()
            CustomAIProviderManager.shared.replaceProviders([MockData.customProvider])

            var written: [String] = []
            func shot<V: View>(
                _ name: String, size: CGSize = size, main: Bool = false, fullPage: Bool = false,
                @ViewBuilder _ content: () -> V
            ) {
                guard main || !isChinese else { return }
                written += render(name + suffix, size: size, fullPage: fullPage) { app.environment(content()) }
            }
            func page(_ name: String, _ view: ViewType, main: Bool = true) {
                MainWindowNavigation.shared.selectedView = view
                shot("page-\(name)", main: main, fullPage: true) { ContentView() }
            }

            // Sidebar pages, each whole.
            page("home", .dashboard)
            page("modes", .modes)
            page("models-local", .models)
            ModelManagementView.snapshotFilter = .cloud
            page("models-cloud", .models)
            ModelManagementView.snapshotFilter = .custom
            page("models-custom", .models, main: false)
            ModelManagementView.snapshotFilter = nil
            page("transcribe-audio", .transcribeAudio)
            page("audio", .audio)
            page("dictionary", .dictionary)
            page("settings", .settings)
            page("account", .account)
            shot("page-home-empty") { ContentView().modelContainer(empty) }

            for state in YapCloud.SnapshotState.allCases where state != .funded {
                YapCloud.shared.applySnapshotState(state)
                MainWindowNavigation.shared.selectedView = .account
                shot("account-\(state.rawValue)", fullPage: true) { ContentView() }
            }
            YapCloud.shared.applySnapshotState(.funded)

            // Settings groups on their own, whole (the Settings page above shows them in order).
            shot("settings-config-sync", fullPage: true) {
                Form { ConfigSyncSettingsSection() }
                    .formStyle(.grouped)
                    .scrollContentBackground(.hidden)
            }

            // Panels that open inside a page.
            ModeView.snapshotOpensEditor = true
            MainWindowNavigation.shared.selectedView = .modes
            shot("sheet-mode-editor", fullPage: true) { ContentView() }
            ModeView.snapshotOpensEditor = false
            ModelManagementView.snapshotFilter = .custom
            ModelManagementView.snapshotPanel = .customProviderEditor
            MainWindowNavigation.shared.selectedView = .models
            shot("sheet-custom-provider-editor", fullPage: true) { ContentView() }
            ModelManagementView.snapshotFilter = nil
            ModelManagementView.snapshotPanel = nil

            // Sheets, at the size they're presented at.
            if let notes = ReleaseNotes.current {
                shot("sheet-whats-new", size: CGSize(width: 560, height: 620)) { ReleaseNotesSheet(notes: notes) }
            }
            shot("sheet-version-history", size: CGSize(width: 640, height: 520)) { ConfigVersionHistorySheet() }
            shot("sheet-history-settings", size: CGSize(width: 480, height: 560)) {
                HistorySettingsPanel(onClose: {})
            }
            shot("sheet-yap-cloud-models", size: CGSize(width: 520, height: 520)) {
                YapCloudModelBrowser(
                    title: "All Yap Cloud Models",
                    models: YapCloud.shared.models.map { ($0.id, $0.displayName, $0.id) },
                    selectedID: YapCloud.shared.models.first?.id, onSelect: { _ in })
            }
            shot("sheet-restore-settings", size: CGSize(width: 440, height: 200)) {
                OnboardingCloudRestoreSheet { _ in }
            }

            // Recorder panels mid-dictation, on a dark desktop-like backdrop.
            app.engine.recordingState = .recording
            app.engine.partialTranscript = "so the standup 改到 Friday morning"
            shot("recorder-mini", size: CGSize(width: 420, height: 160)) {
                MiniRecorderView(
                    stateProvider: app.engine, recorder: app.engine.recorder,
                    assistantSession: app.engine.assistantSession,
                    onRecordButtonTapped: {}, onCloseTapped: {}, onAssistantFollowUp: { _ in })
            }
            shot("recorder-notch", size: CGSize(width: 520, height: 160)) {
                NotchRecorderView(
                    stateProvider: app.engine, recorder: app.engine.recorder,
                    assistantSession: app.engine.assistantSession,
                    onRecordButtonTapped: {}, onCloseTapped: {}, onAssistantFollowUp: { _ in })
            }
            app.engine.recordingState = .idle
            app.engine.partialTranscript = ""

            // Onboarding, every screen in order.
            YapCloud.shared.applySnapshotState(.signedOut)
            shot("onboarding-1-permissions", size: onboardingSize, main: true) { onboardingPermissions }
            shot("onboarding-2-microphone", size: onboardingSize, main: true) {
                OnboardingMicrophoneScreen(contentMaxWidth: 620, onBack: {}, onContinue: {})
            }
            shot("onboarding-3-model-yapcloud", size: onboardingSize, main: true) { onboardingModel(.yapCloud) }
            shot("onboarding-3-model-openrouter", size: onboardingSize, main: true) { onboardingModel(.recommended) }
            shot("onboarding-3-model-api", size: onboardingSize) { onboardingModel(.cloud) }
            shot("onboarding-3-model-local", size: onboardingSize) { onboardingModel(.local) }
            shot("onboarding-4-api-key", size: onboardingSize, main: true) {
                OnboardingAPIScreen(
                    aiService: app.aiService, contentMaxWidth: 620, providerOptions: [.openRouter, .groq, .gemini],
                    selectedProvider: .constant(.openRouter), isSelectedProviderVerified: false, canContinue: false,
                    isShowingSkipWarning: .constant(false), onVerificationChanged: {}, onBack: {}, onContinue: {},
                    onRequestSkip: {}, onConfirmSkip: {})
            }
            for (index, step) in OnboardingExperienceCatalog.steps.enumerated() {
                if index > 0 {
                    shot("onboarding-5-practice-\(index + 1)-intro", size: onboardingSize) {
                        onboardingExperience(step, intro: true)
                    }
                }
                shot("onboarding-5-practice-\(index + 1)", size: onboardingSize, main: index == 0) {
                    onboardingExperience(step, intro: false)
                }
            }
            shot("onboarding-6-context", size: onboardingSize, main: true) {
                OnboardingContextAwarenessScreen(contentMaxWidth: 620, onBack: {}, onContinue: {})
            }
            shot("onboarding-7-final", size: onboardingSize, main: true) {
                OnboardingTrustScreen(contentMaxWidth: 700, onBack: {}, onContinue: {}).modelContainer(empty)
            }
            shot("onboarding-7-final-after-practice", size: onboardingSize) {
                OnboardingTrustScreen(contentMaxWidth: 700, onBack: {}, onContinue: {}).modelContainer(practiced)
            }

            defaultsGuard.restore()
            print("Wrote \(written.count) snapshots to \(outputDirectory.path)")
            exit(0)
        }

        /// Onboarding's window is a fixed 950pt wide (AppWindowLayout.defaultWidth), 750pt at its shortest.
        private static let onboardingSize = CGSize(width: AppWindowLayout.defaultWidth, height: AppWindowLayout.minimumHeight)

        private static func inMemoryContainer() -> ModelContainer {
            try! ModelContainer(
                for: Transcription.self, VocabularyWord.self, WordReplacement.self, SessionMetric.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true))
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

        private static func onboardingExperience(_ step: OnboardingExperienceStep, intro: Bool) -> some View {
            OnboardingExperienceScreen(
                step: step, isInIntroPhase: intro,
                shortcutAction: .primaryRecording, hasShortcut: true, text: .constant(""),
                isLastStep: false, isReady: true, isComplete: false,
                onBackFromIntro: {}, onContinueIntro: {}, onBackFromPractice: {}, onAdvance: {},
                onShortcutChanged: {}, onAppear: {})
        }

        private static func render<V: View>(
            _ name: String, size: CGSize = size, fullPage: Bool, @ViewBuilder _ content: () -> V
        ) -> [String] {
            [NSAppearance.Name.aqua, .darkAqua].map { appearanceName in
                let isDark = appearanceName == .darkAqua
                var (host, window) = layOut(content(), size: size, appearanceName: appearanceName)
                if fullPage {
                    // Lazy stacks estimate their height, so re-measure after each resize (overflow can turn
                    // negative) until it settles. ponytail: the largest scroll view is assumed to be the page.
                    var height = size.height
                    for _ in 0..<3 {
                        let overflow = scrollOverflow(in: host)
                        let next = min(max(size.height, height + overflow), 6_000)
                        guard abs(next - height) > 1 else { break }
                        height = next
                        window.contentView = nil
                        (host, window) = layOut(
                            content(), size: CGSize(width: size.width, height: height), appearanceName: appearanceName)
                    }
                }

                let url = outputDirectory.appendingPathComponent("\(name)-\(isDark ? "dark" : "light").png")
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: url)
                }
                window.contentView = nil
                return url.path
            }
        }

        private static func layOut<V: View>(
            _ content: V, size: CGSize, appearanceName: NSAppearance.Name
        ) -> (NSView, NSWindow) {
            let host = NSHostingView(
                rootView: content
                    .environment(\.colorScheme, appearanceName == .darkAqua ? .dark : .light)
                    .frame(width: size.width, height: size.height)
                    .background(Color(nsColor: .windowBackgroundColor)))
            host.frame = CGRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearanceName)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            // Forms and lists fill their rows (and panels finish opening) on the next run-loop turns.
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            host.layoutSubtreeIfNeeded()
            return (host, window)
        }

        /// How much taller (or, negative, shorter) than its visible area the page's scroll view content is.
        private static func scrollOverflow(in view: NSView) -> CGFloat {
            var overflow = -CGFloat.infinity
            func visit(_ view: NSView) {
                if let scrollView = view as? NSScrollView, scrollView.frame.height > 200,
                    let document = scrollView.documentView
                {
                    overflow = max(overflow, document.frame.height - scrollView.contentView.bounds.height)
                }
                view.subviews.forEach(visit)
            }
            visit(view)
            return overflow.isFinite ? overflow : 0
        }
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
