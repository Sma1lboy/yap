#if DEBUG
    import AppKit

    /// `scripts/paste-session-check.sh`: `--paste-session-check`, then quits. Each scenario runs CursorPaster's own
    /// paste (prepare, wait, target and ownership checks, ⌘V, restore), History's and Paste Last's wait for their app,
    /// Finish and Send's Enter and Undo's Delete on a private pasteboard of its own (NSPasteboard(name:)), with outlets
    /// that record instead of acting: ⌘V notes what the pasteboard held when it would have gone out, Enter and Delete
    /// are noted too, the app in front is a made-up process ID and its focused element a stand-in the scenario sets
    /// (whether it takes text as well), activating an app is only noted, Auto Learn / Last Paste, the Scratchpad and
    /// notifications are lists, and time only moves when the scenario advances it. The general pasteboard is never
    /// touched, no key is sent, no app is activated and nothing is read from the app in front. Prints one
    /// `paste-check: {json}` line per scenario with what happened (keys, outcomes, the board, Scratchpad, notices,
    /// activations, Auto Learn), what should have, and `pass`; then `paste-check-done:`.
    @MainActor
    enum PasteSessionCheck {
        static let argument = "--paste-session-check"

        static func runIfRequested() {
            guard CommandLine.arguments.contains(argument) else { return }
            let results = scenarios.map { $0() } + [dictationCheckOutlets()]
            let failed = results.filter { !$0 }.count
            // Asserts: a failure ends the app before the next line.
            ClipboardManager.selfCheck()
            PasteClipboard.selfCheck()
            print("paste-check-selfchecks: ClipboardManager PasteClipboard ok")
            print("paste-check-done: \(results.count) scenarios, \(failed) failed")
            fflush(stdout)
            exit(0)
        }

        /// The outlets the dictation checks install (`installCheck`: offline, latency, isolation, lifecycle, quit,
        /// residency, first run), as they are, on the real clock: ⌘V goes out (not sent) and is timed, then the check
        /// closes before the restore (2 s with the default setting) is due; the restore must not write afterwards.
        static func dictationCheckOutlets() -> Bool {
            final class Seen {
                var commandTimes: [TimeInterval] = []
                var outcome: String?
                var closed = false
            }
            let seen = Seen()
            let close = CursorPaster.Outlets.installCheck(commandSent: { seen.commandTimes.append($0) })
            let clipboard = CursorPaster.outlets.clipboard
            let pasteboard = clipboard.pasteboard
            func run(for seconds: TimeInterval, until done: () -> Bool = { false }) {
                let end = Date().addingTimeInterval(seconds)
                while Date() < end, !done() { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            }
            var failures: [String] = []
            write(original, to: pasteboard)
            let task = CursorPaster.startPasteAtCursor("dictation A", lead: .shortcut)
            Task { @MainActor in seen.outcome = "\(await task.value.result)" }
            run(for: 1) { seen.outcome != nil }
            if seen.outcome != "commandPosted" || seen.commandTimes.count != 1 {
                failures.append("outcome \(seen.outcome ?? "none"), ⌘V times \(seen.commandTimes.count)")
            }
            if pasteboard.string(forType: .string) != "dictation A" { failures.append("text not on the private pasteboard") }
            let first = seen.outcome ?? "none"
            seen.outcome = nil
            // Close the clipboard, wait past the restore and try a late paste, all before the release: a released
            // pasteboard isn't read again (reading it would bring it back).
            let closedAt = pasteboard.changeCount
            Task { @MainActor in
                await clipboard.close()
                seen.closed = true
            }
            run(for: 1) { seen.closed }
            run(for: 2.5)  // past the 2 s restore
            if !seen.closed { failures.append("close didn't finish") }
            let late = CursorPaster.startPasteAtCursor("late", lead: .shortcut)
            Task { @MainActor in seen.outcome = "\(await late.value.result)" }
            run(for: 0.3)
            if pasteboard.changeCount != closedAt { failures.append("pasteboard written after close") }
            if seen.outcome != "commandNotPosted" { failures.append("a paste after close: \(seen.outcome ?? "none")") }
            seen.closed = false
            Task { @MainActor in
                await close()  // what the checks call: close (already done), then release
                seen.closed = true
            }
            run(for: 1) { seen.closed }
            let line: [String: Any] = [
                "scenario": "dictation checks' outlets, real clock, closed before the restore", "pass": failures.isEmpty,
                "failures": failures, "outcomes": ["A": first, "late": seen.outcome ?? "none"],
                "keysTimed": seen.commandTimes.count,
            ]
            if let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) {
                print("paste-check: \(String(decoding: data, as: UTF8.self))")
            }
            return failures.isEmpty
        }

        // MARK: - Clock

        /// Scenario time: a sleep returns once `advance` reaches its deadline; cancelling the sleeping task ends it.
        final class Clock: @unchecked Sendable {
            private struct Waiter {
                let deadline: TimeInterval
                let order: Int
                let continuation: CheckedContinuation<Void, Never>
            }
            private let lock = NSLock()
            private var time: TimeInterval = 0
            private var order = 0
            private var waiters: [UUID: Waiter] = [:]

            var now: TimeInterval { lock.withLock { time } }

            func sleep(_ seconds: TimeInterval) async {
                let id = UUID()
                await withTaskCancellationHandler {
                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        let cancelled: Bool = lock.withLock {
                            guard !Task.isCancelled else { return true }
                            order += 1
                            waiters[id] = Waiter(deadline: time + seconds, order: order, continuation: continuation)
                            return false
                        }
                        if cancelled { continuation.resume() }
                    }
                } onCancel: {
                    lock.withLock { waiters.removeValue(forKey: id) }?.continuation.resume()
                }
            }

            /// Resumes the earliest sleep due by `limit`, with the time set to its deadline. False when none is due.
            func resumeNext(by limit: TimeInterval) -> Bool {
                let next: Waiter? = lock.withLock {
                    guard let (id, waiter) = waiters.min(by: { ($0.value.deadline, $0.value.order) < ($1.value.deadline, $1.value.order) }),
                        waiter.deadline <= limit
                    else { return nil }
                    waiters[id] = nil
                    time = max(time, waiter.deadline)
                    return waiter
                }
                next?.continuation.resume()
                return next != nil
            }

            func set(_ value: TimeInterval) { lock.withLock { time = max(time, value) } }
        }

        // MARK: - Pasteboard contents

        typealias Item = [(NSPasteboard.PasteboardType, Data)]
        static let transientTypes: Set<NSPasteboard.PasteboardType> = [
            .init("org.nspasteboard.TransientType"), .init("org.nspasteboard.AutoGeneratedType"),
        ]

        static let original: [Item] = [
            [
                (.string, Data("original one".utf8)), (.html, Data("<b>original</b> one".utf8)),
                (.init("com.example.yap-check.reference"), Data([1, 2, 3, 250])),
            ],
            [(.string, Data("original two".utf8)), (.png, Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 7]))],
        ]
        static let userCopy: [Item] = [
            [(.string, Data("copied by the user".utf8)), (.init("com.example.yap-check.user"), Data([9]))]
        ]

        /// Made-up process IDs, above the system's limit (99999): never a running app, never looked up.
        static let app: pid_t = 900_001
        static let otherApp: pid_t = 900_002
        /// A stand-in focused element for the scenarios: an application element for a made-up process. Creating one
        /// sends nothing anywhere; scenarios only compare them (CFEqual), and no Accessibility call is made with them.
        static func field(_ number: Int32) -> AXUIElement { AXUIElementCreateApplication(910_000 + number) }

        static func contents(of pasteboard: NSPasteboard) -> [Item] {
            (pasteboard.pasteboardItems ?? []).map { item in
                item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
            }
        }

        static func write(_ items: [Item], to pasteboard: NSPasteboard) {
            pasteboard.clearContents()
            guard !items.isEmpty else { return }
            pasteboard.writeObjects(items.map { pairs in
                let item = NSPasteboardItem()
                for (type, data) in pairs { item.setData(data, forType: type) }
                return item
            })
        }

        /// Same items, same types and bytes; the transient markers a restore adds don't count.
        static func same(_ a: [Item], _ b: [Item]) -> Bool {
            func normal(_ item: Item) -> [String: Data] {
                Dictionary(item.filter { !transientTypes.contains($0.0) }.map { ($0.0.rawValue, $0.1) }) { a, _ in a }
            }
            return a.count == b.count && zip(a, b).allSatisfy { normal($0) == normal($1) }
        }

        static func describe(_ items: [Item]) -> [[String: String]] {
            items.map { pairs in
                Dictionary(pairs.map { type, data in
                    (type.rawValue, String(data: data, encoding: .utf8) ?? data.map { String(format: "%02x", $0) }.joined())
                }) { a, _ in a }
            }
        }

        // MARK: - Run

        enum Final {
            /// What the scenario started with, restored.
            case original
            /// Only this paste's text; `transient`: marked so (and with a paste session), as during a paste.
            case text(String, transient: Bool)
            /// Exactly what the user wrote, captured when they did.
            case user
            case empty
            /// What a failed write leaves when nothing was kept to put back (restore off, or a paste that only copies):
            /// the half-written item `writeFails` makes, not the text and not what was there before.
            case halfWritten
        }

        @MainActor
        final class Run {
            let name: String
            let clock = Clock()
            let clipboard: PasteClipboard
            var pasteboard: NSPasteboard { clipboard.pasteboard }
            var start: [Item] = PasteSessionCheck.original
            var userWrote: [Item]?
            var restore = (enabled: true, delay: 0.0)
            var keyResult = CursorPaster.PasteResult.commandPosted
            var frontmost = "com.apple.TextEdit"
            /// The app in front: a made-up process ID (above the system's limit), never looked up.
            var processID: pid_t? = PasteSessionCheck.app
            /// Its focused element, as the focus read reports it.
            var focus = CursorPaster.Focus.element(PasteSessionCheck.field(1))
            /// Pairs of fields where the first contains the second.
            var containers: [(Int32, Int32)] = []
            var canPostKeys = true
            var focusTakesText = true
            /// Apps still running; the target of a History paste is looked up here. Activation is only noted.
            var running: Set<pid_t> = [PasteSessionCheck.app, PasteSessionCheck.otherApp]
            var activations: [pid_t] = []
            /// Auto Learn's work before Finish and Send's key (cancelling its observation), in scenario seconds.
            var autoSendDelay: TimeInterval = 0
            /// How often Auto Learn was told Finish and Send's key is going out (it then stops watching the paste).
            var autoSent = 0
            /// ⌘V lists what the pasteboard held; Enter is "⏎ <key>", Delete "⌫".
            var keys: [String] = []
            var sent: [String] = []
            var scratchpad: [String] = []
            var outcomes: [String: String] = [:]
            var tasks: [String: Task<CursorPaster.PasteOutcome, Never>] = [:]
            var notes: [String] = []
            var failures: [String] = []
            private var closed = false

            init(_ name: String) {
                self.name = name
                clipboard = PasteClipboard(NSPasteboard(name: NSPasteboard.Name("me.sma1lboy.yap.paste-check.\(UUID().uuidString)")))
                var outlets = CursorPaster.Outlets.check(clipboard)
                let clock = self.clock
                outlets.canPostKeys = { [unowned self] in self.canPostKeys }
                outlets.frontmostApp = { [unowned self] in (self.frontmost, self.processID) }
                outlets.focusedElement = { [unowned self] _ in self.focus }
                outlets.encloses = { [unowned self] a, b in
                    guard case .element(let a) = a, case .element(let b) = b else { return false }
                    return self.containers.contains { outer, inner in
                        let (o, i) = (PasteSessionCheck.field(outer), PasteSessionCheck.field(inner))
                        return (CFEqual(o, a) && CFEqual(i, b)) || (CFEqual(o, b) && CFEqual(i, a))
                    }
                }
                outlets.focusCanTakeText = { [unowned self] in self.focusTakesText }
                outlets.postPasteKeys = { [unowned self] in
                    guard self.keyResult == .commandPosted else { return (self.keyResult, nil) }
                    self.keys.append(self.pasteboard.string(forType: .string) ?? "<no text>")
                    return (.commandPosted, clock.now)
                }
                outlets.postSubmitKey = { [unowned self] in
                    self.keys.append("⏎ \($0.rawValue)")
                    return true
                }
                outlets.postDeleteKey = { [unowned self] in
                    self.keys.append("⌫")
                    return true
                }
                outlets.autoSendWillPost = { [unowned self] _ in
                    self.autoSent += 1
                    await clock.sleep(self.autoSendDelay)
                }
                outlets.pasteSent = { [unowned self] in
                    self.sent.append($0.text)
                    return UInt64(self.sent.count)
                }
                outlets.toScratchpad = { [unowned self] in self.scratchpad.append($0) }
                outlets.notify = { [unowned self] in self.notes.append(PasteSessionCheck.label($0)) }
                outlets.activate = { [unowned self] in self.activations.append($0) }
                outlets.isRunning = { [unowned self] in self.running.contains($0) }
                outlets.restoreSettings = { [unowned self] in self.restore }
                outlets.now = { clock.now }
                outlets.sleep = { await clock.sleep($0) }
                CursorPaster.outlets = outlets
            }

            func begin() { PasteSessionCheck.write(start, to: pasteboard) }

            /// Lets the main queue, where the paste's tasks run, do everything it can now.
            func settle() {
                for _ in 0..<4 { RunLoop.main.run(until: Date().addingTimeInterval(0.002)) }
            }

            func advance(to time: TimeInterval) {
                settle()
                while clock.resumeNext(by: time) { settle() }
                clock.set(time)
                settle()
            }

            /// `target`: the process the caller chose, with field 1 as the field it is for (as Undo and Rewrite pass
            /// the field they selected in); `submit`: Finish and Send's Enter after a ⌘V that went out, as dictation
            /// sends it, its result under "<label>⏎".
            func paste(
                _ label: String, _ text: String, at time: TimeInterval, lead: CursorPaster.Lead = .shortcut,
                target: pid_t? = nil, submit: Bool = false
            ) {
                advance(to: time)
                let task = CursorPaster.startPasteAtCursor(
                    text, lead: lead,
                    target: target.map { CursorPaster.Target(processID: $0, focus: .element(PasteSessionCheck.field(1))) })
                tasks[label] = task
                Task { @MainActor [unowned self] in
                    let outcome = await task.value
                    self.outcomes[label] = "\(outcome.result)"
                    guard submit, outcome.result.didPostPasteCommand else { return }
                    self.outcomes[label + "⏎"] = "\(await CursorPaster.submit(.enter, after: outcome))"
                }
                settle()
            }

            /// History's Paste Again / Quick History (`activate`) or Paste Last (`hold`) into `target`.
            func pasteInto(
                _ label: String, _ text: String, at time: TimeInterval, target: pid_t?, activate: Bool = true,
                hold: TimeInterval = 0
            ) {
                advance(to: time)
                let task = CursorPaster.paste(text, into: target, activate: activate, hold: hold)
                tasks[label] = task
                Task { @MainActor [unowned self] in self.outcomes[label] = "\(await task.value.result)" }
                settle()
            }

            /// Undo Last Paste's Delete into field 1 of `processID`, for `request` (by default a new one, taken now as
            /// Undo takes it when it starts).
            func delete(_ label: String, in processID: pid_t, at time: TimeInterval, request: CursorPaster.Request? = nil) {
                advance(to: time)
                let request = request ?? CursorPaster.newRequest()
                Task { @MainActor [unowned self] in
                    self.outcomes[label] =
                        "\(await CursorPaster.deleteSelection(in: processID, field: PasteSessionCheck.field(1), request: request))"
                }
                settle()
            }

            /// How long LastPasteEditor's check and selection of the last paste takes (Accessibility, in scenario
            /// seconds), and what changes the moment it has selected (the focus moving to another field, say).
            var selectDelay: TimeInterval = 0
            var afterSelect: (() -> Void)?
            var editTasks: [String: Task<Void, Never>] = [:]

            /// A LastPasteEditor of its own whose last paste is "rewritten" in field 1 of `app`, having replaced
            /// `replaced`. Its selection is `selectDelay` long and always succeeds; nothing is read through Accessibility
            /// and its refusals are notices ("edit:<why>").
            func editor(replaced: String) -> LastPasteEditor {
                let clock = self.clock
                let record = LastPasteEditor.Record(
                    processID: PasteSessionCheck.app, appElement: PasteSessionCheck.field(0),
                    target: PasteSessionCheck.field(1), range: NSRange(location: 0, length: 9), text: "rewritten",
                    replaced: replaced)
                return LastPasteEditor.check(
                    LastPasteEditor.Outlets(
                        select: { [unowned self] record in
                            if self.selectDelay > 0 { await clock.sleep(self.selectDelay) }
                            self.afterSelect?()
                            return .success(record)
                        },
                        notify: { [unowned self] in self.notes.append("edit:\($0)") }),
                    record: record)
            }

            /// Undo Last Paste through LastPasteEditor: the text the last paste replaced is pasted back (or, with
            /// nothing replaced, Delete).
            func undo(_ label: String, at time: TimeInterval, replaced: String = "original words") {
                advance(to: time)
                let editor = editor(replaced: replaced)
                editTasks[label] = Task { @MainActor [unowned self] in
                    self.outcomes[label] = PasteSessionCheck.label(await editor.undoLastPaste())
                }
                settle()
            }

            /// Rewrite Last Paste once the AI's text came back (no AI call): selected again, `text` pasted over it.
            func rewrite(_ label: String, _ text: String, at time: TimeInterval) {
                advance(to: time)
                let editor = editor(replaced: "")
                editTasks[label] = Task { @MainActor [unowned self] in
                    self.outcomes[label] = PasteSessionCheck.label(await editor.pasteRewrite(text))
                }
                settle()
            }

            func cancel(_ label: String, at time: TimeInterval) {
                advance(to: time)
                tasks[label]?.cancel()
                editTasks[label]?.cancel()
                settle()
            }

            /// The user copies something (a new write: clear, then write).
            func userCopies(_ items: [Item], at time: TimeInterval) {
                advance(to: time)
                PasteSessionCheck.write(items, to: pasteboard)
                userWrote = PasteSessionCheck.contents(of: pasteboard)
            }

            /// The user copies the pasteboard's text again with its paste-session data: same text and session, a new
            /// revision (a clipboard-history app putting Yap's entry back does this).
            func userRewrites(at time: TimeInterval) {
                advance(to: time)
                var item = PasteSessionCheck.contents(of: pasteboard).first ?? []
                item.append((.init("com.example.yap-check.rewritten"), Data([1])))
                PasteSessionCheck.write([item], to: pasteboard)
                userWrote = PasteSessionCheck.contents(of: pasteboard)
            }

            func expectBoard(_ final: Final, _ label: String) {
                let now = PasteSessionCheck.contents(of: pasteboard)
                let ok: Bool
                switch final {
                case .original: ok = PasteSessionCheck.same(now, start)
                case .user: ok = userWrote.map { PasteSessionCheck.same(now, $0) && now.count == $0.count } ?? false
                case .empty: ok = now.isEmpty
                case .halfWritten:
                    ok = now.count == 1 && pasteboard.string(forType: .string) == nil
                        && now[0].map(\.0.rawValue) == ["me.sma1lboy.yap.half-written"]
                case .text(let text, let transient):
                    let types = Set(now.first?.map(\.0) ?? [])
                    ok = now.count == 1 && pasteboard.string(forType: .string) == text
                        && types.isSuperset(of: PasteSessionCheck.transientTypes) == transient
                        && types.contains(ClipboardManager.pasteSessionType) == transient
                }
                if !ok { failures.append("\(label): board \(PasteSessionCheck.describe(now)), expected \(final)") }
            }

            /// Closes the clipboard (cancelling its pending restores), lets every remaining sleep run out, checks nothing
            /// was written after the close, then releases the private pasteboard.
            /// `autoSent`: how often Auto Learn should have heard Enter was going out; by default once per Enter sent.
            /// `activations`: the apps asked to come to the front; by default none.
            func finish(
                board final: Final, outcomes expectedOutcomes: [String: String], keys expectedKeys: [String],
                scratchpad expectedScratchpad: [String] = [], notices expectedNotices: [String]? = nil,
                autoSent expectedAutoSent: Int? = nil, activations expectedActivations: [pid_t] = []
            ) -> Bool {
                advance(to: clock.now)
                expectBoard(final, "end")
                if outcomes != expectedOutcomes { failures.append("outcomes \(outcomes), expected \(expectedOutcomes)") }
                if keys != expectedKeys { failures.append("keys \(keys), expected \(expectedKeys)") }
                let expectedSent = expectedOutcomes.filter { !$0.key.hasSuffix("⏎") && $0.value == "commandPosted" }.count
                if sent.count != expectedSent { failures.append("Auto Learn / Last Paste heard of \(sent), expected \(expectedSent)") }
                if scratchpad != expectedScratchpad { failures.append("Scratchpad got \(scratchpad), expected \(expectedScratchpad)") }
                if let expectedNotices, notes != expectedNotices { failures.append("notices \(notes), expected \(expectedNotices)") }
                let entersSent = outcomes.filter { $0.key.hasSuffix("⏎") && $0.value == "sent" }.count
                if autoSent != (expectedAutoSent ?? entersSent) {
                    failures.append("Auto Learn told of \(autoSent) Enter(s), \(entersSent) sent")
                }
                if activations != expectedActivations {
                    failures.append("activated \(activations), expected \(expectedActivations)")
                }
                let closedAt = pasteboard.changeCount
                Task { @MainActor [unowned self] in
                    await self.clipboard.close()
                    self.closed = true
                }
                var spins = 0
                while !closed, spins < 100 {
                    advance(to: clock.now + 1000)
                    spins += 1
                }
                if !closed { failures.append("close didn't finish") }
                if pasteboard.changeCount != closedAt { failures.append("pasteboard written after close") }
                let finalBoard = PasteSessionCheck.describe(PasteSessionCheck.contents(of: pasteboard))
                pasteboard.releaseGlobally()

                let line: [String: Any] = [
                    "scenario": name, "pass": failures.isEmpty, "failures": failures, "outcomes": outcomes,
                    "keys": keys, "sentToAutoLearn": sent, "autoSent": autoSent, "scratchpad": scratchpad,
                    "notices": notes, "activations": activations, "finalBoard": finalBoard, "expectedBoard": "\(final)",
                ]
                if let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) {
                    print("paste-check: \(String(decoding: data, as: UTF8.self))")
                }
                return failures.isEmpty
            }
        }

        /// A notification as the scenarios expect it: "<reason>→<where the text is>", "sendSkipped:<why>",
        /// "deleteSkipped:<why>".
        static func label(_ notice: CursorPaster.Notice) -> String {
            switch notice {
            case .notPasted(let reason, let destination): return "\(reason)→\(destination)"
            case .sendSkipped(let result): return "sendSkipped:\(result)"
            case .deleteSkipped(let result): return "deleteSkipped:\(result)"
            }
        }

        static func label(_ edit: LastPasteEditor.Edit) -> String {
            switch edit {
            case .refused(let failure): return "refused:\(failure)"
            case .deleted(let result): return "\(result)"
            case .pasted(let result): return "\(result)"
            }
        }

        // MARK: - Scenarios

        /// Shortcut stop, local app: ⌘V 0.02 s after the write, restore 0.25 s after ⌘V.
        static let scenarios: [@MainActor () -> Bool] = [
            {
                let run = Run("one paste")
                run.begin()
                run.paste("A", "dictation A", at: 0)
                run.advance(to: 1)
                return run.finish(board: .original, outcomes: ["A": "commandPosted"], keys: ["dictation A"])
            },
            {
                let run = Run("second paste before the first restore")
                run.begin()
                run.paste("A", "dictation A", at: 0)
                run.paste("B", "dictation B", at: 0.1)
                run.advance(to: 2)
                return run.finish(
                    board: .original, outcomes: ["A": "commandPosted", "B": "commandPosted"],
                    keys: ["dictation A", "dictation B"])
            },
            {
                let run = Run("three pastes, each before the last restore")
                run.begin()
                run.paste("A", "dictation A", at: 0)
                run.paste("B", "dictation B", at: 0.1)
                run.paste("C", "dictation C", at: 0.2)
                run.advance(to: 2)
                return run.finish(
                    board: .original, outcomes: ["A": "commandPosted", "B": "commandPosted", "C": "commandPosted"],
                    keys: ["dictation A", "dictation B", "dictation C"])
            },
            {
                let run = Run("second paste after the first restore")
                run.begin()
                run.paste("A", "dictation A", at: 0)
                run.advance(to: 0.5)
                run.expectBoard(.original, "after A's restore")
                run.paste("B", "dictation B", at: 0.5)
                run.advance(to: 2)
                return run.finish(
                    board: .original, outcomes: ["A": "commandPosted", "B": "commandPosted"],
                    keys: ["dictation A", "dictation B"])
            },
            {
                let run = Run("second paste before the first one's ⌘V")
                run.begin()
                run.paste("A", "dictation A", at: 0)
                run.paste("B", "dictation B", at: 0.005)
                run.advance(to: 2)
                return run.finish(
                    board: .original, outcomes: ["A": "superseded", "B": "commandPosted"], keys: ["dictation B"],
                    scratchpad: ["dictation A"], notices: ["superseded→scratchpad"])
            },
            {
                let run = Run("user copies before ⌘V")
                run.begin()
                run.paste("A", "dictation A", at: 0)
                run.userCopies(userCopy, at: 0.01)
                run.advance(to: 2)
                return run.finish(
                    board: .user, outcomes: ["A": "clipboardChanged"], keys: [], scratchpad: ["dictation A"],
                    notices: ["clipboardChanged→scratchpad"])
            },
            {
                let run = Run("user copies after ⌘V, before the restore")
                run.begin()
                run.paste("A", "dictation A", at: 0)
                run.userCopies(userCopy, at: 0.1)
                run.advance(to: 2)
                return run.finish(board: .user, outcomes: ["A": "commandPosted"], keys: ["dictation A"])
            },
            {
                let run = Run("user rewrites the same text and session after ⌘V")
                run.begin()
                run.paste("A", "dictation A", at: 0)
                run.userRewrites(at: 0.1)
                run.advance(to: 2)
                return run.finish(board: .user, outcomes: ["A": "commandPosted"], keys: ["dictation A"])
            },
            {
                let run = Run("user rewrites the same text and session before ⌘V")
                run.begin()
                run.paste("A", "dictation A", at: 0)
                run.userRewrites(at: 0.01)
                run.advance(to: 2)
                return run.finish(
                    board: .user, outcomes: ["A": "clipboardChanged"], keys: [], scratchpad: ["dictation A"],
                    notices: ["clipboardChanged→scratchpad"])
            },
            {
                let run = Run("user copies, then a new paste")
                run.begin()
                run.paste("A", "dictation A", at: 0)
                run.userCopies(userCopy, at: 0.1)
                run.paste("B", "dictation B", at: 0.15)
                run.advance(to: 2)
                return run.finish(
                    board: .user, outcomes: ["A": "commandPosted", "B": "commandPosted"],
                    keys: ["dictation A", "dictation B"])
            },
            {
                let run = Run("user copies, a new paste starts, then the old ⌘V is due")
                run.begin()
                run.paste("A", "dictation A", at: 0)
                run.userCopies(userCopy, at: 0.01)
                run.paste("B", "dictation B", at: 0.012)
                run.advance(to: 2)
                return run.finish(
                    board: .user, outcomes: ["A": "superseded", "B": "commandPosted"], keys: ["dictation B"],
                    scratchpad: ["dictation A"], notices: ["superseded→scratchpad"])
            },
            {
                let run = Run("clipboard empty before the paste")
                run.start = []
                run.begin()
                run.paste("A", "dictation A", at: 0)
                run.advance(to: 1)
                return run.finish(board: .empty, outcomes: ["A": "commandPosted"], keys: ["dictation A"])
            },
            {
                let run = Run("restore off")
                run.restore.enabled = false
                run.begin()
                run.paste("A", "dictation A", at: 0)
                run.paste("B", "dictation B", at: 0.1)
                run.advance(to: 2)
                return run.finish(
                    board: .text("dictation B", transient: false), outcomes: ["A": "commandPosted", "B": "commandPosted"],
                    keys: ["dictation A", "dictation B"])
            },
            {
                let run = Run("restore turned off between two pastes")
                run.begin()
                run.paste("A", "dictation A", at: 0)
                run.advance(to: 0.1)
                run.restore.enabled = false
                run.paste("B", "dictation B", at: 0.1)
                run.advance(to: 2)
                return run.finish(
                    board: .text("dictation B", transient: false), outcomes: ["A": "commandPosted", "B": "commandPosted"],
                    keys: ["dictation A", "dictation B"])
            },
            {
                let run = Run("clipboard write fails")
                run.begin()
                run.clipboard.writeFails = true
                run.paste("A", "dictation A", at: 0)
                run.advance(to: 2)
                return run.finish(
                    board: .original, outcomes: ["A": "commandNotPosted"], keys: [], scratchpad: ["dictation A"],
                    notices: ["clipboardWriteFailed→scratchpad"])
            },
            {
                let run = Run("clipboard write fails for the second paste")
                run.begin()
                run.paste("A", "dictation A", at: 0)
                run.advance(to: 0.1)
                run.clipboard.writeFails = true
                run.paste("B", "dictation B", at: 0.1)
                run.advance(to: 2)
                return run.finish(
                    board: .original, outcomes: ["A": "commandPosted", "B": "commandNotPosted"], keys: ["dictation A"],
                    scratchpad: ["dictation B"], notices: ["clipboardWriteFailed→scratchpad"])
            },
            {
                let run = Run("⌘V can't be sent")
                run.keyResult = .commandNotPosted
                run.begin()
                run.paste("A", "dictation A", at: 0)
                run.advance(to: 2)
                return run.finish(
                    board: .text("dictation A", transient: true), outcomes: ["A": "commandNotPosted"], keys: [],
                    notices: ["pasteKeysFailed→clipboard"])
            },
            {
                let run = Run("⌘V can't be sent for the second paste")
                run.begin()
                run.paste("A", "dictation A", at: 0)
                run.advance(to: 0.1)
                run.keyResult = .commandNotPosted
                run.paste("B", "dictation B", at: 0.1)
                run.advance(to: 2)
                return run.finish(
                    board: .text("dictation B", transient: true), outcomes: ["A": "commandPosted", "B": "commandNotPosted"],
                    keys: ["dictation A"], notices: ["pasteKeysFailed→clipboard"])
            },
            {
                let run = Run("remote desktop in front: 0.5 s before ⌘V, 5 s before the restore")
                run.frontmost = "com.apple.ScreenSharing"
                run.begin()
                run.paste("A", "dictation A", at: 0)
                run.advance(to: 0.45)
                if !run.keys.isEmpty { run.failures.append("⌘V before 0.5 s") }
                run.advance(to: 5.4)
                run.expectBoard(.text("dictation A", transient: true), "4.9 s after ⌘V")
                run.advance(to: 6)
                return run.finish(board: .original, outcomes: ["A": "commandPosted"], keys: ["dictation A"])
            },
            {
                let run = Run("closed with a restore pending")
                run.begin()
                run.paste("A", "dictation A", at: 0)
                run.advance(to: 0.1)
                return run.finish(
                    board: .text("dictation A", transient: true), outcomes: ["A": "commandPosted"], keys: ["dictation A"])
            },
            {
                let run = Run("no text field for the second paste, before the first restore")
                run.begin()
                run.paste("A", "dictation A", at: 0)
                run.advance(to: 0.1)
                run.focusTakesText = false
                run.paste("B", "dictation B", at: 0.1)
                run.advance(to: 2)
                return run.finish(
                    board: .text("dictation B", transient: false), outcomes: ["A": "commandPosted", "B": "sentToScratchpad"],
                    keys: ["dictation A"], scratchpad: ["dictation B"], notices: ["noTextField→clipboardAndScratchpad"])
            },
        ] + targetScenarios + receiptScenarios + editScenarios

        // MARK: - Target scenarios

        /// Where the paste goes: the app in front and its focused field when the paste started, checked again after the
        /// wait, right before ⌘V; Finish and Send's Enter and Undo's Delete checked the same way.
        static let targetScenarios: [@MainActor () -> Bool] = [
            {
                let run = Run("same app and field: ⌘V, then Enter after the restore ran")
                run.autoSendDelay = 0.2  // Enter 0.37 s in, the restore at 0.27 s
                run.begin()
                run.paste("A", "dictation A", at: 0, submit: true)
                run.advance(to: 1)
                return run.finish(
                    board: .original, outcomes: ["A": "commandPosted", "A⏎": "sent"], keys: ["dictation A", "⏎ enter"])
            },
            {
                let run = Run("another app comes to the front before ⌘V")
                run.begin()
                run.paste("A", "dictation A", at: 0, submit: true)
                run.advance(to: 0.01)
                run.processID = otherApp
                run.frontmost = "com.example.other"
                run.advance(to: 2)
                return run.finish(
                    board: .original, outcomes: ["A": "targetChanged"], keys: [], scratchpad: ["dictation A"],
                    notices: ["targetChanged→scratchpad"])
            },
            {
                let run = Run("same app, another field focused before ⌘V")
                run.begin()
                run.paste("A", "dictation A", at: 0)
                run.advance(to: 0.01)
                run.focus = .element(field(2))
                run.advance(to: 2)
                return run.finish(
                    board: .original, outcomes: ["A": "targetChanged"], keys: [], scratchpad: ["dictation A"],
                    notices: ["targetChanged→scratchpad"])
            },
            {
                let run = Run("the field loses focus before ⌘V, nothing focused in the app")
                run.begin()
                run.paste("A", "dictation A", at: 0)
                run.advance(to: 0.01)
                run.focus = .none
                run.advance(to: 2)
                return run.finish(
                    board: .original, outcomes: ["A": "targetChanged"], keys: [], scratchpad: ["dictation A"],
                    notices: ["targetChanged→scratchpad"])
            },
            {
                let run = Run("same field, but it stops taking text before ⌘V")
                run.begin()
                run.paste("A", "dictation A", at: 0)
                run.advance(to: 0.01)
                run.focusTakesText = false
                run.advance(to: 2)
                return run.finish(
                    board: .original, outcomes: ["A": "targetChanged"], keys: [], scratchpad: ["dictation A"],
                    notices: ["targetChanged→scratchpad"])
            },
            {
                let run = Run("focus moves into the focused element (web view): same container, ⌘V sent")
                run.containers = [(1, 3)]
                run.begin()
                run.paste("A", "dictation A", at: 0)
                run.advance(to: 0.01)
                run.focus = .element(field(3))
                run.advance(to: 2)
                return run.finish(board: .original, outcomes: ["A": "commandPosted"], keys: ["dictation A"])
            },
            {
                let run = Run("remote desktop, Accessibility can't read its focus: same app is enough, 0.5 s / 5 s kept")
                run.frontmost = "com.apple.ScreenSharing"
                run.focus = .unreadable
                run.begin()
                run.paste("A", "dictation A", at: 0, submit: true)
                run.advance(to: 0.45)
                if !run.keys.isEmpty { run.failures.append("⌘V before 0.5 s") }
                run.advance(to: 6)
                return run.finish(
                    board: .original, outcomes: ["A": "commandPosted", "A⏎": "sent"], keys: ["dictation A", "⏎ enter"])
            },
            {
                let run = Run("focus readable at the start, unreadable at ⌘V: not a known change, ⌘V sent")
                run.begin()
                run.paste("A", "dictation A", at: 0)
                run.advance(to: 0.01)
                run.focus = .unreadable
                run.advance(to: 2)
                return run.finish(board: .original, outcomes: ["A": "commandPosted"], keys: ["dictation A"])
            },
            {
                let run = Run("Accessibility turned off before ⌘V")
                run.begin()
                run.paste("A", "dictation A", at: 0)
                run.advance(to: 0.01)
                run.canPostKeys = false
                run.advance(to: 2)
                return run.finish(
                    board: .text("dictation A", transient: true), outcomes: ["A": "leftOnClipboard"], keys: [],
                    notices: ["accessibilityMissing→clipboard"])
            },
            {
                let run = Run("paste cancelled before ⌘V")
                run.begin()
                run.paste("A", "dictation A", at: 0)
                run.cancel("A", at: 0.01)
                run.advance(to: 2)
                return run.finish(
                    board: .original, outcomes: ["A": "superseded"], keys: [], scratchpad: ["dictation A"], notices: [])
            },
            {
                // Until M7.3 the app in front after the wait became the target ("focus coming back"); nothing ever
                // showed it was the app the dictation was for.
                let run = Run("Yap in front when the paste starts, another app in front after the wait: not pasted there")
                run.processID = ProcessInfo.processInfo.processIdentifier
                run.frontmost = "me.sma1lboy.yap.mock"
                run.focus = .element(field(9))
                run.begin()
                run.paste("A", "dictation A", at: 0, lead: .other)
                run.advance(to: 0.05)
                run.processID = app
                run.frontmost = "com.apple.TextEdit"
                run.focus = .element(field(1))
                run.advance(to: 2)
                return run.finish(
                    board: .original, outcomes: ["A": "targetChanged"], keys: [], scratchpad: ["dictation A"],
                    notices: ["targetChanged→scratchpad"])
            },
            {
                let run = Run("History / Undo target: the app it chose is in front")
                run.begin()
                run.paste("A", "dictation A", at: 0, lead: .other, target: app)
                run.advance(to: 2)
                return run.finish(board: .original, outcomes: ["A": "commandPosted"], keys: ["dictation A"])
            },
            {
                let run = Run("History / Undo target: another app in front when the paste starts, clipboard untouched")
                run.processID = otherApp
                run.frontmost = "com.example.other"
                run.begin()
                let before = run.pasteboard.changeCount
                run.paste("A", "dictation A", at: 0, lead: .other, target: app)
                run.advance(to: 2)
                if run.pasteboard.changeCount != before { run.failures.append("clipboard written") }
                return run.finish(
                    board: .original, outcomes: ["A": "targetChanged"], keys: [], scratchpad: ["dictation A"],
                    notices: ["targetChanged→scratchpad"])
            },
            {
                let run = Run("Enter: another app comes to the front after ⌘V, before Enter")
                run.begin()
                run.paste("A", "dictation A", at: 0, submit: true)
                run.advance(to: 0.1)
                run.processID = otherApp
                run.advance(to: 2)
                return run.finish(
                    board: .original, outcomes: ["A": "commandPosted", "A⏎": "targetChanged"], keys: ["dictation A"],
                    notices: ["sendSkipped:targetChanged"])
            },
            {
                let run = Run("Enter: another field focused after ⌘V, before Enter")
                run.begin()
                run.paste("A", "dictation A", at: 0, submit: true)
                run.advance(to: 0.1)
                run.focus = .element(field(2))
                run.advance(to: 2)
                return run.finish(
                    board: .original, outcomes: ["A": "commandPosted", "A⏎": "targetChanged"], keys: ["dictation A"],
                    notices: ["sendSkipped:targetChanged"])
            },
            {
                // Auto Learn had already stopped watching A when B started: that is the only thing the late check
                // can't take back, and it's counted (autoSent 1) though no Enter went out.
                let run = Run("Enter: a new paste starts while Auto Learn is being told about A's Enter")
                run.autoSendDelay = 0.2
                run.begin()
                run.paste("A", "dictation A", at: 0, submit: true)
                run.paste("B", "dictation B", at: 0.3)
                run.advance(to: 2)
                return run.finish(
                    board: .original, outcomes: ["A": "commandPosted", "A⏎": "superseded", "B": "commandPosted"],
                    keys: ["dictation A", "dictation B"], notices: ["sendSkipped:superseded"], autoSent: 1)
            },
            {
                let run = Run("Enter: a new paste starts between A's ⌘V and A's Enter")
                run.begin()
                run.paste("A", "dictation A", at: 0, submit: true)
                run.paste("B", "dictation B", at: 0.1)
                run.advance(to: 2)
                return run.finish(
                    board: .original, outcomes: ["A": "commandPosted", "A⏎": "superseded", "B": "commandPosted"],
                    keys: ["dictation A", "dictation B"], notices: ["sendSkipped:superseded"])
            },
            {
                let run = Run("Undo's Delete into the recorded app")
                run.begin()
                run.delete("U", in: app, at: 0)
                return run.finish(board: .original, outcomes: ["U": "sent"], keys: ["⌫"], notices: [])
            },
            {
                let run = Run("Undo's Delete with another app in front")
                run.processID = otherApp
                run.begin()
                run.delete("U", in: app, at: 0)
                return run.finish(
                    board: .original, outcomes: ["U": "targetChanged"], keys: [], notices: ["deleteSkipped:targetChanged"])
            },
            {
                let run = Run("Undo's Delete calls off a dictation's pending Enter")
                run.begin()
                run.paste("A", "dictation A", at: 0, submit: true)
                run.delete("U", in: app, at: 0.1)
                run.advance(to: 2)
                return run.finish(
                    board: .original, outcomes: ["A": "commandPosted", "A⏎": "superseded", "U": "sent"],
                    keys: ["dictation A", "⌫"], notices: ["sendSkipped:superseded"])
            },
        ]

        // MARK: - Receipts and remaining target edges

        /// What a refused paste, Enter or Delete leaves and says: the target checked after the last wait, where the text
        /// ended up (clipboard, Scratchpad, both) and which notice tells the user so; History's and Paste Last's wait for
        /// their app.
        static let receiptScenarios: [@MainActor () -> Bool] = [
            {
                let run = Run("Enter: same app, another field focused while Auto Learn is told the key is going out")
                run.autoSendDelay = 0.2
                run.begin()
                run.paste("A", "dictation A", at: 0, submit: true)
                run.advance(to: 0.25)  // A's Enter is past its first check, waiting for Auto Learn
                run.focus = .element(field(2))
                run.advance(to: 2)
                return run.finish(
                    board: .original, outcomes: ["A": "commandPosted", "A⏎": "targetChanged"], keys: ["dictation A"],
                    notices: ["sendSkipped:targetChanged"], autoSent: 1)
            },
            {
                let run = Run("Enter: the key events can't be made: receipt says the paste went out, the key didn't")
                run.begin()
                run.paste("A", "dictation A", at: 0, submit: true)
                run.advance(to: 0.1)
                run.canPostKeys = false
                run.advance(to: 2)
                return run.finish(
                    board: .original, outcomes: ["A": "commandPosted", "A⏎": "notSent"], keys: ["dictation A"],
                    notices: ["sendSkipped:notSent"])
            },
            {
                let run = Run("explicit target is Yap, another app comes to the front during the wait: refused")
                let yap = ProcessInfo.processInfo.processIdentifier
                run.processID = yap
                run.frontmost = "me.sma1lboy.yap.mock"
                run.begin()
                run.paste("A", "dictation A", at: 0, lead: .other, target: yap)
                run.advance(to: 0.05)
                run.processID = app
                run.frontmost = "com.apple.TextEdit"
                run.advance(to: 2)
                return run.finish(
                    board: .original, outcomes: ["A": "targetChanged"], keys: [], scratchpad: ["dictation A"],
                    notices: ["targetChanged→scratchpad"])
            },
            {
                let run = Run("Yap in front when the paste starts and still in front: pasted into Yap")
                run.processID = ProcessInfo.processInfo.processIdentifier
                run.frontmost = "me.sma1lboy.yap.mock"
                run.begin()
                run.paste("A", "dictation A", at: 0, lead: .other)
                run.advance(to: 2)
                return run.finish(board: .original, outcomes: ["A": "commandPosted"], keys: ["dictation A"], notices: [])
            },
            {
                // The recorder is a non-activating panel: the app the user dictates into stays in front throughout.
                let run = Run("recorder clicked, the app stays in front: pasted, no notice")
                run.begin()
                run.paste("A", "dictation A", at: 0, lead: .other, submit: true)
                run.advance(to: 2)
                return run.finish(
                    board: .original, outcomes: ["A": "commandPosted", "A⏎": "sent"], keys: ["dictation A", "⏎ enter"],
                    notices: [])
            },
            {
                let run = Run("restore off, another app in front before ⌘V: the text is on the clipboard and in the Scratchpad")
                run.restore.enabled = false
                run.begin()
                run.paste("A", "dictation A", at: 0)
                run.advance(to: 0.01)
                run.processID = otherApp
                run.advance(to: 2)
                return run.finish(
                    board: .text("dictation A", transient: false), outcomes: ["A": "targetChanged"], keys: [],
                    scratchpad: ["dictation A"], notices: ["targetChanged→clipboardAndScratchpad"])
            },
            {
                let run = Run("Accessibility turned off and the user copied before ⌘V: the copy stays, text to the Scratchpad")
                run.begin()
                run.paste("A", "dictation A", at: 0)
                run.userCopies(userCopy, at: 0.005)
                run.canPostKeys = false
                run.advance(to: 2)
                return run.finish(
                    board: .user, outcomes: ["A": "clipboardChanged"], keys: [], scratchpad: ["dictation A"],
                    notices: ["accessibilityMissing→scratchpad"])
            },
            {
                let run = Run("no Accessibility and the clipboard write fails: Scratchpad, not \"copied\"")
                run.canPostKeys = false
                run.begin()
                run.clipboard.writeFails = true
                run.paste("A", "dictation A", at: 0)
                run.advance(to: 2)
                return run.finish(
                    board: .halfWritten, outcomes: ["A": "commandNotPosted"], keys: [], scratchpad: ["dictation A"],
                    notices: ["accessibilityMissing→scratchpad"])
            },
            {
                let run = Run("no text field and the clipboard write fails: Scratchpad only")
                run.focusTakesText = false
                run.begin()
                run.clipboard.writeFails = true
                run.paste("A", "dictation A", at: 0)
                run.advance(to: 2)
                return run.finish(
                    board: .halfWritten, outcomes: ["A": "sentToScratchpad"], keys: [], scratchpad: ["dictation A"],
                    notices: ["noTextField→scratchpad"])
            },
            {
                let run = Run("Undo's Delete: same app, another field focused since the selection")
                run.begin()
                run.advance(to: 0.05)
                run.focus = .element(field(2))
                run.delete("U", in: app, at: 0.1)
                return run.finish(
                    board: .original, outcomes: ["U": "targetChanged"], keys: [], notices: ["deleteSkipped:targetChanged"])
            },
            {
                let run = Run("Undo's Delete: focus moved inside the selected field (web view): sent")
                run.containers = [(1, 3)]
                run.focus = .element(field(3))
                run.begin()
                run.delete("U", in: app, at: 0)
                return run.finish(board: .original, outcomes: ["U": "sent"], keys: ["⌫"], notices: [])
            },
            {
                let run = Run("Undo's Delete can't be sent: receipt, not \"removed\"")
                run.begin()
                run.canPostKeys = false
                run.delete("U", in: app, at: 0)
                return run.finish(board: .original, outcomes: ["U": "notSent"], keys: [], notices: ["deleteSkipped:notSent"])
            },
            {
                // The first Undo's selection read was slow; the second started meanwhile. One Delete, not two.
                let run = Run("two Undos: the earlier one's Delete comes after the later one started, only one Delete")
                run.begin()
                let first = CursorPaster.newRequest()
                run.delete("U2", in: app, at: 0.05)
                run.delete("U1", in: app, at: 0.1, request: first)
                return run.finish(board: .original, outcomes: ["U1": "superseded", "U2": "sent"], keys: ["⌫"], notices: [])
            },
            {
                let run = Run("History paste, its app already in front: pasted, not activated again")
                run.begin()
                run.pasteInto("A", "dictation A", at: 0, target: app)
                run.advance(to: 2)
                return run.finish(board: .original, outcomes: ["A": "commandPosted"], keys: ["dictation A"], notices: [])
            },
            {
                let run = Run("History paste, its app comes to the front 50 ms after it's asked: pasted there")
                run.processID = ProcessInfo.processInfo.processIdentifier
                run.frontmost = "me.sma1lboy.yap.mock"
                run.begin()
                run.pasteInto("A", "dictation A", at: 0, target: app)
                run.advance(to: 0.05)
                run.processID = app
                run.frontmost = "com.apple.TextEdit"
                run.advance(to: 2)
                return run.finish(
                    board: .original, outcomes: ["A": "commandPosted"], keys: ["dictation A"], notices: [],
                    activations: [app])
            },
            {
                let run = Run("History paste, its app takes 0.6 s (past the old fixed 0.15 s): still pasted there")
                run.processID = ProcessInfo.processInfo.processIdentifier
                run.begin()
                run.pasteInto("A", "dictation A", at: 0, target: app)
                run.advance(to: 0.59)
                if !run.keys.isEmpty || run.outcomes["A"] != nil { run.failures.append("done before the app was in front") }
                run.processID = app
                run.advance(to: 2)
                return run.finish(
                    board: .original, outcomes: ["A": "commandPosted"], keys: ["dictation A"], notices: [],
                    activations: [app])
            },
            {
                let run = Run("History paste, its app never comes to the front: refused after 1 s, clipboard untouched")
                run.processID = ProcessInfo.processInfo.processIdentifier
                run.begin()
                let before = run.pasteboard.changeCount
                run.pasteInto("A", "dictation A", at: 0, target: app)
                run.advance(to: 0.95)
                if run.outcomes["A"] != nil { run.failures.append("gave up before 1 s") }
                run.advance(to: 2)
                if run.pasteboard.changeCount != before { run.failures.append("clipboard written") }
                return run.finish(
                    board: .original, outcomes: ["A": "targetChanged"], keys: [], scratchpad: ["dictation A"],
                    notices: ["targetChanged→scratchpad"], activations: [app])
            },
            {
                let run = Run("History paste, a third app comes to the front instead: not pasted into it")
                run.processID = ProcessInfo.processInfo.processIdentifier
                run.begin()
                run.pasteInto("A", "dictation A", at: 0, target: app)
                run.advance(to: 0.05)
                run.processID = otherApp
                run.frontmost = "com.example.other"
                run.advance(to: 2)
                return run.finish(
                    board: .original, outcomes: ["A": "targetChanged"], keys: [], scratchpad: ["dictation A"],
                    notices: ["targetChanged→scratchpad"], activations: [app])
            },
            {
                let run = Run("History paste, its app quits while Yap waits: refused at once")
                run.processID = ProcessInfo.processInfo.processIdentifier
                run.begin()
                run.pasteInto("A", "dictation A", at: 0, target: app)
                run.advance(to: 0.2)
                run.running.remove(app)
                run.advance(to: 0.25)
                if run.outcomes["A"] != "targetChanged" { run.failures.append("still waiting 50 ms after the app quit") }
                run.advance(to: 2)
                return run.finish(
                    board: .original, outcomes: ["A": "targetChanged"], keys: [], scratchpad: ["dictation A"],
                    notices: ["targetQuit→scratchpad"], activations: [app])
            },
            {
                // The request is taken when History's paste starts, so the dictation that starts during the wait wins.
                let run = Run("History paste, a dictation's paste starts while Yap waits for the app: the dictation's goes")
                run.processID = ProcessInfo.processInfo.processIdentifier
                run.begin()
                run.pasteInto("H", "from History", at: 0, target: app)
                run.advance(to: 0.1)
                run.processID = app
                run.paste("B", "dictation B", at: 0.1)
                run.advance(to: 2)
                return run.finish(
                    board: .original, outcomes: ["H": "superseded", "B": "commandPosted"], keys: ["dictation B"],
                    scratchpad: ["from History"], notices: ["superseded→scratchpad"], activations: [app])
            },
            {
                let run = Run("History paste cancelled while Yap waits for the app: nothing sent, no notice")
                run.processID = ProcessInfo.processInfo.processIdentifier
                run.begin()
                run.pasteInto("A", "dictation A", at: 0, target: app)
                run.cancel("A", at: 0.1)
                run.advance(to: 2)
                return run.finish(
                    board: .original, outcomes: ["A": "superseded"], keys: [], scratchpad: ["dictation A"], notices: [],
                    activations: [app])
            },
            {
                let run = Run("History paste with no app recorded: Scratchpad, not the app in front, clipboard untouched")
                run.begin()
                let before = run.pasteboard.changeCount
                run.pasteInto("A", "dictation A", at: 0, target: nil)
                run.advance(to: 2)
                if run.pasteboard.changeCount != before { run.failures.append("clipboard written") }
                return run.finish(
                    board: .original, outcomes: ["A": "targetChanged"], keys: [], scratchpad: ["dictation A"],
                    notices: ["noTarget→scratchpad"])
            },
            {
                let run = Run("Paste Last: 0.15 s for its keys to come up, then pasted where it was pressed")
                run.begin()
                run.pasteInto("A", "last dictation", at: 0, target: app, activate: false, hold: 0.15)
                run.advance(to: 0.2)
                if !run.keys.isEmpty { run.failures.append("⌘V before 0.25 s") }
                run.advance(to: 2)
                return run.finish(board: .original, outcomes: ["A": "commandPosted"], keys: ["last dictation"], notices: [])
            },
            {
                let run = Run("Paste Last: a dictation's paste starts during its 0.15 s: Paste Last isn't sent")
                run.begin()
                run.pasteInto("L", "last dictation", at: 0, target: app, activate: false, hold: 0.15)
                run.paste("B", "dictation B", at: 0.05)
                run.advance(to: 2)
                return run.finish(
                    board: .original, outcomes: ["L": "superseded", "B": "commandPosted"], keys: ["dictation B"],
                    scratchpad: ["last dictation"], notices: ["superseded→scratchpad"])
            },
        ]

        // MARK: - Undo and Rewrite: their field and their request

        /// Undo's paste of the text the last paste replaced, and Rewrite's paste, through LastPasteEditor: they go to the
        /// field it selected in or nowhere, and a request a newer paste replaced while it selected is refused before the
        /// clipboard is touched.
        static let editScenarios: [@MainActor () -> Bool] = [
            {
                let run = Run("Undo puts back the replaced text into the field it selected in")
                run.begin()
                run.undo("U", at: 0)
                run.advance(to: 2)
                return run.finish(board: .original, outcomes: ["U": "commandPosted"], keys: ["original words"], notices: [])
            },
            {
                let run = Run("Undo: same app, another field focused right after the selection: not pasted into it")
                run.afterSelect = { run.focus = .element(field(2)) }
                run.begin()
                run.undo("U", at: 0)
                run.advance(to: 2)
                return run.finish(
                    board: .original, outcomes: ["U": "targetChanged"], keys: [], scratchpad: ["original words"],
                    notices: ["targetChanged→scratchpad"])
            },
            {
                let run = Run("Undo: another field focused during the wait before ⌘V: refused")
                run.begin()
                run.undo("U", at: 0)
                run.advance(to: 0.05)
                run.focus = .element(field(2))
                run.advance(to: 2)
                return run.finish(
                    board: .original, outcomes: ["U": "targetChanged"], keys: [], scratchpad: ["original words"],
                    notices: ["targetChanged→scratchpad"])
            },
            {
                let run = Run("Undo: focus moved inside the selected field (web view): same container, pasted")
                run.containers = [(1, 3)]
                run.afterSelect = { run.focus = .element(field(3)) }
                run.begin()
                run.undo("U", at: 0)
                run.advance(to: 2)
                return run.finish(board: .original, outcomes: ["U": "commandPosted"], keys: ["original words"], notices: [])
            },
            {
                // Unreadable is not a known move: only the app is checked, as for any paste.
                let run = Run("Undo: the app's focus can't be read after the selection: pasted, only the app checked")
                run.afterSelect = { run.focus = .unreadable }
                run.begin()
                run.undo("U", at: 0)
                run.advance(to: 2)
                return run.finish(board: .original, outcomes: ["U": "commandPosted"], keys: ["original words"], notices: [])
            },
            {
                let run = Run("Rewrite: pasted over the last paste in the field it selected in")
                run.begin()
                run.rewrite("R", "rewritten again", at: 0)
                run.advance(to: 2)
                return run.finish(board: .original, outcomes: ["R": "commandPosted"], keys: ["rewritten again"], notices: [])
            },
            {
                let run = Run("Rewrite: another field focused right after the selection: not pasted into it")
                run.afterSelect = { run.focus = .element(field(2)) }
                run.begin()
                run.rewrite("R", "rewritten again", at: 0)
                run.advance(to: 2)
                return run.finish(
                    board: .original, outcomes: ["R": "targetChanged"], keys: [], scratchpad: ["rewritten again"],
                    notices: ["targetChanged→scratchpad"])
            },
            {
                // Undo's request is taken before its 0.15 s selection; B starts at 0.1 and waits for ⌘V until 0.2.
                let run = Run("Undo selects slowly, a dictation's paste starts meanwhile: Undo refused before writing, B pasted once")
                run.selectDelay = 0.15
                run.begin()
                run.undo("U", at: 0)
                run.paste("B", "dictation B", at: 0.1, lead: .other)
                run.advance(to: 0.15)
                run.expectBoard(.text("dictation B", transient: true), "when Undo came back")
                run.advance(to: 2)
                return run.finish(
                    board: .original, outcomes: ["U": "superseded", "B": "commandPosted"], keys: ["dictation B"],
                    scratchpad: ["original words"], notices: ["superseded→scratchpad"])
            },
            {
                let run = Run("Undo selects slowly, restore off, a dictation's paste starts meanwhile: B's text stays")
                run.restore.enabled = false
                run.selectDelay = 0.15
                run.begin()
                run.undo("U", at: 0)
                run.paste("B", "dictation B", at: 0.1, lead: .other)
                run.advance(to: 2)
                return run.finish(
                    board: .text("dictation B", transient: false), outcomes: ["U": "superseded", "B": "commandPosted"],
                    keys: ["dictation B"], scratchpad: ["original words"], notices: ["superseded→scratchpad"])
            },
            {
                let run = Run("Undo selects slowly, a paste starts, then the user copies: Undo doesn't overwrite the copy")
                run.selectDelay = 0.15
                run.begin()
                run.undo("U", at: 0)
                run.paste("B", "dictation B", at: 0.1, lead: .other)
                run.userCopies(userCopy, at: 0.12)
                run.advance(to: 0.15)
                run.expectBoard(.user, "when Undo came back")
                run.advance(to: 2)
                return run.finish(
                    board: .user, outcomes: ["U": "superseded", "B": "clipboardChanged"], keys: [],
                    scratchpad: ["original words", "dictation B"],
                    notices: ["superseded→scratchpad", "clipboardChanged→scratchpad"])
            },
            {
                // No text field focused just as Undo comes back: the early return copies, but only a current request.
                let run = Run("Undo selects slowly, a paste starts, no text field as Undo comes back: B's clipboard kept")
                run.selectDelay = 0.15
                run.begin()
                run.undo("U", at: 0)
                run.paste("B", "dictation B", at: 0.1, lead: .other)
                run.advance(to: 0.14)
                run.focusTakesText = false
                run.advance(to: 0.16)
                run.focusTakesText = true
                run.advance(to: 2)
                return run.finish(
                    board: .original, outcomes: ["U": "superseded", "B": "commandPosted"], keys: ["dictation B"],
                    scratchpad: ["original words"], notices: ["superseded→scratchpad"])
            },
            {
                let run = Run("Undo selects slowly, Accessibility gone as it comes back, a paste waiting: B's clipboard kept")
                run.selectDelay = 0.15
                run.begin()
                run.undo("U", at: 0)
                run.paste("B", "dictation B", at: 0.1, lead: .other)
                run.advance(to: 0.14)
                run.canPostKeys = false
                run.advance(to: 0.16)
                run.canPostKeys = true
                run.advance(to: 2)
                return run.finish(
                    board: .original, outcomes: ["U": "superseded", "B": "commandPosted"], keys: ["dictation B"],
                    scratchpad: ["original words"], notices: ["superseded→scratchpad"])
            },
            {
                let run = Run("Rewrite selects slowly, a dictation's paste starts meanwhile: Rewrite refused before writing")
                run.selectDelay = 0.15
                run.begin()
                run.rewrite("R", "rewritten again", at: 0)
                run.paste("B", "dictation B", at: 0.1, lead: .other)
                run.advance(to: 2)
                return run.finish(
                    board: .original, outcomes: ["R": "superseded", "B": "commandPosted"], keys: ["dictation B"],
                    scratchpad: ["rewritten again"], notices: ["superseded→scratchpad"])
            },
            {
                let run = Run("Undo cancelled while it selects, nothing newer: clipboard untouched, nothing sent, no notice")
                run.selectDelay = 0.15
                run.begin()
                let before = run.pasteboard.changeCount
                run.undo("U", at: 0)
                run.cancel("U", at: 0.05)
                run.advance(to: 2)
                if run.pasteboard.changeCount != before { run.failures.append("clipboard written") }
                return run.finish(
                    board: .original, outcomes: ["U": "superseded"], keys: [], scratchpad: ["original words"], notices: [])
            },
        ]
    }
#endif
