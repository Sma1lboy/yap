import Foundation

/// One completed dictation, reduced to what the Home week panel needs.
struct WeekStatsSample: Sendable {
    let timestamp: Date
    let words: Int
    let audioDuration: TimeInterval
    /// Set only for a real dictation pasted with ⌘V (SessionMetric.isRealPaste).
    var paste: Paste? = nil
    /// Recorded before dictations had a timeline (no stopSource): nothing about its paste is known.
    var predatesTiming = false

    struct Paste: Equatable, Sendable {
        /// Stop → ⌘V in seconds (SessionMetric.measuredPasteWait); nil when it wasn't measured.
        var wait: TimeInterval?
        /// Auto Learn watched it to the end with a complete result: true left as pasted, false changed. Nil when it
        /// wasn't watched (off, refused, field cleared, sent, not found) or the result is incomplete.
        var unchanged: Bool?
    }
}

extension WeekStatsSample {
    /// From a SessionMetric's fields.
    init(
        timestamp: Date, words: Int, audioDuration: TimeInterval, source: String?, stopSource: String?,
        pasteOutcome: String?, stopToPasteCommand: TimeInterval?, editObserved: Bool?, editChanged: Bool?,
        editDistance: Double?
    ) {
        self.init(timestamp: timestamp, words: words, audioDuration: audioDuration)
        predatesTiming = stopSource == nil
        guard SessionMetric.isRealPaste(source: source, stopSource: stopSource, pasteOutcome: pasteOutcome) else { return }
        var unchanged: Bool?
        if editObserved == true, let editChanged, let editDistance, editDistance.isFinite, (0...1).contains(editDistance),
            editChanged == (editDistance > 0)
        {
            unchanged = !editChanged
        }
        paste = Paste(
            wait: SessionMetric.measuredPasteWait(
                source: source, stopSource: stopSource, pasteOutcome: pasteOutcome, stopToPasteCommand: stopToPasteCommand),
            unchanged: unchanged)
    }
}

/// One week's real ⌘V pastes (this week, or last week cut at the same weekday and time).
struct WeekPastes: Equatable, Sendable {
    /// Real dictations pasted with ⌘V.
    var count = 0
    /// Their measured stop → ⌘V times.
    var waits: [TimeInterval] = []
    /// Watched to the end with a complete result, and of those, left as pasted.
    var watched = 0
    var unchanged = 0

    /// Median stop → ⌘V; nil below WeekStats.minimumSamples.
    var waitMedian: TimeInterval? {
        guard waits.count >= WeekStats.minimumSamples else { return nil }
        let sorted = waits.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }

    /// Share of watched pastes left as pasted; nil below WeekStats.minimumSamples.
    var unchangedShare: Double? {
        guard watched >= WeekStats.minimumSamples else { return nil }
        return Double(unchanged) / Double(watched)
    }

    mutating func add(_ paste: WeekStatsSample.Paste) {
        count += 1
        if let wait = paste.wait { waits.append(wait) }
        if let unchanged = paste.unchanged {
            watched += 1
            if unchanged { self.unchanged += 1 }
        }
    }
}

/// Monday-to-Sunday summary for the Home panel. Pure value, computed by `WeekStats.compute`.
struct WeekStats: Equatable, Sendable {
    /// How far back the streak counts: today and this many days before it.
    // ponytail: streak tops out at 61 days; widen lookbackDays if long streaks need to show.
    static let lookbackDays = 60
    /// Fewer samples than this and Home shows the count, not a median or a share.
    static let minimumSamples = 5

    var weekStart: Date
    var lastDayOfWeek: Date
    var todayIndex: Int
    var words = 0
    var sessions = 0
    var audioDuration: TimeInterval = 0
    /// Words in last week's window cut at the same weekday and time as now.
    var previousWordsToDate = 0
    var dailyWords: [Int] = Array(repeating: 0, count: 7)
    var streakDays = 0
    var hasSessionToday = false
    var pastes = WeekPastes()
    /// Last week's pastes, cut at the same weekday and time as now.
    var previousPastes = WeekPastes()
    /// This week's dictations recorded before dictations had a timeline.
    var untimedSessions = 0

    /// Fractional change vs last week at the same point; nil when last week had nothing.
    var changeVsLastWeek: Double? {
        guard previousWordsToDate > 0 else { return nil }
        return Double(words - previousWordsToDate) / Double(previousWordsToDate)
    }

    /// Words per minute of recorded audio; nil without audio.
    var wordsPerMinute: Double? {
        guard audioDuration >= 1, words > 0 else { return nil }
        return Double(words) / (audioDuration / 60)
    }

    /// Median stop → ⌘V this week minus last week's at the same point, in seconds; nil unless both have enough.
    var waitChangeVsLastWeek: TimeInterval? {
        guard let now = pastes.waitMedian, let before = previousPastes.waitMedian else { return nil }
        return now - before
    }

    /// Unchanged share this week minus last week's at the same point, in percentage points; nil unless both have
    /// enough.
    var unchangedPointsVsLastWeek: Double? {
        guard let now = pastes.unchangedShare, let before = previousPastes.unchangedShare else { return nil }
        return (now - before) * 100
    }

    /// Time saved this week (DashboardTimeSaving), with the stop → ⌘V waits that were measured.
    var timeSaved: TimeInterval {
        DashboardTimeSaving.timeSaved(
            words: words, duration: audioDuration, measuredPasteWait: pastes.waits.reduce(0, +))
    }

    /// `wasActive` answers for days before last week's Monday, which the loader doesn't read samples for: only the
    /// streak reaches back that far.
    static func compute(
        samples: [WeekStatsSample], now: Date, calendar: Calendar, wasActive: (Date) -> Bool = { _ in false }
    ) -> WeekStats {
        let today = calendar.startOfDay(for: now)
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? today
        let previousWeekStart = Self.previousWeekStart(now: now, calendar: calendar)
        let previousCutoff = calendar.date(byAdding: .day, value: -7, to: now) ?? now

        var stats = WeekStats(
            weekStart: weekStart,
            lastDayOfWeek: calendar.date(byAdding: .day, value: 6, to: weekStart) ?? weekStart,
            todayIndex: calendar.dateComponents([.day], from: weekStart, to: today).day ?? 0
        )
        var activeDays = Set<Date>()

        for sample in samples where sample.timestamp <= now {
            activeDays.insert(calendar.startOfDay(for: sample.timestamp))

            if sample.timestamp >= weekStart {
                stats.words += sample.words
                stats.sessions += 1
                stats.audioDuration += sample.audioDuration
                let day = calendar.dateComponents([.day], from: weekStart, to: calendar.startOfDay(for: sample.timestamp)).day ?? 0
                if stats.dailyWords.indices.contains(day) {
                    stats.dailyWords[day] += sample.words
                }
                if let paste = sample.paste { stats.pastes.add(paste) }
                if sample.predatesTiming { stats.untimedSessions += 1 }
            } else if sample.timestamp >= previousWeekStart, sample.timestamp < previousCutoff {
                stats.previousWordsToDate += sample.words
                if let paste = sample.paste { stats.previousPastes.add(paste) }
            }
        }

        stats.hasSessionToday = activeDays.contains(today)
        let earliest = calendar.date(byAdding: .day, value: -lookbackDays, to: today) ?? today
        var day = stats.hasSessionToday ? today : calendar.date(byAdding: .day, value: -1, to: today) ?? today
        while day >= earliest, activeDays.contains(day) || (day < previousWeekStart && wasActive(day)) {
            stats.streakDays += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }

        return stats
    }

    /// Last week's Monday 00:00: the loader reads every dictation from here on.
    static func previousWeekStart(now: Date, calendar: Calendar) -> Date {
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: -7, to: weekStart) ?? weekStart
    }
}

#if DEBUG
extension WeekStats {
    /// Runs the boundary cases through `compute`; traps on the first mismatch.
    static func runSelfCheck() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        calendar.firstWeekday = 2

        func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
        }
        func sample(_ d: Date, _ words: Int, _ audio: TimeInterval = 30) -> WeekStatsSample {
            WeekStatsSample(timestamp: d, words: words, audioDuration: audio)
        }

        // Thursday Sep 24 2026, 15:00. Week starts Monday Sep 21.
        let now = date(24, 15)

        // Empty data.
        let empty = compute(samples: [], now: now, calendar: calendar)
        precondition(empty.weekStart == date(21, 0), "week starts Monday 00:00")
        precondition(empty.lastDayOfWeek == date(27, 0), "week ends Sunday")
        precondition(empty.todayIndex == 3, "Thursday is index 3")
        precondition(empty.words == 0 && empty.sessions == 0 && empty.streakDays == 0)
        precondition(empty.changeVsLastWeek == nil && empty.wordsPerMinute == nil)

        // Monday boundary: Sunday 23:59 belongs to last week, Monday 00:00 to this week.
        let boundary = compute(
            samples: [sample(date(20, 23, 59), 10), sample(date(21, 0), 20)],
            now: now, calendar: calendar)
        precondition(boundary.words == 20 && boundary.sessions == 1, "Monday 00:00 counts this week")
        precondition(boundary.dailyWords == [20, 0, 0, 0, 0, 0, 0])
        precondition(boundary.previousWordsToDate == 0, "last Sunday is past the same-point cutoff")

        // Same-point comparison: last week up to Thursday 15:00 only.
        let comparison = compute(
            samples: [
                sample(date(17, 14), 100),  // last Thu 14:00, before cutoff
                sample(date(17, 16), 900),  // last Thu 16:00, after cutoff
                sample(date(22, 9), 150),
            ],
            now: now, calendar: calendar)
        precondition(comparison.previousWordsToDate == 100, "cut last week at the same point")
        precondition(comparison.changeVsLastWeek == 0.5, "+50%")

        // Streak without today: Tue + Wed → 2, today not active.
        let noToday = compute(samples: [sample(date(22, 9), 5), sample(date(23, 9), 5)], now: now, calendar: calendar)
        precondition(noToday.streakDays == 2 && !noToday.hasSessionToday, "streak counts from yesterday")

        // Streak with today, gap on Monday stops it: Sun, Tue, Wed, Thu → 3.
        let withToday = compute(
            samples: [sample(date(20, 9), 5), sample(date(22, 9), 5), sample(date(23, 9), 5), sample(date(24, 8), 5)],
            now: now, calendar: calendar)
        precondition(withToday.streakDays == 3 && withToday.hasSessionToday, "streak includes today")

        // Every day since last Monday (Sep 14), and before that, what the loader's per-day count says: Sep 10–13
        // active, Sep 9 not → 11 + 4. Days inside the read window are never asked; the streak stops at 61 days.
        let everyDay = (14...24).map { sample(date($0, 9), 5) }
        var asked: [Date] = []
        let longer = compute(samples: everyDay, now: now, calendar: calendar) { day in
            asked.append(day)
            return day >= date(10, 0)
        }
        precondition(longer.streakDays == 15, "streak continues before the read window")
        precondition(asked == [date(13, 0), date(12, 0), date(11, 0), date(10, 0), date(9, 0)], "asked only while it lasts")
        let capped = compute(samples: everyDay, now: now, calendar: calendar) { _ in true }
        precondition(capped.streakDays == lookbackDays + 1, "today and 60 days before it")

        // Pace: 150 words in 60 s of audio.
        let pace = compute(samples: [sample(date(22, 9), 150, 60)], now: now, calendar: calendar)
        precondition(pace.wordsPerMinute == 150)

        runPasteSelfCheck(calendar: calendar, now: now) { date($0, $1) }
    }

    /// Stop → ⌘V and unchanged-after-paste: which metrics count, the 5-sample floor, medians, last week's same point.
    private static func runPasteSelfCheck(calendar: Calendar, now: Date, date: (Int, Int) -> Date) {
        /// A metric as SessionMetric stores it; the defaults are a real shortcut dictation pasted with ⌘V 0.8 s after
        /// the stop and left as pasted.
        func metric(
            _ at: Date, source: String? = "recorder", stop: String? = "shortcutRelease", outcome: String? = "pasted",
            wait: TimeInterval? = 0.8, observed: Bool? = true, changed: Bool? = false, distance: Double? = 0
        ) -> WeekStatsSample {
            WeekStatsSample(
                timestamp: at, words: 40, audioDuration: 10, source: source, stopSource: stop, pasteOutcome: outcome,
                stopToPasteCommand: wait, editObserved: observed, editChanged: changed, editDistance: distance)
        }
        func week(_ samples: [WeekStatsSample]) -> WeekStats { compute(samples: samples, now: now, calendar: calendar) }
        let tuesday = date(22, 9)
        // SessionMetric.isRealPaste spells out the raw values (yap-mcp builds it without DictationTimeline): every stop
        // but a file counts, and only `pasted`.
        for stop in DictationTimeline.StopSource.allCases {
            precondition(
                SessionMetric.isRealPaste(
                    source: "recorder", stopSource: stop.rawValue, pasteOutcome: DictationTimeline.PasteOutcome.pasted.rawValue)
                    == (stop != .file), "\(stop) out of step with SessionMetric.isRealPaste")
        }

        // Not a measured real paste: a file dictation, other outcomes, an older metric, an unknown stop. None of them
        // becomes a 0 s sample.
        let excluded = week([
            metric(tuesday, stop: "file"), metric(tuesday, outcome: "scratchpad"), metric(tuesday, outcome: "clipboardOnly"),
            metric(tuesday, outcome: "failed"), metric(tuesday, outcome: nil), metric(tuesday, stop: nil, outcome: nil),
            metric(tuesday, source: nil), metric(tuesday, stop: "somethingNew"),
        ])
        precondition(excluded.pastes == WeekPastes(), "not real ⌘V pastes")
        precondition(excluded.untimedSessions == 1 && excluded.sessions == 8, "the older metric counts as untimed only")
        // Pasted, but the time is missing, NaN, infinite or negative: a paste without a time.
        let badTimes = week([.nan, .infinity, -0.1, nil].map { metric(tuesday, wait: $0) })
        precondition(badTimes.pastes.count == 4 && badTimes.pastes.waits.isEmpty, "pasted, but not timed")
        precondition(badTimes.timeSaved == DashboardTimeSaving.timeSaved(words: 160, duration: 40, measuredPasteWait: 0))

        // 0, 4 and 5 samples: no median or share below 5.
        precondition(week([]).pastes.waitMedian == nil && week([]).pastes.unchangedShare == nil)
        let four = week((0..<4).map { _ in metric(tuesday) })
        precondition(four.pastes.waits.count == 4 && four.pastes.waitMedian == nil && four.pastes.unchangedShare == nil)
        let five = week([0.5, 0.9, 0.7, 2.4, 0.6].map { metric(tuesday, wait: $0) })
        precondition(five.pastes.waitMedian == 0.7 && five.pastes.unchangedShare == 1, "odd count: the middle one")
        let six = week([0.5, 0.9, 0.7, 2.4, 0.6, 0.8].map { metric(tuesday, wait: $0) })
        precondition(abs(six.pastes.waitMedian! - 0.75) < 1e-9, "even count: mean of the middle two")
        precondition(abs(six.timeSaved - (240.0 / 40 * 60 - 60 - 5.9)) < 1e-9, "time saved less the measured waits")

        // Unchanged share: watched with a complete result only. Refused, cleared, auto-sent, Auto Learn off (nil) and
        // incomplete results count neither way.
        let edits = week(
            (0..<4).map { _ in metric(tuesday) } + [
                metric(tuesday, changed: true, distance: 0.2),
                metric(tuesday, observed: false, changed: nil, distance: nil),  // secureField, fieldCleared, autoSent…
                metric(tuesday, observed: nil, changed: nil, distance: nil),  // Auto Learn off, or an older metric
                metric(tuesday, observed: true, changed: nil, distance: nil),  // incomplete
                metric(tuesday, observed: true, changed: false, distance: .nan),
                metric(tuesday, observed: true, changed: false, distance: 0.3),  // inconsistent
                metric(tuesday, outcome: "scratchpad"),  // not a ⌘V paste at all
            ])
        precondition(edits.pastes.count == 10 && edits.pastes.watched == 5 && edits.pastes.unchanged == 4)
        precondition(edits.pastes.unchangedShare == 0.8)

        // Last week to the same point (Thursday 15:00); the trend needs 5 samples there too.
        let lastWeek = (0..<5).map {
            metric(date(17, 14), wait: 1.0 + Double($0) * 0.1, changed: $0 == 0, distance: $0 == 0 ? 0.5 : 0)
        }
        let afterCutoff = (0..<5).map { _ in metric(date(17, 16), wait: 9, changed: true, distance: 1) }
        let thisWeek = (0..<5).map { _ in metric(tuesday) }
        let trend = week(lastWeek + afterCutoff + thisWeek)
        precondition(trend.previousPastes.count == 5, "last Thursday after 15:00 isn't compared")
        precondition(abs(trend.waitChangeVsLastWeek! - (0.8 - 1.2)) < 1e-9, "0.4 s faster")
        precondition(abs(trend.unchangedPointsVsLastWeek! - 20) < 1e-9, "100 % vs 80 %: +20 points")
        let thin = week(Array(lastWeek.prefix(4)) + thisWeek)
        precondition(thin.waitChangeVsLastWeek == nil && thin.unchangedPointsVsLastWeek == nil, "no trend from 4")
        // Sunday 23:59 is last week, past the cutoff; Monday 00:00 is this week.
        let edge = week([metric(date(20, 23)), metric(date(21, 0))])
        precondition(edge.pastes.count == 1 && edge.previousPastes.count == 0)
    }
}
#endif
