#if DEBUG
    import AppKit

    /// `scripts/meeting-files-check.sh`: launched with `--meeting-files <mic.wav> <system.wav>` (16 kHz mono PCM16),
    /// the app runs both files through meeting recording's chunking, transcription (the mode's model), notes and
    /// saving, prints the result between `meeting-check:` marker lines and quits.
    @MainActor
    enum MeetingFilesCheck {
        static let argument = "--meeting-files"
        static var isRequested: Bool { CommandLine.arguments.contains(argument) }

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
                print("meeting-check: transcript-begin\n\(result.transcript)\nmeeting-check: transcript-end")
                print("meeting-check: notes-begin\n\(result.notes ?? "")\nmeeting-check: notes-end")
                print("meeting-check: markdown-bytes \(result.markdown.utf8.count)")
                fflush(stdout)
                exit(0)
            }
        }
    }
#endif
