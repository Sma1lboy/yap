#if DEBUG
    import Foundation
    import OSLog
    import SwiftData

    /// `make mcp-check`: launched with `--mcp-fixture <data folder> <expected folder>`, the app writes a Yap data
    /// folder for yap-mcp to read and quits before touching any settings or data of its own. The folder gets the
    /// app's stores, made by the app's own `createPersistentContainer` (default.store left with its `-wal`, as a
    /// running Yap has it), with three meetings and dictations in History (one with an app, a mode and a
    /// cleaned-up text in Chinese and English, one long one, and 55 alike for search_history's limit), and
    /// one meeting's `Recordings/meetings/<id>/segments.json`; that meeting's speakers are renamed the way History's
    /// Speaker Names… does it (`MeetingEdits.rename`). The dictionary gets words and replacement rules. For each
    /// meeting, the expected folder gets `<id>.md`, History's Export Markdown of it. One
    /// `mcp-fixture: <role> <id>` line per named entry goes to stdout.
    ///
    /// `--mcp-fixture-writer <data folder>` keeps adding dictations to that folder's history, one save each, for up
    /// to two minutes: the writer yap-mcp has to read next to. Dictation n's text is `writer-seq-n` and 8 KB of
    /// filler, its enhanced text `writer-check-n`; `mcp-writer: n` goes to stdout after each save.
    @MainActor
    enum MCPFixture {
        static let argument = "--mcp-fixture"
        static let writerArgument = "--mcp-fixture-writer"
        static let writerFiller = String(repeating: "0123456789abcdef", count: 512)

        static func runIfRequested() {
            MCPEvalFixture.runIfRequested()
            let arguments = CommandLine.arguments
            if let index = arguments.firstIndex(of: writerArgument), arguments.indices.contains(index + 1) {
                keepWriting(to: URL(fileURLWithPath: arguments[index + 1], isDirectory: true))
            }
            guard let index = arguments.firstIndex(of: argument), arguments.indices.contains(index + 2) else { return }
            // Kept open until exit, as a running Yap keeps it: closing the store would fold the -wal into it.
            let container: ModelContainer
            do {
                container = try write(
                    data: URL(fileURLWithPath: arguments[index + 1], isDirectory: true),
                    expected: URL(fileURLWithPath: arguments[index + 2], isDirectory: true))
            } catch {
                print("mcp-fixture: failed \(error)")
                fflush(stdout)
                exit(1)
            }
            fflush(stdout)
            withExtendedLifetime(container) { exit(0) }
        }

        private static func container(in data: URL) throws -> ModelContainer {
            try VoiceInkApp.createPersistentContainer(
                schema: YapStores.schema, logger: Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MCPFixture"),
                directory: data)
        }

        private static func keepWriting(to data: URL) -> Never {
            do {
                let container = try container(in: data)
                let context = ModelContext(container)
                let deadline = Date().addingTimeInterval(120)
                var sequence = 0
                while Date() < deadline {
                    sequence += 1
                    let entry = Transcription(
                        text: "writer-seq-\(sequence) " + writerFiller, duration: 1,
                        enhancedText: "writer-check-\(sequence)", transcriptionStatus: .completed)
                    context.insert(entry)
                    try context.save()
                    print("mcp-writer: \(sequence)")
                    fflush(stdout)
                    usleep(2_000)
                }
                exit(0)
            } catch {
                print("mcp-writer: failed \(error)")
                fflush(stdout)
                exit(1)
            }
        }

        private static func date(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
            Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
        }

        private static func write(data: URL, expected: URL) throws -> ModelContainer {
            let fileManager = FileManager.default
            try fileManager.createDirectory(at: expected, withIntermediateDirectories: true)
            let container = try container(in: data)
            let context = ModelContext(container)

            // Speakers named in History: Me, Others 1, Others 2 (and a piece that couldn't be transcribed).
            let segments = [
                MeetingSegment(speaker: .me, start: 2, end: 20, text: "先看一下 CI，然后 review 一下 API 的字段。"),
                MeetingSegment(speaker: .others, start: 21, end: 44, text: "Can we ship on Friday?", remote: 1),
                MeetingSegment(speaker: .others, start: 45, end: 70, text: "Kubernetes 那边的 rollout 我已经跑过了。", remote: 2),
                MeetingSegment(speaker: .others, start: 71, end: 95, text: "", remote: 1, failed: true),
                MeetingSegment(speaker: .me, start: 3_610, end: 3_630, text: "Thursday works. 周四见。"),
            ]
            let folder = data.appendingPathComponent("Recordings/meetings/\(UUID().uuidString)", isDirectory: true)
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONEncoder().encode(segments).write(to: folder.appendingPathComponent("segments.json"))
            let renamed = meeting(
                MeetingNotes.transcript(segments), at: date(29, 15, 0), duration: 3_634,
                notes: "## Summary\n- Ship on Friday.\n\n## Action items\n- [ ] Review the API fields — Me — Thursday")
            renamed.audioFileURL = folder.appendingPathComponent("mix.wav").absoluteString
            renamed.meetingFailedPieces = 1
            context.insert(renamed)
            try context.save()
            if let problem = MeetingEdits.rename(
                renamed, names: ["me": "Tingting", "others-1": "Reed", "others-2": "Shelley"], in: context)
            {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: problem])
            }

            // Speakers still being told apart: plain Me / Others, no notes.
            let pending = meeting(
                MeetingNotes.transcript([
                    MeetingSegment(speaker: .me, start: 0, end: 12, text: "Morning, everyone."),
                    MeetingSegment(speaker: .others, start: 13, end: 30, text: "早上好，我们开始吧。"),
                ]), at: date(30, 9, 30), duration: 31, notes: nil)
            pending.meetingSpeakerStatus = SpeakerSplitSkip.pendingStatus
            context.insert(pending)

            // Telling the speakers apart failed.
            let failed = meeting(
                MeetingNotes.transcript([MeetingSegment(speaker: .others, start: 5, end: 25, text: "Budget is approved.")]),
                at: date(28, 10, 0), duration: 125, notes: "- Budget approved.")
            failed.meetingSpeakerStatus = SpeakerSplitSkip.timedOut.rawValue
            context.insert(failed)

            // A dictation, which no meeting tool may return.
            let dictation = Transcription(text: "A dictation, not a meeting.", duration: 3, transcriptionStatus: .completed)
            dictation.timestamp = date(30, 10, 0)
            context.insert(dictation)

            // Dictated into an app with a mode that cleaned it up; Chinese and English in one sentence.
            let mixed = Transcription(
                text: "好的 我们先看一下 ci 再合并", duration: 4, enhancedText: "好的，我们先看一下 CI 再合并。",
                modeName: "Chat", transcriptionStatus: .completed)
            mixed.timestamp = date(30, 10, 5)
            mixed.sourceAppName = "Slack"
            mixed.sourceAppBundleID = "com.tinyspeck.slackmacgap"
            context.insert(mixed)

            // Long enough that a snippet from its middle is cut on both sides.
            let long = Transcription(
                text: "notes for the deploy", duration: 60,
                enhancedText: String(repeating: "Before the deploy we check the dashboards. ", count: 5)
                    + "Then the Kubernetes rollout starts. "
                    + String(repeating: "After the deploy we watch the error rate. ", count: 5),
                transcriptionStatus: .completed)
            long.timestamp = date(27, 8, 0)
            context.insert(long)

            // 55 alike, for search_history's limit.
            for minute in 0..<55 {
                let note = Transcription(text: "Standup note \(minute)", duration: 2, transcriptionStatus: .completed)
                note.timestamp = date(1, 9, minute)
                context.insert(note)
            }

            // The dictionary: words (one learned automatically) and replacement rules (one with two originals).
            let learned = VocabularyWord(word: "Tingting")
            learned.isAutoLearned = true
            for word in [VocabularyWord(word: "Kubernetes"), VocabularyWord(word: "Shelley"), learned] {
                context.insert(word)
            }
            let k8s = WordReplacement(originalText: "k8s, kates", replacementText: "Kubernetes")
            let typo = WordReplacement(originalText: "先看下", replacementText: "先看一下")
            typo.isAutoLearned = true
            context.insert(k8s)
            context.insert(typo)
            try context.save()

            // History's Save Meetings to Folder… with the whole History selected, next to the expected folder:
            // mcp-check compares its files with get_meeting and the export, byte for byte.
            let archive = expected.deletingLastPathComponent().appendingPathComponent("archive", isDirectory: true)
            try fileManager.createDirectory(at: archive, withIntermediateDirectories: true)
            let selection = [renamed, pending, failed, dictation, mixed, long]
            let report = MeetingArchive.export(MeetingArchive.entries(for: selection), to: archive)
            guard report.written == 3 else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "archive: \(report.items)"])
            }
            for (role, entry) in [
                ("renamed", renamed), ("pending", pending), ("failed", failed), ("dictation", dictation),
                ("mixed", mixed), ("long", long),
            ] {
                if entry.isMeeting {
                    try Data(MeetingNotes.markdown(for: entry).utf8)
                        .write(to: expected.appendingPathComponent("\(entry.id.uuidString).md"))
                }
                print("mcp-fixture: \(role) \(entry.id.uuidString)")
            }
            return container
        }

        private static func meeting(_ text: String, at timestamp: Date, duration: TimeInterval, notes: String?) -> Transcription {
            let meeting = Transcription(text: text, duration: duration, enhancedText: notes, transcriptionStatus: .completed)
            meeting.kind = Transcription.meetingKind
            meeting.timestamp = timestamp
            return meeting
        }
    }
#endif
