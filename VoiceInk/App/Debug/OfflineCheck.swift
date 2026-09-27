#if DEBUG
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
