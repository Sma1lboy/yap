import Foundation
import SwiftData
import SwiftUI
import os

struct DashboardContent: View {
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "DashboardContent")
    private static let peakHoursUnlockDuration: TimeInterval = 30 * 60
    private static let reviewBacklogActionThreshold = 50
    // Above this count, skip live auto-refresh (full reload is expensive); tab reopen still refreshes.
    private static let automaticStatsRefreshMetricLimit = 2_000
    private static let statsRefreshDebounceNanoseconds: UInt64 = 750_000_000
    let modelContext: ModelContext

    @State private var statsSummary: DashboardStatsSummary = .empty
    @State private var hasLoadedStatsSnapshot: Bool = false
    @State private var statsSnapshotGeneratedAt: Date?
    @State private var isDashboardStatsRefreshing = false
    @State private var dashboardStatsTask: Task<Void, Never>?
    @State private var dashboardStatsLoadGeneration = 0
    @State private var isModelPerformancePanelPresented = false
    @State private var isModelUsagePanelPresented = false
    @State private var isAutoLearnFailurePanelPresented = false
    @State private var isAutoLearnReviewPanelPresented = false
    @State private var autoLearnReviewBacklogCount = 0
    @State private var autoLearnBacklogRefreshGeneration = 0
    @State private var autoLearnFailurePresentationTask: Task<Void, Never>?
    @State private var isInsightsViewPresented = false
    @State private var selectedInsightPeriod: DashboardInsightPeriod = .allTime
    @State private var isAccessibilityEnabled = AXIsProcessTrusted()
    @EnvironmentObject private var updaterViewModel: UpdaterViewModel
    @ObservedObject private var modeManager = ModeManager.shared
    @EnvironmentObject private var transcriptionModelManager: TranscriptionModelManager
    @State private var isSystemInfoCopied = false
    @AppStorage(AutoLearnSettings.isEnabledKey) private var isAutoLearnEnabled = true
    @AppStorage(AutoLearnSettings.hasFailureKey) private var hasAutoLearnFailure = false
    @AppStorage(AutoLearnSettings.failureAcknowledgedKey) private var isAutoLearnFailureAcknowledged = false
    init(modelContext: ModelContext) {
        self.modelContext = modelContext

        let cachedSummary = DashboardStatsCache.shared.currentSummary()
        let cachedMetadata = DashboardStatsCache.shared.currentMetadata()
        _statsSummary = State(initialValue: cachedSummary ?? .empty)
        _hasLoadedStatsSnapshot = State(initialValue: cachedSummary != nil)
        _statsSnapshotGeneratedAt = State(initialValue: cachedMetadata?.generatedAt)
    }

    var body: some View {
        Group {
            if isInsightsViewPresented {
                ScrollView {
                    dashboardInsightsView
                        .padding(.vertical, DashboardLayout.pageVerticalPadding)
                        .padding(.horizontal, DashboardLayout.pageHorizontalPadding)
                }
            } else {
                HistoryView { homeHeader }
            }
        }
        .task {
            scheduleDashboardStatsRefresh(allowSkipWhenFresh: hasLoadedStatsSnapshot)
        }
        .task {
            await refreshAutoLearnReviewBacklogCount()
        }
        .onAppear {
            refreshAccessibilityStatus()
            updaterViewModel.checkForUpdatesIfDue()
            if shouldAutomaticallyPresentAutoLearnFailure {
                scheduleAutoLearnFailurePresentation()
            }
        }
        .onChange(of: hasAutoLearnFailure) { _, _ in
            updateAutoLearnFailurePresentation()
        }
        .onChange(of: isAutoLearnEnabled) { _, _ in
            updateAutoLearnFailurePresentation()
        }
        .onChange(of: isAutoLearnFailureAcknowledged) { _, _ in
            updateAutoLearnFailurePresentation()
        }
        .onChange(of: isAutoLearnFailurePanelPresented) { wasPresented, isPresented in
            if wasPresented, !isPresented, hasAutoLearnFailure, isAutoLearnEnabled {
                AutoLearnSettings.acknowledgeCurrentFailure()
            }
        }
        .onReceive(LifecycleObserver.shared.publisher(for: .applicationDidBecomeActive)) { _ in
            refreshAccessibilityStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: .sessionMetricsDidChange)) { _ in
            DashboardStatsCache.shared.markStale()

            if shouldRefreshStatsAfterMetricChange {
                scheduleDashboardStatsRefresh(debounce: true, allowSkipWhenFresh: false)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .autoLearnQueueDidChange)) { _ in
            scheduleAutoLearnReviewBacklogRefresh()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .autoLearnReviewProposalsDidChange)
        ) { _ in
            scheduleAutoLearnReviewBacklogRefresh()
        }
        .onDisappear {
            dashboardStatsTask?.cancel()
            dashboardStatsTask = nil
            dashboardStatsLoadGeneration += 1
            isDashboardStatsRefreshing = false
            autoLearnFailurePresentationTask?.cancel()
            autoLearnFailurePresentationTask = nil
        }
        .sidePanel(isPresented: $isModelPerformancePanelPresented) {
            ModelPerformancePanel(
                summaries: selectedModelPerformance
            ) {
                isModelPerformancePanelPresented = false
            }
        }
        .sidePanel(isPresented: $isModelUsagePanelPresented) {
            ModelUsagePanel(
                summary: selectedModelUsage
            ) {
                isModelUsagePanelPresented = false
            }
        }
        .sidePanel(isPresented: $isAutoLearnFailurePanelPresented) {
            AutoLearnFailurePanel {
                isAutoLearnFailurePanelPresented = false
            }
        }
        .sidePanel(isPresented: $isAutoLearnReviewPanelPresented) {
            AutoLearnReviewPanel {
                isAutoLearnReviewPanelPresented = false
            }
        }
    }

    private func scheduleAutoLearnFailurePresentation() {
        autoLearnFailurePresentationTask?.cancel()
        autoLearnFailurePresentationTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled, shouldAutomaticallyPresentAutoLearnFailure else { return }
            isAutoLearnFailurePanelPresented = true
            autoLearnFailurePresentationTask = nil
        }
    }

    private var shouldAutomaticallyPresentAutoLearnFailure: Bool {
        hasAutoLearnFailure && isAutoLearnEnabled && !isAutoLearnFailureAcknowledged
    }

    private var dashboardReviewCorrectionCount: Int? {
        guard isAutoLearnEnabled,
            autoLearnReviewBacklogCount > Self.reviewBacklogActionThreshold
        else {
            return nil
        }
        return autoLearnReviewBacklogCount
    }

    @MainActor
    private func refreshAutoLearnReviewBacklogCount() async {
        let generation = autoLearnBacklogRefreshGeneration
        let queuedCount = (try? await AutoLearnService.shared.outstandingReviewCount()) ?? 0
        let proposalCount = (try? await AutoLearnService.shared.reviewProposalCount()) ?? 0
        guard generation == autoLearnBacklogRefreshGeneration else { return }
        autoLearnReviewBacklogCount = queuedCount + proposalCount
    }

    private func scheduleAutoLearnReviewBacklogRefresh() {
        autoLearnBacklogRefreshGeneration += 1
        Task { await refreshAutoLearnReviewBacklogCount() }
    }

    private func updateAutoLearnFailurePresentation() {
        if shouldAutomaticallyPresentAutoLearnFailure {
            scheduleAutoLearnFailurePresentation()
        } else {
            autoLearnFailurePresentationTask?.cancel()
            autoLearnFailurePresentationTask = nil
            isAutoLearnFailurePanelPresented = false
        }
    }

    /// Scrolls above the history list: reminders, this week's panel, footer links.
    private var homeHeader: some View {
        VStack(alignment: .leading, spacing: DashboardLayout.sectionSpacing) {
            if !isAccessibilityEnabled {
                DashboardAccessibilityReminder(onOpenSettings: openAccessibilitySettings)
            }

            if !modeManager.hasEnabledConfiguration {
                DashboardNoModesReminder(onOpenModes: ModeSetupNavigator.openModesSettings)
            }

            YapCloudBalanceCard()

            HomeWeekPanel(modeSummary: defaultModeSummary)

            footerLinks
        }
    }

    /// "shortcut · transcription model · enhancement model" for the default mode.
    private var defaultModeSummary: String? {
        guard let mode = modeManager.getDefaultConfiguration() ?? modeManager.currentEffectiveConfiguration else {
            return nil
        }

        var parts: [String] = []

        if let shortcut = ShortcutStore.shortcut(for: .primaryRecording)?.displayString, !shortcut.isEmpty {
            parts.append(shortcut)
        }

        if let modelName = mode.selectedTranscriptionModelName {
            let model = TranscriptionModelRegistry.model(
                forSelectionKey: modelName,
                in: transcriptionModelManager.allAvailableModels
            )
            parts.append(model?.displayName ?? modelName)
        }

        if mode.isAIEnhancementEnabled, let aiModel = mode.selectedAIModel, !aiModel.isEmpty {
            parts.append(aiModel)
        } else {
            parts.append(String(localized: "No enhancement"))
        }

        return parts.joined(separator: " \u{00B7} ")
    }

    private var footerLinks: some View {
        HStack(spacing: 16) {
            Button {
                isInsightsViewPresented = true
            } label: {
                Label("Stats", systemImage: "chart.bar")
            }
            .help("View dictation stats")

            if let count = dashboardReviewCorrectionCount {
                Button(action: openAutoLearnReviewPanel) {
                    Label("Review Corrections", systemImage: "text.book.closed")
                }
                .help(
                    String(format: String(localized: "Review %lld pending corrections"), Int64(count))
                )
            }

            Spacer()

            Button(action: copySystemInfo) {
                Label(
                    LocalizedStringKey(isSystemInfoCopied ? "Copied!" : "Copy System Info"),
                    systemImage: isSystemInfoCopied ? "checkmark" : "doc.on.doc"
                )
            }
        }
        .buttonStyle(.link)
        .font(.system(size: 12))
        .foregroundStyle(AppTheme.Text.secondary)
    }

    private var selectedProductivityPoints: [DashboardProductivityPoint] {
        statsSummary.productivity(for: selectedInsightPeriod)
    }

    private var selectedDailyActivityPoints: [DashboardProductivityPoint] {
        statsSummary.dailyActivity(for: selectedInsightPeriod)
    }

    private var selectedModelPerformance: [ModelPerformanceSummary] {
        statsSummary.modelPerformance(for: selectedInsightPeriod)
    }

    private var selectedModelUsage: ModelUsageSummary {
        statsSummary.modelUsage(for: selectedInsightPeriod)
    }

    private var selectedPeakHours: DashboardPeakHoursSummary {
        statsSummary.peakHours(for: selectedInsightPeriod)
    }

    private var selectedTotals: DashboardMetricTotals {
        statsSummary.totals(for: selectedInsightPeriod)
    }

    private var selectedTimeSavedSummary: DashboardTimeSavedSummary {
        return DashboardTimeSavedSummary(
            timeSaved: DashboardTimeSaving.timeSaved(words: selectedTotals.words, duration: selectedTotals.duration),
            wordCount: selectedTotals.words,
            sessionCount: selectedTotals.count
        )
    }

    private var statsUpdatedAtText: String {
        guard let statsSnapshotGeneratedAt else {
            return String(localized: "Stats not updated yet")
        }

        let formattedDate = statsSnapshotGeneratedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        return String(format: String(localized: "Updated at %@"), formattedDate)
    }
    private var canViewPeakHours: Bool {
        hasLoadedStatsSnapshot && selectedTotals.duration >= Self.peakHoursUnlockDuration && selectedPeakHours.hasData
    }

    private var shouldLockPeakHours: Bool {
        hasLoadedStatsSnapshot && !canViewPeakHours
    }

    private var shouldRefreshStatsAfterMetricChange: Bool {
        !hasLoadedStatsSnapshot || statsSummary.totalCount < Self.automaticStatsRefreshMetricLimit
    }


    private func refreshAccessibilityStatus() {
        isAccessibilityEnabled = AXIsProcessTrusted()
    }

    private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func openModelPerformancePanel() {
        isModelPerformancePanelPresented = true
    }

    private func openModelUsagePanel() {
        isModelUsagePanelPresented = true
    }

    private func openAutoLearnReviewPanel() {
        isAutoLearnReviewPanelPresented = true
    }

    @MainActor
    private func refreshDashboardStats() {
        scheduleDashboardStatsRefresh(allowSkipWhenFresh: false)
    }

    @MainActor
    private func scheduleDashboardStatsRefresh(
        debounce: Bool = false,
        allowSkipWhenFresh: Bool = false
    ) {
        dashboardStatsTask?.cancel()
        dashboardStatsLoadGeneration += 1

        let generation = dashboardStatsLoadGeneration
        let modelContainer = modelContext.container

        dashboardStatsTask = Task {
            if debounce {
                try? await Task.sleep(nanoseconds: Self.statsRefreshDebounceNanoseconds)
                guard !Task.isCancelled else {
                    return
                }
            }

            await loadDashboardStatsEfficiently(
                from: modelContainer,
                generation: generation,
                allowSkipWhenFresh: allowSkipWhenFresh
            )
        }
    }

    private func loadDashboardStatsEfficiently(
        from modelContainer: ModelContainer,
        generation: Int,
        allowSkipWhenFresh: Bool
    ) async {
        do {
            if allowSkipWhenFresh {
                let shouldRefreshAutomatically =
                    SessionMetricMigrationService.shared.isRunning
                    || DashboardStatsCache.shared.shouldRefreshSnapshotAutomatically()

                guard shouldRefreshAutomatically else {
                    return
                }
            }

            let shouldStartRefresh = await MainActor.run {
                guard generation == dashboardStatsLoadGeneration else {
                    return false
                }

                self.isDashboardStatsRefreshing = true
                return true
            }

            guard shouldStartRefresh else {
                return
            }

            let summary = try await DashboardStatsLoader.load(from: modelContainer)

            guard !Task.isCancelled else {
                await finishDashboardStatsRefresh(generation: generation)
                return
            }

            let shouldAcceptSummary = summary.totalCount > 0 || !SessionMetricMigrationService.shared.isRunning

            await MainActor.run {
                guard generation == dashboardStatsLoadGeneration else {
                    return
                }

                self.isDashboardStatsRefreshing = false

                guard shouldAcceptSummary else {
                    return
                }

                self.statsSummary = summary
                let metadata = DashboardStatsCache.shared.update(summary)
                self.statsSnapshotGeneratedAt = metadata.generatedAt
                self.hasLoadedStatsSnapshot = true
            }
        } catch is CancellationError {
            await finishDashboardStatsRefresh(generation: generation)
        } catch {
            await finishDashboardStatsRefresh(generation: generation)
            logger.error("Error loading dashboard stats: \(error, privacy: .public)")
        }
    }

    private func finishDashboardStatsRefresh(generation: Int) async {
        await MainActor.run {
            guard generation == dashboardStatsLoadGeneration else {
                return
            }

            self.isDashboardStatsRefreshing = false
        }
    }

    // MARK: - Sections

    private var dashboardInsightsView: some View {
        DashboardInsightsView(
            selectedPeriod: $selectedInsightPeriod,
            productivityPoints: selectedProductivityPoints,
            dailyActivityPoints: selectedDailyActivityPoints,
            peakHoursSummary: selectedPeakHours,
            isPeakHoursLocked: shouldLockPeakHours,
            timeSavedSummary: selectedTimeSavedSummary,
            modelUsage: selectedModelUsage,
            modelPerformanceSummaries: selectedModelPerformance,
            updatedAtText: statsUpdatedAtText,
            isRefreshingStats: isDashboardStatsRefreshing,
            onBack: { isInsightsViewPresented = false },
            onRefreshStats: refreshDashboardStats,
            onViewModelUsage: openModelUsagePanel,
            onViewModelPerformance: openModelPerformancePanel
        )
    }

    private func copySystemInfo() {
        SystemInfoService.shared.copySystemInfoToClipboard()

        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            isSystemInfoCopied = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                isSystemInfoCopied = false
            }
        }
    }
}

private struct DashboardAccessibilityReminder: View {
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(AppTheme.Accent.fill)

                Image(systemName: "hand.raised")
                    .font(.system(size: 15, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(AppTheme.Accent.primary)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 3) {
                Text("Enable Accessibility Access")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text("Required for Yap to paste transcripts into other apps and for its shortcuts to work.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 12)

            AppActionButton("Open Settings", action: onOpenSettings)
                .help("Open Accessibility settings")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppCardBackground(cornerRadius: 16))
    }
}

private struct DashboardNoModesReminder: View {
    let onOpenModes: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(AppTheme.Accent.fill)

                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 15, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(AppTheme.Accent.primary)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 3) {
                Text("Set Up a Mode")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text("Yap needs at least one mode to record. Create one to start dictating.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 12)

            AppActionButton("Manage Modes", action: onOpenModes)
                .help("Open Modes settings")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppCardBackground(cornerRadius: 16))
    }
}
