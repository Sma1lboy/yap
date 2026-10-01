#if DEBUG
    import AppKit
    import SwiftData

    /// `make dictation-latency` (scripts/dictation-latency.sh): `--dictation-latency <rounds> --dictate-file <wav>…`.
    /// Dictates every file once per round through the normal stop → transcribe → deliver path, with the model loaded
    /// beforehand the way a press loads it while the user speaks, and CursorPaster.dryRun so ⌘V is timed but never
    /// sent. Prints one `dictation-latency:` JSON line per dictation, read back from its SessionMetric, then quits.
    /// One untimed dictation first pays for anything compiled on first use (Metal shaders). After the rounds, the
    /// first file is dictated six more times with the model released, as Keep model loaded: After Each Dictation does:
    /// three stopped while the press's preload is still loading, three pressed while the release is still running.
    /// Those lines carry `loads`, the model loads from the press to the paste, which must be 1.
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

                await engine.loadCurrentModel()
                _ = await engine.dictateFile(files[0])
                for round in 1...rounds {
                    for file in files {
                        await engine.loadCurrentModel()
                        let transcription = await engine.dictateFile(file, measured: true)
                        report(transcription, clip: file.deletingPathExtension().lastPathComponent, round: round,
                            in: engine.modelContext)
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
                    let transcription = await engine.dictateFile(files[0], measured: true)
                    report(transcription, clip: "stop-during-load", round: round, in: engine.modelContext,
                        loads: loads.count)
                }
                for round in 1...3 {
                    await engine.loadCurrentModel()
                    loads.count = 0
                    let release = Task { await engine.releaseModels() }  // the last dictation's release, still running
                    engine.preloadCurrentModel()
                    await release.value
                    let transcription = await engine.dictateFile(files[0], measured: true)
                    report(transcription, clip: "press-during-release", round: round, in: engine.modelContext,
                        loads: loads.count)
                }

                await engine.releaseModels()  // ggml asserts at exit() while any Metal buffer is still allocated
                restorePasteboard()
                fflush(stdout)
                exit(0)  // NSApp.terminate is turned into "hide to the menu bar"
            }
            return true
        }

        private static func report(
            _ transcription: Transcription, clip: String, round: Int, in context: ModelContext, loads: Int? = nil
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
            if let loads { line["loads"] = loads }
            if let metric {
                line["stopSource"] = metric.stopSource
                line["pasteOutcome"] = metric.pasteOutcome
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
