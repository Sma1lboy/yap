import SwiftUI

/// Home's "what do I press" card: dictation, the voice edits of the last paste and the Rewrite mode's key for
/// editing selected text. Unset keys say so and link to where they're recorded (Settings; Modes for Rewrite).
struct HomeShortcutsCard: View {
    @EnvironmentObject private var recordingShortcutManager: RecordingShortcutManager
    @EnvironmentObject private var enhancementService: AIEnhancementService
    @ObservedObject private var modeManager = ModeManager.shared

    private struct Item: Identifiable {
        let id: String
        let title: LocalizedStringKey
        let note: String
        let shortcut: Shortcut?
        var notSetAction: (() -> Void)?
        var addAction: (() -> Void)?
    }

    /// The mode that edits selected text: the enabled one using the Rewrite prompt.
    static func editMode(in configs: [ModeConfig]) -> ModeConfig? {
        configs.first { $0.isEnabled && $0.isAIEnhancementEnabled && $0.selectedPrompt == PromptTemplates.rewritePromptId.uuidString }
    }

    private func addRewriteMode() {
        let seeded = StarterModePromptSeeder.ensurePrompts(for: [.rewrite], in: enhancementService.customPrompts)
        if seeded.didChange { enhancementService.customPrompts = seeded.prompts }
        StarterModeFactory.add(kind: .rewrite)
    }

    private var items: [Item] {
        [
            Item(
                id: "dictate", title: "Dictate", note: dictateNote,
                shortcut: recordingShortcutManager.primaryRecordingShortcut == .none
                    ? nil : ShortcutStore.shortcut(for: .primaryRecording)),
            Item(
                id: "undo", title: "Undo Last Paste",
                note: String(localized: "Or say \"scratch that\" / \"删掉刚才那句\""),
                shortcut: ShortcutStore.shortcut(for: .undoLastPaste)),
            Item(
                id: "rewrite", title: "Rewrite Last Dictation",
                note: String(localized: "Press, say how to change it, press again"),
                shortcut: ShortcutStore.shortcut(for: .rewriteLastPaste)),
            editItem,
        ]
    }

    private var editItem: Item {
        let note = String(localized: "Select text, then say how to change it")
        guard let mode = Self.editMode(in: modeManager.configurations) else {
            return Item(
                id: "edit", title: "Edit Selected Text", note: String(localized: "Needs the Rewrite mode"), shortcut: nil,
                addAction: addRewriteMode)
        }
        return Item(
            id: "edit", title: "Edit Selected Text", note: note, shortcut: ShortcutStore.shortcut(for: .mode(mode.id)),
            notSetAction: { MainWindowNavigation.shared.navigate(to: .modes) })
    }

    private var dictateNote: String {
        switch recordingShortcutManager.primaryRecordingShortcutMode {
        case .pushToTalk: return String(localized: "Hold to talk, release to paste")
        case .toggle: return String(localized: "Press to start, press again to paste")
        case .hybrid: return String(localized: "Hold to talk, or tap to start and stop")
        case .doubleTap: return String(localized: "Double-tap to start and stop")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.x3) {
            HStack(alignment: .firstTextBaseline) {
                Text("Shortcuts")
                    .font(AppTheme.font(.body, .semibold))
                    .foregroundStyle(AppTheme.Text.primary)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Change in Settings") { MainWindowNavigation.shared.navigate(to: .settings) }
                    .buttonStyle(.link)
                    .font(AppTheme.font(.footnote))
                    .appLinkStyle()
            }

            // Two columns fit down to the window's minimum width; the notes wrap.
            LazyVGrid(
                columns: [GridItem(.flexible(), alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading)],
                alignment: .leading, spacing: AppTheme.Spacing.x4
            ) { cells }
        }
        .padding(AppTheme.Spacing.x4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppCardBackground(cornerRadius: AppTheme.Radius.card))
    }

    private var cells: some View {
        ForEach(items) { item in
            VStack(alignment: .leading, spacing: AppTheme.Spacing.x2) {
                Text(item.title)
                    .font(AppTheme.font(.footnote, .semibold))
                    .foregroundStyle(AppTheme.Text.primary)
                if let add = item.addAction {
                    Button("Add Rewrite Mode", action: add)
                        .controlSize(.small)
                } else if item.shortcut != nil {
                    ShortcutVisualization(shortcut: item.shortcut, isRecording: false, isCompact: true)
                } else if let notSet = item.notSetAction {
                    Button("Not set", action: notSet)
                        .buttonStyle(.link)
                        .font(AppTheme.font(.footnote))
                        .appLinkStyle()
                } else {
                    Text("Not set")
                        .font(AppTheme.font(.footnote))
                        .foregroundStyle(AppTheme.Text.muted)
                }
                Text(item.note)
                    .font(AppTheme.font(.caption))
                    .foregroundStyle(AppTheme.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }
}

#if DEBUG
    extension HomeShortcutsCard {
        static func selfCheck() {
            let rewrite = PromptTemplates.rewritePromptId.uuidString
            let clean = ModeConfig(name: "Clean", isAIEnhancementEnabled: true, selectedPrompt: PromptTemplates.defaultPromptId.uuidString)
            let off = ModeConfig(name: "Off", isAIEnhancementEnabled: true, selectedPrompt: rewrite, isEnabled: false)
            let on = ModeConfig(name: "Rewrite", isAIEnhancementEnabled: true, selectedPrompt: rewrite)
            assert(editMode(in: [clean]) == nil, "no Rewrite mode: offer to add it")
            assert(editMode(in: [clean, off]) == nil, "a disabled one has no working shortcut")
            assert(editMode(in: [clean, off, on])?.id == on.id)
        }
    }
#endif
