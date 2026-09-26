import SwiftUI

struct PromptEditorView: View {
    enum Mode {
        case add
        case edit(CustomPrompt)

        static func == (lhs: Mode, rhs: Mode) -> Bool {
            switch (lhs, rhs) {
            case (.add, .add):
                return true
            case (.edit(let prompt1), .edit(let prompt2)):
                return prompt1.id == prompt2.id
            default:
                return false
            }
        }
    }

    let mode: Mode
    @EnvironmentObject private var enhancementService: AIEnhancementService
    let onDismiss: () -> Void
    let onSave: (CustomPrompt) -> Void
    let onDelete: ((CustomPrompt) -> Void)?
    @State private var title: String
    @State private var promptText: String
    @State private var useSystemInstructions: Bool
    @State private var showDeleteConfirmation = false

    private var saveButtonTitle: LocalizedStringKey {
        mode == .add ? "Create & Select" : "Save & Select"
    }

    private var editingPrompt: CustomPrompt? {
        if case .edit(let prompt) = mode {
            return prompt
        }
        return nil
    }

    private var canDeletePrompt: Bool {
        editingPrompt != nil && onDelete != nil
    }

    private var isSaveDisabled: Bool {
        return title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init(
        mode: Mode,
        onDismiss: @escaping () -> Void,
        onSave: @escaping (CustomPrompt) -> Void,
        onDelete: ((CustomPrompt) -> Void)? = nil
    ) {
        self.mode = mode
        self.onDismiss = onDismiss
        self.onSave = onSave
        self.onDelete = onDelete
        switch mode {
        case .add:
            _title = State(initialValue: "")
            _promptText = State(initialValue: "")
            _useSystemInstructions = State(initialValue: true)
        case .edit(let prompt):
            _title = State(initialValue: prompt.title)
            _promptText = State(initialValue: prompt.promptText)
            _useSystemInstructions = State(initialValue: prompt.useSystemInstructions)
        }
    }

    private func dismissPanel() {
        onDismiss()
    }

    var body: some View {
        QuickPanelScaffold {
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.x5) {
                    if case .add = mode {
                        templateMenu
                    }

                    instructionsEditor
                    systemTemplateToggle
                }
                .padding(.horizontal, AppTheme.Spacing.x5)
                .padding(.top, 76)  // design-exempt: layout offset, not spacing
                .padding(.bottom, 72)  // design-exempt: layout offset, not spacing
            }
        } header: {
            header
        } footer: {
            footer
        }
        .confirmationDialog(
            "Delete Prompt?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                deletePrompt()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                String(
                    format: String(localized: "Are you sure you want to delete '%@'? This action cannot be undone."),
                    title))
        }
    }

    private var header: some View {
        HStack(spacing: AppTheme.Spacing.x3) {
            Button {
                dismissPanel()
            } label: {
                Image(systemName: "chevron.left")
                    .font(AppTheme.font(.callout, .semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 28, height: 28)
                    .background(AppTheme.Surface.card)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
            .help("Back")
            .accessibilityLabel("Back")

            TextField("Prompt name", text: $title)
                .textFieldStyle(.plain)
                .font(AppTheme.font(.headline, .semibold))

            Spacer()
        }
        .padding(.horizontal, AppTheme.Spacing.x5)
        .frame(height: QuickPanelMetrics.headerHeight)
    }

    private var systemTemplateToggle: some View {
        HStack(spacing: AppTheme.Spacing.x3) {
            Toggle(isOn: $useSystemInstructions) {
                HStack(spacing: AppTheme.Spacing.x1) {
                    Text("Use System Template")
                    InfoTip(
                        "If enabled, your instructions are combined with a general-purpose template to improve transcription quality.\n\nDisable for full control over the AI's system prompt (for advanced users)."
                    )
                }
            }
            .toggleStyle(.switch)

            Spacer(minLength: 12)
        }
    }

    private var templateMenu: some View {
        Menu {
            ForEach(PromptTemplates.all) { template in
                Button {
                    title = template.title
                    promptText = template.promptText
                    useSystemInstructions = template.useSystemInstructions
                } label: {
                    Text(template.title)
                }
            }
        } label: {
            Label("Template", systemImage: "sparkles")
                .font(AppTheme.font(.body, .medium))
                .foregroundColor(.secondary)
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
        .help("Start with a template")
    }

    private var instructionsEditor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $promptText)
                .font(.system(.body, design: .monospaced))
                .frame(height: 440)
                .scrollContentBackground(.hidden)
                .padding(AppTheme.Spacing.x2)
                .background(AppCardBackground(cornerRadius: AppTheme.Radius.control))
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.control))

            if promptText.isEmpty {
                Text("Write prompt instructions")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, AppTheme.Spacing.x4)
                    .padding(.top, AppTheme.Spacing.x3)
                    .allowsHitTesting(false)
            }
        }
    }

    private var footer: some View {
        HStack {
            if canDeletePrompt {
                AppActionButton("Delete", kind: .destructive, minWidth: 90) {
                    showDeleteConfirmation = true
                }
            } else {
                AppActionButton("Cancel") {
                    dismissPanel()
                }
                .keyboardShortcut(.escape, modifiers: [])
            }

            Spacer()

            AppActionButton(saveButtonTitle, kind: .primary, minWidth: 108) {
                if let savedPrompt = save() {
                    onSave(savedPrompt)
                }
                dismissPanel()
            }
            .disabled(isSaveDisabled)
            .keyboardShortcut(.return, modifiers: .command)
            .help("Save this prompt and select it.")
        }
        .padding(.horizontal, AppTheme.Spacing.x5)
        .frame(height: QuickPanelMetrics.footerHeight)
    }

    private func deletePrompt() {
        guard let prompt = editingPrompt, canDeletePrompt else { return }
        onDelete?(prompt)
        dismissPanel()
    }

    private func save() -> CustomPrompt? {
        switch mode {
        case .add:
            return enhancementService.addPrompt(
                title: title,
                promptText: promptText,
                useSystemInstructions: useSystemInstructions
            )
        case .edit(let prompt):
            let updatedPrompt = CustomPrompt(
                id: prompt.id,
                title: title,
                promptText: promptText,
                useSystemInstructions: useSystemInstructions
            )
            enhancementService.updatePrompt(updatedPrompt)
            return updatedPrompt
        }
    }
}
