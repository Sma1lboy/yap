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

    init(context: OpaquePointer) {
        self.context = context
    }

    deinit {
        if let context = context {
            whisper_free(context)
        }
    }

    private var transcription = ""

    func fullTranscribe(samples: [Float]) -> Bool {
        guard let context = context else { return false }
        transcription = ""
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
        for window in windows {
            let runs = autoLanguage ? WhisperChunking.mergeRuns(languagePieces(samples, window, probs)) : []
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
        return true
    }

    /// Clean single-language windows detect at p > 0.99; a window holding an English stretch followed
    /// by a Chinese one measured p = 0.56.
    private static let mixedLanguageThreshold: Float = 0.8
    private static let minLanguagePiece = 6 * WhisperChunking.sampleRate

    /// Whisper decodes a window in one language, so a window holding an English stretch and a Chinese
    /// one came out entirely in English with the Chinese translated (upstream #940 / #914). An ambiguous
    /// window is halved at its quietest moment until each piece is confident or ~6 s long. A confident
    /// window is decoded with the detected language rather than letting whisper_full detect it again.
    /// Empty when detection fails; the caller then decodes with the configured language.
    private func languagePieces(
        _ samples: [Float], _ range: Range<Int>, _ probs: [Float]
    ) -> [(range: Range<Int>, language: String)] {
        guard let (language, probability) = detectLanguage(samples[range]) else { return [] }
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
            for i in 0..<whisper_full_n_segments(context) {
                transcription += String(cString: whisper_full_get_segment_text(context, i))
            }
        }
        return success
    }

    func getTranscription() -> String {
        transcription
    }

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
        if let context = context {
            whisper_free(context)
            self.context = nil
        }
        languageCString = nil
    }

    func setPrompt(_ prompt: String?) {
        self.prompt = prompt
    }

    func setLanguage(_ language: String?) {
        self.language = language
    }
}

fileprivate func cpuCount() -> Int {
    ProcessInfo.processInfo.processorCount
}
