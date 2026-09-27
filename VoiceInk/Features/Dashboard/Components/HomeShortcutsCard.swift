import SwiftUI

/// Home's "what do I press" row: dictation and the voice edits of the last paste, with their current keys.
/// Unset keys say so and link to Settings, where every shortcut is recorded.
struct HomeShortcutsCard: View {
    @EnvironmentObject private var recordingShortcutManager: RecordingShortcutManager

    private struct Item: Identifiable {
        let id: String
        let title: LocalizedStringKey
        let note: String
        let shortcut: Shortcut?
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
        ]
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

            // Three columns fit down to the window's minimum width; the notes wrap.
            HStack(alignment: .top, spacing: AppTheme.Spacing.x4) { cells }
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
                if item.shortcut != nil {
                    ShortcutVisualization(shortcut: item.shortcut, isRecording: false, isCompact: true)
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
