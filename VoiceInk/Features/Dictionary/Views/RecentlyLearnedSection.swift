import SwiftData
import SwiftUI

/// Dictionary › Recently Learned: the rules Auto Learn added in the last week (AutoLearnLearnedLog), each with the
/// edit it came from and an Undo that takes it back out of the dictionary.
struct RecentlyLearnedSection: View {
    @Query private var replacements: [WordReplacement]
    @Query private var vocabulary: [VocabularyWord]
    @AppStorage(AutoLearnSettings.isEnabledKey) private var isAutoLearnEnabled = true
    @State private var entries: [AutoLearnLearnedEntry] = []
    let onOpenSettings: () -> Void

    #if DEBUG
        /// ui-snapshots: these instead of the log on disk.
        static var snapshotEntries: [AutoLearnLearnedEntry]?
    #endif

    init(onOpenSettings: @escaping () -> Void) {
        self.onOpenSettings = onOpenSettings
        #if DEBUG
            _entries = State(initialValue: Self.snapshotEntries ?? [])
        #endif
    }

    /// Entries whose rule is still there; one removed from the list by hand isn't shown.
    private var shownEntries: [AutoLearnLearnedEntry] {
        let rules = replacements.map { (originalText: $0.originalText, replacementText: $0.replacementText) }
        let words = vocabulary.map(\.word)
        return entries.filter { Self.isInDictionary($0.correction, replacements: rules, vocabulary: words) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.x3) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.x1) {
                Text("Recently Learned")
                    .font(AppTheme.font(.headline, .semibold))
                    .foregroundStyle(AppTheme.Text.primary)
                Text("Rules Auto Learn added in the last 7 days, and the edit each one came from.")
                    .font(AppTheme.font(.footnote))
                    .foregroundStyle(AppTheme.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            let shown = shownEntries
            if shown.isEmpty {
                emptyState
            } else {
                VStack(spacing: 0) {
                    ForEach(shown) { entry in
                        RecentlyLearnedRow(entry: entry) {
                            Task { await AutoLearnService.shared.undoLearned([entry]) }
                        }
                        if entry.id != shown.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .autoLearnRecentlyLearnedDidChange)) { _ in
            Task { await load() }
        }
    }

    private var emptyState: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.x3) {
            Image(yapIcon: "sparkles")
                .font(AppTheme.font(.headline))
                .foregroundStyle(AppTheme.Text.muted)
            VStack(alignment: .leading, spacing: AppTheme.Spacing.x2) {
                Text(
                    isAutoLearnEnabled
                        ? "Nothing learned in the last 7 days. When you correct a word Yap pasted, the rule Auto Learn adds shows up here."
                        : "Auto Learn is off. Turn it on in Dictionary Settings to learn from the words you correct after Yap pastes."
                )
                .font(AppTheme.font(.body))
                .foregroundStyle(AppTheme.Text.secondary)
                .fixedSize(horizontal: false, vertical: true)
                AppActionButton("Dictionary Settings", action: onOpenSettings)
            }
        }
        .padding(.vertical, AppTheme.Spacing.x2)
    }

    @MainActor
    private func load() async {
        #if DEBUG
            if Self.snapshotEntries != nil { return }
        #endif
        entries = await AutoLearnService.shared.recentlyLearned()
    }

    /// The rule Auto Learn added is still in the dictionary: its source on a replacement with the same result, or its
    /// vocabulary word.
    static func isInDictionary(
        _ correction: AutoLearnAppliedCorrection,
        replacements: [(originalText: String, replacementText: String)],
        vocabulary: [String]
    ) -> Bool {
        if correction.replacementSourceWasAdded {
            let destination = WordReplacementVariants.destinationKey(for: correction.correctedVocabularyTerm)
            if replacements.contains(where: {
                WordReplacementVariants.destinationKey(for: $0.replacementText) == destination
                    && WordReplacementVariants.contains(
                        correction.incorrectTextToReplace, in: WordReplacementVariants.parse($0.originalText))
            }) {
                return true
            }
        }
        if correction.vocabularyCreationDate != nil {
            let key = WordReplacementVariants.key(for: correction.correctedVocabularyTerm)
            return vocabulary.contains { WordReplacementVariants.key(for: $0) == key }
        }
        return false
    }
}

private struct RecentlyLearnedRow: View {
    let entry: AutoLearnLearnedEntry
    let onUndo: () -> Void

    var body: some View {
        let correction = entry.correction
        HStack(alignment: .center, spacing: AppTheme.Spacing.x3) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.x1) {
                HStack(spacing: AppTheme.Spacing.x2) {
                    Text(verbatim: correction.displayPair)
                        .font(AppTheme.font(.body, .medium))
                        .foregroundStyle(AppTheme.Text.primary)
                        .lineLimit(1)
                    if !correction.replacementSourceWasAdded {
                        Text("Vocabulary")
                            .font(AppTheme.font(.caption))
                            .foregroundStyle(AppTheme.Text.muted)
                    }
                }
                Text(verbatim: String(localized: "“\(correction.sourceOriginal)” → “\(correction.sourceCorrected)”"))
                    .font(AppTheme.font(.footnote))
                    .foregroundStyle(AppTheme.Text.secondary)
                    .lineLimit(2)
                    .help(String(localized: "“\(correction.sourceOriginal)” → “\(correction.sourceCorrected)”"))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(entry.learnedAt, format: .relative(presentation: .named))
                .font(AppTheme.font(.caption))
                .foregroundStyle(AppTheme.Text.muted)
                .monospacedDigit()

            AppActionButton("Undo", action: onUndo)
        }
        .padding(.vertical, AppTheme.Spacing.x2)
        .padding(.horizontal, AppTheme.Spacing.x1)
    }
}

#if DEBUG
    extension RecentlyLearnedSection {
        static func selfCheck() {
            func correction(_ from: String, _ to: String, replacement: Bool = true, vocabulary: Bool = false)
                -> AutoLearnAppliedCorrection
            {
                AutoLearnAppliedCorrection(
                    incorrectTextToReplace: from, correctedVocabularyTerm: to, replacementSourceWasAdded: replacement,
                    vocabularyCreationDate: vocabulary ? Date() : nil, sourceOriginal: from, sourceCorrected: to)
            }
            let rules = [(originalText: "open router, pay gate", replacementText: "paygate")]
            assert(isInDictionary(correction("pay gate", "paygate"), replacements: rules, vocabulary: []))
            assert(!isInDictionary(correction("why app", "Yap"), replacements: rules, vocabulary: []), "removed by hand")
            assert(isInDictionary(correction("why app", "Yap", vocabulary: true), replacements: rules, vocabulary: ["Yap"]))
            assert(
                isInDictionary(correction("x", "Parakeet", replacement: false, vocabulary: true), replacements: [], vocabulary: ["parakeet"]))

            // The notification lists the rules, not just how many (English, the source language).
            guard Bundle.main.preferredLocalizations.first == "en" else { return }
            let two = [correction("Jon", "John"), correction("x", "Parakeet", replacement: false, vocabulary: true)]
            assert(AutoLearnService.learnedNotificationTitle(for: two) == "Learned 2 corrections: “Jon” → “John” and “Parakeet”")
            let five = (1...5).map { correction("w\($0)", "W\($0)") }
            assert(
                AutoLearnService.learnedNotificationTitle(for: five)
                    == "Learned 5 corrections: “w1” → “W1”, “w2” → “W2”, and 3 more",
                AutoLearnService.learnedNotificationTitle(for: five))
        }
    }
#endif
