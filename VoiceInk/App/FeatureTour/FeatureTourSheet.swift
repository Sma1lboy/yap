import SwiftUI

/// "Explore Key Features" (Settings › Help, and the Help menu): one card per feature with the key that
/// triggers it, if any, and a Show Me button that closes the sheet on the page where it's set up.
struct FeatureTourSheet: View {
    @Environment(\.dismiss) private var dismiss

    private struct Feature: Identifiable {
        let id: String
        let systemImage: String
        let title: LocalizedStringKey
        let detail: LocalizedStringKey
        var shortcut: ShortcutAction?
        let destination: ViewType
    }

    private let features: [Feature] = [
        Feature(
            id: "dictate", systemImage: "mic", title: "Dictate Anywhere",
            detail: "Press your shortcut in any app, speak, and the text is pasted where the cursor is.",
            shortcut: .primaryRecording, destination: .settings),
        Feature(
            id: "modes", systemImage: "square.stack", title: "Modes",
            detail: "Each mode has its own language, model and AI prompt, and can switch on by itself in the apps you pick.",
            destination: .modes),
        Feature(
            id: "context", systemImage: "text.cursor", title: "Text Around the Cursor",
            detail: "A mode can pass the app name, window title and the text around the cursor to AI enhancement, so names and tone match what you're writing. Turn it on per mode.",
            destination: .modes),
        Feature(
            id: "undo", systemImage: "arrow.uturn.backward", title: "Undo Last Paste",
            detail: "Takes back the text Yap pasted last. If it replaced selected text, that text comes back. Saying only \"scratch that\" or \"删掉刚才那句\" does the same.",
            shortcut: .undoLastPaste, destination: .settings),
        Feature(
            id: "rewrite", systemImage: "wand.and.stars", title: "Rewrite Last Dictation",
            detail: "Press, say how to change the text Yap pasted last (\"make it more formal\"), press again. It's replaced in place.",
            shortcut: .rewriteLastPaste, destination: .settings),
        Feature(
            id: "edit", systemImage: "text.badge.checkmark", title: "Edit Selected Text",
            detail: "Select text in any app, use the Rewrite mode's shortcut and say the change (\"make it shorter\"). The selection is replaced. Set the shortcut on the Rewrite mode.",
            destination: .modes),
        Feature(
            id: "dictionary", systemImage: "character.book.closed", title: "Dictionary and Auto-Learn",
            detail: "Add names and terms Yap should spell your way. Auto-Learn suggests entries from the corrections you make after a paste.",
            destination: .dictionary),
        Feature(
            id: "chinese", systemImage: "character", title: "Chinese Cleanup",
            detail: "Removes fillers like 嗯 and 呃, turns spoken \"换行\" into line breaks and converts Traditional to Simplified, offline and before AI. It's under the gear on the Models page.",
            destination: .models),
        Feature(
            id: "meeting", systemImage: "person.2.wave.2", title: "Record Meeting",
            detail: "Records your microphone and the sound of other apps, then saves notes and a transcript in History. The first time, macOS asks for System Audio Recording.",
            shortcut: .meetingRecording, destination: .settings),
        Feature(
            id: "scratchpad", systemImage: "square.and.pencil", title: "Scratchpad",
            detail: "A small floating note. Dictate into it, or when a dictation finds no text field Yap adds it here with the time, so it isn't lost. The text stays on this Mac.",
            shortcut: .openScratchpad, destination: .settings),
        Feature(
            id: "files", systemImage: "waveform", title: "Transcribe Audio Files",
            detail: "Drop in a recording or video and get its transcript in History.",
            destination: .transcribeAudio),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.x1) {
                Text("Explore Key Features")
                    .font(AppTheme.font(.headline, .semibold))
                Text("What Yap can do beyond plain dictation, and where each one is set up.")
                    .font(AppTheme.font(.footnote))
                    .foregroundStyle(AppTheme.Text.secondary)
            }
            .padding([.horizontal, .top], AppTheme.Spacing.x6)
            .padding(.bottom, AppTheme.Spacing.x4)

            ScrollView {
                VStack(spacing: AppTheme.Spacing.x3) {
                    ForEach(features) { card($0) }
                }
                .padding(.horizontal, AppTheme.Spacing.x6)
                .padding(.bottom, AppTheme.Spacing.x4)
            }

            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.appAction(.primary))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(AppTheme.Spacing.x4)
        }
        .frame(width: 560, height: 620)
        .onExitCommand { dismiss() }
    }

    private func card(_ feature: Feature) -> some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.x3) {
            Image(yapIcon: feature.systemImage)
                .font(AppTheme.font(.body))
                .foregroundStyle(AppTheme.Text.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: AppTheme.Spacing.x1) {
                HStack(spacing: AppTheme.Spacing.x2) {
                    Text(feature.title)
                        .font(AppTheme.font(.body, .semibold))
                    if let action = feature.shortcut {
                        if let shortcut = ShortcutStore.shortcut(for: action) {
                            ShortcutVisualization(shortcut: shortcut, isRecording: false, isCompact: true)
                        } else {
                            Text("Not set")
                                .font(AppTheme.font(.footnote))
                                .foregroundStyle(AppTheme.Text.secondary)
                        }
                    }
                }
                Text(feature.detail)
                    .font(AppTheme.font(.footnote))
                    .foregroundStyle(AppTheme.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button("Show Me") {
                MainWindowNavigation.shared.navigate(to: feature.destination)
                dismiss()
            }
            .controlSize(.small)
        }
        .padding(AppTheme.Spacing.x4)
        .background(AppCardBackground(cornerRadius: AppTheme.Radius.card))
    }
}
