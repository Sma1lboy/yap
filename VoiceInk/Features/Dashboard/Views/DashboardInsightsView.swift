import SwiftUI

struct DashboardInsightsView: View {
    @Binding var selectedPeriod: DashboardInsightPeriod
    let productivityPoints: [DashboardProductivityPoint]
    let dailyActivityPoints: [DashboardProductivityPoint]
    let peakHoursSummary: DashboardPeakHoursSummary
    let isPeakHoursLocked: Bool
    let timeSavedSummary: DashboardTimeSavedSummary
    let modelUsage: ModelUsageSummary
    let modelPerformanceSummaries: [ModelPerformanceSummary]
    let updatedAtText: String
    let isRefreshingStats: Bool
    let onBack: () -> Void
    let onRefreshStats: () -> Void
    let onViewModelUsage: () -> Void
    let onViewModelPerformance: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.x6) {
            header

            DashboardEditorialSummaryCard(
                summary: timeSavedSummary
            )

            DashboardProductivityCard(
                period: $selectedPeriod,
                points: productivityPoints,
                updatedAtText: updatedAtText,
                isRefreshingStats: isRefreshingStats,
                onRefreshStats: onRefreshStats
            )

            DashboardActivityCalendarCard(
                points: dailyActivityPoints,
                summary: timeSavedSummary,
                peakHoursSummary: peakHoursSummary,
                isPeakHoursLocked: isPeakHoursLocked
            )

            ModelUsageCard(
                summary: modelUsage,
                onViewMore: onViewModelUsage
            )

            ModelPerformanceCard(
                summaries: modelPerformanceSummaries,
                onViewMore: onViewModelPerformance
            )
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.x4) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.x1) {
                Text("Yap Insights")
                    .font(AppTheme.font(.display, .semibold, design: .rounded))
                    .foregroundStyle(AppTheme.Text.primary)

                Text("A closer look at your Yap usage.")
                    .font(AppTheme.font(.body, .medium))
                    .foregroundStyle(AppTheme.Text.secondary)
            }

            Spacer()

            HStack(spacing: AppTheme.Spacing.x2) {
                AppIconButton(
                    systemName: "chevron.left",
                    help: "Back to dashboard",
                    size: 34,
                    iconSize: 12,
                    cornerRadius: AppTheme.Radius.panel,
                    action: onBack
                )

                InsightPeriodPicker(
                    title: "Insights period",
                    selection: $selectedPeriod
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
