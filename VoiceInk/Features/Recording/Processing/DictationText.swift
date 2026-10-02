import Foundation
import SwiftData

/// The rule-based text steps a dictation goes through between recognition and AI enhancement, in the order the
/// pipeline runs them. `make text-fidelity-check` runs these same functions on fixed text and prints each step.
///
/// Between `clean` and `finish` the pipeline checks for a whole-transcript hallucination, trims, and applies
/// trigger words, which choose the mode `finish` gets its paragraph setting from.
enum DictationText {
    enum Step: String {
        case filter, chineseCleanup, paragraphs, replacements
    }

    /// Right after recognition: annotations and the user's English filler words out, then the Chinese cleanup.
    static func clean(_ text: String, chinese: ChineseCleanup.Options, step: ((Step, String) -> Void)? = nil) -> String {
        let filtered = TranscriptionOutputFilter.filter(text)
        step?(.filter, filtered)
        let cleaned = ChineseCleanup.apply(filtered, options: chinese)
        step?(.chineseCleanup, cleaned)
        return cleaned
    }

    /// Once the mode is known: paragraphs when the mode turns them on, then the user's word replacements.
    @MainActor
    static func finish(
        _ text: String, paragraphs: Bool, replacementsIn context: ModelContext, step: ((Step, String) -> Void)? = nil
    ) -> String {
        var text = text
        if paragraphs {
            text = ParagraphFormatter.format(text)
            step?(.paragraphs, text)
        }
        text = WordReplacementService.shared.applyReplacements(to: text, using: context)
        step?(.replacements, text)
        return text
    }
}
