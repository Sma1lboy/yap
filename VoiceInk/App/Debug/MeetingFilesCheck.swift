#if DEBUG
    import AppKit

    /// `scripts/meeting-files-check.sh`: launched with `--meeting-files <mic.wav> <system.wav>` (16 kHz mono PCM16),
    /// the app runs both files through meeting recording's chunking, transcription (the mode's model), notes and
    /// saving, prints the result between `meeting-check:` marker lines and quits.
    /// `--meeting-fail-pieces N` makes the first N pieces fail; `--meeting-fail-save` makes saving the entry fail.
    /// `--meeting-recovery-check`: waits for the launch-time recovery of interrupted meetings, prints it, quits.
    @MainActor
    enum MeetingFilesCheck {
        static let argument = "--meeting-files"
        static let recoveryArgument = "--meeting-recovery-check"
        static var isRequested: Bool {
            CommandLine.arguments.contains(argument) || CommandLine.arguments.contains(recoveryArgument)
        }
        static var failPieces: Int {
            let arguments = CommandLine.arguments
            guard let index = arguments.firstIndex(of: "--meeting-fail-pieces"), arguments.indices.contains(index + 1)
            else { return 0 }
            return Int(arguments[index + 1]) ?? 0
        }
        nonisolated static var failsSave: Bool { CommandLine.arguments.contains("--meeting-fail-save") }

        /// After the launch-time recovery, in `--meeting-recovery-check` only.
        static func reportRecovery(_ results: [MeetingRecorder.MeetingResult]) {
            guard CommandLine.arguments.contains(recoveryArgument) else { return }
            print("meeting-check: recovered \(results.count)")
            for result in results {
                print("meeting-check: recovered-folder \(result.folder?.lastPathComponent ?? "none")")
                print("meeting-check: audio-only \(result.audioOnly) save-error \(result.saveError ?? "none") failed-pieces \(result.failedPieces)")
                print("meeting-check: transcript-begin\n\(result.transcript)\nmeeting-check: transcript-end")
            }
            fflush(stdout)
            exit(0)
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
                fflush(stdout)
                exit(0)
            }
        }
    }
#endif
