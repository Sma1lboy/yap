#if DEBUG
    import AVFoundation
    import AppKit

    /// `make offline-check` (scripts/offline-check.sh): launched with `--dictate-file <wav>`, the app waits for
    /// launch-time work to settle, runs one dictation of that file through the normal pipeline, prints the result
    /// between `offline-check:` marker lines (Unix times, for matching against the script's socket log) and quits.
    /// The general pasteboard is put back afterwards, since delivery copies the text there.
    @MainActor
    enum OfflineCheck {
        static let argument = "--dictate-file"
        /// `--first-run-check <model name>`, with `--dictate-file`: scripts/first-run-check.sh.
        static let firstRunArgument = "--first-run-check"
        /// Also true for `--meeting-files`: both run the mock identity as a fresh install (no fake data).
        static var isRequested: Bool { CommandLine.arguments.contains(argument) || MeetingFilesCheck.isRequested }

        static func runIfRequested(engine: VoiceInkEngine) {
            let arguments = CommandLine.arguments
            guard let index = arguments.firstIndex(of: argument), arguments.indices.contains(index + 1) else { return }
            let file = URL(fileURLWithPath: arguments[index + 1])
            if arguments.contains("--residency-check") { return runResidency(engine: engine, file: file) }
            if let modelIndex = arguments.firstIndex(of: firstRunArgument), arguments.indices.contains(modelIndex + 1) {
                return runFirstRun(engine: engine, modelName: arguments[modelIndex + 1], file: file)
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(10))
                let pasteboard = NSPasteboard.general
                let saved = pasteboard.pasteboardItems?.map { item in
                    item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
                } ?? []
                print("offline-check: start \(Date().timeIntervalSince1970)")
                let transcription = await engine.dictateFile(file)
                print("offline-check: end \(Date().timeIntervalSince1970)")
                print("offline-check: model \(transcription.transcriptionModelName ?? "none")")
                print("offline-check: enhanced \(transcription.enhancedText != nil)")
                print("offline-check: seconds \(transcription.transcriptionDuration ?? 0)")
                print("offline-check: text \(transcription.text)")
                pasteboard.clearContents()
                pasteboard.writeObjects(saved.map { pairs in
                    let item = NSPasteboardItem()
                    pairs.forEach { item.setData($0.1, forType: $0.0) }
                    return item
                })
                try? await Task.sleep(for: .seconds(5))
                print("offline-check: quit \(Date().timeIntervalSince1970)")
                fflush(stdout)
                exit(0)  // NSApp.terminate is turned into "hide to the menu bar"
            }
        }

        /// `--residency-check` (scripts/model-residency-check.sh): dictates the clip against a model that is never
        /// loaded, kept, released by ModelResidency (the script sets a few seconds of "keep loaded"), reloaded
        /// without a preload, released again, and reloaded with a preload started 3 s before the dictation, as the
        /// shortcut press does while you speak. The script samples the process's footprint between the markers.
        private static func runResidency(engine: VoiceInkEngine, file: URL) {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(10))
                let pasteboard = NSPasteboard.general
                let saved = pasteboard.pasteboardItems?.map { item in
                    item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
                } ?? []
                let keep = UserDefaults.standard.integer(forKey: ModelResidency.keepSecondsKey)
                func mark(_ name: String) {
                    print("residency: mark \(name) \(Date().timeIntervalSince1970)")
                    fflush(stdout)
                }
                func dictate(_ name: String) async {
                    let t = Date()
                    let transcription = await engine.dictateFile(file)
                    print("residency: dictation \(name) total \(String(format: "%.2f", Date().timeIntervalSince(t))) s, transcription \(String(format: "%.2f", transcription.transcriptionDuration ?? 0)) s")
                    mark("after " + name)
                }
                mark("baseline")
                try? await Task.sleep(for: .seconds(3))
                await dictate("never loaded")
                try? await Task.sleep(for: .seconds(3))
                await dictate("kept loaded")
                mark("idle, loaded")
                try? await Task.sleep(for: .seconds(Double(keep) + 8))
                mark("idle, released")
                await dictate("released, no preload")
                try? await Task.sleep(for: .seconds(Double(keep) + 8))
                mark("idle, released again")
                engine.preloadCurrentModel()
                try? await Task.sleep(for: .seconds(3))
                await dictate("released, preload 3 s earlier")
                await engine.releaseModels()  // ggml asserts at exit() while any Metal buffer is still allocated
                pasteboard.clearContents()
                pasteboard.writeObjects(saved.map { pairs in
                    let item = NSPasteboardItem()
                    pairs.forEach { item.setData($0.1, forType: $0.0) }
                    return item
                })
                fflush(stdout)
                exit(0)
            }
        }

        /// `--preview-check`: the recorder's path for local Whisper with the live transcript on. The registry's
        /// session gets the file's PCM in real time through its chunk callback, as the recorder would send it; each
        /// preview text is printed with its time, then the final transcription is timed.
        private static func runLivePreview(engine: VoiceInkEngine, modelName: String, file: URL) async {
            let manager = engine.whisperModelManager
            if manager.whisperContext == nil, let model = manager.availableModels.first(where: { $0.name == modelName }) {
                try? await manager.loadModel(model)
            }
            guard
                let configuration = ModeRuntimeResolver.transcriptionConfiguration(
                    transcriptionModelManager: engine.transcriptionModelManager),
                let audio = try? AVAudioFile(forReading: file, commonFormat: .pcmFormatInt16, interleaved: true),
                let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length)),
                (try? audio.read(into: buffer)) != nil, let int16 = buffer.int16ChannelData
            else {
                print("first-run: preview check could not start")
                return
            }
            let pcm = Data(bytes: int16[0], count: Int(buffer.frameLength) * 2)
            let recordingStart = Date()
            let session = engine.serviceRegistry.createSession(for: configuration) { text in
                print("first-run: preview at \(String(format: "%.1f", Date().timeIntervalSince(recordingStart))) s: \(text)")
            }
            print("first-run: preview session \(type(of: session))")
            // Nil for a session without live text; the recording still takes its real time.
            let feed = try? await session.prepare(configuration: configuration)
            var offset = 0
            while offset < pcm.count {
                let next = min(pcm.count, offset + 3_200)  // 100 ms of 16 kHz Int16
                feed?(pcm.subdata(in: offset..<next))
                offset = next
                let due = recordingStart.addingTimeInterval(Double(offset) / 32_000)
                if due > Date() { try? await Task.sleep(for: .seconds(due.timeIntervalSinceNow)) }
            }
            let released = Date()
            let text = (try? await session.transcribe(audioURL: file)) ?? "(failed)"
            print("first-run: final with \(type(of: session)) \(Date().timeIntervalSince(released)) \(text)")
        }

        /// Fresh install without the model: download it through WhisperModelManager (as onboarding's Download
        /// button does), report what the shortcut's preflight says mid-download, then dictate the file twice.
        /// The first dictation includes loading the model cold; the second is warm. Times in seconds.
        private static func runFirstRun(engine: VoiceInkEngine, modelName: String, file: URL) {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                let manager = engine.whisperModelManager
                guard let model = TranscriptionModelRegistry.models.compactMap({ $0 as? WhisperModel })
                    .first(where: { $0.name == modelName })
                else {
                    print("first-run: unknown model \(modelName)")
                    exit(1)
                }
                let pasteboard = NSPasteboard.general
                let saved = pasteboard.pasteboardItems?.map { item in
                    item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
                } ?? []
                let start = Date()
                manager.startDownload(model)
                var reportedPreflight = false
                while !manager.availableModels.contains(where: { $0.name == modelName }) {
                    if let error = manager.downloadErrors[modelName] {
                        print("first-run: download failed \(error)")
                        exit(1)
                    }
                    if !reportedPreflight, (manager.downloadProgress[modelName + "_main"] ?? 0) > 0.05 {
                        reportedPreflight = true
                        print("first-run: preflight during download: \(engine.recordingStartFailure(modeId: nil)?.title ?? "none")")
                        if let detail = manager.downloadDetails[modelName + "_main"] { print("first-run: progress \(detail.summary)") }
                    }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                let downloaded = Date()
                print("first-run: download \(downloaded.timeIntervalSince(start))")
                print("first-run: preflight after download: \(engine.recordingStartFailure(modeId: nil)?.title ?? "none")")
                if CommandLine.arguments.contains("--wait-for-warmup") {
                    while WhisperModelWarmupCoordinator.shared.isWarming(modelNamed: modelName) {
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    print("first-run: warmup finished \(Date().timeIntervalSince(downloaded)) after the download")
                }
                for label in ["first dictation (cold)", "second dictation (warm)"] {
                    let t = Date()
                    let transcription = await engine.dictateFile(file)
                    print("first-run: \(label) \(Date().timeIntervalSince(t)) transcription \(transcription.transcriptionDuration ?? 0)")
                    print("first-run: text \(transcription.text)")
                }
                print("first-run: total \(Date().timeIntervalSince(start))")
                if CommandLine.arguments.contains("--preview-check") {
                    // Off, on, off, on: the same real-time recording with and without the preview.
                    for live in [false, true, false, true] {
                        UserDefaults.standard.set(live, forKey: RecorderDisplaySettingsKeys.showLiveTranscript)
                        await runLivePreview(engine: engine, modelName: modelName, file: file)
                    }
                    UserDefaults.standard.removeObject(forKey: RecorderDisplaySettingsKeys.showLiveTranscript)
                }
                // ggml asserts at exit() while any Metal buffer is still allocated.
                await manager.cleanupResources()
                pasteboard.clearContents()
                pasteboard.writeObjects(saved.map { pairs in
                    let item = NSPasteboardItem()
                    pairs.forEach { item.setData($0.1, forType: $0.0) }
                    return item
                })
                fflush(stdout)
                exit(0)
            }
        }
    }
#endif
