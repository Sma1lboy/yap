#if DEBUG
    import AppKit
    import OSLog
    import SwiftData
    import SwiftUI

    /// `make home-feedback-perf`: Home's week panel on a heavy user's last 60 days (20,000 SessionMetrics, the same
    /// every run), in a stats.store on disk built the way the app builds it. The data is written once by its own launch
    /// (`--write`); each timing launch copies it and works on the copy, so every run is a new process opening the same
    /// file, and nothing it saves carries over. Prints one JSON line per measurement.
    @MainActor
    enum HomeFeedbackPerf {
        static let argument = "--home-feedback-perf"
        static let count = 20_000

        static func runIfRequested() {
            let arguments = CommandLine.arguments
            guard let index = arguments.firstIndex(of: argument), arguments.count > index + 1 else { return }
            let data = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
            MainActor.assumeIsolated {
                do {
                    if arguments.contains("--write") { try write(data) } else { try measure(data) }
                } catch {
                    print("home-feedback-perf: FAIL \(error)")
                    exit(1)
                }
            }
            fflush(stdout)
            exit(0)
        }

        private static func container(_ directory: URL) throws -> ModelContainer {
            try VoiceInkApp.createPersistentContainer(
                schema: YapStores.schema,
                logger: Logger(subsystem: "com.prakashjoshipax.voiceink", category: "HomeFeedbackPerf"), directory: directory)
        }

        // MARK: - Data

        /// 20,000 dictations over the 60 days before HomeFeedbackFixture.now, in the mix a long-time user's store has:
        /// metrics from versions before the timeline, modes on auto (one language, both) and on a fixed language,
        /// pastes that went to the Scratchpad or failed, missing times, every kind of edit outcome and none.
        private static func write(_ data: URL) throws {
            try? FileManager.default.removeItem(at: data)
            let started = Date()
            let context = ModelContext(try container(data))
            var random = MCPEvalFixture.SplitMix(seed: 60)
            let modes = (0..<4).map { UUID(uuidString: "00000000-0000-0000-0000-00000000000\($0)")! }
            let span = Double(WeekStats.lookbackDays) * 86_400
            for index in 0..<count {
                let when = HomeFeedbackFixture.now.addingTimeInterval(
                    -span * Double(index) / Double(count) - Double(random.next(60)))
                let metric = SessionMetric(
                    transcriptionId: UUID(), timestamp: when, wordCount: 5 + random.next(120),
                    audioDuration: 2 + Double(random.next(400)) / 10, transcriptionModelName: "Large v3 Turbo (Quantized)",
                    transcriptionDuration: 0.6, speedFactor: 12, modeName: ["Dictation", "Chat", "Email", "Code"][index % 4],
                    aiEnhancementModelName: random.next(3) == 0 ? "gpt-5-mini" : nil, enhancementDuration: nil)
                let kind = random.next(100)
                if kind >= 15 {  // 15 %: from a version before the timeline, every newer field nil
                    metric.stopSource = ["shortcutRelease", "shortcutPress", "recorderButton", "other"][random.next(4)]
                    metric.modeID = modes[random.next(4)]
                    if kind >= 25 {  // a mode on auto, with what Whisper detected; 10 % on a fixed language
                        metric.detectedLanguages = ["zh", "zh", "en", "en,zh", "zh,en"][random.next(5)]
                        metric.languageDetectionDuration = 0.44 + Double(random.next(8)) / 100
                    }
                    let outcome = random.next(100)
                    metric.pasteOutcome =
                        outcome < 80
                        ? "pasted" : outcome < 88 ? "scratchpad" : outcome < 93 ? "clipboardOnly" : outcome < 96 ? "failed" : nil
                    if outcome < 96, random.next(20) != 0 { metric.stopToPasteCommand = 0.6 + Double(random.next(90)) / 100 }
                    let edit = random.next(100)
                    if metric.pasteOutcome == "pasted", edit < 55 {
                        let distance = random.next(3) == 0 ? Double(1 + random.next(99)) / 100 : 0
                        metric.editObserved = true
                        metric.editChanged = distance > 0
                        metric.editDistance = distance
                    } else if metric.pasteOutcome == "pasted", edit < 75 {
                        metric.editObserved = false
                        metric.editUnobservableReason = ["fieldCleared", "autoSent", "secureField", "noReadableField"][
                            random.next(4)]
                    } else if metric.pasteOutcome == "pasted", edit < 78 {
                        metric.editObserved = true  // incomplete: counted neither way
                    }
                }
                context.insert(metric)
                if index % 1_000 == 999 { try context.save() }
            }
            try context.save()
            print(
                "home-feedback-perf: wrote \(try context.fetchCount(FetchDescriptor<SessionMetric>())) metrics in "
                    + "\(Int(Date().timeIntervalSince(started))) s")
        }

        // MARK: - Measuring

        /// The longest the main thread went without running a 5 ms timer, i.e. how long it was blocked.
        final class Heartbeat {
            private var last = ProcessInfo.processInfo.systemUptime
            private var longest: TimeInterval = 0
            private var timer: Timer?

            func start() {
                last = ProcessInfo.processInfo.systemUptime
                longest = 0
                let timer = Timer(timeInterval: 0.005, repeats: true) { [unowned self] _ in
                    MainActor.assumeIsolated {
                        let now = ProcessInfo.processInfo.systemUptime
                        longest = max(longest, now - last)
                        last = now
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
                self.timer = timer
            }

            /// In ms. Includes the time since the last tick, so a block still running at the end counts.
            func stop() -> Double {
                timer?.invalidate()
                longest = max(longest, ProcessInfo.processInfo.systemUptime - last)
                return (longest * 1000).rounded()
            }
        }

        private static func spin(until done: () -> Bool, timeout: TimeInterval = 30) {
            let deadline = Date().addingTimeInterval(timeout)
            while !done(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.002)) }
        }

        private static func spin(for seconds: TimeInterval) {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.002)) }
        }

        /// Loads the week the way the panel does, from the main actor, and how long until it had it (ms).
        private static func load(_ container: ModelContainer, now: Date) -> (WeekStats, Double) {
            var week: WeekStats?
            let started = ProcessInfo.processInfo.systemUptime
            var ended = started
            Task {
                week = try! await WeekStatsLoader.load(from: container, now: now)
                ended = ProcessInfo.processInfo.systemUptime
            }
            spin { week != nil }
            return (week!, (ended - started) * 1000)
        }

        private static func emit(_ line: [String: Any]) {
            let json = try! JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])
            print("home-feedback-perf: \(String(decoding: json, as: UTF8.self))")
            fflush(stdout)
        }

        private static func percentiles(_ values: [Double]) -> [String: Double] {
            let sorted = values.sorted()
            func at(_ p: Double) -> Double {
                (sorted[max(0, Int((Double(sorted.count) * p).rounded(.up)) - 1)] * 10).rounded() / 10
            }
            return ["p50": at(0.5), "p95": at(0.95), "max": at(1)]
        }

        private static func measure(_ source: URL) throws {
            guard FileManager.default.fileExists(atPath: source.appendingPathComponent("stats.store").path) else {
                throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: source.path])
            }
            let run = FileManager.default.temporaryDirectory.appendingPathComponent("yap-home-perf-\(UUID().uuidString)")
            try FileManager.default.copyItem(at: source, to: run)
            defer { try? FileManager.default.removeItem(at: run) }
            let heartbeat = Heartbeat()
            let now = HomeFeedbackFixture.now

            // Cold: a new process, a new container on the file, its first fetch.
            heartbeat.start()
            let opened = ProcessInfo.processInfo.systemUptime
            let container = try container(run)
            let openMs = (ProcessInfo.processInfo.systemUptime - opened) * 1000
            let (cold, coldMs) = load(container, now: now)
            emit([
                "phase": "cold", "openMs": openMs.rounded(), "loadMs": coldMs.rounded(), "mainBlockMs": heartbeat.stop(),
                "thisWeek": cold.sessions, "pasted": cold.pastes.count, "timed": cold.pastes.waits.count,
                "watched": cold.pastes.watched, "untimed": cold.untimedSessions, "streak": cold.streakDays,
                "metricsInStore": try ModelContext(container).fetchCount(FetchDescriptor<SessionMetric>()),
            ])

            // Warm: the same container again and again (the 60 s refresh, the reload after each dictation).
            heartbeat.start()
            var warm: [Double] = []
            for _ in 0..<30 {
                let (week, ms) = load(container, now: now)
                precondition(week == cold, "the same data loads the same week")
                warm.append(ms)
            }
            emit(["phase": "warm", "loads": warm.count, "loadMs": percentiles(warm), "mainBlockMs": heartbeat.stop()])

            // A late edit outcome as Auto Learn saves it: SessionEditRecorder finds the metric by its dictation on the
            // main context and saves, on the main thread.
            let main = container.mainContext
            let weekStart = cold.weekStart
            var unwatched = FetchDescriptor<SessionMetric>(
                predicate: #Predicate { $0.timestamp >= weekStart && $0.pasteOutcome == "pasted" && $0.editObserved == nil },
                sortBy: [SortDescriptor(\.timestamp)])
            unwatched.fetchLimit = 20
            let ids = try ModelContext(container).fetch(unwatched).map(\.transcriptionId)
            precondition(ids.count == 20)
            let recorder = SessionEditRecorder(modelContext: main)
            var edits: [Double] = []
            heartbeat.start()
            for id in ids {
                let started = ProcessInfo.processInfo.systemUptime
                recorder.record(.observed(distance: 0), for: id)
                edits.append((ProcessInfo.processInfo.systemUptime - started) * 1000)
                spin(for: 0.01)
            }
            let editBlock = heartbeat.stop()
            let (afterEdits, _) = load(container, now: now)
            precondition(afterEdits.pastes.watched == cold.pastes.watched + 20, "every outcome saved and read back")
            emit(["phase": "late-edit", "saves": edits.count, "mainMs": percentiles(edits), "mainBlockMs": editBlock])

            // The mode editor's detection time (newest 20 of one model on auto out of the 20,000), on the main context.
            // The model as TranscriptionModelRegistry lists it, built here: the registry also builds Yap Cloud's
            // catalog, which would fetch it and save it in the dev app's settings.
            let turbo = WhisperModel(
                name: "ggml-large-v3-turbo-q5_0", displayName: "Large v3 Turbo (Quantized)", size: "547 MB",
                supportedLanguages: [:], description: "", speed: 0.75, accuracy: 0.94, ramUsage: 1.0)
            var lookups: [Double] = []
            for _ in 0..<20 {
                let started = ProcessInfo.processInfo.systemUptime
                precondition(LanguagePinSuggestion.detectionCost(model: turbo, in: main) != nil)
                lookups.append((ProcessInfo.processInfo.systemUptime - started) * 1000)
            }
            emit(["phase": "detection-cost", "lookups": lookups.count, "mainMs": percentiles(lookups)])

            measurePanel(container)
        }

        /// The real panel in an offscreen window: how many times it fetches for a dictation and its late edit
        /// outcome, that the fetch after the outcome sees it, and that turning Auto Learn off fetches nothing.
        private static func measurePanel(_ container: ModelContainer) {
            let suite = "yap-home-perf-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set(true, forKey: AutoLearnSettings.isEnabledKey)
            HomeWeekPanel.reloads = []
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless], backing: .buffered,
                defer: false)
            let host = NSHostingView(
                rootView: HomeWeekPanel(modeSummary: nil).modelContainer(container).defaultAppStorage(defaults))
            host.frame = window.contentRect(forFrameRect: window.frame)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            spin { HomeWeekPanel.reloads.count == 1 }
            let first = HomeWeekPanel.reloads.count
            precondition(first == 1, "the panel loads once when it appears, not \(first) times")
            let main = container.mainContext
            let recorder = SessionEditRecorder(modelContext: main)

            /// A dictation saved and announced as the pipeline does it.
            func dictation() -> UUID {
                let metric = SessionMetric(
                    transcriptionId: UUID(), wordCount: 20, audioDuration: 5, transcriptionModelName: nil,
                    transcriptionDuration: nil, speedFactor: nil, modeName: nil, aiEnhancementModelName: nil,
                    enhancementDuration: nil)
                metric.stopSource = "shortcutRelease"
                metric.pasteOutcome = "pasted"
                metric.stopToPasteCommand = 0.7
                main.insert(metric)
                try! main.save()
                NotificationCenter.default.post(name: .sessionMetricsDidChange, object: nil)
                return metric.transcriptionId
            }
            // Its outcome 300 ms later, inside the panel's 500 ms wait; then another dictation whose outcome comes 2 s
            // after it.
            let before = HomeWeekPanel.reloads.last!
            let soon = dictation()
            spin(for: 0.3)
            recorder.record(.observed(distance: 0), for: soon)
            spin(for: 1.5)
            let burst = HomeWeekPanel.reloads.count - first
            let afterBurst = HomeWeekPanel.reloads.last!
            let late = dictation()
            spin(for: 2)
            let afterPaste = HomeWeekPanel.reloads.last!
            recorder.record(.observed(distance: 0.3), for: late)
            spin(for: 1.5)
            let separate = HomeWeekPanel.reloads.count - first - burst
            let afterLate = HomeWeekPanel.reloads.last!

            // Auto Learn turned off: the panel says so at once and fetches nothing new.
            let beforeOff = HomeWeekPanel.reloads.count
            defaults.set(false, forKey: AutoLearnSettings.isEnabledKey)
            spin(for: 1.5)
            let whenOff = HomeWeekPanel.reloads.count - beforeOff
            window.contentView = nil

            precondition(burst == 1, "a dictation and its outcome within 500 ms: one fetch, not \(burst)")
            precondition(afterBurst.pastes.count == before.pastes.count + 1)
            precondition(afterBurst.pastes.watched == before.pastes.watched + 1, "the fetch came after the outcome was saved")
            precondition(separate == 2, "a dictation, then its outcome 2 s later: two fetches, not \(separate)")
            precondition(afterPaste.pastes.watched == afterBurst.pastes.watched)
            precondition(afterLate.pastes.watched == afterBurst.pastes.watched + 1, "the late outcome is in the second")
            precondition(whenOff == 0, "turning Auto Learn off fetched \(whenOff) times")
            emit([
                "phase": "panel", "initialFetches": first, "fetchesForDictationAndOutcome300msApart": burst,
                "fetchesForDictationAndOutcome2sApart": separate, "fetchesWhenAutoLearnTurnedOff": whenOff,
            ])
        }
    }
#endif
