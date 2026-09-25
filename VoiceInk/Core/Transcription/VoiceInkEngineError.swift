import Foundation

enum VoiceInkEngineError: Error, Identifiable {
    case transcriptionFailed

    var id: String { UUID().uuidString }
}

extension VoiceInkEngineError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .transcriptionFailed:
            return String(localized: "Failed to transcribe the audio.")
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .transcriptionFailed:
            return String(
                localized: "Check the default model try again. If the problem persists, try a different model.")
        }
    }
}
