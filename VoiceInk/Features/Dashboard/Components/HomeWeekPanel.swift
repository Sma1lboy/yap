import Combine
import SwiftData
import SwiftUI

enum WeekStatsLoader {
    /// Reads every dictation since last week's Monday, and for the streak, whether there was one on each day before
    /// that. Fetching a SwiftData row costs about 0.1 ms whatever properties it asks for (2.7 s for 20,000 on an M4
    /// Pro), so the 60 days the streak can reach aren't fetched whole: each earlier day is a count, asked only while
    /// the streak is still going (`make home-feedback-perf`).
    static func load(from container: ModelContainer, now: Date = Date()) async throws -> WeekStats {
        try await Task.detached(priority: .utility) {
            let calendar = DashboardPeriodWindows.dashboardCalendar()
            let context = ModelContext(container)
            let since = WeekStats.previousWeekStart(now: now, calendar: calendar)
            let samples = try context.fetch(FetchDescriptor<SessionMetric>(predicate: #Predicate { $0.timestamp >= since }))
                .map {
                    WeekStatsSample(
                        timestamp: $0.timestamp, words: $0.wordCount, audioDuration: $0.audioDuration, source: $0.source,
                        stopSource: $0.stopSource, pasteOutcome: $0.pasteOutcome, stopToPasteCommand: $0.stopToPasteCommand,
                        editObserved: $0.editObserved, editChanged: $0.editChanged, editDistance: $0.editDistance)
                }
            return WeekStats.compute(samples: samples, now: now, calendar: calendar) { day in
                let end = calendar.date(byAdding: .day, value: 1, to: day) ?? day
                let count = try? context.fetchCount(
                    FetchDescriptor<SessionMetric>(predicate: #Predicate { $0.timestamp >= day && $0.timestamp < end }))
                return (count ?? 0) > 0
            }
        }.value
    }
}

/// Home dashboard: this week's numbers, loading and refreshing themselves.
struct HomeWeekPanel: View {
    let modeSummary: String?

    @Environment(\.modelContext) private var modelContext
    @AppStorage(AutoLearnSettings.isEnabledKey) private var isAutoLearnEnabled = true
    @State private var stats = WeekStats.compute(
        samples: [], now: Date(), calendar: DashboardPeriodWindows.dashboardCalendar())
    @State private var metricChangeTask: Task<Void, Never>?

    var body: some View {
        HomeWeekPanelContent(stats: stats, modeSummary: modeSummary, isAutoLearnEnabled: isAutoLearnEnabled)
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
            // A new dictation, or Auto Learn's outcome for one, saved up to 60 s after its paste.
            .onReceive(
                NotificationCenter.default.publisher(for: .sessionMetricsDidChange)
                    .merge(with: NotificationCenter.default.publisher(for: .sessionEditOutcomeDidChange))
            ) { _ in
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
            #if DEBUG
                Self.reloads = (Self.reloads.count + 1, fresh)
            #endif
        }
    }

    #if DEBUG
        /// How many weeks the panel has loaded and the last one: `make home-feedback-perf` counts the fetches and
        /// checks what the last one saw.
        @MainActor static var reloads: (count: Int, last: WeekStats?) = (0, nil)
    #endif
}

struct HomeWeekPanelContent: View {
    let stats: WeekStats
    let modeSummary: String?
    /// Off: no paste is watched, so the unchanged share can't grow (and Home doesn't ask to turn it on).
    let isAutoLearnEnabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.x5) {
            header

            HStack(alignment: .bottom, spacing: AppTheme.Spacing.x6) {
                hero
                Spacer(minLength: 0)
                HomeWeekBars(dailyWords: stats.dailyWords, todayIndex: stats.todayIndex, weekStart: stats.weekStart)
                    .frame(width: 220)
            }

            // A note that doesn't fit wraps to a second line ("Dictez aujourd'hui pour la conserver"); the row's tiles
            // keep one height.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: AppTheme.Spacing.x3) { tiles }
                Grid(horizontalSpacing: AppTheme.Spacing.x3, verticalSpacing: AppTheme.Spacing.x3) {
                    let all = Array(tileModels.enumerated())
                    GridRow { ForEach(all.prefix(2), id: \.offset) { HomeStatTile(model: $0.element) } }
                    GridRow { ForEach(all.suffix(2), id: \.offset) { HomeStatTile(model: $0.element) } }
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: AppTheme.Spacing.x3) {
                HomeFeedbackCard(model: pasteWaitModel)
                HomeFeedbackCard(model: unchangedModel)
            }
            .fixedSize(horizontal: false, vertical: true)

            if stats.sessions > 0 {
                Text(
                    verbatim: DashboardTimeSaving.explanation(
                        timedPastes: stats.pastes.waits.count, dictations: stats.sessions)
                )
                .font(AppTheme.font(.caption))
                .foregroundStyle(AppTheme.Text.muted)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Median stop → ⌘V this week (docs/dictation-latency.md, "On Home").
    private var pasteWaitModel: HomeFeedbackCard.Model {
        let pastes = stats.pastes
        var lines: [String] = []
        if let median = pastes.waitMedian {
            lines.append(String(format: String(localized: "%lld timed pastes this week"), pastes.waits.count))
            if let change = stats.waitChangeVsLastWeek {
                lines.append(
                    String(
                        format: String(localized: "%@ s vs last week"),
                        change.formatted(.number.precision(.fractionLength(2)).sign(strategy: .always()))))
            } else {
                lines.append(String(localized: "Not enough from last week to compare"))
            }
            return .init(
                title: "Stop to paste", value: median.formatted(.number.precision(.fractionLength(2))),
                unit: "s median", lines: lines,
                footnote: String(localized: "From stopping a dictation to Yap sending ⌘V, not until the text shows up in the app."))
        }
        if !pastes.waits.isEmpty {
            lines.append(
                String(
                    format: String(localized: "Collecting: %1$lld so far, %2$lld needed"), pastes.waits.count,
                    WeekStats.minimumSamples))
        } else if stats.sessions > 0, stats.untimedSessions == stats.sessions {
            lines.append(String(localized: "Dictations saved by older versions of Yap weren't timed"))
        } else {
            lines.append(String(localized: "No timed pastes yet this week"))
        }
        return .init(
            title: "Stop to paste", value: "–", unit: nil, lines: lines,
            footnote: String(localized: "From stopping a dictation to Yap sending ⌘V, not until the text shows up in the app."))
    }

    /// Watched pastes left as pasted this week (docs/auto-learn.md, "On Home").
    private var unchangedModel: HomeFeedbackCard.Model {
        let pastes = stats.pastes
        var lines: [String] = []
        if !isAutoLearnEnabled {
            lines.append(String(localized: "Auto Learn is off, so new pastes aren't watched."))
        }
        let share = pastes.unchangedShare
        if share != nil {
            lines.append(
                String(
                    format: String(localized: "%1$lld of %2$lld watched pastes left as pasted"), pastes.unchanged,
                    pastes.watched))
        } else if pastes.watched > 0 {
            lines.append(
                String(
                    format: String(localized: "Collecting: %1$lld so far, %2$lld needed"), pastes.watched,
                    WeekStats.minimumSamples))
        } else if isAutoLearnEnabled {
            lines.append(String(localized: "No watched pastes yet this week"))
        }
        if pastes.count > 0 {
            lines.append(
                String(format: String(localized: "Watched %1$lld of %2$lld pastes this week"), pastes.watched, pastes.count))
        }
        if share != nil {
            if let points = stats.unchangedPointsVsLastWeek {
                lines.append(
                    String(
                        format: String(localized: "%@ pts vs last week"),
                        points.formatted(.number.precision(.fractionLength(0)).sign(strategy: .always()))))
            } else {
                lines.append(String(localized: "Not enough from last week to compare"))
            }
        }
        return .init(
            title: "Unchanged after paste",
            value: share.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "–", unit: nil, lines: lines,
            footnote: String(
                localized: "Auto Learn checks a paste for up to 60 s, until focus leaves the field. Not an accuracy score: changes after that aren't seen."))
    }

    /// The default mode's models, and the week on the right. The brand (icon, Yap, version) is in the sidebar.
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.x3) {
            if let modeSummary {
                Text(verbatim: modeSummary)
                    .font(AppTheme.font(.body))
                    .foregroundStyle(AppTheme.Text.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: AppTheme.Spacing.x3)

            Text(
                String(
                    format: String(localized: "This week · %@"),
                    (stats.weekStart..<stats.lastDayOfWeek).formatted(.interval.month(.abbreviated).day())
                )
            )
            .font(AppTheme.font(.footnote, .medium))
            .foregroundStyle(AppTheme.Text.secondary)
            .lineLimit(1)
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.x1) {
            HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.x2) {
                Text(stats.words, format: .number)
                    .font(AppTheme.font(.display, .semibold))
                    .monospacedDigit()
                    .foregroundStyle(AppTheme.Text.primary)
                    .contentTransition(.numericText())
                Text("words dictated")
                    .font(AppTheme.font(.body))
                    .foregroundStyle(AppTheme.Text.secondary)
            }
            .accessibilityElement(children: .combine)

            comparison
                .font(AppTheme.font(.footnote))
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
                Image(yapIcon: change >= 0 ? "arrow.up.right" : "arrow.down.right")
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
        let timeSaved = stats.timeSaved
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
                note: String(localized: "Estimate · 40 wpm"),
                spokenValue: Formatters.spokenHoursAndMinutes(timeSaved)),
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
        /// What VoiceOver reads instead of `value`, when that is abbreviated ("1h 5m").
        var spokenValue: String? = nil
    }

    let model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.x2) {
            HomeTileHeader(title: model.title, value: model.value, unit: model.unit, spokenValue: model.spokenValue)

            Text(verbatim: model.note)
                .font(AppTheme.font(.caption))
                .foregroundStyle(AppTheme.Text.muted)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(AppTheme.Spacing.x4)
        .accessibilityElement(children: .combine)
        .frame(minWidth: 128, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // A card like every other on Home (surface + 1px border, DESIGN.md), not a sunken well.
        .background(AppCardBackground(cornerRadius: AppTheme.Radius.card))
    }
}

/// A measured number with what it is counted from and what it doesn't mean: the value (or – while collecting), its
/// sample counts and comparison, and a footnote on what was measured.
struct HomeFeedbackCard: View {
    struct Model {
        let title: LocalizedStringKey
        let value: String
        let unit: LocalizedStringKey?
        let lines: [String]
        let footnote: String
    }

    let model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.x2) {
            HomeTileHeader(title: model.title, value: model.value, unit: model.unit)

            VStack(alignment: .leading, spacing: AppTheme.Spacing.half) {
                ForEach(model.lines, id: \.self) { line in
                    Text(verbatim: line)
                        .font(AppTheme.font(.footnote))
                        .monospacedDigit()
                        .foregroundStyle(AppTheme.Text.secondary)
                }
            }

            Spacer(minLength: 0)

            Text(verbatim: model.footnote)
                .font(AppTheme.font(.caption))
                .foregroundStyle(AppTheme.Text.muted)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(AppTheme.Spacing.x4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
        .background(AppCardBackground(cornerRadius: AppTheme.Radius.card))
    }
}

/// A Home tile's title over its number and unit.
private struct HomeTileHeader: View {
    let title: LocalizedStringKey
    let value: String
    let unit: LocalizedStringKey?
    var spokenValue: String? = nil

    var body: some View {
        Text(title)
            .font(AppTheme.font(.caption, .medium))
            .foregroundStyle(AppTheme.Text.secondary)
            .lineLimit(1)

        HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.x1) {
            Text(verbatim: value)
                .font(AppTheme.font(.title, .semibold))
                .monospacedDigit()
                .foregroundStyle(AppTheme.Text.primary)
                // "–" would be read as "en dash".
                .accessibilityLabel(value == "–" ? Text("No number yet") : Text(verbatim: spokenValue ?? value))
            if let unit {
                Text(unit)
                    .font(AppTheme.font(.footnote))
                    .foregroundStyle(AppTheme.Text.secondary)
            }
        }
        .lineLimit(1)
        // A number is never cut ("403h 21…"): too wide for four tiles in a row, the panel puts them in two.
        .fixedSize(horizontal: true, vertical: false)
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

        VStack(spacing: AppTheme.Spacing.x2) {
            HStack(alignment: .bottom, spacing: AppTheme.Spacing.x2) {
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

            HStack(spacing: AppTheme.Spacing.x2) {
                ForEach(0..<7, id: \.self) { index in
                    let day = calendar.date(byAdding: .day, value: index, to: weekStart) ?? weekStart
                    Text(day.formatted(.dateTime.weekday(.narrow)))
                        .font(AppTheme.font(.micro, index == todayIndex ? .semibold : .regular))
                        .foregroundStyle(index == todayIndex ? AppTheme.Text.primary : AppTheme.Text.muted)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Words per day this week"))
        .accessibilityValue(accessibilityDays(calendar: calendar))
    }

    /// "Mon 120, Tue 0, …" up to today; later days haven't happened.
    private func accessibilityDays(calendar: Calendar) -> String {
        (0...min(todayIndex, 6)).map { index in
            let day = calendar.date(byAdding: .day, value: index, to: weekStart) ?? weekStart
            let words = dailyWords.indices.contains(index) ? dailyWords[index] : 0
            return "\(day.formatted(.dateTime.weekday(.abbreviated))) \(words)"
        }
        .joined(separator: ", ")
    }

    @ViewBuilder
    private func bar(_ index: Int) -> some View {
        let words = dailyWords.indices.contains(index) ? dailyWords[index] : 0
        let shape = RoundedRectangle(cornerRadius: AppTheme.Radius.small, style: .continuous)

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
    HomeWeekPanelContent(stats: .previewSample, modeSummary: "⌥ Space · Scribe · gpt-5-mini", isAutoLearnEnabled: true)
        .padding(AppTheme.Spacing.x6)
        .frame(width: 760)
}
