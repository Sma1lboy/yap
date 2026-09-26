import SwiftData
import SwiftUI

struct VocabularyView: View {
    @Query private var vocabularyWords: [VocabularyWord]
    @Environment(\.modelContext) private var modelContext
    @State private var newWord = ""
    @State private var showAlert = false
    @State private var alertMessage = ""
    @State private var sortMode: VocabularySortMode = .wordAsc
    @State private var showInfoPopover = false
    @FocusState private var isInputFocused: Bool

    init() {
        _sortMode = State(initialValue: DictionarySortService.shared.savedVocabularyMode())
    }

    private var sortedItems: [VocabularyWord] {
        DictionarySortService.shared.sortVocabulary(vocabularyWords, by: sortMode)
    }

    private func toggleSort() {
        let service = DictionarySortService.shared
        sortMode = service.nextVocabularyMode(after: sortMode)
        service.saveVocabularyMode(sortMode)
    }

    private var sortIconName: String {
        switch sortMode {
        case .wordAsc: "chevron.up"
        case .wordDesc: "chevron.down"
        case .newest: "clock.arrow.circlepath"
        case .oldest: "clock"
        }
    }

    private var shouldShowAddButton: Bool {
        !newWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.x3) {
            HStack(spacing: AppTheme.Spacing.x2) {
                TextField("", text: $newWord, prompt: Text("Add word to vocabulary"))
                    .textFieldStyle(.roundedBorder)
                    .font(AppTheme.font(.body))
                    .onSubmit { addWords() }
                    .labelsHidden()
                    .focused($isInputFocused)

                if shouldShowAddButton {
                    AddIconButton(
                        helpText: "Add word",
                        isDisabled: !shouldShowAddButton,
                        action: addWords
                    )
                }

                Button {
                    showInfoPopover.toggle()
                } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.borderless)
                .help("Vocabulary examples")
                .accessibilityLabel("Vocabulary examples")
                .popover(isPresented: $showInfoPopover) {
                    VocabularyInfoPopover()
                }
            }
            .animation(.easeInOut(duration: 0.2), value: shouldShowAddButton)

            if !vocabularyWords.isEmpty {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.x3) {
                    Button(action: toggleSort) {
                        HStack(spacing: AppTheme.Spacing.x1) {
                            Text(String(localized: "Vocabulary Words (\(vocabularyWords.count))"))
                                .font(AppTheme.font(.footnote, .medium))
                                .foregroundColor(.secondary)

                            Image(systemName: sortIconName)
                                .font(AppTheme.font(.caption))
                                .foregroundColor(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Change sort order")

                    FlowLayout(spacing: AppTheme.Spacing.x2) {
                        ForEach(sortedItems) { item in
                            VocabularyWordView(item: item) {
                                removeWord(item)
                            }
                        }
                    }
                    .padding(.vertical, AppTheme.Spacing.x1)
                }
                .padding(.top, AppTheme.Spacing.x1)
            } else {
                DictionaryEmptyState(
                    systemImage: "character.book.closed",
                    message: "Add names, product terms, and jargon so Yap spells them correctly.",
                    buttonTitle: "Add First Word",
                    action: { isInputFocused = true }
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .alert("Vocabulary", isPresented: $showAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
    }

    private func addWords() {
        let input = newWord.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        if let error = DictionaryService.addVocabularyWords(
            input, existing: Array(vocabularyWords), context: modelContext)
        {
            alertMessage = error
            showAlert = true
            return
        }
        newWord = ""
    }

    private func removeWord(_ word: VocabularyWord) {
        if let error = DictionaryService.removeVocabularyWord(word, context: modelContext) {
            alertMessage = error
            showAlert = true
        }
    }
}

struct DictionaryEmptyState: View {
    let systemImage: String
    let message: LocalizedStringKey
    let buttonTitle: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        VStack(spacing: AppTheme.Spacing.x3) {
            Image(systemName: systemImage)
                .font(AppTheme.font(.display))
                .foregroundColor(.secondary.opacity(0.6))

            Text(message)
                .font(AppTheme.font(.body))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button(buttonTitle, action: action)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, AppTheme.Spacing.x6)
    }
}

struct VocabularyInfoPopover: View {
    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.x4) {
            Text("How to use Vocabulary")
                .font(AppTheme.font(.body, .semibold))

            Text(
                "Vocabulary helps supported transcription models and AI enhancement preserve important names, technical terms, and unique spellings."
            )
            .font(AppTheme.font(.caption))
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Text("Add one entry at a time, or paste multiple entries separated by commas.")
                .font(AppTheme.font(.caption))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Text("Examples")
                .font(AppTheme.font(.caption))
                .foregroundColor(.secondary)

            Text(verbatim: "Yap, OpenRouter, SwiftData, WebSocket")
                .font(AppTheme.font(.footnote))
                .padding(AppTheme.Spacing.x2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.textBackgroundColor))
                .cornerRadius(AppTheme.Radius.small)
        }
        .padding()
        .frame(width: 320)
    }
}

struct VocabularyWordView: View {
    let item: VocabularyWord
    let onDelete: () -> Void

    var body: some View {
        DictionaryPill(onRemove: onDelete, removeHelp: "Remove word") {
            Text(item.word)
                .lineLimit(1)
        }
    }
}
