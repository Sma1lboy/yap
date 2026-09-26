import AppKit
import SwiftData
import SwiftUI

struct QuickHistoryView: View {
    @ObservedObject var viewModel: QuickHistoryViewModel
    let onPaste: (Transcription) -> Void
    let onDismiss: () -> Void

    @FocusState private var isSearchFocused: Bool

    private var hasSearchQuery: Bool {
        !viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.isShowingDetail {
                detailView
            } else {
                historyView
            }
        }
        .frame(width: 680, height: 470)
        .background {
            VisualEffectView(material: .sidebar, blendingMode: .behindWindow)
            AppTheme.Surface.window.opacity(0.50)
        }
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous)
                .strokeBorder(AppTheme.Border.control.opacity(0.55), lineWidth: 1)
        }
        .onAppear {
            DispatchQueue.main.async {
                isSearchFocused = true
            }
        }
        .onChange(of: viewModel.isShowingDetail) { _, isShowingDetail in
            isSearchFocused = !isShowingDetail
            if !isShowingDetail {
                viewModel.isShowingInfo = false
            }
        }
    }

    private var historyView: some View {
        QuickPanelScaffold {
            if viewModel.filteredTranscriptions.isEmpty {
                emptyState
            } else {
                resultsList
            }
        } header: {
            searchHeader
        } footer: {
            keyboardHints
        }
    }

    private var searchHeader: some View {
        HStack(spacing: AppTheme.Spacing.x4) {
            TextField("Search transcriptions...", text: $viewModel.searchText)
                .textFieldStyle(.plain)
                .font(AppTheme.font(.headline))
                .focused($isSearchFocused)
                .frame(maxWidth: 340)

            if viewModel.isSearching {
                ProgressView()
                    .controlSize(.small)
            }

            QuickHistoryWindowDragArea()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            escapeKeyCap
        }
        .padding(.horizontal, AppTheme.Spacing.x5)
        .frame(height: QuickPanelMetrics.headerHeight)
    }

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: AppTheme.Spacing.x1) {
                    ForEach(viewModel.filteredTranscriptions) { transcription in
                        QuickHistoryRow(
                            transcription: transcription,
                            isSelected: viewModel.selectedID == transcription.id,
                            onSelect: {
                                viewModel.selectedID = transcription.id
                            },
                            onPaste: {
                                onPaste(transcription)
                            }
                        )
                        .id(transcription.id)
                    }
                }
                .padding(AppTheme.Spacing.x2)
                .padding(.top, 58)  // design-exempt: layout offset, not spacing
                .padding(.bottom, 58)  // design-exempt: layout offset, not spacing
            }
            .scrollIndicators(.never)
            .frame(maxWidth: .infinity)
            .onChange(of: viewModel.keyboardSelectionID) { _, selectedID in
                guard let selectedID else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(selectedID, anchor: .center)
                }
            }
        }
    }

    @ViewBuilder
    private var detailView: some View {
        if let transcription = viewModel.selectedTranscription {
            QuickPanelScaffold {
                ScrollView {
                    detailContent(transcription)
                }
                .scrollIndicators(.never)
            } header: {
                detailHeader
            } footer: {
                QuickHistoryDetailActionBar(
                    transcription: transcription,
                    audioURL: audioURL(for: transcription),
                    isInfoPresented: viewModel.isShowingInfo,
                    onToggleInfo: {
                        viewModel.isShowingInfo.toggle()
                    },
                    onPaste: {
                        onPaste(transcription)
                    },
                    onTranscriptionUpdated: { updated in
                        viewModel.reload(selecting: updated)
                    }
                )
            }
            .sidePanel(
                isPresented: Binding(
                    get: { viewModel.isShowingInfo },
                    set: { viewModel.isShowingInfo = $0 }
                ),
                dismissOnExitCommand: false
            ) {
                TranscriptionInfoSidePanel(transcription: transcription) {
                    viewModel.isShowingInfo = false
                }
                .id(transcription.id)
            }
        }
    }

    private func detailContent(_ transcription: Transcription) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.x3) {
            if transcription.hasEnhancedHistoryText {
                detailTextSection("Enhanced", text: transcription.preferredHistoryText, isPrimary: true)
                detailTextSection("Original", text: transcription.text, isPrimary: false)
            } else {
                detailTextSection("Transcription", text: transcription.text, isPrimary: true)
            }

        }
        .padding(AppTheme.Spacing.x4)
        .padding(.top, 54)  // design-exempt: layout offset, not spacing
        .padding(.bottom, 58)  // design-exempt: layout offset, not spacing
    }

    private var detailHeader: some View {
        HStack(spacing: AppTheme.Spacing.x3) {
            Button {
                withAnimation(.easeOut(duration: 0.16)) {
                    viewModel.isShowingDetail = false
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(AppTheme.font(.callout, .semibold))
            }
            .buttonStyle(.plain)
            .help("Back to history")
            .accessibilityLabel("Back to history")

            Text("Transcription Details")
                .font(AppTheme.font(.callout, .semibold))

            Spacer()
            QuickHistoryWindowDragArea()
                .frame(width: 120)
                .frame(maxHeight: .infinity)

            escapeKeyCap
        }
        .padding(.horizontal, AppTheme.Spacing.x5)
        .frame(height: 52)
    }

    private var escapeKeyCap: some View {
        QuickPanelEscapeButton(
            help: "Dismiss",
            action: onDismiss
        )
    }

    private func audioURL(for transcription: Transcription) -> URL? {
        guard let urlString = transcription.audioFileURL,
            let url = URL(string: urlString),
            FileManager.default.fileExists(atPath: url.path)
        else {
            return nil
        }
        return url
    }

    private func detailTextSection(_ title: LocalizedStringKey, text: String, isPrimary: Bool) -> some View {
        Text(text)
            .font(AppTheme.font(.body))
            .foregroundStyle(isPrimary ? AppTheme.Text.primary : AppTheme.Text.secondary)
            .lineSpacing(2)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(AppTheme.Spacing.x3)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous)
                    .fill(isPrimary ? AppTheme.Surface.control : AppTheme.Surface.subtle)
                    .overlay {
                        RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous)
                            .stroke(AppTheme.Border.subtle, lineWidth: 1)
                    }
            )
            .overlay(alignment: .topTrailing) {
                CopyIconButton(
                    textToCopy: text,
                    accessibilityLabel: "Copy text"
                )
                .padding(AppTheme.Spacing.x3)
            }
            .overlay(alignment: .bottomTrailing) {
                if shouldShowTextKind(for: text) {
                    Text(title)
                        .font(AppTheme.font(.micro, .semibold))
                        .foregroundStyle(isPrimary ? AppTheme.Text.primary : AppTheme.Text.secondary)
                        .padding(.horizontal, AppTheme.Spacing.x2)
                        .frame(height: 21)
                        .background(
                            isPrimary ? AppTheme.Surface.controlActive : AppTheme.Surface.subtle,
                            in: RoundedRectangle(cornerRadius: AppTheme.Radius.small)
                        )
                        .padding(AppTheme.Spacing.x3)
                }
            }
    }

    private func shouldShowTextKind(for text: String) -> Bool {
        let font = NSFont.systemFont(ofSize: 13)
        let availableTextWidth: CGFloat = 630
        let renderedBounds = (text as NSString).boundingRect(
            with: NSSize(width: availableTextWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        let lineHeight = font.ascender - font.descender + font.leading
        let renderedLineCount = Int(ceil(renderedBounds.height / lineHeight))
        return renderedLineCount > 3
    }

    private var emptyState: some View {
        VStack(spacing: AppTheme.Spacing.x3) {
            Spacer()
            Image(systemName: hasSearchQuery ? "magnifyingglass" : "text.bubble")
                .font(AppTheme.font(.display))
                .foregroundStyle(AppTheme.Text.muted)
            Text(hasSearchQuery ? "No matching transcriptions" : "No transcriptions yet")
                .font(AppTheme.font(.callout, .medium))
            Text(hasSearchQuery ? "Try another search term." : "Your recent transcriptions will appear here.")
                .font(AppTheme.font(.footnote))
                .foregroundStyle(AppTheme.Text.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var keyboardHints: some View {
        HStack(spacing: AppTheme.Spacing.x3) {
            commandPill("Details", systemImage: nil, shortcut: "⌘↵") {
                if viewModel.selectedTranscription != nil {
                    withAnimation(.easeOut(duration: 0.16)) {
                        viewModel.isShowingDetail = true
                    }
                }
            }

            Spacer()

            commandPill("Paste Text", systemImage: nil, shortcut: "↵") {
                if let transcription = viewModel.selectedTranscription {
                    onPaste(transcription)
                }
            }
        }
        .padding(.horizontal, AppTheme.Spacing.x3)
        .frame(height: 44)
    }

    private func commandPill(
        _ title: LocalizedStringKey,
        systemImage: String?,
        shortcut: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: AppTheme.Spacing.x2) {
                if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Text(shortcut)
                    .font(AppTheme.font(.micro, .medium, design: .rounded))
                    .foregroundStyle(AppTheme.Text.muted)
                    .padding(.horizontal, AppTheme.Spacing.x1)
                    .padding(.vertical, AppTheme.Spacing.x1)
                    .background(AppTheme.Surface.controlActive, in: RoundedRectangle(cornerRadius: AppTheme.Radius.small))
            }
            .font(AppTheme.font(.caption, .medium))
            .foregroundStyle(AppTheme.Text.secondary)
            .padding(.horizontal, AppTheme.Spacing.x3)
            .frame(height: 32)
            .fixedSize(horizontal: true, vertical: false)
            .background(
                QuickPanelButtonBackground()
            )
        }
        .buttonStyle(.plain)
    }
}
