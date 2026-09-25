import SwiftData
import SwiftUI

/// Transcription history list. `header` scrolls with the list (Home puts its week panel there).
struct HistoryView<Header: View>: View {
    private struct PaginationCursor {
        let timestamp: Date
        let id: UUID
    }

    private struct DayGroup: Identifiable {
        let id: Date
        var items: [Transcription]
    }

    private let header: Header

    init(@ViewBuilder header: () -> Header) {
        self.header = header()
    }

    @Environment(\.modelContext) private var modelContext
    @State private var searchText = ""
    @State private var expandedId: UUID?
    @State private var selectedTranscriptions: Set<Transcription> = []
    @State private var showDeleteConfirmation = false
    @State private var isPanelPresented = false
    @State private var panelMode: HistoryPanelMode = .info
    @State private var panelTranscriptionId: UUID?
    @State private var displayedTranscriptions: [Transcription] = []
    @State private var isLoading = false
    @State private var hasMoreContent = true
    @State private var paginationCursor: PaginationCursor?
    @State private var isViewCurrentlyVisible = false
    @State private var wordCounts: [UUID: Int] = [:]

    private let exportService = VoiceInkCSVExportService()
    private let pageSize = 20

    @Query(Self.createLatestTranscriptionIndicatorDescriptor()) private var latestTranscriptionIndicator:
        [Transcription]

    private static func createLatestTranscriptionIndicatorDescriptor() -> FetchDescriptor<Transcription> {
        var descriptor = FetchDescriptor<Transcription>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return descriptor
    }

    private func cursorQueryDescriptor(after cursor: PaginationCursor? = nil) -> FetchDescriptor<Transcription> {
        var descriptor = FetchDescriptor<Transcription>(
            sortBy: [
                SortDescriptor(\Transcription.timestamp, order: .reverse),
                SortDescriptor(\Transcription.id, order: .reverse),
            ]
        )

        if !searchText.isEmpty {
            let query = searchText
            if let cursor {
                let cursorTimestamp = cursor.timestamp
                let cursorID = cursor.id
                descriptor.predicate = #Predicate<Transcription> { transcription in
                    (transcription.text.localizedStandardContains(query)
                        || (transcription.enhancedText?.localizedStandardContains(query) ?? false))
                        && (transcription.timestamp < cursorTimestamp
                            || (transcription.timestamp == cursorTimestamp && transcription.id < cursorID))
                }
            } else {
                descriptor.predicate = #Predicate<Transcription> { transcription in
                    transcription.text.localizedStandardContains(query)
                        || (transcription.enhancedText?.localizedStandardContains(query) ?? false)
                }
            }
        } else {
            if let cursor {
                let cursorTimestamp = cursor.timestamp
                let cursorID = cursor.id
                descriptor.predicate = #Predicate<Transcription> { transcription in
                    transcription.timestamp < cursorTimestamp
                        || (transcription.timestamp == cursorTimestamp && transcription.id < cursorID)
                }
            }
        }

        // Fetch one extra row so the UI can determine whether another page exists.
        descriptor.fetchLimit = pageSize + 1

        return descriptor
    }

    private var allSelected: Bool {
        !displayedTranscriptions.isEmpty && displayedTranscriptions.allSatisfy { selectedTranscriptions.contains($0) }
    }

    private var panelTranscription: Transcription? {
        guard let id = panelTranscriptionId else { return nil }
        return displayedTranscriptions.first { $0.id == id }
    }

    private func openPanel(mode: HistoryPanelMode, transcriptionID: UUID? = nil) {
        panelMode = mode
        panelTranscriptionId = transcriptionID

        isPanelPresented = true
    }

    private func closePanel() {
        isPanelPresented = false
        panelMode = .info
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    header
                        .padding(.bottom, 24)

                    topBar

                    if displayedTranscriptions.isEmpty && !isLoading {
                        emptyStateView
                    } else {
                        cardListView
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 28)
                .padding(.bottom, 24)
            }

            if !selectedTranscriptions.isEmpty {
                Divider()
                selectionBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: selectedTranscriptions.isEmpty)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sidePanel(
            isPresented: .init(
                get: { isPanelPresented },
                set: { newValue in
                    if !newValue { closePanel() }
                }
            )
        ) {
            panelContent
        }
        .alert("Delete Selected Items?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                deleteSelectedTranscriptions()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                String(
                    localized:
                        "This action cannot be undone. Are you sure you want to delete \(selectedTranscriptions.count) items?"
                ))
        }
        .onAppear {
            isViewCurrentlyVisible = true
            Task { await loadInitialContent() }
        }
        .onDisappear {
            isViewCurrentlyVisible = false
        }
        .onChange(of: searchText) { _, _ in
            Task {
                resetPagination()
                await loadInitialContent()
            }
        }
        .onChange(of: latestTranscriptionIndicator.first?.id) { oldId, newId in
            guard isViewCurrentlyVisible else { return }
            if newId != oldId {
                Task {
                    resetPagination()
                    await loadInitialContent()
                }
            }
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.system(size: 12))
                TextField("Search transcriptions...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(AppTheme.Surface.card)
            )
            .frame(maxWidth: .infinity)

            Button("Transcribe File…") {
                MainWindowNavigation.shared.navigate(to: .transcribeAudio)
            }
            .help("Transcribe an audio or video file")

            AppIconButton(
                systemName: "gearshape",
                help: "History settings",
                size: 30,
                iconSize: 13,
                cornerRadius: AppTheme.Radius.pill
            ) {
                openPanel(mode: .historySettings)
            }
        }
        .padding(.bottom, 4)
    }

    private var selectionBar: some View {
        HStack(spacing: 16) {
            Text(String(format: String(localized: "%lld selected"), Int64(selectedTranscriptions.count)))
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)

            Spacer()

            Button(action: {
                openPanel(mode: .analysis)
            }) {
                Label("Analyze", systemImage: "chart.bar.xaxis")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)

            Button(action: {
                exportService.exportTranscriptionsToCSV(transcriptions: Array(selectedTranscriptions))
            }) {
                Label("Export", systemImage: "square.and.arrow.up")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)

            Button(action: { showDeleteConfirmation = true }) {
                Label("Delete", systemImage: "trash")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundColor(AppTheme.Status.error.opacity(0.80))

            Divider()
                .frame(height: 16)

            if allSelected {
                Button("Deselect All") {
                    selectedTranscriptions.removeAll()
                }
                .font(.system(size: 12, weight: .medium))
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            } else {
                Button("Select All") {
                    Task { await selectAllTranscriptions() }
                }
                .font(.system(size: 12, weight: .medium))
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(
            AppTheme.Surface.window
                .shadow(color: Color.black.opacity(0.1), radius: 3, y: -2)
        )
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        HStack(spacing: 8) {
            Image(systemName: searchText.isEmpty ? "mic" : "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
            Text(verbatim: emptyStateMessage)
                .font(.system(size: 13))
        }
        .foregroundStyle(AppTheme.Text.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)
    }

    private var emptyStateMessage: String {
        guard searchText.isEmpty else {
            return String(localized: "No results found")
        }
        guard let shortcut = ShortcutStore.shortcut(for: .primaryRecording)?.displayString, !shortcut.isEmpty else {
            return String(localized: "No transcriptions yet")
        }
        return String(format: String(localized: "Press %@ and start talking"), shortcut)
    }

    // MARK: - Card List

    /// Loaded items grouped by calendar day, newest first (items arrive sorted).
    private var dayGroups: [DayGroup] {
        var groups: [DayGroup] = []
        for transcription in displayedTranscriptions {
            let day = Calendar.current.startOfDay(for: transcription.timestamp)
            if groups.last?.id == day {
                groups[groups.count - 1].items.append(transcription)
            } else {
                groups.append(DayGroup(id: day, items: [transcription]))
            }
        }
        return groups
    }

    @ViewBuilder
    private var cardListView: some View {
        let isSelecting = !selectedTranscriptions.isEmpty

        ForEach(dayGroups) { group in
            dayHeader(group)

            ForEach(Array(group.items.enumerated()), id: \.element.id) { index, transcription in
                if index > 0 {
                    Divider()
                        .padding(.leading, 10)
                }

                HistoryCardRow(
                    transcription: transcription,
                    wordCount: wordCounts[transcription.id] ?? 0,
                    isExpanded: expandedId == transcription.id,
                    isChecked: selectedTranscriptions.contains(transcription),
                    isSelecting: isSelecting,
                    onToggleExpand: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            expandedId = expandedId == transcription.id ? nil : transcription.id
                        }
                    },
                    onToggleCheck: { toggleSelection(transcription) },
                    onShowInfo: {
                        openPanel(mode: .info, transcriptionID: transcription.id)
                    }
                )
            }
        }

        if hasMoreContent {
            Button(action: {
                Task { await loadMoreContent() }
            }) {
                HStack(spacing: 8) {
                    if isLoading {
                        ProgressView().controlSize(.small)
                    }
                    Text(isLoading ? "Loading..." : "Load More")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(AppTheme.Text.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isLoading)
        }
    }

    private func dayHeader(_ group: DayGroup) -> some View {
        let words = group.items.reduce(0) { $0 + (wordCounts[$1.id] ?? 0) }

        return HStack(alignment: .firstTextBaseline) {
            Text(verbatim: Self.dayTitle(group.id))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppTheme.Text.primary)

            Spacer()

            Text(
                verbatim: String(localized: "\(Int64(group.items.count)) items") + " \u{00B7} "
                    + String(localized: "\(Int64(words)) words")
            )
            .font(.system(size: 11))
            .monospacedDigit()
            .foregroundStyle(AppTheme.Text.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.top, 24)
        .padding(.bottom, 6)
    }

    private static func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return String(localized: "Today") }
        if calendar.isDateInYesterday(day) { return String(localized: "Yesterday") }
        if calendar.isDate(day, equalTo: Date(), toGranularity: .year) {
            return day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        }
        return day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year())
    }

    // MARK: - Side Panel

    @ViewBuilder
    private var panelContent: some View {
        switch panelMode {
        case .info:
            infoPanelContent
        case .analysis:
            HistoryAnalysisPanelView(
                transcriptions: Array(selectedTranscriptions),
                onClose: {
                    closePanel()
                }
            )
            .id(selectedTranscriptions.count)
        case .historySettings:
            HistorySettingsPanel(onClose: closePanel)
        }
    }

    @ViewBuilder
    private var infoPanelContent: some View {
        if let transcription = panelTranscription {
            TranscriptionInfoSidePanel(transcription: transcription, onClose: closePanel)
                .id(transcription.id)
        } else {
            Color.clear
                .task { closePanel() }
        }
    }

    // MARK: - Data Loading

    @MainActor
    private func loadInitialContent() async {
        isLoading = true
        defer { isLoading = false }

        do {
            paginationCursor = nil
            let items = try modelContext.fetch(cursorQueryDescriptor())
            let page = Array(items.prefix(pageSize))
            displayedTranscriptions = page
            countWords(in: page)
            paginationCursor = page.last.map { PaginationCursor(timestamp: $0.timestamp, id: $0.id) }
            hasMoreContent = items.count > pageSize
        } catch {
            print("Error loading transcriptions: \(error)")
        }
    }

    @MainActor
    private func loadMoreContent() async {
        guard !isLoading, hasMoreContent, let paginationCursor else { return }

        isLoading = true
        defer { isLoading = false }

        do {
            let items = try modelContext.fetch(cursorQueryDescriptor(after: paginationCursor))
            let page = Array(items.prefix(pageSize))
            displayedTranscriptions.append(contentsOf: page)
            countWords(in: page)
            self.paginationCursor = page.last.map { PaginationCursor(timestamp: $0.timestamp, id: $0.id) }
            hasMoreContent = items.count > pageSize
        } catch {
            print("Error loading more transcriptions: \(error)")
        }
    }

    private func countWords(in page: [Transcription]) {
        for transcription in page where wordCounts[transcription.id] == nil {
            wordCounts[transcription.id] = WordCounter.count(in: transcription.enhancedText ?? transcription.text)
        }
    }

    @MainActor
    private func resetPagination() {
        displayedTranscriptions = []
        paginationCursor = nil
        hasMoreContent = true
        isLoading = false
    }

    // MARK: - Selection & Deletion

    private func toggleSelection(_ transcription: Transcription) {
        if selectedTranscriptions.contains(transcription) {
            selectedTranscriptions.remove(transcription)
        } else {
            selectedTranscriptions.insert(transcription)
        }
    }

    private func performDeletion(for transcription: Transcription) {
        if let urlString = transcription.audioFileURL,
            let url = URL(string: urlString),
            FileManager.default.fileExists(atPath: url.path)
        {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                print("Error deleting audio file: \(error.localizedDescription)")
            }
        }

        if expandedId == transcription.id {
            expandedId = nil
        }
        if panelTranscriptionId == transcription.id {
            panelTranscriptionId = nil
            closePanel()
        }

        selectedTranscriptions.remove(transcription)
        modelContext.delete(transcription)
    }

    private func deleteSelectedTranscriptions() {
        for transcription in selectedTranscriptions {
            performDeletion(for: transcription)
        }
        selectedTranscriptions.removeAll()

        Task {
            do {
                try modelContext.save()
                NotificationCenter.default.post(name: .transcriptionDeleted, object: nil)
                await loadInitialContent()
            } catch {
                print("Error saving deletion: \(error.localizedDescription)")
                await loadInitialContent()
            }
        }
    }

    private func selectAllTranscriptions() async {
        do {
            var allDescriptor = FetchDescriptor<Transcription>()

            if !searchText.isEmpty {
                allDescriptor.predicate = #Predicate<Transcription> { transcription in
                    transcription.text.localizedStandardContains(searchText)
                        || (transcription.enhancedText?.localizedStandardContains(searchText) ?? false)
                }
            }

            allDescriptor.propertiesToFetch = [\.id]
            let allTranscriptions = try modelContext.fetch(allDescriptor)
            let visibleIds = Set(displayedTranscriptions.map { $0.id })

            await MainActor.run {
                selectedTranscriptions = Set(displayedTranscriptions)

                for transcription in allTranscriptions {
                    if !visibleIds.contains(transcription.id) {
                        selectedTranscriptions.insert(transcription)
                    }
                }
            }
        } catch {
            print("Error selecting all transcriptions: \(error)")
        }
    }
}

private enum HistoryPanelMode {
    case info
    case analysis
    case historySettings
}

// MARK: - History Card Row

private struct HistoryCardRow: View {
    let transcription: Transcription
    let wordCount: Int
    let isExpanded: Bool
    let isChecked: Bool
    let isSelecting: Bool
    let onToggleExpand: () -> Void
    let onToggleCheck: () -> Void
    let onShowInfo: () -> Void

    @State private var selectedTab: TranscriptionTab = .original
    @State private var didCopyCollapsedText = false
    @State private var isHovering = false

    private var preferredCopyText: String {
        guard let enhancedText = transcription.enhancedText, !enhancedText.isEmpty else {
            return transcription.text
        }
        return enhancedText
    }

    private var displayText: String {
        switch selectedTab {
        case .original:
            return transcription.text
        case .enhanced:
            return transcription.enhancedText ?? ""
        }
    }

    private var hasAudioFile: Bool {
        if let urlString = transcription.audioFileURL,
            let url = URL(string: urlString),
            FileManager.default.fileExists(atPath: url.path)
        {
            return true
        }
        return false
    }

    private var metaText: String {
        var parts: [String] = []
        if transcription.duration > 0 {
            parts.append(Duration.seconds(transcription.duration).formatted(.time(pattern: .minuteSecond)))
        }
        parts.append(String(localized: "\(Int64(wordCount)) words"))
        return parts.joined(separator: " \u{00B7} ")
    }

    private var showsActions: Bool { isHovering || isExpanded }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Keeps its slot so text doesn't shift when the checkbox appears on hover.
            Toggle(
                "",
                isOn: Binding(
                    get: { isChecked },
                    set: { _ in onToggleCheck() }
                )
            )
            .toggleStyle(CircularCheckboxStyle())
            .labelsHidden()
            .padding(.top, -1)
            .opacity(isSelecting || isHovering || isChecked ? 1 : 0)
            .allowsHitTesting(isSelecting || isHovering || isChecked)

            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 6) {
                    metaLine

                    if !isExpanded {
                        Text(preferredCopyText)
                            .font(.system(size: 13))
                            .lineSpacing(3)
                            .lineLimit(3)
                            .foregroundStyle(AppTheme.Text.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { onToggleExpand() }

                if isExpanded {
                    expandedContent
                        .padding(.top, 6)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovering && !isExpanded ? AppTheme.Surface.subtle : Color.clear)
        )
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
        }
    }

    private var metaLine: some View {
        HStack(spacing: 8) {
            Text(transcription.timestamp, format: .dateTime.hour().minute())
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(AppTheme.Text.secondary)

            if let modeName = transcription.modeName, !modeName.isEmpty {
                Text(verbatim: modeName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(AppTheme.Text.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(AppTheme.Surface.subtle))
            }

            statusBadge

            Text(verbatim: metaText)
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(AppTheme.Text.muted)
                .lineLimit(1)

            Spacer(minLength: 8)

            HStack(spacing: 2) {
                if !isExpanded {
                    rowActionButton(
                        systemName: didCopyCollapsedText ? "checkmark" : "doc.on.doc",
                        help: "Copy transcription",
                        action: copyCollapsedText)
                }
                rowActionButton(
                    systemName: "chevron.right",
                    help: isExpanded ? "Collapse" : "Expand",
                    action: onToggleExpand
                )
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .opacity(showsActions ? 1 : 0)
            .allowsHitTesting(showsActions)
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch transcription.transcriptionStatus {
        case TranscriptionStatus.failed.rawValue:
            Label("Failed", systemImage: "exclamationmark.triangle")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AppTheme.Status.error.opacity(0.85))
        case TranscriptionStatus.canceled.rawValue:
            Label("Canceled", systemImage: "xmark.circle")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AppTheme.Text.muted)
        default:
            EmptyView()
        }
    }

    private func rowActionButton(
        systemName: String, help: LocalizedStringKey, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AppTheme.Text.secondary)
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(Text(help))
    }

    private func copyCollapsedText() {
        let _ = ClipboardManager.copyToClipboard(preferredCopyText)
        withAnimation { didCopyCollapsedText = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation { didCopyCollapsedText = false }
        }
    }

    // MARK: - Expanded Content

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Tabs
            if transcription.enhancedText != nil {
                HStack(spacing: 4) {
                    ForEach(TranscriptionTab.allCases, id: \.self) { tab in
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                selectedTab = tab
                            }
                        } label: {
                            Text(LocalizedStringKey(tab.rawValue))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(selectedTab == tab ? .primary : .secondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(
                                    Capsule()
                                        .fill(selectedTab == tab ? AppTheme.Surface.controlActive : Color.clear)
                                )
                        }
                        .buttonStyle(.plain)
                    }
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
            .hoverCopyButton(textToCopy: displayText)

            if hasAudioFile, let urlString = transcription.audioFileURL,
                let url = URL(string: urlString)
            {
                Divider()
                AudioPlayerView(url: url, transcription: transcription, onInfoTap: onShowInfo)
                    .padding(.vertical, 4)
            } else {
                HStack {
                    Spacer()
                    Button(action: onShowInfo) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("View details")
                }
            }
        }
    }
}

struct CircularCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(action: {
            configuration.isOn.toggle()
        }) {
            Image(systemName: configuration.isOn ? "checkmark.circle.fill" : "circle")
                .symbolRenderingMode(.hierarchical)
                .foregroundColor(configuration.isOn ? AppTheme.Selection.foreground : .secondary)
                .font(.system(size: 16))
        }
        .buttonStyle(.plain)
    }
}

#Preview("History rows") {
    let dictated = Transcription(
        text: "okay so the plan for tomorrow is to move the standup to ten and then we review the onboarding flow",
        duration: 24,
        enhancedText: "Plan for tomorrow: move the standup to 10:00, then review the onboarding flow together.",
        modeName: "Notes",
        transcriptionStatus: .completed
    )
    let failed = Transcription(
        text: "Transcription Failed: network timeout",
        duration: 7,
        modeName: "Email",
        transcriptionStatus: .failed
    )

    VStack(alignment: .leading, spacing: 0) {
        HistoryCardRow(
            transcription: dictated, wordCount: 14, isExpanded: false, isChecked: false, isSelecting: false,
            onToggleExpand: {}, onToggleCheck: {}, onShowInfo: {})
        Divider().padding(.leading, 10)
        HistoryCardRow(
            transcription: failed, wordCount: 5, isExpanded: false, isChecked: true, isSelecting: true,
            onToggleExpand: {}, onToggleCheck: {}, onShowInfo: {})
    }
    .padding(24)
    .frame(width: 760)
}
