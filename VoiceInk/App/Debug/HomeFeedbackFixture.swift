#if DEBUG
    import Foundation
    import SwiftData

    /// Home's stop-to-paste and unchanged-after-paste numbers on fixed weeks of SessionMetrics: each scenario is
    /// written to its own in-memory stats store, saved, read back through `WeekStatsLoader` (the query Home runs) and
    /// checked against numbers worked out by hand. `make home-feedback-check` prints them; `make ui-snapshots` renders
    /// each one (home-feedback-*).
    @MainActor
    enum HomeFeedbackFixture {
        static let argument = "--home-feedback-check"

        struct Scenario {
            let name: String
            let isAutoLearnEnabled: Bool
            let metrics: [SessionMetric]
            /// Traps when the loaded week isn't what the metrics add up to.
            let check: (WeekStats) -> Void
        }

        /// Thursday 15:00 of the week of Sep 21 2026 on the dashboard calendar (Monday first, this Mac's time zone).
        static var now: Date {
            DashboardPeriodWindows.dashboardCalendar().date(
                from: DateComponents(year: 2026, month: 9, day: 24, hour: 15))!
        }

        static func scenarios() -> [Scenario] {
            let calendar = DashboardPeriodWindows.dashboardCalendar()
            /// `day` 0 is this Monday, −7 last Monday; `hour` on that day.
            func at(_ day: Int, _ hour: Double) -> Date {
                calendar.date(byAdding: .day, value: day, to: calendar.dateInterval(of: .weekOfYear, for: now)!.start)!
                    .addingTimeInterval(hour * 3600)
            }
            /// A real shortcut dictation pasted with ⌘V, unless told otherwise. `distance` nil and `reason` nil: Auto
            /// Learn didn't watch; `reason`: it couldn't; `distance`: it did.
            func metric(
                _ date: Date, stop: String? = "shortcutRelease", outcome: String? = "pasted", wait: Double? = 0.8,
                reason: String? = nil, distance: Double? = nil
            ) -> SessionMetric {
                let metric = SessionMetric(
                    transcriptionId: UUID(), timestamp: date, wordCount: 30, audioDuration: 9,
                    transcriptionModelName: "Large v3 Turbo (Quantized)", transcriptionDuration: 0.5, speedFactor: 18,
                    modeName: "Dictation", aiEnhancementModelName: nil, enhancementDuration: nil)
                metric.stopSource = stop
                metric.pasteOutcome = outcome
                metric.stopToPasteCommand = stop == nil ? nil : wait
                if let reason {
                    metric.editObserved = false
                    metric.editUnobservableReason = reason
                } else if let distance {
                    metric.editObserved = true
                    metric.editChanged = distance > 0
                    metric.editDistance = distance
                }
                return metric
            }
            func near(_ a: Double?, _ b: Double) -> Bool { a.map { abs($0 - b) < 1e-9 } == true }

            // This week Mon–Thu: 14 real pastes, 10 watched to the end (8 left as pasted), 2 refused (field cleared,
            // auto-sent), 2 not watched; a file dictation and a Scratchpad paste that don't count. Last week before
            // Thursday 15:00: 9 pastes, 8 watched, 6 unchanged; three slow ones after 15:00 aren't compared.
            let waits = [0.62, 0.71, 0.68, 0.95, 0.74, 1.32, 0.66, 0.81, 0.77, 0.70, 0.88, 0.69, 0.73, 0.79]
            let edits: [(String?, Double?)] =
                Array(repeating: (nil, 0), count: 8) + [(nil, 0.12), (nil, 0.4), ("fieldCleared", nil), ("autoSent", nil),
                (nil, nil), (nil, nil)]
            var data = zip(waits, edits).enumerated().map { index, pair in
                metric(at(index % 4, 8 + Double(index) / 4), wait: pair.0, reason: pair.1.0, distance: pair.1.1)
            }
            data += [metric(at(1, 11), stop: "file", wait: 0.3, distance: 0), metric(at(2, 12), outcome: "scratchpad", wait: nil)]
            let lastWaits = [0.9, 1.0, 1.1, 1.2, 1.3, 0.95, 1.05, 1.15, 1.25]
            data += lastWaits.enumerated().map { index, wait in
                metric(at(-7 + index % 4, 8 + Double(index) / 4), wait: wait, distance: index < 8 ? (index < 6 ? 0 : 0.3) : nil)
            }
            data += (0..<3).map { metric(at(-4, 16 + Double($0)), wait: 3, distance: 1) }

            return [
                Scenario(name: "data", isAutoLearnEnabled: true, metrics: data) { week in
                    precondition(week.pastes.count == 14 && week.pastes.waits.count == 14, "file and Scratchpad left out")
                    precondition(near(week.pastes.waitMedian, 0.735), "median of 14: (0.73 + 0.74) / 2")
                    precondition(week.pastes.watched == 10 && week.pastes.unchanged == 8 && week.pastes.unchangedShare == 0.8)
                    precondition(week.previousPastes.count == 9 && near(week.previousPastes.waitMedian, 1.1))
                    precondition(near(week.waitChangeVsLastWeek, -0.365) && near(week.unchangedPointsVsLastWeek, 5))
                },
                // Only dictations from before the timeline: nothing to time or watch.
                Scenario(
                    name: "older-version", isAutoLearnEnabled: true,
                    metrics: (0..<9).map { metric(at($0 % 4, 10), stop: nil, outcome: nil) }
                ) { week in
                    precondition(week.sessions == 9 && week.untimedSessions == 9 && week.pastes == WeekPastes())
                },
                // Three pastes: counts, no median or share.
                Scenario(
                    name: "few", isAutoLearnEnabled: true,
                    metrics: [metric(at(0, 9), wait: 0.7, distance: 0), metric(at(1, 9), wait: 0.9, distance: 0), metric(at(2, 9), wait: 0.8)]
                ) { week in
                    precondition(week.pastes.waits.count == 3 && week.pastes.waitMedian == nil)
                    precondition(week.pastes.watched == 2 && week.pastes.unchangedShare == nil)
                },
                // Auto Learn off: pasted and timed, never watched. Nil isn't "unchanged".
                Scenario(
                    name: "auto-learn-off", isAutoLearnEnabled: false,
                    metrics: (0..<8).map { metric(at($0 % 4, 8 + Double($0) / 4), wait: 0.6 + Double($0) * 0.05) }
                ) { week in
                    precondition(week.pastes.count == 8 && week.pastes.watched == 0 && week.pastes.unchangedShare == nil)
                    precondition(near(week.pastes.waitMedian, 0.775))
                },
                // 20 pastes, 6 watched (5 unchanged), the rest refused; last week 5 of 5 unchanged.
                Scenario(
                    name: "low-coverage", isAutoLearnEnabled: true,
                    metrics: (0..<20).map { index in
                        let reasons = ["noReadableField", "pastedTextNotFound", "secureField"]
                        return metric(
                            at(index % 4, 8 + Double(index) / 4), wait: 0.7 + Double(index % 5) * 0.02,
                            reason: index < 6 ? nil : reasons[index % 3], distance: index < 6 ? (index == 0 ? 0.25 : 0) : nil)
                    } + (0..<7).map { metric(at(-7 + $0 % 3, 10), distance: $0 < 5 ? 0 : nil) }
                ) { week in
                    precondition(week.pastes.count == 20 && week.pastes.watched == 6 && week.pastes.unchanged == 5)
                    precondition(week.previousPastes.watched == 5 && near(week.unchangedPointsVsLastWeek, (5.0 / 6 - 1) * 100))
                },
                // Enough this week, nothing last week: no trend.
                Scenario(
                    name: "no-last-week", isAutoLearnEnabled: true,
                    metrics: (0..<7).map { metric(at($0 % 4, 8 + Double($0) / 4), wait: 0.7, distance: $0 < 6 ? ($0 == 0 ? 0.2 : 0) : nil) }
                ) { week in
                    precondition(week.pastes.unchangedShare != nil && week.pastes.waitMedian == 0.7)
                    precondition(week.previousPastes == WeekPastes() && week.waitChangeVsLastWeek == nil)
                    precondition(week.unchangedPointsVsLastWeek == nil)
                },
            ]
        }

        /// Writes the scenario to a fresh in-memory store, saves, and loads the week the way Home does.
        static func load(_ scenario: Scenario) -> WeekStats {
            let container = try! ModelContainer(
                for: SessionMetric.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            let context = ModelContext(container)
            scenario.metrics.forEach(context.insert)
            try! context.save()
            var loaded: WeekStats?
            Task { loaded = try! await WeekStatsLoader.load(from: container, now: now) }
            while loaded == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            scenario.check(loaded!)
            return loaded!
        }

        static func runIfRequested() {
            guard CommandLine.arguments.contains(argument) else { return }
            MainActor.assumeIsolated {
                WeekStats.runSelfCheck()
                print("home-feedback-check: WeekStats.runSelfCheck ok")
                for scenario in scenarios() {
                    let week = load(scenario)
                    let line: [String: Any] = [
                        "scenario": scenario.name, "autoLearn": scenario.isAutoLearnEnabled,
                        "dictations": week.sessions, "untimed": week.untimedSessions, "pasted": week.pastes.count,
                        "timed": week.pastes.waits.count, "medianSeconds": week.pastes.waitMedian ?? NSNull(),
                        "watched": week.pastes.watched, "unchanged": week.pastes.unchanged,
                        "unchangedShare": week.pastes.unchangedShare ?? NSNull(),
                        "lastWeekPasted": week.previousPastes.count,
                        "waitChangeSeconds": week.waitChangeVsLastWeek ?? NSNull(),
                        "unchangedChangePoints": week.unchangedPointsVsLastWeek ?? NSNull(),
                        "timeSavedSeconds": week.timeSaved.rounded(),
                    ]
                    let json = try! JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])
                    print("home-feedback-check: \(String(decoding: json, as: UTF8.self))")
                }
                do { try SessionEditRecorder.selfCheck() } catch { fatalError("SessionEditRecorder: \(error)") }
                print("home-feedback-check: SessionEditRecorder.selfCheck ok (a late edit outcome is saved, then Home reloads)")
            }
            fflush(stdout)
            exit(0)
        }
    }
#endif
