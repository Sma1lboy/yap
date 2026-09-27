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
        let notes: String?
        let transcript: String
        /// Why there are no notes (Yap Refine, no AI provider, the request failed); nil when there are.
        let notesProblem: String?
        let markdown: String
    }

    @Published private(set) var phase: Phase = .idle

    static let consentShownKey = "meetingRecordingConsentShown"
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MeetingRecorder")
    private weak var engine: VoiceInkEngine?
    private var session: Session?

    func configure(engine: VoiceInkEngine) {
        self.engine = engine
    }

    // MARK: - Start / stop

    /// The shortcut and the menu: starts, or stops a running recording. The first time, the consent note comes
    /// first and recording starts from its button.
    func toggle() {
        switch phase {
        case .recording: Task { await stop() }
        case .finishing: return
        case .idle, .done:
            if UserDefaults.standard.bool(forKey: Self.consentShownKey) {
                Task { await start() }
            } else {
                phase = .consent
                MeetingPanelController.shared.show()
            }
        case .consent:
            cancelConsent()
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

    func dismissResult() {
        if case .done = phase { phase = .idle }
        MeetingPanelController.shared.close()
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
        guard phase.isRecording, let session, let engine else { return }
        self.session = nil
        phase = .finishing(String(localized: "Transcribing the last part…"))
        session.stopCapture()
        let (segments, failures) = await session.finish()
        if failures > 0 {
            logger.error("\(failures, privacy: .public) meeting pieces failed to transcribe")
        }

        phase = .finishing(String(localized: "Writing notes…"))
        let transcript = MeetingNotes.transcript(segments)
        let summary = await MeetingSummarizer(engine: engine).notes(for: transcript)

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
        engine.modelContext.insert(transcription)
        try? engine.modelContext.save()
        NotificationCenter.default.post(name: .transcriptionCreated, object: transcription)

        let markdown = MeetingNotes.markdown(
            title: String(localized: "Meeting"), date: session.started, duration: session.duration,
            notes: summary.notes, transcript: transcript)
        phase = .done(MeetingResult(
            transcriptionID: transcription.id, notes: summary.notes, transcript: transcript,
            notesProblem: summary.problem, markdown: markdown))
        MeetingPanelController.shared.show()
        logger.notice("Meeting saved: \(segments.count, privacy: .public) segments, notes \(summary.notes != nil, privacy: .public)")
    }

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

        @MainActor init(engine: VoiceInkEngine, configuration: TranscriptionRuntimeConfiguration) {
            self.registry = engine.serviceRegistry
            self.configuration = configuration
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
                lock.lock()
                failures += 1
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
    }

    func notes(for transcript: String) async -> Summary {
        guard !transcript.isEmpty else { return Summary() }
        guard let service = engine.enhancementService, let aiService = service.getAIService() else {
            return Summary(problem: Self.setupHint)
        }
        let base = ModeRuntimeResolver.currentEnhancementConfiguration(enhancementService: service, aiService: aiService)
        guard let provider = base.provider, provider != .voiceInkRefine, service.isConfigured(for: base) else {
            return Summary(problem: Self.setupHint)
        }
        func ask(_ text: String, prompt: String) async throws -> String {
            let configuration = base.replacingPrompt(
                CustomPrompt(title: MeetingNotes.promptTitle, promptText: prompt, useSystemInstructions: false))
            let result = try await service.enhance(
                text, configuration: configuration, timeout: MeetingNotes.timeout(forCharacters: text.count))
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
                duration: Date().timeIntervalSince(started))
        } catch {
            return Summary(problem: EnhancementFailureFormatter.message(for: error))
        }
    }

    static var setupHint: String {
        String(localized: "No notes: this mode has no AI provider for them (Yap Refine can't write notes). Choose one in the mode for your next meeting; the transcript is saved in History.")
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
