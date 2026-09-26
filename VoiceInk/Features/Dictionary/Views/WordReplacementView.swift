import SwiftData
import SwiftUI

private enum WordReplacementSortColumn {
    case original
    case replacement
}

struct WordReplacementView: View {
    @Query private var wordReplacements: [WordReplacement]
    @Environment(\.modelContext) private var modelContext
    @State private var showAlert = false
    @State private var editingReplacement: WordReplacement? = nil
    @State private var alertMessage = ""
    @State private var sortMode: WordReplacementSortMode = .originalAsc
    @State private var originalWord = ""
    @State private var replacementWord = ""
    @State private var showInfoPopover = false
    @FocusState private var isOriginalFocused: Bool

    init() {
        _sortMode = State(initialValue: DictionarySortService.shared.savedWordReplacementMode())
    }

    private var sortedReplacements: [WordReplacement] {
        DictionarySortService.shared.sortWordReplacements(wordReplacements, by: sortMode)
    }

    private func toggleSort(for column: WordReplacementSortColumn) {
        let service = DictionarySortService.shared
        switch column {
        case .original:
            switch sortMode {
            case .originalAsc: sortMode = .originalDesc
            case .originalDesc: sortMode = .newest
            case .newest: sortMode = .oldest
            case .oldest, .replacementAsc, .replacementDesc: sortMode = .originalAsc
            }
        case .replacement:
            switch sortMode {
            case .replacementAsc: sortMode = .replacementDesc
            case .replacementDesc: sortMode = .newest
            case .newest: sortMode = .oldest
            case .oldest, .originalAsc, .originalDesc: sortMode = .replacementAsc
            }
        }
        service.saveWordReplacementMode(sortMode)
    }

    private var dateSortIconName: String? {
        switch sortMode {
        case .newest: "clock.arrow.circlepath"
        case .oldest: "clock"
        case .originalAsc, .originalDesc, .replacementAsc, .replacementDesc: nil
        }
    }

    private var shouldShowAddButton: Bool {
        !trimmedOriginal.isEmpty || !trimmedReplacement.isEmpty
    }

    private var trimmedOriginal: String {
        originalWord.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedReplacement: String {
        replacementWord.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasValidOriginalVariants: Bool {
        !WordReplacementVariants.parse(trimmedOriginal).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.x3) {
            HStack(spacing: AppTheme.Spacing.x2) {
                TextField("", text: $originalWord, prompt: Text("Original text (use commas for multiple)"))
                    .textFieldStyle(.roundedBorder)
                    .font(AppTheme.font(.body))
                    .onSubmit { addReplacement() }
                    .labelsHidden()
                    .focused($isOriginalFocused)

                Image(systemName: "arrow.right")
                    .foregroundColor(.secondary)
                    .font(AppTheme.font(.micro))
                    .frame(width: 10)

                TextField("", text: $replacementWord, prompt: Text("Replacement text"))
                    .textFieldStyle(.roundedBorder)
                    .font(AppTheme.font(.body))
                    .onSubmit { addReplacement() }
                    .labelsHidden()

                if shouldShowAddButton {
                    AddIconButton(
                        helpText: "Add word replacement",
                        isDisabled: trimmedOriginal.isEmpty || trimmedReplacement.isEmpty || !hasValidOriginalVariants,
                        action: addReplacement
                    )
                }

                Button {
                    showInfoPopover.toggle()
                } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.borderless)
                .help("Word replacement examples")
                .accessibilityLabel("Word replacement examples")
                .popover(isPresented: $showInfoPopover) {
                    WordReplacementInfoPopover()
                }
            }
            .animation(.easeInOut(duration: 0.2), value: shouldShowAddButton)

            if !wordReplacements.isEmpty {
                VStack(spacing: 0) {
                    HStack(spacing: AppTheme.Spacing.x2) {
                        Button(action: { toggleSort(for: .original) }) {
                            HStack(spacing: AppTheme.Spacing.x1) {
                                Text("Original")
                                    .font(AppTheme.font(.footnote, .medium))
                                    .foregroundColor(.secondary)

                                if sortMode == .originalAsc || sortMode == .originalDesc {
                                    Image(systemName: sortMode == .originalAsc ? "chevron.up" : "chevron.down")
                                        .font(AppTheme.font(.caption))
                                        .foregroundColor(.secondary)
                                } else if let dateSortIconName {
                                    Image(systemName: dateSortIconName)
                                        .font(AppTheme.font(.caption))
                                        .foregroundColor(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .help("Sort by original")

                        Image(systemName: "arrow.right")
                            .foregroundColor(.secondary)
                            .font(AppTheme.font(.micro))
                            .frame(width: 10)

                        Button(action: { toggleSort(for: .replacement) }) {
                            HStack(spacing: AppTheme.Spacing.x1) {
                                Text("Replacement")
                                    .font(AppTheme.font(.footnote, .medium))
                                    .foregroundColor(.secondary)

                                if sortMode == .replacementAsc || sortMode == .replacementDesc {
                                    Image(systemName: sortMode == .replacementAsc ? "chevron.up" : "chevron.down")
                                        .font(AppTheme.font(.caption))
                                        .foregroundColor(.secondary)
                                } else if let dateSortIconName {
                                    Image(systemName: dateSortIconName)
                                        .font(AppTheme.font(.caption))
                                        .foregroundColor(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .help("Sort by replacement")
                    }
                    .padding(.horizontal, AppTheme.Spacing.x1)
                    .padding(.vertical, AppTheme.Spacing.x2)

                    Divider()

                    LazyVStack(spacing: 0) {
                        ForEach(sortedReplacements, id: \.persistentModelID) { replacement in
                            ReplacementRow(
                                original: replacement.originalText,
                                replacement: replacement.replacementText,
                                onDelete: { removeReplacement(replacement) },
                                onEdit: { editingReplacement = replacement },
                                onRemoveSource: { source in
                                    removeSource(source, from: replacement)
                                }
                            )

                            if replacement.persistentModelID != sortedReplacements.last?.persistentModelID {
                                Divider()
                            }
                        }
                    }
                }
                .padding(.top, AppTheme.Spacing.x1)
            } else {
                DictionaryEmptyState(
                    systemImage: "arrow.left.arrow.right",
                    message: "Replace words Yap often gets wrong, or expand shortcuts like “my email”.",
                    buttonTitle: "Add First Replacement",
                    action: { isOriginalFocused = true }
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: isEditingReplacement) {
            if let editingReplacement {
                EditReplacementSheet(replacement: editingReplacement, modelContext: modelContext)
            }
        }
        .alert("Word Replacement", isPresented: $showAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
    }

    private func addReplacement() {
        let original = trimmedOriginal
        let replacement = trimmedReplacement
        guard !original.isEmpty, !replacement.isEmpty,
            !WordReplacementVariants.parse(original).isEmpty else { return }
        if let error = DictionaryService.addWordReplacement(
            original: original, replacement: replacement, existing: Array(wordReplacements), context: modelContext)
        {
            alertMessage = error
            showAlert = true
            return
        }
        originalWord = ""
        replacementWord = ""
    }

    private func removeReplacement(_ replacement: WordReplacement) {
        if let error = DictionaryService.removeWordReplacement(replacement, context: modelContext) {
            alertMessage = error
            showAlert = true
        }
    }

    private func removeSource(_ source: String, from replacement: WordReplacement) {
        let sources = WordReplacementVariants.parse(replacement.originalText)
        guard sources.contains(source) else { return }

        if let error = DictionaryService.removeWordReplacementSource(
            source,
            from: replacement,
            context: modelContext
        ) {
            alertMessage = error
            showAlert = true
            return
        }
        NotificationCenter.default.post(name: .wordReplacementsDidChange, object: nil)
    }

    private var isEditingReplacement: Binding<Bool> {
        Binding(
            get: { editingReplacement != nil },
            set: { isPresented in
                if !isPresented {
                    editingReplacement = nil
                }
            }
        )
    }
}

struct WordReplacementInfoPopover: View {
    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.x4) {
            Text("How to use Word Replacements")
                .font(AppTheme.font(.body, .semibold))

            VStack(alignment: .leading, spacing: AppTheme.Spacing.x2) {
                Text("Separate multiple originals with commas:")
                    .font(AppTheme.font(.caption))
                    .foregroundColor(.secondary)

                Text("Voicing, Voice ink, Voiceing")
                    .font(AppTheme.font(.footnote))
                    .padding(AppTheme.Spacing.x2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.textBackgroundColor))
                    .cornerRadius(AppTheme.Radius.small)
            }

            Text("Type \\n in the replacement for a line break, \\n\\n for a new paragraph.")
                .font(AppTheme.font(.caption))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Scroll horizontally to view all phrases.")
                .font(AppTheme.font(.caption))
                .foregroundColor(.secondary)

            Divider()

            Text("Examples")
                .font(AppTheme.font(.caption))
                .foregroundColor(.secondary)

            VStack(spacing: AppTheme.Spacing.x3) {
                HStack(spacing: AppTheme.Spacing.x2) {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.x1) {
                        Text("Original:")
                            .font(AppTheme.font(.caption))
                            .foregroundColor(.secondary)
                        Text("my website link")
                            .font(AppTheme.font(.footnote))
                    }

                    Image(systemName: "arrow.right")
                        .font(AppTheme.font(.caption))
                        .foregroundColor(.secondary)

                    VStack(alignment: .leading, spacing: AppTheme.Spacing.x1) {
                        Text("Replacement:")
                            .font(AppTheme.font(.caption))
                            .foregroundColor(.secondary)
                        Text(verbatim: "https://github.com/Sma1lboy/yap")
                            .font(AppTheme.font(.footnote))
                    }
                }
                .padding(AppTheme.Spacing.x3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.textBackgroundColor))
                .cornerRadius(AppTheme.Radius.small)

                HStack(spacing: AppTheme.Spacing.x2) {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.x1) {
                        Text("Original:")
                            .font(AppTheme.font(.caption))
                            .foregroundColor(.secondary)
                        Text("Voicing, Voice ink")
                            .font(AppTheme.font(.footnote))
                    }

                    Image(systemName: "arrow.right")
                        .font(AppTheme.font(.caption))
                        .foregroundColor(.secondary)

                    VStack(alignment: .leading, spacing: AppTheme.Spacing.x1) {
                        Text("Replacement:")
                            .font(AppTheme.font(.caption))
                            .foregroundColor(.secondary)
                        Text("Yap")
                            .font(AppTheme.font(.footnote))
                    }
                }
                .padding(AppTheme.Spacing.x3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.textBackgroundColor))
                .cornerRadius(AppTheme.Radius.small)
            }
        }
        .padding()
        .frame(width: 380)
    }
}

struct ReplacementRow: View {
    let original: String
    let replacement: String
    let onDelete: () -> Void
    let onEdit: () -> Void
    let onRemoveSource: (String) -> Void

    private var sources: [String] {
        WordReplacementVariants.parse(original)
    }

    var body: some View {
        HStack(spacing: AppTheme.Spacing.x2) {
            ScrollView(.horizontal) {
                HStack(spacing: AppTheme.Spacing.x2) {
                    ForEach(sources, id: \.self) { source in
                        ReplacementSourcePill(
                            source: source,
                            showsRemoveButton: sources.count > 1
                        ) {
                            onRemoveSource(source)
                        }
                    }
                }
            }
            .scrollIndicators(.never)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(original)

            Image(systemName: "arrow.right")
                .foregroundColor(.secondary)
                .font(AppTheme.font(.micro))
                .frame(width: 10)

            HStack(spacing: AppTheme.Spacing.x2) {
                ScrollView(.horizontal) {
                    Text(replacement)
                        .font(AppTheme.font(.body))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .scrollIndicators(.never)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(replacement)

                HStack(spacing: AppTheme.Spacing.x2) {
                    Button(action: onEdit) {
                        Image(systemName: "pencil.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(AppTheme.Text.primary)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.borderless)
                    .help("Edit replacement")
                    .accessibilityLabel("Edit replacement")

                    Button(action: onDelete) {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(AppTheme.Text.primary)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.borderless)
                    .help("Remove replacement")
                    .accessibilityLabel("Remove replacement")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, AppTheme.Spacing.x2)
        .padding(.horizontal, AppTheme.Spacing.x1)
    }
}

private struct ReplacementSourcePill: View {
    let source: String
    let showsRemoveButton: Bool
    let onRemove: () -> Void

    var body: some View {
        DictionaryPill(
            onRemove: showsRemoveButton ? onRemove : nil,
            removeHelp: "Remove \(source) from Word Replacements",
            removeAccessibilityLabel: "Remove \(source) from Word Replacements"
        ) {
            Text(source)
                .fixedSize(horizontal: true, vertical: false)
        }
    }
}
