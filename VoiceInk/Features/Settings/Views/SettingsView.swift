import Carbon.HIToolbox
import Cocoa
import SwiftUI

@MainActor
struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var updaterViewModel: UpdaterViewModel
    @EnvironmentObject private var menuBarManager: MenuBarManager
    @EnvironmentObject private var recordingShortcutManager: RecordingShortcutManager
    @EnvironmentObject private var recorderUIManager: RecorderUIManager
    @EnvironmentObject private var transcriptionModelManager: TranscriptionModelManager
    @EnvironmentObject private var enhancementService: AIEnhancementService
    @ObservedObject private var launchAtLoginManager = LaunchAtLoginManager.shared
    @ObservedObject private var mediaController = MediaController.shared
    @ObservedObject private var playbackController = PlaybackController.shared
    @AppStorage(OnboardingSettings.completedV2Key) private var hasCompletedOnboardingV2 = true
    @AppStorage("restoreClipboardAfterPaste") private var restoreClipboardAfterPaste = true
    @AppStorage("AppendTrailingSpace") private var appendTrailingSpace = true
    @AppStorage("clipboardRestoreDelay") private var clipboardRestoreDelay = 2.0
    @AppStorage(PasteMethod.userDefaultsKey) private var pasteMethodRawValue = PasteMethod.standard.rawValue
    @AppStorage(AppAppearancePreference.userDefaultsKey) private var appAppearancePreference = AppAppearancePreference
        .system
    @AppStorage(AppLanguagePreference.userDefaultsKey) private var appLanguagePreference = AppLanguagePreference
        .systemValue
    @AppStorage(RecorderDisplaySettingsKeys.showLiveTranscript) private var showLiveTranscript = true
    @AppStorage(FinishAndSendSettings.key) private var finishAndSendKey = FinishAndSendKey.none.rawValue
    @State private var showResetOnboardingAlert = false
    @State private var showLanguageRestartAlert = false
    @State private var cancelRecordingShortcutRecorderResetID = 0
    @State private var isImportingSettings = false
    #if DEBUG
        /// make ui-snapshots: the query the search field starts with.
        @MainActor static var snapshotQuery = ""
        @State private var searchText = SettingsView.snapshotQuery
    #else
        @State private var searchText = ""
    #endif
    @State private var pendingShortcutRestore: [DefaultShortcuts.Change] = []
    @State private var showRestoreShortcutsAlert = false

    @State private var isRestoreClipboardExpanded = false
    @State private var isShowingHistorySettings = false

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    private var visibleGroups: Set<SettingsGroup> { SettingsGroup.visible(for: searchText) }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            settingsForm
        }
    }

    private var searchField: some View {
        HStack(spacing: AppTheme.Spacing.x2) {
            Image(yapIcon: "magnifyingglass")
                .foregroundStyle(AppTheme.Text.secondary)
                .font(AppTheme.font(.footnote))
            TextField("Search Settings", text: $searchText)
                .textFieldStyle(.plain)
                .font(AppTheme.font(.body))
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(yapIcon: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppTheme.Text.secondary)
                .accessibilityLabel("Clear Search")
            }
        }
        .padding(.horizontal, AppTheme.Spacing.x3)
        .padding(.vertical, AppTheme.Spacing.x2)
        .background(Capsule().fill(AppTheme.Surface.card))
        .padding(.horizontal, AppTheme.Spacing.x4)
        .padding(.top, AppTheme.Spacing.x3)
    }

    private var settingsForm: some View {
        Form {
            if visibleGroups.isEmpty {
                Text("No settings match")
                    .foregroundStyle(AppTheme.Text.secondary)
                    .frame(maxWidth: .infinity)
            }

            if visibleGroups.contains(.account) {
                AccountSettingsSection()
            }

            if visibleGroups.contains(.config) {
                ConfigSyncSettingsSection()
            }

            if visibleGroups.contains(.shortcuts) {
                Section {
                    LabeledContent("Primary Shortcut") {
                        HStack(spacing: AppTheme.Spacing.x2) {
                            Spacer()
                            shortcutModePicker(binding: $recordingShortcutManager.primaryRecordingShortcutMode)
                            ShortcutRecorder(action: .primaryRecording) {
                                recordingShortcutManager.primaryRecordingShortcut = .custom
                                recordingShortcutManager.updateShortcutStatus()
                            }
                            .controlSize(.small)
                        }
                    }

                    if recordingShortcutManager.secondaryRecordingShortcut != .none {
                        LabeledContent("Secondary Shortcut") {
                            HStack(spacing: AppTheme.Spacing.x2) {
                                Spacer()
                                shortcutModePicker(binding: $recordingShortcutManager.secondaryRecordingShortcutMode)
                                ShortcutRecorder(action: .secondaryRecording) {
                                    recordingShortcutManager.secondaryRecordingShortcut = .custom
                                    recordingShortcutManager.updateShortcutStatus()
                                }
                                .controlSize(.small)
                                Button {
                                    withAnimation { recordingShortcutManager.secondaryRecordingShortcut = .none }
                                } label: {
                                    Image(yapIcon: "minus.circle.fill")
                                        .foregroundColor(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Remove Secondary Shortcut")
                                .accessibilityLabel("Remove Secondary Shortcut")
                            }
                        }
                    }

                    if recordingShortcutManager.secondaryRecordingShortcut == .none {
                        Button("Add Second Shortcut") {
                            withAnimation { recordingShortcutManager.secondaryRecordingShortcut = .custom }
                        }
                    }

                    Button("Restore Default Shortcuts…") {
                        pendingShortcutRestore = DefaultShortcuts.changes(current: { ShortcutStore.shortcut(for: $0) })
                        showRestoreShortcutsAlert = true
                    }

                } header: {
                    HStack(spacing: AppTheme.Spacing.x1) {
                        Text("Shortcuts")
                        InfoTip("Supports keyboard combinations and mouse buttons.")
                    }
                }
            }

            if visibleGroups.contains(.voiceEdits) {
                Section {
                    LabeledContent {
                        ShortcutRecorder(action: .undoLastPaste)
                            .controlSize(.small)
                    } label: {
                        HStack(spacing: AppTheme.Spacing.x1) {
                            Text("Undo Last Paste")
                            InfoTip("Takes back the text Yap pasted last, if it's still where Yap put it and unchanged. If it replaced selected text, that text comes back; otherwise it's removed. Saying only \"scratch that\" or \"删掉刚才那句\" does the same.")
                        }
                    }

                    LabeledContent {
                        ShortcutRecorder(action: .rewriteLastPaste)
                            .controlSize(.small)
                    } label: {
                        HStack(spacing: AppTheme.Spacing.x1) {
                            Text("Rewrite Last Dictation")
                            InfoTip("Press, say how to change the text Yap pasted last (\"make it more formal\", \"改正式一点\"), press again. It's rewritten in place with this mode's AI provider.")
                        }
                    }
                } header: {
                    Text("Voice Edits")
                } footer: {
                    Text("Both act only on the text Yap pasted last, and only if it's still there unchanged.")
                        .font(AppTheme.font(.footnote))
                        .foregroundStyle(AppTheme.Text.secondary)
                }
            }

            if visibleGroups.contains(.additionalShortcuts) {
                Section("Additional Shortcuts") {
                    LabeledContent("Paste Last Transcription (Original)") {
                        ShortcutRecorder(action: .pasteLastTranscription) {
                            recordingShortcutManager.updateShortcutStatus()
                        }
                        .controlSize(.small)
                    }

                    LabeledContent("Paste Last Transcription (Enhanced)") {
                        ShortcutRecorder(action: .pasteLastEnhancement) {
                            recordingShortcutManager.updateShortcutStatus()
                        }
                        .controlSize(.small)
                    }

                    LabeledContent("Copy Last Transcription") {
                        ShortcutRecorder(action: .copyLastTranscription)
                            .controlSize(.small)
                    }

                    LabeledContent("Retry Last Transcription") {
                        ShortcutRecorder(action: .retryLastTranscription) {
                            recordingShortcutManager.updateShortcutStatus()
                        }
                        .controlSize(.small)
                    }

                    // Also set from the History and Dictionary panels; same stored shortcut.
                    LabeledContent("Open Quick History") {
                        ShortcutRecorder(action: .openQuickHistory)
                            .controlSize(.small)
                    }

                    LabeledContent("Quick Add to Dictionary") {
                        ShortcutRecorder(action: .quickAddToDictionary)
                            .controlSize(.small)
                    }

                    LabeledContent {
                        ShortcutRecorder(action: .meetingRecording)
                            .controlSize(.small)
                    } label: {
                        HStack(spacing: AppTheme.Spacing.x1) {
                            Text("Record Meeting")
                            InfoTip("Press once to start recording a meeting (your microphone and other apps' sound), again to stop and get notes. ⌘ + Space here always means the right ⌘; the left one stays Spotlight's.")
                        }
                    }

                    LabeledContent {
                        HStack(spacing: AppTheme.Spacing.x2) {
                            ShortcutRecorder(
                                action: .cancelRecorder,
                                defaultShortcut: Self.defaultCancelRecordingShortcut
                            )
                            .id(cancelRecordingShortcutRecorderResetID)
                            .controlSize(.small)

                            Button {
                                RecorderPanelShortcutManager.resetEscapeConfirmationHint()
                                ShortcutStore.setShortcut(nil, for: .cancelRecorder)
                                cancelRecordingShortcutRecorderResetID += 1
                            } label: {
                                Image(yapIcon: "arrow.counterclockwise")
                            }
                            .buttonStyle(.plain)
                            .help("Reset to default")
                            .accessibilityLabel("Reset to default")
                        }
                    } label: {
                        HStack(spacing: AppTheme.Spacing.half) {
                            Text("Cancel Recording")
                            InfoTip(
                                "The assigned shortcut cancels the recording. Resetting restores the default double-Escape behavior."
                            )
                        }
                    }

                }
            }

            if visibleGroups.contains(.pasting) {
                Section("Pasting") {
                    Toggle(isOn: $appendTrailingSpace) {
                        HStack(spacing: AppTheme.Spacing.x1) {
                            Text("Add Space After Paste")
                            InfoTip("Add a trailing space after pasted transcription output.")
                        }
                    }

                    Picker(selection: $finishAndSendKey) {
                        ForEach(FinishAndSendKey.allCases, id: \.self) { key in
                            Text(key.displayName).tag(key.rawValue)
                        }
                    } label: {
                        HStack(spacing: AppTheme.Spacing.x1) {
                            Text("Auto Send")
                            InfoTip("Press Return while recording to stop and deliver the result. Yap will then paste the result and press the selected key to send it. Choose None to disable this feature.")
                        }
                    }

                    ExpandableSettingsRow(
                        isExpanded: $isRestoreClipboardExpanded,
                        isEnabled: $restoreClipboardAfterPaste,
                        label: "Keep Clipboard Content",
                        infoMessage:
                            "Yap temporarily uses the clipboard to paste transcription. When enabled, it restores your previous clipboard content after the selected delay. When disabled, the pasted transcription stays on your clipboard."
                    ) {
                        Picker("Restore Delay", selection: $clipboardRestoreDelay) {
                            Text("250ms").tag(0.25)
                            Text("500ms").tag(0.5)
                            Text("1s").tag(1.0)
                            Text("2s").tag(2.0)
                            Text("3s").tag(3.0)
                            Text("4s").tag(4.0)
                            Text("5s").tag(5.0)
                        }
                    }

                    Picker(selection: $pasteMethodRawValue) {
                        ForEach(PasteMethod.allCases) { method in
                            Text(method.displayName).tag(method.rawValue)
                        }
                    } label: {
                        HStack(spacing: AppTheme.Spacing.x1) {
                            Text("Paste Method")
                            InfoTip(
                                "Default uses simulated Cmd+V key events. AppleScript can help when custom keyboard layouts do not paste correctly."
                            )
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: pasteMethodRawValue) { _, newValue in
                        guard let method = PasteMethod(rawValue: newValue) else {
                            pasteMethodRawValue = PasteMethod.standard.rawValue
                            return
                        }
                        PasteMethod.setCurrent(method)
                    }
                }
            }

            if visibleGroups.contains(.interface) {
                Section("Interface") {
                    Picker("Appearance", selection: $appAppearancePreference) {
                        ForEach(AppAppearancePreference.allCases) { preference in
                            Text(preference.displayName).tag(preference)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: appAppearancePreference) { _, newValue in
                        newValue.apply()
                    }

                    Picker("Language", selection: $appLanguagePreference) {
                        ForEach(AppLanguagePreference.availableOptions) { option in
                            Text(option.displayName).tag(option.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: appLanguagePreference) { oldValue, newValue in
                        guard oldValue != newValue else { return }
                        let normalizedValue = AppLanguagePreference.normalizedRawValue(newValue)
                        if normalizedValue != newValue {
                            appLanguagePreference = normalizedValue
                            return
                        }
                        AppLanguagePreference.apply(rawValue: normalizedValue)
                        showLanguageRestartAlert = true
                    }

                    Picker("Recorder Style", selection: $recorderUIManager.recorderPanelStyle) {
                        ForEach(RecorderPanelStyle.allCases) { style in
                            Text(style.displayName).tag(style)
                        }
                    }
                    .pickerStyle(.menu)

                    Toggle(isOn: $showLiveTranscript) {
                        HStack(spacing: AppTheme.Spacing.x1) {
                            Text("Live Text Display")
                            InfoTip("Shows text while you speak. Realtime models stream it; local Whisper models show a preview that the final transcript replaces when you stop.")
                        }
                    }
                }
            }

            if visibleGroups.contains(.general) {
                Section("General") {
                    Toggle("Hide Dock Icon", isOn: $menuBarManager.isMenuBarOnly)

                    Toggle(
                        String(localized: "Launch at Login"),
                        isOn: Binding(
                            get: { launchAtLoginManager.isEnabled },
                            set: { launchAtLoginManager.setEnabled($0) }
                        )
                    )
                    .disabled(launchAtLoginManager.isUpdating)
                }
            }

            if visibleGroups.contains(.backup) {
                Section {
                    LabeledContent("Export Settings") {
                        Button("Export") {
                            Task {
                                await ImportExportService.shared.exportSettings(
                                    enhancementService: enhancementService,
                                    recordingShortcutManager: recordingShortcutManager,
                                    menuBarManager: menuBarManager,
                                    mediaController: mediaController,
                                    playbackController: playbackController,
                                    recorderUIManager: recorderUIManager,
                                    modelContext: modelContext
                                )
                            }
                        }
                    }

                    LabeledContent("Import Settings") {
                        Button("Import") {
                            guard !isImportingSettings else { return }
                            isImportingSettings = true
                            Task { @MainActor in
                                defer { isImportingSettings = false }
                                await ImportExportService.shared.importSettings(
                                    enhancementService: enhancementService,
                                    recordingShortcutManager: recordingShortcutManager,
                                    menuBarManager: menuBarManager,
                                    mediaController: mediaController,
                                    playbackController: playbackController,
                                    recorderUIManager: recorderUIManager,
                                    modelContext: modelContext,
                                    transcriptionModelManager: transcriptionModelManager
                                )
                            }
                        }
                        .disabled(isImportingSettings)
                    }
                } header: {
                    Text("Backup")
                } footer: {
                    Text("Export all settings, or choose specific categories when importing a backup.")
                }
            }

            if visibleGroups.contains(.history) {
                Section("History") {
                    LabeledContent("Auto-delete transcripts and audio") {
                        Button("History Settings…") { isShowingHistorySettings = true }
                    }
                }
            }

            if visibleGroups.contains(.help) {
                Section("Help") {
                    LabeledContent {
                        Button("Start") { MainWindowNavigation.shared.isShowingFeatureTour = true }
                    } label: {
                        Text("Explore Key Features")
                        Text("A card for each feature, with its shortcut and where to set it up.")
                    }
                }
            }

            if visibleGroups.contains(.diagnostics) {
                Section("Diagnostics") {
                    DiagnosticsSettingsView()

                    Button("Reset Onboarding") {
                        showResetOnboardingAlert = true
                    }
                }
            }

            if visibleGroups.contains(.about) {
                Section("About") {
                    LabeledContent("Version") {
                        Text(verbatim: appVersion)
                            .textSelection(.enabled)
                    }

                    if ReleaseNotes.current != nil {
                        Button(String(format: String(localized: "What's New in %@"), ReleaseNotes.currentVersion)) {
                            ReleaseNotesPresenter.shared.showCurrent()
                        }
                    }

                    Toggle(
                        "Automatically Check for Updates",
                        isOn: Binding(
                            get: { updaterViewModel.checksForUpdatesWhenDashboardAppears },
                            set: { updaterViewModel.setChecksForUpdatesWhenDashboardAppears($0) }
                        ))

                    HStack {
                        Button("Check for Updates") {
                            updaterViewModel.checkForUpdates()
                        }
                        .disabled(!updaterViewModel.canCheckForUpdates)

                        Link("Report an Issue", destination: AppIdentity.issuesURL)
                        .appLinkStyle()
                    }

                    YapCloudLegalLinks()
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .modifier(CloudSyncOffer())
        .sheet(isPresented: $isShowingHistorySettings) {
            HistorySettingsPanel(onClose: { isShowingHistorySettings = false })
                .frame(width: 480, height: 560)
                .onExitCommand { isShowingHistorySettings = false }
        }
        .alert("Restore Default Shortcuts", isPresented: $showRestoreShortcutsAlert) {
            Button("Cancel", role: .cancel) {}
            if !pendingShortcutRestore.isEmpty {
                Button("Restore", role: .destructive) {
                    DefaultShortcuts.apply(pendingShortcutRestore, recordingShortcutManager: recordingShortcutManager)
                }
            }
        } message: {
            Text(restoreShortcutsMessage)
        }
        .alert("Reset Onboarding", isPresented: $showResetOnboardingAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                DispatchQueue.main.async {
                    hasCompletedOnboardingV2 = false
                }
            }
        } message: {
            Text("You'll see the introduction screens again the next time you launch the app.")
        }
        .alert("Restart Yap to Apply Language", isPresented: $showLanguageRestartAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Your language change will take full effect after you quit and reopen Yap.")
        }
    }

    private var restoreShortcutsMessage: String {
        guard !pendingShortcutRestore.isEmpty else {
            return String(localized: "Your shortcuts already match the defaults.")
        }
        let notSet = String(localized: "Not set")
        let lines = pendingShortcutRestore.map {
            "\($0.action.displayName): \($0.from?.displayString ?? notSet) → \($0.to?.displayString ?? notSet)"
        }
        return lines.joined(separator: "\n") + "\n\n" + String(localized: "Shortcuts for individual modes are not changed.")
    }

    private static let defaultCancelRecordingShortcut = Shortcut.key(
        keyCode: UInt16(kVK_Escape),
        modifierFlags: []
    )

    @ViewBuilder
    private func shortcutModePicker(binding: Binding<RecordingShortcutManager.Mode>) -> some View {
        Picker("", selection: binding) {
            ForEach(RecordingShortcutManager.Mode.allCases, id: \.self) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .labelsHidden()
        .fixedSize()
    }
}

extension Text {
    func settingsDescription() -> some View {
        self
            .font(AppTheme.font(.footnote))
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
