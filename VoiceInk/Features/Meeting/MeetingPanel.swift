import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The floating meeting window: the consent note before the first recording, "Recording meeting" with a timer
/// while recording, progress while finishing, then the notes. Non-activating, so it never takes focus from the
/// call; it sits in the top-right corner of the screen with the pointer.
@MainActor
final class MeetingPanelController {
    static let shared = MeetingPanelController()
    private var panel: NSPanel?

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        position(panel)
        panel.orderFrontRegardless()
    }

    func close() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 120),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = true
        let host = NSHostingView(rootView: MeetingPanelView(recorder: MeetingRecorder.shared))
        host.sizingOptions = [.preferredContentSize]
        panel.contentView = host
        return panel
    }

    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        let frame = screen.visibleFrame
        panel.setFrameTopLeftPoint(NSPoint(x: frame.maxX - panel.frame.width - 16, y: frame.maxY - 16))
    }
}

/// Text for the meeting's chat, so the others know they're being recorded (in both languages on purpose).
enum MeetingConsentNotice {
    static let text = """
        本次会议由我在本机用 Yap 录音并转写，仅用于整理会议纪要。
        I'm recording and transcribing this meeting on my Mac with Yap, only to write meeting notes.
        """

    static func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

struct MeetingPanelView: View {
    @ObservedObject var recorder: MeetingRecorder

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.x3) {
            switch recorder.phase {
            case .idle:
                EmptyView()
            case .consent:
                consent
            case .recording(let started):
                recording(since: started)
            case .finishing(let message):
                HStack(spacing: AppTheme.Spacing.x3) {
                    ProgressView().controlSize(.small)
                    Text(message).font(AppTheme.font(.callout))
                }
            case .done(let result):
                done(result)
            }
        }
        .padding(AppTheme.Spacing.x4)
        .frame(width: 380, alignment: .leading)
        .background(AppMaterialCardBackground(cornerRadius: AppTheme.Radius.card))
    }

    private var consent: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.x3) {
            Text("Recording a Meeting").font(AppTheme.font(.headline, .semibold))
            Text("Yap records your microphone and the sound from other apps, transcribes it on the fly with this mode's model, and writes notes when you stop. To stop, click ✓ in this panel; the keyboard never stops a meeting.")
                .font(AppTheme.font(.callout))
                .fixedSize(horizontal: false, vertical: true)
            Text("You're responsible for telling everyone in the meeting and getting their consent. Recording people without it can be against the law (in China, the EU and many US states, among others) or your company's rules.")
                .font(AppTheme.font(.caption))
                .foregroundColor(AppTheme.Text.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Copy Recording Notice") { MeetingConsentNotice.copy() }
                Spacer()
                Button("Cancel") { recorder.cancelConsent() }
                Button("Start Recording") { recorder.acceptConsentAndStart() }
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
        }
    }

    /// Only a click on ✓ ends the meeting, and it always keeps it: there's no discard, and the keyboard (the
    /// meeting shortcut included) never stops it.
    private func recording(since started: Date) -> some View {
        HStack(spacing: AppTheme.Spacing.x3) {
            Circle().fill(AppTheme.Status.error).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: AppTheme.Spacing.x1) {
                Text("Recording meeting").font(AppTheme.font(.callout, .semibold))
                TimelineView(.periodic(from: started, by: 1)) { context in
                    if let until = recorder.stopReminderUntil, context.date < until {
                        Text("Still recording. Click ✓ to end the meeting.")
                            .font(AppTheme.font(.caption))
                            .foregroundColor(AppTheme.Text.secondary)
                    } else {
                        Text(MeetingNotes.timestamp(context.date.timeIntervalSince(started)))
                            .font(AppTheme.font(.caption)).monospacedDigit()
                            .foregroundColor(AppTheme.Text.secondary)
                    }
                }
            }
            Spacer()
            Button("Copy Notice") { MeetingConsentNotice.copy() }
                .help("Copy a short note for the meeting chat saying you're recording.")
                .controlSize(.small)
            AppIconButton(systemName: "checkmark", help: "End Meeting and Save", size: 32, iconSize: 15) {
                Task { await recorder.stop() }
            }
        }
    }

    private func done(_ result: MeetingRecorder.MeetingResult) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.x3) {
            Text(result.notes == nil ? "Meeting Transcript" : "Meeting Notes").font(AppTheme.font(.headline, .semibold))
            if let error = result.saveError {
                note(String(format: String(localized: "This meeting couldn't be saved to History: %@ Its audio is kept, and Yap tries again the next time it starts."), error), color: AppTheme.Status.error)
            }
            if let error = result.exportError {
                note(String(format: String(localized: "The Markdown file couldn't be written: %@"), error), color: AppTheme.Status.error)
            }
            if (result.saveError != nil || result.exportError != nil), let folder = result.folder {
                HStack(spacing: AppTheme.Spacing.x2) {
                    Text(String(format: String(localized: "Audio: %@"), (folder.path as NSString).abbreviatingWithTildeInPath))
                        .font(AppTheme.font(.caption))
                        .foregroundColor(AppTheme.Text.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer()
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                        .controlSize(.small)
                }
            }
            if result.failedPieces > 0 {
                note(String(localized: "\(Int64(result.failedPieces)) parts couldn't be transcribed; they're marked in the transcript."), color: AppTheme.Status.warning)
            }
            if let problem = result.notesProblem {
                note(problem, color: AppTheme.Status.warning)
            }
            if let skipped = result.speakersSkipped {
                note(skipped.message, color: AppTheme.Text.secondary)
            }
            if result.isRegenerating {
                HStack(spacing: AppTheme.Spacing.x2) {
                    ProgressView().controlSize(.small)
                    Text("Writing notes…").font(AppTheme.font(.caption)).foregroundColor(AppTheme.Text.secondary)
                }
            } else if let problem = result.regenerateProblem {
                note(String(format: String(localized: "The notes weren't regenerated: %@ The previous notes are kept."), problem),
                    color: AppTheme.Status.warning)
            }
            ScrollView {
                // Notes are Markdown (headings, lists, to-dos); copy and export keep the Markdown source.
                if let notes = result.notes {
                    MarkdownContentView(notes, fontSize: 13, foregroundColor: AppTheme.Text.primary)
                } else {
                    Text(result.transcript)
                        .font(AppTheme.font(.callout))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxHeight: 320)
            // Two rows, so no label is cut off in any language.
            HStack {
                Button(result.notes == nil ? "Copy Transcript" : "Copy Notes") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(result.notes ?? result.transcript, forType: .string)
                }
                .fixedSize()
                Button("Export Markdown…") { recorder.exportMarkdown() }
                    .fixedSize()
            }
            .controlSize(.small)
            HStack {
                if result.canRegenerate {
                    Button("Regenerate Notes") { Task { await recorder.regenerateNotes() } }
                        .fixedSize()
                        .disabled(result.isRegenerating)
                        .help("Write the notes again with the meeting prompt and this mode's AI provider.")
                }
                Spacer()
                Button("Open History") {
                    HistoryNavigator.open()
                    recorder.dismissResult()
                }
                .fixedSize()
                Button("Close") { recorder.dismissResult() }
                    .fixedSize()
            }
            .controlSize(.small)
        }
    }

    private func note(_ text: String, color: Color) -> some View {
        Text(text)
            .font(AppTheme.font(.caption))
            .foregroundColor(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Saves a meeting as Markdown where the user picks. Returns why writing the file failed; nil when it was
/// written or the user cancelled.
enum MeetingExport {
    @MainActor @discardableResult static func saveMarkdown(_ markdown: String, suggestedName: String? = nil) -> String? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = suggestedName
            ?? "\(String(localized: "Meeting")) \(Date().formatted(.iso8601.year().month().day())).md"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            try markdown.write(to: url, atomically: true, encoding: .utf8)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

/// Next to the duck in the menu bar while a meeting records: a red dot and the elapsed time.
struct MeetingMenuBarBadge: View {
    @ObservedObject var recorder = MeetingRecorder.shared

    var body: some View {
        if case .recording(let started) = recorder.phase {
            TimelineView(.periodic(from: started, by: 1)) { context in
                Text("● " + MeetingNotes.timestamp(context.date.timeIntervalSince(started)))
                    .monospacedDigit()
            }
        }
    }
}
