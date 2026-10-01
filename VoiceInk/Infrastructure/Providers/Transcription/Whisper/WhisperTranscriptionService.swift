import AVFoundation
import Accelerate
import Foundation
import SwiftData
import os

class WhisperTranscriptionService: TranscriptionService {

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "WhisperTranscriptionService")
    private let modelsDirectory: URL
    private weak var modelProvider: (any WhisperModelProvider)?
    /// Source of dictionary words for the prompt; nil means no dictionary.
    private let modelContainer: ModelContainer?

    init(modelsDirectory: URL, modelProvider: (any WhisperModelProvider)? = nil, modelContext: ModelContext? = nil) {
        self.modelsDirectory = modelsDirectory
        self.modelProvider = modelProvider
        self.modelContainer = modelContext?.container
    }

    func transcribe(audioURL: URL, model: any TranscriptionModel, context: TranscriptionRequestContext) async throws
        -> String
    {
        try await transcribeWithSegments(audioURL: audioURL, model: model, context: context).text
    }

    /// The text and its timed segments (seconds from the start of the audio, for subtitle export), both from this
    /// request's decode. Nothing here waits for the main actor when the model is loaded: right after a stop it is busy
    /// with the recorder and History for about 20 ms.
    func transcribeWithSegments(audioURL: URL, model: any TranscriptionModel, context: TranscriptionRequestContext)
        async throws -> (text: String, segments: [TimedSegment])
    {
        guard model.provider == .whisper, let modelProvider else {
            throw VoiceInkEngineError.modelLoadFailed
        }

        logger.notice("Initiating local transcription for model: \(model.displayName, privacy: .public)")

        let samples = try Self.readAudioSamples(audioURL)
        let prompt = WhisperPrompt.withVocabulary(context.prompt ?? "", words: dictionaryWords())
        // The shared context, in this request's turn: the preload the shortcut press started is waited for, never
        // loaded a second time, and the language and prompt go with this decode only. Cancelling the task takes it
        // out of the queue, or aborts its decode (whisper.cpp's abort callback) and frees the turn for the next one.
        let abort = WhisperContext.Abort()
        let transcript: WhisperContext.Transcript?
        do {
            transcript = try await withTaskCancellationHandler {
                try await modelProvider.withContext(named: model.name) { whisperContext, loaded in
                    if loaded { DictationTimeline.modelDidLoad() }
                    return await whisperContext.transcribe(
                        samples: samples, language: context.language, prompt: prompt, abort: abort)
                }
            } onCancel: {
                abort.set()
            }
        } catch is CancellationError {
            logger.notice("Local transcription cancelled before decoding")
            throw CancellationError()
        } catch {
            logger.error("❌ Failed to load model: \(model.name, privacy: .public) - \(error, privacy: .public)")
            throw VoiceInkEngineError.modelLoadFailed
        }
        if abort.isSet {
            logger.notice("Local transcription cancelled while decoding")
            throw CancellationError()
        }
        guard let transcript else {
            logger.error("❌ Core transcription engine failed (whisper_full).")
            throw VoiceInkEngineError.whisperCoreFailed
        }
        DictationTimeline.languagesDetected(transcript.detectedLanguages, seconds: transcript.languageDetectionTime)

        logger.notice("Whisper transcription completed successfully.")
        return (transcript.text, transcript.segments)
    }

    /// Read through a context of its own on this thread; the main context would wait for the main actor.
    private func dictionaryWords() -> [(word: String, dateAdded: Date)] {
        guard let modelContainer else { return [] }
        let words = (try? ModelContext(modelContainer).fetch(FetchDescriptor<VocabularyWord>())) ?? []
        return words.map { ($0.word, $0.dateAdded) }
    }

    static func readAudioSamples(_ url: URL) throws -> [Float] {
        samples(fromWAV: try Data(contentsOf: url))
    }

    /// Every Int16 sample's float, scaled as the decode always has (÷ 32767, clamped to -1...1). vDSP's own division
    /// differs in the last bit for some values, so it looks these up instead.
    private static let scaledSamples: [Float] = (0..<65_536).map { max(-1.0, min(Float($0 - 32_768) / 32767.0, 1.0)) }

    /// 16-bit little-endian PCM from `pcmDataOffset` on, scaled to -1...1, in vDSP passes (the per-sample read it
    /// replaced took 8 ms for 8 s of audio, between the stop and the decode).
    static func samples(fromWAV data: Data) -> [Float] {
        let start = pcmDataOffset(data)
        let count = max(0, (data.count - start) / 2)
        guard count > 0 else { return [] }
        var shorts = [Int16](repeating: 0, count: count)
        let bytes = data.startIndex + start..<data.startIndex + start + 2 * count
        _ = shorts.withUnsafeMutableBytes { data.copyBytes(to: $0, from: bytes) }
        var indices = [Float](repeating: 0, count: count)
        var floats = [Float](repeating: 0, count: count)
        var offset: Float = 32_768
        let length = vDSP_Length(count)
        indices.withUnsafeMutableBufferPointer { index in
            vDSP_vflt16(shorts, 1, index.baseAddress!, 1, length)
            vDSP_vsadd(index.baseAddress!, 1, &offset, index.baseAddress!, 1, length)
        }
        vDSP_vindex(scaledSamples, indices, 1, &floats, 1, length)
        return floats
    }

    /// Where the samples start. Apple's writers put a FLLR padding chunk before `data`, so the recorder's
    /// files start at byte 4096, not 44; reading from 44 fed whisper ~0.13 s of zeros plus the chunk
    /// header. Falls back to 44 when the file isn't RIFF.
    static func pcmDataOffset(_ data: Data) -> Int {
        let bytes = [UInt8](data.prefix(65_536))
        guard bytes.count >= 12, bytes[0..<4] == [0x52, 0x49, 0x46, 0x46] else { return 44 }  // "RIFF"
        var offset = 12
        while offset + 8 <= bytes.count {
            let size = bytes[offset + 4..<offset + 8].enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
            if bytes[offset..<offset + 4] == [0x64, 0x61, 0x74, 0x61] { return offset + 8 }  // "data"
            offset += 8 + size + (size & 1)
        }
        return 44
    }

    #if DEBUG
        static func selfCheck() {
            func chunk(_ id: String, _ payload: [UInt8]) -> [UInt8] {
                let n = payload.count
                return Array(id.utf8) + [UInt8(n & 0xFF), UInt8(n >> 8 & 0xFF), 0, 0] + payload
            }
            let fmt = chunk("fmt ", [UInt8](repeating: 1, count: 16))
            let plain = Array("RIFF".utf8) + [0, 0, 0, 0] + Array("WAVE".utf8) + fmt + chunk("data", [7, 0])
            assert(pcmDataOffset(Data(plain)) == 44)
            let padded = Array("RIFF".utf8) + [0, 0, 0, 0] + Array("WAVE".utf8) + fmt
                + chunk("FLLR", [UInt8](repeating: 0, count: 4044)) + chunk("data", [7, 0])
            assert(pcmDataOffset(Data(padded)) == 4096)
            assert(pcmDataOffset(Data([1, 2, 3])) == 44)

            // Same floats as the per-sample read it replaced: every Int16 value, both offsets, an odd trailing byte.
            func perSample(_ data: Data) -> [Float] {
                stride(from: pcmDataOffset(data), to: data.count - 1, by: 2).map {
                    data[$0..<$0 + 2].withUnsafeBytes {
                        max(-1.0, min(Float(Int16(littleEndian: $0.load(as: Int16.self))) / 32767.0, 1.0))
                    }
                }
            }
            let allValues = (Int(Int16.min)...Int(Int16.max)).flatMap { value -> [UInt8] in
                let bits = UInt16(bitPattern: Int16(value))
                return [UInt8(bits & 0xFF), UInt8(bits >> 8)]
            }
            for wav in [Data(plain.dropLast(2) + allValues + [9]), Data(padded.dropLast(2) + allValues)] {
                assert(samples(fromWAV: wav) == perSample(wav))
            }
            assert(samples(fromWAV: Data(plain)).count == 1 && samples(fromWAV: Data([1, 2, 3])).isEmpty)
        }
    #endif
}
