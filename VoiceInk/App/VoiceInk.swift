import AppIntents
import AppKit
import FluidAudio
import OSLog
import SwiftData
import SwiftUI

@main
struct VoiceInkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    let container: ModelContainer

    @StateObject private var engine: VoiceInkEngine
    // Retain managers without subscribing the entire scene to download progress.
    @State private var whisperModelManager: WhisperModelManager
    @State private var fluidAudioModelManager: FluidAudioModelManager
    @StateObject private var transcriptionModelManager: TranscriptionModelManager
    @StateObject private var recorderUIManager: RecorderUIManager
    @StateObject private var recordingShortcutManager: RecordingShortcutManager
    @StateObject private var updaterViewModel: UpdaterViewModel
    @StateObject private var menuBarManager: MenuBarManager
    @StateObject private var mainWindowNavigation = MainWindowNavigation.shared
    @StateObject private var aiService = AIService()
    @StateObject private var enhancementService: AIEnhancementService
    @StateObject private var activeWindowService = ActiveWindowService.shared
    @AppStorage(OnboardingSettings.completedV2Key) private var hasCompletedOnboardingV2 = false
    @State private var showMenuBarIcon = true
    @State private var didShowLaunchReminders = false

    // Audio cleanup manager for automatic deletion of old audio files
    private let audioCleanupManager = AudioCleanupManager.shared

    // Transcription auto-cleanup service for zero data retention
    private let transcriptionAutoCleanupService = TranscriptionAutoCleanupService.shared

    // Model prewarm service for optimizing model on wake from sleep
    @StateObject private var prewarmService: ModelPrewarmService

    init() {
        // NSApp is YapApplication (see there): SwiftUI creates NSApplication.shared itself and doesn't read
        // NSPrincipalClass, so the subclass has to be the first to ask for it.
        _ = YapApplication.shared
        // Disable HTTP response caching — prevents API responses from being stored in Cache.db
        URLCache.shared = URLCache(memoryCapacity: 0, diskCapacity: 0)

        AppDefaults.registerDefaults()
        #if DEBUG
            // make ui-snapshots: render fake-data screens to /tmp/yap-ui/snapshots and exit.
            UISnapshots.runIfRequested()
            // make meeting-call-check: print who uses the microphone and exit, before anything writes settings.
            MeetingCallCheck.runIfRequested()
            // make mcp-check: write a data folder for yap-mcp and the expected exports, and exit, before anything
            // writes settings.
            MCPFixture.runIfRequested()
            // make edit-rate-check: print the correction-rate fixtures, run their self-checks, and exit.
            EditRateCheck.runIfRequested()
            // make home-feedback-check: Home's paste numbers on fixed weeks, through WeekStatsLoader, and exit.
            HomeFeedbackFixture.runIfRequested()
            // make home-feedback-perf: Home's week panel on 20,000 metrics in a stats.store on disk, and exit.
            HomeFeedbackPerf.runIfRequested()
        #endif
        // Before onboarding can complete in this session, so a fresh install isn't mistaken for an update.
        ReleaseNotesPresenter.shared.showsOnNextMainWindow = ReleaseNotes.recordLaunch()
        #if DEBUG
            ReleaseNotes.selfCheck()
            TrustBody.selfCheck()
            WhisperChunking.selfCheck()
            TimedSegments.selfCheck()
            PCMResampler.selfCheck()
            MicrophoneLevelProbe.selfCheck()
            MoveToApplicationsPrompt.selfCheck()
            RecordedAudioIssue.selfCheck()
            VisualizerMotion.selfCheck()
            DictationAnnouncer.selfCheck()
            RecordingRecovery.selfCheck()
            TranscriptionOutputFilter.selfCheck()
            CancelConfirmation.selfCheck()
            DefaultShortcuts.selfCheck()
            SettingsGroup.selfCheck()
            ClipboardManager.selfCheck()
            LastPasteEditor.selfCheck()
            PromptTemplates.selfCheck()
            HomeShortcutsCard.selfCheck()
            CursorPaster.selfCheck()
            ScratchpadStore.selfCheck()
            StarterModeCatalog.selfCheck()
            TranscriptionLanguageSupport.selfCheck()
            CursorContextReader.selfCheck()
            YapIconCheck.selfCheck()
            MeetingChunker.selfCheck()
            MeetingNotes.selfCheck()
            MeetingEdits.selfCheck()
            MeetingEcho.selfCheck()
            MeetingRecorder.shortcutSelfCheck()
            MeetingRecorder.speakersSelfCheck()
            MeetingRecorder.recoverySelfCheck()
            MeetingSummarizer.selfCheck()
            MeetingStatusLine.selfCheck()
            MeetingCallPolicy.selfCheck()
            OpenAICompatibleChat.selfCheck()
            ModelFileDownloader.selfCheck()
            ReplacementText.selfCheck()
            WhisperPrompt.selfCheck()
            WhisperTranscriptionService.selfCheck()
            ChineseCleanup.selfCheck()
            WhisperLivePreview.selfCheck()
            DictationTimeline.selfCheck()
            LanguagePinSuggestion.selfCheck()
            TranscriptionDelivery.selfCheck()
            AutoLearnAXTextReader.selfCheck()
            FinalSnapshotDiffEngine.selfCheck()
            Task { @MainActor in
                do { try SessionEditRecorder.selfCheck() } catch { assertionFailure("SessionEditRecorder selfCheck: \(error)") }
            }
            Task.detached {
                do { try await AutoLearnLearnedLog.selfCheck() } catch { assertionFailure("AutoLearnLearnedLog selfCheck: \(error)") }
            }
            RecentlyLearnedSection.selfCheck()
            Task { @MainActor in await RecordingShortcutModeHandler.selfCheck() }
            Task { @MainActor in await WhisperModelManager.selfCheck() }
            Task { @MainActor in await AppDelegate.quitSelfCheck() }
            Task.detached {
                do { try SessionMetricRecorder.selfCheck() } catch { assertionFailure("SessionMetric selfCheck: \(error)") }
            }
            ModelResidency.selfCheck()
            YapCloud.modeNamesSelfCheck()
            RecordingContextSnapshot.selfCheck()
            HistoryQuery.selfCheck()
            AgentAccess.selfCheck()
            AgentConnection.selfCheck()
        #endif
        AppLanguagePreference.applyStored()
        AppAppearancePreference.applyStored()
        OnboardingV2Migration.prepareIfNeeded()
        // After the migration (it wipes modes on fresh installs) and before services read settings at init.
        YapConfigLoader.shared.applyAtLaunch()
        #if DEBUG
            MockEnvironment.seedSettings()  // make mock only
        #endif

        let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "Initialization")
        let schema = YapStores.schema
        let resolvedContainer: ModelContainer

        // Attempt 1: Try persistent storage
        do {
            resolvedContainer = try Self.createPersistentContainer(schema: schema, logger: logger)
        } catch let persistentError {
            // Attempt 2: Try in-memory storage
            do {
                resolvedContainer = try Self.createInMemoryContainer(schema: schema, logger: logger)
                logger.warning("Using in-memory storage as fallback. Data will not persist between sessions.")

                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = String(localized: "Storage Warning")
                    alert.informativeText = String(
                        localized:
                            "Yap couldn't access its storage location. Your transcriptions will not be saved between sessions."
                    )
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: String(localized: "OK"))
                    alert.runModal()
                }
            } catch let memoryError {
                let persistentDetail = Self.fullErrorDescription(persistentError)
                let memoryDetail = Self.fullErrorDescription(memoryError)
                logger.critical(
                    "❌ All ModelContainer init attempts failed.\nPersistent:\n\(persistentDetail, privacy: .public)\nIn-memory:\n\(memoryDetail, privacy: .public)"
                )
                fatalError(
                    "Yap failed to initialize storage.\nPersistent:\n\(persistentDetail)\nIn-memory:\n\(memoryDetail)"
                )
            }
        }

        container = resolvedContainer
        #if DEBUG
            MockEnvironment.seedStores(resolvedContainer)  // make mock only
        #endif
        DictionaryService.cleanUpDictionaryContent(context: resolvedContainer.mainContext, source: "launch")
        SessionEditRecorder.shared.modelContext = resolvedContainer.mainContext

        // Initialize services with proper sharing of instances
        let aiService = AIService()
        _aiService = StateObject(wrappedValue: aiService)
        aiService.refreshOllamaAvailabilityInBackground()
        Task { @MainActor in
            await aiService.fetchOpenRouterModelsIfNeededForMigration()
        }

        let updaterViewModel = UpdaterViewModel()
        _updaterViewModel = StateObject(wrappedValue: updaterViewModel)

        let enhancementService = AIEnhancementService(aiService: aiService, modelContext: resolvedContainer.mainContext)
        _enhancementService = StateObject(wrappedValue: enhancementService)
        let autoLearnReviewer = AutoLearnAIReviewer(enhancementService: enhancementService)
        Task {
            await AutoLearnService.shared.configure(
                modelContainer: resolvedContainer,
                reviewer: autoLearnReviewer
            )
        }

        // 1. Create modelsDirectory URL
        let appSupportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppIdentity.supportDirectoryName)
        let modelsDirectory = appSupportDirectory.appendingPathComponent("WhisperModels")

        // 2. Create model managers
        let whisperModelManager = WhisperModelManager(modelsDirectory: modelsDirectory)
        let fluidAudioModelManager = FluidAudioModelManager()
        let transcriptionModelManager = TranscriptionModelManager(
            whisperModelManager: whisperModelManager,
            fluidAudioModelManager: fluidAudioModelManager
        )

        // 3. Create UI manager
        let recorderUIManager = RecorderUIManager()

        // 4. Create engine
        let engine = VoiceInkEngine(
            modelContext: resolvedContainer.mainContext,
            whisperModelManager: whisperModelManager,
            transcriptionModelManager: transcriptionModelManager,
            enhancementService: enhancementService
        )

        // 5. Configure circular deps
        recorderUIManager.configure(engine: engine, recorder: engine.recorder)
        engine.recorderUIManager = recorderUIManager
        MeetingRecorder.shared.configure(engine: engine)
        MeetingCallDetector.shared.configure(engine: engine)
        // Once; a shortcut the user cleared stays cleared.
        ShortcutStore.seedShortcut(.rightCommandSpace, for: .meetingRecording)

        // 6. Initialize model state
        // Migration and refreshAllAvailableModels must run before loadCurrentTranscriptionModel so renamed keys are remapped and imported models are present when restoring the saved selection.
        StreamingKeysMigration.run()
        whisperModelManager.createModelsDirectoryIfNeeded()
        whisperModelManager.loadAvailableModels()
        transcriptionModelManager.refreshAllAvailableModels()
        transcriptionModelManager.loadCurrentTranscriptionModel()
        _whisperModelManager = State(initialValue: whisperModelManager)
        _fluidAudioModelManager = State(initialValue: fluidAudioModelManager)
        _transcriptionModelManager = StateObject(wrappedValue: transcriptionModelManager)
        _recorderUIManager = StateObject(wrappedValue: recorderUIManager)
        _engine = StateObject(wrappedValue: engine)

        // 7. Create other services that depend on engine
        let recordingShortcutManager = RecordingShortcutManager(engine: engine, recorderUIManager: recorderUIManager)
        _recordingShortcutManager = StateObject(wrappedValue: recordingShortcutManager)

        let menuBarManager = MenuBarManager()
        _menuBarManager = StateObject(wrappedValue: menuBarManager)
        menuBarManager.configure(engine: engine)

        CloudConfigSync.shared.store = YapCloud.shared
        #if DEBUG
            MockEnvironment.attachCloudStore()  // make mock only
        #endif
        YapConfigLoader.shared.attach(
            aiService: aiService,
            enhancementService: enhancementService,
            transcriptionModelManager: transcriptionModelManager,
            recordingShortcutManager: recordingShortcutManager,
            menuBarManager: menuBarManager,
            recorderUIManager: recorderUIManager,
            modelContext: resolvedContainer.mainContext
        )
        Task { @MainActor in
            await YapConfigLoader.shared.finishLaunch()
        }
        #if DEBUG
            OfflineCheck.runIfRequested(engine: engine)  // make offline-check only
            MeetingFilesCheck.runIfRequested()  // scripts/meeting-files-check.sh only
        #endif

        let activeWindowService = ActiveWindowService.shared
        _activeWindowService = StateObject(wrappedValue: activeWindowService)

        let prewarmService = ModelPrewarmService(
            transcriptionModelManager: transcriptionModelManager,
            whisperModelManager: whisperModelManager,
            modelContext: resolvedContainer.mainContext
        )
        _prewarmService = StateObject(wrappedValue: prewarmService)

        appDelegate.menuBarManager = menuBarManager
        appDelegate.engine = engine

        // Ensure no lingering recording state from previous runs
        Task {
            await recorderUIManager.resetOnLaunch()
        }

        AppShortcuts.updateAppShortcutParameters()

        let statsMigrationTask = SessionMetricMigrationService.shared.runStatsMigrationIfNeeded(
            modelContainer: resolvedContainer)
        let mainContext = resolvedContainer.mainContext
        Task { @MainActor in
            await statsMigrationTask?.value
            TranscriptionAutoCleanupService.shared.startMonitoring(modelContext: mainContext)
            let offeredDictation = RecordingRecovery.offerAtLaunch(modelContext: mainContext, engine: engine)
            // In the background, so the rest of launch isn't held up by a long transcription. Its "recovering"
            // note would replace dictation's offer, so it's left out then.
            Task { @MainActor in
                let recovered = await MeetingRecorder.shared.recoverInterruptedMeetings(announceStart: !offeredDictation)
                #if DEBUG
                    await MeetingFilesCheck.reportRecovery(recovered, engine: engine)  // scripts/meeting-files-check.sh only
                    await MeetingFilesCheck.runEditCheck(engine: engine)  // scripts/meeting-files-check.sh only
                #endif
                // Meetings saved while their speakers were still being told apart, when the app quit.
                let resumed = await MeetingRecorder.shared.resumeSpeakers()
                #if DEBUG
                    await MeetingFilesCheck.reportSpeakersResume(resumed, engine: engine)  // scripts/meeting-long-check.sh only
                #endif
            }

            let tokenBackfillTask = SessionMetricMigrationService.shared.runEnhancementTokenBackfillIfNeeded(
                modelContainer: resolvedContainer)
            await tokenBackfillTask?.value
        }
    }

    // MARK: - Container Creation Helpers

    private static func fullErrorDescription(_ error: Error, depth: Int = 0) -> String {
        let ns = error as NSError
        let indent = String(repeating: "  ", count: depth)
        var lines: [String] = []
        lines.append("\(indent)[\(ns.domain) \(ns.code)] \(ns.localizedDescription)")
        for (key, value) in ns.userInfo {
            let keyStr = "\(key)"
            if keyStr == NSUnderlyingErrorKey || keyStr == "NSDetailedErrors" { continue }
            lines.append("\(indent)  \(keyStr): \(value)")
        }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error {
            lines.append("\(indent)  Underlying:")
            lines.append(fullErrorDescription(underlying, depth: depth + 2))
        }
        if let details = ns.userInfo["NSDetailedErrors"] as? [Error] {
            lines.append("\(indent)  DetailedErrors (\(details.count)):")
            for (i, detail) in details.enumerated() {
                lines.append("\(indent)    [\(i)]:")
                lines.append(fullErrorDescription(detail, depth: depth + 3))
            }
        }
        return lines.joined(separator: "\n")
    }

    /// The app's stores in `directory` (Yap's Application Support folder; `make mcp-check`'s fixture passes its own).
    static func createPersistentContainer(
        schema: Schema, logger: Logger,
        directory appSupportURL: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppIdentity.supportDirectoryName, isDirectory: true)
    ) throws -> ModelContainer {

        try? FileManager.default.createDirectory(at: appSupportURL, withIntermediateDirectories: true)

        let defaultStoreURL = appSupportURL.appendingPathComponent("default.store")
        let dictionaryStoreURL = appSupportURL.appendingPathComponent("dictionary.store")
        let statsStoreURL = appSupportURL.appendingPathComponent("stats.store")

        let transcriptConfig = YapStores.historyConfiguration(url: defaultStoreURL)

        // Dev shares the local stores but must never connect to CloudKit.
        #if DEBUG || LOCAL_BUILD
            let dictionaryCloudKit: ModelConfiguration.CloudKitDatabase = .none
        #else
            let dictionaryCloudKit: ModelConfiguration.CloudKitDatabase = .private(
                "iCloud.com.prakashjoshipax.VoiceInk")
        #endif
        let dictionaryConfig = YapStores.dictionaryConfiguration(url: dictionaryStoreURL, cloudKitDatabase: dictionaryCloudKit)

        let statsSchema = Schema([SessionMetric.self])
        let statsConfig = ModelConfiguration(
            "stats",
            schema: statsSchema,
            url: statsStoreURL,
            cloudKitDatabase: .none
        )

        do {
            return try ModelContainer(for: schema, configurations: transcriptConfig, dictionaryConfig, statsConfig)
        } catch {
            logger.error(
                "❌ Failed to create persistent ModelContainer:\n\(Self.fullErrorDescription(error), privacy: .public)")
            throw error
        }
    }

    private static func createInMemoryContainer(schema: Schema, logger: Logger) throws -> ModelContainer {
        let transcriptSchema = Schema([Transcription.self])
        let transcriptConfig = ModelConfiguration("default", schema: transcriptSchema, isStoredInMemoryOnly: true)

        let dictionarySchema = Schema([VocabularyWord.self, WordReplacement.self])
        let dictionaryConfig = ModelConfiguration("dictionary", schema: dictionarySchema, isStoredInMemoryOnly: true)

        let statsSchema = Schema([SessionMetric.self])
        let statsConfig = ModelConfiguration("stats", schema: statsSchema, isStoredInMemoryOnly: true)

        do {
            return try ModelContainer(for: schema, configurations: transcriptConfig, dictionaryConfig, statsConfig)
        } catch {
            logger.error(
                "❌ Failed to create in-memory ModelContainer:\n\(Self.fullErrorDescription(error), privacy: .public)")
            throw error
        }
    }

    var body: some Scene {
        Window("Yap", id: AppWindowID.main) {
            Group {
                if hasCompletedOnboardingV2 {
                    ContentView()
                        .environmentObject(engine)
                        .environmentObject(whisperModelManager)
                        .environmentObject(fluidAudioModelManager)
                        .environmentObject(transcriptionModelManager)
                        .environmentObject(recorderUIManager)
                        .environmentObject(recordingShortcutManager)
                        .environmentObject(updaterViewModel)
                        .environmentObject(menuBarManager)
                        .environmentObject(mainWindowNavigation)
                        .environmentObject(aiService)
                        .environmentObject(enhancementService)
                        .modelContainer(container)
                        .onAppear {
                            showLaunchRemindersIfNeeded()

                            // Run due audio-only cleanup and schedule future checks when transcript cleanup is not managing retention.
                            if !UserDefaults.standard.bool(forKey: CleanupSettingsKeys.isTranscriptionCleanupEnabled)
                                && UserDefaults.standard.bool(forKey: CleanupSettingsKeys.isAudioCleanupEnabled)
                            {
                                Task {
                                    await audioCleanupManager.runAutomaticCleanupIfNeeded(
                                        modelContext: container.mainContext)
                                }
                                audioCleanupManager.startAutomaticCleanup(modelContext: container.mainContext)
                            }

                            // Process any pending open-file request now that the main ContentView is ready.
                            if let pendingURL = appDelegate.pendingOpenFileURL {
                                NotificationCenter.default.post(
                                    name: .navigateToDestination, object: nil,
                                    userInfo: ["destination": "Transcribe Audio"])
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    NotificationCenter.default.post(
                                        name: .openFileForTranscription, object: nil, userInfo: ["url": pendingURL])
                                }
                                appDelegate.pendingOpenFileURL = nil
                            }
                        }
                        .background(
                            WindowAccessor { window in
                                WindowManager.shared.configureWindow(window)
                            }
                        )
                        .onDisappear {
                            // Stop the automatic audio cleanup process
                            audioCleanupManager.stopAutomaticCleanup()
                        }
                } else {
                    OnboardingView(hasCompletedOnboardingV2: $hasCompletedOnboardingV2)
                        .modelContainer(container)
                        .environmentObject(whisperModelManager)
                        .environmentObject(transcriptionModelManager)
                        .environmentObject(aiService)
                        .environmentObject(enhancementService)
                        .frame(width: AppWindowLayout.defaultWidth)
                        .frame(minHeight: AppWindowLayout.minimumHeight)
                        .background(
                            WindowAccessor { window in
                                WindowManager.shared.configureWindow(window)
                            })
                }
            }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: AppWindowLayout.defaultWidth, height: AppWindowLayout.minimumHeight)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}

            // The app has no Settings scene; ⌘, opens the Settings page of the main window.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…", action: SettingsNavigator.open)
                    .keyboardShortcut(",", modifiers: .command)
            }

            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updaterViewModel: updaterViewModel)
            }

            // No Help book ships, so the default "Yap Help" item only showed an error.
            CommandGroup(replacing: .help) {
                Button("Explore Key Features", action: FeatureTourNavigator.open)
                Link("Report an Issue", destination: AppIdentity.issuesURL)
            }
        }

        MenuBarExtra(isInserted: $showMenuBarIcon) {
            MenuBarView()
                .environmentObject(engine)
                .environmentObject(whisperModelManager)
                .environmentObject(fluidAudioModelManager)
                .environmentObject(transcriptionModelManager)
                .environmentObject(recorderUIManager)
                .environmentObject(recordingShortcutManager)
                .environmentObject(menuBarManager)
                .environmentObject(mainWindowNavigation)
                .environmentObject(updaterViewModel)
                .environmentObject(aiService)
                .environmentObject(enhancementService)
        } label: {
            // Template duck glyph (design/logo.svg simplified) at the 18pt size of system menu bar icons.
            let image: NSImage = {
                $0.size = NSSize(width: 18, height: 18)
                $0.isTemplate = true
                return $0
            }(NSImage(named: "menuBarIcon")!)

            HStack(spacing: AppTheme.Spacing.x1) {
                Image(nsImage: image)
                MeetingMenuBarBadge()
            }
            .background(MainWindowRequestBridge(menuBarManager: menuBarManager))
        }
        .menuBarExtraStyle(.menu)

        #if DEBUG
            WindowGroup("Debug") {
                Button("Toggle Menu Bar Only") {
                    menuBarManager.isMenuBarOnly.toggle()
                }
            }
        #endif
    }

    /// Only one notification fits on screen, so show at most one launch reminder.
    private func showLaunchRemindersIfNeeded() {
        guard !didShowLaunchReminders else { return }
        didShowLaunchReminders = true

        if !AXIsProcessTrusted() {
            NotificationManager.shared.showNotification(
                title: String(localized: "Accessibility permission is not provided"),
                type: .warning,
                duration: 7.0,
                actionButton: (String(localized: "Open Settings"), Self.openAccessibilitySettings)
            )
            return
        }

        if !ModeManager.shared.hasEnabledConfiguration {
            NotificationManager.shared.showNotification(
                title: String(localized: "No mode configured"),
                type: .warning,
                duration: 7.0,
                actionButton: (String(localized: "Manage Modes"), ModeSetupNavigator.openModesSettings)
            )
        }
    }

    private static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct MainWindowRequestBridge: View {
    @Environment(\.openWindow) private var openWindow
    let menuBarManager: MenuBarManager

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onReceive(NotificationCenter.default.publisher(for: .showMainWindowRequested)) { _ in
                let existingWindow = WindowManager.shared.currentMainWindow()

                if existingWindow == nil {
                    menuBarManager.activateForPresentedWindow()
                    WindowManager.shared.prepareForUserRequestedMainWindow()
                    openWindow(id: AppWindowID.main)
                } else {
                    menuBarManager.activateForPresentedWindow()
                    openWindow(id: AppWindowID.main)
                    WindowManager.shared.showMainWindow()
                }
            }
    }
}

struct WindowAccessor: NSViewRepresentable {
    let callback: (NSWindow) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        notifyWindowIfNeeded(for: view, context: context)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        notifyWindowIfNeeded(for: nsView, context: context)
    }

    private func notifyWindowIfNeeded(for view: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = view.window,
                context.coordinator.window !== window
            {
                context.coordinator.window = window
                callback(window)
            }
        }
    }

    final class Coordinator {
        weak var window: NSWindow?
    }
}
