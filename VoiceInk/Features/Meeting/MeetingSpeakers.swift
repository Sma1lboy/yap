import Foundation
import SwiftData
import os

/// Telling a meeting's remote speakers apart can take longer than anyone wants to wait once they click ✓ (see
/// docs/meeting-recording.md for the measured rate). The meeting is finished as usual, and if the speakers
/// aren't ready after `speakerWait` seconds, it's saved with plain "Others" (`meetingSpeakerStatus` "pending") and
/// the result is shown; the same diarization keeps running and, when it's done, the saved meeting's transcript and
/// segments.json get "Others 1", "Others 2". The notes aren't rewritten; the panel suggests Regenerate Notes.
/// A meeting still pending when the app quits is picked up at the next launch.
extension MeetingRecorder {
    typealias SpeakerJob = Task<Result<[SpeakerTurn], Error>, Never>

    private static let speakersLogger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MeetingSpeakers")

    /// How long finishing a meeting waits for the speakers before saving it without them. Recovery doesn't use it:
    /// it runs in the background anyway and waits for them.
    static var speakerWait: TimeInterval {
        #if DEBUG
            if let wait = MeetingFilesCheck.speakerWait { return wait }
        #endif
        return 10
    }

    /// Starts diarizing a meeting folder's system.wav. Its progress ("Downloading the speaker model… n%", then
    /// "Telling speakers apart…") goes to `speakerProgress[folder name]`, wherever that points at the time.
    func speakerTurns(folder: URL, duration: TimeInterval, engine: VoiceInkEngine) -> SpeakerJob {
        let name = folder.lastPathComponent
        let system = folder.appendingPathComponent("system.wav")
        let directory = engine.recordingsDirectory.deletingLastPathComponent()
            .appendingPathComponent("SpeakerModels", isDirectory: true)
        return Task { [weak self] in
            let started = Date()
            do {
                let turns = try await MeetingDiarizer.turns(of: system, duration: duration, directory: directory) { fraction in
                    Task { @MainActor in
                        self?.speakerProgress[name]?(
                            fraction < 1
                                ? String(format: String(localized: "Downloading the speaker model… %lld%%"), Int(fraction * 100))
                                : String(localized: "Telling speakers apart…"))
                    }
                }
                let elapsed = Date().timeIntervalSince(started)
                Self.speakersLogger.notice("Diarized \(Int(duration), privacy: .public) s in \(elapsed, privacy: .public) s: \(Set(turns.map(\.id)).count, privacy: .public) speakers")
                #if DEBUG
                    if MeetingFilesCheck.isRequested {
                        print(String(format: "meeting-check: diarized in %.1f s; system audio %d s", elapsed, Int(duration)))
                    }
                #endif
                return .success(turns)
            } catch {
                Self.speakersLogger.error("Diarization failed: \(error.localizedDescription, privacy: .public)")
                return .failure(error)
            }
        }
    }

    /// The job's result, or nil if it isn't done within `seconds` (the job keeps running either way).
    static func value<T: Sendable>(of job: Task<T, Never>, within seconds: TimeInterval) async -> T? {
        guard seconds.isFinite else { return await job.value }
        return await withCheckedContinuation { continuation in
            let done = OSAllocatedUnfairLock(initialState: false)
            @Sendable func finish(_ value: T?) {
                if done.withLock({ let was = $0; $0 = true; return !was }) { continuation.resume(returning: value) }
            }
            Task { finish(await job.value) }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                finish(nil)
            }
        }
    }

    /// The segments with "Others n" from the diarizer's turns, and why they stay plain "Others" if they do.
    static func labeled(
        _ segments: [MeetingSegment], _ result: Result<[SpeakerTurn], Error>
    ) -> ([MeetingSegment], SpeakerSplitSkip?) {
        switch result {
        case .success(let turns):
            let labeled = SpeakerLabels.assign(segments, turns: turns)
            return (labeled, labeled == segments ? .oneSpeaker : nil)
        case .failure(let error):
            return (segments, SpeakerSplitSkip(error: error))
        }
    }

    /// After the meeting was saved as "pending": waits for the job and puts its speakers into the entry.
    @discardableResult
    func continueSpeakers(_ job: SpeakerJob, id: UUID, folder: URL) -> Task<Void, Never> {
        let name = folder.lastPathComponent
        speakerProgress[name] = { [weak self] message in self?.updateResult(id) { $0.speakersPending = message } }
        let task = Task { [weak self] in
            let result = await job.value
            guard let self else { return }
            applySpeakers(result, to: id)
            speakerProgress[name] = nil
            speakerJobs[id] = nil
        }
        speakerJobs[id] = task
        return task
    }

    /// Puts the speakers found after saving into the meeting: segments.json first (written whole, atomically),
    /// then the transcript and the status in one save. If that save fails, segments.json is put back, so the file
    /// and the entry never disagree and the next launch tries again. A meeting deleted meanwhile is left alone; one
    /// whose folder is gone is marked as failed.
    func applySpeakers(_ result: Result<[SpeakerTurn], Error>, to id: UUID) {
        guard let engine, let transcription = try? engine.modelContext.fetch(
            FetchDescriptor<Transcription>(predicate: #Predicate { $0.id == id })).first
        else { return }
        guard let segments = MeetingEdits.segments(of: transcription), let url = MeetingEdits.segmentsURL(of: transcription)
        else {
            transcription.meetingSpeakerStatus = SpeakerSplitSkip.failed.rawValue
            try? engine.modelContext.save()
            updateResult(id) { $0.speakersPending = nil; $0.speakersSkipped = .failed }
            return
        }
        let (labeled, skip) = Self.labeled(segments, result)
        let old = (text: transcription.text, status: transcription.meetingSpeakerStatus, file: try? Data(contentsOf: url))
        if labeled != segments {
            do {
                try JSONEncoder().encode(labeled).write(to: url, options: .atomic)
                transcription.text = MeetingNotes.transcript(labeled, names: transcription.meetingSpeakerNames)
            } catch {
                Self.speakersLogger.error("Speakers not written: \(error.localizedDescription, privacy: .public)")
                return
            }
        }
        transcription.meetingSpeakerStatus = skip.flatMap { $0.isFailure ? $0.rawValue : nil }
        do {
            try engine.modelContext.save()
        } catch {
            (transcription.text, transcription.meetingSpeakerStatus) = (old.text, old.status)
            if labeled != segments { try? old.file?.write(to: url, options: .atomic) }
            Self.speakersLogger.error("Speakers not saved: \(error.localizedDescription, privacy: .public)")
            return
        }
        updateResult(id) { result in
            result.speakersPending = nil
            result.speakersSkipped = skip
            result.speakersLabeledLater = labeled != segments
            result.transcript = transcription.text
            result.markdown = MeetingNotes.markdown(for: transcription)
        }
    }

    /// At launch: meetings whose speakers were still being told apart when the app quit get them now, one at a
    /// time, in the background. Returns their History entries' ids.
    @discardableResult
    func resumeSpeakers() async -> [UUID] {
        guard let engine else { return [] }
        let pending = SpeakerSplitSkip.pendingStatus
        let meetings = (try? engine.modelContext.fetch(
            FetchDescriptor<Transcription>(predicate: #Predicate { $0.meetingSpeakerStatus == pending }))) ?? []
        var resumed: [UUID] = []
        for transcription in meetings where speakerJobs[transcription.id] == nil {
            guard let mix = transcription.audioFileURL.flatMap(URL.init(string:)) else { continue }
            let folder = mix.deletingLastPathComponent()
            Self.speakersLogger.notice("Telling speakers apart for \(folder.lastPathComponent, privacy: .public), cut off last time")
            let job = speakerTurns(folder: folder, duration: transcription.duration, engine: engine)
            await continueSpeakers(job, id: transcription.id, folder: folder).value
            resumed.append(transcription.id)
        }
        return resumed
    }

    /// Changes the result the panel shows, if it's still this meeting's.
    func updateResult(_ id: UUID, _ change: (inout MeetingResult) -> Void) {
        guard case .done(var result) = phase, result.transcriptionID == id else { return }
        change(&result)
        setResult(result)
    }
}

#if DEBUG
    extension MeetingRecorder {
        static func speakersSelfCheck() {
            let segments = [
                MeetingSegment(speaker: .others, start: 0, end: 20, text: "a"),
                MeetingSegment(speaker: .others, start: 22, end: 40, text: "b"),
            ]
            let two = [SpeakerTurn(id: "A", start: 0, end: 20), SpeakerTurn(id: "B", start: 22, end: 40)]
            assert(labeled(segments, .success(two)).0.map(\.remote) == [1, 2] && labeled(segments, .success(two)).1 == nil)
            let one = labeled(segments, .success([SpeakerTurn(id: "A", start: 0, end: 40)]))
            assert(one.0 == segments && one.1 == .oneSpeaker)
            let failed = labeled(segments, .failure(MeetingDiarizer.Failure.timedOut(90)))
            assert(failed.0 == segments && failed.1 == .timedOut)
            // Only failures are kept on the entry; "one speaker" and "too short" aren't problems.
            assert(SpeakerSplitSkip.timedOut.isFailure && !SpeakerSplitSkip.oneSpeaker.isFailure && !SpeakerSplitSkip.tooShort.isFailure)
            assert(SpeakerSplitSkip(rawValue: SpeakerSplitSkip.modelDownloadFailed.rawValue) == .modelDownloadFailed)
            assert(SpeakerSplitSkip(rawValue: SpeakerSplitSkip.pendingStatus) == nil)
        }
    }
#endif
