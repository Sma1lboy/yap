#if DEBUG
    import CryptoKit
    import Foundation
    import OSLog
    import SwiftData

    /// `scripts/meeting-archive-check.sh`: `--meeting-archive-check <data folder> <step> [arguments]`, on a History
    /// store in that folder (the app's own `createPersistentContainer`), then quits. Steps:
    /// - `seed`: two meetings on the same day (one with a failed piece, one with renamed speakers, both with notes)
    ///   and a dictation, each meeting with a `mix.wav` in `Recordings/meetings/<id>/`.
    /// - `export <folder> <expected folder> [start epoch]`: the whole History as the selection (the dictation too),
    ///   saved to `<folder>` the way History's Save Meetings to Folder… does (`MeetingArchive`); waits until the epoch
    ///   first, so two launches race. Each meeting's Export Markdown bytes go to `<expected folder>/<id>.md`.
    /// - `edit`: new notes for the first meeting, as a successful Regenerate Notes saves them.
    /// - `auto <action> [arguments]`: Settings › Meetings › Save Meetings to a Folder Automatically
    ///   (`MeetingAutoArchive.shared`, its switch and folder in this identity's defaults, so each launch is a restart),
    ///   driven through the app's own save paths (`MeetingRecorder.save`, `applySpeakers`, `MeetingEdits.rename` and
    ///   `saveNotes`); see `auto(_:data:_:)`. `--auto-archive-delay S` makes each file wait S seconds once allowed to
    ///   start. Each action waits for the queue, then prints the switch, the folder and the last result.
    /// Prints `archive-check: …` lines, among them a SHA-256 of every entry's fields before and after the export.
    @MainActor
    enum MeetingArchiveCheck {
        static let argument = "--meeting-archive-check"

        static func runIfRequested() {
            let arguments = CommandLine.arguments
            guard let index = arguments.firstIndex(of: argument), arguments.indices.contains(index + 2) else { return }
            let data = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
            let rest = Array(arguments[(index + 3)...])
            // Exits before the launch-time self-checks; this one is the subject here.
            MeetingArchive.selfCheck()
            do {
                let container = try VoiceInkApp.createPersistentContainer(
                    schema: YapStores.schema, logger: Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MeetingArchiveCheck"),
                    directory: data)
                let context = ModelContext(container)
                switch arguments[index + 2] {
                case "seed": try seed(context, data: data)
                case "export": try export(context, rest)
                case "edit": try edit(context)
                case "auto": try auto(context, data: data, rest)
                default: print("archive-check: unknown step")
                }
            } catch {
                print("archive-check: failed \(error)")
                fflush(stdout)
                exit(1)
            }
            fflush(stdout)
            exit(0)
        }

        private static func seed(_ context: ModelContext, data: URL) throws {
            let day = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 9, minute: 5))!
            let first = Transcription(
                text: "[00:00] \(MeetingSegment.Speaker.me.label): 先看一下 CI，然后 review API 的字段。\n"
                    + "[00:21] \(MeetingSegment.Speaker.others.label): \(MeetingNotes.failedMarker)",
                duration: 754, enhancedText: "## Summary\n- CI first.\n\n## Action items\n- [ ] Review the API fields — Me — Thursday",
                transcriptionStatus: .completed)
            first.meetingFailedPieces = 1
            let second = Transcription(
                text: "[00:00] Tingting: ../../etc/passwd: 周四见。\n[00:08] Reed: Can we ship on Friday?", duration: 125,
                enhancedText: "- Ship on Friday.", transcriptionStatus: .completed)
            second.meetingSpeakerNamesJSON = ["me": "Tingting", "others-1": "Reed"].json
            for (meeting, offset) in [(first, 0.0), (second, 5 * 3_600.0)] {
                meeting.kind = Transcription.meetingKind
                meeting.timestamp = day.addingTimeInterval(offset)
                let folder = data.appendingPathComponent("Recordings/meetings/\(meeting.id.uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let mix = folder.appendingPathComponent("mix.wav")
                try Data(repeating: 7, count: 4_096).write(to: mix)
                meeting.audioFileURL = mix.absoluteString
                context.insert(meeting)
            }
            let dictation = Transcription(text: "A dictation, not a meeting.", duration: 3, transcriptionStatus: .completed)
            dictation.timestamp = day.addingTimeInterval(3_600)
            context.insert(dictation)
            try context.save()
            print("archive-check: meeting \(first.id.uuidString.lowercased())")
            print("archive-check: meeting \(second.id.uuidString.lowercased())")
            print("archive-check: dictation \(dictation.id.uuidString.lowercased())")
        }

        private static func export(_ context: ModelContext, _ arguments: [String]) throws {
            guard arguments.count >= 2 else { throw CocoaError(.fileNoSuchFile) }
            let folder = URL(fileURLWithPath: arguments[0], isDirectory: true)
            let expected = URL(fileURLWithPath: arguments[1], isDirectory: true)
            let selection = try context.fetch(FetchDescriptor<Transcription>())
            print("archive-check: selection \(selection.count) meetings \(selection.filter(\.isMeeting).count)")
            print("archive-check: history-before \(fingerprint(selection))")
            try FileManager.default.createDirectory(at: expected, withIntermediateDirectories: true)
            for meeting in selection where meeting.isMeeting {
                try Data(MeetingNotes.markdown(for: meeting).utf8)
                    .write(to: expected.appendingPathComponent("\(meeting.id.uuidString.lowercased()).md"))
            }
            let entries = MeetingArchive.entries(for: selection)
            if arguments.count > 2, let start = TimeInterval(arguments[2]) {
                Thread.sleep(until: Date(timeIntervalSince1970: start))
            }
            let report = MeetingArchive.export(entries, to: folder)
            for item in report.items {
                print("archive-check: item \(item.id.uuidString.lowercased()) \(describe(item.outcome)) \(item.fileName)")
            }
            print("archive-check: written \(report.written) there \(report.alreadyThere) conflicts \(report.conflicts.count) failed \(report.failures.count)")
            print("archive-check: history-after \(fingerprint(try context.fetch(FetchDescriptor<Transcription>()))) changes \(context.hasChanges)")
        }

        private static func edit(_ context: ModelContext) throws {
            let meetings = try context.fetch(FetchDescriptor<Transcription>(sortBy: [SortDescriptor(\.timestamp)])).filter(\.isMeeting)
            guard let first = meetings.first else { throw CocoaError(.fileNoSuchFile) }
            first.enhancedText = "## Summary\n- CI first, then the API.\n"
            try context.save()
            print("archive-check: edited \(first.id.uuidString.lowercased())")
        }

        /// The auto-archive actions:
        /// - `on [folder]` / `off`: the switch, as Settings sets it (a folder: the one just chosen).
        /// - `create [pending]`: a new meeting saved as finishing one saves it, with a `segments.json` of two remote
        ///   pieces; `pending`: its speakers still being told apart.
        /// - `create-cleanup`: the same, then deleted right away with its audio, as the retention cleanup does.
        /// - `delete <id>`: that cleanup on a saved meeting.
        /// - `speakers <id> two|fail|gone`: the speakers arriving after saving (two people; the diarizer timed out;
        ///   the recording folder deleted first).
        /// - `rename <id> <key=name,…>`, `notes <id> <text>`: Speaker Names and a Regenerate Notes that got notes
        ///   (`--meeting-fail-save`: their save fails).
        /// - `resave <id>`: the same saved meeting handed on twice more, unchanged.
        /// - `race-off`: two meetings saved, then turned off at once. `race-switch <folder>`: two meetings saved, the
        ///   folder changed at once, then a third meeting saved.
        private static func auto(_ context: ModelContext, data: URL, _ arguments: [String]) throws {
            let all = CommandLine.arguments
            if let index = all.firstIndex(of: "--auto-archive-delay"), all.indices.contains(index + 1) {
                MeetingAutoArchive.writerDelay = TimeInterval(all[index + 1]) ?? 0
            }
            let archive = MeetingAutoArchive.shared
            func entry(_ id: String) throws -> Transcription {
                guard let uuid = UUID(uuidString: id), let found = try context.fetch(
                    FetchDescriptor<Transcription>(predicate: #Predicate { $0.id == uuid })).first
                else { throw CocoaError(.fileNoSuchFile) }
                return found
            }
            func create(pending: Bool) throws -> Transcription {
                let id = UUID()
                let folder = data.appendingPathComponent("Recordings/meetings/\(id.uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let mix = folder.appendingPathComponent("mix.wav")
                try Data(repeating: 7, count: 4_096).write(to: mix)
                let segments = [
                    MeetingSegment(speaker: .me, start: 0, end: 5, text: "Let's start with the CI."),
                    MeetingSegment(speaker: .others, start: 6, end: 20, text: "The build is green."),
                    MeetingSegment(speaker: .others, start: 22, end: 40, text: "Ship it on Friday then."),
                ]
                try JSONEncoder().encode(segments).write(to: folder.appendingPathComponent("segments.json"))
                let meeting = Transcription(
                    text: MeetingNotes.transcript(segments), duration: 40, enhancedText: "- Ship on Friday (\(id.uuidString.prefix(8))).",
                    audioFileURL: mix.absoluteString, transcriptionStatus: .completed)
                meeting.kind = Transcription.meetingKind
                meeting.meetingSpeakerStatus = pending ? SpeakerSplitSkip.pendingStatus : nil
                if let error = MeetingRecorder.shared.save(meeting, in: context) {
                    throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: error])
                }
                print("archive-check: created \(meeting.id.uuidString.lowercased())")
                return meeting
            }
            /// What the retention cleanup does with an entry: its audio folder, then the entry.
            func cleanUp(_ meeting: Transcription) throws {
                if let url = meeting.audioFileURL.flatMap(URL.init(string:)) { try Transcription.removeAudio(at: url) }
                let id = meeting.id.uuidString.lowercased()
                context.delete(meeting)
                try context.save()
                print("archive-check: deleted \(id)")
            }

            var failure: Error?
            spin {
                do {
                    switch arguments.first ?? "" {
                    case "on":
                        await archive.turnOn(folder: arguments.count > 1 ? URL(fileURLWithPath: arguments[1], isDirectory: true) : nil)
                    case "off":
                        await archive.turnOff()
                    case "create":
                        _ = try create(pending: arguments.dropFirst().first == "pending")
                    case "create-cleanup":
                        try cleanUp(try create(pending: false))
                    case "delete":
                        try cleanUp(try entry(arguments[1]))
                    case "speakers":
                        let meeting = try? entry(arguments[1])
                        let result: Result<[SpeakerTurn], Error>
                        switch arguments[2] {
                        case "two": result = .success([SpeakerTurn(id: "A", start: 6, end: 20), SpeakerTurn(id: "B", start: 22, end: 40)])
                        case "gone":
                            if let url = meeting?.audioFileURL.flatMap(URL.init(string:)) { try Transcription.removeAudio(at: url) }
                            result = .success([])
                        default: result = .failure(MeetingDiarizer.Failure.timedOut(90))
                        }
                        MeetingRecorder.shared.applySpeakers(result, to: UUID(uuidString: arguments[1])!, in: context)
                        print("archive-check: speaker-status \((try? entry(arguments[1])).map { $0.meetingSpeakerStatus ?? "none" } ?? "no-entry")")
                    case "rename":
                        var names: MeetingSpeakerNames = [:]
                        for pair in arguments[2].split(separator: ",") {
                            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                            names[parts[0]] = parts[1]
                        }
                        print("archive-check: edit-error \(MeetingEdits.rename(try entry(arguments[1]), names: names, in: context) ?? "none")")
                    case "notes":
                        let summary = MeetingSummarizer.Summary(notes: arguments[2], modelName: "check")
                        let meeting = try entry(arguments[1])
                        print("archive-check: edit-error \(MeetingEdits.saveNotes(arguments[2], from: summary, to: meeting, in: context) ?? "none")")
                        print("archive-check: notes-now \(meeting.enhancedText ?? "")")
                    case "resave":
                        let meeting = try entry(arguments[1])
                        try MeetingEdits.save(meeting, in: context)
                        try MeetingEdits.save(meeting, in: context)
                    case "race-off":
                        _ = try create(pending: false)
                        _ = try create(pending: false)
                        await archive.turnOff()
                        print("archive-check: off-at \(Int64(Date().timeIntervalSince1970 * 1_000_000_000))")
                    case "race-switch":
                        _ = try create(pending: false)
                        _ = try create(pending: false)
                        await archive.turnOn(folder: URL(fileURLWithPath: arguments[1], isDirectory: true))
                        print("archive-check: switched-at \(Int64(Date().timeIntervalSince1970 * 1_000_000_000))")
                        _ = try create(pending: false)
                    default:
                        throw CocoaError(.featureUnsupported)
                    }
                } catch {
                    failure = error
                }
                await archive.drain()
            }
            if let failure { throw failure }
            let last = archive.lastResult.map { "\($0.item.id.uuidString.lowercased()) \(describe($0.item.outcome)) \($0.item.fileName)" } ?? "none"
            print("archive-check: auto enabled \(archive.isEnabled) folder \(archive.folder?.path ?? "none") queued \(archive.queued)")
            print("archive-check: auto last \(last)")
        }

        /// Runs `body` on the main actor and waits for it here, during the app's init, by running the main run loop.
        private static func spin(_ body: @escaping @MainActor () async -> Void) {
            final class Flag { var done = false }
            let flag = Flag()
            Task { @MainActor in
                await body()
                flag.done = true
            }
            while !flag.done { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        }

        private static func describe(_ outcome: MeetingArchive.Outcome) -> String {
            switch outcome {
            case .written: return "written"
            case .alreadyThere: return "there"
            case .conflict(let conflict): return "conflict-\(conflict)"
            case .failed(let failure): return "failed-\(failure)"
            }
        }

        /// Every field an export could touch, of every entry.
        private static func fingerprint(_ entries: [Transcription]) -> String {
            let fields = entries.sorted { $0.id.uuidString < $1.id.uuidString }.map {
                [$0.id.uuidString, "\($0.timestamp.timeIntervalSince1970)", "\($0.duration)", $0.text, $0.enhancedText ?? "",
                 $0.kind ?? "", $0.meetingSpeakerNamesJSON ?? "", $0.audioFileURL ?? "", "\($0.meetingFailedPieces ?? 0)"]
                    .joined(separator: "\u{1}")
            }
            return SHA256.hash(data: Data(fields.joined(separator: "\u{2}").utf8)).map { String(format: "%02x", $0) }.joined()
        }
    }
#endif
