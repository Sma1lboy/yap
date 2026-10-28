import Foundation
import SwiftData

@MainActor
final class CustomVocabularyService {
    static let shared = CustomVocabularyService()

    private init() {}

    /// Saved words in DictionaryTerms' order (newest first), so providers that cap their hints drop the oldest.
    func loadSavedVocabulary(from context: ModelContext) -> RecordingVocabulary {
        RecordingVocabulary(savedTerms: DictionaryTerms.newestFirst(in: context))
    }
}
