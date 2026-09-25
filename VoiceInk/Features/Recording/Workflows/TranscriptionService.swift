import Foundation

struct TranscriptionRequestContext {
    let language: String?

    static var currentDefaults: TranscriptionRequestContext {
        TranscriptionRequestContext(language: UserDefaults.standard.string(forKey: "SelectedLanguage") ?? "auto")
    }
}

/// A protocol defining the interface for a transcription service.
protocol TranscriptionService {
    /// Transcribes the audio from a given file URL.
    ///
    /// - Parameters:
    ///   - audioURL: The URL of the audio file to transcribe.
    ///   - model: The `TranscriptionModel` to use for transcription. This provides context about the provider (local, OpenAI, etc.).
    /// - Returns: The transcribed text as a `String`.
    /// - Throws: An error if the transcription fails.
    func transcribe(audioURL: URL, model: any TranscriptionModel, context: TranscriptionRequestContext) async throws
        -> String
}

extension TranscriptionService {
    func transcribe(audioURL: URL, model: any TranscriptionModel) async throws -> String {
        let context = TranscriptionRequestContext.currentDefaults
        return try await transcribe(audioURL: audioURL, model: model, context: context)
    }
}
