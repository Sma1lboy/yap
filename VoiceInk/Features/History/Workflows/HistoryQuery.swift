import Foundation
import SwiftData

/// What History's Filter menu narrows the list to. Combines with the search text.
struct HistoryFilter: Equatable {
    var appBundleID: String?
    var appName: String?
    var modeName: String?
    var meetingsOnly = false

    var isActive: Bool { appBundleID != nil || modeName != nil || meetingsOnly }
}

enum HistorySort: CaseIterable, Identifiable {
    case newest, oldest, longest, mostWords

    /// The choice lasts until the app quits; HistoryView starts from it each time it appears.
    static var remembered = HistorySort.newest

    var id: Self { self }

    /// Newest and oldest read as a timeline, so the list keeps its day headers; the others don't.
    var groupsByDay: Bool { self == .newest || self == .oldest }

    var title: String {
        switch self {
        case .newest: String(localized: "Newest")
        case .oldest: String(localized: "Oldest")
        case .longest: String(localized: "Longest")
        case .mostWords: String(localized: "Most Words")
        }
    }
}

enum HistoryQuery {
    /// Orders `items` for the non-default sorts (Newest pages straight from the database). Ties fall back to newest
    /// first, then id, so a page boundary never repeats or skips a row.
    static func sorted(
        _ items: [Transcription], by sort: HistorySort,
        wordCount: (Transcription) -> Int = { WordCounter.count(in: $0.enhancedText ?? $0.text) }
    ) -> [Transcription] {
        let keyed = items.map { (item: $0, words: sort == .mostWords ? wordCount($0) : 0) }
        return keyed.sorted { a, b in
            switch sort {
            case .newest: break
            case .oldest: if a.item.timestamp != b.item.timestamp { return a.item.timestamp < b.item.timestamp }
            case .longest: if a.item.duration != b.item.duration { return a.item.duration > b.item.duration }
            case .mostWords: if a.words != b.words { return a.words > b.words }
            }
            if a.item.timestamp != b.item.timestamp { return a.item.timestamp > b.item.timestamp }
            return a.item.id.uuidString > b.item.id.uuidString
        }.map(\.item)
    }

    struct Cursor {
        let timestamp: Date
        let id: UUID
    }

    /// Search text, filter and (for the next page) the position after `cursor` in one predicate.
    /// Unused parts are switched off by a captured Bool, since a #Predicate can't be assembled piece by piece.
    static func predicate(search: String, filter: HistoryFilter, after cursor: Cursor? = nil)
        -> Predicate<Transcription>
    {
        let hasQuery = !search.isEmpty
        let query = search
        let app: String? = filter.appBundleID
        let mode: String? = filter.modeName
        let meetingKind: String? = filter.meetingsOnly ? Transcription.meetingKind : nil
        let hasCursor = cursor != nil
        let cursorTimestamp = cursor?.timestamp ?? .distantFuture
        let cursorID = cursor?.id ?? UUID()

        return #Predicate<Transcription> { t in
            (!hasQuery || t.text.localizedStandardContains(query)
                || (t.enhancedText?.localizedStandardContains(query) ?? false))
                && (app == nil || t.sourceAppBundleID == app)
                && (mode == nil || t.modeName == mode)
                && (meetingKind == nil || t.kind == meetingKind)
                && (!hasCursor || t.timestamp < cursorTimestamp
                    || (t.timestamp == cursorTimestamp && t.id < cursorID))
        }
    }

    /// Apps and modes that appear in `items`, for the Filter menu. Apps are keyed by bundle id.
    static func facets(of items: [Transcription]) -> (apps: [(id: String, name: String)], modes: [String]) {
        var apps: [String: String] = [:]
        var modes = Set<String>()
        for item in items {
            if let id = item.sourceAppBundleID, !id.isEmpty {
                apps[id] = item.sourceAppName?.isEmpty == false ? item.sourceAppName : id
            }
            if let mode = item.modeName, !mode.isEmpty { modes.insert(mode) }
        }
        return (
            apps.map { (id: $0.key, name: $0.value) }.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            },
            modes.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        )
    }

    static func facets(in context: ModelContext) -> (apps: [(id: String, name: String)], modes: [String]) {
        var descriptor = FetchDescriptor<Transcription>()
        descriptor.propertiesToFetch = [\.sourceAppBundleID, \.sourceAppName, \.modeName]
        return facets(of: (try? context.fetch(descriptor)) ?? [])
    }
}

#if DEBUG
    extension HistoryQuery {
        static func selfCheck() {
            func make(_ text: String, app: String? = nil, mode: String? = nil, meeting: Bool = false) -> Transcription {
                let t = Transcription(text: text, duration: 1, modeName: mode)
                t.sourceAppBundleID = app
                t.sourceAppName = app.map { String($0.split(separator: ".").last ?? "") }
                t.kind = meeting ? Transcription.meetingKind : nil
                return t
            }
            func matches(_ t: Transcription, _ search: String = "", _ filter: HistoryFilter = HistoryFilter()) -> Bool {
                (try? predicate(search: search, filter: filter).evaluate(t)) ?? false
            }

            let mail = make("hello team", app: "com.apple.mail", mode: "Email")
            let notes = make("buy milk", app: "com.apple.Notes")
            let meeting = make("standup", mode: "Meeting", meeting: true)
            let old = make("hello again")

            assert(matches(mail) && matches(old), "no filter matches everything")
            assert(matches(mail, "hello") && !matches(notes, "hello"), "search")

            var f = HistoryFilter()
            f.appBundleID = "com.apple.mail"
            assert(matches(mail, "", f) && !matches(notes, "", f) && !matches(old, "", f), "app filter")
            assert(matches(mail, "hello", f) && !matches(old, "hello", f), "app filter combines with search")

            f = HistoryFilter()
            f.modeName = "Email"
            assert(matches(mail, "", f) && !matches(notes, "", f), "mode filter")

            f = HistoryFilter()
            f.meetingsOnly = true
            assert(matches(meeting, "", f) && !matches(mail, "", f), "meetings only")
            f.modeName = "Email"
            assert(!matches(meeting, "", f), "filters combine with AND")

            let cursor = Cursor(timestamp: mail.timestamp, id: mail.id)
            let earlier = make("earlier")
            earlier.timestamp = mail.timestamp.addingTimeInterval(-60)
            let later = make("later")
            later.timestamp = mail.timestamp.addingTimeInterval(60)
            let after = predicate(search: "", filter: HistoryFilter(), after: cursor)
            assert((try? after.evaluate(earlier)) == true && (try? after.evaluate(later)) == false, "cursor")

            let facets = facets(of: [mail, notes, meeting, old])
            assert(facets.apps.map(\.id) == ["com.apple.mail", "com.apple.Notes"])
            assert(facets.modes == ["Email", "Meeting"])
            assert(!HistoryFilter().isActive && f.isActive)

            let base = Date()
            func item(_ text: String, seconds: TimeInterval, age: TimeInterval) -> Transcription {
                let t = Transcription(text: text, duration: seconds)
                t.timestamp = base.addingTimeInterval(-age)
                return t
            }
            let a = item("one two", seconds: 30, age: 300)
            let b = item("one two three four five", seconds: 10, age: 200)
            let c = item("one", seconds: 20, age: 100)
            let d = item("one", seconds: 20, age: 50)  // ties with c on duration; newer
            let all = [a, b, c, d]
            func order(_ sort: HistorySort) -> [String] { sorted(all, by: sort).map(\.text) }
            assert(order(.newest) == ["one", "one", "one two three four five", "one two"])
            assert(sorted(all, by: .newest).first === d && sorted(all, by: .oldest).first === a, "newest/oldest")
            assert(sorted(all, by: .longest).map { $0.duration } == [30, 20, 20, 10], "longest")
            assert(sorted(all, by: .longest)[1] === d, "duration tie: newer first")
            assert(sorted(all, by: .mostWords).first === b && sorted(all, by: .mostWords)[1] === a, "most words")
            assert(sorted(all, by: .mostWords)[2] === d, "word tie: newer first")
            assert(sorted([], by: .longest).isEmpty)
        }
    }
#endif
