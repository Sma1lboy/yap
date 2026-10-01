// Stand-ins for the app types LibWhisper.swift touches, so it compiles without the app.
import Foundation

enum VoiceInkEngineError: Error { case modelLoadFailed }

final class VADModelManager {
    static let shared = VADModelManager()
    var path: String?
    func getModelPath() async -> String? { path }
}

/// SubtitleExport.swift extends the app's SwiftData model; only its segments field is touched.
final class Transcription {
    var segmentsJSON: String?
}
