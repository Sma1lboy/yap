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
    /// page (scripts/ui-review.py) groups by. The Chinese runs (-AppleLanguages (zh-Hans) and (zh-Hant)) render only `main` shots.
    @MainActor
    enum UISnapshots {
        static let argument = "--render-snapshots"
        static let outputDirectory = URL(
            fileURLWithPath: ProcessInfo.processInfo.environment["YAP_UI_SNAPSHOTS_OUT"] ?? "/tmp/yap-ui/snapshots",
            isDirectory: true)
        /// The main window's minimum size.
        static let size = CGSize(width: AppWindowLayout.minimumWidth, height: AppWindowLayout.minimumHeight)

        /// Call first thing at launch; returns only when the argument isn't present.
        static func runIfRequested() {
            guard CommandLine.arguments.contains(argument) else { return }
            // Rendering builds real managers that write UserDefaults (fake starter modes, a custom provider…), and
            // CFFIXED_USER_HOME doesn't isolate UserDefaults. Only the copy scripts/ui-snapshots.sh re-identifies
            // may run this, so those writes land in its own throwaway domain, never the dev app's.
            guard Bundle.main.bundleIdentifier == AppIdentity.snapshotsIdentifier else {
                print("--render-snapshots runs only as \(AppIdentity.snapshotsIdentifier); use make ui-snapshots")
                exit(2)
            }
            NSApplication.shared.setActivationPolicy(.prohibited)
            YapCloud.isSnapshotMode = true
            try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            let language = Bundle.main.preferredLocalizations.first ?? "en"
            let suffix = language == "zh-Hant" ? "-zht" : language.hasPrefix("zh") ? "-zh" : language == "en" ? "" : "-\(language)"

            let empty = inMemoryContainer()
            let full = inMemoryContainer()
            MockData.insertHistory(into: full.mainContext)
            MockData.insertDictionary(into: full.mainContext)
            // Home loads its week stats through its own ModelContext, which only sees saved data.
            try? full.mainContext.save()
            let practiced = inMemoryContainer()
            practiced.mainContext.insert(Transcription(text: "Standup moved to Friday.", duration: 3))

            // Before the managers: the Yap Cloud catalog decides which transcription models exist.
            YapCloud.shared.applySnapshotState(.funded)
            let app = SnapshotApp(container: full)
            // Keys as after onboarding (Right Option) plus an undo key, in the snapshot app's own defaults;
            // Rewrite stays unset so Home's Not set state is in the shot too.
            func setSnapshotShortcuts() {
                ShortcutStore.setShortcut(.modifierOnly(keyCode: 61, modifierFlags: [.option]), for: .primaryRecording)
                ShortcutStore.setShortcut(.key(keyCode: 6, modifierFlags: [.control, .option]), for: .undoLastPaste)
                ShortcutStore.setShortcut(nil, for: .rewriteLastPaste)
                app.recordingShortcutManager.primaryRecordingShortcut = .custom
            }
            setSnapshotShortcuts()
            CloudConfigSync.shared.store = MockConfigStore()
            MockData.installModes()
            CustomAIProviderManager.shared.replaceProviders([MockData.customProvider])

            var written: [String] = []
            func shot<V: View>(
                _ name: String, size: CGSize = size, main: Bool = false, fullPage: Bool = false, titled: Bool = false,
                highContrast: Bool = false, @ViewBuilder _ content: () -> V
            ) {
                guard main || suffix.isEmpty else { return }
                written += render(
                    name + suffix, size: size, fullPage: fullPage, titled: titled, highContrast: highContrast
                ) {
                    app.environment(content())
                }
            }
            func page(_ name: String, _ view: ViewType, main: Bool = true) {
                MainWindowNavigation.shared.selectedView = view
                shot("page-\(name)", main: main, fullPage: true, titled: true) { ContentView() }
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
            WordReplacementView.snapshotSelecting = true
            page("dictionary-select", .dictionary)
            WordReplacementView.snapshotSelecting = false
            page("settings", .settings)
            page("account", .account)

            // Increase Contrast: the same pages under macOS's high-contrast appearances (borders, secondary text,
            // selection fill). File names end in -contrast-light / -contrast-dark.
            DesignTokens.forceIncreasedContrast = true
            for (name, view) in [("home", ViewType.dashboard), ("settings", .settings), ("dictionary", .dictionary)] {
                MainWindowNavigation.shared.selectedView = view
                shot("page-\(name)-contrast", fullPage: true, titled: true, highContrast: true) { ContentView() }
            }
            WordReplacementView.snapshotSelecting = true
            MainWindowNavigation.shared.selectedView = .dictionary
            shot("page-dictionary-select-contrast", fullPage: true, titled: true, highContrast: true) { ContentView() }
            WordReplacementView.snapshotSelecting = false
            DesignTokens.forceIncreasedContrast = false
            // Something the pages above render (likely the mock config sync) resets them; set them again.
            setSnapshotShortcuts()
            MainWindowNavigation.shared.selectedView = .dashboard
            shot("page-home-empty", titled: true) { ContentView().modelContainer(empty) }

            for state in YapCloud.SnapshotState.allCases where state != .funded {
                YapCloud.shared.applySnapshotState(state)
                MainWindowNavigation.shared.selectedView = .account
                shot("account-\(state.rawValue)", fullPage: true, titled: true) { ContentView() }
            }
            YapCloud.shared.applySnapshotState(.funded)

            // Settings groups on their own, whole (the Settings page above shows them in order).
            shot("settings-config-sync", fullPage: true) {
                Form { ConfigSyncSettingsSection() }
                    .formStyle(.grouped)
                    .scrollContentBackground(.hidden)
            }

            // Settings search: a query that matches some sections, and one that matches none.
            SettingsView.snapshotQuery = "paste"
            MainWindowNavigation.shared.selectedView = .settings
            shot("settings-search", fullPage: true, titled: true) { ContentView() }
            SettingsView.snapshotQuery = "zzzz"
            shot("settings-search-empty", fullPage: true, titled: true) { ContentView() }
            SettingsView.snapshotQuery = ""

            // Settings › Account: signed out (sign-in form), then signed in with sync on.
            func accountGroup() -> some View {
                Form { AccountSettingsSection() }
                    .formStyle(.grouped)
                    .scrollContentBackground(.hidden)
            }
            UserDefaults.standard.set(false, forKey: CloudConfigSync.enabledKey)
            YapCloud.shared.applySnapshotState(.signedOut)
            shot("settings-account-signed-out", main: true, fullPage: true) { accountGroup() }
            YapCloud.shared.applySnapshotState(.funded)
            UserDefaults.standard.set(true, forKey: CloudConfigSync.enabledKey)
            CloudConfigSync.shared.applySnapshotSynced()
            shot("settings-account-signed-in", main: true, fullPage: true) { accountGroup() }
            UserDefaults.standard.set(false, forKey: CloudConfigSync.enabledKey)

            // Panels that open inside a page.
            ModeView.snapshotOpensEditor = true
            MainWindowNavigation.shared.selectedView = .modes
            shot("sheet-mode-editor", fullPage: true, titled: true) { ContentView() }
            ModeView.snapshotEditsEnhancedMode = true
            ModeConfigFormView.snapshotExpandsContext = true
            shot("sheet-mode-editor-context", main: true, fullPage: true, titled: true) { ContentView() }
            ModeView.snapshotEditsEnhancedMode = false
            ModeConfigFormView.snapshotExpandsContext = false
            ModeView.snapshotOpensEditor = false
            ModelManagementView.snapshotFilter = .custom
            ModelManagementView.snapshotPanel = .customProviderEditor
            MainWindowNavigation.shared.selectedView = .models
            shot("sheet-custom-provider-editor", fullPage: true, titled: true) { ContentView() }
            ModelManagementView.snapshotFilter = nil
            ModelManagementView.snapshotPanel = .settings
            shot("sheet-model-settings", fullPage: true, titled: true) { ContentView() }
            ModelManagementView.snapshotPanel = nil

            // Sheets, at the size they're presented at.
            if let notes = ReleaseNotes.current {
                shot("sheet-whats-new", size: CGSize(width: 560, height: 620)) { ReleaseNotesSheet(notes: notes) }
            }
            shot("sheet-feature-tour", size: CGSize(width: 560, height: 620), main: true) { FeatureTourSheet() }
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
            shot("history-row-subtitles", size: CGSize(width: 680, height: 420)) {
                let item = Transcription(text: MockData.history[0].original, duration: 6)
                let _ = item.segmentsJSON = TimedSegments.encode(MockData.fileSegments)
                HistoryCardRow(
                    transcription: item, wordCount: 14, isExpanded: true, isChecked: false, isSelecting: false,
                    onToggleExpand: {}, onToggleCheck: {}, onShowInfo: {}
                )
                .padding(AppTheme.Spacing.x4)
            }
            shot("history-row-meeting-failed-pieces", size: CGSize(width: 680, height: 120), main: true) {
                let item = Transcription(
                    text: "[00:00] \(MeetingSegment.Speaker.me.label): \(MeetingNotes.failedMarker)\n[00:08] "
                        + "\(MeetingSegment.Speaker.others.label): API 那边还差三个 endpoint，周四能 land", duration: 754)
                let _ = item.kind = Transcription.meetingKind
                let _ = item.meetingFailedPieces = 2
                HistoryCardRow(
                    transcription: item, wordCount: 14, isExpanded: false, isChecked: false, isSelecting: false,
                    onToggleExpand: {}, onToggleCheck: {}, onShowInfo: {}
                )
                .padding(AppTheme.Spacing.x4)
            }
            // A meeting whose speakers are being told apart after it was saved, and one where that failed.
            for (name, status) in [("pending", SpeakerSplitSkip.pendingStatus), ("failed", SpeakerSplitSkip.timedOut.rawValue)] {
                shot("history-row-meeting-speakers-\(name)", size: CGSize(width: 680, height: 120), main: true) {
                    let item = Transcription(
                        text: "[00:00] \(MeetingSegment.Speaker.me.label): 今天我想把 GitHub Actions 的 pipeline 改一下\n[00:08] "
                            + "\(MeetingSegment.Speaker.others.label): API 那边还差三个 endpoint，周四能 land", duration: 3_754)
                    let _ = item.kind = Transcription.meetingKind
                    let _ = item.meetingSpeakerStatus = status
                    HistoryCardRow(
                        transcription: item, wordCount: 14, isExpanded: false, isChecked: false, isSelecting: false,
                        onToggleExpand: {}, onToggleCheck: {}, onShowInfo: {}
                    )
                    .padding(AppTheme.Spacing.x4)
                }
            }
            // A meeting's History row on its notes tab (rendered Markdown), its tools in each state, the names editor.
            let meetingSpeakers = [
                ("me", MeetingSegment.Speaker.me.label), ("others-1", String(format: String(localized: "Others %lld"), 1)),
                ("others-2", String(format: String(localized: "Others %lld"), 2)),
            ].map { (key: $0.0, label: $0.1) }
            let namedMeeting = Transcription(
                text: "[00:00] Jackson: 今天我想把 GitHub Actions 的 pipeline 改一下\n[00:08] Sara: API 那边还差三个 endpoint，周四能 land\n"
                    + "[00:21] \(meetingSpeakers[2].label): Safari 上 IndexedDB 的问题我来看", duration: 754,
                enhancedText: """
                    ## 摘要
                    - CI 太慢，怀疑 Dockerfile 里 layer 的顺序让 build cache 失效。
                    - Safari 上的 IndexedDB transaction 问题：retry 改成 exponential backoff。

                    ## 待办
                    - [ ] 调整 Dockerfile layer 顺序 — Jackson — 周五
                    - [ ] 补齐三个 endpoint — Sara — 周四
                    - [x] 复现 Safari 的问题 — \(meetingSpeakers[2].label) — 未指定
                    """)
            namedMeeting.kind = Transcription.meetingKind
            namedMeeting.meetingSpeakerNamesJSON = ["me": "Jackson", "others-1": "Sara"].json
            MeetingRowTools.snapshotSpeakers = meetingSpeakers
            HistoryCardRow.initialTab = .enhanced
            shot("history-row-meeting-notes", size: CGSize(width: 680, height: 460), main: true) {
                HistoryCardRow(
                    transcription: namedMeeting, wordCount: 40, isExpanded: true, isChecked: false, isSelecting: false,
                    onToggleExpand: {}, onToggleCheck: {}, onShowInfo: {}
                )
                .padding(AppTheme.Spacing.x4)
            }
            HistoryCardRow.initialTab = .original
            MeetingRowTools.snapshotSpeakers = nil
            let toolStates: [(String, Bool, String?, Bool)] = [
                ("regenerating", true, nil, false),
                ("regenerate-failed", false, MeetingSummarizer.setupHint, false),
                ("renamed", false, nil, true),
            ]
            for (name, regenerating, problem, renamed) in toolStates {
                shot("history-meeting-tools-\(name)", size: CGSize(width: 620, height: 110), main: true) {
                    MeetingRowTools(
                        transcription: namedMeeting, speakers: meetingSpeakers, isRegenerating: regenerating,
                        problem: problem, renamed: renamed
                    )
                    .padding(AppTheme.Spacing.x4)
                }
            }
            shot("history-meeting-speaker-names", size: CGSize(width: 360, height: 300), main: true) {
                MeetingSpeakerNamesEditor(
                    speakers: meetingSpeakers, names: namedMeeting.meetingSpeakerNames, onCancel: {}, onSave: { _ in nil })
            }
            shot("sheet-restore-settings", size: CGSize(width: 440, height: 200)) {
                OnboardingCloudRestoreSheet { _ in }
            }

            // Scratchpad window (empty, with two dictations) and the notification when a dictation found no text field.
            let scratchpadURL = FileManager.default.temporaryDirectory.appendingPathComponent("yap-snapshot-scratchpad.txt")
            let scratchpad = ScratchpadStore(fileURL: scratchpadURL)
            shot("scratchpad-empty", size: CGSize(width: 380, height: 320), main: true) {
                ScratchpadView(store: scratchpad)
            }
            scratchpad.text = ScratchpadStore.appending(
                MockData.history[0].original, to: "Buy oat milk\nBook the dentist", at: Date(timeIntervalSince1970: 1_790_000_000))
            scratchpad.text = ScratchpadStore.appending(
                "Standup 改到 Friday morning。", to: scratchpad.text, at: Date(timeIntervalSince1970: 1_790_003_600))
            shot("scratchpad-text", size: CGSize(width: 380, height: 320), main: true) {
                ScratchpadView(store: scratchpad)
            }
            shot("notification-scratchpad", size: CGSize(width: 620, height: 80), main: true) {
                AppNotificationView(
                    title: ScratchpadStore.noTextFieldMessage, type: .warning, duration: 6, onClose: {}, onTap: nil,
                    actionButton: (String(localized: "Open Scratchpad"), {})
                )
                .padding(AppTheme.Spacing.x4)
            }
            // Call detection: the prompt for a meeting app and for a browser, and the reminder when the call ends.
            func callApp(_ bundleID: String) -> MeetingCallApp {
                MeetingCallApp.recognize(MicrophoneProcess(pid: 1, bundleID: bundleID, responsiblePID: 1, responsibleBundleID: nil))!
            }
            let callNotifications = [
                ("call-detected", callApp("us.zoom.xos").askMessage, String(localized: "Record Meeting")),
                ("call-detected-browser", callApp("com.google.Chrome").askMessage, String(localized: "Record Meeting")),
                ("call-ended", MeetingCallApp.endMessage, String(localized: "Show Meeting Panel")),
            ]
            for (name, title, button) in callNotifications {
                shot("notification-\(name)", size: CGSize(width: 620, height: 80), main: true) {
                    AppNotificationView(
                        title: title, type: .info, duration: 15, onClose: {}, onTap: nil, actionButton: (button, {}))
                    .padding(AppTheme.Spacing.x4)
                }
            }
            // Settings › Additional Shortcuts with the call detection switch on, found by searching for it.
            UserDefaults.standard.set(true, forKey: MeetingCallDetector.enabledKey)
            SettingsView.snapshotQuery = String(localized: "Remind Me to Record When a Call Starts")
            MainWindowNavigation.shared.selectedView = .settings
            shot("settings-call-detection", main: true, fullPage: true, titled: true) { ContentView() }
            SettingsView.snapshotQuery = ""
            UserDefaults.standard.removeObject(forKey: MeetingCallDetector.enabledKey)

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
            // The same two with Reduce Motion on: steady level bars, no springs.
            shot("recorder-mini-reduce-motion", size: CGSize(width: 420, height: 160)) {
                MiniRecorderView(
                    stateProvider: app.engine, recorder: app.engine.recorder,
                    assistantSession: app.engine.assistantSession,
                    onRecordButtonTapped: {}, onCloseTapped: {}, onAssistantFollowUp: { _ in })
                .environment(\.reduceMotionOverride, true)
            }
            shot("recorder-notch-reduce-motion", size: CGSize(width: 520, height: 160)) {
                NotchRecorderView(
                    stateProvider: app.engine, recorder: app.engine.recorder,
                    assistantSession: app.engine.assistantSession,
                    onRecordButtonTapped: {}, onCloseTapped: {}, onAssistantFollowUp: { _ in })
                .environment(\.reduceMotionOverride, true)
            }
            app.engine.recordingState = .idle
            app.engine.partialTranscript = ""

            // Meeting recording panel, each state.
            let meeting = MeetingRecorder.shared
            let meetingNotes = """
                ## 摘要
                - CI 太慢，怀疑 Dockerfile 里 layer 的顺序让 build cache 失效。
                - Safari 上的 IndexedDB transaction 问题：retry 改成 exponential backoff。

                ## 待办
                - [ ] 调整 Dockerfile layer 顺序 — 我 — 周五
                - [ ] 补齐三个 endpoint — Sara — 周四
                """
            let meetingTranscript = "[00:00] \(MeetingSegment.Speaker.me.label): 今天我想把 GitHub Actions 的 pipeline 改一下\n"
                + "[00:08] \(MeetingSegment.Speaker.others.label): API 那边还差三个 endpoint，周四能 land"
            let meetingFolder = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support/me.sma1lboy.yap/Recordings/meetings/9D1C6A0E-0B7F-4E43-A1B5-3F2C8E7D4A10")
            var meetingStates: [(String, MeetingRecorder.Phase, CGFloat, Bool)] = [
                ("consent", .consent, 280, true),
                ("recording", .recording(started: Date().addingTimeInterval(-754)), 110, true),
                ("finishing", .finishing(String(localized: "Writing notes…")), 90, false),
                ("notes", .done(.init(
                    transcriptionID: UUID(), notes: meetingNotes, transcript: meetingTranscript, notesProblem: nil,
                    markdown: "", notesModel: nil)), 420, true),
                ("transcript-only", .done(.init(
                    transcriptionID: UUID(), notes: nil, transcript: meetingTranscript,
                    notesProblem: MeetingSummarizer.setupHint, markdown: "", notesModel: nil)), 330, true),
                ("failed-pieces", .done(.init(
                    transcriptionID: UUID(), notes: nil, transcript: meetingTranscript + "\n[00:31] "
                        + MeetingSegment.Speaker.others.label + ": " + MeetingNotes.failedMarker,
                    notesProblem: nil, markdown: "", notesModel: nil, failedPieces: 1, speakersSkipped: .oneSpeaker)), 300, true),
                ("save-failed", .done(.init(
                    transcriptionID: UUID(), notes: meetingNotes, transcript: meetingTranscript, notesProblem: nil,
                    markdown: "", notesModel: nil, folder: meetingFolder, speakersSkipped: .timedOut,
                    saveError: CocoaError(.fileWriteOutOfSpace).localizedDescription)), 520, true),
                ("export-failed", .done(.init(
                    transcriptionID: UUID(), notes: nil, transcript: meetingTranscript,
                    notesProblem: nil, markdown: "", notesModel: nil, folder: meetingFolder,
                    speakersSkipped: .modelDownloadFailed,
                    exportError: CocoaError(.fileWriteNoPermission).localizedDescription)), 320, true),
            ]
            meetingStates += [
                ("regenerating", .done(.init(
                    transcriptionID: UUID(), notes: meetingNotes, transcript: meetingTranscript, notesProblem: nil,
                    markdown: "", notesModel: nil, isRegenerating: true)), 460, true),
                ("regenerate-failed", .done(.init(
                    transcriptionID: UUID(), notes: meetingNotes, transcript: meetingTranscript, notesProblem: nil,
                    markdown: "", notesModel: nil,
                    regenerateProblem: EnhancementFailureFormatter.message(for: EnhancementError.timeout))), 480, true),
                // Echo taken out of "Me"; then an hour-long meeting saved before its speakers were told apart, and
                // the same once they arrived.
                ("echo-removed", .done(.init(
                    transcriptionID: UUID(), notes: meetingNotes, transcript: meetingTranscript, notesProblem: nil,
                    markdown: "", notesModel: nil, echoRemoved: 3)), 450, true),
                ("speakers-pending", .done(.init(
                    transcriptionID: UUID(), notes: meetingNotes, transcript: meetingTranscript, notesProblem: nil,
                    markdown: "", notesModel: nil, echoRemoved: 2,
                    speakersPending: String(localized: "Telling speakers apart…"))), 500, true),
                ("speakers-arrived", .done(.init(
                    transcriptionID: UUID(), notes: meetingNotes, transcript: meetingTranscript, notesProblem: nil,
                    markdown: "", notesModel: nil, speakersLabeledLater: true)), 460, true),
            ]
            for (name, phase, height, main) in meetingStates {
                meeting.setSnapshotPhase(phase)
                shot("meeting-\(name)", size: CGSize(width: 420, height: height), main: main) {
                    MeetingPanelView(recorder: meeting).padding(AppTheme.Spacing.x4)
                }
            }
            meeting.setSnapshotPhase(.idle)

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
            shot("onboarding-3-model-local-downloading", size: onboardingSize) {
                onboardingModel(.local, downloading: .init(received: 240_000_000, total: 574_041_195, bytesPerSecond: 4_500_000))
            }
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

        private static func onboardingModel(
            _ kind: OnboardingTranscriptionSetupKind, downloading: ModelFileDownloader.Progress? = nil
        ) -> some View {
            OnboardingModelScreen(
                contentMaxWidth: 620, localModel: OnboardingCoordinator().requiredTranscriptionModel, setupKind: kind,
                providerOptions: CloudProviderRegistry.allProviders, selectedProviderKey: .constant(""),
                isLocalDownloaded: false, isLocalDownloading: downloading != nil,
                localDownloadStatus: downloading.map { FluidAudioDownloadStatus(fractionCompleted: $0.fraction, message: $0.summary) },
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
            _ name: String, size: CGSize = size, fullPage: Bool, titled: Bool = false, highContrast: Bool = false,
            @ViewBuilder _ content: () -> V
        ) -> [String] {
            let names: [NSAppearance.Name] =
                highContrast ? [.accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua] : [.aqua, .darkAqua]
            return names.map { appearanceName in
                let isDark = appearanceName == .darkAqua || appearanceName == .accessibilityHighContrastDarkAqua
                var (host, window) = layOut(content(), size: size, appearanceName: appearanceName, titled: titled)
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
                            content(), size: CGSize(width: size.width, height: height), appearanceName: appearanceName,
                            titled: titled)
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

        /// `titled`: the app's real window chrome (transparent title bar over full-size content, as
        /// WindowManager.configureWindow sets up), captured from the window's frame view so the traffic lights and
        /// the title-bar safe area are in the picture.
        private static func layOut<V: View>(
            _ content: V, size: CGSize, appearanceName: NSAppearance.Name, titled: Bool = false
        ) -> (NSView, NSWindow) {
            let host = NSHostingView(
                rootView: content
                    .environment(\.colorScheme, [.darkAqua, .accessibilityHighContrastDarkAqua].contains(appearanceName) ? .dark : .light)
                    .frame(width: size.width, height: size.height)
                    .background(Color(nsColor: .windowBackgroundColor)))
            host.frame = CGRect(origin: .zero, size: size)
            let style: NSWindow.StyleMask =
                titled ? [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView] : [.borderless]
            let window = NSWindow(contentRect: host.frame, styleMask: style, backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearanceName)
            if titled {
                window.titlebarAppearsTransparent = true
                window.titleVisibility = .hidden
                // Full-size content: the window frame is the page size, title bar included.
                window.setFrame(CGRect(origin: .zero, size: size), display: false)
            }
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            // Forms and lists fill their rows (and panels finish opening) on the next run-loop turns.
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            host.layoutSubtreeIfNeeded()
            let captured = titled ? (host.superview ?? host) : host
            captured.layoutSubtreeIfNeeded()
            return (captured, window)
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
#endif
