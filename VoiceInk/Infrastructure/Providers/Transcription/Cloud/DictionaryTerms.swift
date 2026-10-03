import Foundation
import SwiftData

/// The Dictionary's words as cloud transcription requests send them: trimmed, blanks dropped, one per spelling
/// ignoring case, most recently added first (words added at the same moment by spelling). Requests that take at
/// most N terms (Deepgram, OpenRouter and Yap Cloud's hint fields, xAI) send the first N, so a word just added is
/// sent and the oldest are the ones left out, as local Whisper's prompt does; the rest take the whole list.
/// Read for each request, so a word added or deleted counts from the next one.
enum DictionaryTerms {
    static func newestFirst(in context: ModelContext) -> [String] {
        let words = (try? context.fetch(FetchDescriptor<VocabularyWord>())) ?? []
        return newestFirst(words.map { ($0.word, $0.dateAdded) })
    }

    static func newestFirst(_ words: [(word: String, dateAdded: Date)]) -> [String] {
        let trimmed: [(word: String, dateAdded: Date)] = words.map {
            ($0.word.trimmingCharacters(in: .whitespacesAndNewlines), $0.dateAdded)
        }
        let ordered = trimmed.sorted { lhs, rhs in
            lhs.dateAdded != rhs.dateAdded ? lhs.dateAdded > rhs.dateAdded : lhs.word < rhs.word
        }
        var seen = Set<String>()
        return ordered.map(\.word).filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    #if DEBUG
        static func selfCheck() {
            let start = Date(timeIntervalSince1970: 1_800_000_000)
            func at(_ seconds: Double) -> Date { start.addingTimeInterval(seconds) }

            // Over 100: the word added last is in the first 100, the oldest is the one out.
            let many = (0..<100).map { (word: String(format: "A%03d", $0), dateAdded: at(Double($0))) }
                + [(word: "ZNewestName", dateAdded: at(1_000))]
            let first100 = Array(newestFirst(many).prefix(100))
            assert(first100.first == "ZNewestName" && first100.last == "A001" && !first100.contains("A000"))

            // Trimmed, blanks out, the newest spelling of a case duplicate kept as typed; CJK and mixed words whole.
            let small: [(word: String, dateAdded: Date)] = [
                (" Kubernetes ", at(1)), ("张三丰", at(2)), ("kubernetes\n", at(3)), ("  ", at(4)), ("useEffect", at(5)),
                ("React组件", at(2)),
            ]
            assert(newestFirst(small) == ["useEffect", "kubernetes", "React组件", "张三丰"])
            assert(newestFirst([]) == [])

            // Same date: by spelling, whatever order the store returns them in.
            let sameDate = (0..<101).map { (word: String(format: "W%03d", $0), dateAdded: start) }
            assert(newestFirst(sameDate) == newestFirst(sameDate.reversed()))
            assert(newestFirst(sameDate).prefix(100).last == "W099")
            assert(newestFirst([("kubernetes", start), ("Kubernetes", start)]) == ["Kubernetes"])
        }
    #endif
}
