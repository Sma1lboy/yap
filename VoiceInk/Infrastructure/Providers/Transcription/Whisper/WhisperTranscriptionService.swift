import AVFoundation
import Foundation
import SwiftData
import os

class WhisperTranscriptionService: TranscriptionService {

    private var whisperContext: WhisperContext?
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "WhisperTranscriptionService")
    private let modelsDirectory: URL
    private weak var modelProvider: (any WhisperModelProvider)?
    /// Source of dictionary words for the prompt; nil (warmup) means no dictionary.
    private let modelContext: ModelContext?

    init(modelsDirectory: URL, modelProvider: (any WhisperModelProvider)? = nil, modelContext: ModelContext? = nil) {
        self.modelsDirectory = modelsDirectory
        self.modelProvider = modelProvider
        self.modelContext = modelContext
    }

    func transcribe(audioURL: URL, model: any TranscriptionModel, context: TranscriptionRequestContext) async throws
        -> String
    {
        guard model.provider == .whisper else {
            throw VoiceInkEngineError.modelLoadFailed
        }

        logger.notice("Initiating local transcription for model: \(model.displayName, privacy: .public)")

        // Check if the required model is already loaded in the model provider
        if let provider = modelProvider,
            await provider.isModelLoaded,
            let loadedContext = await provider.whisperContext,
            await provider.loadedWhisperModel?.name == model.name
        {

            logger.notice("Using already loaded model: \(model.name, privacy: .public)")
            whisperContext = loadedContext
        } else {
            // Resolve the on-disk URL using the provider's availableModels (covers imports)
            let resolvedURL: URL? = await modelProvider?.availableModels.first(where: { $0.name == model.name })?.url
            guard let modelURL = resolvedURL, FileManager.default.fileExists(atPath: modelURL.path) else {
                logger.error("❌ Model file not found for: \(model.name, privacy: .public)")
                throw VoiceInkEngineError.modelLoadFailed
            }

            logger.notice("Loading model: \(model.name, privacy: .public)")
            do {
                whisperContext = try await WhisperContext.createContext(path: modelURL.path)
            } catch {
                logger.error("❌ Failed to load model: \(model.name, privacy: .public) - \(error, privacy: .public)")
                throw VoiceInkEngineError.modelLoadFailed
            }
        }

        guard let whisperContext = whisperContext else {
            logger.error("❌ Cannot transcribe: Model could not be loaded")
            throw VoiceInkEngineError.modelLoadFailed
        }

        // Read audio data
        let data = try readAudioSamples(audioURL)

        // Set prompt
        await whisperContext.setLanguage(context.language)
        await whisperContext.setPrompt(
            WhisperPrompt.withVocabulary(context.prompt ?? "", words: await dictionaryWords()))

        // Transcribe
        let success = await whisperContext.fullTranscribe(samples: data)

        guard success else {
            logger.error("❌ Core transcription engine failed (whisper_full).")
            throw VoiceInkEngineError.whisperCoreFailed
        }

        let text = await whisperContext.getTranscription()

        logger.notice("Whisper transcription completed successfully.")

        // Only release resources if we created a new context (not using the shared one)
        if await modelProvider?.whisperContext !== whisperContext {
            await whisperContext.releaseResources()
            self.whisperContext = nil
        }

        return text
    }

    private func dictionaryWords() async -> [(word: String, dateAdded: Date)] {
        guard let modelContext else { return [] }
        return await MainActor.run {
            ((try? modelContext.fetch(FetchDescriptor<VocabularyWord>())) ?? []).map { ($0.word, $0.dateAdded) }
        }
    }

    private func readAudioSamples(_ url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        let floats = stride(from: Self.pcmDataOffset(data), to: data.count - 1, by: 2).map {
            return data[$0..<$0 + 2].withUnsafeBytes {
                let short = Int16(littleEndian: $0.load(as: Int16.self))
                return max(-1.0, min(Float(short) / 32767.0, 1.0))
            }
        }
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
        }
    #endif
}
