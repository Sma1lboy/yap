import SwiftUI

struct AudioFileRow: View {
    @ObservedObject var item: AudioFileQueueItem
    let isExpanded: Bool
    let onToggleExpand: () -> Void
    let onRemove: () -> Void
    let onRetry: () -> Void

    @State private var selectedTab: TranscriptionTab = .original

    private var displayText: String {
        switch selectedTab {
        case .original:
            return item.transcription?.text ?? ""
        case .enhanced:
            return item.transcription?.enhancedText ?? ""
        }
    }

    /// Text for copy/save — matches visible content regardless of expansion state.
    private var actionText: String {
        if isExpanded {
            return displayText
        }
        return item.transcription?.enhancedText ?? item.transcription?.text ?? ""
    }

    var body: some View {
        switch item.status {
        case .pending:
            pendingRow
        case .processing(let phase):
            processingRow(phase: phase)
        case .completed:
            completedRows
        case .failed(let message):
            failedRow(message: message)
        }
    }

    // MARK: - Pending

    private var pendingRow: some View {
        HStack {
            Image(systemName: "clock")
                .foregroundColor(.secondary)

            Text(item.filename)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Text("Waiting")
                .font(.caption)
                .foregroundColor(.secondary)

            Button {
                onRemove()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove")
            .accessibilityLabel("Remove")
        }
    }

    // MARK: - Processing

    private func processingRow(phase: QueueItemStatus.ProcessingPhase) -> some View {
        HStack {
            ProgressView()
                .scaleEffect(0.5)
                .frame(width: 16, height: 16)

            Text(item.filename)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Text(LocalizedStringKey(phase.rawValue))
                .font(.caption)
                .foregroundColor(AppTheme.Accent.text)
        }
    }

    // MARK: - Completed

    @ViewBuilder
    private var completedRows: some View {
        HStack {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(AppTheme.Status.positive)

            Text(item.filename)
                .foregroundColor(.primary)
                .lineLimit(1)
                .truncationMode(.middle)

            if !isExpanded, let transcription = item.transcription {
                Text(transcription.enhancedText ?? transcription.text)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if let transcription = item.transcription {
                HStack(spacing: AppTheme.Spacing.half) {
                    CopyIconButton(textToCopy: actionText)
                    SaveIconButton(
                        textToSave: actionText,
                        suggestedBaseName: item.url.deletingPathExtension().lastPathComponent
                    )
                }

                if transcription.duration > 0 {
                    Text(formatDuration(transcription.duration))
                        .font(.caption.weight(.medium))
                        .foregroundColor(.secondary)
                }
            }

            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundColor(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .animation(.easeInOut(duration: 0.2), value: isExpanded)
        }
        .contentShape(Rectangle())
        .onTapGesture { onToggleExpand() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(isExpanded ? LocalizedStringKey("Collapse") : "Expand")
        .accessibilityAction { onToggleExpand() }

        if isExpanded, let transcription = item.transcription {
            if transcription.enhancedText != nil {
                HStack(spacing: AppTheme.Spacing.x1) {
                    tabButton(tab: .original)
                    tabButton(tab: .enhanced)
                    Spacer()
                }
            }

            ScrollView {
                MarkdownContentView(
                    displayText,
                    fontSize: 14,
                    foregroundColor: AppTheme.Text.primary
                )
            }
            .frame(maxHeight: 350)

            HStack(spacing: AppTheme.Spacing.x3) {
                if let model = transcription.transcriptionModelName {
                    Label(model, systemImage: "cpu")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if let prompt = transcription.promptName {
                    Label(prompt, systemImage: "sparkles")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
        }
    }

    private func tabButton(tab: TranscriptionTab) -> some View {
        Button {
            selectedTab = tab
        } label: {
            Text(LocalizedStringKey(tab.rawValue))
                .font(.subheadline.weight(selectedTab == tab ? .semibold : .regular))
                .foregroundColor(selectedTab == tab ? AppTheme.Accent.text : AppTheme.Text.secondary)
                .padding(.horizontal, AppTheme.Spacing.x3)
                .padding(.vertical, AppTheme.Spacing.x1)
                .background(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.small, style: .continuous)
                        .fill(selectedTab == tab ? AppTheme.Accent.fill : Color.clear)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Failed

    private func failedRow(message: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundColor(AppTheme.Status.error)

            VStack(alignment: .leading, spacing: AppTheme.Spacing.half) {
                Text(item.filename)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(message)
                    .font(.caption)
                    .foregroundColor(AppTheme.Status.error.opacity(0.80))
                    .lineLimit(2)
            }

            Spacer()

            Button {
                onRetry()
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(.bordered)
            .help("Retry")
            .accessibilityLabel("Retry")
            .controlSize(.small)
        }
    }

    // MARK: - Helpers

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
