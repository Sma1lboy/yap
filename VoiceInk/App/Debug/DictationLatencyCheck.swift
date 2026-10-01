#if DEBUG
    import AppKit
    import SwiftData

    /// `make dictation-latency` (scripts/dictation-latency.sh): `--dictation-latency <rounds> --dictate-file <wav>…`.
    /// Dictates every file once per round through the normal stop → transcribe → deliver path, with the model loaded
    /// beforehand the way a press loads it while the user speaks, and CursorPaster.dryRun so ⌘V is timed but never
    /// sent. Prints one `dictation-latency:` JSON line per dictation, read back from its SessionMetric, then quits.
    /// One untimed dictation first pays for anything compiled on first use (Metal shaders). Every line carries
    /// `savedAfterPaste`, seconds from ⌘V to the History save. After the rounds, the first file is dictated six more
    /// times with the model released, as Keep model loaded: After Each Dictation does: three stopped while the press's
    /// preload is still loading, three pressed while the release is still running; their `loads` (model loads from the
    /// press to the paste) must be 1. Then once with a paste that fails: `inHistory` says it was saved all the same.
    @MainActor
    enum DictationLatencyCheck {
        static let argument = "--dictation-latency"

        static func runIfRequested(engine: VoiceInkEngine) -> Bool {
            let arguments = CommandLine.arguments
            guard let index = arguments.firstIndex(of: argument), arguments.indices.contains(index + 1),
                let rounds = Int(arguments[index + 1]), rounds > 0
            else { return false }
            let files = arguments.indices.dropLast()
                .filter { arguments[$0] == OfflineCheck.argument }
                .map { URL(fileURLWithPath: arguments[$0 + 1]) }
            guard !files.isEmpty else { return false }

            Task { @MainActor in
                try? await Task.sleep(for: .seconds(10))  // launch-time work settles, as in offline-check
                CursorPaster.dryRun = true
                let restorePasteboard = OfflineCheck.savePasteboard()

                // When each dictation's History entry was saved, from its ⌘V: the save comes after the paste.
                final class Saves { var afterPaste: [UUID: TimeInterval] = [:] }
                let saves = Saves()
                let observer = NotificationCenter.default.addObserver(
                    forName: .transcriptionCompleted, object: nil, queue: .main
                ) { note in
                    guard let transcription = note.object as? Transcription,
                        let command = CursorPaster.lastDryRunCommandTime
                    else { return }
                    saves.afterPaste[transcription.id] = ProcessInfo.processInfo.systemUptime - command
                }
                @MainActor func dictate(_ file: URL, measured: Bool = true) async -> Transcription {
                    CursorPaster.lastDryRunCommandTime = nil
                    return await engine.dictateFile(file, measured: measured)
                }
                @MainActor func report(
                    _ transcription: Transcription, clip: String, round: Int, scenario: [String: Any] = [:]
                ) {
                    var extra = scenario
                    extra["savedAfterPaste"] = saves.afterPaste[transcription.id]
                    Self.report(transcription, clip: clip, round: round, in: engine.modelContext, extra: extra)
                }

                await engine.loadCurrentModel()
                _ = await dictate(files[0], measured: false)
                for round in 1...rounds {
                    for file in files {
                        await engine.loadCurrentModel()
                        let transcription = await dictate(file)
                        report(transcription, clip: file.deletingPathExtension().lastPathComponent, round: round)
                    }
                }

                // Model loads from the press to the paste, for the scenarios below.
                final class Loads { var count = 0 }
                let loads = Loads()
                let load = engine.whisperModelManager.makeContext
                engine.whisperModelManager.makeContext = { file in
                    loads.count += 1
                    return try await load(file)
                }
                for round in 1...3 {
                    await engine.releaseModels()
                    loads.count = 0
                    engine.preloadCurrentModel()  // the press; the stop follows at once
                    let transcription = await dictate(files[0])
                    report(transcription, clip: "stop-during-load", round: round, scenario: ["loads": loads.count])
                }
                for round in 1...3 {
                    await engine.loadCurrentModel()
                    loads.count = 0
                    let release = Task { await engine.releaseModels() }  // the last dictation's release, still running
                    engine.preloadCurrentModel()
                    await release.value
                    let transcription = await dictate(files[0])
                    report(transcription, clip: "press-during-release", round: round, scenario: ["loads": loads.count])
                }

                // A paste that fails still leaves the dictation in History, saved to the store.
                await engine.loadCurrentModel()
                CursorPaster.dryRunResult = .commandNotPosted
                let failed = await dictate(files[0])
                CursorPaster.dryRunResult = .commandPosted
                let failedID = failed.id
                let stored = try? ModelContext(engine.modelContext.container).fetch(
                    FetchDescriptor<Transcription>(predicate: #Predicate { $0.id == failedID })
                ).first
                report(failed, clip: "paste-failed", round: 1, scenario: [
                    "inHistory": stored?.transcriptionStatus == TranscriptionStatus.completed.rawValue
                        && stored?.text.isEmpty == false
                ])

                NotificationCenter.default.removeObserver(observer)
                await engine.releaseModels()  // ggml asserts at exit() while any Metal buffer is still allocated
                restorePasteboard()
                fflush(stdout)
                exit(0)  // not NSApp.terminate, which can't finish from inside a Task (AppDelegate.applicationShouldTerminate)
            }
            return true
        }

        /// `extra` with `loads` or `inHistory` marks a scenario line, kept out of the timing table.
        private static func report(
            _ transcription: Transcription, clip: String, round: Int, in context: ModelContext, extra: [String: Any]
        ) {
            let id = transcription.id
            let metric = try? context.fetch(
                FetchDescriptor<SessionMetric>(predicate: #Predicate { $0.transcriptionId == id })
            ).first
            var line: [String: Any] = [
                "clip": clip, "round": round, "model": transcription.transcriptionModelName ?? "none",
                "audio": transcription.duration, "status": transcription.transcriptionStatus ?? "none",
                "characters": transcription.text.count,
            ]
            line.merge(extra) { _, new in new }
            if let metric {
                line["stopSource"] = metric.stopSource
                line["pasteOutcome"] = metric.pasteOutcome
                line["languages"] = metric.detectedLanguages
                line["languageDetection"] = metric.languageDetectionDuration
                let offsets: [(String, TimeInterval?)] = [
                    ("recorderStopped", metric.stopToRecorderStopped), ("modelReady", metric.stopToModelReady),
                    ("transcribed", metric.stopToTranscribed), ("processed", metric.stopToProcessed),
                    ("enhanced", metric.stopToEnhanced), ("pasteCommand", metric.stopToPasteCommand),
                ]
                for case let (name, value?) in offsets { line[name] = value }
            }
            if round == 1 { line["text"] = transcription.text }
            guard let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]),
                let json = String(data: data, encoding: .utf8)
            else { return }
            print("dictation-latency: \(json)")
        }
    }
#endif
