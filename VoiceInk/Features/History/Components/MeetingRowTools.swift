import SwiftData
import SwiftUI

/// A meeting's own actions in its expanded History row: write the notes again with the meeting prompt, and give
/// the speakers real names. Renaming rewrites the transcript only; the row then offers to regenerate the notes.
struct MeetingRowTools: View {
    let transcription: Transcription
    var onNotesRegenerated: () -> Void = {}

    @Environment(\.modelContext) private var modelContext
    @State private var speakers: [(key: String, label: String)]?
    @State private var isRegenerating: Bool
    @State private var problem: String?
    @State private var renamed: Bool
    @State private var isEditingNames = false

    /// The other parameters are for make ui-snapshots (a popover and a running task can't be rendered).
    init(
        transcription: Transcription, onNotesRegenerated: @escaping () -> Void = {},
        speakers: [(key: String, label: String)]? = nil, isRegenerating: Bool = false, problem: String? = nil,
        renamed: Bool = false
    ) {
        self.transcription = transcription
        self.onNotesRegenerated = onNotesRegenerated
        #if DEBUG
            _speakers = State(initialValue: speakers ?? Self.snapshotSpeakers)
        #else
            _speakers = State(initialValue: speakers)
        #endif
        _isRegenerating = State(initialValue: isRegenerating)
        _problem = State(initialValue: problem)
        _renamed = State(initialValue: renamed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.x2) {
            HStack(spacing: AppTheme.Spacing.x2) {
                AppActionButton("Regenerate Notes") { Task { await regenerate() } }
                    .disabled(isRegenerating)
                    .help("Write the notes again with the meeting prompt and this mode's AI provider.")
                if let speakers, !speakers.isEmpty {
                    // Not while the others are still being told apart: the names would be for "Others", which goes away.
                    AppActionButton("Speaker Names…") { isEditingNames = true }
                        .disabled(isRegenerating || transcription.meetingSpeakerStatus == SpeakerSplitSkip.pendingStatus)
                        .popover(isPresented: $isEditingNames, arrowEdge: .bottom) {
                            MeetingSpeakerNamesEditor(
                                speakers: speakers, names: transcription.meetingSpeakerNames,
                                onCancel: { isEditingNames = false },
                                onSave: { names in
                                    let error = MeetingEdits.rename(transcription, names: names, in: modelContext)
                                    if error == nil {
                                        isEditingNames = false
                                        renamed = true
                                        problem = nil
                                    }
                                    return error
                                })
                        }
                }
                if isRegenerating {
                    ProgressView().controlSize(.small)
                    Text("Writing notes…")
                        .font(AppTheme.font(.caption))
                        .foregroundStyle(AppTheme.Text.secondary)
                }
                Spacer(minLength: 0)
            }
            // The panel's status line rule (MeetingStatusLine): stale or kept notes are a warning.
            if let problem {
                MeetingStatusLineView(line: .init(
                    kind: .warning,
                    text: String(format: String(localized: "The notes weren't regenerated: %@ The previous notes are kept."), problem)))
            } else if renamed {
                MeetingStatusLineView(line: .init(
                    kind: .warning,
                    text: String(localized: "Names saved in the transcript. The notes still use the old names: click Regenerate Notes to update them.")))
            }
        }
        .task(id: transcription.meetingSpeakerStatus) {
            // Again when the speakers told apart in the background arrive (the status goes from "pending" to nil).
            if let loaded = MeetingEdits.segments(of: transcription).map(MeetingEdits.speakers) { speakers = loaded }
        }
    }

    #if DEBUG
        /// make ui-snapshots: the speakers of a meeting that has no folder on disk.
        static var snapshotSpeakers: [(key: String, label: String)]?
    #endif

    private func regenerate() async {
        guard let engine = MeetingRecorder.shared.engine else { return }
        isRegenerating = true
        problem = nil
        problem = await MeetingEdits.regenerateNotes(for: transcription, engine: engine)
        isRegenerating = false
        if problem == nil {
            renamed = false
            onNotesRegenerated()
        }
    }
}

/// One field per speaker; an empty field goes back to "Me" / "Others 2".
struct MeetingSpeakerNamesEditor: View {
    let speakers: [(key: String, label: String)]
    let onCancel: () -> Void
    /// Returns why the names couldn't be saved.
    let onSave: (MeetingSpeakerNames) -> String?

    @State private var names: MeetingSpeakerNames
    @State private var error: String?

    init(
        speakers: [(key: String, label: String)], names: MeetingSpeakerNames, onCancel: @escaping () -> Void,
        onSave: @escaping (MeetingSpeakerNames) -> String?
    ) {
        self.speakers = speakers
        self.onCancel = onCancel
        self.onSave = onSave
        _names = State(initialValue: names)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.x3) {
            Text("Speaker Names").font(AppTheme.font(.body, .semibold))
            Text("Shown in the transcript and the Markdown export, and used for the notes when you regenerate them.")
                .font(AppTheme.font(.caption))
                .foregroundStyle(AppTheme.Text.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: AppTheme.Spacing.x3, verticalSpacing: AppTheme.Spacing.x2) {
                ForEach(speakers, id: \.key) { speaker in
                    GridRow {
                        Text(verbatim: speaker.label)
                            .font(AppTheme.font(.callout))
                            .foregroundStyle(AppTheme.Text.secondary)
                        TextField(
                            speaker.label,
                            text: Binding(get: { names[speaker.key] ?? "" }, set: { names[speaker.key] = $0 }),
                            prompt: Text("Name"))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 180)
                    }
                }
            }
            if let error {
                Text(error)
                    .font(AppTheme.font(.caption))
                    .foregroundStyle(AppTheme.Status.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                AppActionButton("Cancel", action: onCancel)
                AppActionButton("Save", kind: .primary) { error = onSave(names) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(AppTheme.Spacing.x4)
        .frame(width: 320)
        .background(AppTheme.Surface.window)
        .popoverAppAppearance()
    }
}

/// Transcribe Meeting in an expanded History row: for a meeting saved with its audio only (MeetingRetranscription).
/// It says which model and language the mode has and where the recording goes, and starts only on Transcribe; while
/// it runs, the row shows the step and Cancel; afterwards, how it ended. A meeting it can't do says why, with no
/// button; without a transcription model in the mode, it offers the modes instead.
struct MeetingTranscribeTools: View {
    let transcription: Transcription

    /// What the user is asked to confirm: the mode's model and language, read when they clicked.
    struct Plan {
        let model: String
        let language: String
        let destination: String
        /// What runs; nil only in make ui-snapshots.
        let configuration: TranscriptionRuntimeConfiguration?

        init(_ configuration: TranscriptionRuntimeConfiguration) {
            self.init(
                model: configuration.model.displayName,
                language: TranscriptionLanguageSupport.displayName(configuration.language),
                destination: MeetingRetranscription.destination(of: configuration.model), configuration: configuration)
        }

        init(model: String, language: String, destination: String, configuration: TranscriptionRuntimeConfiguration? = nil) {
            (self.model, self.language, self.destination, self.configuration) = (model, language, destination, configuration)
        }
    }

    @ObservedObject private var retranscriber = MeetingRetranscriber.shared
    /// make ui-snapshots only; otherwise read from the entry and its folder on each render (a few `stat`s, and
    /// none for a meeting that has its transcript), so a folder removed meanwhile is seen.
    private let shownEligibility: MeetingRetranscription.Eligibility?
    @State private var plan: Plan?
    @State private var noModel: Bool
    @State private var refused: String?

    /// The other parameters are for make ui-snapshots.
    init(
        transcription: Transcription, eligibility: MeetingRetranscription.Eligibility? = nil, plan: Plan? = nil,
        noModel: Bool = false, refused: String? = nil
    ) {
        self.transcription = transcription
        shownEligibility = eligibility
        _plan = State(initialValue: plan)
        _noModel = State(initialValue: noModel)
        _refused = State(initialValue: refused)
    }

    private var state: MeetingRetranscriber.State? { retranscriber.states[transcription.id] }

    var body: some View {
        let eligibility = shownEligibility ?? MeetingRetranscription.eligibility(of: transcription)
        let reason = MeetingRetranscription.reason(for: eligibility)
        let canStart = if case .eligible = eligibility { true } else { false }
        // Nothing at all for a meeting with its transcript and no run: no gap in the row.
        if state != nil || plan != nil || canStart || reason != nil {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.x2) {
                if let state {
                    stateView(state)
                } else if let plan {
                    confirmation(plan)
                } else if canStart {
                    startButton
                } else if let reason {
                    MeetingStatusLineView(line: .init(kind: .warning, text: reason))
                }
                if noModel, plan == nil, state?.isActive != true {
                    HStack(spacing: AppTheme.Spacing.x2) {
                        MeetingStatusLineView(line: .init(
                            kind: .warning,
                            text: String(localized: "No transcription model is chosen in the current mode. Choose one in Modes, then transcribe the meeting.")))
                        AppActionButton("Open Modes") { ModeSetupNavigator.openModesSettings() }
                    }
                }
                if let refused, state?.isActive != true {
                    MeetingStatusLineView(line: .init(kind: .warning, text: refused))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var startButton: some View {
        HStack(spacing: AppTheme.Spacing.x2) {
            AppActionButton("Transcribe Meeting…") { prepare() }
                .help("Transcribe this meeting from its microphone and system audio recordings, with this mode's model.")
            Text("Only its audio was saved.")
                .font(AppTheme.font(.caption))
                .foregroundStyle(AppTheme.Text.secondary)
            Spacer(minLength: 0)
        }
    }

    private func confirmation(_ plan: Plan) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.x2) {
            Text(String(format: String(localized: "Transcribe with %@, language %@ (this mode's settings now)."), plan.model, plan.language))
                .font(AppTheme.font(.callout, .medium))
                .foregroundStyle(AppTheme.Text.primary)
                .fixedSize(horizontal: false, vertical: true)
            Text(plan.destination)
                .font(AppTheme.font(.caption))
                .foregroundStyle(AppTheme.Text.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("The whole recording is transcribed again, then speakers are told apart and notes are written by this mode's AI provider, if it has one. The entry stays as it is until that's done; canceling or a failure changes nothing. Each try is a new full run, so a cloud model is called again.")
                .font(AppTheme.font(.caption))
                .foregroundStyle(AppTheme.Text.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: AppTheme.Spacing.x2) {
                Spacer(minLength: 0)
                AppActionButton("Cancel") { self.plan = nil }
                AppActionButton("Transcribe", kind: .primary) { begin(plan) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(AppTheme.Spacing.x3)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous).fill(AppTheme.Surface.subtle))
    }

    @ViewBuilder
    private func stateView(_ state: MeetingRetranscriber.State) -> some View {
        switch state {
        case .running(let step):
            HStack(spacing: AppTheme.Spacing.x2) {
                MeetingStatusLineView(line: .init(kind: .progress, text: step))
                AppActionButton("Cancel") { retranscriber.cancel(transcription.id) }
                Spacer(minLength: 0)
            }
        case .canceling:
            MeetingStatusLineView(line: .init(kind: .progress, text: String(localized: "Canceling… The part being transcribed finishes first.")))
        case .done(let result):
            // The panel's lines for the new result (failed parts, why no notes or speakers, echo), with "Transcribed"
            // first among the information, in MeetingStatusLine's order.
            let transcribed = MeetingStatusLine(
                kind: .info, text: String(localized: "Transcribed. This entry now has the meeting's transcript."))
            let lines = ([transcribed] + result.statusLines).enumerated()
                .sorted { ($0.element.kind, $0.offset) < ($1.element.kind, $1.offset) }.map(\.element)
            ForEach(lines, id: \.self) { MeetingStatusLineView(line: $0) }
        case .failed(let error):
            MeetingStatusLineView(line: .init(
                kind: .error,
                text: String(format: String(localized: "The meeting wasn't transcribed: %@ The entry and its recordings are unchanged."), error)))
            retryButton
        case .canceled:
            MeetingStatusLineView(line: .init(kind: .info, text: String(localized: "Canceled. The entry and its recordings are unchanged.")))
            retryButton
        }
    }

    @ViewBuilder
    private var retryButton: some View {
        if transcription.transcriptionStatus == TranscriptionStatus.failed.rawValue, plan == nil {
            AppActionButton("Transcribe Meeting…") { prepare() }
        }
    }

    /// The mode's model and language now; with none, the way to choose one, and nothing starts.
    private func prepare() {
        refused = nil
        if let busy = retranscriber.busyReason() {
            refused = busy
            return
        }
        guard let engine = MeetingRecorder.shared.engine,
            let configuration = ModeRuntimeResolver.transcriptionConfiguration(
                transcriptionModelManager: engine.transcriptionModelManager)
        else {
            noModel = true
            return
        }
        noModel = false
        plan = Plan(configuration)
    }

    private func begin(_ plan: Plan) {
        self.plan = nil
        guard let configuration = plan.configuration else { return }
        refused = retranscriber.start(transcription, configuration: configuration)
    }
}
