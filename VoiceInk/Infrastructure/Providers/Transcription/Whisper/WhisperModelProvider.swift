import Foundation
import SwiftData

/// Protocol that WhisperModelManager conforms to, decoupling TranscriptionServiceRegistry
/// and WhisperTranscriptionService from concrete manager types.
@MainActor
protocol WhisperModelProvider: AnyObject {
    var whisperContext: WhisperContext? { get }
    var loadedWhisperModel: WhisperModelFile? { get }
    /// The shared context holding the model named `name`, loaded once: a load already running is waited for, never
    /// repeated. `waited` is true when the caller had to wait for a load.
    func context(forModelNamed name: String) async throws -> (context: WhisperContext, waited: Bool)
}
