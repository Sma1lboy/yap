import Foundation

enum AutoLearnTextNormalizer {
    /// Produces a comparison-only representation of text exposed by editable
    /// web controls. The original field value remains untouched for anchoring.
    static func accessibilityComparable(_ text: String) -> String {
        let normalizedLineEndings = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\u{200B}", with: "")

        let normalizedBlankLines = normalizedLineEndings
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                let value = String(line)
                return value.trimmingCharacters(in: .whitespaces).isEmpty ? "" : value
            }
            .joined(separator: "\n")

        return normalizedBlankLines
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
    }
}

struct AutoLearnPasteToken: Hashable, Sendable {
    let id: UUID
}

struct AutoLearnRevision: Sendable {
    let original: String
    let corrected: String
}

struct AutoLearnFieldSnapshot: Sendable {
    let baselineFieldText: String
    let finalFieldText: String
    let pastedRange: NSRange
    let originalPastedText: String
}

struct DetectedCorrectionCandidate: Hashable, Sendable {
    let originalText: String
    let correctedText: String
}

struct AutoLearnReviewCandidate: Sendable {
    let candidateID: UUID
    let originalText: String
    let correctedText: String
}

enum AutoLearnReviewAction: String, Codable, Sendable {
    case addReplacementAndVocabulary
    case addReplacementOnly
    case addVocabularyOnly
    case rejectCorrection
}

struct AutoLearnReviewDecision: Sendable {
    let candidateID: UUID
    let learningAction: AutoLearnReviewAction
    let incorrectTextToReplace: String?
    let correctedVocabularyTerm: String?
}

enum AutoLearnUnresolvedReason: String, Sendable {
    case missingDecision
    case conflictingDecisions
    case missingRequiredActionValues
    case invalidRequiredActionValues
}

struct AutoLearnUnresolvedReview: Sendable {
    let candidateID: UUID
    let reason: AutoLearnUnresolvedReason
    let learningAction: AutoLearnReviewAction?
    let incorrectTextToReplace: String?
    let correctedVocabularyTerm: String?
}

struct AutoLearnReviewResult: Sendable {
    let reviewDecisions: [AutoLearnReviewDecision]
    let unresolvedReviews: [AutoLearnUnresolvedReview]
}

struct AutoLearnReviewProposal: Codable, Identifiable, Sendable {
    let id: UUID
    let candidateID: UUID
    let originalText: String
    let correctedText: String
    let learningAction: AutoLearnReviewAction
    let incorrectTextToReplace: String?
    let correctedVocabularyTerm: String?

    var addsReplacement: Bool {
        learningAction == .addReplacementAndVocabulary || learningAction == .addReplacementOnly
    }

    var addsVocabulary: Bool {
        learningAction == .addReplacementAndVocabulary || learningAction == .addVocabularyOnly
    }

    var reviewCandidate: AutoLearnReviewCandidate {
        AutoLearnReviewCandidate(
            candidateID: candidateID,
            originalText: originalText,
            correctedText: correctedText
        )
    }

    var reviewDecision: AutoLearnReviewDecision {
        AutoLearnReviewDecision(
            candidateID: candidateID,
            learningAction: learningAction,
            incorrectTextToReplace: incorrectTextToReplace,
            correctedVocabularyTerm: correctedVocabularyTerm
        )
    }
}

struct AutoLearnReviewSelection: Sendable {
    let proposalID: UUID
    let includesReplacement: Bool
    let includesVocabulary: Bool
    let incorrectTextToReplace: String?
    let correctedVocabularyTerm: String
}

struct AutoLearnMutationSummary: Sendable {
    let createdCount: Int
    let updatedCount: Int
    let vocabularyCount: Int
    let learnedCorrections: [AutoLearnAppliedCorrection]

    var hasChanges: Bool {
        createdCount > 0 || updatedCount > 0 || vocabularyCount > 0
    }

    static let empty = AutoLearnMutationSummary(
        createdCount: 0,
        updatedCount: 0,
        vocabularyCount: 0,
        learnedCorrections: []
    )
}

struct AutoLearnAppliedCorrection: Codable, Hashable, Sendable {
    let incorrectTextToReplace: String
    let correctedVocabularyTerm: String
    let replacementSourceWasAdded: Bool
    let vocabularyCreationDate: Date?
    /// The edit it was learned from: the pasted words around the change, and what the user made of them
    /// (AutoLearnReviewCandidate, at most a few words either side).
    let sourceOriginal: String
    let sourceCorrected: String
}

extension AutoLearnAppliedCorrection {
    /// “heard” → “meant”, or “term” when only the vocabulary entry was added.
    var displayPair: String {
        replacementSourceWasAdded
            ? String(localized: "“\(incorrectTextToReplace)” → “\(correctedVocabularyTerm)”")
            : String(localized: "“\(correctedVocabularyTerm)”")
    }
}

/// A rule Auto Learn added, kept for the Dictionary's Recently Learned list (AutoLearnLearnedLog).
struct AutoLearnLearnedEntry: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let learnedAt: Date
    let correction: AutoLearnAppliedCorrection
}

enum AutoLearnReviewSchedule: String, CaseIterable, Identifiable {
    case immediately
    case manually

    var id: String { rawValue }

    var title: String {
        switch self {
        case .immediately: String(localized: "Immediately")
        case .manually: String(localized: "Manually")
        }
    }

}

enum AutoLearnLimits {
    static let observationDurationNanoseconds: UInt64 = 60_000_000_000
    static let verificationDelayNanoseconds: UInt64 = 120_000_000
    static let focusChangeGraceNanoseconds: UInt64 = 250_000_000
    static let accessibilityTimeoutSeconds: Float = 0.20
    static let captureAccessibilityTimeoutSeconds: Float = 0.10
    static let maximumFieldUTF16Length = 100_000
    static let maximumPastedCharacters = 12_000
    static let maximumDiffSegments = 2_048
    static let maximumCandidateCharacters = 256
    static let maximumCandidateSegments = 24
    static let reviewContextSegmentsPerSide = 3
    static let maximumUnspacedCandidateCharacters = 32
    static let maximumReviewBatchCandidates = 100
}

/// Why Auto Learn couldn't watch a paste (or read the field at the end). Nothing from the field is kept; only how often
/// each reason happened, in UserDefaults, on this Mac (docs/auto-learn.md).
enum AutoLearnUnobservableReason: String, CaseIterable {
    case accessibilityNotTrusted
    case targetIsYap
    case emptyPaste
    case pasteTooLong
    /// Secure keyboard entry is on (a password field has focus somewhere, or Terminal's Secure Keyboard Entry).
    case secureInput
    /// The field reports the secure-text-field role or subrole (native and web password fields).
    case secureField
    /// More than AutoLearnLimits.maximumFieldUTF16Length characters.
    case fieldTooLong
    case noReadableField
    case pastedTextNotFound
    /// The field was empty at the end. A chat app empties it on send, so a send can't be told from a deletion.
    case fieldCleared
    /// Finish and Send was about to press its key right after the paste, so watching stopped. Recorded before the key's
    /// last target check: the key may then not have gone out (CursorPaster.submit). Not a confirmation it was sent.
    case autoSent
}

struct AutoLearnUnobservableError: Error {
    let reason: AutoLearnUnobservableReason
}

enum AutoLearnUnobservableCounts {
    static let defaultsKey = "AutoLearnUnobservableCounts"

    static func record(_ reason: AutoLearnUnobservableReason, defaults: UserDefaults = .standard) {
        var counts = defaults.dictionary(forKey: defaultsKey) as? [String: Int] ?? [:]
        counts[reason.rawValue, default: 0] += 1
        defaults.set(counts, forKey: defaultsKey)
    }

    static func all(defaults: UserDefaults = .standard) -> [AutoLearnUnobservableReason: Int] {
        let counts = defaults.dictionary(forKey: defaultsKey) as? [String: Int] ?? [:]
        return Dictionary(uniqueKeysWithValues: counts.compactMap { key, value in
            AutoLearnUnobservableReason(rawValue: key).map { ($0, value) }
        })
    }
}

enum AutoLearnProviderPolicy {
    static func isSupported(_ provider: AIProvider) -> Bool {
        provider.supportsEnhancement
            && provider != .voiceInkRefine
    }
}
