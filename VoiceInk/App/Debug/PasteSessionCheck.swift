#if DEBUG
    import AppKit

    /// `scripts/paste-session-check.sh`: `--paste-session-check`, then quits. Each scenario runs CursorPaster's own
    /// paste (prepare, wait, ownership, ⌘V, restore) on a private pasteboard of its own (NSPasteboard(name:)), with
    /// outlets that record instead of acting: ⌘V notes what the pasteboard held when it would have gone out, the
    /// field in front always takes text, Auto Learn / Last Paste, the Scratchpad and notifications are lists, and time
    /// only moves when the scenario advances it. The general pasteboard is never touched, no key is sent and nothing
    /// is read from the app in front. Prints one `paste-check: {json}` line per scenario with what happened, what
    /// should have, and `pass`; then `paste-check-done:`.
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
            var keys: [String] = []
            var sent: [String] = []
            var scratchpad: [String] = []
            var outcomes: [String: String] = [:]
            var notes: [String] = []
            var failures: [String] = []
            private var closed = false

            init(_ name: String) {
                self.name = name
                clipboard = PasteClipboard(NSPasteboard(name: NSPasteboard.Name("me.sma1lboy.yap.paste-check.\(UUID().uuidString)")))
                var outlets = CursorPaster.Outlets.check(clipboard)
                let clock = self.clock
                outlets.frontmostApp = { [unowned self] in (self.frontmost, nil) }
                outlets.postPasteKeys = { [unowned self] in
                    guard self.keyResult == .commandPosted else { return (self.keyResult, nil) }
                    self.keys.append(self.pasteboard.string(forType: .string) ?? "<no text>")
                    return (.commandPosted, clock.now)
                }
                outlets.pasteSent = { [unowned self] in
                    self.sent.append($0.text)
                    return nil
                }
                outlets.toScratchpad = { [unowned self] in self.scratchpad.append($0) }
                outlets.notify = { [unowned self] in self.notes.append("\($0)") }
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

            func paste(_ label: String, _ text: String, at time: TimeInterval, lead: CursorPaster.Lead = .shortcut) {
                advance(to: time)
                let task = CursorPaster.startPasteAtCursor(text, lead: lead)
                Task { @MainActor [unowned self] in self.outcomes[label] = "\(await task.value.result)" }
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
            func finish(
                board final: Final, outcomes expectedOutcomes: [String: String], keys expectedKeys: [String],
                scratchpad expectedScratchpad: [String] = []
            ) -> Bool {
                advance(to: clock.now)
                expectBoard(final, "end")
                if outcomes != expectedOutcomes { failures.append("outcomes \(outcomes), expected \(expectedOutcomes)") }
                if keys != expectedKeys { failures.append("⌘V pasted \(keys), expected \(expectedKeys)") }
                let expectedSent = expectedOutcomes.values.filter { $0 == "commandPosted" }.count
                if sent.count != expectedSent { failures.append("Auto Learn / Last Paste heard of \(sent), expected \(expectedSent)") }
                if scratchpad != expectedScratchpad { failures.append("Scratchpad got \(scratchpad), expected \(expectedScratchpad)") }

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
                    "keys": keys, "sentToAutoLearn": sent, "scratchpad": scratchpad, "notices": notes,
                    "finalBoard": finalBoard, "expectedBoard": "\(final)",
                ]
                if let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) {
                    print("paste-check: \(String(decoding: data, as: UTF8.self))")
                }
                return failures.isEmpty
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
                    board: .original, outcomes: ["A": "clipboardChanged", "B": "commandPosted"], keys: ["dictation B"],
                    scratchpad: ["dictation A"])
            },
            {
                let run = Run("user copies before ⌘V")
                run.begin()
                run.paste("A", "dictation A", at: 0)
                run.userCopies(userCopy, at: 0.01)
                run.advance(to: 2)
                return run.finish(
                    board: .user, outcomes: ["A": "clipboardChanged"], keys: [], scratchpad: ["dictation A"])
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
                    board: .user, outcomes: ["A": "clipboardChanged"], keys: [], scratchpad: ["dictation A"])
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
                    board: .user, outcomes: ["A": "clipboardChanged", "B": "commandPosted"], keys: ["dictation B"],
                    scratchpad: ["dictation A"])
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
                    board: .original, outcomes: ["A": "commandNotPosted"], keys: [], scratchpad: ["dictation A"])
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
                    scratchpad: ["dictation B"])
            },
            {
                let run = Run("⌘V can't be sent")
                run.keyResult = .commandNotPosted
                run.begin()
                run.paste("A", "dictation A", at: 0)
                run.advance(to: 2)
                return run.finish(
                    board: .text("dictation A", transient: true), outcomes: ["A": "commandNotPosted"], keys: [])
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
                    keys: ["dictation A"])
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
        ]
    }
#endif
