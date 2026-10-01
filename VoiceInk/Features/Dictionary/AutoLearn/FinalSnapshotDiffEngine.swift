import Foundation

enum FinalSnapshotDiffEngine {
    /// The changed pasted text, for learning. Nil when it's unchanged or can't be found.
    static func revision(from snapshot: AutoLearnFieldSnapshot) -> AutoLearnRevision? {
        guard !textIsExactlyEqual(snapshot.baselineFieldText, snapshot.finalFieldText),
            let correctedText = finalPastedText(in: snapshot)
        else { return nil }
        let normalizedOriginalText = AutoLearnTextNormalizer.accessibilityComparable(
            snapshot.originalPastedText
        )
        let normalizedCorrectedText = AutoLearnTextNormalizer.accessibilityComparable(
            correctedText
        )
        guard !textIsExactlyEqual(normalizedOriginalText, normalizedCorrectedText) else {
            return nil
        }

        return AutoLearnRevision(
            original: normalizedOriginalText,
            corrected: normalizedCorrectedText
        )
    }

    /// What became of the pasted text, for the correction rate (docs/auto-learn.md):
    /// - field as it was → untouched, 0;
    /// - field empty → unobservable `fieldCleared`: a chat app empties it on send, so a send can't be told from a
    ///   deletion;
    /// - the text around the paste no longer locates it → unobservable `pastedTextNotFound`;
    /// - text only typed before or after the pasted text → untouched, 0;
    /// - pasted text gone, the text around it still there → deleted, 1;
    /// - otherwise AutoLearnEditMeasure.distance between the pasted text and what is now between its neighbours.
    static func observe(_ snapshot: AutoLearnFieldSnapshot) -> AutoLearnEditOutcome {
        if textIsExactlyEqual(snapshot.baselineFieldText, snapshot.finalFieldText) {
            return .observed(distance: 0)
        }
        if AutoLearnTextNormalizer.accessibilityComparable(snapshot.finalFieldText).isEmpty {
            return .unobservable(.fieldCleared)
        }
        guard let correctedText = finalPastedText(in: snapshot) else {
            return .unobservable(.pastedTextNotFound)
        }
        let original = AutoLearnEditMeasure.units(
            in: AutoLearnTextNormalizer.accessibilityComparable(snapshot.originalPastedText))
        let corrected = AutoLearnEditMeasure.units(in: AutoLearnTextNormalizer.accessibilityComparable(correctedText))
        if AutoLearnEditMeasure.onlyAddedAround(original: original, corrected: corrected) {
            return .observed(distance: 0)
        }
        return .observed(distance: AutoLearnEditMeasure.distance(original: original, corrected: corrected))
    }

    /// What lies, in the final field, between the text that was right before and right after the paste. Nil when the
    /// recorded paste doesn't match the baseline or its neighbours aren't found exactly once.
    private static func finalPastedText(in snapshot: AutoLearnFieldSnapshot) -> String? {
        let baseline = snapshot.baselineFieldText as NSString

        guard isValid(snapshot.pastedRange, inUTF16Length: baseline.length) else { return nil }

        let baselinePastedText = baseline.substring(with: snapshot.pastedRange)
        guard textIsExactlyEqual(baselinePastedText, snapshot.originalPastedText) else {
            return nil
        }

        let beforeRange = NSRange(location: 0, length: snapshot.pastedRange.location)
        let afterLocation = NSMaxRange(snapshot.pastedRange)
        let afterRange = NSRange(
            location: afterLocation,
            length: baseline.length - afterLocation
        )
        let beforeText = baseline.substring(with: beforeRange)
        let afterText = baseline.substring(with: afterRange)

        return correctedPastedText(
            in: snapshot.finalFieldText,
            beforeText: beforeText,
            afterText: afterText
        )
    }

    private static func correctedPastedText(
        in finalText: String,
        beforeText: String,
        afterText: String
    ) -> String? {
        let leftBoundary: String.Index
        if beforeText.isEmpty {
            leftBoundary = finalText.startIndex
        } else {
            let anchor = String(beforeText.suffix(16))
            guard let range = uniqueRange(of: anchor, in: finalText) else { return nil }
            leftBoundary = range.upperBound
        }

        let rightBoundary: String.Index
        if afterText.isEmpty {
            rightBoundary = finalText.endIndex
        } else {
            let anchor = String(afterText.prefix(16))
            guard let range = uniqueRange(of: anchor, in: finalText),
                range.lowerBound >= leftBoundary
            else { return nil }
            rightBoundary = range.lowerBound
        }

        return String(finalText[leftBoundary..<rightBoundary])
    }

    private static func uniqueRange(of value: String, in text: String) -> Range<String.Index>? {
        guard !value.isEmpty,
            let firstRange = text.range(of: value, options: .literal)
        else { return nil }

        let nextSearchStart = text.index(after: firstRange.lowerBound)
        guard nextSearchStart >= text.endIndex
            || text.range(
                of: value,
                options: .literal,
                range: nextSearchStart..<text.endIndex
            ) == nil
        else { return nil }

        return firstRange
    }

    private static func textIsExactlyEqual(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf16.elementsEqual(rhs.utf16)
    }

    private static func isValid(_ range: NSRange, inUTF16Length length: Int) -> Bool {
        range.location != NSNotFound
            && range.location >= 0
            && range.length >= 0
            && range.location <= length
            && range.length <= length - range.location
    }
}

#if DEBUG
    extension FinalSnapshotDiffEngine {
        struct Fixture {
            let name: String
            let snapshot: AutoLearnFieldSnapshot
            let expected: AutoLearnEditOutcome
            /// What learning gets from the same read: a revision with candidates, a revision without, or none.
            let learns: Bool?
        }

        /// The field held `before + pasted + after` right after the paste and `final` when the observation ended.
        private static func fixture(
            _ name: String, before: String = "", pasted: String, after: String = "", final: String,
            expected: AutoLearnEditOutcome, learns: Bool?
        ) -> Fixture {
            Fixture(
                name: name,
                snapshot: AutoLearnFieldSnapshot(
                    baselineFieldText: before + pasted + after, finalFieldText: final,
                    pastedRange: NSRange(location: before.utf16.count, length: pasted.utf16.count),
                    originalPastedText: pasted),
                expected: expected, learns: learns)
        }

        static let fixtures: [Fixture] = [
            fixture(
                "untouched", before: "Notes: ", pasted: "Ship the build on Friday.",
                final: "Notes: Ship the build on Friday.", expected: .observed(distance: 0), learns: nil),
            // Send the report to Jon tomorrow . → 7 units, 1 substituted.
            fixture(
                "one English word", pasted: "Send the report to Jon tomorrow.",
                final: "Send the report to John tomorrow.", expected: .observed(distance: 1.0 / 7), learns: true),
            // 我们下周三去杭州开会。→ 11 units, 1 substituted.
            fixture(
                "one Chinese word", pasted: "我们下周三去杭州开会。", final: "我们下周三去苏州开会。",
                expected: .observed(distance: 1.0 / 11), learns: true),
            // 用 Swift UI 写界面 → 用 SwiftUI 写界面: 6 units, Swift → SwiftUI and UI deleted.
            fixture(
                "mixed script", pasted: "用 Swift UI 写界面", final: "用 SwiftUI 写界面",
                expected: .observed(distance: 2.0 / 6), learns: true),
            // 8 units; only the final "." survives, so 7 edits. (Learning may still propose the pair; the AI rejects it.)
            fixture(
                "rewritten", pasted: "The meeting is on Friday at noon.", final: "Cancel it.",
                expected: .observed(distance: 7.0 / 8), learns: nil),
            fixture(
                "deleted, the text around it kept", before: "Hi Sam,\n", pasted: "see you at noon.", after: "\nThanks",
                final: "Hi Sam,\n\nThanks", expected: .observed(distance: 1), learns: false),
            fixture(
                "field emptied (deleted, or sent in a chat app)", pasted: "Running late", final: "",
                expected: .unobservable(.fieldCleared), learns: false),
            fixture(
                "typed after the paste", pasted: "Running ten minutes late",
                final: "Running ten minutes late, start without me", expected: .observed(distance: 0), learns: false),
            fixture(
                "typed before the paste", before: "Re: ", pasted: "我们走", final: "Re: 好的，我们走",
                expected: .observed(distance: 0), learns: nil),
            fixture(
                "spacing only", pasted: "see  you at noon", final: "see you at noon",
                expected: .observed(distance: 0), learns: false),
            fixture(
                "the text around it changed too", before: "Dear team, ", pasted: "the release is today.",
                after: " Best, Ann", final: "Hello all — the release is today. Regards",
                expected: .unobservable(.pastedTextNotFound), learns: nil),
        ]

        static func selfCheck() {
            for fixture in fixtures {
                let outcome = observe(fixture.snapshot)
                switch (outcome, fixture.expected) {
                case let (.observed(distance), .observed(expected)):
                    assert(abs(distance - expected) < 1e-9, "\(fixture.name): distance \(distance), expected \(expected)")
                default:
                    assert(outcome == fixture.expected, "\(fixture.name): \(outcome), expected \(fixture.expected)")
                }
                // Learning reads the same snapshot as before: a revision when the normalized text differs.
                let revision = revision(from: fixture.snapshot)
                switch fixture.learns {
                case .some(true):
                    assert(revision.map { !CorrectionDiffEngine.candidates(from: $0).isEmpty } == true, fixture.name)
                case .some(false):
                    assert(revision.map { CorrectionDiffEngine.candidates(from: $0).isEmpty } ?? true, fixture.name)
                case nil:
                    break
                }
            }

            assert(AutoLearnEditMeasure.units(in: "Don't e-mail me, 好吗?") == ["Don't", "e-mail", "me", ",", "好", "吗", "?"])
            assert(AutoLearnEditMeasure.distance(original: [], corrected: []) == 0)
            // Past the comparison cap the edit count is the longer side, never more than 1 after dividing.
            let long = (0..<2_100).map { Substring("w\($0)") }
            let other = (0..<2_100).map { Substring("x\($0)") }
            assert(AutoLearnEditMeasure.distance(original: long, corrected: other) == 1)
        }
    }
#endif
