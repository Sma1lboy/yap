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
                    AppActionButton("Speaker Names…") { isEditingNames = true }
                        .disabled(isRegenerating)
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
            if let problem {
                Text(String(format: String(localized: "The notes weren't regenerated: %@ The previous notes are kept."), problem))
                    .font(AppTheme.font(.caption))
                    .foregroundStyle(AppTheme.Status.warning)
                    .fixedSize(horizontal: false, vertical: true)
            } else if renamed {
                Text("Names saved in the transcript. The notes still use the old names: click Regenerate Notes to update them.")
                    .font(AppTheme.font(.caption))
                    .foregroundStyle(AppTheme.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: transcription.id) {
            if speakers == nil { speakers = MeetingEdits.segments(of: transcription).map(MeetingEdits.speakers) }
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
