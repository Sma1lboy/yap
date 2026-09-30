import AppKit
import SwiftData
import os

/// A meeting the app quit or crashed in the middle of: its folder (Recordings/meetings/<id>/) holds mic.wav and
/// system.wav but no History entry refers to it, because the entry is only saved once the meeting ends (or saving
/// it failed). At launch each one goes through the same finishing steps as a meeting that ended normally, in the
/// background and without the panel, which stays free for a new meeting. Without a transcription model, or when
/// the previous launch's attempt was cut off, it's saved with its audio only and the reason.
extension MeetingRecorder {
    private static let recoveryAttemptedKey = "RecoveryAttemptedMeetings"
    private static let channelFiles = ["mic.wav", "system.wav"]
    private static let recoveryLogger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MeetingRecovery")

    /// A folder is interrupted when no History entry refers to it and no meeting is being recorded, finished or
    /// recovered in it right now.
    static func isInterrupted(_ folder: String, saved: Set<String>, active: Set<String>) -> Bool {
        !saved.contains(folder) && !active.contains(folder)
    }

    /// The folder names History entries refer to: a meeting's `audioFileURL` is `…/meetings/<id>/mix.wav`.
    static func meetingFolders(of audioFileURLs: [String?]) -> Set<String> {
        Set(audioFileURLs.compactMap { $0.flatMap(URL.init(string:)) }.compactMap { url in
            let folder = url.deletingLastPathComponent()
            return folder.deletingLastPathComponent().lastPathComponent == "meetings" ? folder.lastPathComponent : nil
        })
    }

    /// At launch: recovers every interrupted meeting, oldest first, one at a time. Returns what was saved.
    @discardableResult
    func recoverInterruptedMeetings(announceStart: Bool = true) async -> [MeetingResult] {
        guard let engine else { return [] }
        let root = engine.recordingsDirectory.appendingPathComponent("meetings", isDirectory: true)
        var descriptor = FetchDescriptor<Transcription>()
        descriptor.propertiesToFetch = [\.audioFileURL]
        let saved = Self.meetingFolders(of: ((try? engine.modelContext.fetch(descriptor)) ?? []).map(\.audioFileURL))
        let folders = ((try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey])) ?? [])
            .filter { folder in
                (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                    && Self.isInterrupted(folder.lastPathComponent, saved: saved, active: activeFolders)
                    && Self.hasAudio(folder)
            }
            .sorted { Self.created($0) < Self.created($1) }
        guard !folders.isEmpty else { return [] }

        if announceStart {
            NotificationManager.shared.showNotification(
                title: String(localized: "Yap quit during a meeting. It's being recovered in the background and will be in History."),
                type: .info, duration: 8)
        }
        var results: [MeetingResult] = []
        for folder in folders {
            let result = await recover(folder, engine: engine)
            results.append(result)
            announce(result, started: Self.created(folder))
        }
        return results
    }

    private func recover(_ folder: URL, engine: VoiceInkEngine) async -> MeetingResult {
        let name = folder.lastPathComponent
        activeFolders.insert(name)
        defer { activeFolders.remove(name) }
        let started = Self.created(folder)
        Self.restoreOriginals(in: folder)

        // Marked before the work starts: if it crashes the app, the next launch saves the audio only.
        var attempted = Set(UserDefaults.standard.stringArray(forKey: Self.recoveryAttemptedKey) ?? [])
        let triedBefore = attempted.contains(name)
        attempted.insert(name)
        UserDefaults.standard.set(Array(attempted), forKey: Self.recoveryAttemptedKey)

        if triedBefore {
            return saveAudioOnly(folder, started: started, engine: engine, reason: String(localized: "Recovering it stopped partway last time."))
        }
        guard let configuration = ModeRuntimeResolver.transcriptionConfiguration(
            transcriptionModelManager: engine.transcriptionModelManager)
        else {
            return saveAudioOnly(folder, started: started, engine: engine, reason: String(localized: "No transcription model is chosen in the mode."))
        }

        // The session writes mic.wav and system.wav afresh, so the originals are read from beside them
        // (`*.orig`) and removed only once the entry is saved.
        let fileManager = FileManager.default
        for file in Self.channelFiles {
            try? fileManager.moveItem(at: folder.appendingPathComponent(file), to: folder.appendingPathComponent(file + ".orig"))
        }
        try? fileManager.createDirectory(at: folder.appendingPathComponent("pieces"), withIntermediateDirectories: true)
        guard let session = try? Session(
            folder: folder, started: started, transcriber: Transcriber(engine: engine, configuration: configuration))
        else {
            Self.restoreOriginals(in: folder)
            return saveAudioOnly(folder, started: started, engine: engine, reason: String(localized: "Its folder couldn't be written to."))
        }
        session.feed(file: folder.appendingPathComponent("mic.wav.orig"), as: .me)
        session.feed(file: folder.appendingPathComponent("system.wav.orig"), as: .others)
        let result = await finishMeeting(session, engine: engine, timestamp: started) { _ in }
        if result.saveError == nil {
            for file in Self.channelFiles { try? fileManager.removeItem(at: folder.appendingPathComponent(file + ".orig")) }
            forgetAttempt(name)
        }
        Self.recoveryLogger.notice("Recovered meeting \(name, privacy: .public): \(result.failedPieces, privacy: .public) failed pieces")
        return result
    }

    /// Without transcribing: the mix for the History player and an entry that says why there's no transcript.
    private func saveAudioOnly(_ folder: URL, started: Date, engine: VoiceInkEngine, reason: String) -> MeetingResult {
        let channels = Self.channelFiles.map { folder.appendingPathComponent($0) }
        let mix = folder.appendingPathComponent("mix.wav")
        MeetingMixer.mix(channels, into: mix)
        let bytes = channels.compactMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }.max() ?? 44
        let text = String(format: String(localized: "Yap quit during this meeting, and it couldn't be transcribed afterwards. %@ The audio is saved with this entry."), reason)
        let transcription = Transcription(
            text: text, duration: TimeInterval(max(0, bytes - 44) / 2) / MeetingChunker.sampleRate,
            audioFileURL: mix.absoluteString, transcriptionStatus: .failed)
        transcription.kind = Transcription.meetingKind
        transcription.timestamp = started
        let saveError = save(transcription, engine: engine)
        if saveError == nil { forgetAttempt(folder.lastPathComponent) }
        Self.recoveryLogger.notice("Saved meeting \(folder.lastPathComponent, privacy: .public) with audio only: \(reason, privacy: .public)")
        return MeetingResult(
            transcriptionID: transcription.id, notes: nil, transcript: text, notesProblem: nil, markdown: "",
            notesModel: nil, folder: folder, saveError: saveError, audioOnly: true)
    }

    private func announce(_ result: MeetingResult, started: Date) {
        let when = started.formatted(date: .abbreviated, time: .shortened)
        let openHistory: (label: String, action: () -> Void) = (String(localized: "Open History"), { HistoryNavigator.open() })
        if let error = result.saveError, let folder = result.folder {
            NotificationManager.shared.showNotification(
                title: String(format: String(localized: "The meeting from %@ couldn't be saved to History: %@ Its audio is still in its folder."), when, error),
                type: .error, duration: 30,
                actionButton: (String(localized: "Show in Finder"), { NSWorkspace.shared.activateFileViewerSelecting([folder]) }))
        } else if result.audioOnly {
            NotificationManager.shared.showNotification(
                title: String(format: String(localized: "The meeting from %@ is in History with its audio only; it couldn't be transcribed."), when),
                type: .warning, duration: 12, actionButton: openHistory)
        } else {
            NotificationManager.shared.showNotification(
                title: String(format: String(localized: "The interrupted meeting from %@ is recovered and in History."), when),
                type: .success, duration: 12, actionButton: openHistory)
        }
    }

    private func forgetAttempt(_ name: String) {
        let attempted = (UserDefaults.standard.stringArray(forKey: Self.recoveryAttemptedKey) ?? []).filter { $0 != name }
        UserDefaults.standard.set(attempted, forKey: Self.recoveryAttemptedKey)
    }

    /// Puts back originals an earlier attempt moved aside, and fixes headers a crash left unfinished, so the
    /// files open in any player.
    private static func restoreOriginals(in folder: URL) {
        let fileManager = FileManager.default
        for file in channelFiles {
            let url = folder.appendingPathComponent(file), original = folder.appendingPathComponent(file + ".orig")
            if fileManager.fileExists(atPath: original.path) {
                try? fileManager.removeItem(at: url)
                try? fileManager.moveItem(at: original, to: url)
            }
            RecordingRecovery.repairWAVHeader(url)
        }
    }

    private static func hasAudio(_ folder: URL) -> Bool {
        channelFiles.flatMap { [$0, $0 + ".orig"] }.contains { file in
            ((try? folder.appendingPathComponent(file).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 44
        }
    }

    /// When the meeting started: its folder is created at the start of recording.
    private static func created(_ folder: URL) -> Date {
        (try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
    }
}

#if DEBUG
    extension MeetingRecorder {
        static func recoverySelfCheck() {
            // Saved meetings are known by their folder; a dictation's WAV isn't a meeting folder.
            let saved = meetingFolders(of: [
                "file:///x/Recordings/meetings/A/mix.wav", "file:///x/Recordings/d.wav", nil, "not a url",
            ])
            assert(saved == ["A"])
            assert(!isInterrupted("A", saved: saved, active: []))  // has a History entry
            assert(!isInterrupted("B", saved: saved, active: ["B"]))  // being recorded or finished right now
            assert(isInterrupted("B", saved: saved, active: ["C"]))
        }
    }
#endif
