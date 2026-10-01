import AVFoundation
import Foundation
import SwiftData
import os

class WhisperTranscriptionService: TranscriptionService {

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "WhisperTranscriptionService")
    private let modelsDirectory: URL
    private weak var modelProvider: (any WhisperModelProvider)?
    /// Source of dictionary words for the prompt; nil means no dictionary.
    private let modelContext: ModelContext?
    /// The last transcription's timed segments (seconds from the start of the audio), for subtitle export.
    private(set) var lastSegments: [TimedSegment] = []

    init(modelsDirectory: URL, modelProvider: (any WhisperModelProvider)? = nil, modelContext: ModelContext? = nil) {
        self.modelsDirectory = modelsDirectory
        self.modelProvider = modelProvider
        self.modelContext = modelContext
    }

    func transcribe(audioURL: URL, model: any TranscriptionModel, context: TranscriptionRequestContext) async throws
        -> String
    {
        lastSegments = []
        guard model.provider == .whisper, let modelProvider else {
            throw VoiceInkEngineError.modelLoadFailed
        }

        logger.notice("Initiating local transcription for model: \(model.displayName, privacy: .public)")

        // The shared context: the preload the shortcut press started is waited for, never loaded a second time.
        let whisperContext: WhisperContext
        do {
            let ready = try await modelProvider.context(forModelNamed: model.name)
            whisperContext = ready.context
            if ready.waited { DictationTimeline.modelDidLoad() }
        } catch {
            logger.error("❌ Failed to load model: \(model.name, privacy: .public) - \(error, privacy: .public)")
            throw VoiceInkEngineError.modelLoadFailed
        }

        let data = try Self.readAudioSamples(audioURL)

        await whisperContext.setLanguage(context.language)
        await whisperContext.setPrompt(
            WhisperPrompt.withVocabulary(context.prompt ?? "", words: await dictionaryWords()))

        let success = await whisperContext.fullTranscribe(samples: data)

        guard success else {
            logger.error("❌ Core transcription engine failed (whisper_full).")
            throw VoiceInkEngineError.whisperCoreFailed
        }

        let text = await whisperContext.getTranscription()
        lastSegments = await whisperContext.getSegments()

        logger.notice("Whisper transcription completed successfully.")
        return text
    }

    private func dictionaryWords() async -> [(word: String, dateAdded: Date)] {
        guard let modelContext else { return [] }
        return await MainActor.run {
            ((try? modelContext.fetch(FetchDescriptor<VocabularyWord>())) ?? []).map { ($0.word, $0.dateAdded) }
        }
    }

    static func readAudioSamples(_ url: URL) throws -> [Float] {
        samples(fromWAV: try Data(contentsOf: url))
    }

    /// 16-bit PCM from `pcmDataOffset` on, scaled to -1...1. One pass over the bytes: slicing `Data` per sample took
    /// 8 ms for an 8 s recording, between the stop and the decode.
    static func samples(fromWAV data: Data) -> [Float] {
        let start = pcmDataOffset(data)
        let count = max(0, (data.count - start) / 2)
        return data.withUnsafeBytes { raw in
            (0..<count).map { index in
                let short = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: start + 2 * index, as: Int16.self))
                return max(-1.0, min(Float(short) / 32767.0, 1.0))
            }
        }
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
