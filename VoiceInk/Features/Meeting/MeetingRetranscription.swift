import Foundation
import SwiftData
import os

/// Transcribe Meeting in History: a meeting saved with its audio only (recovery found no transcription model in
/// the mode, or its earlier try was cut off) goes through the meeting steps again, from its own mic.wav and
/// system.wav, with the model and language the mode has when the user starts it. Its History entry then gets the
/// timestamped transcript, the speakers and the notes, keeping its id, its date and its recordings.
///
/// The work happens in a folder of its own (`MeetingRetranscription/<entry id>/` next to `Recordings`), so the
/// meeting's folder is only read until the very end: no `*.orig`, nothing moved. Only a finished run changes
/// anything, `segments.json` and the entry together; a cancel, a failure or a quit leave the entry and its files as
/// they were. That folder isn't in `Recordings/meetings/`, so launch-time recovery never takes it for an
/// interrupted meeting; what a quit leaves there is removed at the next launch.
enum MeetingRetranscription {
    /// Whether a History entry can be transcribed as a meeting, read from the entry and the files only.
    enum Eligibility: Equatable {
        case eligible(Sources)
        /// A dictation or an imported file.
        case notMeeting
        /// Its transcript is there already: only an entry saved with its audio only (status `failed`, which
        /// nothing but `saveAudioOnly` gives a meeting) is transcribed this way.
        case transcribed
        /// Its audio isn't a file in a meeting's folder (`Recordings/meetings/<id>/`), or isn't a path at all.
        case noMeetingFolder
        /// The folder or every recording in it is gone (audio retention, deleted by hand).
        case audioGone
        /// Only the mix is left: without the two channels nobody can be told apart as "Me" or "Others".
        case mixOnly
    }

    /// The meeting's own recordings: "Me" from the microphone file, "Others" from the system audio file. One of
    /// them may be missing; its speaker then has no lines.
    struct Sources: Equatable {
        let folder: URL
        let microphone: URL?
        let system: URL?
    }

    static func eligibility(of transcription: Transcription) -> Eligibility {
        eligibility(kind: transcription.kind, status: transcription.transcriptionStatus, audioFileURL: transcription.audioFileURL)
    }

    static func eligibility(kind: String?, status: String?, audioFileURL: String?) -> Eligibility {
        guard kind == Transcription.meetingKind else { return .notMeeting }
        guard status == TranscriptionStatus.failed.rawValue else { return .transcribed }
        guard let string = audioFileURL, let mix = URL(string: string), mix.isFileURL, Transcription.isMeetingAudio(mix)
        else { return .noMeetingFolder }
        let folder = mix.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue
        else { return .audioGone }
        // A channel is its file, or the original an earlier recovery moved aside and never put back.
        func channel(_ name: String) -> URL? {
            [name, name + ".orig"].map { folder.appendingPathComponent($0) }.first(where: hasAudio)
        }
        let sources = Sources(folder: folder, microphone: channel("mic.wav"), system: channel("system.wav"))
        if sources.microphone != nil || sources.system != nil { return .eligible(sources) }
        return hasAudio(mix) ? .mixOnly : .audioGone
    }

    /// More than a WAV header.
    private static func hasAudio(_ url: URL) -> Bool {
        ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 44
    }

    /// Why an entry can't be transcribed, as History says it; nil when it can, or when it isn't one History offers
    /// it for (a dictation, a meeting with its transcript).
    static func reason(for eligibility: Eligibility) -> String? {
        switch eligibility {
        case .eligible, .notMeeting, .transcribed: return nil
        case .noMeetingFolder:
            return String(localized: "Its audio isn't in a meeting folder, so it can't be transcribed as a meeting.")
        case .audioGone:
            return String(localized: "Its recordings are gone (deleted, or removed by the audio retention setting), so it can't be transcribed.")
        case .mixOnly:
            return String(localized: "Only the mixed audio is left. Without the separate microphone and system audio recordings, Yap can't tell you from the others, so it doesn't transcribe it as a meeting.")
        }
    }

    /// Where the audio goes with the mode's model, in the words of Yap's privacy note ("Local models keep everything
    /// on this Mac. With your own API key, audio and text go only to the provider you choose. With Yap Cloud, they
    /// pass through Yap's server on the way to the model provider"), in the meeting's 20–28 s pieces.
    static func destination(of model: any TranscriptionModel) -> String {
        switch model.provider {
        case .whisper, .fluidAudio, .transcribeCpp, .nativeApple:
            return String(localized: "A local model: the recording stays on this Mac.")
        case .yapCloud:
            return String(localized: "Yap Cloud: the recording, in 20–28 s parts, passes through Yap's server on the way to the model provider, and is billed to your Yap Cloud balance.")
        case .custom:
            return String(format: String(localized: "The recording, in 20–28 s parts, goes only to the endpoint you set up for %@."), model.displayName)
        default:
            return String(format: String(localized: "With your own API key: the recording, in 20–28 s parts, goes only to %@."), model.provider.rawValue)
        }
    }

    /// Where a run works: next to `Recordings`, never inside `Recordings/meetings/`.
    static func workRoot(recordings: URL) -> URL {
        recordings.deletingLastPathComponent().appendingPathComponent("MeetingRetranscription", isDirectory: true)
    }
}

/// Runs Transcribe Meeting, one meeting at a time, and keeps each entry's last result for History to show.
@MainActor
final class MeetingRetranscriber: ObservableObject {
    static let shared = MeetingRetranscriber()

    enum State: Equatable {
        /// What it's doing now ("Transcribing…", "Telling speakers apart…", "Writing notes…").
        case running(String)
        case canceling
        /// Saved; `failedPieces` pieces couldn't be transcribed (each a marked line, as in any meeting).
        case done(failedPieces: Int)
        /// Nothing was changed; why.
        case failed(String)
        case canceled

        var isActive: Bool {
            switch self {
            case .running, .canceling: return true
            default: return false
            }
        }
    }

    @Published private(set) var states: [UUID: State] = [:]
    private var job: (id: UUID, task: Task<Void, Never>, transcriber: MeetingRecorder.Transcriber)?
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MeetingRetranscription")

    var isRunning: Bool { job != nil }

    /// Why no meeting can be transcribed right now; nil when one can. One at a time, and not while a meeting is
    /// recorded, finished or recovered: those would take turns with it on the same model.
    func busyReason() -> String? {
        if job != nil {
            return String(localized: "Another meeting is being transcribed. Try again when it's done.")
        }
        if !MeetingRecorder.shared.activeFolders.isEmpty {
            return String(localized: "A meeting is being recorded or recovered. Try again when it's done.")
        }
        return nil
    }

    /// Transcribe Meeting in History. `configuration` is the mode's model and language the user was shown; the run
    /// keeps them to the end, whatever the mode is changed to meanwhile. Returns why it didn't start.
    @discardableResult
    func start(_ transcription: Transcription, configuration: TranscriptionRuntimeConfiguration) -> String? {
        let id = transcription.id
        if states[id]?.isActive == true { return nil }  // the same meeting again: the run in progress is it
        if let busy = busyReason() { return busy }
        guard case .eligible(let sources) = MeetingRetranscription.eligibility(of: transcription) else {
            return MeetingRetranscription.reason(for: MeetingRetranscription.eligibility(of: transcription))
                ?? String(localized: "This meeting already has its transcript.")
        }
        guard let engine = MeetingRecorder.shared.engine, let audioFileURL = transcription.audioFileURL else {
            return String(localized: "Yap isn't ready yet. Try again in a moment.")
        }
        let work = MeetingRetranscription.workRoot(recordings: engine.recordingsDirectory)
            .appendingPathComponent(id.uuidString, isDirectory: true)
        let session: MeetingRecorder.Session
        do {
            try? FileManager.default.removeItem(at: work)
            try FileManager.default.createDirectory(at: work.appendingPathComponent("pieces"), withIntermediateDirectories: true)
            session = try MeetingRecorder.Session(
                folder: work, started: transcription.timestamp,
                transcriber: MeetingRecorder.Transcriber(engine: engine, configuration: configuration))
        } catch {
            try? FileManager.default.removeItem(at: work)
            return error.localizedDescription
        }
        let names = transcription.meetingSpeakerNames
        let transcribing = String(localized: "Transcribing the meeting…")
        states[id] = .running(transcribing)
        logger.notice("Transcribing meeting \(id, privacy: .public) with \(configuration.model.displayName, privacy: .public)")

        let task = Task { @MainActor [weak self] in
            // Read once, whole, from the meeting's own files; nothing is written next to them.
            await Task.detached {
                if let microphone = sources.microphone { session.feed(file: microphone, as: .me) }
                if let system = sources.system { session.feed(file: system, as: .others) }
            }.value
            // Waits for the speakers: a meeting saved without them would have them written into the work folder.
            let processed = await MeetingRecorder.shared.processMeeting(
                session, engine: engine, speakerWait: .infinity, names: names, notesMode: configuration.mode,
                stoppable: true, transcribing: transcribing
            ) { message in
                if self?.states[id]?.isActive == true, self?.states[id] != .canceling { self?.states[id] = .running(message) }
            }
            guard let self else { return }
            let outcome: State
            if let processed, !Task.isCancelled {
                processed.speakerJob?.cancel()  // never set with an endless wait
                if let error = Self.commit(
                    processed, duration: session.duration, configuration: configuration, to: id,
                    audioFileURL: audioFileURL, work: work, in: engine.modelContext)
                {
                    outcome = .failed(error)
                } else {
                    outcome = .done(failedPieces: processed.failures)
                }
            } else {
                outcome = .canceled
            }
            try? FileManager.default.removeItem(at: work)
            states[id] = outcome
            job = nil
            logger.notice("Meeting \(id, privacy: .public) transcription ended: \(String(describing: outcome), privacy: .public)")
            #if DEBUG
                MeetingFilesCheck.retranscriptionEnded(id, outcome)
            #endif
        }
        job = (id, task, session.transcriber)
        return nil
    }

    /// Cancel in History: the piece being transcribed (or the speakers' step, or the notes request) is the last;
    /// nothing is saved.
    func cancel(_ id: UUID) {
        guard let job, job.id == id else { return }
        states[id] = .canceling
        job.transcriber.cancel()
        job.task.cancel()
    }

    /// Puts the new transcript into the entry: `segments.json` beside its recordings first (written whole,
    /// atomically), then the entry in one save, which hands it to saving to a folder automatically. If the save
    /// fails, the entry's fields and `segments.json` are put back as they were, and nothing else in the shared
    /// context is rolled back. The id, the date, the audio and any speaker names stay.
    private static func commit(
        _ processed: MeetingRecorder.Processed, duration: TimeInterval, configuration: TranscriptionRuntimeConfiguration,
        to id: UUID, audioFileURL: String, work: URL, in context: ModelContext
    ) -> String? {
        guard let transcription = try? context.fetch(FetchDescriptor<Transcription>(predicate: #Predicate { $0.id == id })).first
        else { return String(localized: "The meeting was deleted from History while it was being transcribed.") }
        guard transcription.audioFileURL == audioFileURL,
            case .eligible(let sources) = MeetingRetranscription.eligibility(of: transcription)
        else { return String(localized: "The meeting changed while it was being transcribed, so nothing was saved.") }

        let segmentsURL = sources.folder.appendingPathComponent("segments.json")
        let oldSegments = try? Data(contentsOf: segmentsURL)
        do {
            try JSONEncoder().encode(processed.segments).write(to: segmentsURL, options: .atomic)
        } catch {
            return error.localizedDescription
        }
        // The History player's mix: made with the entry when it was saved; only if it's gone is the new one put there.
        var placedMix: URL? = nil
        if let mix = URL(string: audioFileURL), !FileManager.default.fileExists(atPath: mix.path),
            (try? FileManager.default.copyItem(at: work.appendingPathComponent("mix.wav"), to: mix)) != nil
        {
            placedMix = mix
        }

        let old = (
            transcription.text, transcription.duration, transcription.enhancedText, transcription.transcriptionModelName,
            transcription.aiEnhancementModelName, transcription.promptName, transcription.enhancementDuration,
            transcription.modeName, transcription.modeEmoji, transcription.transcriptionStatus,
            transcription.meetingFailedPieces, transcription.meetingSpeakerStatus)
        let transcript = MeetingNotes.transcript(processed.segments, names: transcription.meetingSpeakerNames)
        let summary = processed.summary
        transcription.text = transcript.isEmpty ? String(localized: "(Nothing was said in this meeting.)") : transcript
        transcription.duration = duration
        transcription.enhancedText = summary.notes
        transcription.transcriptionModelName = configuration.model.displayName
        transcription.aiEnhancementModelName = summary.modelName
        transcription.promptName = summary.notes == nil ? nil : MeetingNotes.promptTitle
        transcription.enhancementDuration = summary.duration
        transcription.modeName = configuration.metadata.name
        transcription.modeEmoji = configuration.metadata.emoji
        transcription.transcriptionStatus = TranscriptionStatus.completed.rawValue
        transcription.meetingFailedPieces = processed.failures > 0 ? processed.failures : nil
        transcription.meetingSpeakerStatus = nil
        do {
            try MeetingEdits.save(transcription, in: context)
            return nil
        } catch {
            (transcription.text, transcription.duration, transcription.enhancedText, transcription.transcriptionModelName,
                transcription.aiEnhancementModelName, transcription.promptName, transcription.enhancementDuration,
                transcription.modeName, transcription.modeEmoji, transcription.transcriptionStatus,
                transcription.meetingFailedPieces, transcription.meetingSpeakerStatus) = old
            if let oldSegments {
                try? oldSegments.write(to: segmentsURL, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: segmentsURL)
            }
            if let placedMix { try? FileManager.default.removeItem(at: placedMix) }
            return error.localizedDescription
        }
    }

    /// At launch: work folders a quit left behind. Nothing in them is the only copy of anything. Skipped if a run
    /// was already started from History this launch (its folder is in use).
    static func removeLeftovers(recordings: URL) {
        guard !shared.isRunning else { return }
        try? FileManager.default.removeItem(at: MeetingRetranscription.workRoot(recordings: recordings))
    }

    #if DEBUG
        /// make ui-snapshots: an entry's state without running anything.
        func setSnapshotState(_ state: State?, for id: UUID) { states[id] = state }
    #endif
}

#if DEBUG
    extension MeetingRetranscription {
        /// On real files in a temporary folder: which entries can be transcribed, and from what.
        static func selfCheck() {
            let fileManager = FileManager.default
            let root = fileManager.temporaryDirectory.appendingPathComponent("yap-retranscribe-check-\(UUID().uuidString)")
            defer { try? fileManager.removeItem(at: root) }
            let meetings = root.appendingPathComponent("Recordings/meetings", isDirectory: true)
            let audio = Data(count: 44) + Data(repeating: 1, count: 3_200)
            func folder(_ files: [String: Data]) -> String {
                let folder = meetings.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
                for (name, data) in files { try? data.write(to: folder.appendingPathComponent(name)) }
                return folder.appendingPathComponent("mix.wav").absoluteString
            }
            let meeting = Transcription.meetingKind, failed = TranscriptionStatus.failed.rawValue
            func check(_ kind: String?, _ status: String?, _ url: String?) -> Eligibility {
                eligibility(kind: kind, status: status, audioFileURL: url)
            }

            let both = folder(["mic.wav": audio, "system.wav": audio, "mix.wav": audio])
            guard case .eligible(let sources) = check(meeting, failed, both) else { return assertionFailure("both channels") }
            assert(sources.microphone?.lastPathComponent == "mic.wav" && sources.system?.lastPathComponent == "system.wav")
            assert(sources.folder.absoluteString + "mix.wav" == both)
            // A dictation, and a meeting with its transcript (a recovered one, or one where nothing was said).
            assert(check(nil, failed, both) == .notMeeting)
            assert(check(meeting, TranscriptionStatus.completed.rawValue, both) == .transcribed)
            assert(check(meeting, nil, both) == .transcribed)
            // Only the microphone: "Me" alone; the system audio as headers only counts as missing.
            guard case .eligible(let micOnly) = check(meeting, failed, folder(["mic.wav": audio, "system.wav": Data(count: 44)]))
            else { return assertionFailure("microphone only") }
            assert(micOnly.microphone != nil && micOnly.system == nil)
            // An original a cut-off recovery left aside is read where it is.
            guard case .eligible(let aside) = check(meeting, failed, folder(["mic.wav.orig": audio, "system.wav": audio]))
            else { return assertionFailure("orig") }
            assert(aside.microphone?.lastPathComponent == "mic.wav.orig")
            // Only the mix, nothing, the folder gone, a path that isn't a meeting folder or a file URL.
            assert(check(meeting, failed, folder(["mix.wav": audio])) == .mixOnly)
            assert(check(meeting, failed, folder(["mix.wav": Data(count: 44)])) == .audioGone)
            assert(check(meeting, failed, meetings.appendingPathComponent("gone/mix.wav").absoluteString) == .audioGone)
            assert(check(meeting, failed, root.appendingPathComponent("Recordings/a.wav").absoluteString) == .noMeetingFolder)
            assert(check(meeting, failed, "not a url") == .noMeetingFolder)
            assert(check(meeting, failed, "https://example.com/meetings/x/mix.wav") == .noMeetingFolder)
            assert(check(meeting, failed, nil) == .noMeetingFolder)
            assert(reason(for: .eligible(sources)) == nil && reason(for: .transcribed) == nil)
            assert([Eligibility.noMeetingFolder, .audioGone, .mixOnly].allSatisfy { reason(for: $0) != nil })
            // The work folder is never one recovery scans.
            let recordings = root.appendingPathComponent("Recordings", isDirectory: true)
            let work = workRoot(recordings: recordings).appendingPathComponent("x/mix.wav")
            assert(!Transcription.isMeetingAudio(work) && !work.path.hasPrefix(recordings.path + "/"))
        }
    }
#endif
