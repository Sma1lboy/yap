import SwiftUI

struct VoiceInkButton: View {
    let title: LocalizedStringKey
    let action: () -> Void
    var isDisabled: Bool = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .foregroundColor(AppTheme.Text.onAccent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, AppTheme.Spacing.x3)
                .background(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.control)
                        .fill(isDisabled ? AppTheme.Accent.disabled : AppTheme.Accent.primary)
                )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }
}

struct ModeEmptyStateView: View {
    let action: () -> Void

    var body: some View {
        VStack(spacing: AppTheme.Spacing.x4) {
            Image(systemName: "bolt.circle.fill")
                .font(AppTheme.font(.display))
                .foregroundColor(.secondary)

            Text("No Modes")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Add customized modes for different contexts")
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            VoiceInkButton(
                title: "Add New Mode",
                action: action
            )
            .frame(maxWidth: 250)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ModeConfigurationsGrid: View {
    @ObservedObject var modeManager: ModeManager
    let onEditConfig: (ModeConfig) -> Void
    @EnvironmentObject var enhancementService: AIEnhancementService

    var body: some View {
        LazyVStack(spacing: AppTheme.Spacing.x3) {
            ForEach($modeManager.configurations) { $config in
                ConfigurationRow(
                    config: $config,
                    isEditing: false,
                    modeManager: modeManager,
                    onEditConfig: onEditConfig
                )
            }
        }
    }
}

struct DefaultModeIndicator: View {
    var body: some View {
        HStack(spacing: AppTheme.Spacing.x1) {
            Image(systemName: "checkmark.seal.fill")
                .font(AppTheme.font(.caption, .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.primary)

            Text("Default")
                .font(AppTheme.font(.caption, .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.leading, AppTheme.Spacing.x2)
        .padding(.trailing, AppTheme.Spacing.x2)
        .frame(height: 24)
        .background {
            Capsule()
                .fill(AppTheme.Surface.card)
        }
        .overlay {
            Capsule()
                .strokeBorder(AppTheme.Border.control, lineWidth: 0.5)
        }
        .contentShape(Capsule())
        .help("Default mode is used when no app or website matches")
    }
}

private struct ModeShortcutIndicator: View {
    let modeID: UUID
    @State private var shortcut: Shortcut?

    private var action: ShortcutAction {
        .mode(modeID)
    }

    init(modeID: UUID) {
        self.modeID = modeID
        _shortcut = State(initialValue: ShortcutStore.shortcut(for: .mode(modeID)))
    }

    var body: some View {
        Group {
            if let shortcut {
                ShortcutVisualization(shortcut: shortcut, isRecording: false, isCompact: true)
                    .help("Mode shortcut: \(shortcut.displayString)")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Mode shortcut: \(shortcut.displayString)")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: ShortcutStore.shortcutDidChange)) { notification in
            guard let changedAction = notification.object as? ShortcutAction,
                changedAction == action
            else { return }
            shortcut = ShortcutStore.shortcut(for: action)
        }
    }
}

struct ConfigurationRow: View {
    private struct TranscriptionModelMetadata {
        let label: String
        let isWarning: Bool
    }

    @Binding var config: ModeConfig
    let isEditing: Bool
    let modeManager: ModeManager
    let onEditConfig: (ModeConfig) -> Void
    @EnvironmentObject var enhancementService: AIEnhancementService
    @EnvironmentObject var transcriptionModelManager: TranscriptionModelManager
    @State private var isHovering = false
    @State private var isShowingDeleteConfirmation = false
    @State private var deletionCandidate: ModeConfig?

    private let maxAppIconsToShow = 5

    private var selectedPrompt: CustomPrompt? {
        guard let promptId = config.selectedPrompt,
            let uuid = UUID(uuidString: promptId)
        else { return nil }
        return enhancementService.allPrompts.first { $0.id == uuid }
    }

    private var transcriptionModelMetadata: TranscriptionModelMetadata {
        switch ModeRuntimeResolver.transcriptionModelResolution(
            mode: config,
            transcriptionModelManager: transcriptionModelManager
        ) {
        case .available(_, let model):
            return TranscriptionModelMetadata(
                label: model.displayName,
                isWarning: false
            )
        case .noMode, .noSelection, .modelNotFound, .unavailable:
            return TranscriptionModelMetadata(
                label: String(localized: "Unavailable"),
                isWarning: true
            )
        }
    }

    private var selectedLanguage: String? {
        if let langCode = config.selectedLanguage {
            if langCode == "auto" { return String(localized: "Auto") }
            if langCode == "en" { return String(localized: "English") }

            if let modelName = config.selectedTranscriptionModelName,
                let model = TranscriptionModelRegistry.model(
                    forSelectionKey: modelName,
                    in: transcriptionModelManager.allAvailableModels
                ),
                let langName = TranscriptionLanguageSupport.languages(
                    for: model, realtimeEnabled: config.isRealtimeTranscriptionEnabled)[langCode]
            {
                return langName
            }
            return langCode.uppercased()
        }
        return "Default"
    }

    private var appCount: Int { return config.allAppConfigs.count }
    private var websiteCount: Int { return config.allURLConfigs.count }

    private var websiteText: String {
        if websiteCount == 0 { return "" }
        return String(localized: "\(websiteCount) Websites")
    }

    private var appText: String {
        if appCount == 0 { return "" }
        return String(localized: "\(appCount) Apps")
    }

    private var extraAppsCount: Int {
        return max(0, appCount - maxAppIconsToShow)
    }

    private var visibleAppConfigs: [AppConfig] {
        return Array(config.allAppConfigs.prefix(maxAppIconsToShow))
    }

    @ViewBuilder private var modeActions: some View {
        Button {
            onEditConfig(config)
        } label: {
            Text("Edit")
        }

        Button {
            modeManager.duplicateConfiguration(with: config.id)
        } label: {
            Text("Duplicate")
        }

        Divider()

        Button(role: .destructive) {
            deletionCandidate = config
            isShowingDeleteConfirmation = true
        } label: {
            Text("Delete")
        }
        .disabled(config.isDefault)
    }

    private var editModeButton: some View {
        Button {
            onEditConfig(config)
        } label: {
            Text("Edit")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, AppTheme.Spacing.x2)
                .padding(.vertical, AppTheme.Spacing.half)
                .background(
                    Capsule()
                        .fill(AppTheme.Surface.control)
                )
                .overlay(
                    Capsule()
                        .stroke(AppTheme.Border.control, lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .help("Edit mode")
        .accessibilityLabel("Edit mode")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: AppTheme.Spacing.x3) {
                // A Button, not a tap gesture, so Edit is reachable with the keyboard and VoiceOver.
                Button {
                    onEditConfig(config)
                } label: {
                    HStack(spacing: AppTheme.Spacing.x3) {
                        ZStack {
                            ModeIconView(icon: config.icon, size: config.icon.kind == .emoji ? 20 : 16)
                        }
                        .frame(width: 40, height: 40)
                        .background(
                            AppCardBackground(isSelected: false, cornerRadius: AppTheme.Radius.pill)
                        )

                        VStack(alignment: .leading, spacing: AppTheme.Spacing.x1) {
                            Text(config.name)
                                .font(AppTheme.font(.headline, .semibold))
                                .lineLimit(1)
                                .truncationMode(.tail)

                            HStack(spacing: AppTheme.Spacing.x3) {
                                if appCount > 0 {
                                    HStack(spacing: AppTheme.Spacing.x1) {
                                        Image(systemName: "app.fill")
                                            .font(AppTheme.font(.micro))
                                        Text(appText)
                                            .font(.caption2)
                                    }
                                }

                                if websiteCount > 0 {
                                    HStack(spacing: AppTheme.Spacing.x1) {
                                        Image(systemName: "globe")
                                            .font(AppTheme.font(.micro))
                                        Text(websiteText)
                                            .font(.caption2)
                                    }
                                }
                            }
                            .padding(.top, AppTheme.Spacing.half)
                            .foregroundColor(.secondary)
                        }

                        Spacer()

                        if config.isDefault {
                            DefaultModeIndicator()
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Edit mode")

                if !config.isDefault {
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { config.isEnabled },
                            set: { newValue in
                                if newValue {
                                    modeManager.enableConfiguration(with: config.id)
                                } else {
                                    modeManager.disableConfiguration(with: config.id)
                                }
                            }
                        )
                    )
                    .toggleStyle(SwitchToggleStyle(tint: AppTheme.Accent.primary))
                    .labelsHidden()
                    .accessibilityLabel(String(format: String(localized: "Enable %@"), config.name))
                }
            }
            .padding(.vertical, AppTheme.Spacing.x3)
            .padding(.horizontal, AppTheme.Spacing.x4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppMaterialCardBackground.fill)

            Divider()

            HStack(spacing: AppTheme.Spacing.x2) {
                let modelMetadata = transcriptionModelMetadata
                HStack(spacing: AppTheme.Spacing.x1) {
                    Image(systemName: "waveform")
                        .font(AppTheme.font(.micro))
                    Text(modelMetadata.label)
                        .font(.caption)
                }
                .foregroundStyle(modelMetadata.isWarning ? AppTheme.Status.error : AppTheme.Text.primary)
                .padding(.horizontal, AppTheme.Spacing.x2)
                .padding(.vertical, AppTheme.Spacing.half)
                .background(
                    Capsule()
                        .fill(
                            modelMetadata.isWarning
                                ? AppTheme.Status.errorFill : AppTheme.Surface.control)
                )
                .overlay(
                    Capsule()
                        .stroke(
                            modelMetadata.isWarning
                                ? AppTheme.Status.error.opacity(0.40) : AppTheme.Border.control,
                            lineWidth: 0.5
                        )
                )

                if let language = selectedLanguage, language != "Default" {
                    HStack(spacing: AppTheme.Spacing.x1) {
                        Image(systemName: "globe")
                            .font(AppTheme.font(.micro))
                        Text(language)
                            .font(.caption)
                    }
                    .padding(.horizontal, AppTheme.Spacing.x2)
                    .padding(.vertical, AppTheme.Spacing.half)
                    .background(
                        Capsule()
                            .fill(AppTheme.Surface.control)
                    )
                    .overlay(
                        Capsule()
                            .stroke(AppTheme.Border.control, lineWidth: 0.5)
                    )
                }

                if config.isAIEnhancementEnabled,
                    config.selectedAIProvider != AIProvider.localCLI.rawValue,
                    let modelName = config.selectedAIModel,
                    !modelName.isEmpty
                {
                    HStack(spacing: AppTheme.Spacing.x1) {
                        Image(systemName: "cpu")
                            .font(AppTheme.font(.micro))
                        Text(modelName.count > 20 ? String(modelName.prefix(18)) + "..." : modelName)
                            .font(.caption)
                    }
                    .padding(.horizontal, AppTheme.Spacing.x2)
                    .padding(.vertical, AppTheme.Spacing.half)
                    .background(
                        Capsule()
                            .fill(AppTheme.Surface.control)
                    )
                    .overlay(
                        Capsule()
                            .stroke(AppTheme.Border.control, lineWidth: 0.5)
                    )
                }

                if config.outputMode != .paste {
                    HStack(spacing: AppTheme.Spacing.x1) {
                        Image(systemName: config.outputMode.iconName)
                            .font(AppTheme.font(.micro))
                        Text(config.outputMode.displayName)
                            .font(.caption)
                    }
                    .padding(.horizontal, AppTheme.Spacing.x2)
                    .padding(.vertical, AppTheme.Spacing.half)
                    .background(
                        Capsule()
                            .fill(AppTheme.Surface.control)
                    )
                    .overlay(
                        Capsule()
                            .stroke(AppTheme.Border.control, lineWidth: 0.5)
                    )
                }

                if config.isAIEnhancementEnabled {
                    HStack(spacing: AppTheme.Spacing.x1) {
                        Image(systemName: "sparkles")
                            .font(AppTheme.font(.micro))
                        Text(
                            config.selectedAIProvider == AIProvider.voiceInkRefine.rawValue
                                ? VoiceInkRefineService.providerName
                                : selectedPrompt?.title ?? "AI"
                        )
                            .font(.caption)
                    }
                    .padding(.horizontal, AppTheme.Spacing.x2)
                    .padding(.vertical, AppTheme.Spacing.half)
                    .background(
                        Capsule()
                            .fill(AppTheme.Surface.control)
                    )
                    .overlay(
                        Capsule()
                            .stroke(AppTheme.Border.control, lineWidth: 0.5)
                    )
                }

                ModeShortcutIndicator(modeID: config.id)

                Spacer()

                if isHovering {
                    editModeButton
                        .transition(.opacity)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                onEditConfig(config)
            }
            .padding(.vertical, AppTheme.Spacing.x2)
            .padding(.horizontal, AppTheme.Spacing.x4)
            .background(AppTheme.Surface.card)
        }
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.panel))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.panel)
                .stroke(
                    AppMaterialCardBackground.border(for: isEditing),
                    lineWidth: AppMaterialCardBackground.lineWidth(for: isEditing)
                )
        }
        .opacity(config.isEnabled ? 1.0 : 0.70)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
        .contextMenu {
            modeActions
        }
        .confirmationDialog(
            "Delete Mode?",
            isPresented: $isShowingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let deletionCandidate {
                    _ = modeManager.removeConfiguration(with: deletionCandidate.id)
                }
                deletionCandidate = nil
            }
            Button("Cancel", role: .cancel) {
                deletionCandidate = nil
            }
        } message: {
            if let deletionCandidate {
                Text(
                    String(
                        format: String(localized: "Are you sure you want to delete '%@'? This action cannot be undone."),
                        deletionCandidate.name
                    )
                )
            }
        }
    }

}

struct ModeAppIcon: View {
    let bundleId: String

    var body: some View {
        if let icon = TriggerAppIconCache.shared.icon(for: bundleId) {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 20, height: 20)
        } else {
            Image(systemName: "app.fill")
                .font(AppTheme.font(.callout))
                .foregroundColor(.secondary)
                .frame(width: 20, height: 20)
        }
    }
}

struct AppGridItem: View {
    let app: (url: URL, name: String, bundleId: String, icon: NSImage)
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: AppTheme.Spacing.x2) {
                Image(nsImage: app.icon)
                    .resizable()
                    .frame(width: 40, height: 40)
                    .cornerRadius(8)
                    .shadow(color: Color(NSColor.shadowColor).opacity(0.1), radius: 2, x: 0, y: 1)
                Text(app.name)
                    .font(AppTheme.font(.micro))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(height: 28)
            }
            .frame(width: 80, height: 80)
            .padding(AppTheme.Spacing.x2)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.control)
                    .fill(isSelected ? AppTheme.Accent.fillSubtle : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.control)
                    .stroke(isSelected ? AppTheme.Accent.primary : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
