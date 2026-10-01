#if DEBUG
    import AppKit
    import SwiftData

    /// `make dictation-latency` (scripts/dictation-latency.sh): `--dictation-latency <rounds> --dictate-file <wav>…`.
    /// Dictates every file once per round through the normal stop → transcribe → deliver path, with the model loaded
    /// beforehand the way a press loads it while the user speaks, and CursorPaster.dryRun so ⌘V is timed but never
    /// sent. Prints one `dictation-latency:` JSON line per dictation, read back from its SessionMetric, then quits.
    /// One untimed dictation first pays for anything compiled on first use (Metal shaders).
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

                await engine.preloadTranscriptionModel()
                _ = await engine.dictateFile(files[0])
                for round in 1...rounds {
                    for file in files {
                        await engine.preloadTranscriptionModel()
                        let transcription = await engine.dictateFile(file, measured: true)
                        report(transcription, clip: file.deletingPathExtension().lastPathComponent, round: round,
                            in: engine.modelContext)
                    }
                }

                await engine.whisperModelManager.cleanupResources()  // ggml asserts at exit with Metal buffers left
                restorePasteboard()
                fflush(stdout)
                exit(0)  // NSApp.terminate is turned into "hide to the menu bar"
            }
            return true
        }

        private static func report(_ transcription: Transcription, clip: String, round: Int, in context: ModelContext) {
            let id = transcription.id
            let metric = try? context.fetch(
                FetchDescriptor<SessionMetric>(predicate: #Predicate { $0.transcriptionId == id })
            ).first
            var line: [String: Any] = [
                "clip": clip, "round": round, "model": transcription.transcriptionModelName ?? "none",
                "audio": transcription.duration, "status": transcription.transcriptionStatus ?? "none",
                "characters": transcription.text.count,
            ]
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
