#if DEBUG
    import AppKit

    /// `make offline-check` (scripts/offline-check.sh): launched with `--dictate-file <wav>`, the app waits for
    /// launch-time work to settle, runs one dictation of that file through the normal pipeline, prints the result
    /// between `offline-check:` marker lines (Unix times, for matching against the script's socket log) and quits.
    /// The general pasteboard is put back afterwards, since delivery copies the text there.
    @MainActor
    enum OfflineCheck {
        static let argument = "--dictate-file"
        static var isRequested: Bool { CommandLine.arguments.contains(argument) }

        static func runIfRequested(engine: VoiceInkEngine) {
            let arguments = CommandLine.arguments
            guard let index = arguments.firstIndex(of: argument), arguments.indices.contains(index + 1) else { return }
            let file = URL(fileURLWithPath: arguments[index + 1])
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(10))
                let pasteboard = NSPasteboard.general
                let saved = pasteboard.pasteboardItems?.map { item in
                    item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
                } ?? []
                print("offline-check: start \(Date().timeIntervalSince1970)")
                let transcription = await engine.dictateFile(file)
                print("offline-check: end \(Date().timeIntervalSince1970)")
                print("offline-check: model \(transcription.transcriptionModelName ?? "none")")
                print("offline-check: enhanced \(transcription.enhancedText != nil)")
                print("offline-check: seconds \(transcription.transcriptionDuration ?? 0)")
                print("offline-check: text \(transcription.text)")
                pasteboard.clearContents()
                pasteboard.writeObjects(saved.map { pairs in
                    let item = NSPasteboardItem()
                    pairs.forEach { item.setData($0.1, forType: $0.0) }
                    return item
                })
                try? await Task.sleep(for: .seconds(5))
                print("offline-check: quit \(Date().timeIntervalSince1970)")
                fflush(stdout)
                exit(0)  // NSApp.terminate is turned into "hide to the menu bar"
            }
        }
    }
#endif
