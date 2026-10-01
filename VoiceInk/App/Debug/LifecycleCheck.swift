#if DEBUG
    import AppKit
    import SwiftData

    /// `make lifecycle-check` (scripts/lifecycle-check.sh): launched with `--dictate-file <short clip>
    /// --lifecycle-check <suite> <long clip> <second-language clip> <mic.wav> <system.wav> [<longer clip>]`, runs one
    /// suite against the mode's local model through the app's own registry, engine, import queue and meeting recorder,
    /// printing one `lifecycle:` JSON line per result (IsolationCheck.emit); the script compares them.
    /// - `whisper`: speech detection a piece at a time against one whisper.cpp call on every clip; cancelling a
    ///   request waiting for its turn, one decoding, one in speech detection (the longer clip), one waiting for a load,
    ///   a dictation (Cancel during transcription) and an audio import, each followed by a request that must come out
    ///   as alone; a dictation queued behind a request in speech detection, with what it waits for as the recorder
    ///   shows it; the long clip alone again at the end, against the start (the Mac slowing down meanwhile).
    /// - `residency`: per "Keep model loaded" (Always, 5 s, After each dictation): whether the model is loaded right
    ///   after, and a while after, a live-preview session's final text, an audio import, a meeting and the wake
    ///   prewarm, and after a cancelled request; then a memory-pressure warning during a meeting.
    /// - `backend` (FluidAudio or transcribe.cpp as the mode's model): the short clip (mode language) and the
    ///   second-language clip alone, then started together; a release during a decode; a cancelled request in the
    ///   queue and one decoding; then Quit through NSApplication.terminate one second into a transcription, with what
    ///   the Quit waits for and whether its panel is up, every half second until the exit.
    @MainActor
    enum LifecycleCheck {
        static let argument = "--lifecycle-check"

        struct Request {
            let name: String
            let file: URL
            let model: any TranscriptionModel
            let context: TranscriptionRequestContext
        }

        static func run(engine: VoiceInkEngine, clip: URL, arguments: [String]) {
            if arguments.first == "download", arguments.count >= 2 {
                return download(fluidAudioModel: arguments[1])
            }
            guard arguments.count >= 5 else {
                print("lifecycle: usage --lifecycle-check <suite> <long clip> <second clip> <mic.wav> <system.wav>")
                exit(2)
            }
            let suite = arguments[0]
            let long = URL(fileURLWithPath: arguments[1])
            let second = URL(fileURLWithPath: arguments[2])
            let microphone = URL(fileURLWithPath: arguments[3])
            let system = URL(fileURLWithPath: arguments[4])
            let longer = arguments.count >= 6 ? URL(fileURLWithPath: arguments[5]) : nil
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(10))  // launch-time work settles, as in offline-check
                CursorPaster.dryRun = true
                let restorePasteboard = OfflineCheck.savePasteboard()
                let manager = engine.whisperModelManager
                let makeContext = manager.makeContext
                manager.makeContext = { file in
                    IsolationCheck.emit(["event": "load", "model": file.name])
                    return try await makeContext(file)
                }
                guard let configuration = ModeRuntimeResolver.transcriptionConfiguration(
                    transcriptionModelManager: engine.transcriptionModelManager)
                else {
                    print("lifecycle: no transcription model")
                    exit(1)
                }
                let checks = Checks(engine: engine, configuration: configuration, clip: clip, long: long, second: second,
                                    microphone: microphone, system: system, longer: longer)
                switch suite {
                case "whisper": await checks.whisper()
                case "residency": await checks.residency()
                case "backend":
                    await checks.backend()
                    restorePasteboard()
                    return  // ends with a real Quit
                default:
                    print("lifecycle: unknown suite \(suite)")
                    exit(2)
                }
                restorePasteboard()
                await engine.closeLocalModels()  // ggml asserts at exit() while any Metal buffer is still allocated
                IsolationCheck.emit(["event": "done"])
                exit(0)
            }
        }

        /// `--lifecycle-check download <name>`: the FluidAudio model through the app's own download (Models >
        /// Download), into `--fluidaudio-models <dir>` when given.
        private static func download(fluidAudioModel name: String) {
            Task { @MainActor in
                guard let model = TranscriptionModelRegistry.models.lazy.compactMap({ $0 as? FluidAudioModel })
                    .first(where: { $0.name == name })
                else {
                    print("lifecycle: unknown FluidAudio model \(name)")
                    exit(2)
                }
                let manager = FluidAudioModelManager()
                let started = Date()
                manager.startDownload(model)
                while !manager.isFluidAudioModelDownloaded(model) {
                    if let error = manager.downloadError(for: model) {
                        print("lifecycle: download failed \(error)")
                        exit(1)
                    }
                    try? await Task.sleep(for: .milliseconds(500))
                }
                while manager.isFluidAudioModelDownloading(model) { try? await Task.sleep(for: .milliseconds(200)) }
                IsolationCheck.emit(["event": "downloaded", "model": name, "seconds": Date().timeIntervalSince(started)])
                exit(0)
            }
        }

        @MainActor
        final class Checks {
            let engine: VoiceInkEngine
            let configuration: TranscriptionRuntimeConfiguration
            let clip, long, second, microphone, system: URL
            let longer: URL?
            var registry: TranscriptionServiceRegistry { engine.serviceRegistry }
            let activity = LocalModelActivity.shared

            init(engine: VoiceInkEngine, configuration: TranscriptionRuntimeConfiguration, clip: URL, long: URL,
                 second: URL, microphone: URL, system: URL, longer: URL?) {
                self.engine = engine
                self.configuration = configuration
                self.clip = clip
                self.long = long
                self.second = second
                self.microphone = microphone
                self.system = system
                self.longer = longer
            }

            func record(_ phase: String, _ request: String, _ result: [String: Any]) {
                IsolationCheck.emit(result.merging(["phase": phase, "request": request]) { $1 })
            }

            /// Whether the mode's model is in memory, whichever backend holds it.
            var loaded: Bool {
                switch configuration.model.provider {
                case .whisper: return engine.whisperModelManager.whisperContext != nil
                case .fluidAudio: return registry.fluidAudioTranscriptionService.hasLoadedManagers
                case .transcribeCpp: return registry.transcribeCppTranscriptionService.isModelLoaded
                default: return false
                }
            }

            func request(_ name: String, _ file: URL, language: String) -> Request {
                Request(
                    name: name, file: file, model: configuration.model,
                    context: TranscriptionRequestContext(
                        language: language,
                        prompt: configuration.model.provider == .whisper ? WhisperPrompt.resolvedPrompt(for: language) : nil))
            }

            /// A request in a task of its own, so it can be cancelled; the result says how it ended and when.
            func start(_ request: Request) -> Task<[String: Any], Never> {
                let registry = registry
                return Task { @MainActor in
                    let started = Date()
                    func ended(_ fields: [String: Any]) -> [String: Any] {
                        fields.merging(["seconds": Date().timeIntervalSince(started), "end": Date().timeIntervalSince1970]) { $1 }
                    }
                    do {
                        let result = try await registry.transcribeWithSegments(
                            audioURL: request.file, model: request.model, context: request.context)
                        return ended(["ok": true, "text": result.text, "segments": IsolationCheck.segments(result.segments)])
                    } catch is CancellationError {
                        return ended(["ok": false, "cancelled": true])
                    } catch {
                        return ended(["ok": false, "error": "\(error)"])
                    }
                }
            }

            func transcribe(_ request: Request) async -> [String: Any] { await start(request).value }

            func waitUntil(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
                let deadline = Date().addingTimeInterval(seconds)
                while !condition() {
                    if Date() > deadline { return false }
                    try? await Task.sleep(for: .milliseconds(20))
                }
                return true
            }

            /// The step of the oldest local-model work in flight, as the recorder and the Quit panel read it.
            var stage: LocalModelActivity.Stage? { activity.works.first?.stage }

            /// Cancels `task` once it has spent `after` seconds in `stage`; how long the cancel took and in which
            /// step it came.
            func cancel(_ task: Task<[String: Any], Never>, in stage: LocalModelActivity.Stage, after: Double)
                async -> [String: Any]
            {
                guard await waitUntil(60, { self.stage == stage }) else {
                    task.cancel()
                    return (await task.value).merging(["reachedStage": false]) { $1 }
                }
                try? await Task.sleep(for: .seconds(after))
                let stageAtCancel = self.stage
                let interruptible = activity.works.first?.interruptible ?? true
                let cancelAt = Date()
                task.cancel()
                // Still running a moment later (a step that can't stop): the work says it was cancelled.
                _ = await waitUntil(1) { self.activity.works.first?.cancelled ?? true }
                let marked = activity.works.first?.cancelled ?? true
                let result = await task.value
                return result.merging([
                    "reachedStage": true, "stageAtCancel": "\(stageAtCancel.map { "\($0)" } ?? "none")",
                    "interruptibleAtCancel": interruptible, "afterCancel": Date().timeIntervalSince(cancelAt),
                    "markedCancelled": marked, "loadedAfter": loaded,
                ]) { $1 }
            }

            // MARK: - whisper

            func whisper() async {
                let language = configuration.language
                let a = request("A", clip, language: language)
                let big = request("long", long, language: language)
                for _ in 0..<2 {
                    record("baseline", "A", await transcribe(a))
                    record("baseline", "long", await transcribe(big))
                }

                // Speech detection a piece at a time: whisper.cpp's own probabilities and segments, on every clip.
                if let context = engine.whisperModelManager.whisperContext {
                    for file in [clip, long, second, microphone, system] + [longer].compactMap({ $0 }) {
                        let samples = (try? WhisperTranscriptionService.readAudioSamples(file)) ?? []
                        record("vad-parity", file.lastPathComponent, await context.speechDetectionParity(samples))
                    }
                }

                // The longer clip (about 22 minutes): how long speech detection over it takes alone, then a cancel
                // during its decode; then cancels a tenth, half and nine tenths into speech detection.
                if let longer {
                    let huge = request("longer", longer, language: language)
                    var speechSeconds: [Double] = []
                    for round in 0..<2 {
                        let running = start(huge)
                        _ = await waitUntil(60) { self.stage == .speechDetection }
                        let began = Date()
                        _ = await waitUntil(900) { self.stage != .speechDetection }
                        speechSeconds.append(Date().timeIntervalSince(began))
                        record("speech-baseline", "longer", ["ok": true, "round": round, "seconds": speechSeconds.last!])
                        record("cancel-longer-decoding", "longer",
                               (await cancel(running, in: .decoding, after: 1)).merging(["round": round]) { $1 })
                    }
                    let speech = speechSeconds.sorted()[speechSeconds.count / 2]
                    for (round, fraction) in [0.1, 0.5, 0.9].enumerated() {
                        let running = start(huge)
                        let result = await cancel(running, in: .speechDetection, after: speech * fraction)
                        record("cancel-speech", "longer", result.merging(["round": round, "fraction": fraction]) { $1 })
                        record("cancel-speech-after", "A", await transcribe(a).merging(["round": round]) { $1 })
                    }

                    // A dictation queued behind a request in speech detection: what it waits for, as the recorder
                    // shows it; then that request is cancelled and the dictation completes.
                    let running = start(huge)
                    _ = await waitUntil(60) { self.stage == .speechDetection }
                    let dictating = IsolationCheck.Running { await self.dictate(self.clip) }
                    _ = await waitUntil(10) { self.activity.dictationWait(at: Date()) != nil }
                    let seen = activity.dictationWait(at: Date())
                    running.cancel()
                    _ = await running.value
                    _ = await waitUntil(120) { dictating.result != nil }
                    record("wait-visible", "dictation", (dictating.result ?? ["ok": false]).merging([
                        "waitSeen": seen != nil, "waitTitle": seen?.waitTitle ?? "", "waitStage": seen?.stageText ?? "",
                    ]) { $1 })
                }

                // Queued: the long request decodes, A waits for its turn and is cancelled there.
                for round in 0..<3 {
                    let running = start(big)
                    try? await Task.sleep(for: .milliseconds(300))
                    let queued = start(a)
                    try? await Task.sleep(for: .milliseconds(200))
                    let cancelAt = Date()
                    queued.cancel()
                    let cancelled = await queued.value
                    let afterCancel = Date().timeIntervalSince(cancelAt)
                    let first = await running.value
                    record("cancel-queued", "A", cancelled.merging(["round": round, "afterCancel": afterCancel]) { $1 })
                    record("cancel-queued", "long", first.merging(["round": round]) { $1 })
                    record("cancel-queued-after", "A", await transcribe(a).merging(["round": round]) { $1 })
                }

                // Cancelled 0.5-5 s in: in speech detection (stops between pieces) or in a decode (the next window or
                // whisper.cpp graph computation, its abort callback). The model stays loaded.
                for (round, offset) in [0.5, 2.0, 3.5, 5.0].enumerated() {
                    let decoding = start(big)
                    try? await Task.sleep(for: .seconds(offset))
                    let cancelAt = Date()
                    decoding.cancel()
                    let cancelled = await decoding.value
                    record("cancel-decoding", "long", cancelled.merging([
                        "round": round, "offset": offset, "loadedAfter": loaded,
                        "afterCancel": Date().timeIntervalSince(cancelAt),
                    ]) { $1 })
                    record("cancel-decoding-after", "A", await transcribe(a).merging(["round": round]) { $1 })
                }

                // Waiting for a load: the load finishes (another request may share it), this one doesn't decode.
                await engine.whisperModelManager.cleanupResources()
                let loading = start(a)
                _ = await waitUntil(5) { engine.whisperModelManager.isModelLoading }
                loading.cancel()
                record("cancel-loading", "A", (await loading.value).merging(["loadedAfter": loaded]) { $1 })
                record("cancel-loading-after", "A", await transcribe(a))

                // A dictation cancelled during its transcription: saved as cancelled, the next one completes.
                record("dictation-baseline", "dictation", await dictate(clip))
                let dictating = IsolationCheck.Running { await self.dictate(self.long) }
                _ = await waitUntil(10) { engine.recordingState == .transcribing }
                try? await Task.sleep(for: .milliseconds(500))
                let cancelAt = Date()
                await engine.cancelRecording()
                _ = await waitUntil(120) { dictating.result != nil }
                record("dictation-cancel", "dictation",
                       (dictating.result ?? [:]).merging(["afterCancel": Date().timeIntervalSince(cancelAt)]) { $1 })
                record("dictation-after", "dictation", await dictate(clip))

                // An audio import cancelled while transcribing: back to pending, no History entry; then it completes.
                let entriesBefore = importedEntries()
                let queue = AudioTranscriptionManager.shared
                let copy = FileManager.default.temporaryDirectory.appendingPathComponent("lifecycle-\(UUID()).wav")
                try? FileManager.default.copyItem(at: long, to: copy)
                queue.addToQueue(urls: [copy])
                guard let item = queue.queue.last, let mode = ModeManager.shared.currentEffectiveConfiguration else {
                    record("import-cancel", "import", ["ok": false, "error": "not queued"])
                    return
                }
                queue.startProcessing(modelContext: engine.modelContext, engine: engine, mode: mode)
                _ = await waitUntil(20) {
                    if case .processing(.transcribing) = item.status { return true }
                    return false
                }
                try? await Task.sleep(for: .milliseconds(500))
                queue.cancelProcessing()
                // How long the cancelled import still held the model: the next request waits for its turn.
                let next = await transcribe(request("A", clip, language: language))
                try? await Task.sleep(for: .seconds(12))  // longer than the whole file takes: nothing saved late
                record("import-cancel", "import", [
                    "ok": false, "status": "\(item.status)", "afterCancel": next["seconds"] ?? -1,
                    "nextOK": next["ok"] ?? false, "newEntries": importedEntries() - entriesBefore,
                ])
                queue.startProcessing(modelContext: engine.modelContext, engine: engine, mode: mode)
                _ = await waitUntil(300) { item.status.isTerminal && !queue.isProcessingQueue }
                record("import-after", "import", [
                    "ok": { if case .completed = item.status { return true } else { return false } }(),
                    "text": item.transcription?.text ?? "", "newEntries": importedEntries() - entriesBefore,
                ])

                // The live preview's final text, alone and with another model asked for mid-recording (its load frees
                // the model the preview decodes with). Neither may hang; both finals must come out as alone.
                record("preview", "long", await previewFinal(long))
                let models = engine.transcriptionModelManager.allAvailableModels
                if let otherName = engine.whisperModelManager.availableModels.map(\.name)
                    .first(where: { $0 != configuration.model.name }),
                    let other = models.first(where: { $0.name == otherName })
                {
                    let switchRequest = Request(name: "other", file: clip, model: other, context: a.context)
                    record("preview-switch", "long", await previewFinal(long, switchTo: switchRequest))
                } else {
                    record("preview-switch", "long", ["ok": false, "error": "no second Whisper model"])
                }

                // The long clip alone again: against the start, whether the Mac slowed down during the suite.
                record("baseline-end", "long", await transcribe(big))
                // Nothing left reported as running or waiting: every piece of work ended once.
                let idle = await waitUntil(5) { self.activity.works.isEmpty && self.activity.waits.isEmpty }
                record("activity-idle", "all", ["ok": idle, "works": activity.works.count, "waits": activity.waits.count])
            }

            func dictate(_ file: URL) async -> [String: Any] {
                let started = Date()
                let transcription = await engine.dictateFile(file)
                return ["ok": transcription.transcriptionStatus == TranscriptionStatus.completed.rawValue,
                        "status": transcription.transcriptionStatus ?? "none", "text": transcription.text,
                        "seconds": Date().timeIntervalSince(started)]
            }

            func importedEntries() -> Int {
                let entries = (try? engine.modelContext.fetch(FetchDescriptor<Transcription>())) ?? []
                return entries.filter { $0.audioFileURL?.contains("transcribed_") == true }.count
            }

            // MARK: - residency

            func residency() async {
                let language = configuration.language
                let a = request("A", clip, language: language)
                let big = request("long", long, language: language)
                for keep in [ModelResidency.keepAlways, 5, ModelResidency.keepAfterEach] {
                    UserDefaults.standard.set(keep, forKey: ModelResidency.keepSecondsKey)
                    // How long "a while after" is: the setting plus the timer's slack; After each: its 30 s grace.
                    let later = keep == ModelResidency.keepAfterEach ? ModelResidency.afterEachGraceSeconds + 6 : 9
                    let workloads: [(String, () async -> [String: Any])] = [
                        ("preview", { await self.previewFinal() }),
                        ("import", { await self.importFile() }),
                        ("meeting", { await self.meeting() }),
                        ("prewarm", { await self.prewarm() }),
                        ("cancelled", {
                            let decoding = self.start(big)
                            try? await Task.sleep(for: .milliseconds(500))
                            decoding.cancel()
                            return await decoding.value
                        }),
                    ]
                    for (name, workload) in workloads {
                        await engine.releaseModels()
                        let result = await workload()
                        let right = loaded
                        try? await Task.sleep(for: .seconds(later))
                        record("residency", name, result.merging([
                            "keep": keep, "loadedRightAfter": right, "loadedLater": loaded, "laterSeconds": later,
                        ]) { $1 })
                    }
                }

                // A memory-pressure warning during a meeting: no piece fails; the model goes once nothing uses it.
                UserDefaults.standard.set(ModelResidency.keepAlways, forKey: ModelResidency.keepSecondsKey)
                _ = await transcribe(a)  // loaded, kept by "Always"
                let running = IsolationCheck.Running { await self.meeting() }
                try? await Task.sleep(for: .seconds(1))
                ModelResidency.shared.simulateMemoryPressure()
                _ = await waitUntil(600) { running.result != nil }
                let meetingEnd = Date()
                let released = await waitUntil(15) { !self.loaded }
                record("pressure", "meeting", (running.result ?? [:]).merging([
                    "releasedAfterMeeting": released, "releaseSeconds": Date().timeIntervalSince(meetingEnd),
                ]) { $1 })
                record("pressure-after", "A", await transcribe(a))
            }

            /// The recorder's live-preview session (show live transcript on), `file` fed in real time, then its final
            /// text: OfflineCheck's preview check. A recording counts as busy for ModelResidency (the engine's
            /// recording state), so this runs as a use. With `switchTo`, that request (another model) runs `switchAfter`
            /// seconds in, freeing the model the preview decodes with.
            func previewFinal(_ file: URL? = nil, switchTo: Request? = nil, switchAfter: Double = 3) async -> [String: Any] {
                let file = file ?? clip
                UserDefaults.standard.set(true, forKey: RecorderDisplaySettingsKeys.showLiveTranscript)
                defer { UserDefaults.standard.removeObject(forKey: RecorderDisplaySettingsKeys.showLiveTranscript) }
                engine.preloadCurrentModel()  // as the shortcut press does
                var previews: [String] = []
                let session = registry.createSession(for: configuration) { previews.append($0) }
                return await ModelResidency.shared.withUse {
                    guard let feed = try? await session.prepare(configuration: configuration),
                        let data = try? Data(contentsOf: file)
                    else { return ["ok": false, "error": "no preview session"] }
                    let pcm = data.subdata(in: WhisperTranscriptionService.pcmDataOffset(data)..<data.count)
                    let recordingStart = Date()
                    var offset = 0
                    var switched: [String: Any] = [:]
                    var previewsBeforeSwitch = 0
                    while offset < pcm.count {
                        let next = min(pcm.count, offset + 3_200)  // 100 ms
                        feed(pcm.subdata(in: offset..<next))
                        offset = next
                        if let other = switchTo, switched.isEmpty, Date().timeIntervalSince(recordingStart) >= switchAfter {
                            previewsBeforeSwitch = previews.count
                            switched = await transcribe(other)
                        }
                        let due = recordingStart.addingTimeInterval(Double(offset) / 32_000)
                        if due > Date() { try? await Task.sleep(for: .seconds(due.timeIntervalSinceNow)) }
                    }
                    let started = Date()
                    do {
                        let text = try await session.transcribe(audioURL: file)
                        return ["ok": true, "text": text, "seconds": Date().timeIntervalSince(started),
                                "session": "\(type(of: session))", "previews": previews.count,
                                "previewsBeforeSwitch": previewsBeforeSwitch, "switchOK": switched["ok"] ?? false]
                    } catch {
                        return ["ok": false, "error": "\(error)"]
                    }
                }
            }

            func importFile() async -> [String: Any] {
                let queue = AudioTranscriptionManager.shared
                let copy = FileManager.default.temporaryDirectory.appendingPathComponent("lifecycle-\(UUID()).wav")
                try? FileManager.default.copyItem(at: clip, to: copy)
                queue.addToQueue(urls: [copy])
                guard let item = queue.queue.last, let mode = ModeManager.shared.currentEffectiveConfiguration else {
                    return ["ok": false, "error": "not queued"]
                }
                queue.startProcessing(modelContext: engine.modelContext, engine: engine, mode: mode)
                _ = await waitUntil(300) { item.status.isTerminal && !queue.isProcessingQueue }
                guard case .completed = item.status else { return ["ok": false, "error": "\(item.status)"] }
                return ["ok": true, "text": item.transcription?.text ?? ""]
            }

            func meeting() async -> [String: Any] {
                guard let (result, _) = await MeetingRecorder.shared.processFiles(microphone: microphone, system: system)
                else { return ["ok": false, "error": "no meeting"] }
                return ["ok": result.failedPieces == 0, "failedPieces": result.failedPieces]
            }

            /// The prewarm a wake from sleep starts (ModelPrewarmService, "Prewarm model on wake").
            func prewarm() async -> [String: Any] {
                NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
                let loadedByPrewarm = await waitUntil(30) { self.loaded }
                // The prewarm's transcription is still running when the model has just loaded.
                try? await Task.sleep(for: .seconds(3))
                return ["ok": loadedByPrewarm]
            }

            // MARK: - backend

            func backend() async {
                let language = configuration.language
                let a = request("A", clip, language: language)
                let b = request("B", second, language: "en")
                let big = request("long", long, language: language)
                for _ in 0..<2 {
                    record("baseline", "A", await transcribe(a))
                    record("baseline", "B", await transcribe(b))
                }
                for (round, delay) in [0, 0, 2, 10, 50].enumerated() {
                    for (x, y) in [(a, b), (b, a)] {
                        let first = start(x)
                        try? await Task.sleep(for: .milliseconds(delay))
                        let later = start(y)
                        record("same", x.name, (await first.value).merging(["round": round]) { $1 })
                        record("same", y.name, (await later.value).merging(["round": round, "delay": delay]) { $1 })
                    }
                }

                // The idle release (and memory pressure) during a decode: it goes after it, and the model is gone.
                let decoding = start(big)
                try? await Task.sleep(for: .milliseconds(300))
                let releaseAsked = Date()
                await registry.releaseAll()
                let releasedAt = Date()
                let decoded = await decoding.value
                record("release-during", "long", decoded.merging([
                    "loadedAfterRelease": loaded, "releaseSeconds": releasedAt.timeIntervalSince(releaseAsked),
                    "releasedAfterDecode": (decoded["end"] as? Double ?? .infinity) <= releasedAt.timeIntervalSince1970 + 0.05,
                ]) { $1 })
                let afterRelease = await transcribe(a)
                record("release-after", "A", afterRelease.merging(["loadedAfter": loaded]) { $1 })

                // Kept loaded between requests until a release asks.
                try? await Task.sleep(for: .seconds(2))
                record("kept", "A", ["ok": loaded])

                // Cancelled while waiting for a turn, and while decoding.
                let running = start(big)
                try? await Task.sleep(for: .milliseconds(300))
                let queued = start(a)
                try? await Task.sleep(for: .milliseconds(200))
                queued.cancel()
                record("cancel-queued", "A", await queued.value)
                record("cancel-queued", "long", await running.value)
                let cancelling = start(big)
                record("cancel-decoding", "long", await cancel(cancelling, in: .decoding, after: 0.7))
                record("cancel-after", "A", await transcribe(a))

                // Quit one second into a transcription, through NSApplication.terminate from the run loop.
                let inFlight = start(big)
                try? await Task.sleep(for: .seconds(1))
                NotificationCenter.default.addObserver(
                    forName: NSApplication.willTerminateNotification, object: nil, queue: .main
                ) { _ in
                    MainActor.assumeIsolated {
                        IsolationCheck.emit(["event": "will terminate", "loaded": self.loaded])
                    }
                }
                Task { @MainActor in
                    let result = await inFlight.value
                    self.record("quit-in-flight", "long", result)
                }
                // What the Quit panel shows while Quit waits, and whether it is up: the main actor keeps running.
                Task { @MainActor in
                    while true {
                        try? await Task.sleep(for: .milliseconds(500))
                        let work = self.activity.works.first
                        let panel = NSApp.windows.contains {
                            $0 is NSPanel && $0.isVisible && "\(type(of: $0.contentView as Any))".contains("QuitWaitView")
                        }
                        IsolationCheck.emit([
                            "event": "quit-wait", "title": work?.waitTitle ?? "", "stage": work?.stageText ?? "",
                            "interruptible": work?.interruptible ?? true, "panel": panel,
                        ])
                    }
                }
                IsolationCheck.emit(["event": "terminate"])
                RunLoop.main.perform(inModes: [.common]) { NSApplication.shared.terminate(nil) }
                CFRunLoopWakeUp(CFRunLoopGetMain())
            }
        }
    }
#endif
