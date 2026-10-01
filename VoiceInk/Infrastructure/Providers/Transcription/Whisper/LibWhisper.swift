import Foundation
import os

#if canImport(whisper)
    import whisper
#else
    #error("Unable to import whisper module. Please check your project configuration.")
#endif

// Meet Whisper C++ constraint: Don't access from more than one thread at a time.
actor WhisperContext {
    private var context: OpaquePointer?
    private var language: String?
    private var languageCString: [CChar]?
    private var prompt: String?
    private var promptCString: [CChar]?
    private var vadModelPath: String?
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "WhisperContext")

    private init() {}

    #if DEBUG
        /// A context without a model, for selfChecks that count loads.
        static func placeholder() -> WhisperContext { WhisperContext() }
    #endif

    init(context: OpaquePointer) {
        self.context = context
        preview.attach(context)
    }

    deinit {
        preview.attach(nil)
        if let context = context {
            whisper_free(context)
        }
    }

    private var transcription = ""
    /// This transcription's segments, in seconds from the start of the recording (windows and language
    /// pieces are decoded separately; their offsets are added back).
    private var segments: [TimedSegment] = []
    /// With language auto: every language this transcription was decoded in, in order, each once; and the time the
    /// detections took. Empty and 0 when the language was set.
    private var detectedLanguages: [String] = []
    private var languageDetectionTime: TimeInterval = 0

    /// What one `transcribe` produced.
    struct Transcript {
        let text: String
        /// In seconds from the start of the audio (see `segments`).
        let segments: [TimedSegment]
        /// With language auto: the languages it was decoded in and the time detecting them took (see
        /// `detectedLanguages`).
        let detectedLanguages: [String]
        let languageDetectionTime: TimeInterval
    }

    /// Stops a `transcribe` in flight: whisper.cpp checks it before each graph computation (`abort_callback`), and
    /// the window loop before each window. Set from any thread (a cancelled request's cancellation handler).
    final class Abort: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }
    private var abort: Abort?

    /// One whole transcription with this request's language and prompt. A single synchronous actor call, so no other
    /// request on this context can change the language or prompt between setting them and decoding, or reset the
    /// results before they're returned. Nil when whisper_full fails, `abort` is set, or the model has been released;
    /// an aborted decode leaves the context usable for the next one.
    func transcribe(samples: [Float], language: String?, prompt: String?, abort: Abort? = nil) -> Transcript? {
        self.language = language
        self.prompt = prompt
        self.abort = abort
        defer { self.abort = nil }
        guard fullTranscribe(samples: samples), abort?.isSet != true else { return nil }
        return Transcript(
            text: transcription, segments: segments, detectedLanguages: detectedLanguages,
            languageDetectionTime: languageDetectionTime)
    }

    private func fullTranscribe(samples: [Float]) -> Bool {
        guard let context = context else { return false }
        transcription = ""
        segments = []
        detectedLanguages = []
        languageDetectionTime = 0
        whisper_reset_timings(context)

        let isVADEnabled = UserDefaults.standard.bool(forKey: "IsVADEnabled")
        guard let (speech, probs) = detectSpeech(samples) else {
            return decode(samples[...], vad: isVADEnabled && vadModelPath != nil)
        }

        let windows = WhisperChunking.windows(
            speech: speech, probs: probs, total: samples.count, keepSilence: !isVADEnabled)
        logger.notice(
            "Decoding \(samples.count / WhisperChunking.sampleRate, privacy: .public)s in \(windows.count, privacy: .public) windows, VAD \(isVADEnabled, privacy: .public)"
        )
        let autoLanguage = (language ?? "auto") == "auto"
        var detections: [Int: (language: String, probability: Float)?] = [:]
        func detection(_ index: Int) -> (language: String, probability: Float)? {
            if let known = detections[index] { return known }
            let result = detectLanguage(samples[windows[index]])
            detections[index] = result
            return result
        }
        // Each detection costs a full encoder pass, as much as decoding the window. When the first, middle
        // and last windows agree, decode every window in that language instead of detecting each one.
        let recordingLanguage =
            autoLanguage
            ? WhisperChunking.sharedLanguage(
                WhisperChunking.canaries(windows.count).map(detection), threshold: Self.singleLanguageThreshold)
            : nil
        for (index, window) in windows.enumerated() {
            if abort?.isSet == true { return false }
            let runs: [(range: Range<Int>, language: String)]
            if let recordingLanguage {
                runs = [(window, recordingLanguage)]
            } else if autoLanguage {
                runs = WhisperChunking.mergeRuns(languagePieces(samples, window, probs, known: detection(index)))
            } else {
                runs = []
            }
            if runs.count > 1 {
                logger.notice("Mixed-language window: \(runs.map(\.language).joined(separator: ","), privacy: .public)")
            }
            if runs.isEmpty {
                guard decode(samples[window], vad: false) else { return false }
            }
            for run in runs {
                guard decode(samples[run.range], vad: false, language: run.language) else { return false }
            }
        }
        segments = TimedSegments.snapToSpeech(segments, speech: speech)
        return true
    }

    /// Clean single-language windows detect at p > 0.99; a window holding an English stretch followed
    /// by a Chinese one measured p = 0.56.
    private static let mixedLanguageThreshold: Float = 0.8
    /// Canary windows must all be this sure before the rest of the recording skips detection.
    private static let singleLanguageThreshold: Float = 0.95
    private static let minLanguagePiece = 6 * WhisperChunking.sampleRate

    /// Whisper decodes a window in one language, so a window holding an English stretch and a Chinese
    /// one came out entirely in English with the Chinese translated (upstream #940 / #914). An ambiguous
    /// window is halved at its quietest moment until each piece is confident or ~6 s long. A confident
    /// window is decoded with the detected language rather than letting whisper_full detect it again.
    /// Empty when detection fails; the caller then decodes with the configured language.
    private func languagePieces(
        _ samples: [Float], _ range: Range<Int>, _ probs: [Float],
        known: (language: String, probability: Float)?? = nil
    ) -> [(range: Range<Int>, language: String)] {
        guard let (language, probability) = known ?? detectLanguage(samples[range]) else { return [] }
        let quarter = range.count / 4
        guard probability < Self.mixedLanguageThreshold, range.count >= 2 * Self.minLanguagePiece,
            let middle = WhisperChunking.quietestPoint(
                probs, in: (range.lowerBound + quarter)..<(range.upperBound - quarter))
        else { return [(range, language)] }

        let left = languagePieces(samples, range.lowerBound..<middle, probs)
        let right = languagePieces(samples, middle..<range.upperBound, probs)
        return left.isEmpty || right.isEmpty ? [(range, language)] : left + right
    }

    private func detectLanguage(_ samples: ArraySlice<Float>) -> (language: String, probability: Float)? {
        guard let context else { return nil }
        let start = ProcessInfo.processInfo.systemUptime
        defer { languageDetectionTime += ProcessInfo.processInfo.systemUptime - start }
        let threads = Int32(max(1, min(8, cpuCount() - 2)))
        let melStatus = samples.withUnsafeBufferPointer {
            whisper_pcm_to_mel(context, $0.baseAddress, Int32($0.count), threads)
        }
        guard melStatus == 0 else { return nil }
        var probabilities = [Float](repeating: 0, count: Int(whisper_lang_max_id()) + 1)
        let id = whisper_lang_auto_detect(context, 0, threads, &probabilities)
        guard id >= 0, let name = whisper_lang_str(id) else { return nil }
        return (String(cString: name), probabilities[Int(id)])
    }

    /// Speech ranges in samples plus Silero's per-hop speech probabilities. Nil when the VAD model is
    /// unavailable.
    private func detectSpeech(_ samples: [Float]) -> ([Range<Int>], [Float])? {
        guard let vadModelPath,
            let vctx = whisper_vad_init_from_file_with_params(vadModelPath, whisper_vad_default_context_params())
        else { return nil }
        defer { whisper_vad_free(vctx) }

        guard
            samples.withUnsafeBufferPointer({ whisper_vad_detect_speech(vctx, $0.baseAddress, Int32($0.count)) }),
            let segments = whisper_vad_segments_from_probs(vctx, vadParams())
        else { return nil }
        defer { whisper_vad_free_segments(segments) }
        let probs = Array(UnsafeBufferPointer(start: whisper_vad_probs(vctx), count: Int(whisper_vad_n_probs(vctx))))

        // Segment times are centiseconds.
        let perCs = WhisperChunking.sampleRate / 100
        let speech = (0..<whisper_vad_segments_n_segments(segments)).map { i in
            let t0 = Int(whisper_vad_segments_get_segment_t0(segments, i)) * perCs
            let t1 = Int(whisper_vad_segments_get_segment_t1(segments, i)) * perCs
            return min(t0, samples.count)..<min(max(t0, t1), samples.count)
        }
        return (speech, probs)
    }

    private func vadParams() -> whisper_vad_params {
        var vadParams = whisper_vad_default_params()
        vadParams.threshold = 0.50
        vadParams.min_speech_duration_ms = 250
        vadParams.min_silence_duration_ms = 100
        vadParams.max_speech_duration_s = Float.greatestFiniteMagnitude
        vadParams.speech_pad_ms = 30
        vadParams.samples_overlap = 0.1
        return vadParams
    }

    /// `language` overrides the configured one (used with a language already detected for this audio).
    private func decode(_ samples: ArraySlice<Float>, vad: Bool, language: String? = nil) -> Bool {
        guard let context = context else { return false }

        let maxThreads = max(1, min(8, cpuCount() - 2))
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)

        let selectedLanguage = language ?? self.language ?? "auto"
        if selectedLanguage != "auto" {
            languageCString = Array(selectedLanguage.utf8CString)
            params.language = languageCString?.withUnsafeBufferPointer { ptr in
                ptr.baseAddress
            }
        } else {
            languageCString = nil
            params.language = nil
        }

        if prompt != nil {
            promptCString = Array(prompt!.utf8CString)
            params.initial_prompt = promptCString?.withUnsafeBufferPointer { ptr in
                ptr.baseAddress
            }
        } else {
            promptCString = nil
            params.initial_prompt = nil
        }

        params.print_realtime = true
        params.print_progress = false
        params.print_timestamps = true
        params.print_special = false
        params.translate = false
        params.n_threads = Int32(maxThreads)
        params.offset_ms = 0
        params.no_context = true
        params.single_segment = false
        params.temperature = 0.2

        if vad, let vadModelPath = self.vadModelPath {
            params.vad = true
            params.vad_model_path = (vadModelPath as NSString).utf8String
            params.vad_params = vadParams()
        } else {
            params.vad = false
        }
        if let abort {
            params.abort_callback = { userData in
                guard let userData else { return false }
                return Unmanaged<Abort>.fromOpaque(userData).takeUnretainedValue().isSet
            }
            params.abort_callback_user_data = Unmanaged.passUnretained(abort).toOpaque()
        }

        var success = true
        samples.withUnsafeBufferPointer { samplesBuffer in
            if whisper_full(context, params, samplesBuffer.baseAddress, Int32(samplesBuffer.count)) != 0 {
                logger.error("❌ Failed to run whisper_full. VAD enabled: \(params.vad, privacy: .public)")
                success = false
            }
        }

        languageCString = nil
        promptCString = nil

        if success {
            let count = whisper_full_n_segments(context)
            for i in 0..<count {
                let text = String(cString: whisper_full_get_segment_text(context, i))
                transcription += text
                // Slices keep the recording's indices, so startIndex is this slice's offset. With whisper's own
                // VAD (the whole recording in one call) times are already mapped back to the original audio.
                segments.append(
                    TimedSegments.fromWhisper(
                        t0: whisper_full_get_segment_t0(context, i), t1: whisper_full_get_segment_t1(context, i),
                        text: text, offsetSamples: samples.startIndex, sliceSamples: samples.count))
            }
            // Under auto: the language this piece came out in, whether detected above or by whisper_full itself.
            if count > 0, (self.language ?? "auto") == "auto",
                let decoded = selectedLanguage != "auto"
                    ? selectedLanguage : whisper_lang_str(whisper_full_lang_id(context)).map({ String(cString: $0) }),
                !detectedLanguages.contains(decoded)
            {
                detectedLanguages.append(decoded)
            }
        }
        return success
    }

    // MARK: - Live preview (WhisperLivePreview)

    /// Previews run outside the actor on their own whisper_state (states on one context are independent in
    /// whisper.cpp), so the final transcription never queues behind one. The lock is held for a whole preview
    /// decode; releasing the model raises the abort flag and takes the lock first, so the context is never freed
    /// under a running preview.
    final class PreviewSlot: @unchecked Sendable {
        private let lock = NSLock()
        private let abortFlag = AbortFlag()
        private var context: OpaquePointer?
        private var state: OpaquePointer?

        /// `isSet` aborts the decode in flight. `closed` keeps new decodes from starting (and from clearing
        /// `isSet`) once a recording has stopped; checked and cleared in one step so stop can't be undone by a
        /// decode that was about to begin.
        final class AbortFlag: @unchecked Sendable {
            private let lock = NSLock()
            private var value = false
            private var closed = true
            var isSet: Bool {
                get { lock.withLock { value } }
                set { lock.withLock { value = newValue } }
            }
            func begin() -> Bool { lock.withLock { if closed { return false }; value = false; return true } }
            func setClosed(_ closed: Bool) { lock.withLock { self.closed = closed; if closed { value = true } } }
        }

        func attach(_ context: OpaquePointer?) {
            abortFlag.isSet = true
            lock.withLock {
                if let state { whisper_free_state(state) }
                state = nil
                self.context = context
            }
        }

        /// Lets decodes run (a recording started).
        func open() {
            abortFlag.setClosed(false)
        }

        /// Stops a decode in flight (whisper.cpp checks the flag between steps) and refuses new ones.
        func close() {
            abortFlag.setClosed(true)
        }

        /// Closes and frees the preview state. Waits for an aborted decode to return.
        func releaseState() {
            close()
            lock.withLock {
                if let state { whisper_free_state(state) }
                state = nil
            }
        }

        /// One quick decode for the recorder: greedy, no temperature fallback, no timestamps, one segment, a
        /// token cap, abortable. `language` nil = detect; the detected language is returned so later previews
        /// skip detection. No initial prompt: the app's zh prompt made previews repeat "好,好,好". Nil when
        /// closed, aborted, failed or no model is attached.
        func transcribe(_ samples: [Float], language: String?) -> (text: String, language: String)? {
            guard !samples.isEmpty else { return nil }
            return lock.withLock { () -> (text: String, language: String)? in
                guard let context, abortFlag.begin() else { return nil }
                if state == nil { state = whisper_init_state(context) }
                guard let state else { return nil }

                var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
                params.print_realtime = false
                params.print_progress = false
                params.print_timestamps = false
                params.no_timestamps = true
                params.no_context = true
                params.single_segment = true
                params.temperature = 0
                params.temperature_inc = 0
                // Speech runs at most ~6 tokens a second; the cap stops a repetition loop early.
                params.max_tokens = Int32(samples.count * 8 / 16_000 + 16)
                params.n_threads = Int32(max(1, min(8, cpuCount() - 2)))
                params.abort_callback = { userData in
                    guard let userData else { return false }
                    return Unmanaged<AbortFlag>.fromOpaque(userData).takeUnretainedValue().isSet
                }
                params.abort_callback_user_data = Unmanaged.passUnretained(abortFlag).toOpaque()

                let languageC = language.map { Array($0.utf8CString) }
                let status = languageC.withOptionalBufferPointer { languagePointer in
                    params.language = languagePointer
                    return samples.withUnsafeBufferPointer {
                        whisper_full_with_state(context, state, params, $0.baseAddress, Int32($0.count))
                    }
                }
                guard status == 0, !abortFlag.isSet else { return nil }
                let text = (0..<whisper_full_n_segments_from_state(state))
                    .map { String(cString: whisper_full_get_segment_text_from_state(state, $0)) }
                    .joined()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let detected = whisper_lang_str(whisper_full_lang_id_from_state(state)).map { String(cString: $0) }
                return (text, language ?? detected ?? "auto")
            }
        }
    }

    nonisolated let preview = PreviewSlot()

    static func createContext(path: String) async throws -> WhisperContext {
        let whisperContext = WhisperContext()
        try await whisperContext.initializeModel(path: path)

        // Load VAD model from bundle resources
        let vadModelPath = await VADModelManager.shared.getModelPath()
        await whisperContext.setVADModelPath(vadModelPath)

        return whisperContext
    }

    private func initializeModel(path: String) throws {
        var params = whisper_context_default_params()
        #if targetEnvironment(simulator)
            params.use_gpu = false
            logger.info("Running on the simulator, using CPU")
        #else
            params.flash_attn = true  // Enable flash attention for Metal
            logger.info("Flash attention enabled for Metal")
        #endif

        let context = whisper_init_from_file_with_params(path, params)
        if let context {
            self.context = context
            preview.attach(context)
        } else {
            logger.error("❌ Couldn't load model at \(path, privacy: .public)")
            throw VoiceInkEngineError.modelLoadFailed
        }
    }

    private func setVADModelPath(_ path: String?) {
        self.vadModelPath = path
        if path != nil {
            logger.info("VAD model loaded from bundle resources")
        }
    }

    func releaseResources() {
        preview.attach(nil)
        if let context = context {
            whisper_free(context)
            self.context = nil
        }
        languageCString = nil
    }
}

fileprivate func cpuCount() -> Int {
    ProcessInfo.processInfo.processorCount
}

extension Optional where Wrapped == [CChar] {
    /// Calls `body` with a pointer to the array's storage, or nil.
    fileprivate func withOptionalBufferPointer<R>(_ body: (UnsafePointer<CChar>?) -> R) -> R {
        switch self {
        case .some(let array): return array.withUnsafeBufferPointer { body($0.baseAddress) }
        case .none: return body(nil)
        }
    }
}
