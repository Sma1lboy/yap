#if DEBUG
    import AppKit
    import Combine

    /// `make quit-check` (scripts/quit-check.sh): launched with `--dictate-file <wav> --quit-check <state>`, the app
    /// brings its local Whisper model to `state` and then quits the way the menu bar's Quit does,
    /// `NSApplication.terminate`, with nothing released first:
    /// `dictated` after a dictation of the file (loaded or not per "Keep model loaded"); `preloaded` after the
    /// shortcut-press preload has finished; `loading` while that preload is still loading; `decoding` while a
    /// dictation of the file is being transcribed; `twice` preloaded, then Quit twice in a row.
    /// Prints `quit-check:` marker lines with Unix times; the script checks the exit status and the crash reports.
    @MainActor
    enum QuitCheck {
        static let argument = "--quit-check"
        private static var loadingObserver: AnyCancellable?

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
                    NSApplication.shared.terminate(nil)
                    // Only when AppKit didn't quit: it ignores terminate: while a sheet is attached to a window.
                    mark("terminate returned, sheet attached \(NSApp.windows.contains { $0.attachedSheet != nil })")
                }
                CFRunLoopWakeUp(CFRunLoopGetMain())
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
                case "preloaded", "twice":
                    engine.preloadCurrentModel()
                    await waitForLoad()
                case "loading":
                    // Quit as the load starts: whisper.cpp takes a few hundred ms to read the model, off the main thread.
                    loadingObserver = manager.$isModelLoading.first { $0 }.sink { _ in quit() }
                    engine.preloadCurrentModel()
                    return
                case "decoding":
                    Task { @MainActor in
                        let transcription = await engine.dictateFile(file)
                        mark("dictation finished: \(transcription.text)")
                    }
                    await waitForLoad()
                default:
                    print("quit-check: unknown state \(state)")
                    exit(2)
                }
                quit()
            }
        }
    }
#endif
