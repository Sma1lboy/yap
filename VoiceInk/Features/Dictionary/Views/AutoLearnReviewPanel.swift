import SwiftUI

struct AutoLearnReviewPanel: View {
    fileprivate enum ReviewComponent: Hashable {
        case replacement
        case vocabulary
    }

    fileprivate struct ReviewDraft: Equatable {
        var incorrectText: String
        var correctedTerm: String

        init(proposal: AutoLearnReviewProposal) {
            incorrectText = proposal.incorrectTextToReplace ?? ""
            correctedTerm = proposal.correctedVocabularyTerm ?? ""
        }
    }

    let onClose: () -> Void

    @State private var proposals: [AutoLearnReviewProposal] = []
    @State private var selections: [UUID: Set<ReviewComponent>] = [:]
    @State private var drafts: [UUID: ReviewDraft] = [:]
    @State private var isReviewing = false
    @State private var isApplying = false
    @State private var errorMessage: String?

    var body: some View {
        QuickPanelScaffold {
            reviewContent
        } header: {
            floatingHeader
        } footer: {
            footer
        }
        .task {
            await loadAndReview()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .autoLearnReviewProposalsDidChange)
        ) { _ in
            Task { await reloadProposals(selectNewItems: true) }
        }
    }

    @ViewBuilder
    private var reviewContent: some View {
        if proposals.isEmpty, !isReviewing {
            emptyState
        } else {
            reviewList
        }
    }

    private var floatingHeader: some View {
        HStack(spacing: AppTheme.Spacing.x3) {
            HStack(spacing: AppTheme.Spacing.x1) {
                Text("Review Corrections")
                    .font(AppTheme.font(.body, .semibold))
                    .fontWeight(.semibold)
                    .foregroundStyle(AppTheme.Text.primary)

                InfoTip(
                    message: "The arrow icon refers to Word Replacement. The book icon refers to Vocabulary.",
                    iconSize: .small,
                    iconColor: .secondary,
                    width: 320
                )
            }

            Spacer()

            AppIconButton(
                systemName: "xmark",
                help: "Close",
                size: 28,
                iconSize: 14,
                cornerRadius: AppTheme.Radius.control,
                action: onClose
            )
        }
        .padding(.horizontal, AppTheme.Spacing.x5)
        .frame(height: QuickPanelMetrics.headerHeight)
    }

    private var reviewList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: AppTheme.Spacing.x3) {
                if isReviewing {
                    HStack(spacing: AppTheme.Spacing.x2) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Reviewing pending corrections…")
                            .font(AppTheme.font(.footnote))
                            .foregroundStyle(AppTheme.Text.secondary)
                    }
                    .padding(.bottom, AppTheme.Spacing.half)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(AppTheme.font(.caption, .medium))
                        .foregroundStyle(AppTheme.Status.error)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, AppTheme.Spacing.half)
                }

                ForEach(proposals) { proposal in
                    AutoLearnReviewProposalRow(
                        proposal: proposal,
                        draft: draftBinding(for: proposal),
                        selectedComponents: selections[proposal.id] ?? [],
                        isDisabled: isApplying,
                        onToggleAll: { isSelected in
                            selections[proposal.id] = isSelected
                                ? availableComponents(for: proposal)
                                : []
                        },
                        onToggleComponent: { component in
                            var selected = selections[proposal.id] ?? []
                            if selected.contains(component) {
                                selected.remove(component)
                            } else {
                                selected.insert(component)
                            }
                            selections[proposal.id] = selected
                        },
                        onCommitEdits: { draft in
                            persist(draft, for: proposal)
                        }
                    )
                }
            }
            .padding(AppTheme.Spacing.x4)
            .padding(.top, 68)  // design-exempt: layout offset, not spacing
            .padding(.bottom, 58)  // design-exempt: layout offset, not spacing
        }
        .scrollIndicators(.never)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Corrections to Review", systemImage: "checkmark.circle")
        } description: {
            Text(errorMessage ?? "New manual-review suggestions will appear here.")
        }
        .padding(.top, 68)  // design-exempt: layout offset, not spacing
        .padding(.bottom, 58)  // design-exempt: layout offset, not spacing
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var footer: some View {
        if !proposals.isEmpty {
            HStack(spacing: AppTheme.Spacing.x3) {
                AppActionButton("Dismiss All", kind: .destructive) {
                    dismiss(Set(proposals.map(\.id)))
                }
                .disabled(isApplying || isReviewing)

                Spacer()

                AppActionButton(applyButtonTitle, kind: .primary) {
                    applySelections()
                }
                .disabled(selectedProposalCount == 0 || hasInvalidSelection || isApplying || isReviewing)
                .help(firstValidationIssue ?? "Apply the selected corrections")
            }
            .padding(.horizontal, AppTheme.Spacing.x5)
            .frame(height: QuickPanelMetrics.footerHeight)
        }
    }

    private var applyButtonTitle: LocalizedStringKey {
        if !proposals.isEmpty,
           proposals.allSatisfy({ selections[$0.id] == availableComponents(for: $0) }) {
            return "Apply All (\(proposals.count))"
        }
        return "Apply Selected (\(selectedProposalCount))"
    }

    private var selectedProposalCount: Int {
        proposals.filter { !(selections[$0.id] ?? []).isEmpty }.count
    }

    private var hasInvalidSelection: Bool {
        firstValidationIssue != nil
    }

    private var firstValidationIssue: String? {
        for proposal in proposals {
            let selected = selections[proposal.id] ?? []
            guard !selected.isEmpty else { continue }
            let draft = drafts[proposal.id] ?? ReviewDraft(proposal: proposal)

            let correctedTerm = draft.correctedTerm.trimmingCharacters(in: .whitespacesAndNewlines)
            if correctedTerm.isEmpty {
                return String(localized: "The corrected value cannot be empty.")
            }

            if selected.contains(.replacement) {
                let incorrectText = draft.incorrectText.trimmingCharacters(in: .whitespacesAndNewlines)
                if incorrectText.isEmpty {
                    return String(localized: "The original value cannot be empty.")
                }
                if incorrectText.contains(",") {
                    return String(localized: "A reviewed replacement can contain only one original value.")
                }
                if incorrectText.precomposedStringWithCanonicalMapping
                    == correctedTerm.precomposedStringWithCanonicalMapping
                {
                    return String(localized: "The original and corrected values must be different.")
                }
            }
        }
        return nil
    }

    @MainActor
    private func loadAndReview() async {
        isReviewing = true
        errorMessage = nil
        await reloadProposals(selectNewItems: true)
        await AutoLearnService.shared.preparePendingReviewForApproval()
        await reloadProposals(selectNewItems: true)
        isReviewing = false

        let pendingCount = (try? await AutoLearnService.shared.pendingReviewCount()) ?? 0
        if pendingCount > 0, errorMessage == nil {
            errorMessage = String(
                localized: "Some corrections could not be reviewed. Check the selected AI provider and try again."
            )
        }
    }

    @MainActor
    private func reloadProposals(selectNewItems: Bool) async {
        do {
            let loaded = try await AutoLearnService.shared.reviewProposals()
            let loadedIDs = Set(loaded.map(\.id))
            prepareDraftsAndSelections(for: loaded, selectNewItems: selectNewItems)
            selections = selections.filter { loadedIDs.contains($0.key) }
            drafts = drafts.filter { loadedIDs.contains($0.key) }
            proposals = loaded
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func applySelections() {
        let reviewSelections = proposals.compactMap { proposal -> AutoLearnReviewSelection? in
            let selected = selections[proposal.id] ?? []
            guard !selected.isEmpty else { return nil }
            return AutoLearnReviewSelection(
                proposalID: proposal.id,
                includesReplacement: selected.contains(.replacement),
                includesVocabulary: selected.contains(.vocabulary),
                incorrectTextToReplace: draftBinding(for: proposal).wrappedValue.incorrectText
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                correctedVocabularyTerm: draftBinding(for: proposal).wrappedValue.correctedTerm
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        guard !reviewSelections.isEmpty, !hasInvalidSelection else { return }
        Task { @MainActor in
            isApplying = true
            errorMessage = nil
            do {
                _ = try await AutoLearnService.shared.applyReviewProposals(reviewSelections)
                await reloadProposals(selectNewItems: false)
            } catch {
                errorMessage = error.localizedDescription
            }
            isApplying = false
        }
    }

    private func prepareDraftsAndSelections(
        for loaded: [AutoLearnReviewProposal],
        selectNewItems: Bool
    ) {
        for proposal in loaded {
            if drafts[proposal.id] == nil {
                drafts[proposal.id] = ReviewDraft(proposal: proposal)
            }
            if selectNewItems, selections[proposal.id] == nil {
                selections[proposal.id] = availableComponents(for: proposal)
            }
        }
    }

    private func draftBinding(for proposal: AutoLearnReviewProposal) -> Binding<ReviewDraft> {
        Binding(
            get: { drafts[proposal.id] ?? ReviewDraft(proposal: proposal) },
            set: { drafts[proposal.id] = $0 }
        )
    }

    private func persist(_ draft: ReviewDraft, for proposal: AutoLearnReviewProposal) {
        let incorrectText = draft.incorrectText.trimmingCharacters(in: .whitespacesAndNewlines)
        let correctedTerm = draft.correctedTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !correctedTerm.isEmpty, !proposal.addsReplacement || !incorrectText.isEmpty else { return }

        Task { @MainActor in
            do {
                try await AutoLearnService.shared.updateReviewProposal(
                    proposalID: proposal.id,
                    incorrectTextToReplace: proposal.addsReplacement ? incorrectText : nil,
                    correctedVocabularyTerm: correctedTerm
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func availableComponents(
        for proposal: AutoLearnReviewProposal
    ) -> Set<ReviewComponent> {
        var components = Set<ReviewComponent>()
        if proposal.addsReplacement {
            components.insert(.replacement)
        }
        if proposal.addsVocabulary {
            components.insert(.vocabulary)
        }
        return components
    }

    private func dismiss(_ proposalIDs: Set<UUID>) {
        guard !proposalIDs.isEmpty else { return }
        Task { @MainActor in
            isApplying = true
            errorMessage = nil
            do {
                try await AutoLearnService.shared.dismissReviewProposals(proposalIDs)
                await reloadProposals(selectNewItems: false)
            } catch {
                errorMessage = error.localizedDescription
            }
            isApplying = false
        }
    }
}

private struct AutoLearnReviewProposalRow: View {
    private enum EditableField: Hashable {
        case incorrect
        case corrected
    }

    let proposal: AutoLearnReviewProposal
    @Binding var draft: AutoLearnReviewPanel.ReviewDraft
    let selectedComponents: Set<AutoLearnReviewPanel.ReviewComponent>
    let isDisabled: Bool
    let onToggleAll: (Bool) -> Void
    let onToggleComponent: (AutoLearnReviewPanel.ReviewComponent) -> Void
    let onCommitEdits: (AutoLearnReviewPanel.ReviewDraft) -> Void

    @FocusState private var focusedField: EditableField?
    @State private var editingField: EditableField?
    @State private var hoveredField: EditableField?
    @State private var valueBeforeEditing = ""

    var body: some View {
        HStack(spacing: AppTheme.Spacing.x2) {
            Toggle(
                "Select correction",
                isOn: Binding(
                    get: { !selectedComponents.isEmpty },
                    set: onToggleAll
                )
            )
            .labelsHidden()
            .toggleStyle(.checkbox)
            .help(selectedComponents.isEmpty ? "Select correction" : "Deselect correction")
            .accessibilityLabel("Select correction")
            .accessibilityValue(selectedComponents.isEmpty ? "Not selected" : "Selected")

            correctionText
                .truncationMode(.tail)
                .padding(.vertical, AppTheme.Spacing.half)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(correctionSummary)

            HStack(spacing: AppTheme.Spacing.x1) {
                if proposal.addsReplacement {
                    reviewButton(
                        "Word Replacement",
                        systemImage: "arrow.left.arrow.right",
                        component: .replacement
                    )
                }
                if proposal.addsVocabulary {
                    reviewButton(
                        "Vocabulary",
                        systemImage: "character.book.closed",
                        component: .vocabulary
                    )
                }
            }
        }
        .padding(AppTheme.Spacing.x3)
        .background(ProviderSurface(cornerRadius: AppTheme.Radius.control))
        .disabled(isDisabled)
        .onChange(of: focusedField) { previous, current in
            if current == nil, let previous {
                commit(previous)
            }
        }
    }

    @ViewBuilder
    private var correctionText: some View {
        if proposal.addsReplacement,
            let source = proposal.incorrectTextToReplace,
            let destination = proposal.correctedVocabularyTerm
        {
            HStack(spacing: AppTheme.Spacing.x2) {
                editableValue(
                    text: $draft.incorrectText,
                    fallback: source,
                    field: .incorrect,
                    isEmphasized: false
                )
                Image(systemName: "arrow.right")
                    .font(AppTheme.font(.micro, .medium))
                    .foregroundStyle(AppTheme.Text.muted)
                editableValue(
                    text: $draft.correctedTerm,
                    fallback: destination,
                    field: .corrected,
                    isEmphasized: true
                )
            }
            .font(AppTheme.font(.body))
        } else if let term = proposal.correctedVocabularyTerm {
            editableValue(
                text: $draft.correctedTerm,
                fallback: term,
                field: .corrected,
                isEmphasized: true
            )
            .font(AppTheme.font(.body))
        }
    }

    @ViewBuilder
    private func editableValue(
        text: Binding<String>,
        fallback: String,
        field: EditableField,
        isEmphasized: Bool
    ) -> some View {
        let validationMessage = validationMessage(for: field)
        if editingField == field {
            TextField("", text: text)
                .textFieldStyle(.plain)
                .fontWeight(isEmphasized ? .semibold : .regular)
                .focused($focusedField, equals: field)
                .onSubmit { commit(field) }
                .onExitCommand { cancel(field, binding: text) }
                .padding(.horizontal, AppTheme.Spacing.x1)
                .padding(.vertical, AppTheme.Spacing.x1)
                .background(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.small)
                        .fill(AppTheme.Surface.window)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: AppTheme.Radius.small)
                        .stroke(
                            validationMessage == nil ? AppTheme.Border.subtle : AppTheme.Status.error,
                            lineWidth: 1
                        )
                }
                .fixedSize(horizontal: false, vertical: true)
                .help(validationMessage ?? "Press Return to finish editing")
        } else {
            Text(text.wrappedValue.isEmpty ? fallback : text.wrappedValue)
                .lineLimit(1)
                .foregroundStyle(isEmphasized ? AppTheme.Text.primary : AppTheme.Text.secondary)
                .fontWeight(isEmphasized ? .semibold : .regular)
                .contentShape(Rectangle())
                .onTapGesture { beginEditing(field, value: text.wrappedValue) }
                .help("Click to edit")
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Click to edit")
                .accessibilityAction { beginEditing(field, value: text.wrappedValue) }
                .onHover { isHovering in
                    hoveredField = isHovering ? field : nil
                }
                .padding(.horizontal, AppTheme.Spacing.x1)
                .padding(.vertical, AppTheme.Spacing.x1)
                .background {
                    RoundedRectangle(cornerRadius: AppTheme.Radius.small)
                        .fill(
                            hoveredField == field
                                ? AppTheme.Surface.window.opacity(0.8)
                                : Color.clear
                        )
                }
        }
    }

    private func beginEditing(_ field: EditableField, value: String) {
        if let editingField, editingField != field {
            onCommitEdits(draft)
        }
        valueBeforeEditing = value
        editingField = field
        DispatchQueue.main.async { focusedField = field }
    }

    private func commit(_ field: EditableField) {
        guard editingField == field else { return }
        editingField = nil
        focusedField = nil
        onCommitEdits(draft)
    }

    private func cancel(_ field: EditableField, binding: Binding<String>) {
        binding.wrappedValue = valueBeforeEditing
        editingField = nil
        focusedField = nil
    }

    private func validationMessage(for field: EditableField) -> String? {
        let incorrectText = draft.incorrectText.trimmingCharacters(in: .whitespacesAndNewlines)
        let correctedTerm = draft.correctedTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        let isReplacementSelected = selectedComponents.contains(.replacement)

        if field == .corrected, correctedTerm.isEmpty {
            return String(localized: "The corrected value cannot be empty.")
        }
        guard field == .incorrect, isReplacementSelected else { return nil }
        if incorrectText.isEmpty {
            return String(localized: "The original value cannot be empty.")
        }
        if incorrectText.contains(",") {
            return String(localized: "A reviewed replacement can contain only one original value.")
        }
        if incorrectText.precomposedStringWithCanonicalMapping
            == correctedTerm.precomposedStringWithCanonicalMapping
        {
            return String(localized: "The original and corrected values must be different.")
        }
        return nil
    }

    private var correctionSummary: String {
        if proposal.addsReplacement {
            return "\(draft.incorrectText) → \(draft.correctedTerm)"
        }
        return draft.correctedTerm
    }

    private func reviewButton(
        _ title: LocalizedStringKey,
        systemImage: String,
        component: AutoLearnReviewPanel.ReviewComponent
    ) -> some View {
        let isSelected = selectedComponents.contains(component)
        return Button {
            onToggleComponent(component)
        } label: {
            Image(systemName: systemImage)
                .font(AppTheme.font(.caption, .semibold))
                .foregroundStyle(isSelected ? AppTheme.Text.primary : AppTheme.Text.muted)
                .frame(width: 30, height: 26)
                .background(QuickPanelButtonBackground(isSelected: isSelected))
        }
        .buttonStyle(.plain)
        .help(Text(title))
        .accessibilityLabel(title)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }

}
