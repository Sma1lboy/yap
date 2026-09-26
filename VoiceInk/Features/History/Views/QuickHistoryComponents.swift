import AppKit
import SwiftData
import SwiftUI

struct QuickHistoryDetailActionBar: View {
    let transcription: Transcription
    let audioURL: URL?
    let isInfoPresented: Bool
    let onToggleInfo: () -> Void
    let onPaste: () -> Void
    let onTranscriptionUpdated: (Transcription) -> Void

    @EnvironmentObject private var engine: VoiceInkEngine
    @EnvironmentObject private var enhancementService: AIEnhancementService
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var modeManager = ModeManager.shared

    @State private var isShowingModes = false
    @State private var isShowingPrompts = false
    @State private var isWorking = false
    @State private var selectedPromptOverride: CustomPrompt?

    private var selectedMode: ModeConfig? {
        modeManager.currentEffectiveConfiguration
    }

    private var enhancementConfiguration: EnhancementRuntimeConfiguration? {
        guard let aiService = enhancementService.getAIService() else { return nil }
        return ModeRuntimeResolver.currentEnhancementConfiguration(
            mode: selectedMode,
            enhancementService: enhancementService,
            aiService: aiService
        )
    }

    private var selectedPromptTitle: String {
        selectedPromptOverride?.title
            ?? transcription.promptName
            ?? enhancementConfiguration?.prompt?.title
            ?? String(localized: "Select Prompt")
    }

    var body: some View {
        HStack(spacing: AppTheme.Spacing.x2) {
            modeButton
            promptButton
            retryButton
            finderButton
            infoButton
            Spacer(minLength: 8)
            pasteButton
        }
        .padding(.horizontal, AppTheme.Spacing.x3)
        .frame(height: 44)
        .onChange(of: transcription.id) { _, _ in
            selectedPromptOverride = nil
        }
    }

    private var modeButton: some View {
        Button {
            isShowingModes.toggle()
        } label: {
            actionLabel(title: selectedMode?.name ?? String(localized: "Select Mode")) {
                if let selectedMode {
                    ModeIconView(
                        icon: selectedMode.icon,
                        size: selectedMode.icon.kind == .emoji ? 13 : 11,
                        color: AppTheme.Text.primary
                    )
                    .frame(width: 16)
                } else {
                    Image(systemName: "square.grid.2x2")
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(isWorking)
        .popover(isPresented: $isShowingModes, arrowEdge: .bottom) {
            ModePopover(selectedModeId: selectedMode?.id) { mode in
                modeManager.setActiveConfiguration(mode)
                isShowingModes = false
                retranscribe(using: mode)
            }
        }
        .help("Select a mode and retranscribe")
    }

    private var promptButton: some View {
        Button {
            isShowingPrompts.toggle()
        } label: {
            actionLabel(title: selectedPromptTitle) {
                Image(systemName: "wand.and.stars")
            }
        }
        .buttonStyle(.plain)
        .disabled(isWorking)
        .popover(isPresented: $isShowingPrompts, arrowEdge: .bottom) {
            promptPopover
        }
        .help("Select a prompt and enhance")
    }

    private var pasteButton: some View {
        Button(action: onPaste) {
            HStack(spacing: AppTheme.Spacing.x2) {
                Text("Paste Text")
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Text("↵")
                    .font(AppTheme.font(.micro, .medium, design: .rounded))
                    .foregroundStyle(AppTheme.Text.muted)
                    .padding(.horizontal, AppTheme.Spacing.x1)
                    .padding(.vertical, AppTheme.Spacing.x1)
                    .background(AppTheme.Surface.controlActive, in: RoundedRectangle(cornerRadius: AppTheme.Radius.small))
            }
            .font(AppTheme.font(.caption, .medium))
            .foregroundStyle(AppTheme.Text.secondary)
            .padding(.horizontal, AppTheme.Spacing.x3)
            .frame(minWidth: 112)
            .frame(height: 32)
            .fixedSize(horizontal: true, vertical: false)
            .background(QuickPanelButtonBackground())
        }
        .buttonStyle(.plain)
        .help("Paste enhanced text when available, otherwise paste the original transcription")
    }

    private var retryButton: some View {
        Button {
            guard let selectedMode else {
                showError(String(localized: "No mode selected"))
                return
            }
            retranscribe(using: selectedMode)
        } label: {
            Group {
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(AppTheme.font(.footnote, .medium))
                }
            }
            .foregroundStyle(AppTheme.Text.secondary)
            .frame(width: 34, height: 32)
            .background(QuickPanelButtonBackground())
        }
        .buttonStyle(.plain)
        .disabled(isWorking || audioURL == nil)
        .help("Retranscribe with the selected mode")
        .accessibilityLabel("Retranscribe with the selected mode")
    }

    private var finderButton: some View {
        Button {
            guard let audioURL else { return }
            NSWorkspace.shared.selectFile(
                audioURL.path,
                inFileViewerRootedAtPath: audioURL.deletingLastPathComponent().path
            )
        } label: {
            Image(systemName: "folder")
                .font(AppTheme.font(.footnote, .medium))
                .foregroundStyle(AppTheme.Text.secondary)
                .frame(width: 34, height: 32)
                .background(QuickPanelButtonBackground())
        }
        .buttonStyle(.plain)
        .disabled(audioURL == nil)
        .help("Show recording in Finder")
        .accessibilityLabel("Show recording in Finder")
    }

    private var infoButton: some View {
        Button(action: onToggleInfo) {
            Image(systemName: "info.circle")
                .font(AppTheme.font(.footnote, .medium))
                .foregroundStyle(AppTheme.Text.secondary)
                .frame(width: 34, height: 32)
                .background(QuickPanelButtonBackground(isSelected: isInfoPresented))
        }
        .buttonStyle(.plain)
        .help(isInfoPresented ? LocalizedStringKey("Hide transcription info") : "Show transcription info")
        .accessibilityLabel(isInfoPresented ? LocalizedStringKey("Hide transcription info") : "Show transcription info")
    }

    private func actionLabel<Icon: View>(title: String, @ViewBuilder icon: () -> Icon) -> some View {
        HStack(spacing: AppTheme.Spacing.x2) {
            icon()
            Text(title)
                .lineLimit(1)
                .truncationMode(.tail)
            Image(systemName: "chevron.down")
                .font(AppTheme.font(.micro, .semibold))
                .foregroundStyle(AppTheme.Text.muted)
        }
        .font(AppTheme.font(.caption, .medium))
        .foregroundStyle(AppTheme.Text.secondary)
        .padding(.horizontal, AppTheme.Spacing.x3)
        .frame(maxWidth: 140)
        .frame(height: 32)
        .clipped()
        .background(QuickPanelButtonBackground())
        .fixedSize(horizontal: true, vertical: false)
    }

    private var promptPopover: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.x2) {
            Text("Select Prompt")
                .font(AppTheme.font(.body, .semibold))
                .padding(.horizontal)
                .padding(.top, AppTheme.Spacing.x2)

            Divider()

            ScrollView {
                let prompts = enhancementService.allPrompts
                let promptsUnavailable = enhancementConfiguration?.provider == .voiceInkRefine

                VStack(alignment: .leading, spacing: AppTheme.Spacing.x1) {
                    if promptsUnavailable {
                        Text("Custom prompts aren't available with Yap Refine. Select another mode first.")
                            .font(AppTheme.font(.footnote))
                            .foregroundStyle(AppTheme.Text.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, AppTheme.Spacing.x2)
                            .padding(.bottom, AppTheme.Spacing.x2)
                    }

                    if prompts.isEmpty {
                        Text("No Prompts Available")
                            .font(AppTheme.font(.body))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, AppTheme.Spacing.x4)
                    } else {
                        ForEach(prompts) { prompt in
                            EnhancementPromptRow(
                                prompt: prompt,
                                isSelected: enhancementConfiguration?.prompt?.id == prompt.id,
                                isDisabled: promptsUnavailable,
                                action: {
                                    isShowingPrompts = false
                                    selectedPromptOverride = prompt
                                    enhance(using: prompt)
                                }
                            )
                            .disabled(promptsUnavailable)
                        }
                    }
                }
                .padding(.horizontal)
            }
            .scrollIndicators(.never)
        }
        .frame(width: 230)
        .frame(maxHeight: 340)
        .padding(.vertical, AppTheme.Spacing.x2)
        .background(AppTheme.Surface.window)
        .popoverAppAppearance()
    }

    private func retranscribe(using mode: ModeConfig) {
        guard let audioURL else {
            showError(String(localized: "Audio file is unavailable"))
            return
        }
        guard let configuration = ModeRuntimeResolver.transcriptionConfiguration(
            mode: mode,
            transcriptionModelManager: engine.transcriptionModelManager
        ) else {
            showError(String(localized: "No transcription model selected"))
            return
        }

        isWorking = true
        let service = AudioTranscriptionService(modelContext: modelContext, engine: engine)

        Task {
            do {
                let result = try await service.retranscribeAudio(
                    from: audioURL,
                    using: configuration.model,
                    mode: mode
                )
                await MainActor.run {
                    isWorking = false
                    if let failure = result.enhancementFailure {
                        NotificationManager.shared.showNotification(
                            title: EnhancementFailureFormatter.transcriptionSavedMessage(description: failure),
                            type: .warning
                        )
                    } else {
                        NotificationManager.shared.showNotification(
                            title: String(localized: "Retranscription successful"),
                            type: .success,
                            duration: 1.0
                        )
                    }
                    onTranscriptionUpdated(result.transcription)
                }
            } catch {
                await MainActor.run {
                    isWorking = false
                    showError(
                        error.localizedDescription.isEmpty
                            ? String(localized: "Retranscription failed")
                            : error.localizedDescription
                    )
                }
            }
        }
    }

    private func enhance(using prompt: CustomPrompt) {
        guard let baseConfiguration = enhancementConfiguration else {
            selectedPromptOverride = nil
            showError(String(localized: "AI Enhancement is not enabled or configured"))
            return
        }

        isWorking = true
        let configuration = baseConfiguration.replacingPrompt(prompt)

        Task {
            do {
                transcription.aiEnhancementModelName =
                    configuration.modelName ?? configuration.provider?.defaultModel
                transcription.promptName = configuration.prompt?.title
                let result = try await enhancementService.enhance(
                    transcription.text,
                    configuration: configuration
                )
                await MainActor.run {
                    transcription.enhancedText = result.text
                    transcription.aiEnhancementModelName =
                        configuration.modelName ?? configuration.provider?.defaultModel
                    transcription.promptName =
                        result.promptName ?? configuration.prompt?.title
                    transcription.enhancementDuration = result.duration
                    transcription.aiRequestSystemMessage = result.systemMessage
                    transcription.aiRequestUserMessage = result.userMessage
                    do {
                        try modelContext.save()
                    } catch {
                        modelContext.rollback()
                        selectedPromptOverride = nil
                        isWorking = false
                        showError(
                            error.localizedDescription.isEmpty
                                ? String(localized: "Could not save re-enhancement")
                                : error.localizedDescription
                        )
                        return
                    }
                    selectedPromptOverride = nil
                    isWorking = false
                    NotificationManager.shared.showNotification(
                        title: String(localized: "Re-enhancement successful"),
                        type: .success,
                        duration: 1.0
                    )
                }
            } catch {
                await MainActor.run {
                    selectedPromptOverride = nil
                    isWorking = false
                    let description = EnhancementFailureFormatter.description(for: error)
                    showError(
                        EnhancementFailureFormatter.reEnhancementMessage(description: description)
                    )
                }
            }
        }
    }

    private func showError(_ title: String) {
        NotificationManager.shared.showNotification(title: title, type: .error, duration: 3.0)
    }
}

struct QuickHistoryWindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        DraggableAreaView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DraggableAreaView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }

        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}

struct QuickHistoryRow: View {
    let transcription: Transcription
    let isSelected: Bool
    let onSelect: () -> Void
    let onPaste: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: AppTheme.Spacing.x3) {
                Image(systemName: "bubble.left")
                    .font(AppTheme.font(.title3, .medium))
                    .foregroundStyle(AppTheme.Text.primary)
                    .frame(width: 26)

                Text(transcription.preferredHistoryText)
                    .font(AppTheme.font(.body))
                    .foregroundStyle(AppTheme.Text.primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if transcription.hasEnhancedHistoryText {
                    enhancedBadge
                } else {
                    Text(transcription.timestamp, format: .relative(presentation: .named))
                        .font(AppTheme.font(.micro))
                        .foregroundStyle(AppTheme.Text.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }

                if let modelName = transcription.transcriptionModelName, !modelName.isEmpty {
                    modelBadge(modelName)
                }
            }
            .padding(.horizontal, AppTheme.Spacing.x3)
            .frame(height: 46)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous)
                    .fill(isSelected ? AppTheme.Selection.fill : (isHovered ? AppTheme.Surface.subtle : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            TapGesture(count: 2)
                .onEnded(onPaste)
        )
        .onHover { isHovered = $0 }
        .accessibilityLabel(transcription.hasEnhancedHistoryText ? "Enhanced transcription" : "Original transcription")
        .accessibilityValue(transcription.preferredHistoryText)
        .accessibilityHint("Selects this transcription. Double-click to paste.")
    }

    private var enhancedBadge: some View {
        Text("Enhanced")
            .font(AppTheme.font(.micro, .medium))
            .foregroundStyle(AppTheme.Text.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, AppTheme.Spacing.x2)
            .frame(maxWidth: 64)
            .frame(height: 24)
            .background(AppTheme.Surface.controlActive, in: RoundedRectangle(cornerRadius: AppTheme.Radius.small))
    }

    private func modelBadge(_ modelName: String) -> some View {
        Text(modelName)
            .font(AppTheme.font(.micro, .medium))
            .foregroundStyle(AppTheme.Text.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, AppTheme.Spacing.x2)
            .frame(maxWidth: 84)
            .frame(height: 24)
            .background(AppTheme.Surface.controlActive, in: RoundedRectangle(cornerRadius: AppTheme.Radius.small))
    }
}
