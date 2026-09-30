import AVFoundation
import AppKit
import SwiftData
import os

/// Meeting recording: one shortcut starts a long recording of the microphone ("me") and system audio ("others",
/// SystemAudioTap), transcribes it in 20–28 s pieces while the meeting goes on, and when it's stopped writes notes
/// with the mode's AI provider and saves one History entry (kind "meeting") with both recordings and a mix.
/// Nothing is pasted. The dictation recorder's media pausing and output muting are not used here, and dictation
/// skips them while a meeting records (Recorder checks `isRecordingMeeting`).
@MainActor
final class MeetingRecorder: ObservableObject {
    static let shared = MeetingRecorder()
    /// Read by the dictation Recorder, which must not mute the output or pause media during a meeting.
    static var isRecordingMeeting: Bool { shared.phase.isRecording }

    enum Phase: Equatable {
        case idle
        case consent
        case recording(started: Date)
        case finishing(String)
        case done(MeetingResult)

        var isRecording: Bool { if case .recording = self { return true } else { return false } }
    }

    struct MeetingResult: Equatable {
        let transcriptionID: UUID
        var notes: String?
        /// Updated when the speakers are told apart after saving.
        var transcript: String
        /// Why there are no notes (Yap Refine, no AI provider, the request failed); nil when there are.
        var notesProblem: String?
        var markdown: String
        /// The AI model that wrote the notes.
        var notesModel: String?
        /// Where the meeting's audio is (mic.wav, system.wav, mix.wav).
        var folder: URL? = nil
        /// Pieces that couldn't be transcribed; each keeps a marked line in the transcript.
        var failedPieces = 0
        /// Why the remote lines are plain "Others"; nil when they were told apart or nobody remote spoke.
        var speakersSkipped: SpeakerSplitSkip? = nil
        /// "Me" pieces the other side's voice was taken out of (MeetingEcho), whole or in part.
        var echoRemoved = 0
        /// The History entry couldn't be saved (the folder stays, and the next launch recovers it).
        var saveError: String? = nil
        /// A recovered meeting saved with its audio only, not transcribed.
        var audioOnly = false
        /// The last "Export Markdown…" from the panel couldn't write the file.
        var exportError: String? = nil
        /// "Regenerate Notes" is writing them; `regenerateProblem` says why the last try left the notes as they were.
        var isRegenerating = false
        var regenerateProblem: String? = nil
        /// The meeting is saved and its remote speakers are still being told apart in the background: what that's
        /// doing now ("Telling speakers apart…", the model download). nil once done or when not needed.
        var speakersPending: String? = nil
        /// The speakers were told apart after the meeting was saved: the transcript has them, the notes don't.
        var speakersLabeledLater = false

        /// Only a saved, transcribed meeting in which something was said has notes that can be written again.
        var canRegenerate: Bool { saveError == nil && !audioOnly && !transcript.isEmpty }
    }

    @Published private(set) var phase: Phase = .idle

    static let consentShownKey = "meetingRecordingConsentShown"
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MeetingRecorder")
    weak var engine: VoiceInkEngine?
    private var session: Session?
    /// Folders of meetings being recorded, finished or recovered right now: never taken for interrupted ones.
    var activeFolders: Set<String> = []
    /// Speakers being told apart after their meeting was saved (MeetingSpeakers.swift), by History entry.
    var speakerJobs: [UUID: Task<Void, Never>] = [:]
    /// Where each running diarization's progress goes, by meeting folder: the "finishing" panel, then the result.
    var speakerProgress: [String: @MainActor (String) -> Void] = [:]

    func configure(engine: VoiceInkEngine) {
        self.engine = engine
    }

    // MARK: - Start / stop

    /// What the meeting shortcut does in each phase. A running meeting is never stopped from the keyboard (a
    /// stray right ⌘ + Space ended one): the shortcut only brings the panel forward with a reminder to click ✓.
    enum ShortcutAction: Equatable { case start, showConsent, cancelConsent, remindToClickStop, ignore }

    static func shortcutAction(for phase: Phase, consentShown: Bool) -> ShortcutAction {
        switch phase {
        case .recording: return .remindToClickStop
        case .finishing: return .ignore
        case .idle, .done: return consentShown ? .start : .showConsent
        case .consent: return .cancelConsent
        }
    }

    /// Until when the recording panel shows "click ✓ to end the meeting" after the shortcut was pressed.
    @Published private(set) var stopReminderUntil: Date?

    /// The meeting shortcut. Starts a meeting (the first time, the consent note comes first and recording starts
    /// from its button); during a meeting it doesn't stop it. Stopping is a click on ✓ in the panel.
    func toggle() {
        switch Self.shortcutAction(for: phase, consentShown: UserDefaults.standard.bool(forKey: Self.consentShownKey)) {
        case .start:
            Task { await start() }
        case .showConsent:
            phase = .consent
            MeetingPanelController.shared.show()
        case .cancelConsent:
            cancelConsent()
        case .remindToClickStop:
            stopReminderUntil = Date().addingTimeInterval(4)
            MeetingPanelController.shared.show()
        case .ignore:
            return
        }
    }

    func acceptConsentAndStart() {
        UserDefaults.standard.set(true, forKey: Self.consentShownKey)
        Task { await start() }
    }

    func cancelConsent() {
        phase = .idle
        MeetingPanelController.shared.close()
    }

    /// "Export Markdown…" in the panel: a failed write shows in the panel instead of being dropped.
    func exportMarkdown() {
        guard case .done(var result) = phase else { return }
        result.exportError = MeetingExport.saveMarkdown(result.markdown)
        phase = .done(result)
    }

    /// "Regenerate Notes" in the panel: the same as in History; the old notes stay if it fails.
    func regenerateNotes() async {
        guard case .done(var result) = phase, result.canRegenerate, !result.isRegenerating, let engine else { return }
        let id = result.transcriptionID
        guard let transcription = try? engine.modelContext.fetch(
            FetchDescriptor<Transcription>(predicate: #Predicate { $0.id == id })).first
        else { return }
        result.isRegenerating = true
        result.regenerateProblem = nil
        phase = .done(result)
        let problem = await MeetingEdits.regenerateNotes(for: transcription, engine: engine)
        guard case .done(var current) = phase, current.transcriptionID == id else { return }
        current.isRegenerating = false
        current.regenerateProblem = problem
        if problem == nil {
            current.notes = transcription.enhancedText
            current.notesProblem = nil
            current.notesModel = transcription.aiEnhancementModelName
            current.markdown = MeetingEdits.markdown(for: transcription)
            current.speakersLabeledLater = false  // the new notes have the speakers
        }
        phase = .done(current)
    }

    func dismissResult() {
        if case .done = phase { phase = .idle }
        MeetingPanelController.shared.close()
    }

    /// A newer result for the meeting the panel shows (MeetingSpeakers.swift, when the speakers arrive).
    func setResult(_ result: MeetingResult) {
        phase = .done(result)
    }

    func start() async {
        guard !phase.isRecording, let engine else { return }
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            return notify(String(localized: "Meeting recording needs microphone access."), pane: .microphone)
        }
        guard let configuration = ModeRuntimeResolver.transcriptionConfiguration(
            transcriptionModelManager: engine.transcriptionModelManager)
        else { return notify(String(localized: "Choose a transcription model in the mode before recording a meeting.")) }
        guard let micDevice = AudioDeviceManager.shared.resolveCurrentRecordingDevice().deviceID else {
            return notify(String(localized: "No microphone is available for the meeting recording."), pane: .microphone)
        }

        let started = Date()
        let folder = engine.recordingsDirectory.appendingPathComponent("meetings/\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("pieces"), withIntermediateDirectories: true)
            let session = try Session(
                folder: folder, started: started, transcriber: Transcriber(engine: engine, configuration: configuration))
            self.session = session
            activeFolders.insert(folder.lastPathComponent)
            try session.startMicrophone(deviceID: micDevice)
            do {
                try session.startSystemAudio()
            } catch {
                logger.error("System audio tap failed: \(error.localizedDescription, privacy: .public)")
                notify(String(localized: "Yap can't record other apps' sound; only your microphone is recorded."), pane: .screenRecording)
            }
        } catch {
            session?.stopCapture()
            session = nil
            activeFolders.remove(folder.lastPathComponent)
            return notify(String(format: String(localized: "Meeting recording couldn't start: %@"), error.localizedDescription))
        }
        phase = .recording(started: started)
        MeetingPanelController.shared.show()
        scheduleSilenceCheck(started: started)
        logger.notice("Meeting recording started with \(configuration.model.displayName, privacy: .public)")
    }

    /// If system audio is all zeros a few seconds in, the permission was most likely denied (the tap then delivers
    /// only zeros); it can also just be that nobody has spoken yet, which the message allows for.
    private func scheduleSilenceCheck(started: Date) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, case .recording(let current) = self.phase, current == started,
                let session = self.session, session.systemAudioIsAllZeros
            else { return }
            self.notify(
                String(localized: "No sound from other apps yet. If the call is already talking, allow Yap under System Audio Recording."),
                pane: .screenRecording)
        }
    }

    func stop() async {
        guard phase.isRecording, let session else { return }
        self.session = nil
        phase = .finishing(String(localized: "Transcribing the last part…"))
        session.stopCapture()
        await complete(session)
    }

    /// After capture: finishes the meeting with progress in the panel, then shows the result.
    @discardableResult
    private func complete(_ session: Session) async -> MeetingResult? {
        guard let engine else { return nil }
        let result = await finishMeeting(session, engine: engine) { [weak self] message in self?.phase = .finishing(message) }
        phase = .done(result)
        MeetingPanelController.shared.show()
        return result
    }

    /// Everything after capture, without touching the panel (recovery runs it in the background): waits for the
    /// transcription, takes the speakers' echo out of "Me", tells remote speakers apart, writes notes, saves the
    /// History entry. Telling speakers apart is waited for up to `speakerWait` seconds (`MeetingRecorder.speakerWait`
    /// when nil); past that the meeting is saved with plain "Others" and the speakers are filled in when they're
    /// ready (`continueSpeakers`).
    func finishMeeting(
        _ session: Session, engine: VoiceInkEngine, timestamp: Date? = nil, speakerWait: TimeInterval? = nil,
        progress: @escaping @MainActor @Sendable (String) -> Void
    ) async -> MeetingResult {
        defer { activeFolders.remove(session.folder.lastPathComponent) }
        progress(String(localized: "Transcribing the last part…"))
        let transcribing = Date()
        var (segments, failures) = await session.finish()
        if failures > 0 {
            logger.error("\(failures, privacy: .public) meeting pieces failed to transcribe")
        }
        #if DEBUG
            if MeetingFilesCheck.isRequested {
                let elapsed = String(format: "%.1f", Date().timeIntervalSince(transcribing))
                print("meeting-check: transcribed in \(elapsed) s; \(segments.count) pieces, \(Int(session.duration)) s per channel")
            }
        #endif
        // Echo: the other side heard through the speakers, transcribed again as "Me". Reads both channels' files.
        let folder = session.folder
        let deduplicated = await Task.detached { [segments] in MeetingEcho.removeEcho(from: segments, folder: folder) }.value
        let echoRemoved = deduplicated.filter(\.hadEcho).count
        if echoRemoved > 0 {
            segments = deduplicated
            try? JSONEncoder().encode(segments).write(to: folder.appendingPathComponent("segments.json"), options: .atomic)
            logger.notice("Echo taken out of \(echoRemoved, privacy: .public) of the microphone's pieces")
        }
        #if DEBUG
            if MeetingFilesCheck.isRequested { print("meeting-check: echo-removed \(echoRemoved)") }
        #endif
        var speakersSkipped: SpeakerSplitSkip? = nil
        var speakerJob: SpeakerJob? = nil
        if segments.contains(where: { $0.speaker == .others && !$0.isFailed }) {
            if session.duration < MeetingDiarizer.minimumDuration {
                speakersSkipped = .tooShort
            } else {
                progress(String(localized: "Telling speakers apart…"))
                speakerProgress[folder.lastPathComponent] = progress
                let job = speakerTurns(folder: folder, duration: session.duration, engine: engine)
                if let turns = await Self.value(of: job, within: speakerWait ?? Self.speakerWait) {
                    speakerProgress[folder.lastPathComponent] = nil
                    let labeled: [MeetingSegment]
                    (labeled, speakersSkipped) = Self.labeled(segments, turns)
                    if labeled != segments {
                        segments = labeled
                        try? JSONEncoder().encode(segments).write(to: folder.appendingPathComponent("segments.json"), options: .atomic)
                    }
                } else {
                    speakerJob = job
                }
            }
        }

        progress(String(localized: "Writing notes…"))
        let transcript = MeetingNotes.transcript(segments)
        // Notes from what was understood; the failed pieces' markers are left out.
        let summary = await MeetingSummarizer(engine: engine).notes(for: MeetingNotes.transcript(segments.filter { !$0.isFailed }))

        let transcription = Transcription(
            text: transcript.isEmpty ? String(localized: "(Nothing was said in this meeting.)") : transcript,
            duration: session.duration,
            enhancedText: summary.notes,
            audioFileURL: session.mixURL.absoluteString,
            transcriptionModelName: session.transcriber.configuration.model.displayName,
            aiEnhancementModelName: summary.modelName,
            promptName: summary.notes == nil ? nil : MeetingNotes.promptTitle,
            enhancementDuration: summary.duration,
            modeName: session.transcriber.configuration.metadata.name,
            modeEmoji: session.transcriber.configuration.metadata.emoji,
            transcriptionStatus: .completed)
        transcription.kind = Transcription.meetingKind
        transcription.meetingFailedPieces = failures > 0 ? failures : nil
        transcription.meetingSpeakerStatus = speakerJob == nil ? nil : SpeakerSplitSkip.pendingStatus
        if let timestamp { transcription.timestamp = timestamp }
        let saveError = save(transcription, engine: engine)

        let markdown = MeetingNotes.markdown(
            title: String(localized: "Meeting"), date: session.started, duration: session.duration,
            notes: summary.notes, transcript: transcript)
        logger.notice("Meeting saved: \(segments.count, privacy: .public) segments, notes \(summary.notes != nil, privacy: .public)")
        var result = MeetingResult(
            transcriptionID: transcription.id, notes: summary.notes, transcript: transcript,
            notesProblem: summary.problem, markdown: markdown, notesModel: summary.modelName,
            folder: session.folder, failedPieces: failures, speakersSkipped: speakersSkipped, echoRemoved: echoRemoved,
            saveError: saveError)
        if let speakerJob {
            // Without an entry there's nothing to update; the next launch recovers the folder from the start.
            if saveError == nil {
                result.speakersPending = String(localized: "Telling speakers apart…")
                continueSpeakers(speakerJob, id: transcription.id, folder: folder)
            } else {
                speakerProgress[folder.lastPathComponent] = nil
            }
        }
        return result
    }

    /// Saves a new History entry; returns the error instead of dropping it. A failed entry isn't left pending in
    /// the context, so its folder stays without an entry and the next launch recovers it.
    func save(_ transcription: Transcription, engine: VoiceInkEngine) -> String? {
        engine.modelContext.insert(transcription)
        do {
            #if DEBUG
                if MeetingFilesCheck.failsSave { throw CocoaError(.fileWriteNoPermission) }
            #endif
            try engine.modelContext.save()
            NotificationCenter.default.post(name: .transcriptionCreated, object: transcription)
            return nil
        } catch {
            engine.modelContext.delete(transcription)
            logger.error("Meeting not saved: \(error.localizedDescription, privacy: .public)")
            return error.localizedDescription
        }
    }

    #if DEBUG
        /// `--meeting-files <mic.wav> <system.wav>` (MeetingFilesCheck): two 16 kHz mono PCM16 files go through the
        /// same channels, chunking, transcription, notes and saving as a live recording, without capture.
        func processFiles(microphone: URL, system: URL) async -> (MeetingResult, folder: URL)? {
            guard let engine, let configuration = ModeRuntimeResolver.transcriptionConfiguration(
                transcriptionModelManager: engine.transcriptionModelManager)
            else { return nil }
            let folder = engine.recordingsDirectory.appendingPathComponent("meetings/\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder.appendingPathComponent("pieces"), withIntermediateDirectories: true)
            guard let session = try? Session(
                folder: folder, started: Date(), transcriber: Transcriber(engine: engine, configuration: configuration))
            else { return nil }
            activeFolders.insert(folder.lastPathComponent)
            phase = .recording(started: session.started)
            session.feed(file: microphone, as: .me)
            session.feed(file: system, as: .others)
            return await complete(session).map { ($0, folder) }
        }
    #endif

    #if DEBUG
        /// make ui-snapshots: puts the panel in a given state without recording.
        func setSnapshotPhase(_ phase: Phase) { self.phase = phase }
    #endif

    private func notify(_ message: String, pane: PrivacySettingsPane? = nil) {
        NotificationManager.shared.showNotification(
            title: message, type: .warning, duration: 8,
            actionButton: pane.map { pane in (String(localized: "Open Settings"), { pane.open() }) })
    }

    // MARK: - Session

    /// One recording: both channels' files, chunkers and the transcription queue.
    final class Session {
        let folder: URL
        let started: Date
        let transcriber: Transcriber
        var mixURL: URL { folder.appendingPathComponent("mix.wav") }
        private(set) var duration: TimeInterval = 0

        private let queue = DispatchQueue(label: "me.sma1lboy.yap.meeting.channels")
        private var channels: [MeetingSegment.Speaker: Channel]
        private let microphone = CoreAudioRecorder()
        private let systemAudio = SystemAudioTap()

        init(folder: URL, started: Date, transcriber: Transcriber) throws {
            self.folder = folder
            self.started = started
            self.transcriber = transcriber
            channels = [
                .me: try Channel(url: folder.appendingPathComponent("mic.wav")),
                .others: try Channel(url: folder.appendingPathComponent("system.wav")),
            ]
        }

        var systemAudioIsAllZeros: Bool { queue.sync { channels[.others]?.peak == 0 } }

        func startMicrophone(deviceID: AudioDeviceID) throws {
            microphone.onAudioChunk = { [weak self] data in
                var samples = [Int16](repeating: 0, count: data.count / 2)
                _ = samples.withUnsafeMutableBytes { data.copyBytes(to: $0) }
                self?.receive(samples, from: .me)
            }
            // CoreAudioRecorder always writes a file; mic.wav is written from the same samples, kept on the clock.
            try microphone.startRecording(toOutputFile: folder.appendingPathComponent("pieces/mic-raw.wav"), deviceID: deviceID)
        }

        func startSystemAudio() throws {
            systemAudio.onSamples = { [weak self] samples in self?.receive(samples, from: .others) }
            try systemAudio.start()
        }

        /// Samples from either capture queue: padded to the wall clock after a gap (device switch), written, cut.
        func receive(_ samples: [Int16], from speaker: MeetingSegment.Speaker) {
            let elapsed = Date().timeIntervalSince(started)
            queue.async { [self] in
                guard let channel = channels[speaker] else { return }
                let pieces = channel.append(samples, elapsedAtEnd: elapsed)
                for piece in pieces { transcriber.enqueue(piece, speaker: speaker, folder: folder) }
            }
        }

        /// A whole recorded channel from a 16 kHz mono PCM16 WAV, in one-second blocks, without the wall clock.
        /// Reads from byte 44 to the end, so a file whose header was never finished (a crash) works too.
        // ponytail: pieces queue up in memory faster than they're transcribed (~1 MB per piece); fine for hours,
        // feed with backpressure if recovered meetings get much longer.
        func feed(file: URL, as speaker: MeetingSegment.Speaker) {
            guard let handle = try? FileHandle(forReadingFrom: file) else { return }
            defer { try? handle.close() }
            try? handle.seek(toOffset: 44)
            queue.sync {
                guard let channel = channels[speaker] else { return }
                while let data = try? handle.read(upToCount: 32_000), !data.isEmpty {
                    let block = PCM16WAVWriter.samples(from: Data(count: 44) + data)
                    let elapsed = TimeInterval(channel.writer.sampleCount + block.count) / MeetingChunker.sampleRate
                    for piece in channel.append(block, elapsedAtEnd: elapsed) {
                        transcriber.enqueue(piece, speaker: speaker, folder: folder)
                    }
                }
            }
        }

        func stopCapture() {
            microphone.stopRecording()
            microphone.onAudioChunk = nil
            systemAudio.stop()
            systemAudio.onSamples = nil
        }

        /// Flushes both channels, waits for every piece, writes the mix; returns the segments in time order.
        func finish() async -> ([MeetingSegment], Int) {
            let (tails, length) = queue.sync { () -> ([(MeetingSegment.Speaker, MeetingChunker.Piece)], Int) in
                var tails: [(MeetingSegment.Speaker, MeetingChunker.Piece)] = []
                for (speaker, channel) in channels {
                    if let tail = channel.flush() { tails.append((speaker, tail)) }
                }
                return (tails, channels.values.map(\.writer.sampleCount).max() ?? 0)
            }
            for (speaker, piece) in tails { transcriber.enqueue(piece, speaker: speaker, folder: folder) }
            duration = TimeInterval(length) / MeetingChunker.sampleRate
            let result = await transcriber.finish()
            queue.sync { channels.values.forEach { $0.writer.close() } }
            MeetingMixer.mix(
                [folder.appendingPathComponent("mic.wav"), folder.appendingPathComponent("system.wav")], into: mixURL)
            try? FileManager.default.removeItem(at: folder.appendingPathComponent("pieces"))
            let data = try? JSONEncoder().encode(result.segments)
            try? data?.write(to: folder.appendingPathComponent("segments.json"))
            return (result.segments, result.failures)
        }
    }

    /// One channel's file and chunker, kept on the wall clock.
    final class Channel {
        let writer: PCM16WAVWriter
        private var chunker = MeetingChunker()
        private(set) var peak: Int16 = 0

        init(url: URL) throws { writer = try PCM16WAVWriter(url: url) }

        func append(_ samples: [Int16], elapsedAtEnd: TimeInterval) -> [MeetingChunker.Piece] {
            // Behind the clock by more than half a second (a device switch, a stalled device): fill with silence
            // so both channels' timestamps stay aligned.
            let expected = Int(elapsedAtEnd * MeetingChunker.sampleRate) - samples.count
            var pieces: [MeetingChunker.Piece] = []
            if expected - writer.sampleCount > Int(MeetingChunker.sampleRate / 2) {
                let gap = [Int16](repeating: 0, count: expected - writer.sampleCount)
                writer.append(gap)
                pieces += chunker.append(gap)
            }
            writer.append(samples)
            if peak == 0, let loudest = samples.lazy.map({ $0 == .min ? .max : abs($0) }).max() { peak = max(peak, loudest) }
            return pieces + chunker.append(samples)
        }

        func flush() -> MeetingChunker.Piece? { chunker.flush() }
    }

    /// Transcribes pieces one at a time, in order, with the mode's transcription model.
    final class Transcriber: @unchecked Sendable {
        let configuration: TranscriptionRuntimeConfiguration
        private let registry: TranscriptionServiceRegistry
        private let lock = NSLock()
        private var chain: Task<Void, Never>?
        private var segments: [MeetingSegment] = []
        private var failures = 0
        private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MeetingRecorder")

        #if DEBUG
            /// `--meeting-fail-pieces N`: the first N pieces fail, for scripts/meeting-files-check.sh.
            private var failuresToInject = 0
        #endif

        @MainActor init(engine: VoiceInkEngine, configuration: TranscriptionRuntimeConfiguration) {
            self.registry = engine.serviceRegistry
            self.configuration = configuration
            #if DEBUG
                failuresToInject = MeetingFilesCheck.failPieces
            #endif
        }

        func enqueue(_ piece: MeetingChunker.Piece, speaker: MeetingSegment.Speaker, folder: URL) {
            lock.lock()
            let previous = chain
            chain = Task { [self] in
                await previous?.value
                await transcribe(piece, speaker: speaker, folder: folder)
            }
            lock.unlock()
        }

        func finish() async -> (segments: [MeetingSegment], failures: Int) {
            lock.lock()
            let last = chain
            lock.unlock()
            await last?.value
            lock.lock()
            defer { lock.unlock() }
            return (segments.sorted { $0.start < $1.start }, failures)
        }

        private func transcribe(_ piece: MeetingChunker.Piece, speaker: MeetingSegment.Speaker, folder: URL) async {
            let url = folder.appendingPathComponent("pieces/\(speaker.rawValue)-\(Int(piece.start * 1000)).wav")
            do {
                #if DEBUG
                    lock.lock()
                    let inject = failuresToInject > 0
                    if inject { failuresToInject -= 1 }
                    lock.unlock()
                    if inject { throw CocoaError(.fileReadUnknown) }
                #endif
                try PCM16WAVWriter.write(piece.samples, to: url)
                defer { try? FileManager.default.removeItem(at: url) }
                let raw = try await registry.transcribe(
                    audioURL: url, model: configuration.model, context: configuration.requestContext)
                let text = TranscriptionOutputFilter.filter(raw).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                lock.lock()
                segments.append(MeetingSegment(speaker: speaker, start: piece.start, end: piece.end, text: text))
                lock.unlock()
            } catch {
                logger.error("Meeting piece at \(piece.start, privacy: .public)s failed: \(error.localizedDescription, privacy: .public)")
                // The piece keeps a line in the transcript, marked as not transcribed.
                lock.lock()
                failures += 1
                segments.append(MeetingSegment(speaker: speaker, start: piece.start, end: piece.end, text: "", failed: true))
                lock.unlock()
            }
        }
    }
}

/// Writes notes for a meeting transcript with the mode's AI provider and the built-in meeting notes prompt.
/// Long transcripts are summarized in parts first, then the parts' notes are merged.
@MainActor
struct MeetingSummarizer {
    let engine: VoiceInkEngine

    struct Summary {
        var notes: String?
        var problem: String?
        var modelName: String?
        var duration: TimeInterval?
        /// What the final request sent (the prompt with the speakers' names, the transcript or part notes).
        var systemMessage: String?
        var userMessage: String?
    }

    /// `names`: the speakers' real names, when the user gave any; the prompt then says who is who.
    func notes(for transcript: String, names: MeetingSpeakerNames = [:]) async -> Summary {
        guard !transcript.isEmpty else { return Summary() }
        guard let service = engine.enhancementService, let aiService = service.getAIService() else {
            return Summary(problem: Self.setupHint)
        }
        let base = ModeRuntimeResolver.currentEnhancementConfiguration(enhancementService: service, aiService: aiService)
        func withPrompt(_ prompt: String) -> EnhancementRuntimeConfiguration {
            base.replacingPrompt(CustomPrompt(title: MeetingNotes.promptTitle, promptText: prompt, useSystemInstructions: false))
        }
        // Checked with the notes prompt in place: the mode's own prompt selection doesn't matter here.
        // The mode's AI enhancement switch decides: without it, a fresh install would fall back to whatever local
        // model is around (Ollama) for every meeting.
        guard base.isEnabled, let provider = base.provider, provider != .voiceInkRefine,
            service.isConfigured(for: withPrompt(MeetingNotes.prompt))
        else {
            return Summary(problem: Self.setupHint)
        }
        var last: AIEnhancementResult?
        func ask(_ text: String, prompt: String) async throws -> String {
            #if DEBUG
                if MeetingFilesCheck.takeNotesFailure() { throw EnhancementError.enhancementFailed }
            #endif
            let configuration = withPrompt(MeetingNotes.named(prompt, names: names))
            let result = try await service.enhance(
                text, configuration: configuration, timeout: MeetingNotes.timeout(forCharacters: text.count))
            last = result
            return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let started = Date()
        do {
            let parts = MeetingNotes.parts(of: transcript)
            var input = transcript
            if parts.count > 1 {
                var partNotes: [String] = []
                for (index, part) in parts.enumerated() {
                    partNotes.append("## Part \(index + 1)\n" + (try await ask(part, prompt: MeetingNotes.partPrompt)))
                }
                input = partNotes.joined(separator: "\n\n")
            }
            let notes = try await ask(input, prompt: MeetingNotes.prompt)
            return Summary(
                notes: notes.isEmpty ? nil : notes, modelName: base.modelName ?? provider.defaultModel,
                duration: Date().timeIntervalSince(started), systemMessage: last?.systemMessage,
                userMessage: last?.userMessage)
        } catch {
            return Summary(problem: EnhancementFailureFormatter.message(for: error))
        }
    }

    static var setupHint: String {
        String(localized: "No notes: AI enhancement is off in this mode, or it has no AI provider for them (Yap Refine can't write notes). Turn it on and choose a provider in the mode for your next meeting; the transcript is saved in History.")
    }
}

/// Adds 16 kHz mono PCM16 WAV files into one (the History player's audio), clipping, in blocks.
enum MeetingMixer {
    static func mix(_ inputs: [URL], into output: URL) {
        let handles = inputs.compactMap { try? FileHandle(forReadingFrom: $0) }
        defer { handles.forEach { try? $0.close() } }
        guard let writer = try? PCM16WAVWriter(url: output) else { return }
        defer { writer.close() }
        handles.forEach { try? $0.seek(toOffset: 44) }
        let blockBytes = 1 << 20
        while true {
            let blocks = handles.map { PCM16WAVWriter.samples(from: Data(count: 44) + ($0.readData(ofLength: blockBytes))) }
            let length = blocks.map(\.count).max() ?? 0
            guard length > 0 else { break }
            var mixed = [Int16](repeating: 0, count: length)
            for block in blocks {
                for (index, sample) in block.enumerated() {
                    mixed[index] = Int16(clamping: Int32(mixed[index]) + Int32(sample))
                }
            }
            writer.append(mixed)
        }
    }
}

#if DEBUG
    extension MeetingRecorder {
        /// The keyboard never ends a running meeting.
        static func shortcutSelfCheck() {
            for consent in [true, false] {
                assert(shortcutAction(for: .recording(started: Date()), consentShown: consent) == .remindToClickStop)
                assert(shortcutAction(for: .finishing("x"), consentShown: consent) == .ignore)
                assert(shortcutAction(for: .consent, consentShown: consent) == .cancelConsent)
            }
            assert(shortcutAction(for: .idle, consentShown: true) == .start)
            assert(shortcutAction(for: .idle, consentShown: false) == .showConsent)
        }
    }
#endif
