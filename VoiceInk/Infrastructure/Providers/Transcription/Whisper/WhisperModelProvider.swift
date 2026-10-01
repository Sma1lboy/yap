import Foundation
import SwiftData

/// Protocol that WhisperModelManager conforms to, decoupling TranscriptionServiceRegistry
/// and WhisperTranscriptionService from concrete manager types.
@MainActor
protocol WhisperModelProvider: AnyObject {
    var whisperContext: WhisperContext? { get }
    var loadedWhisperModel: WhisperModelFile? { get }
    /// Runs `body` on the shared context holding the model named `name`, in its turn: nothing frees or replaces that
    /// context until `body` returns. `loaded` is true when the model had to be loaded (or a load waited for).
    nonisolated func withContext<T>(
        named name: String, _ body: (_ context: WhisperContext, _ loaded: Bool) async throws -> T
    ) async throws -> T
}
