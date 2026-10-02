import AppKit
import SwiftUI

/// In History's selection bar when the selection holds meetings: how many, never the dictations next to them.
struct MeetingArchiveButton: View {
    let meetings: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(String(localized: "Save \(Int64(meetings)) Meetings…"), yapIcon: "folder")
                .font(AppTheme.font(.footnote, .medium))
                .lineLimit(1)
                .fixedSize()
        }
        .buttonStyle(.plain)
        .foregroundColor(.secondary)
        .help(String(localized: "Save \(Int64(meetings)) Meetings…"))
    }
}

/// Saves the selected meetings as Markdown files in a folder the user picks (MeetingArchive): first what will
/// happen, then what did, file by file where something wasn't saved.
struct MeetingArchiveSheet: View {
    enum Phase {
        case confirm, writing
        case done(MeetingArchive.Report)
    }

    private let meetings: [Transcription]
    private let dictations: Int
    private let onClose: () -> Void
    @State private var phase: Phase

    /// `phase` is for make ui-snapshots (a folder can't be picked there).
    init(selection: [Transcription], onClose: @escaping () -> Void, phase: Phase = .confirm) {
        meetings = selection.filter(\.isMeeting)
        dictations = selection.count - meetings.count
        self.onClose = onClose
        _phase = State(initialValue: phase)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.x3) {
            Text("Save Meetings to Folder").font(AppTheme.font(.body, .semibold))
            switch phase {
            case .confirm, .writing: explanation
            case .done(let report): results(report)
            }
            HStack(spacing: AppTheme.Spacing.x2) {
                if case .writing = phase {
                    ProgressView().controlSize(.small)
                    Text("Saving…").font(AppTheme.font(.footnote)).foregroundStyle(AppTheme.Text.secondary)
                }
                Spacer()
                switch phase {
                case .confirm, .writing:
                    AppActionButton("Cancel", action: onClose)
                        .keyboardShortcut(.cancelAction)
                    AppActionButton("Choose Folder…", kind: .primary, action: chooseFolder)
                        .keyboardShortcut(.defaultAction)
                case .done(let report):
                    if report.items.contains(where: { $0.outcome != .failed(.folderMissing) }) {
                        AppActionButton("Show in Finder") { showInFinder(report) }
                    } else {
                        // The folder is gone: the way out is another one, for the same meetings.
                        AppActionButton("Choose Folder…", action: chooseFolder)
                    }
                    AppActionButton("Done", kind: .primary, action: onClose)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .disabled(isWriting)
        }
        .padding(AppTheme.Spacing.x5)
        .frame(width: 480)
        .background(AppTheme.Surface.window)
    }

    private var isWriting: Bool {
        if case .writing = phase { return true }
        return false
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.x2) {
            Text(String(localized: "\(Int64(meetings.count)) meetings, one Markdown file each, as Export Markdown writes them."))
                .font(AppTheme.font(.footnote))
            if dictations > 0 {
                Text(String(localized: "\(Int64(dictations)) selected dictations aren't included: only meetings are saved."))
                    .font(AppTheme.font(.footnote))
            }
            note("Files already in the folder are never replaced. When a meeting has changed since it was last saved there (speaker names, notes, Yap's language or time zone), a new file is added next to the old one, which stays as it was.")
            note("These files are separate from History: deleting a meeting there, or History deleting it after the retention period, doesn't remove them. Any app that can open the folder can read them, and a folder that syncs (iCloud Drive, Dropbox…) uploads them.")
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func note(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(AppTheme.font(.caption))
            .foregroundStyle(AppTheme.Text.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func results(_ report: MeetingArchive.Report) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.x2) {
            Text(verbatim: report.folder.path)
                .font(AppTheme.font(.caption))
                .foregroundStyle(AppTheme.Text.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            if report.written > 0 {
                line("checkmark.circle", AppTheme.Status.success, String(localized: "\(Int64(report.written)) new files saved."))
            }
            if report.alreadyThere > 0 {
                line("info.circle", AppTheme.Status.info,
                    String(localized: "\(Int64(report.alreadyThere)) already in the folder with the same content; nothing added for them."))
            }
            if !report.conflicts.isEmpty {
                line("exclamationmark.triangle", AppTheme.Status.warning,
                    String(localized: "\(Int64(report.conflicts.count)) not saved: something else has the same name, and it was left as it is."))
                files(report.conflicts)
            }
            if !report.failures.isEmpty {
                line("exclamationmark.triangle", AppTheme.Status.error,
                    String(localized: "\(Int64(report.failures.count)) couldn't be saved:"))
                files(report.failures)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func line(_ icon: String, _ color: Color, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.x2) {
            Image(yapIcon: icon)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(AppTheme.font(.footnote))
        .foregroundStyle(color)
        .accessibilityElement(children: .combine)
    }

    /// Each file's name, then why. A batch failing for one reason (the folder is gone) says it once. At most
    /// `shownFiles` names, then how many more, so a hundred meetings in a vanished folder don't make the sheet taller
    /// than the screen.
    @ViewBuilder
    private func files(_ items: [MeetingArchive.Item]) -> some View {
        let reasons = Set(items.map { Self.reason($0.outcome) })
        let shared = reasons.count == 1 && items.count > 1 ? reasons.first : nil
        VStack(alignment: .leading, spacing: AppTheme.Spacing.x2) {
            if let shared {
                Text(shared).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(items.prefix(Self.shownFiles), id: \.fileName) { item in
                VStack(alignment: .leading, spacing: AppTheme.Spacing.half) {
                    Text(verbatim: item.fileName)
                        .foregroundStyle(AppTheme.Text.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if shared == nil {
                        Text(Self.reason(item.outcome)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if items.count > Self.shownFiles {
                Text(String(localized: "\(Int64(items.count - Self.shownFiles)) more"))
            }
        }
        .font(AppTheme.font(.caption))
        .foregroundStyle(AppTheme.Text.secondary)
        .padding(.leading, AppTheme.Spacing.x5)
        .textSelection(.enabled)
    }

    private static let shownFiles = 5

    static func reason(_ outcome: MeetingArchive.Outcome) -> String {
        switch outcome {
        case .written, .alreadyThere: return ""
        case .conflict(.differentContent): return String(localized: "a file with other content (perhaps an edited copy)")
        case .conflict(.symbolicLink): return String(localized: "a symbolic link")
        case .conflict(.notAFile): return String(localized: "a folder or another item")
        case .failed(.folderMissing): return String(localized: "The folder isn't there anymore, and Yap doesn't create it again. Choose a folder again.")
        case .failed(.notPermitted): return String(localized: "Yap isn't allowed to write to this folder.")
        case .failed(.unreadable): return String(localized: "Yap can't read the file with this name to compare it.")
        case .failed(.other(let code)): return NSError(domain: NSPOSIXErrorDomain, code: Int(code)).localizedDescription
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Save Here")
        panel.message = String(localized: "Choose a folder for the Markdown files.")
        NSApp.activate(ignoringOtherApps: true)
        // Cancelled: nothing is written.
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let entries = MeetingArchive.entries(for: meetings)
        phase = .writing
        Task {
            let report = await Task.detached { MeetingArchive.export(entries, to: folder) }.value
            phase = .done(report)
        }
    }

    private func showInFinder(_ report: MeetingArchive.Report) {
        let saved = report.items.filter { $0.outcome == .written || $0.outcome == .alreadyThere }
            .map { report.folder.appendingPathComponent($0.fileName) }
        NSWorkspace.shared.activateFileViewerSelecting(saved.isEmpty ? [report.folder] : saved)
    }
}
