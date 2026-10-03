#if DEBUG
    import AppKit
    import SwiftData
    import os

    /// `scripts/meeting-files-check.sh`: launched with `--meeting-files <mic.wav> <system.wav>` (16 kHz mono PCM16),
    /// the app runs both files through meeting recording's chunking, transcription (the mode's model), notes and
    /// saving, prints the result between `meeting-check:` marker lines and quits.
    /// `--meeting-fail-pieces N` makes the first N pieces fail; `--meeting-fail-save` makes saving the entry fail.
    /// `--meeting-speaker-wait S` waits S seconds for the speakers before saving without them (default 10); when it
    /// saves without them, the check waits for them to arrive in the saved entry and prints it again, or with
    /// `--meeting-exit-before-speakers` quits right away, as if the app had quit then.
    /// `--meeting-recovery-check`: waits for the launch-time recovery of interrupted meetings, prints it, quits.
    /// `--meeting-speakers-resume-check`: waits for the launch-time resume of speakers cut off by a quit, prints the
    /// entries, quits.
    /// `--meeting-edit-check <folder> <key=name,…> [--meeting-regenerate N] [--meeting-fail-notes N]`: after the
    /// launch-time recovery, renames the speakers of the saved meeting in that folder, then regenerates its notes N
    /// times (the first `--meeting-fail-notes` requests fail), printing each result, and quits.
    /// `--meeting-retranscribe-check <folder>`: after the launch-time recovery, prints what Transcribe Meeting makes
    /// of every History entry, then starts it for the meeting in that folder the way History's button does (the
    /// mode's model, no model: refused), waits for the end and prints the entry. `--meeting-retranscribe-twice`
    /// clicks twice; `--meeting-retranscribe-cancel-after N` cancels right after the Nth piece's request;
    /// `--meeting-retranscribe-kill-after N` kills the app there (SIGKILL), as a crash or a forced quit would.
    @MainActor
    enum MeetingFilesCheck {
        static let argument = "--meeting-files"
        static let recoveryArgument = "--meeting-recovery-check"
        static let speakersResumeArgument = "--meeting-speakers-resume-check"
        static var isRequested: Bool {
            [argument, recoveryArgument, speakersResumeArgument, "--meeting-edit-check", retranscribeArgument]
                .contains(where: CommandLine.arguments.contains)
        }
        static var speakerWait: TimeInterval? {
            CommandLine.arguments.contains("--meeting-speaker-wait") ? TimeInterval(number(after: "--meeting-speaker-wait")) : nil
        }
        static var failPieces: Int { number(after: "--meeting-fail-pieces") }
        nonisolated static var failsSave: Bool { CommandLine.arguments.contains("--meeting-fail-save") }

        nonisolated private static func number(after flag: String) -> Int {
            let arguments = CommandLine.arguments
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return 0 }
            return Int(arguments[index + 1]) ?? 0
        }

        static let retranscribeArgument = "--meeting-retranscribe-check"
        /// Transcription requests made by meeting pieces in this launch.
        nonisolated static let requests = OSAllocatedUnfairLock(initialState: 0)
        private static var retranscribing: UUID?
        private static var retranscriptionEnd: CheckedContinuation<MeetingRetranscriber.State, Never>?

        /// After each piece's transcription request: counts it; true when Transcribe Meeting is to be canceled now.
        nonisolated static func pieceTranscribed() -> Bool {
            let count = requests.withLock { $0 += 1; return $0 }
            if count == number(after: "--meeting-retranscribe-kill-after") {
                print("meeting-check: killed after \(count) requests")
                fflush(stdout)
                kill(getpid(), SIGKILL)
            }
            guard count == number(after: "--meeting-retranscribe-cancel-after") else { return false }
            Task { @MainActor in retranscribing.map(MeetingRetranscriber.shared.cancel) }
            return true
        }

        static func retranscriptionEnded(_ id: UUID, _ state: MeetingRetranscriber.State) {
            guard id == retranscribing else { return }
            retranscriptionEnd?.resume(returning: state)
            retranscriptionEnd = nil
        }

        private static func describe(_ eligibility: MeetingRetranscription.Eligibility) -> String {
            switch eligibility {
            case .eligible(let sources):
                return "eligible mic=\(sources.microphone?.lastPathComponent ?? "none") system=\(sources.system?.lastPathComponent ?? "none")"
            case .notMeeting: return "not-meeting"
            case .transcribed: return "transcribed"
            case .noMeetingFolder: return "no-meeting-folder"
            case .audioGone: return "audio-gone"
            case .mixOnly: return "mix-only"
            }
        }

        /// After the launch-time recovery, in `--meeting-retranscribe-check` only.
        static func runRetranscribeCheck(engine: VoiceInkEngine) async {
            let arguments = CommandLine.arguments
            guard let index = arguments.firstIndex(of: retranscribeArgument), arguments.indices.contains(index + 1)
            else { return }
            let folder = arguments[index + 1]
            let entries = (try? engine.modelContext.fetch(FetchDescriptor<Transcription>(sortBy: [SortDescriptor(\.timestamp)]))) ?? []
            print("meeting-check: entries \(entries.count)")
            for entry in entries {
                let name = entry.audioFileURL.flatMap(URL.init(string:))?.deletingLastPathComponent().lastPathComponent ?? "none"
                print("meeting-check: eligibility \(name) \(entry.id) \(describe(MeetingRetranscription.eligibility(of: entry)))")
            }
            guard let meeting = entries.first(where: { $0.audioFileURL?.contains("/\(folder)/") == true }) else {
                print("meeting-check: no entry in \(folder)")
                exit(1)
            }
            func printEntry(_ label: String) {
                print("meeting-check: \(label) id \(meeting.id) timestamp \(meeting.timestamp.timeIntervalSince1970) status \(meeting.transcriptionStatus ?? "none") failed-pieces \(meeting.meetingFailedPieces ?? 0) model \(meeting.transcriptionModelName ?? "none") audio \(meeting.audioFileURL ?? "none")")
                print("meeting-check: \(label)-text-begin\n\(meeting.text)\nmeeting-check: \(label)-text-end")
            }
            printEntry("before")
            // What History's Transcribe Meeting does: the mode's model and language now, or no start at all.
            guard let configuration = ModeRuntimeResolver.transcriptionConfiguration(
                transcriptionModelManager: engine.transcriptionModelManager)
            else {
                print("meeting-check: retranscribe refused no-model; running \(MeetingRetranscriber.shared.isRunning)")
                await exitReleasingModels(engine)
            }
            print("meeting-check: retranscribe plan model \(configuration.model.displayName) language \(configuration.language) destination \(MeetingRetranscription.destination(of: configuration.model))")
            retranscribing = meeting.id
            let outcome = await withCheckedContinuation { continuation in
                retranscriptionEnd = continuation
                let refused = MeetingRetranscriber.shared.start(meeting, configuration: configuration)
                print("meeting-check: retranscribe start \(refused ?? "started")")
                if arguments.contains("--meeting-retranscribe-twice") {
                    let again = MeetingRetranscriber.shared.start(meeting, configuration: configuration)
                    print("meeting-check: retranscribe again \(again ?? "same run") running \(MeetingRetranscriber.shared.isRunning)")
                }
                if refused != nil { retranscriptionEnded(meeting.id, .failed(refused!)) }
            }
            print("meeting-check: retranscribe outcome \(outcome)")
            print("meeting-check: requests \(requests.withLock { $0 })")
            print("meeting-check: entries-after \((try? engine.modelContext.fetchCount(FetchDescriptor<Transcription>())) ?? -1)")
            printEntry("after")
            await exitReleasingModels(engine)
        }

        private static var notesFailuresLeft = number(after: "--meeting-fail-notes")
        /// `--meeting-fail-notes N`: the first N notes requests fail.
        static func takeNotesFailure() -> Bool {
            guard notesFailuresLeft > 0 else { return false }
            notesFailuresLeft -= 1
            return true
        }

        /// Meeting pieces load the shared model, kept per Keep model loaded; ggml asserts at exit() while any Metal
        /// buffer is still allocated, so every exit after a transcription releases it first.
        private static func exitReleasingModels(_ engine: VoiceInkEngine?) async -> Never {
            // The check reads the auto-archive folder afterwards; a real quit doesn't wait for it (docs: Known limits).
            await MeetingAutoArchive.shared.drain()
            await engine?.releaseModels()
            fflush(stdout)
            exit(0)
        }

        /// After the launch-time recovery, in `--meeting-edit-check` only.
        static func runEditCheck(engine: VoiceInkEngine) async {
            let arguments = CommandLine.arguments
            guard let index = arguments.firstIndex(of: "--meeting-edit-check"), arguments.indices.contains(index + 2)
            else { return }
            let folder = arguments[index + 1]
            var names: MeetingSpeakerNames = [:]
            for pair in arguments[index + 2].split(separator: ",") {
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                if parts.count == 2 { names[parts[0]] = parts[1] }
            }
            let meetings = (try? engine.modelContext.fetch(FetchDescriptor<Transcription>())) ?? []
            guard let meeting = meetings.first(where: { $0.isMeeting && $0.audioFileURL?.contains("/\(folder)/") == true })
            else {
                print("meeting-check: no saved meeting in \(folder)")
                exit(1)
            }
            print("meeting-check: speakers \(MeetingEdits.segments(of: meeting).map { MeetingEdits.speakers(in: $0).map(\.key) } ?? [])")
            print("meeting-check: transcript-before-begin\n\(meeting.text)\nmeeting-check: transcript-before-end")
            print("meeting-check: rename-error \(MeetingEdits.rename(meeting, names: names, in: engine.modelContext) ?? "none")")
            print("meeting-check: stored-names \(meeting.meetingSpeakerNamesJSON ?? "none")")
            print("meeting-check: transcript-begin\n\(meeting.text)\nmeeting-check: transcript-end")
            print("meeting-check: markdown-begin\n\(MeetingNotes.markdown(for: meeting))\nmeeting-check: markdown-end")
            for run in 0..<number(after: "--meeting-regenerate") {
                let before = meeting.enhancedText
                let problem = await MeetingEdits.regenerateNotes(for: meeting, engine: engine)
                print("meeting-check: regenerate \(run + 1) problem \(problem ?? "none") changed \(meeting.enhancedText != before) kept \(problem == nil || meeting.enhancedText == before)")
            }
            print("meeting-check: notes-begin\n\(meeting.enhancedText ?? "")\nmeeting-check: notes-end")
            print("meeting-check: prompt-begin\n\(meeting.aiRequestSystemMessage ?? "")\nmeeting-check: prompt-end")
            await exitReleasingModels(engine)
        }

        /// After the launch-time resume of speakers, in `--meeting-speakers-resume-check` only.
        static func reportSpeakersResume(_ ids: [UUID], engine: VoiceInkEngine) async {
            guard CommandLine.arguments.contains(speakersResumeArgument) else { return }
            print("meeting-check: speakers-resumed \(ids.count)")
            for id in ids {
                guard let meeting = try? engine.modelContext.fetch(
                    FetchDescriptor<Transcription>(predicate: #Predicate { $0.id == id })).first
                else { continue }
                printSpeakers(meeting)
            }
            await exitReleasingModels(engine)
        }

        /// A saved meeting's speaker status and transcript.
        private static func printSpeakers(_ meeting: Transcription) {
            print("meeting-check: entry \(meeting.id) speaker-status \(meeting.meetingSpeakerStatus ?? "none")")
            print("meeting-check: entry-transcript-begin\n\(meeting.text)\nmeeting-check: entry-transcript-end")
        }

        /// After the launch-time recovery, in `--meeting-recovery-check` only.
        static func reportRecovery(_ results: [MeetingRecorder.MeetingResult], engine: VoiceInkEngine) async {
            guard CommandLine.arguments.contains(recoveryArgument) else { return }
            print("meeting-check: recovered \(results.count)")
            for result in results {
                print("meeting-check: recovered-folder \(result.folder?.lastPathComponent ?? "none")")
                print("meeting-check: audio-only \(result.audioOnly) save-error \(result.saveError ?? "none") failed-pieces \(result.failedPieces)")
                print("meeting-check: transcript-begin\n\(result.transcript)\nmeeting-check: transcript-end")
            }
            await exitReleasingModels(engine)
        }

        static func runIfRequested() {
            let arguments = CommandLine.arguments
            guard let index = arguments.firstIndex(of: argument), arguments.indices.contains(index + 2) else { return }
            let microphone = URL(fileURLWithPath: arguments[index + 1])
            let system = URL(fileURLWithPath: arguments[index + 2])
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(10))
                let started = Date()
                guard let (result, folder) = await MeetingRecorder.shared.processFiles(microphone: microphone, system: system)
                else {
                    print("meeting-check: failed (no transcription model?)")
                    exit(1)
                }
                print("meeting-check: seconds \(Date().timeIntervalSince(started))")
                print("meeting-check: folder \(folder.path)")
                let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.sorted() ?? []
                print("meeting-check: files \(files.joined(separator: " "))")
                print("meeting-check: notes-problem \(result.notesProblem ?? "none")")
                print("meeting-check: failed-pieces \(result.failedPieces)")
                print("meeting-check: failed-marker \(MeetingNotes.failedMarker)")
                print("meeting-check: save-error \(result.saveError ?? "none")")
                print("meeting-check: speakers-skipped \(result.speakersSkipped?.message ?? "none")")
                print("meeting-check: notes-model \(result.notesModel ?? "none")")
                print("meeting-check: transcript-begin\n\(result.transcript)\nmeeting-check: transcript-end")
                print("meeting-check: notes-begin\n\(result.notes ?? "")\nmeeting-check: notes-end")
                print("meeting-check: markdown-bytes \(result.markdown.utf8.count)")
                print("meeting-check: speakers-pending \(result.speakersPending != nil)")
                if result.speakersPending != nil {
                    let id = result.transcriptionID
                    let meeting = try? MeetingRecorder.shared.engine?.modelContext.fetch(
                        FetchDescriptor<Transcription>(predicate: #Predicate { $0.id == id })).first
                    if let meeting { printSpeakers(meeting) }
                    if !CommandLine.arguments.contains("--meeting-exit-before-speakers") {
                        let saved = Date()
                        await MeetingRecorder.shared.speakerJobs[id]?.value
                        print(String(format: "meeting-check: speakers-arrived %.1f s after saving", Date().timeIntervalSince(saved)))
                        if let meeting { printSpeakers(meeting) }
                        if case .done(let shown) = MeetingRecorder.shared.phase {
                            print("meeting-check: panel pending \(shown.speakersPending != nil) labeled-later \(shown.speakersLabeledLater)")
                        }
                    }
                }
                await exitReleasingModels(MeetingRecorder.shared.engine)
            }
        }
    }
#endif
