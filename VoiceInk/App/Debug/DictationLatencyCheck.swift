#if DEBUG
    import AppKit
    import SwiftData

    /// `make dictation-latency` (scripts/dictation-latency.sh): `--dictation-latency <rounds> --dictate-file <wav>…`.
    /// Dictates every file once per round through the normal stop → transcribe → deliver path, with the model loaded
    /// beforehand the way a press loads it while the user speaks, and CursorPaster's check outlets (a private
    /// pasteboard, no key sent) so ⌘V is timed but never sent. Prints one `dictation-latency:` JSON line per
    /// dictation, read back from its SessionMetric, then quits.
    /// One untimed dictation first pays for anything compiled on first use (Metal shaders). Every line carries
    /// `savedAfterPaste`, seconds from ⌘V to the History save. After the rounds, the first file is dictated six more
    /// times with the model released, as Keep model loaded: After Each Dictation does: three stopped while the press's
    /// preload is still loading, three pressed while the release is still running; their `loads` (model loads from the
    /// press to the paste) must be 1. Then once with a paste that fails: `inHistory` says it was saved all the same.
    /// Last, Rewrite Last Dictation through the engine (`rewrites`): one `dictation-rewrite:` line per scenario.
    @MainActor
    enum DictationLatencyCheck {
        /// When ⌘V would have gone out for the current dictation; what the next paste reports.
        final class Paste {
            var commandTime: TimeInterval?
            var result = CursorPaster.PasteResult.commandPosted
            /// What the private pasteboard held at each ⌘V, while the rewrites run (nil: not noted).
            var keys: [String]?
        }

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
                let paste = Paste()
                let closeClipboard = CursorPaster.Outlets.installCheck(
                    result: { paste.result },
                    commandSent: {
                        paste.commandTime = $0
                        paste.keys?.append(CursorPaster.outlets.clipboard.pasteboard.string(forType: .string) ?? "<no text>")
                    })

                // When each dictation's History entry was saved, from its ⌘V: the save comes after the paste.
                final class Saves { var afterPaste: [UUID: TimeInterval] = [:] }
                let saves = Saves()
                let observer = NotificationCenter.default.addObserver(
                    forName: .transcriptionCompleted, object: nil, queue: .main
                ) { note in
                    guard let transcription = note.object as? Transcription,
                        let command = paste.commandTime
                    else { return }
                    saves.afterPaste[transcription.id] = ProcessInfo.processInfo.systemUptime - command
                }
                @MainActor func dictate(_ file: URL, measured: Bool = true) async -> Transcription {
                    paste.commandTime = nil
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
                paste.result = .commandNotPosted
                let failed = await dictate(files[0])
                paste.result = .commandPosted
                let failedID = failed.id
                let stored = try? ModelContext(engine.modelContext.container).fetch(
                    FetchDescriptor<Transcription>(predicate: #Predicate { $0.id == failedID })
                ).first
                report(failed, clip: "paste-failed", round: 1, scenario: [
                    "inHistory": stored?.transcriptionStatus == TranscriptionStatus.completed.rawValue
                        && stored?.text.isEmpty == false
                ])

                paste.keys = []
                await rewrites(engine: engine, instruction: files[0], other: files[files.count > 1 ? 1 : 0], paste: paste)
                NotificationCenter.default.removeObserver(observer)
                await engine.releaseModels()  // ggml asserts at exit() while any Metal buffer is still allocated
                await closeClipboard()
                fflush(stdout)
                exit(0)  // not NSApp.terminate, which can't finish from inside a Task (AppDelegate.applicationShouldTerminate)
            }
            return true
        }

        /// Rewrite Last Dictation through VoiceInkEngine, as its shortcut runs it: `prepareRewrite` (the first press),
        /// then `instruction` transcribed by the model and handed to the engine's follow-up, which asks the AI and pastes
        /// over the paste the press selected. Explicit outlets, none taken from `live`: the AI answers from the scenario
        /// (no request leaves the Mac, no input field is read), the last paste is a made-up field 1 of a made-up app in
        /// front, nothing is read through Accessibility, and the Scratchpad, notices and Delete are noted instead of
        /// acted on. ⌘V stays the dictation checks' (the private pasteboard, `paste.keys`). Things that happen during
        /// the AI's wait run inside it, before it answers: another dictation through the engine, a paste left waiting
        /// for ⌘V, a second rewrite, the dictation cancelled. One `dictation-rewrite:` line per scenario.
        private static func rewrites(engine: VoiceInkEngine, instruction: URL, other: URL, paste: Paste) async {
            final class Seen {
                var asked: [String] = [], instructions: [String] = [], stateAtAI: [String] = [], selected: [String] = []
                var scratchpad: [String] = [], notices: [String] = [], boardAtReply: String?
                /// Per question to the AI, in order: its answer, and what happens before it answers.
                var replies: [(Result<String, LastPasteEditor.Failure>, (@MainActor () async -> Void)?)] = []
            }
            let seen = Seen()
            let app: pid_t = 900_001  // above the system's limit: never a running app
            let field = AXUIElementCreateApplication(910_001)  // a stand-in, only compared (CFEqual)
            func record(_ text: String, replaced: String = "") -> LastPasteEditor.Record {
                LastPasteEditor.Record(
                    processID: app, appElement: AXUIElementCreateApplication(910_000), target: field,
                    range: NSRange(location: 0, length: (text as NSString).length), text: text, replaced: replaced)
            }
            func part(_ tag: String, of input: String) -> String {
                guard let start = input.range(of: "<\(tag)>\n"), let end = input.range(of: "\n</\(tag)>") else { return input }
                return String(input[start.upperBound..<end.lowerBound])
            }
            let outlets = LastPasteEditor.Outlets(
                capture: { text, _, replaced in record(text, replaced: replaced) },
                select: { record in
                    seen.selected.append(record.text)
                    return .success(record)
                },
                rewrite: { input, _, _ in
                    seen.asked.append(part("TEXT", of: input))
                    seen.instructions.append(part("INSTRUCTION", of: input))
                    seen.stateAtAI.append("\(engine.recordingState)")
                    guard !seen.replies.isEmpty else { return .failure(.rewriteFailed("no reply set")) }
                    let (reply, during) = seen.replies.removeFirst()
                    await during?()
                    try? await Task.sleep(for: .milliseconds(300))  // the provider's answer on its way
                    seen.boardAtReply = CursorPaster.outlets.clipboard.pasteboard.string(forType: .string)
                    return reply
                },
                notify: { seen.notices.append("edit:\($0)") })
            CursorPaster.outlets.frontmostApp = { ("com.example.yap-check", app) }
            CursorPaster.outlets.focusedElement = { _ in .element(field) }
            CursorPaster.outlets.postDeleteKey = {
                paste.keys?.append("⌫")
                return true
            }
            CursorPaster.outlets.pasteSent = {
                LastPasteEditor.shared.pasteDidFinish(text: $0.text, processID: $0.processID, replacing: $0.replaced)
                return nil
            }
            CursorPaster.outlets.toScratchpad = { seen.scratchpad.append($0) }
            CursorPaster.outlets.notify = { seen.notices.append(PasteSessionCheck.label($0)) }
            let editor = LastPasteEditor.shared

            /// Runs `body` from a fresh state (with `lastPaste`, unless nil: the one the scenario before left), then
            /// prints what happened against `expected`.
            func scenario(
                _ name: String, lastPaste: String? = "dictation A",
                replies: [(Result<String, LastPasteEditor.Failure>, (@MainActor () async -> Void)?)] = [],
                expected: [String: [String]], _ body: () async -> Void
            ) async {
                if let lastPaste { editor.installCheck(outlets, record: record(lastPaste)) }
                (seen.asked, seen.instructions, seen.stateAtAI, seen.selected) = ([], [], [], [])
                (seen.scratchpad, seen.notices, seen.boardAtReply, seen.replies) = ([], [], nil, replies)
                paste.keys = []
                await body()
                try? await Task.sleep(for: .milliseconds(100))  // the last paste read back
                let observed: [String: [String]] = [
                    "keys": paste.keys ?? [], "aiAsked": seen.asked, "selected": seen.selected,
                    "scratchpad": seen.scratchpad, "notices": seen.notices, "stateAtAI": seen.stateAtAI,
                    "boardAtReply": seen.boardAtReply.map { [$0] } ?? [],
                ]
                let failures = expected.compactMap { key, value in
                    observed[key] == value ? nil : "\(key) \(observed[key] ?? []), expected \(value)"
                }.sorted()
                var line: [String: Any] = observed
                line["scenario"] = name
                line["pass"] = failures.isEmpty
                line["failures"] = failures
                line["instructions"] = seen.instructions
                if let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) {
                    print("dictation-rewrite: \(String(decoding: data, as: UTF8.self))")
                }
            }
            func dictate(_ rewrite: LastPasteEditor.Rewrite?) async {
                guard let rewrite else { return }
                _ = await engine.dictateFile(instruction, rewriting: rewrite)
            }

            await scenario(
                "rewrite: the AI's text pasted over the paste the press selected",
                replies: [(.success("rewritten A"), nil)],
                expected: [
                    "keys": ["rewritten A"], "aiAsked": ["dictation A"], "selected": ["dictation A", "dictation A"],
                    "scratchpad": [], "notices": [], "stateAtAI": ["enhancing"],
                ]
            ) { await dictate(await editor.prepareRewrite()) }
            await scenario(
                "rewrite the rewrite, then Undo: each acts on the paste before it", lastPaste: nil,
                replies: [(.success("rewritten twice"), nil)],
                expected: [
                    "keys": ["rewritten twice", "⌫"], "aiAsked": ["rewritten A"],
                    "selected": ["rewritten A", "rewritten A", "rewritten twice"], "scratchpad": [], "notices": [],
                ]
            ) {
                await dictate(await editor.prepareRewrite())
                try? await Task.sleep(for: .milliseconds(100))
                await editor.undoLastPaste()
            }
            await scenario(
                "another dictation pasted while the AI works: it stays, the reply goes to the Scratchpad",
                replies: [(.success("rewritten A"), { _ = await engine.dictateFile(other) })],
                expected: [
                    "aiAsked": ["dictation A"], "selected": ["dictation A"], "scratchpad": ["rewritten A"],
                    "notices": ["superseded→scratchpad"],
                ]
            ) { await dictate(await editor.prepareRewrite()) }
            final class Pending { var task: Task<CursorPaster.PasteOutcome, Never>? }
            let pending = Pending()
            await scenario(
                "a paste waiting for ⌘V when the AI answers: its clipboard and ⌘V kept, the reply to the Scratchpad",
                replies: [(.success("rewritten A"), { pending.task = CursorPaster.startPasteAtCursor("dictation B", lead: .other) })],
                expected: [
                    "keys": ["dictation B"], "aiAsked": ["dictation A"], "selected": ["dictation A"],
                    "scratchpad": ["rewritten A"], "notices": ["superseded→scratchpad"], "boardAtReply": ["dictation B"],
                ]
            ) {
                await dictate(await editor.prepareRewrite())
                _ = await pending.task?.value
            }
            await scenario(
                "a paste while the instruction is recorded: the AI isn't asked, nothing said",
                replies: [(.success("rewritten B"), nil)],
                expected: [
                    "keys": ["dictation B"], "aiAsked": [], "selected": ["dictation A"], "scratchpad": [], "notices": [],
                ]
            ) {
                let rewrite = await editor.prepareRewrite()
                _ = await CursorPaster.startPasteAtCursor("dictation B", lead: .shortcut).value
                await dictate(rewrite)
            }
            await scenario(
                "a second rewrite during the first one's AI wait, answered first: it's pasted, the first to the Scratchpad",
                replies: [
                    (.success("rewritten 1"), { await dictate(await editor.prepareRewrite()) }),
                    (.success("rewritten 2"), nil),
                ],
                expected: [
                    "keys": ["rewritten 2"], "aiAsked": ["dictation A", "dictation A"],
                    "selected": ["dictation A", "dictation A", "dictation A"], "scratchpad": ["rewritten 1"],
                    "notices": ["superseded→scratchpad"],
                ]
            ) { await dictate(await editor.prepareRewrite()) }
            await scenario(
                "the dictation cancelled while the AI works: nothing pasted, the reply kept in the Scratchpad, nothing said",
                replies: [(.success("rewritten A"), { await engine.cancelRecording() })],
                expected: [
                    "keys": [], "aiAsked": ["dictation A"], "selected": ["dictation A"], "scratchpad": ["rewritten A"],
                    "notices": [], "stateAtAI": ["enhancing"],
                ]
            ) { await dictate(await editor.prepareRewrite()) }
            await scenario(
                "the AI fails: said why, nothing pasted or made up",
                replies: [(.failure(.rewriteFailed("check: provider error")), nil)],
                expected: [
                    "keys": [], "scratchpad": [], "notices": ["edit:rewriteFailed(\"check: provider error\")"],
                ]
            ) { await dictate(await editor.prepareRewrite()) }
            await scenario(
                "the AI returns no text: said so, nothing pasted",
                replies: [(.success(" \n"), nil)],
                expected: [
                    "keys": [], "scratchpad": [],
                    "notices": ["edit:\(LastPasteEditor.Failure.rewriteFailed(String(localized: "The AI returned no text.")))"],
                ]
            ) { await dictate(await editor.prepareRewrite()) }
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
