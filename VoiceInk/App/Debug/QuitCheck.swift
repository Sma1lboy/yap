#if DEBUG
    import AppKit
    import Combine

    /// `make quit-check` (scripts/quit-check.sh): launched with `--dictate-file <wav> --quit-check <state>`, the app
    /// brings its local Whisper model to `state` and then quits through `NSApplication.terminate`, with nothing
    /// released first: `dictated` after a dictation of the file (loaded or not per "Keep model loaded"); `preloaded`
    /// after the shortcut-press preload has finished; `loading` while that preload is still loading; `decoding` while
    /// a dictation of the file is being transcribed; `importing` one second into the import of a long file
    /// (`--quit-import-file`); `twice` preloaded, then Quit twice in a row; `menubar` and `appmenu` preloaded, then the
    /// real "Quit Yap" item of the menu bar icon's menu or of the app menu (⌘Q) is performed, which runs the app's own
    /// action; `warmup` while the post-download warm-up runs; `previewing` three seconds into a recording with the
    /// live preview on; `meeting` while a meeting fed from `--quit-meeting-files <mic.wav> <system.wav>` records,
    /// answering "End Meeting and Quit".
    /// Prints `quit-check:` marker lines with Unix times; the script checks the exit status and the crash reports.
    @MainActor
    enum QuitCheck {
        static let argument = "--quit-check"
        /// The `meeting` case: AppDelegate's "A meeting is recording" question answers "End Meeting and Quit".
        nonisolated static var endsMeetingOnQuit: Bool { CommandLine.arguments.contains("--quit-meeting-files") }
        private static var loadingObserver: AnyCancellable?
        private static var warmupObserver: AnyCancellable?
        private static var meetingObserver: AnyCancellable?

        static func run(engine: VoiceInkEngine, file: URL, state: String) {
            let manager = engine.whisperModelManager
            func mark(_ name: String) {
                print("quit-check: \(name) \(Date().timeIntervalSince1970)")
                fflush(stdout)
            }
            NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification, object: nil, queue: .main
            ) { _ in
                MainActor.assumeIsolated { mark("will terminate, model loaded \(manager.whisperContext != nil)") }
            }
            /// From a run loop block, as a menu item's action or a quit Apple event arrives, not from inside a
            /// main-queue job (this Task): there, AppKit's wait for a `.terminateLater` reply can't run the main actor.
            func quit() {
                RunLoop.main.perform(inModes: [.common]) {
                    let menuItem = state == "menubar" || state == "appmenu" ? quitItem(in: state) : nil
                    if menuItem == nil, state == "menubar" || state == "appmenu" {
                        mark("no Quit Yap item in the \(state)")
                        exit(3)
                    }
                    mark("terminate, \(type(of: NSApp!)), model loaded \(manager.whisperContext != nil), loading \(manager.isModelLoading)")
                    if state == "twice" {
                        // A second ⌘Q while the first Quit is still closing (AppKit waits for its reply in a modal loop).
                        RunLoop.main.add(Timer(timeInterval: 0.01, repeats: false) { _ in
                            MainActor.assumeIsolated {
                                mark("terminate again, model loaded \(manager.whisperContext != nil)")
                                NSApplication.shared.terminate(nil)
                            }
                        }, forMode: .common)
                    }
                    if let (menu, index) = menuItem {
                        menu.performActionForItem(at: index)
                    } else {
                        NSApplication.shared.terminate(nil)
                    }
                    // Only when AppKit didn't quit: it ignores terminate: while a sheet is attached to a window.
                    mark("terminate returned, sheet attached \(NSApp.windows.contains { $0.attachedSheet != nil })")
                }
                CFRunLoopWakeUp(CFRunLoopGetMain())
            }
            /// The status item's menu is SwiftUI's MenuBarExtra (`.menu` style), filled when it opens.
            func quitItem(in place: String) -> (NSMenu, Int)? {
                let menu: NSMenu?
                if place == "appmenu" {
                    menu = NSApp.mainMenu?.items.first?.submenu
                } else {
                    let statusWindow = NSApp.windows.first { String(describing: type(of: $0)) == "NSStatusBarWindow" }
                    let item = statusWindow.flatMap {
                        $0.responds(to: Selector(("statusItem"))) ? $0.value(forKey: "statusItem") as? NSStatusItem : nil
                    }
                    menu = item?.menu
                }
                guard let menu else { return nil }
                menu.delegate?.menuNeedsUpdate?(menu)
                menu.delegate?.menuWillOpen?(menu)
                // "Quit Yap" in the status menu; the app menu's carries the display name ("Quit Yap Dev" in Debug).
                guard let index = menu.items.firstIndex(where: { $0.title.hasPrefix("Quit Yap") }) else {
                    print("quit-check: \(place) items \(menu.items.map(\.title))")
                    return nil
                }
                return (menu, index)
            }
            func waitForLoad() async {
                while !manager.isModelLoaded { try? await Task.sleep(for: .milliseconds(10)) }
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(10))
                let restorePasteboard = OfflineCheck.savePasteboard()
                defer { restorePasteboard() }
                switch state {
                case "dictated":
                    let transcription = await engine.dictateFile(file)
                    print("quit-check: text \(transcription.text)")
                case "preloaded", "twice", "menubar", "appmenu":
                    engine.preloadCurrentModel()
                    await waitForLoad()
                case "loading":
                    // Quit as the load starts: whisper.cpp takes a few hundred ms to read the model, off the main thread.
                    loadingObserver = manager.$isModelLoading.first { $0 }.sink { _ in quit() }
                    engine.preloadCurrentModel()
                    return
                case "appleevent":
                    // The script sends the quit Apple event (NSRunningApplication.terminate, as the Dock, logout and
                    // Sparkle's installer do) once this line is out.
                    engine.preloadCurrentModel()
                    await waitForLoad()
                    mark("terminate, \(type(of: NSApp!)), model loaded \(manager.whisperContext != nil), loading \(manager.isModelLoading), waiting for a quit Apple event")
                    return
                case "decoding":
                    Task { @MainActor in
                        let transcription = await engine.dictateFile(file)
                        mark("dictation finished: \(transcription.text)")
                    }
                    await waitForLoad()
                case "warmup":
                    // The warm-up a download starts (WhisperModelWarmupCoordinator, a context of its own), with the
                    // mode's model as the one just downloaded: Quit as soon as it is warming up.
                    guard let model = TranscriptionModelRegistry.models.lazy.compactMap({ $0 as? WhisperModel })
                        .first(where: { $0.name == manager.availableModels.first?.name })
                    else {
                        print("quit-check: no WhisperModel for \(manager.availableModels.map(\.name))")
                        exit(2)
                    }
                    let coordinator = WhisperModelWarmupCoordinator.shared
                    coordinator.scheduleWarmup(for: model, whisperModelManager: manager)
                    warmupObserver = coordinator.$warmingModels.dropFirst().first { $0.isEmpty }.sink { _ in
                        mark("warm-up finished, context freed")
                    }
                    try? await Task.sleep(for: .milliseconds(100))  // into createContext or the decode
                    mark("warming up, \(coordinator.isWarming(modelNamed: model.name))")
                case "importing":
                    // A long file in the audio import queue (`--quit-import-file`), Quit one second into its decode.
                    let arguments = CommandLine.arguments
                    guard let index = arguments.firstIndex(of: "--quit-import-file"), arguments.indices.contains(index + 1),
                        let mode = ModeManager.shared.currentEffectiveConfiguration
                    else {
                        print("quit-check: no file to import")
                        exit(2)
                    }
                    let queue = AudioTranscriptionManager.shared
                    queue.addToQueue(urls: [URL(fileURLWithPath: arguments[index + 1])])
                    queue.startProcessing(modelContext: engine.modelContext, engine: engine, mode: mode)
                    while true {
                        if case .processing(.transcribing) = queue.queue.last?.status { break }
                        try? await Task.sleep(for: .milliseconds(10))
                    }
                    try? await Task.sleep(for: .seconds(1))
                    mark("importing, \(queue.isProcessingQueue)")
                case "previewing":
                    // The live preview decoding while the file is "recorded" in real time; Quit three seconds in.
                    UserDefaults.standard.set(true, forKey: RecorderDisplaySettingsKeys.showLiveTranscript)
                    guard let configuration = ModeRuntimeResolver.transcriptionConfiguration(
                        transcriptionModelManager: engine.transcriptionModelManager),
                        let data = try? Data(contentsOf: file)
                    else {
                        print("quit-check: no preview")
                        exit(2)
                    }
                    engine.preloadCurrentModel()
                    var previews = 0
                    let session = engine.serviceRegistry.createSession(for: configuration) { _ in previews += 1 }
                    let feed = try? await session.prepare(configuration: configuration)
                    let pcm = data.subdata(in: WhisperTranscriptionService.pcmDataOffset(data)..<data.count)
                    let started = Date()
                    var offset = 0
                    while Date().timeIntervalSince(started) < 3, offset < pcm.count {
                        let next = min(pcm.count, offset + 3_200)
                        feed?(pcm.subdata(in: offset..<next))
                        offset = next
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    mark("previewing, \(type(of: session)) \(previews) previews")
                case "meeting":
                    let arguments = CommandLine.arguments
                    /// The menu bar item's width: the duck alone, or with the meeting's "● 00:02" next to it.
                    func statusItemWidth() -> Int {
                        Int(NSApp.windows.first { String(describing: type(of: $0)) == "NSStatusBarWindow" }?.frame.width ?? 0)
                    }
                    let idleWidth = statusItemWidth()
                    guard let index = arguments.firstIndex(of: "--quit-meeting-files"), arguments.indices.contains(index + 2),
                        MeetingRecorder.shared.startFromFiles(
                            microphone: URL(fileURLWithPath: arguments[index + 1]),
                            system: URL(fileURLWithPath: arguments[index + 2])) != nil
                    else {
                        print("quit-check: the meeting didn't start")
                        exit(2)
                    }
                    meetingObserver = MeetingRecorder.shared.$phase.first { if case .done = $0 { true } else { false } }
                        .sink { phase in
                            guard case .done(let result) = phase else { return }
                            mark("meeting saved, failed pieces \(result.failedPieces), save error \(result.saveError ?? "none")")
                        }
                    try? await Task.sleep(for: .seconds(2))  // the first pieces are transcribing
                    // How long a hop to the main actor takes while the meeting records (the pieces need it too).
                    let lag = await Task.detached { () -> TimeInterval in
                        let asked = Date()
                        await MainActor.run {}
                        return Date().timeIntervalSince(asked)
                    }.value
                    mark("meeting recording, \(MeetingRecorder.isRecordingMeeting), menu bar item \(idleWidth) → \(statusItemWidth()) pt, main actor hop \(String(format: "%.3f", lag)) s")
                default:
                    print("quit-check: unknown state \(state)")
                    exit(2)
                }
                quit()
            }
        }
    }
#endif
