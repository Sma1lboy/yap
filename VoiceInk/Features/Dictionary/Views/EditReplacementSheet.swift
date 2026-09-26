import SwiftData
import SwiftUI

// Edit existing word replacement entry
struct EditReplacementSheet: View {
    let replacement: WordReplacement
    let modelContext: ModelContext

    @Environment(\.dismiss) private var dismiss

    @State private var originalWord: String
    @State private var replacementWord: String
    @State private var showAlert = false
    @State private var alertMessage = ""

    // MARK: – Initialiser
    init(replacement: WordReplacement, modelContext: ModelContext) {
        self.replacement = replacement
        self.modelContext = modelContext
        _originalWord = State(initialValue: replacement.originalText)
        _replacementWord = State(initialValue: replacement.replacementText)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .overlay(Divider().opacity(0.5), alignment: .bottom)
            formContent
        }
        .frame(width: 460, height: 560)
        .alert("Word Replacement", isPresented: $showAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
    }

    // MARK: – Subviews
    private var header: some View {
        HStack {
            Button("Cancel", role: .cancel) { dismiss() }
                .buttonStyle(.borderless)
                .keyboardShortcut(.escape, modifiers: [])

            Spacer()

            Text("Edit Word Replacement")
                .font(AppTheme.font(.body, .semibold))

            Spacer()

            AppActionButton("Save", kind: .primary) { saveChanges() }
                .disabled(originalWord.isEmpty || replacementWord.isEmpty)
                .keyboardShortcut(.return, modifiers: [])
        }
        .padding(.horizontal)
        .padding(.vertical, AppTheme.Spacing.x3)
        .background(AppCardBackground(isSelected: false, cornerRadius: AppTheme.Radius.panel))
    }

    private var formContent: some View {
        ScrollView {
            VStack(spacing: AppTheme.Spacing.x5) {
                descriptionSection
                inputSection
            }
            .padding(.vertical)
        }
    }

    private var descriptionSection: some View {
        Text("Update the word or phrase that should be automatically replaced.")
            .font(AppTheme.font(.caption))
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.top, AppTheme.Spacing.x2)
    }

    private var inputSection: some View {
        VStack(spacing: AppTheme.Spacing.x4) {
            // Original Text Field
            VStack(alignment: .leading, spacing: AppTheme.Spacing.x2) {
                HStack {
                    Text("Original Text")
                        .font(AppTheme.font(.body, .semibold))
                    Text("Required")
                        .font(AppTheme.font(.caption))
                        .foregroundColor(.secondary)
                }
                TextField("Enter word or phrase to replace (use commas for multiple)", text: $originalWord)
                    .textFieldStyle(.roundedBorder)

            }
            .padding(.horizontal)

            // Replacement Text Field
            VStack(alignment: .leading, spacing: AppTheme.Spacing.x2) {
                HStack {
                    Text("Replacement Text")
                        .font(AppTheme.font(.body, .semibold))
                    Text("Required")
                        .font(AppTheme.font(.caption))
                        .foregroundColor(.secondary)
                }
                TextEditor(text: $replacementWord)
                    .font(AppTheme.font(.body))
                    .frame(height: 100)
                    .padding(AppTheme.Spacing.x2)
                    .background(Color(.textBackgroundColor))
                    .cornerRadius(AppTheme.Radius.small)
                    .overlay(
                        RoundedRectangle(cornerRadius: AppTheme.Radius.small)
                            .stroke(AppTheme.Border.control, lineWidth: 1)
                    )
            }
            .padding(.horizontal)
        }
    }

    // MARK: – Actions
    private func saveChanges() {
        guard !WordReplacementVariants.parse(originalWord).isEmpty,
            !replacementWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }

        if let error = DictionaryService.updateWordReplacement(
            replacement,
            original: originalWord,
            replacementText: replacementWord,
            context: modelContext
        ) {
            alertMessage = error
            showAlert = true
            return
        }
        dismiss()
    }
}
