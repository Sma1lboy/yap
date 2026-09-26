import Foundation
import SwiftUI

struct DashboardProductivityCard: View {
    @Binding var period: DashboardInsightPeriod
    let points: [DashboardProductivityPoint]
    let updatedAtText: String
    let isRefreshingStats: Bool
    let onRefreshStats: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.x5) {
            HStack(alignment: .center, spacing: AppTheme.Spacing.x4) {
                Text(period.chartTitle)
                    .font(AppTheme.font(.title3, .semibold, design: .rounded))
                    .foregroundStyle(AppTheme.Text.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.84)

                Spacer(minLength: 12)

                HStack(spacing: AppTheme.Spacing.x2) {
                    Text(statusText)
                        .font(AppTheme.font(.footnote, .medium))
                        .foregroundStyle(AppTheme.Text.muted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.86)
                        .contentTransition(.opacity)
                        .animation(.easeInOut(duration: 0.18), value: isRefreshingStats)

                    DashboardStatsRefreshButton(
                        isRefreshing: isRefreshingStats,
                        action: onRefreshStats
                    )
                }
                .frame(maxWidth: 260, alignment: .trailing)
            }

            DashboardProductivityChart(period: period, points: points)
                .frame(height: 208)
        }
        .padding(AppTheme.Spacing.x5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DashboardInsightCardBackground(cornerRadius: AppTheme.Radius.panel))
    }

    private var statusText: String {
        isRefreshingStats ? String(localized: "Updating") : updatedAtText
    }
}
struct DashboardEditorialSummaryCard: View {
    let summary: DashboardTimeSavedSummary

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.x5) {
            Text("You made room for")
                .font(AppTheme.font(.headline, .semibold))
                .foregroundStyle(AppTheme.Text.secondary)

            HStack(alignment: .lastTextBaseline, spacing: AppTheme.Spacing.x3) {
                Text(summary.hasData ? Formatters.formattedSavedTime(summary.timeSaved) : "--")
                    .font(AppTheme.font(.display, .semibold, design: .rounded))
                    .foregroundStyle(AppTheme.Accent.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)

                Text("of focused work")
                    .font(AppTheme.font(.title3, .semibold, design: .rounded))
                    .foregroundStyle(AppTheme.Text.secondary)
                    .padding(.bottom, AppTheme.Spacing.x2)
            }

            Rectangle()
                .fill(AppTheme.Text.primary)
                .frame(height: 2)

            HStack(alignment: .top, spacing: AppTheme.Spacing.x8) {
                editorialFact(
                    value: summary.hasData ? Formatters.formattedCompactNumber(summary.wordCount) : "--",
                    copy: "words captured"
                )
                editorialFact(
                    value: summary.hasData ? Formatters.formattedCompactNumber(summary.sessionCount) : "--",
                    copy: "dictation sessions"
                )
                editorialFact(
                    value: averageSessionText,
                    copy: "words per average session"
                )
            }
        }
        .padding(AppTheme.Spacing.x6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DashboardInsightCardBackground(cornerRadius: AppTheme.Radius.panel))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Yap impact summary")
    }

    private var averageSessionText: String {
        guard summary.sessionCount > 0 else { return "--" }
        return Formatters.formattedCompactNumber(summary.wordCount / summary.sessionCount)
    }

    private func editorialFact(value: String, copy: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.x1) {
            Text(value)
                .font(AppTheme.font(.title3, .semibold, design: .rounded))
                .foregroundStyle(AppTheme.Text.primary)
            Text(copy)
                .font(AppTheme.font(.caption, .medium))
                .foregroundStyle(AppTheme.Text.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DashboardStatsRefreshButton: View {
    let isRefreshing: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(AppTheme.Accent.primary)
                        .transition(.opacity)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(AppTheme.font(.footnote, .semibold))
                        .foregroundStyle(AppTheme.Text.primary.opacity(0.72))
                        .transition(.opacity)
                }
            }
            .frame(width: 34, height: 34)
            .background(AppCardBackground(cornerRadius: AppTheme.Radius.panel))
            .animation(.easeInOut(duration: 0.18), value: isRefreshing)
        }
        .buttonStyle(.plain)
        .disabled(isRefreshing)
        .help(refreshHelp)
        .accessibilityLabel(Text(refreshHelp))
    }

    private var refreshHelp: String {
        isRefreshing ? String(localized: "Refreshing stats") : String(localized: "Refresh stats")
    }
}

private enum DashboardProductivityChartData {
    static func visiblePoints(
        for period: DashboardInsightPeriod,
        points: [DashboardProductivityPoint],
        now: Date = Date()
    ) -> [DashboardProductivityPoint] {
        Array(points.prefix(visiblePointCount(for: period, points: points, now: now)))
    }

    static func visiblePointCount(
        for period: DashboardInsightPeriod,
        points: [DashboardProductivityPoint],
        now: Date = Date()
    ) -> Int {
        guard period == .today, let firstPoint = points.first else {
            return points.count
        }

        let calendar = DashboardPeriodWindows.dashboardCalendar()

        guard calendar.isDate(firstPoint.date, inSameDayAs: now) else {
            return points.count
        }

        return min(points.count, calendar.component(.hour, from: now) + 1)
    }

    static func yAxisUpperBound(for value: Int) -> Int {
        guard value > 0 else {
            return 0
        }

        let paddedValue = Double(value) * 1.06
        let magnitude = pow(10, max(0, floor(log10(paddedValue)) - 1))
        let step = max(1, Int(magnitude))

        return max(value, Int(ceil(paddedValue / Double(step))) * step)
    }
}

private struct DashboardProductivityChart: View {
    let period: DashboardInsightPeriod
    let points: [DashboardProductivityPoint]

    private var yAxisUpperBound: Int {
        DashboardProductivityChartData.yAxisUpperBound(for: visiblePoints.map(\.words).max() ?? 0)
    }

    private var hasWords: Bool {
        visiblePoints.contains { $0.words > 0 }
    }

    private var visiblePoints: [DashboardProductivityPoint] {
        DashboardProductivityChartData.visiblePoints(for: period, points: points)
    }

    private var horizontalSlotCount: Int {
        period == .today ? 24 : max(visiblePoints.count, 1)
    }

    private var yAxisLabels: [Int] {
        guard hasWords else {
            return [0]
        }

        return [
            yAxisUpperBound,
            yAxisUpperBound * 3 / 4,
            yAxisUpperBound / 2,
            yAxisUpperBound / 4,
            0,
        ]
        .reduce(into: []) { labels, value in
            if !labels.contains(value) {
                labels.append(value)
            }
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.x3) {
            DashboardProductivityYAxis(labels: yAxisLabels)
                .accessibilityHidden(true)

            DashboardProductivityPlotArea(
                period: period,
                points: points,
                visiblePoints: visiblePoints,
                yAxisUpperBound: yAxisUpperBound,
                horizontalSlotCount: horizontalSlotCount
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Dictated words chart")
        .accessibilityValue(totalWordsAccessibilityValue)
    }

    private var totalWordsAccessibilityValue: String {
        String(
            format: String(localized: "%@ words"),
            Formatters.formattedNumber(points.reduce(0) { $0 + $1.words })
        )
    }
}

private struct DashboardProductivityYAxis: View {
    let labels: [Int]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if labels.count == 1, let label = labels.first {
                VStack(alignment: .leading, spacing: 0) {
                    Spacer(minLength: 0)
                    yAxisLabel(label)
                }
                .frame(maxHeight: .infinity, alignment: .bottomLeading)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(labels, id: \.self) { label in
                        yAxisLabel(label)
                            .frame(maxHeight: .infinity, alignment: .topLeading)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .topLeading)
            }

            Text("Words")
                .font(AppTheme.font(.micro, .semibold))
                .foregroundStyle(AppTheme.Text.secondary.opacity(0.82))
                .lineLimit(1)
                .frame(height: 30, alignment: .topLeading)
        }
        .frame(width: 42, alignment: .leading)
    }

    private func yAxisLabel(_ label: Int) -> some View {
        Text(Formatters.formattedAxisValue(label))
            .font(AppTheme.font(.caption, .medium))
            .foregroundStyle(AppTheme.Text.secondary)
            .lineLimit(1)
    }
}
