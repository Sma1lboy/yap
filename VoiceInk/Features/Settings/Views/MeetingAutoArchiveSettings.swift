import AppKit
import SwiftUI

/// Settings › Meetings: saving meetings to a folder automatically (MeetingAutoArchive). The switch, the folder,
/// what it does and doesn't do, and what the last automatic save did.
struct MeetingAutoArchiveSettings: View {
    @ObservedObject var archive = MeetingAutoArchive.shared

    var body: some View {
        Toggle(isOn: Binding(
            get: { archive.isEnabled },
            set: { on in Task { on ? await turnOn() : await archive.turnOff() } }
        )) {
            HStack(spacing: AppTheme.Spacing.x1) {
                Text("Save Meetings to a Folder Automatically")
                InfoTip("Each meeting's Markdown, as Export Markdown writes it, is added to the folder every time the meeting is saved in History: when it ends, when its speakers have been told apart, after Speaker Names and after Regenerate Notes. Files are never replaced or deleted; a change adds a new file next to the old one, and the same content isn't added twice. A save that was still waiting when Yap quit isn't made up later. The folder and this switch stay on this Mac: settings backups, the config file and Yap Cloud sync don't include them.")
            }
        }
        .disabled(archive.isSwitching)

        VStack(alignment: .leading, spacing: AppTheme.Spacing.x2) {
            if let folder = archive.folder {
                HStack(spacing: AppTheme.Spacing.x2) {
                    Image(yapIcon: "folder")
                    Text(verbatim: folder.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer(minLength: AppTheme.Spacing.x2)
                    AppActionButton("Choose Folder…") { chooseFolder() }
                        .controlSize(.small)
                        .disabled(archive.isSwitching)
                }
                .font(AppTheme.font(.footnote))
                .foregroundStyle(AppTheme.Text.secondary)
            }
            note("Only meetings saved from now on. Meetings already in History aren't copied; select them in History and use Save Meetings… for that. A meeting whose speakers are still being told apart is saved when it ends and again once they're in.")
            note("Any app that can open the folder can read these files, and a folder that syncs (iCloud Drive, Dropbox…) uploads them.")
            if archive.isEnabled { status }
        }
    }

    private func note(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(AppTheme.font(.caption))
            .foregroundStyle(AppTheme.Text.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// What the last automatic save did, or what's waiting.
    @ViewBuilder
    private var status: some View {
        if archive.queued > 0 {
            HStack(spacing: AppTheme.Spacing.x2) {
                ProgressView().controlSize(.mini)
                Text(String(localized: "\(Int64(archive.queued)) meetings waiting to be saved to the folder…"))
            }
            .font(AppTheme.font(.footnote))
            .foregroundStyle(AppTheme.Status.info)
        }
        if let last = archive.lastResult {
            let time = last.date.formatted(date: .omitted, time: .shortened)
            switch last.item.outcome {
            case .written:
                line("checkmark.circle", AppTheme.Status.success, String(localized: "Saved at \(time): \(last.item.fileName)"))
            case .alreadyThere:
                line("info.circle", AppTheme.Status.info, String(localized: "At \(time) the meeting was already in the folder with the same content; nothing was added."))
            case .conflict:
                line("exclamationmark.triangle", AppTheme.Status.warning, String(localized: "Not saved at \(time): \(last.item.fileName) is already in the folder as \(MeetingArchiveSheet.reason(last.item.outcome)); it was left as it is."))
            case .failed:
                line("exclamationmark.triangle", AppTheme.Status.error, String(localized: "Not saved at \(time): \(MeetingArchiveSheet.reason(last.item.outcome))"))
            }
        } else if archive.queued == 0 {
            line("info.circle", AppTheme.Status.info, String(localized: "Nothing saved yet: the next meeting saved in History goes here."))
        }
    }

    private func line(_ icon: String, _ color: Color, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.x2) {
            Image(yapIcon: icon)
            Text(text).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
        .font(AppTheme.font(.footnote))
        .foregroundStyle(color)
        .accessibilityElement(children: .combine)
    }

    /// On with the folder chosen before; without one, the folder is chosen first (cancelled: stays off).
    private func turnOn() async {
        if archive.folder == nil {
            chooseFolder(turningOn: true)
        } else {
            await archive.turnOn()
        }
    }

    /// `turningOn`: picked from the switch, to turn it on; otherwise from Choose Folder….
    private func chooseFolder(turningOn: Bool = false) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Use This Folder")
        panel.message = String(localized: "Choose a folder for meetings saved from now on.")
        NSApp.activate(ignoringOtherApps: true)
        let chosen = panel.runModal() == .OK ? panel.url : nil
        Task { await archive.folderChosen(chosen, turningOn: turningOn) }
    }
}
