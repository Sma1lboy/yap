# Meeting recording (P0)

One shortcut (right ⌘ + Space by default) starts a long recording of the microphone and the sound from other apps; only ✓ in the meeting panel stops it (the shortcut then just brings the panel forward). Yap transcribes while the meeting goes on and writes notes when it stops. Nothing is pasted: the result is one History entry and a small window with the notes.

## How it works

| Step | What happens | Code |
|---|---|---|
| Microphone ("Me") | Its own `CoreAudioRecorder` on the current recording device. It doesn't go through dictation's `Recorder`, so the output isn't muted and media isn't paused. Dictation during a meeting also skips both. | `MeetingRecorder.Session`, `Recorder.startRecording` |
| System audio ("Others") | A Core Audio process tap on every process except Yap (`CATapDescription(stereoGlobalTapButExcludeProcesses:)`), inside a private aggregate device built on the current output device, read with an IOProc. Downmixed and resampled to 16 kHz mono with `PCMResampler`. When the default output changes (AirPods), the aggregate device is rebuilt. | `SystemAudioTap` |
| Timeline | Both channels are written to `mic.wav` / `system.wav` and kept on the wall clock: if a channel falls more than 0.5 s behind (device switch, stalled device), the gap is filled with silence, so both timelines stay aligned. | `MeetingRecorder.Channel` |
| Pieces | Each channel is cut at the quietest 100 ms between 20 and 28 s. Pieces below about −50 dBFS are dropped (Whisper invents text for silence). Leading silence is trimmed, so the timestamp is where speech starts. | `MeetingChunker` |
| Transcription | One piece at a time, in order, through `TranscriptionServiceRegistry` with the mode's model and language, the same entry point dictation uses (local Whisper, cloud, Yap Cloud…). A piece that fails keeps its line in the transcript, `[01:02] Others: (This part couldn't be transcribed.)` (`failed` in `segments.json`); the panel and the History row say "N parts couldn't be transcribed". The notes are written from the other lines. | `MeetingRecorder.Transcriber`, `MeetingNotes.failedMarker` |
| Remote speakers | After the last piece is transcribed and only if "Others" spoke and the meeting is at least 15 s: `system.wav` is diarized once, offline, with FluidAudio's `OfflineDiarizerManager` (VBx clustering). Each "Others" piece takes the speaker it overlaps most, numbered by first appearance: `Others 1`, `Others 2` (`segments.json` gets a `remote` field). Speakers with under 3 s of speech are ignored; with fewer than two real speakers, or on any failure or timeout (60 s + half the meeting), the lines stay plain "Others" and the panel says why in one line (too short, only one other person, timed out, speaker model download failed, failed). Nothing is said when it worked or when nobody on the other side spoke. The models (Segmentation, FBank, Embedding, PldaRho) download on first use into `<Yap support folder>/SpeakerModels`, never FluidAudio's own Application Support folder; the panel shows "Downloading the speaker model… n%". Me is never diarized. | `MeetingDiarizer`, `SpeakerLabels`, `SpeakerSplitSkip`, `MeetingRecorder.labelRemoteSpeakers` |
| Notes | After the last piece: the mode's AI provider with a built-in "Meeting Notes" prompt (summary, decisions, action items with owner and due date, open questions; notes in the meeting's main language, English terms kept). The timeout is 30 s plus 1 s per 100 characters, up to 300 s, instead of dictation's 7 s. Transcripts over 12,000 characters are summarized in parts, and the parts' notes are merged. Yap Refine or no configured provider: transcript only, with a hint. The panel and History show the notes rendered (headings, lists, to-do boxes); copy and export give the Markdown. **Regenerate Notes** (panel, and the expanded History row) runs the same summarizer again with the current mode's provider and the speakers' names, from `segments.json` without the failed pieces. While it runs the row shows "Writing notes…"; if it can't (AI enhancement off, no provider, Yap Refine, the request failed) it says why and the old notes stay. On success `enhancedText`, the model name and the request are replaced. History's "re-enhance with a prompt" is hidden for meetings (player and quick history), since a dictation prompt would overwrite the notes. | `MeetingSummarizer`, `MeetingNotes`, `MeetingEdits`, `MeetingRowTools` |
| Saving | One `Transcription` with `kind = "meeting"`: `text` is the timestamped transcript (`[00:12] Me: …`), `enhancedText` the notes, `audioFileURL` the mix of both channels. The folder `Recordings/meetings/<id>/` also holds `mic.wav`, `system.wav` and `segments.json`. Deleting the entry, or audio retention, removes the whole folder. History can export a meeting as Markdown. **Speaker Names…** in the expanded History row names Me / Others / Others n (key `me`, `others`, `others-n`). The names are stored on the entry (`meetingSpeakerNamesJSON`; older entries have none), the transcript is rebuilt from `segments.json` with them (timestamps and pieces unchanged, `segments.json` untouched), and the export uses the new transcript. The notes aren't rewritten; the row offers Regenerate Notes, whose prompt then says who the user is and what the others are called. If saving the entry fails, or writing the Markdown file does, the panel shows the error and where the audio is, with Show in Finder. History doesn't offer Retranscribe for a meeting (see the limits). | `MeetingRecorder.finishMeeting`, `Transcription.removeAudio` |
| Recovery | At launch, a folder in `Recordings/meetings/` that no History entry refers to and that isn't being recorded or finished right now (a crash or quit mid-meeting, or a failed save) is finished the same way as a meeting that was stopped: transcribed from `mic.wav` / `system.wav`, speakers, notes, one History entry dated when the meeting started. It runs in the background, one folder at a time, and never uses the panel, so a new meeting can start meanwhile. A notification says it started and how it ended. The originals are moved aside as `*.orig` while the folder is rewritten and deleted only after the entry is saved. With no transcription model in the mode, or when the previous launch's attempt was cut off (so a crash in recovery can't loop), the entry is saved with the audio only, status Failed, and the reason as its text. A saved folder is never recovered again. | `MeetingRecovery.swift` |
| Consent | The first time, the panel explains what's recorded and that the user must tell everyone. "Copy Recording Notice" copies a two-language line for the meeting chat. While recording, the panel shows "Recording meeting" with a timer, and the menu bar shows ● and the time. Only ✓ in the panel ends a meeting; while recording, the menu item is "Show Meeting Panel". | `MeetingPanel.swift` |

Permission: `NSAudioCaptureUsageDescription` ("System Audio Recording Only"). macOS asks the first time the tap is used. There's no API to query the answer: when it's denied, the tap still runs but delivers only zeros. If system audio is all zeros 8 s in, Yap says so, with a button to the Privacy settings. The message allows for the call simply not having started.

## Verified here

`make meeting-files-check MODEL=<ggml-large-v3-turbo-q5_0.bin> [NOTES=1]` runs the whole pipeline without any capture permission. It builds a one-minute test meeting from `setup/asr/clips`: the Tingting clips are "Me", the Reed clips "Others", taking turns. It launches the mock identity with `--meeting-files mic.wav system.wav` and prints the result. Results on 2026-09-26 (M4 Pro):

- 41 s per channel, done 7.7 s after "stop", with local Whisper Large v3 Turbo (Quantized) and deepseek-v4.1-flash notes.
- Transcript lines interleave correctly: `[00:00] Me`, `[00:08] Others`, `[00:21] Others`, `[00:28] Me`.
- The notes have headings 摘要 / 决定 / 待办 / 未决问题, English terms are kept, and an owner and due date come out where they were said (Sara, 周四).
- Without `NOTES=1` the mode has AI enhancement off: the transcript is saved with the hint, and no model (local Ollama included) is started.
- Written to disk: `mic.wav mix.wav segments.json system.wav`.

Failures and recovery, 2026-09-30 (same script, which now always runs these): the first piece is made to fail (`--meeting-fail-pieces 1`, DEBUG only; a real failure can't be produced on demand) and the entry's save too (`--meeting-fail-save`). The transcript keeps exactly one marked line and the result counts 1. Then a folder cut off by a crash (both WAV headers with size 0, a leftover `pieces/`) is put next to the unsaved one, and the app is launched twice with `--meeting-recovery-check`: the first launch recovers both as transcribed meetings (`mix.wav`, `segments.json`, no `*.orig` or `pieces/` left), the second recovers nothing. A third folder, marked as a recovery that was cut off last time (in the attempted list, `mic.wav.orig` still aside), is saved with its audio only and the reason.

Speaker labels, 2026-09-29, same script with a second remote voice (Shelley says two lines between Reed's, made with `say`, 50 s per channel, Whisper base-q5_1 for speed): the two voices get `Others 1` and `Others 2` and the check (`labels: OK`, read from `segments.json`) requires one label per voice. Diarizing took 14.5 s and 32 s in two runs, each a cold run that included downloading the models; the run before had the models cached only inside the throwaway mock folder, so a warm figure per minute of audio is not measured yet. Nothing was written to `~/Library/Application Support/FluidAudio`.

Self-checks at launch cover:
- cutting and dropping pieces, the timeline, and the WAV writer;
- the transcript and Markdown format, splitting long transcripts, the timeout;
- mapping diarizer turns to `Others n` (order, noise speakers, one speaker, no overlap, old `segments.json`);
- the right-⌘ rule;
- deleting a meeting's folder;
- the failed-piece line, why speakers weren't told apart, and which folders count as interrupted (not one with an entry, not the meeting being recorded or finished);
- speaker names: applied to every line of that speaker (failed lines too), unnamed speakers keep their label, names cleaned (no colons or line breaks), stored and read back, an old `segments.json` without speaker numbers, and the prompt's names paragraph (none without names).

`make ui-snapshots` renders the panel in each state, in English and Chinese, including failed pieces, a failed save and a failed export.

Speaker names and regenerating, 2026-09-30 (same script, which now always runs these after recovery, `--meeting-edit-check`): the recovered meeting is renamed Me → Tingting, Others 1 → Reed, Others 2 → Shelley. The saved transcript and the Markdown then have only those names, the timestamps are the same and `segments.json` is byte for byte unchanged. Regenerating once without an AI provider (or, with `NOTES=1`, with an injected failed request, `--meeting-fail-notes 1`) keeps the old notes; with `NOTES=1` a second regenerate replaces them, and the sent prompt names all three (the notes gave Tingting's tasks to Tingting). A `segments.json` in the old format (no `remote` field) is renamed Others → Reed.

## Checks that need real permissions (to do by hand)

None of these can be run here without UI automation or permission prompts on the real desktop. Each can be checked afterwards from the files in the meeting's folder (`~/Library/Application Support/me.sma1lboy.yap/Recordings/meetings/<id>/`) or from History.

1. **The tap records.** Start a meeting recording (right ⌘ + Space) while a video plays in Safari and a call runs in Chrome. The first time, macOS asks for System Audio Recording: allow it. Talk a bit, stop after a minute.
   - Expected: `system.wav` has the video or call and none of Yap's own sounds; `mic.wav` has your voice; History shows "Others" lines.
2. **Permission denied.** Reset with `tccutil reset AudioCapture <bundle id>`, start again and deny.
   - Expected: recording continues, and within about 8 s a notice says there's no sound from other apps, with Open Settings; `system.wav` is silent.
   - Also check which Settings pane the button opens (it uses the Screen & System Audio Recording URL).
3. **Headphones switch.** During a recording, connect or disconnect AirPods (and switch the output in Control Center).
   - Expected: the recording continues. `system.wav` keeps recording after the switch, with a silent gap of about the switch time, and both files stay about the same length.
   - The microphone is not switched: if the input device disappears (AirPods were also the mic), "Me" goes silent for the rest of the meeting. See the limits below.
4. **Dictation during a meeting.** While recording, dictate once.
   - Expected: the call stays audible (no output mute) and isn't paused, and the dictation pastes as usual.
5. **Shortcut vs Spotlight.**
   - Left ⌘ + Space still opens Spotlight.
   - Right ⌘ + Space toggles meeting recording and does not open Spotlight.
   - After recording a different shortcut in Settings › Other Shortcuts › Record Meeting, only that one works.
6. **The panel doesn't take focus.** With a call or document focused, start and stop a recording.
   - Expected: typing keeps going to the other app, and the buttons in the panel still work.
7. **A long meeting.** One real meeting of 30–60 minutes.
   - Watch that transcription keeps up (pieces are 20–28 s).
   - Watch how long the notes take: a transcript over 12,000 characters is summarized in parts.
   - Disk use is about 115 MB per channel per hour, plus the mix.

## Known limits of P0

- **Timestamps are per piece** (20–28 s), not per sentence. One piece can hold two turns of the same speaker.
- **A piece with two remote speakers gets one label**, the one who spoke longer in it: pieces are cut at pauses, not at speaker changes, and the text can't be split without word timestamps. Speakers are not named, only numbered, and the numbers mean nothing in the next meeting.
- **Crosstalk:** without headphones the other side also reaches the microphone and shows up under "Me". No de-duplication yet.
- **Microphone device changes aren't followed.** Only the system audio side is rebuilt; the timeline stays aligned, but "Me" is lost after the input disappears.
- **Recovery is from the files only.** A meeting cut off by a crash is transcribed again from the start at the next launch (the pieces already transcribed weren't kept), so it takes about as long as finishing it would have. Its time is the folder's creation time. A folder with no audio at all (a crash in the first second) is left alone.
- **No "Retranscribe" for meetings.** Rerunning a meeting as one dictation would drop the two channels, the speakers and the notes, and rerunning the meeting steps would have to rewrite the notes too; History hides the action for meetings (row menu, player, quick history) and the service refuses a meeting's audio.
- **Names are per meeting.** Nothing carries a name to the next meeting, and renaming needs the meeting's folder (it's gone after audio retention). Names aren't asked for in the panel; they're set in History.
- **Notes need the mode's AI enhancement switch on.** With it off (a fresh install's default), the transcript is saved with a hint and no model, local ones included, is started.
- **Storage and cost:** WAV only, no m4a. A cloud transcription model is called once per piece, which for an hour-long meeting means 150–250 billed calls (Yap Cloud included).
