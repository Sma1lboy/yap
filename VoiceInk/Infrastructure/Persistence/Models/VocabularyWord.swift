import Foundation
import SwiftData

@Model
final class VocabularyWord {
    var word: String = ""
    var dateAdded: Date = Date()
    /// Added by Auto Learn rather than typed in; drives the Dictionary's Auto-added / Manually added filter.
    var isAutoLearned: Bool = false

    init(word: String, dateAdded: Date = Date()) {
        self.word = word
        self.dateAdded = dateAdded
    }
}
