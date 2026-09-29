import SwiftData
import SwiftUI

/// Transcription history list. `header` scrolls with the list (Home puts its week panel there).
struct HistoryView<Header: View>: View {
    private struct DayGroup: Identifiable {
        let id: Date
        var items: [Transcription]
    }

    private let header: Header

    init(@ViewBuilder header: () -> Header) {
        self.header = header()
    }

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var engine: VoiceInkEngine
    @State private var searchText = ""
    @State private var filter = HistoryFilter()
    @State private var sort = HistorySort.remembered
    /// Every match in `sort` order, for the sorts the database can't page (all but Newest); nil for Newest.
    @State private var sortedMatches: [Transcription]?
    @State private var filterApps: [(id: String, name: String)] = []
    @State private var filterModes: [String] = []
    @State private var expandedId: UUID?
    @State private var selectedTranscriptions: Set<Transcription> = []
    @State private var showDeleteConfirmation = false
    @State private var isPanelPresented = false
    @State private var panelMode: HistoryPanelMode = .info
    @State private var panelTranscriptionId: UUID?
    @State private var displayedTranscriptions: [Transcription] = []
    @State private var isLoading = false
    @State private var hasMoreContent = true
    @State private var paginationCursor: HistoryQuery.Cursor?
    @State private var isViewCurrentlyVisible = false
    @State private var wordCounts: [UUID: Int] = [:]
    /// Keyboard cursor: ↑/↓ move it, Return expands, Space checks, ⌘C copies.
    @State private var keyboardRowId: UUID?
    @FocusState private var isListFocused: Bool

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

    private func cursorQueryDescriptor(after cursor: HistoryQuery.Cursor? = nil) -> FetchDescriptor<Transcription> {
        var descriptor = FetchDescriptor<Transcription>(
            predicate: HistoryQuery.predicate(search: searchText, filter: filter, after: cursor),
            sortBy: [
                SortDescriptor(\Transcription.timestamp, order: .reverse),
                SortDescriptor(\Transcription.id, order: .reverse),
            ]
        )
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
            ScrollViewReader { scrollProxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        header
                            .padding(.bottom, AppTheme.Spacing.x6)

                        topBar
                        activeFilterChips

                        if displayedTranscriptions.isEmpty && !isLoading {
                            emptyStateView
                        } else {
                            cardListView
                        }
                    }
                    .padding(.horizontal, AppTheme.Spacing.x6)
                    .padding(.top, AppTheme.Spacing.x8)
                    .padding(.bottom, AppTheme.Spacing.x6)
                }
                .focusable()
                .focused($isListFocused)
                .focusEffectDisabled()
                .onKeyPress(.downArrow) { moveKeyboardRow(by: 1, proxy: scrollProxy) }
                .onKeyPress(.upArrow) { moveKeyboardRow(by: -1, proxy: scrollProxy) }
                .onKeyPress(.return) {
                    guard let id = keyboardRowId else { return .ignored }
                    withAnimation(.easeInOut(duration: 0.2)) { expandedId = expandedId == id ? nil : id }
                    return .handled
                }
                .onKeyPress(.delete) { deleteKeyboardRow() }
                .onKeyPress(.deleteForward) { deleteKeyboardRow() }
                .onKeyPress(.space) {
                    guard let row = keyboardRow else { return .ignored }
                    toggleSelection(row)
                    return .handled
                }
                .onCopyCommand {
                    guard let row = keyboardRow else { return [] }
                    let text = row.enhancedText.flatMap { $0.isEmpty ? nil : $0 } ?? row.text
                    return [NSItemProvider(object: text as NSString)]
                }
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
            reloadFilterOptions()
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
        .onChange(of: sort) { _, newSort in
            HistorySort.remembered = newSort
            Task {
                resetPagination()
                await loadInitialContent()
            }
        }
        .onChange(of: filter) { _, _ in
            Task {
                resetPagination()
                await loadInitialContent()
            }
        }
        .onChange(of: latestTranscriptionIndicator.first?.id) { oldId, newId in
            guard isViewCurrentlyVisible else { return }
            if newId != oldId {
                reloadFilterOptions()
                Task {
                    resetPagination()
                    await loadInitialContent()
                }
            }
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(spacing: AppTheme.Spacing.x3) {
            HStack(spacing: AppTheme.Spacing.x2) {
                Image(yapIcon: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(AppTheme.font(.footnote))
                TextField("Search transcriptions...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(AppTheme.font(.body))
            }
            .padding(.horizontal, AppTheme.Spacing.x3)
            .padding(.vertical, AppTheme.Spacing.x2)
            .background(
                Capsule()
                    .fill(AppTheme.Surface.card)
            )
            .frame(maxWidth: .infinity)

            filterMenu
            sortMenu

            AppActionButton("Transcribe File…", isPill: true) {
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
        .padding(.bottom, AppTheme.Spacing.x1)
    }

    // MARK: - Filter

    private func reloadFilterOptions() {
        let facets = HistoryQuery.facets(in: modelContext)
        filterApps = facets.apps
        filterModes = facets.modes
    }

    private var filterMenu: some View {
        Menu {
            Menu("App") {
                Button("All Apps") { filter.appBundleID = nil; filter.appName = nil }
                Divider()
                ForEach(filterApps, id: \.id) { app in
                    Toggle(
                        app.name,
                        isOn: Binding(
                            get: { filter.appBundleID == app.id },
                            set: { on in
                                filter.appBundleID = on ? app.id : nil
                                filter.appName = on ? app.name : nil
                            }))
                }
            }
            .disabled(filterApps.isEmpty)

            Menu("Mode") {
                Button("All Modes") { filter.modeName = nil }
                Divider()
                ForEach(filterModes, id: \.self) { mode in
                    Toggle(
                        mode,
                        isOn: Binding(
                            get: { filter.modeName == mode },
                            set: { filter.modeName = $0 ? mode : nil }))
                }
            }
            .disabled(filterModes.isEmpty)

            Toggle("Meetings only", isOn: $filter.meetingsOnly)

            if filter.isActive {
                Divider()
                Button("Clear Filter") { filter = HistoryFilter() }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .font(AppTheme.font(.body, .medium))
                .foregroundColor(filter.isActive ? AppTheme.Text.primary : .primary.opacity(0.7))
                .frame(width: 30, height: 30)
                .background(AppCardBackground(isSelected: filter.isActive, cornerRadius: AppTheme.Radius.pill))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Filter history")
        .accessibilityLabel("Filter history")
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: $sort) {
                ForEach(HistorySort.allCases) { Text(verbatim: $0.title).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(AppTheme.font(.body, .medium))
                .foregroundColor(sort == .newest ? .primary.opacity(0.7) : AppTheme.Text.primary)
                .frame(width: 30, height: 30)
                .background(AppCardBackground(isSelected: sort != .newest, cornerRadius: AppTheme.Radius.pill))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sort history")
        .accessibilityLabel("Sort history")
    }

    /// The active filters as removable chips under the search field.
    @ViewBuilder
    private var activeFilterChips: some View {
        if filter.isActive {
            HStack(spacing: AppTheme.Spacing.x2) {
                if let appName = filter.appName {
                    filterChip(appName) { filter.appBundleID = nil; filter.appName = nil }
                }
                if let modeName = filter.modeName {
                    filterChip(modeName) { filter.modeName = nil }
                }
                if filter.meetingsOnly {
                    filterChip(String(localized: "Meetings only")) { filter.meetingsOnly = false }
                }
                Spacer()
            }
            .padding(.top, AppTheme.Spacing.x2)
        }
    }

    private func filterChip(_ title: String, remove: @escaping () -> Void) -> some View {
        Button(action: remove) {
            HStack(spacing: AppTheme.Spacing.x1) {
                Text(verbatim: title)
                Image(systemName: "xmark")
            }
            .font(AppTheme.font(.caption, .medium))
            .foregroundStyle(AppTheme.Text.primary)
            .padding(.horizontal, AppTheme.Spacing.x3)
            .padding(.vertical, AppTheme.Spacing.x1)
            .background(Capsule().fill(AppTheme.Surface.controlActive))
        }
        .buttonStyle(.plain)
        .help("Clear Filter")
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityHint("Clear Filter")
    }

    private var selectionBar: some View {
        HStack(spacing: AppTheme.Spacing.x4) {
            Text(String(format: String(localized: "%lld selected"), Int64(selectedTranscriptions.count)))
                .font(AppTheme.font(.body, .medium))
                .foregroundColor(.secondary)

            Spacer()

            Button(action: {
                openPanel(mode: .analysis)
            }) {
                Label("Analyze", yapIcon: "chart.bar.xaxis")
                    .font(AppTheme.font(.footnote, .medium))
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)

            Button(action: {
                exportService.exportTranscriptionsToCSV(transcriptions: Array(selectedTranscriptions))
            }) {
                Label("Export", yapIcon: "square.and.arrow.up")
                    .font(AppTheme.font(.footnote, .medium))
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)

            if selectedTranscriptions.count == 1, let meeting = selectedTranscriptions.first, meeting.isMeeting {
                Button(action: {
                    MeetingExport.saveMarkdown(MeetingNotes.markdown(
                        title: String(localized: "Meeting"), date: meeting.timestamp, duration: meeting.duration,
                        notes: meeting.enhancedText, transcript: meeting.text))
                }) {
                    Label("Export Markdown…", yapIcon: "doc.text")
                        .font(AppTheme.font(.footnote, .medium))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            }

            Button(action: { showDeleteConfirmation = true }) {
                Label("Delete", yapIcon: "trash")
                    .font(AppTheme.font(.footnote, .medium))
            }
            .buttonStyle(.plain)
            .foregroundColor(AppTheme.Status.error.opacity(0.80))

            Divider()
                .frame(height: 16)

            if allSelected {
                Button("Deselect All") {
                    selectedTranscriptions.removeAll()
                }
                .font(AppTheme.font(.footnote, .medium))
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            } else {
                Button("Select All") {
                    Task { await selectAllTranscriptions() }
                }
                .font(AppTheme.font(.footnote, .medium))
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, AppTheme.Spacing.x6)
        .padding(.vertical, AppTheme.Spacing.x3)
        .background(
            AppTheme.Surface.window
                .shadow(color: Color.black.opacity(0.1), radius: 3, y: -2)
        )
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: AppTheme.Spacing.x4) {
            HStack(spacing: AppTheme.Spacing.x2) {
                Image(yapIcon: isNarrowed ? (searchText.isEmpty ? "line.3.horizontal.decrease" : "magnifyingglass") : "mic")
                    .font(AppTheme.font(.body, .medium))
                Text(verbatim: emptyStateMessage)
                    .font(AppTheme.font(.body))
            }
            .foregroundStyle(AppTheme.Text.secondary)

            // Empty without a search means nothing was ever dictated (or everything was deleted).
            if !isNarrowed {
                TrySayingCard()
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)  // design-exempt: layout offset, not spacing
    }

    private var isNarrowed: Bool { !searchText.isEmpty || filter.isActive }

    private var emptyStateMessage: String {
        guard !filter.isActive else {
            return String(localized: "No transcriptions match this filter")
        }
        guard searchText.isEmpty else {
            return String(localized: "No results found")
        }
        guard let shortcut = ShortcutStore.shortcut(for: .primaryRecording)?.displayString, !shortcut.isEmpty else {
            return String(localized: "No transcriptions yet")
        }
        return String(format: String(localized: "Press %@ and start talking"), shortcut)
    }

    // MARK: - Card List

    /// Loaded items grouped by calendar day in list order (items arrive sorted); one headerless group for the other sorts.
    private var dayGroups: [DayGroup] {
        guard sort.groupsByDay else { return [DayGroup(id: .distantPast, items: displayedTranscriptions)] }
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
            if sort.groupsByDay { dayHeader(group) }

            ForEach(Array(group.items.enumerated()), id: \.element.id) { index, transcription in
                if index > 0 {
                    Divider()
                        .padding(.leading, AppTheme.Spacing.x3)
                }

                HistoryCardRow(
                    transcription: transcription,
                    wordCount: wordCounts[transcription.id] ?? 0,
                    isExpanded: expandedId == transcription.id,
                    isChecked: selectedTranscriptions.contains(transcription),
                    isSelecting: isSelecting,
                    isKeyboardFocused: isListFocused && keyboardRowId == transcription.id,
                    onToggleExpand: {
                        keyboardRowId = transcription.id
                        isListFocused = true
                        withAnimation(.easeInOut(duration: 0.2)) {
                            expandedId = expandedId == transcription.id ? nil : transcription.id
                        }
                    },
                    onToggleCheck: { toggleSelection(transcription) },
                    onShowInfo: {
                        openPanel(mode: .info, transcriptionID: transcription.id)
                    }
                )
                .id(transcription.id)
                .contextMenu { rowMenu(for: transcription) }
            }
        }

        if hasMoreContent {
            Button(action: {
                Task { await loadMoreContent() }
            }) {
                HStack(spacing: AppTheme.Spacing.x2) {
                    if isLoading {
                        ProgressView().controlSize(.small)
                    }
                    Text(isLoading ? "Loading..." : "Load More")
                        .font(AppTheme.font(.footnote, .medium))
                }
                .foregroundStyle(AppTheme.Text.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, AppTheme.Spacing.x4)
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
                .font(AppTheme.font(.body, .semibold))
                .foregroundStyle(AppTheme.Text.primary)

            Spacer()

            Text(
                verbatim: String(localized: "\(Int64(group.items.count)) items") + " \u{00B7} "
                    + String(localized: "\(Int64(words)) words")
            )
            .font(AppTheme.font(.caption))
            .monospacedDigit()
            .foregroundStyle(AppTheme.Text.secondary)
        }
        .padding(.horizontal, AppTheme.Spacing.x3)
        .padding(.top, AppTheme.Spacing.x6)
        .padding(.bottom, AppTheme.Spacing.x2)
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
            if sort == .newest {
                sortedMatches = nil
                let items = try modelContext.fetch(cursorQueryDescriptor())
                let page = Array(items.prefix(pageSize))
                displayedTranscriptions = page
                countWords(in: page)
                paginationCursor = page.last.map { HistoryQuery.Cursor(timestamp: $0.timestamp, id: $0.id) }
                hasMoreContent = items.count > pageSize
            } else {
                let matches = try modelContext.fetch(
                    FetchDescriptor<Transcription>(predicate: HistoryQuery.predicate(search: searchText, filter: filter)))
                let ordered = HistoryQuery.sorted(matches, by: sort)
                sortedMatches = ordered
                let page = Array(ordered.prefix(pageSize))
                displayedTranscriptions = page
                countWords(in: page)
                hasMoreContent = ordered.count > pageSize
            }
        } catch {
            print("Error loading transcriptions: \(error)")
        }
    }

    @MainActor
    private func loadMoreContent() async {
        guard !isLoading, hasMoreContent else { return }

        if let sortedMatches {
            let page = Array(sortedMatches.dropFirst(displayedTranscriptions.count).prefix(pageSize))
            displayedTranscriptions.append(contentsOf: page)
            countWords(in: page)
            hasMoreContent = displayedTranscriptions.count < sortedMatches.count
            return
        }
        guard let paginationCursor else { return }

        isLoading = true
        defer { isLoading = false }

        do {
            let items = try modelContext.fetch(cursorQueryDescriptor(after: paginationCursor))
            let page = Array(items.prefix(pageSize))
            displayedTranscriptions.append(contentsOf: page)
            countWords(in: page)
            self.paginationCursor = page.last.map { HistoryQuery.Cursor(timestamp: $0.timestamp, id: $0.id) }
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
        sortedMatches = nil
        hasMoreContent = true
        isLoading = false
    }

    // MARK: - Row Menu

    @ViewBuilder
    private func rowMenu(for transcription: Transcription) -> some View {
        Button("Copy") { _ = ClipboardManager.copyToClipboard(transcription.preferredHistoryText) }
        if let enhanced = transcription.enhancedText, !enhanced.isEmpty, enhanced != transcription.text {
            Button("Copy Original") { _ = ClipboardManager.copyToClipboard(transcription.text) }
        }
        Button("Paste Again") { pasteAgain(transcription) }
        Button("Retranscribe") { retranscribe(transcription) }
        Button("Show Info") { openPanel(mode: .info, transcriptionID: transcription.id) }
        Divider()
        Button("Delete", role: .destructive) { requestDeletion(of: transcription) }
    }

    /// Goes back to the app the dictation was made in (or, for older rows, hides Yap so the previous app is
    /// frontmost again), then pastes.
    private func pasteAgain(_ transcription: Transcription) {
        let text = transcription.preferredHistoryText
        if let bundleID = transcription.sourceAppBundleID,
            let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        {
            app.activate(options: [.activateIgnoringOtherApps])
        } else {
            NSApp.hide(nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            CursorPaster.pasteAtCursor(text)
        }
    }

    /// The same action as the retranscribe button in the audio player: the current mode and its model.
    private func retranscribe(_ transcription: Transcription) {
        guard let urlString = transcription.audioFileURL, let url = URL(string: urlString),
            FileManager.default.fileExists(atPath: url.path)
        else {
            NotificationManager.shared.showNotification(
                title: String(localized: "Cannot retry: Audio file not found"), type: .error)
            return
        }
        guard let mode = ModeManager.shared.currentEffectiveConfiguration else {
            NotificationManager.shared.showNotification(title: String(localized: "No mode selected"), type: .error)
            return
        }
        guard
            let configuration = ModeRuntimeResolver.transcriptionConfiguration(
                mode: mode, transcriptionModelManager: engine.transcriptionModelManager)
        else {
            NotificationManager.shared.showNotification(
                title: String(localized: "No transcription model selected"), type: .error)
            return
        }
        let service = AudioTranscriptionService(modelContext: modelContext, engine: engine)
        Task { @MainActor in
            do {
                let result = try await service.retranscribeAudio(from: url, using: configuration.model, mode: mode)
                if let failure = result.enhancementFailure {
                    NotificationManager.shared.showNotification(
                        title: EnhancementFailureFormatter.transcriptionSavedMessage(description: failure),
                        type: .warning)
                } else {
                    NotificationManager.shared.showNotification(
                        title: String(localized: "Retranscription successful"), type: .success)
                }
            } catch {
                NotificationManager.shared.showNotification(
                    title: error.localizedDescription.isEmpty
                        ? String(localized: "Retranscription failed") : error.localizedDescription,
                    type: .error)
            }
        }
    }

    /// Opens the usual delete confirmation. Right-clicking a row outside the selection targets just that row.
    private func requestDeletion(of transcription: Transcription) {
        if !selectedTranscriptions.contains(transcription) {
            selectedTranscriptions = [transcription]
        }
        showDeleteConfirmation = true
    }

    private func deleteKeyboardRow() -> KeyPress.Result {
        guard let row = keyboardRow else { return .ignored }
        requestDeletion(of: row)
        return .handled
    }

    // MARK: - Selection & Deletion

    private var keyboardRow: Transcription? {
        displayedTranscriptions.first { $0.id == keyboardRowId }
    }

    private func moveKeyboardRow(by offset: Int, proxy: ScrollViewProxy) -> KeyPress.Result {
        guard !displayedTranscriptions.isEmpty else { return .ignored }
        let current = displayedTranscriptions.firstIndex { $0.id == keyboardRowId }
        let next = current.map { min(max($0 + offset, 0), displayedTranscriptions.count - 1) }
            ?? (offset > 0 ? 0 : displayedTranscriptions.count - 1)
        let id = displayedTranscriptions[next].id
        keyboardRowId = id
        withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id) }
        return .handled
    }

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
                try Transcription.removeAudio(at: url)
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
            var allDescriptor = FetchDescriptor<Transcription>(
                predicate: HistoryQuery.predicate(search: searchText, filter: filter))

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

struct HistoryCardRow: View {
    let transcription: Transcription
    let wordCount: Int
    let isExpanded: Bool
    let isChecked: Bool
    let isSelecting: Bool
    var isKeyboardFocused = false
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
        if let appName = transcription.sourceAppName, !appName.isEmpty { parts.append(appName) }
        if transcription.duration > 0 {
            parts.append(Duration.seconds(transcription.duration).formatted(.time(pattern: .minuteSecond)))
        }
        parts.append(String(localized: "\(Int64(wordCount)) words"))
        return parts.joined(separator: " \u{00B7} ")
    }

    private var showsActions: Bool { isHovering || isExpanded || isKeyboardFocused }

    /// VoiceOver reads the row as one line: time, mode, status, then the text.
    private var accessibilitySummary: String {
        var parts = [transcription.timestamp.formatted(date: .abbreviated, time: .shortened)]
        if let modeName = transcription.modeName, !modeName.isEmpty { parts.append(modeName) }
        if let appName = transcription.sourceAppName, !appName.isEmpty { parts.append(appName) }
        switch transcription.transcriptionStatus {
        case TranscriptionStatus.failed.rawValue: parts.append(String(localized: "Failed"))
        case TranscriptionStatus.canceled.rawValue: parts.append(String(localized: "Canceled"))
        default: break
        }
        parts.append(String(preferredCopyText.prefix(300)))
        return parts.joined(separator: ", ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.x3) {
            // Keeps its slot so text doesn't shift when the checkbox appears on hover.
            Toggle(
                "Select transcription",
                isOn: Binding(
                    get: { isChecked },
                    set: { _ in onToggleCheck() }
                )
            )
            .toggleStyle(CircularCheckboxStyle())
            .labelsHidden()
            .padding(.top, -AppTheme.Spacing.half)
            .opacity(isSelecting || isHovering || isChecked || isKeyboardFocused ? 1 : 0)
            .allowsHitTesting(isSelecting || isHovering || isChecked)

            VStack(alignment: .leading, spacing: AppTheme.Spacing.x2) {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.x2) {
                    metaLine

                    if !isExpanded {
                        Text(preferredCopyText)
                            .font(AppTheme.font(.body))
                            .lineSpacing(3)
                            .lineLimit(3)
                            .foregroundStyle(AppTheme.Text.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { onToggleExpand() }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilitySummary)
                .accessibilityAddTraits(.isButton)
                .accessibilityHint(isExpanded ? LocalizedStringKey("Collapse") : "Expand")
                .accessibilityAction { onToggleExpand() }

                if isExpanded {
                    expandedContent
                        .padding(.top, AppTheme.Spacing.x2)
                }
            }
        }
        .padding(.horizontal, AppTheme.Spacing.x3)
        .padding(.vertical, AppTheme.Spacing.x3)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous)
                .fill(isHovering && !isExpanded ? AppTheme.Surface.subtle : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous)
                .strokeBorder(AppTheme.Accent.primary, lineWidth: 2)
                .opacity(isKeyboardFocused ? 1 : 0)
        )
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
        }
    }

    private var metaLine: some View {
        HStack(spacing: AppTheme.Spacing.x2) {
            Text(transcription.timestamp, format: .dateTime.hour().minute())
                .font(AppTheme.font(.footnote, .medium))
                .monospacedDigit()
                .foregroundStyle(AppTheme.Text.secondary)

            if let modeName = transcription.modeName, !modeName.isEmpty {
                Text(verbatim: modeName)
                    .font(AppTheme.font(.micro, .medium))
                    .foregroundStyle(AppTheme.Text.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, AppTheme.Spacing.x2)
                    .padding(.vertical, AppTheme.Spacing.half)
                    .background(Capsule().fill(AppTheme.Surface.subtle))
            }

            if transcription.usedYapCloud == true {
                Text("Yap Cloud")
                    .font(AppTheme.font(.micro, .medium))
                    .foregroundStyle(AppTheme.Text.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, AppTheme.Spacing.x2)
                    .padding(.vertical, AppTheme.Spacing.half)
                    .background(Capsule().fill(AppTheme.Surface.subtle))
                    .help("Billed to your Yap Cloud balance")
            }

            statusBadge

            Text(verbatim: metaText)
                .font(AppTheme.font(.caption))
                .monospacedDigit()
                .foregroundStyle(AppTheme.Text.muted)
                .lineLimit(1)

            Spacer(minLength: 8)

            HStack(spacing: AppTheme.Spacing.half) {
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
            Label("Failed", yapIcon: "exclamationmark.triangle")
                .font(AppTheme.font(.caption, .medium))
                .foregroundStyle(AppTheme.Status.error.opacity(0.85))
        case TranscriptionStatus.canceled.rawValue:
            Label("Canceled", yapIcon: "xmark.circle")
                .font(AppTheme.font(.caption, .medium))
                .foregroundStyle(AppTheme.Text.muted)
        default:
            EmptyView()
        }
    }

    private func rowActionButton(
        systemName: String, help: LocalizedStringKey, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(yapIcon: systemName)
                .font(AppTheme.font(.caption, .medium))
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

    /// The imported file's name is gone by now (the audio is kept as a copy), so name the export by date.
    private var subtitleBaseName: String {
        "Yap " + transcription.timestamp.formatted(.iso8601.year().month().day().dateSeparator(.dash))
    }

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.x2) {
            // Tabs
            if transcription.enhancedText != nil {
                HStack(spacing: AppTheme.Spacing.x1) {
                    ForEach(TranscriptionTab.allCases, id: \.self) { tab in
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                selectedTab = tab
                            }
                        } label: {
                            Text(LocalizedStringKey(tab.rawValue))
                                .font(AppTheme.font(.caption, .medium))
                                .foregroundColor(selectedTab == tab ? .primary : .secondary)
                                .padding(.horizontal, AppTheme.Spacing.x3)
                                .padding(.vertical, AppTheme.Spacing.x1)
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

            YapCloudCostRow(transcription: transcription)

            SubtitleExportMenu(transcription: transcription, suggestedBaseName: subtitleBaseName)

            if hasAudioFile, let urlString = transcription.audioFileURL,
                let url = URL(string: urlString)
            {
                Divider()
                AudioPlayerView(url: url, transcription: transcription, onInfoTap: onShowInfo)
                    .padding(.vertical, AppTheme.Spacing.x1)
            } else {
                HStack {
                    Spacer()
                    Button(action: onShowInfo) {
                        Image(yapIcon: "info.circle")
                            .font(AppTheme.font(.callout, .medium))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("View details")
                    .accessibilityLabel("View details")
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
            Image(yapIcon: configuration.isOn ? "checkmark.circle.fill" : "circle")
                .symbolRenderingMode(.hierarchical)
                .foregroundColor(configuration.isOn ? AppTheme.Selection.foreground : .secondary)
                .font(AppTheme.font(.headline))
        }
        .buttonStyle(.plain)
        // The custom look drops the label and on/off state; VoiceOver gets a standard checkbox instead.
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
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
        Divider().padding(.leading, AppTheme.Spacing.x3)
        HistoryCardRow(
            transcription: failed, wordCount: 5, isExpanded: false, isChecked: true, isSelecting: true,
            onToggleExpand: {}, onToggleCheck: {}, onShowInfo: {})
    }
    .padding(AppTheme.Spacing.x6)
    .frame(width: 760)
}
