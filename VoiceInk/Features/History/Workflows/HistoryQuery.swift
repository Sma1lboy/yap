import Foundation
import SwiftData

/// What History's Filter menu narrows the list to. Combines with the search text. yap-mcp's search_history uses
/// the same filter (HistoryQuery.swift is compiled into it), with the kind and date fields History doesn't show.
struct HistoryFilter: Equatable {
    var appBundleID: String?
    var appName: String?
    var modeName: String?
    var meetingsOnly = false
    var dictationsOnly = false
    /// Started at or after `since` and at or before `until`.
    var since: Date?
    var until: Date?

    var isActive: Bool {
        appBundleID != nil || modeName != nil || meetingsOnly || dictationsOnly || since != nil || until != nil
    }
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
    /// Unused parts are switched off by a captured Bool, since a #Predicate can't be assembled piece by piece. What
    /// and when are two predicates joined with `evaluate`: as one expression they're too big for the type checker.
    static func predicate(search: String, filter: HistoryFilter, after cursor: Cursor? = nil)
        -> Predicate<Transcription>
    {
        let hasQuery = !search.isEmpty
        let query = search
        let app: String? = filter.appBundleID
        let mode: String? = filter.modeName
        // One kind or the other: meetings have `meetingKind`, dictations nil.
        let filtersKind = filter.meetingsOnly || filter.dictationsOnly
        let kind: String? = filter.meetingsOnly ? Transcription.meetingKind : nil
        let since = filter.since ?? .distantPast
        let until = filter.until ?? .distantFuture
        let hasCursor = cursor != nil
        let cursorTimestamp = cursor?.timestamp ?? .distantFuture
        let cursorID = cursor?.id ?? UUID()

        let what = #Predicate<Transcription> { t in
            (!hasQuery || t.text.localizedStandardContains(query)
                || (t.enhancedText?.localizedStandardContains(query) ?? false))
                && (app == nil || t.sourceAppBundleID == app)
                && (mode == nil || t.modeName == mode)
                && (!filtersKind || t.kind == kind)
        }
        let when = #Predicate<Transcription> { t in
            t.timestamp >= since && t.timestamp <= until
                && (!hasCursor || t.timestamp < cursorTimestamp
                    || (t.timestamp == cursorTimestamp && t.id < cursorID))
        }
        return #Predicate<Transcription> { what.evaluate($0) && when.evaluate($0) }
    }

    /// Where `search` first occurs in `text`, by the same rule as the predicate (`localizedStandardContains`: case
    /// and diacritics ignored), with about `radius` characters on each side on one line, "…" where it's cut. nil
    /// when `text` doesn't contain it.
    static func snippet(of text: String, matching search: String, radius: Int = 80) -> String? {
        guard !search.isEmpty, let hit = text.localizedStandardRange(of: search) else { return nil }
        let start = text.index(hit.lowerBound, offsetBy: -radius, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(hit.upperBound, offsetBy: radius, limitedBy: text.endIndex) ?? text.endIndex
        let line = text[start..<end].split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return (start > text.startIndex ? "…" : "") + line + (end < text.endIndex ? "…" : "")
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
            // Same second as the cursor: only ids after it (the page is ordered by timestamp, then id, descending).
            let tie = make("tie")
            tie.timestamp = mail.timestamp
            assert((try? after.evaluate(tie)) == (tie.id < mail.id), "cursor tie")
            // An until before the cursor bounds the page, ties included; one after it leaves the cursor in charge.
            var bounded = HistoryFilter()
            bounded.until = earlier.timestamp
            let tieAtUntil = make("at until")
            tieAtUntil.timestamp = earlier.timestamp
            let page = predicate(search: "", filter: bounded, after: cursor)
            assert((try? page.evaluate(earlier)) == true && (try? page.evaluate(tieAtUntil)) == true, "until, inclusive")
            assert((try? page.evaluate(tie)) == false && (try? page.evaluate(later)) == false, "until below the cursor")
            bounded.until = later.timestamp
            let wide = predicate(search: "", filter: bounded, after: cursor)
            assert((try? wide.evaluate(earlier)) == true && (try? wide.evaluate(later)) == false, "cursor below until")

            let facets = facets(of: [mail, notes, meeting, old])
            assert(facets.apps.map(\.id) == ["com.apple.mail", "com.apple.Notes"])
            assert(facets.modes == ["Email", "Meeting"])
            assert(!HistoryFilter().isActive && f.isActive)

            // search_history's kinds and dates.
            f = HistoryFilter()
            f.dictationsOnly = true
            assert(matches(mail, "", f) && !matches(meeting, "", f), "dictations only")
            f = HistoryFilter()
            f.since = mail.timestamp.addingTimeInterval(-1)
            f.until = mail.timestamp.addingTimeInterval(1)
            let lastWeek = make("hello")
            lastWeek.timestamp = mail.timestamp.addingTimeInterval(-7 * 86_400)
            assert(matches(mail, "hello", f) && !matches(lastWeek, "hello", f), "since/until")
            f.since = nil
            assert(matches(lastWeek, "hello", f), "until alone")
            // Mixed Chinese and English, any case: the dictation said "CI", the search says "ci".
            let mixed = make("好的，我们先看一下 CI 再合并")
            assert(matches(mixed, "先看一下 ci") && matches(mixed, "看一下") && !matches(mixed, "先看一下CD"), "mixed")

            // Snippets: about 80 characters each side, cut ends marked, one line.
            let long = String(repeating: "a", count: 200) + " Needle here " + String(repeating: "b", count: 200)
            let middle = snippet(of: long, matching: "needle")!
            assert(middle.hasPrefix("…") && middle.hasSuffix("…") && middle.contains("Needle"), middle)
            assert(middle.count == 1 + 80 + "Needle".count + 80 + 1, "\(middle.count)")
            let first = snippet(of: "Needle at the start\nof two lines", matching: "NEEDLE")!
            assert(first == "Needle at the start of two lines", first)
            let last = snippet(of: String(repeating: "x", count: 100) + " ends with needle", matching: "needle")!
            assert(last.hasPrefix("…") && !last.hasSuffix("…") && last.hasSuffix("needle"), last)
            let chinese = String(repeating: "很", count: 100) + "先看一下 CI" + String(repeating: "好", count: 100)
            let hit = snippet(of: chinese, matching: "先看一下 ci")!
            assert(hit == "…" + String(repeating: "很", count: 80) + "先看一下 CI" + String(repeating: "好", count: 80) + "…", hit)
            assert(snippet(of: "abc", matching: "x") == nil && snippet(of: "abc", matching: "") == nil)

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
