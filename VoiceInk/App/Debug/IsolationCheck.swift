#if DEBUG
    import AppKit
    import SwiftData

    /// `make isolation-check` (scripts/isolation-check.sh): launched with `--dictate-file <clip A> --isolation-check
    /// <clip B> <second model> <mic.wav> <system.wav>`, runs local Whisper requests that overlap and prints one
    /// `isolation:` JSON line per result; the script compares each with the same request run alone.
    /// 1. `same`: the mode's model, clip A in Chinese with one prompt and clip B in English with another. Two serial
    ///    runs each, then pairs started together, B delayed 0–50 ms, in both orders.
    /// 2. `import`: clip B through the audio import queue (its timed segments are saved with the entry), alone, then
    ///    while clip A is transcribed again and again.
    /// 3. `fail`: a Whisper model that isn't on disk fails, alone and next to clip A, which must still come out as
    ///    alone; then clip A again.
    /// 4. `meeting`: the two files as a meeting with the mode's model, alone; clip A dictated with the mode switched
    ///    to the second model, alone; then the meeting again while the mode is switched and clip A is dictated until
    ///    the meeting is done.
    /// Every Whisper model load is printed (`load`) to count the switches.
    @MainActor
    enum IsolationCheck {
        static let argument = "--isolation-check"

        struct Request {
            let name: String
            let file: URL
            let model: any TranscriptionModel
            let context: TranscriptionRequestContext
        }

        /// One JSON line, with the Unix time for the script's footprint samples.
        nonisolated static func emit(_ fields: [String: Any]) {
            let line = fields.merging(["t": Date().timeIntervalSince1970]) { old, _ in old }
            let data = (try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])) ?? Data()
            print("isolation: \(String(decoding: data, as: UTF8.self))")
            fflush(stdout)
        }

        nonisolated static func segments(_ list: [TimedSegment]) -> [[Any]] {
            list.map { [$0.start, $0.end, $0.text] }
        }

        static func run(engine: VoiceInkEngine, clipA: URL, arguments: [String]) {
            guard arguments.count >= 4 else {
                print("isolation: usage --isolation-check <clip B> <second model> <mic.wav> <system.wav>")
                exit(2)
            }
            let clipB = URL(fileURLWithPath: arguments[0])
            let secondName = arguments[1]
            let microphone = URL(fileURLWithPath: arguments[2])
            let system = URL(fileURLWithPath: arguments[3])
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(10))  // launch-time work settles, as in offline-check
                CursorPaster.dryRun = true
                let restorePasteboard = OfflineCheck.savePasteboard()
                let manager = engine.whisperModelManager
                let makeContext = manager.makeContext
                manager.makeContext = { file in
                    emit(["event": "load", "model": file.name])
                    return try await makeContext(file)
                }
                let models = engine.transcriptionModelManager.allAvailableModels
                guard
                    let configuration = ModeRuntimeResolver.transcriptionConfiguration(
                        transcriptionModelManager: engine.transcriptionModelManager),
                    let second = models.first(where: { $0.name == secondName }),
                    let missing = models.first(where: { model in
                        model.provider == .whisper && !manager.availableModels.contains { $0.name == model.name }
                    })
                else {
                    print("isolation: setup failed")
                    exit(1)
                }
                let first = configuration.model
                emit(["event": "models", "first": first.name, "second": second.name, "missing": missing.name])
                let a = Request(
                    name: "A", file: clipA, model: first,
                    context: TranscriptionRequestContext(language: "zh", prompt: "以下是普通话的句子，关于安全审查。"))
                let b = Request(
                    name: "B", file: clipB, model: first,
                    context: TranscriptionRequestContext(language: "en", prompt: "Standup notes: deploys, reviews, blockers."))
                let absent = Request(name: "missing", file: clipA, model: missing, context: a.context)

                /// `body`'s result with how long it took, in seconds.
                @MainActor func timed(_ body: () async -> [String: Any]) async -> [String: Any] {
                    let started = Date()
                    let result = await body()
                    return result.merging(["seconds": Date().timeIntervalSince(started)]) { $1 }
                }
                @MainActor func transcribe(_ request: Request) async -> [String: Any] {
                    await timed {
                        do {
                            let result = try await engine.serviceRegistry.transcribeWithSegments(
                                audioURL: request.file, model: request.model, context: request.context)
                            return ["ok": true, "text": result.text, "segments": segments(result.segments)]
                        } catch {
                            return ["ok": false, "error": "\(error)"]
                        }
                    }
                }
                @MainActor func record(_ phase: String, _ round: Int, _ request: String, _ result: [String: Any]) {
                    emit(result.merging(["phase": phase, "round": round, "request": request]) { $1 })
                }

                // 1. Same model, different language and prompt.
                for round in 0..<2 {
                    for request in [a, b] { record("same-serial", round, request.name, await transcribe(request)) }
                }
                var round = 0
                for delay in [0, 0, 2, 10, 50] {
                    for (x, y) in [(a, b), (b, a)] {
                        async let started = transcribe(x)
                        async let delayed: [String: Any] = {
                            try? await Task.sleep(for: .milliseconds(delay))
                            return await transcribe(y)
                        }()
                        let (one, two) = await (started, delayed)
                        record("same", round, x.name, one.merging(["delay": 0]) { $1 })
                        record("same", round, y.name, two.merging(["delay": delay]) { $1 })
                        round += 1
                    }
                }

                // 2. The import queue's saved segments while another request runs.
                @MainActor func importB() async -> [String: Any] {
                    await timed {
                        let queue = AudioTranscriptionManager.shared
                        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("isolation-\(UUID()).wav")
                        try? FileManager.default.copyItem(at: clipB, to: copy)
                        queue.addToQueue(urls: [copy])
                        guard let item = queue.queue.last, let mode = ModeManager.shared.currentEffectiveConfiguration
                        else { return ["ok": false, "error": "import not queued"] }
                        queue.startProcessing(modelContext: engine.modelContext, engine: engine, mode: mode)
                        while !item.status.isTerminal || queue.isProcessingQueue {
                            try? await Task.sleep(for: .milliseconds(20))
                        }
                        guard case .completed = item.status, let transcription = item.transcription else {
                            return ["ok": false, "error": "\(item.status)"]
                        }
                        return ["ok": true, "text": transcription.text,
                                "segments": segments(TimedSegments.decode(transcription.segmentsJSON))]
                    }
                }
                for round in 0..<2 { record("import-serial", round, "import", await importB()) }
                for round in 0..<3 {
                    let imported = Running { await importB() }
                    var index = 0
                    repeat {
                        record("import-other", round * 100 + index, "A", await transcribe(a))
                        index += 1
                    } while imported.result == nil
                    record("import", round, "import", imported.result ?? [:])
                }

                // 3. A failed request, alone and next to one that must succeed; then success again.
                record("fail-alone", 0, "missing", await transcribe(absent))
                record("fail-after", 0, "A", await transcribe(a))
                async let failing = transcribe(absent)
                async let succeeding = transcribe(a)
                let (failed, succeeded) = await (failing, succeeding)
                record("fail-beside", 0, "missing", failed)
                record("fail-beside", 0, "A", succeeded)
                record("fail-after", 1, "A", await transcribe(a))

                // 4. A meeting with the mode's model while dictation uses another one.
                @MainActor func meeting() async -> [String: Any] {
                    await timed {
                        guard let (result, _) = await MeetingRecorder.shared.processFiles(microphone: microphone, system: system)
                        else { return ["ok": false, "error": "no meeting"] }
                        return ["ok": true, "failedPieces": result.failedPieces, "text": result.transcript]
                    }
                }
                @MainActor func switchMode(to model: any TranscriptionModel) {
                    ModeManager.shared.updateCurrentEffectiveConfiguration { $0.selectedTranscriptionModelName = model.name }
                }
                @MainActor func dictate() async -> [String: Any] {
                    await timed {
                        let transcription = await engine.dictateFile(clipA)
                        return ["ok": transcription.transcriptionStatus == TranscriptionStatus.completed.rawValue,
                                "text": transcription.text, "model": transcription.transcriptionModelName ?? "none"]
                    }
                }
                record("meeting-serial", 0, "meeting", await meeting())
                switchMode(to: second)
                for round in 0..<2 { record("dictation-serial", round, "dictation", await dictate()) }
                switchMode(to: first)
                for round in 0..<2 {
                    let running = Running { await meeting() }
                    // processFiles reads the mode's configuration and queues the first pieces right away.
                    try? await Task.sleep(for: .milliseconds(100))
                    switchMode(to: second)
                    var index = 0
                    repeat {
                        record("dictation", round * 100 + index, "dictation", await dictate())
                        index += 1
                    } while running.result == nil
                    record("meeting", round, "meeting", running.result ?? [:])
                    switchMode(to: first)
                }

                restorePasteboard()
                await engine.closeLocalModels()  // ggml asserts at exit() while any Metal buffer is still allocated
                emit(["event": "done"])
                exit(0)
            }
        }

        /// `body` in a task of its own; `result` is set once it has finished.
        @MainActor
        final class Running {
            var result: [String: Any]?
            init(_ body: @escaping @MainActor () async -> [String: Any]) {
                Task { @MainActor in self.result = await body() }
            }
        }
    }
#endif
