import SwiftUI

struct ModelSettingsPanel: View {
    @State private var selectedTab: ModelSettingsTab = .transcription

    var body: some View {
        VStack(spacing: 0) {
            ModelSettingsTabBar(selection: $selectedTab)

            switch selectedTab {
            case .transcription:
                TranscriptionModelSettingsView()
            case .enhancement:
                EnhancementModelSettingsView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private enum ModelSettingsTab: String, CaseIterable, Identifiable {
    case transcription = "Transcription"
    case enhancement = "Enhancement"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .transcription:
            return "captions.bubble.fill"
        case .enhancement:
            return "sparkles"
        }
    }
}

private struct ModelSettingsTabBar: View {
    @Binding var selection: ModelSettingsTab

    var body: some View {
        HStack(spacing: AppTheme.Spacing.x3) {
            ForEach(ModelSettingsTab.allCases) { tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        selection = tab
                    }
                } label: {
                    HStack(spacing: AppTheme.Spacing.x2) {
                        Image(systemName: tab.systemImage)
                            .font(AppTheme.font(.body, .semibold))
                            .symbolRenderingMode(.hierarchical)

                        Text(LocalizedStringKey(tab.rawValue))
                            .font(AppTheme.font(.callout, selection == tab ? .semibold : .medium))
                    }
                    .foregroundStyle(selection == tab ? Color.primary : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, AppTheme.Spacing.x3)
                    .padding(.vertical, AppTheme.Spacing.x2)
                    .background(
                        AppMaterialCardBackground(isSelected: selection == tab, cornerRadius: AppTheme.Radius.pill)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, AppTheme.Spacing.x5)
        .padding(.vertical, AppTheme.Spacing.x3)
    }
}

private struct TranscriptionModelSettingsView: View {
    @EnvironmentObject private var whisperModelManager: WhisperModelManager

    var body: some View {
        Form {
            WhisperPromptSettingsSection(whisperPrompt: whisperModelManager.whisperPrompt)

            FillerWordsSettingsSection()

            AdvancedModelSettingsSection()
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct WhisperPromptSettingsSection: View {
    @ObservedObject var whisperPrompt: WhisperPrompt
    @State private var promptLanguage = "en"
    @State private var draftPrompt = ""
    @State private var isEditing = false

    private var supportedLanguages: [String: String] {
        LanguageDictionary.forProvider(isMultilingual: true, provider: .whisper)
    }

    private var savedPrompt: String {
        whisperPrompt.getLanguagePrompt(for: promptLanguage)
    }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.x3) {
                Picker("Language", selection: $promptLanguage) {
                    ForEach(sortedLanguages, id: \.key) { code, name in
                        Text(name).tag(code)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .accessibilityLabel("Language")
                .disabled(isEditing)

                if promptLanguage != "auto", isEditing {
                    TextEditor(text: $draftPrompt)
                        .font(AppTheme.font(.body))
                        .padding(AppTheme.Spacing.x2)
                        .frame(height: 72)
                        .scrollContentBackground(.hidden)
                        .background(AppTheme.Surface.control)
                        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous)
                                .stroke(Color.secondary.opacity(0.18))
                        }
                        .accessibilityLabel("Whisper Prompt")

                    HStack(spacing: AppTheme.Spacing.x3) {
                        Spacer()

                        Button("Cancel", role: .cancel) {
                            draftPrompt = savedPrompt
                            isEditing = false
                        }

                        Button("Save") {
                            whisperPrompt.setCustomPrompt(draftPrompt, for: promptLanguage)
                            isEditing = false
                        }
                        .buttonStyle(.appAction(.primary))
                        .keyboardShortcut(.defaultAction)
                    }
                    .controlSize(.small)
                } else if promptLanguage != "auto" {
                    if !savedPrompt.isEmpty {
                        Text(savedPrompt)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Button("Edit") {
                        draftPrompt = savedPrompt
                        isEditing = true
                    }
                }
            }
            .padding(.vertical, AppTheme.Spacing.half)
        } header: {
            HStack(spacing: AppTheme.Spacing.x1) {
                Text("Whisper Prompt")
                InfoTip(
                    LocalizedStringKey(
                        "Only local Whisper models use this. Add example text to guide spelling and style."
                    ),
                    learnMoreURL: "https://cookbook.openai.com/examples/whisper_prompting_guide#comparison-with-gpt-prompting"
                )
            }
        }
        .onAppear {
            selectCurrentTranscriptionLanguage()
        }
        .onChange(of: promptLanguage) { _, _ in
            draftPrompt = savedPrompt
            isEditing = false
        }
    }

    private var sortedLanguages: [(key: String, value: String)] {
        supportedLanguages.sorted { first, second in
            if first.key == "auto" { return true }
            if second.key == "auto" { return false }
            return first.value.localizedCaseInsensitiveCompare(second.value) == .orderedAscending
        }
    }

    private func selectCurrentTranscriptionLanguage() {
        let activeLanguage =
            ModeManager.shared.currentEffectiveConfiguration?.selectedLanguage
            ?? UserDefaults.standard.string(forKey: "SelectedLanguage")
            ?? "en"

        promptLanguage = supportedLanguages[activeLanguage] == nil ? "en" : activeLanguage
    }
}

private struct EnhancementModelSettingsView: View {
    @AppStorage("SkipShortEnhancement") private var isSkipShortEnhancementEnabled = true
    @AppStorage("ShortEnhancementWordThreshold") private var shortEnhancementWordThreshold = 3
    @AppStorage(EnhancementRequestSettings.timeoutKey) private var enhancementTimeoutSeconds =
        EnhancementRequestSettings.defaultTimeoutSeconds
    @AppStorage(EnhancementRequestSettings.retryOnTimeoutKey) private var retryOnTimeout =
        EnhancementRequestSettings.defaultRetryOnTimeout
    @State private var isShortEnhancementExpanded = false

    var body: some View {
        Form {
            Section {
                ExpandableSettingsRow(
                    isExpanded: $isShortEnhancementExpanded,
                    isEnabled: $isSkipShortEnhancementEnabled,
                    label: "Skip short transcriptions",
                    infoMessage:
                        "Automatically skip AI enhancement when the transcription has very few words. Short phrases like \"yes\", \"thank you\", or quick commands don't benefit from enhancement."
                ) {
                    Picker("Minimum words", selection: $shortEnhancementWordThreshold) {
                        ForEach(1...15, id: \.self) { count in
                            Text(String(localized: "\(count) words")).tag(count)
                        }
                    }
                }
                .toggleStyle(.switch)
            } header: {
                Text("Enhancement Settings")
            }

            Section {
                Picker("Timeout duration", selection: $enhancementTimeoutSeconds) {
                    ForEach([3, 5, 7, 10, 15, 20, 30, 40, 50, 60], id: \.self) { seconds in
                        Text(String(format: String(localized: "%d seconds"), seconds)).tag(seconds)
                    }
                }
                .pickerStyle(.menu)

                Picker("On timeout", selection: $retryOnTimeout) {
                    Text("Fail immediately").tag(false)
                    Text("Retry").tag(true)
                }
                .pickerStyle(.menu)
            } header: {
                HStack(spacing: AppTheme.Spacing.x1) {
                    Text("Request Timeout")
                    InfoTip(
                        "Set how long to wait for the AI provider to respond. If no response is received within this duration, you can either fail immediately and paste the original transcription, or retry the request up to 3 attempts."
                    )
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct AdvancedModelSettingsSection: View {
    @AppStorage("IsVADEnabled") private var isVADEnabled = true
    @AppStorage("PrewarmModelOnWake") private var prewarmModelOnWake = true
    @AppStorage(CloudTranscriptionSettings.timeoutKey) private var cloudTimeout =
        CloudTranscriptionSettings.defaultTimeout

    var body: some View {
        Section {
            Toggle(isOn: $isVADEnabled) {
                HStack(spacing: AppTheme.Spacing.x1) {
                    Text("Voice Activity Detection (VAD)")
                    InfoTip("Detect speech segments and filter out silence to improve accuracy of local models.")
                }
            }
            .toggleStyle(.switch)

            Toggle(isOn: $prewarmModelOnWake) {
                HStack(spacing: AppTheme.Spacing.x1) {
                    Text("Prewarm model (Experimental)")
                    InfoTip(
                        "Turn this on if local transcriptions take longer than expected. It prepares the selected model in the background when the app launches or wakes."
                    )
                }
            }
            .toggleStyle(.switch)

            Picker(selection: $cloudTimeout) {
                Text("10 seconds").tag(10)
                Text("30 seconds").tag(30)
                Text("1 minute").tag(60)
                Text("2 minutes").tag(120)
                Text("5 minutes").tag(300)
                Text("10 minutes").tag(600)
                Text("20 minutes").tag(1_200)
                Text("30 minutes").tag(1_800)
            } label: {
                HStack(spacing: AppTheme.Spacing.x1) {
                    Text("Timeout")
                    InfoTip(
                        "Set how long to wait for batch cloud transcription to finish. This does not affect local or realtime transcription."
                    )
                }
            }
            .pickerStyle(.menu)
        } header: {
            Text("Advanced")
        }
    }
}
