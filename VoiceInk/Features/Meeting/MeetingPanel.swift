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
            Text("Recording a Meeting").font(AppTheme.font(.headline, .semibold)).accessibilityAddTraits(.isHeader)
            Text("Yap records your microphone and the sound from other apps, transcribes it on the fly with this mode's model, and writes notes when you stop. To stop, click ✓ in this panel; the keyboard never stops a meeting.")
                .font(AppTheme.font(.callout))
                .fixedSize(horizontal: false, vertical: true)
            Text("You're responsible for telling everyone in the meeting and getting their consent. Recording people without it can be against the law (in China, the EU and many US states, among others) or your company's rules.")
                .font(AppTheme.font(.caption))
                .foregroundColor(AppTheme.Text.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // One row when the labels fit; otherwise the copy button goes above, so none is cut off (French).
            ViewThatFits(in: .horizontal) {
                HStack {
                    copyNoticeButton
                    Spacer()
                    consentChoices
                }
                VStack(alignment: .leading, spacing: AppTheme.Spacing.x2) {
                    copyNoticeButton
                    HStack {
                        Spacer()
                        consentChoices
                    }
                }
            }
            .controlSize(.small)
        }
    }

    private var copyNoticeButton: some View {
        Button("Copy Recording Notice") { MeetingConsentNotice.copy() }
            .fixedSize()
    }

    @ViewBuilder private var consentChoices: some View {
        Button("Cancel") { recorder.cancelConsent() }
            .fixedSize()
        Button("Start Recording") { recorder.acceptConsentAndStart() }
            .keyboardShortcut(.defaultAction)
            .fixedSize()
    }

    /// Only a click on ✓ ends the meeting, and it always keeps it: there's no discard, and the keyboard (the
    /// meeting shortcut included) never stops it.
    private func recording(since started: Date) -> some View {
        HStack(spacing: AppTheme.Spacing.x3) {
            Circle().fill(AppTheme.Status.error).frame(width: 10, height: 10).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: AppTheme.Spacing.x1) {
                // Wraps rather than being cut off (German, French).
                Text("Recording meeting").font(AppTheme.font(.callout, .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                TimelineView(.periodic(from: started, by: 1)) { context in
                    if let until = recorder.stopReminderUntil, context.date < until {
                        Text("Still recording. Click ✓ to end the meeting.")
                            .font(AppTheme.font(.caption))
                            .foregroundColor(AppTheme.Text.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(MeetingNotes.timestamp(context.date.timeIntervalSince(started)))
                            .font(AppTheme.font(.caption)).monospacedDigit()
                            .foregroundColor(AppTheme.Text.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
            Button("Copy Notice") { MeetingConsentNotice.copy() }
                .help("Copy a short note for the meeting chat saying you're recording.")
                .controlSize(.small)
                .fixedSize()
            AppIconButton(systemName: "checkmark", help: "End Meeting and Save", size: 32, iconSize: 15) {
                Task { await recorder.stop() }
            }
        }
    }

    private func done(_ result: MeetingRecorder.MeetingResult) -> some View {
        let lines = result.statusLines
        return VStack(alignment: .leading, spacing: AppTheme.Spacing.x3) {
            Text(result.notes == nil ? "Meeting Transcript" : "Meeting Notes")
                .font(AppTheme.font(.headline, .semibold))
                .accessibilityAddTraits(.isHeader)
            // Errors, then warnings, then information (MeetingStatusLine), closer together than the panel's parts;
            // the folder goes with the save error.
            if !lines.isEmpty {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.x2) {
                    ForEach(lines.filter { $0.kind == .error }, id: \.self) { MeetingStatusLineView(line: $0) }
                    if result.saveError != nil, let folder = result.folder {
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
                                .fixedSize()
                        }
                    }
                    ForEach(lines.filter { $0.kind != .error }, id: \.self) { MeetingStatusLineView(line: $0) }
                }
            }
            ScrollView {
                // Notes are Markdown (headings, lists, to-dos); copy and export keep the Markdown source.
                if let notes = result.notes {
                    MarkdownContentView(notes, fontSize: 13, foregroundColor: AppTheme.Text.primary)
                } else if result.transcript.isEmpty {
                    Text("(Nothing was said in this meeting.)")
                        .font(AppTheme.font(.callout))
                        .foregroundColor(AppTheme.Text.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
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
                if result.notes != nil || !result.transcript.isEmpty {
                    Button(result.notes == nil ? "Copy Transcript" : "Copy Notes") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(result.notes ?? result.transcript, forType: .string)
                    }
                    .fixedSize()
                }
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
                // A meeting that couldn't be saved isn't in History (yet).
                if result.saveError == nil {
                    Button("Open History") {
                        HistoryNavigator.open()
                        recorder.dismissResult()
                    }
                    .fixedSize()
                }
                Button("Close") { recorder.dismissResult() }
                    .fixedSize()
            }
            .controlSize(.small)
        }
    }
}

/// One line above a finished meeting's notes, in the order the panel shows them: errors (something wasn't saved or
/// written), then warnings (part of the result is missing or out of date, and what to do about it), then
/// information (what Yap did, or is still doing). The rule is in docs/DESIGN.md › 会议的状态行.
struct MeetingStatusLine: Hashable {
    enum Kind: Int, Comparable {
        case error, warning, info, progress

        /// Progress sorts with information: it's something Yap is doing, not something to act on.
        var rank: Int { min(rawValue, Kind.info.rawValue) }
        static func < (a: Kind, b: Kind) -> Bool { a.rank < b.rank }
    }

    let kind: Kind
    let text: String
}

extension MeetingRecorder.MeetingResult {
    var statusLines: [MeetingStatusLine] {
        var lines: [MeetingStatusLine] = []
        func add(_ kind: MeetingStatusLine.Kind, _ text: String) { lines.append(.init(kind: kind, text: text)) }

        if let saveError {
            add(.error, String(format: String(localized: "This meeting couldn't be saved to History: %@ Its audio is kept, and Yap tries again the next time it starts."), saveError))
        }
        if let exportError {
            add(.error, String(format: String(localized: "The Markdown file couldn't be written: %@"), exportError))
        }
        if failedPieces > 0 {
            add(.warning, String(localized: "\(Int64(failedPieces)) parts couldn't be transcribed; they're marked in the transcript."))
        }
        if let notesProblem { add(.warning, notesProblem) }
        if isRegenerating {
            add(.progress, String(localized: "Writing notes…"))
        } else if let regenerateProblem {
            add(.warning, String(format: String(localized: "The notes weren't regenerated: %@ The previous notes are kept."), regenerateProblem))
        }
        if let speakersSkipped { add(speakersSkipped.isFailure ? .warning : .info, speakersSkipped.message) }
        if let speakersPending {
            add(.progress, speakersPending)
            add(.info, String(localized: "The meeting is saved. Its transcript gets Others 1, Others 2… when this is done; you can close this panel."))
        } else if speakersLabeledLater, notes != nil {
            add(.warning, String(localized: "The transcript now tells the other speakers apart. The notes still say \"Others\": click Regenerate Notes to update them."))
        }
        if echoRemoved > 0 {
            add(.info, String(localized: "Removed \(Int64(echoRemoved)) echoes: your microphone picked up the other side from the speakers."))
        }
        // Stable: within a kind, the order above.
        return lines.enumerated().sorted { ($0.element.kind, $0.offset) < ($1.element.kind, $1.offset) }.map(\.element)
    }
}

/// A status line: red or orange with a warning sign, or secondary with an info sign or a spinner.
struct MeetingStatusLineView: View {
    let line: MeetingStatusLine

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.x2) {
            switch line.kind {
            case .progress:
                ProgressView().controlSize(.mini)
            case .error, .warning:
                Image(yapIcon: "exclamationmark.triangle")
            case .info:
                Image(yapIcon: "info.circle")
            }
            Text(line.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(AppTheme.font(.caption))
        .foregroundStyle(color)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(line.text)
    }

    private var color: Color {
        switch line.kind {
        case .error: return AppTheme.Status.error
        case .warning: return AppTheme.Status.warning
        case .info, .progress: return AppTheme.Text.secondary
        }
    }
}

#if DEBUG
    extension MeetingStatusLine {
        /// Errors first, then warnings, then information and progress, whatever order they come in.
        @MainActor static func selfCheck() {
            typealias Result = MeetingRecorder.MeetingResult
            let everything = Result(
                transcriptionID: UUID(), notes: "## Notes", transcript: "[00:00] Me: hi", notesProblem: "no provider",
                markdown: "", notesModel: nil, folder: nil, failedPieces: 2, speakersSkipped: .timedOut, echoRemoved: 3,
                saveError: "disk full", exportError: "no permission", regenerateProblem: "timed out", speakersLabeledLater: true)
            let kinds = everything.statusLines.map(\.kind)
            assert(kinds == kinds.sorted(), "status lines out of order: \(kinds)")
            assert(kinds.prefix(2) == [.error, .error] && kinds.last == .info)
            assert(everything.statusLines.filter { $0.kind == .warning }.count == 5)
            // Too short or one speaker is information; a failure to tell them apart is a warning.
            func kind(_ skip: SpeakerSplitSkip) -> MeetingStatusLine.Kind? {
                Result(transcriptionID: UUID(), notes: nil, transcript: "x", notesProblem: nil, markdown: "", notesModel: nil,
                    speakersSkipped: skip).statusLines.first?.kind
            }
            assert(kind(.tooShort) == .info && kind(.oneSpeaker) == .info)
            assert(kind(.timedOut) == .warning && kind(.modelDownloadFailed) == .warning && kind(.failed) == .warning)
            // Still telling speakers apart: the spinner, then what it means; never the "labeled later" hint with it.
            let pending = Result(
                transcriptionID: UUID(), notes: "n", transcript: "x", notesProblem: nil, markdown: "", notesModel: nil,
                speakersPending: "…", speakersLabeledLater: true).statusLines
            assert(pending.map(\.kind) == [.progress, .info])
            // Regenerating replaces the last try's problem with its spinner.
            let regenerating = Result(
                transcriptionID: UUID(), notes: "n", transcript: "x", notesProblem: nil, markdown: "", notesModel: nil,
                isRegenerating: true, regenerateProblem: "old").statusLines
            assert(regenerating.map(\.kind) == [.progress])
            // Nothing went wrong and nothing to say: no lines. Nothing said: no notes to write again.
            let clean = Result(transcriptionID: UUID(), notes: "n", transcript: "x", notesProblem: nil, markdown: "", notesModel: nil)
            assert(clean.statusLines.isEmpty && clean.canRegenerate)
            let silent = Result(transcriptionID: UUID(), notes: nil, transcript: "", notesProblem: nil, markdown: "", notesModel: nil)
            assert(!silent.canRegenerate)
        }
    }
#endif

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

/// Next to the duck in the menu bar while a meeting records: a red dot and the elapsed time. Ticks from a one-second
/// timer. With a TimelineView here the status item was redrawn without pause for the whole meeting (a sample of the
/// main thread: 99% in MenuBarExtraController.updateButton), so the meeting's pieces and End Meeting and Quit waited
/// behind it on the main actor.
struct MeetingMenuBarBadge: View {
    @ObservedObject var recorder = MeetingRecorder.shared
    @State private var now = Date()

    var body: some View {
        if case .recording(let started) = recorder.phase {
            Text("● " + MeetingNotes.timestamp(max(0, now.timeIntervalSince(started))))
                .monospacedDigit()
                .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { now = $0 }
        }
    }
}
