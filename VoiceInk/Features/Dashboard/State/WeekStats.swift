import Foundation

/// One completed dictation, reduced to what the Home week panel needs.
struct WeekStatsSample: Sendable {
    let timestamp: Date
    let words: Int
    let audioDuration: TimeInterval
}

/// Monday-to-Sunday summary for the Home panel. Pure value, computed by `WeekStats.compute`.
struct WeekStats: Equatable, Sendable {
    /// How far back the loader fetches. Covers last week's comparison and caps the streak.
    // ponytail: streak tops out at 60 days; widen lookbackDays if long streaks need to show.
    static let lookbackDays = 60

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

    static func compute(samples: [WeekStatsSample], now: Date, calendar: Calendar) -> WeekStats {
        let today = calendar.startOfDay(for: now)
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? today
        let previousWeekStart = calendar.date(byAdding: .day, value: -7, to: weekStart) ?? weekStart
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
            } else if sample.timestamp >= previousWeekStart, sample.timestamp < previousCutoff {
                stats.previousWordsToDate += sample.words
            }
        }

        stats.hasSessionToday = activeDays.contains(today)
        var day = stats.hasSessionToday ? today : calendar.date(byAdding: .day, value: -1, to: today) ?? today
        while activeDays.contains(day) {
            stats.streakDays += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }

        return stats
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

        // Pace: 150 words in 60 s of audio.
        let pace = compute(samples: [sample(date(22, 9), 150, 60)], now: now, calendar: calendar)
        precondition(pace.wordsPerMinute == 150)
    }
}
#endif
