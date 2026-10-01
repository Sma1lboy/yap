import Foundation

/// What Auto Learn saw become of a pasted dictation by the end of its observation. Recorded on the dictation's
/// SessionMetric, on this Mac only (docs/auto-learn.md, "Correction rate").
enum AutoLearnEditOutcome: Equatable, Sendable {
    /// Nothing can be said about this paste: the field was refused or unreadable, or the pasted text couldn't be found.
    case unobservable(AutoLearnUnobservableReason)
    /// Watched to the end. `distance` is AutoLearnEditMeasure.distance: 0 untouched, 1 deleted or entirely rewritten.
    case observed(distance: Double)

    var changed: Bool? {
        guard case .observed(let distance) = self else { return nil }
        return distance > 0
    }
}

/// How much of the pasted text the user changed, in units that work for spaced and unspaced scripts alike.
enum AutoLearnEditMeasure {
    /// Above this many unit pairs in the part that differs (about 2,000 × 2,000), the edit count is taken as the
    /// longer side's length instead of computed: the most it can be, so such an edit reads as a full rewrite.
    static let maximumComparedPairs = 4_000_000

    /// The units an edit is counted in:
    /// - each Han, kana, Hangul, Thai, Lao, Myanmar or Khmer character (scripts written without spaces);
    /// - each word: a run of letters and digits, apostrophes, hyphens and underscores between them included;
    /// - each other character (punctuation, symbols, emoji).
    /// Whitespace separates units and isn't one, so spacing-only edits don't count.
    static func units(in text: String) -> [Substring] {
        var units: [Substring] = []
        var wordStart: String.Index?
        var index = text.startIndex

        func endWord(at end: String.Index) {
            guard let start = wordStart else { return }
            units.append(text[start..<end])
            wordStart = nil
        }

        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if character.isWhitespace {
                endWord(at: index)
            } else if character.unicodeScalars.first.map(CorrectionDiffEngine.isCompactScriptScalar) == true {
                endWord(at: index)
                units.append(text[index..<next])
            } else if character.isLetter || character.isNumber {
                if wordStart == nil { wordStart = index }
            } else if wordStart != nil, "'’-_".contains(character), next < text.endIndex,
                text[next].isLetter || text[next].isNumber
            {
                // Inside a word: don't, e-mail, snake_case.
            } else {
                endWord(at: index)
                units.append(text[index..<next])
            }
            index = next
        }
        endWord(at: text.endIndex)
        return units
    }

    /// Levenshtein distance over `units` (insert, delete, substitute: 1 each), divided by the longer side's unit count.
    /// 0 when both are empty.
    static func distance(original: [Substring], corrected: [Substring]) -> Double {
        let longest = max(original.count, corrected.count)
        guard longest > 0 else { return 0 }
        return Double(editCount(original, corrected)) / Double(longest)
    }

    /// `corrected` still holds every unit of `original`, in order and next to each other: whatever changed was only
    /// added before or after the pasted text (the user kept typing), which isn't an edit of it.
    static func onlyAddedAround(original: [Substring], corrected: [Substring]) -> Bool {
        guard !original.isEmpty else { return true }
        guard corrected.count >= original.count else { return false }
        for start in 0...(corrected.count - original.count)
        where corrected[start..<(start + original.count)].elementsEqual(original) {
            return true
        }
        return false
    }

    private static func editCount(_ a: [Substring], _ b: [Substring]) -> Int {
        // Edits are usually local: compare only what lies between the common start and end.
        var start = 0
        while start < a.count, start < b.count, a[start] == b[start] { start += 1 }
        var endA = a.count
        var endB = b.count
        while endA > start, endB > start, a[endA - 1] == b[endB - 1] {
            endA -= 1
            endB -= 1
        }
        let middleA = a[start..<endA]
        let middleB = b[start..<endB]
        guard !middleA.isEmpty, !middleB.isEmpty else { return max(middleA.count, middleB.count) }
        guard middleA.count * middleB.count <= maximumComparedPairs else { return max(middleA.count, middleB.count) }

        var ids: [Substring: Int] = [:]
        func id(_ unit: Substring) -> Int {
            if let known = ids[unit] { return known }
            ids[unit] = ids.count
            return ids.count - 1
        }
        let x = middleA.map(id)
        let y = middleB.map(id)

        var previous = Array(0...y.count)
        var current = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            current[0] = i
            for j in 1...y.count {
                let substitution = previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1)
                current[j] = min(substitution, previous[j] + 1, current[j - 1] + 1)
            }
            swap(&previous, &current)
        }
        return previous[y.count]
    }
}
