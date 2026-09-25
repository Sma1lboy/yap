import SwiftData
import SwiftUI

enum WeekStatsLoader {
    static func load(from container: ModelContainer, now: Date = Date()) async throws -> WeekStats {
        try await Task.detached(priority: .utility) {
            let calendar = DashboardPeriodWindows.dashboardCalendar()
            let since =
                calendar.date(byAdding: .day, value: -WeekStats.lookbackDays, to: calendar.startOfDay(for: now)) ?? now
            var descriptor = FetchDescriptor<SessionMetric>(
                predicate: #Predicate { $0.timestamp >= since }
            )
            descriptor.propertiesToFetch = [\.timestamp, \.wordCount, \.audioDuration]
            let samples = try ModelContext(container).fetch(descriptor).map {
                WeekStatsSample(timestamp: $0.timestamp, words: $0.wordCount, audioDuration: $0.audioDuration)
            }
            return WeekStats.compute(samples: samples, now: now, calendar: calendar)
        }.value
    }
}

/// Home dashboard: this week's numbers, loading and refreshing themselves.
struct HomeWeekPanel: View {
    let modeSummary: String?

    @Environment(\.modelContext) private var modelContext
    @State private var stats = WeekStats.compute(
        samples: [], now: Date(), calendar: DashboardPeriodWindows.dashboardCalendar())
    @State private var metricChangeTask: Task<Void, Never>?

    var body: some View {
        HomeWeekPanelContent(stats: stats, modeSummary: modeSummary)
            .task {
                #if DEBUG
                    WeekStats.runSelfCheck()
                #endif
                // Periodic refresh also rolls the panel over at midnight and on Monday.
                while !Task.isCancelled {
                    await reload()
                    try? await Task.sleep(for: .seconds(60))
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .sessionMetricsDidChange)) { _ in
                metricChangeTask?.cancel()
                metricChangeTask = Task {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled else { return }
                    await reload()
                }
            }
            .onDisappear { metricChangeTask?.cancel() }
    }

    @MainActor
    private func reload() async {
        if let fresh = try? await WeekStatsLoader.load(from: modelContext.container) {
            stats = fresh
        }
    }
}

struct HomeWeekPanelContent: View {
    let stats: WeekStats
    let modeSummary: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header

            HStack(alignment: .bottom, spacing: 24) {
                hero
                Spacer(minLength: 0)
                HomeWeekBars(dailyWords: stats.dailyWords, todayIndex: stats.todayIndex, weekStart: stats.weekStart)
                    .frame(width: 220)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { tiles }
                Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                    let all = Array(tileModels.enumerated())
                    GridRow { ForEach(all.prefix(2), id: \.offset) { HomeStatTile(model: $0.element) } }
                    GridRow { ForEach(all.suffix(2), id: \.offset) { HomeStatTile(model: $0.element) } }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: "Yap")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(AppTheme.Text.primary)
                if let modeSummary {
                    Text(verbatim: modeSummary)
                        .font(.system(size: 13))
                        .foregroundStyle(AppTheme.Text.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 12)

            Text(
                String(
                    format: String(localized: "This week · %@"),
                    (stats.weekStart..<stats.lastDayOfWeek).formatted(.interval.month(.abbreviated).day())
                )
            )
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(AppTheme.Text.secondary)
            .lineLimit(1)
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(stats.words, format: .number)
                    .font(.system(size: 44, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(AppTheme.Text.primary)
                    .contentTransition(.numericText())
                Text("words dictated")
                    .font(.system(size: 13))
                    .foregroundStyle(AppTheme.Text.secondary)
            }

            comparison
                .font(.system(size: 12))
                .foregroundStyle(AppTheme.Text.secondary)
        }
    }

    @ViewBuilder
    private var comparison: some View {
        if let change = stats.changeVsLastWeek {
            Label {
                Text(
                    String(
                        format: String(localized: "%@ vs last week"),
                        change.formatted(.percent.precision(.fractionLength(0)).sign(strategy: .always()))
                    ))
            } icon: {
                Image(systemName: change >= 0 ? "arrow.up.right" : "arrow.down.right")
            }
        } else if stats.words > 0 {
            Text("Nothing to compare with last week")
        } else {
            Text("Nothing dictated yet this week")
        }
    }

    private var tiles: some View {
        ForEach(Array(tileModels.enumerated()), id: \.offset) { HomeStatTile(model: $0.element) }
    }

    private var tileModels: [HomeStatTile.Model] {
        let timeSaved = DashboardTimeSaving.timeSaved(words: stats.words, duration: stats.audioDuration)
        let wpm = stats.wordsPerMinute

        let streakNote =
            stats.hasSessionToday
            ? String(localized: "Active today")
            : (stats.streakDays > 0 ? String(localized: "Dictate today to keep it") : String(localized: "Start today"))

        return [
            .init(
                title: "Time saved",
                value: Formatters.formattedCompactHoursAndMinutes(timeSaved),
                unit: nil,
                note: String(localized: "vs typing at 40 wpm")),
            .init(
                title: "Speaking pace",
                value: wpm.map { Formatters.formattedNumber(Int($0.rounded())) } ?? "–",
                unit: "wpm",
                note: wpm.map {
                    String(
                        format: String(localized: "%@× typing speed"),
                        ($0 / 40).formatted(.number.precision(.fractionLength(1))))
                } ?? String(localized: "No audio yet")),
            .init(
                title: "Day streak",
                value: Formatters.formattedNumber(stats.streakDays),
                unit: nil,
                note: streakNote),
            .init(
                title: "Dictations",
                value: Formatters.formattedNumber(stats.sessions),
                unit: nil,
                note: String(
                    format: String(localized: "%@ of audio"),
                    Formatters.formattedCompactHoursAndMinutes(stats.audioDuration))),
        ]
    }
}

struct HomeStatTile: View {
    struct Model {
        let title: LocalizedStringKey
        let value: String
        let unit: LocalizedStringKey?
        let note: String
    }

    let model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AppTheme.Text.secondary)
                .lineLimit(1)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(verbatim: model.value)
                    .font(.system(size: 20, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(AppTheme.Text.primary)
                if let unit = model.unit {
                    Text(unit)
                        .font(.system(size: 12))
                        .foregroundStyle(AppTheme.Text.secondary)
                }
            }
            .lineLimit(1)

            Text(verbatim: model.note)
                .font(.system(size: 11))
                .foregroundStyle(AppTheme.Text.muted)
                .lineLimit(1)
        }
        .padding(12)
        .frame(minWidth: 128, maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous)
                .fill(AppTheme.Surface.subtle)
        )
    }
}

/// Seven bars, Monday to Sunday. Today uses the accent; future days are empty outlined slots.
struct HomeWeekBars: View {
    let dailyWords: [Int]
    let todayIndex: Int
    let weekStart: Date

    private static let barAreaHeight: CGFloat = 48
    private static let minimumBarHeight: CGFloat = 3

    private var maxWords: Int { max(dailyWords.max() ?? 0, 1) }

    var body: some View {
        let calendar = DashboardPeriodWindows.dashboardCalendar()

        VStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(0..<7, id: \.self) { index in
                    bar(index)
                        .frame(maxWidth: .infinity)
                        .help(
                            String(localized: "\(Int64(dailyWords.indices.contains(index) ? dailyWords[index] : 0)) words"))
                }
            }
            .frame(height: Self.barAreaHeight, alignment: .bottom)

            Rectangle()
                .fill(AppTheme.Border.card)
                .frame(height: 1)

            HStack(spacing: 8) {
                ForEach(0..<7, id: \.self) { index in
                    let day = calendar.date(byAdding: .day, value: index, to: weekStart) ?? weekStart
                    Text(day.formatted(.dateTime.weekday(.narrow)))
                        .font(.system(size: 10, weight: index == todayIndex ? .semibold : .regular))
                        .foregroundStyle(index == todayIndex ? AppTheme.Text.primary : AppTheme.Text.muted)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Words per day this week"))
    }

    @ViewBuilder
    private func bar(_ index: Int) -> some View {
        let words = dailyWords.indices.contains(index) ? dailyWords[index] : 0
        let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)

        if index > todayIndex {
            shape
                .strokeBorder(AppTheme.Border.card, lineWidth: 1)
                .frame(height: 10)
        } else {
            shape
                .fill(index == todayIndex ? AppTheme.Accent.primary : AppTheme.Text.secondary.opacity(0.35))
                .frame(
                    height: words == 0
                        ? Self.minimumBarHeight
                        : max(Self.minimumBarHeight, Self.barAreaHeight * CGFloat(words) / CGFloat(maxWords))
                )
        }
    }
}

extension WeekStats {
    /// Sample week for previews and snapshot rendering.
    static var previewSample: WeekStats {
        let calendar = DashboardPeriodWindows.dashboardCalendar()
        let now = Date()
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? now
        var samples: [WeekStatsSample] = []
        for (dayOffset, words) in [(-7, 900), (-6, 1200), (-4, 800), (0, 640), (1, 1_120), (2, 380), (3, 910)] {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: weekStart),
                let time = calendar.date(byAdding: .hour, value: 10, to: day)
            else { continue }
            samples.append(WeekStatsSample(timestamp: time, words: words, audioDuration: Double(words) / 150 * 60))
        }
        return compute(samples: samples, now: now, calendar: calendar)
    }
}

#Preview("Week panel") {
    HomeWeekPanelContent(stats: .previewSample, modeSummary: "⌥ Space · Scribe · gpt-5-mini")
        .padding(24)
        .frame(width: 760)
}
