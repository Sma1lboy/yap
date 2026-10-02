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
