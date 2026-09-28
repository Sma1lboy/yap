# Meeting recording (P0)

One shortcut (right ⌘ + Space by default) starts a long recording of the microphone and the sound from other apps; the same shortcut stops it. Yap transcribes while the meeting goes on and writes notes when it stops. Nothing is pasted: the result is one History entry and a small window with the notes.

## How it works

| Step | What happens | Code |
|---|---|---|
| Microphone ("Me") | Its own `CoreAudioRecorder` on the current recording device. It doesn't go through dictation's `Recorder`, so the output isn't muted and media isn't paused. Dictation during a meeting also skips both. | `MeetingRecorder.Session`, `Recorder.startRecording` |
| System audio ("Others") | A Core Audio process tap on every process except Yap (`CATapDescription(stereoGlobalTapButExcludeProcesses:)`), inside a private aggregate device built on the current output device, read with an IOProc. Downmixed and resampled to 16 kHz mono with `PCMResampler`. When the default output changes (AirPods), the aggregate device is rebuilt. | `SystemAudioTap` |
| Timeline | Both channels are written to `mic.wav` / `system.wav` and kept on the wall clock: if a channel falls more than 0.5 s behind (device switch, stalled device), the gap is filled with silence, so both timelines stay aligned. | `MeetingRecorder.Channel` |
| Pieces | Each channel is cut at the quietest 100 ms between 20 and 28 s. Pieces below about −50 dBFS are dropped (Whisper invents text for silence). Leading silence is trimmed, so the timestamp is where speech starts. | `MeetingChunker` |
| Transcription | One piece at a time, in order, through `TranscriptionServiceRegistry` with the mode's model and language, the same entry point dictation uses (local Whisper, cloud, Yap Cloud…). | `MeetingRecorder.Transcriber` |
| Notes | After the last piece: the mode's AI provider with a built-in "Meeting Notes" prompt (summary, decisions, action items with owner and due date, open questions; notes in the meeting's main language, English terms kept). The timeout is 30 s plus 1 s per 100 characters, up to 300 s, instead of dictation's 7 s. Transcripts over 12,000 characters are summarized in parts, and the parts' notes are merged. Yap Refine or no configured provider: transcript only, with a hint. | `MeetingSummarizer`, `MeetingNotes` |
| Saving | One `Transcription` with `kind = "meeting"`: `text` is the timestamped transcript (`[00:12] Me: …`), `enhancedText` the notes, `audioFileURL` the mix of both channels. The folder `Recordings/meetings/<id>/` also holds `mic.wav`, `system.wav` and `segments.json`. Deleting the entry, or audio retention, removes the whole folder. History can export a meeting as Markdown. | `MeetingRecorder.complete`, `Transcription.removeAudio` |
| Consent | The first time, the panel explains what's recorded and that the user must tell everyone. "Copy Recording Notice" copies a two-language line for the meeting chat. While recording, the panel shows "Recording meeting" with a timer, and the menu bar shows ● and the time. | `MeetingPanel.swift` |

Permission: `NSAudioCaptureUsageDescription` ("System Audio Recording Only"). macOS asks the first time the tap is used. There's no API to query the answer: when it's denied, the tap still runs but delivers only zeros. If system audio is all zeros 8 s in, Yap says so, with a button to the Privacy settings. The message allows for the call simply not having started.

## Verified here

`make meeting-files-check MODEL=<ggml-large-v3-turbo-q5_0.bin> [NOTES=1]` runs the whole pipeline without any capture permission. It builds a one-minute test meeting from `setup/asr/clips`: the Tingting clips are "Me", the Reed clips "Others", taking turns. It launches the mock identity with `--meeting-files mic.wav system.wav` and prints the result. Results on 2026-09-26 (M4 Pro):

- 41 s per channel, done 7.7 s after "stop", with local Whisper Large v3 Turbo (Quantized) and deepseek-v4.1-flash notes.
- Transcript lines interleave correctly: `[00:00] Me`, `[00:08] Others`, `[00:21] Others`, `[00:28] Me`.
- The notes have headings 摘要 / 决定 / 待办 / 未决问题, English terms are kept, and an owner and due date come out where they were said (Sara, 周四).
- Without an API key, the fresh install's default provider was the Ollama running on this Mac (`qwen3.8:27b-mlx`), which wrote notes too. With no provider at all, the transcript is saved with the hint.
- Written to disk: `mic.wav mix.wav segments.json system.wav`.

Self-checks at launch cover:
- cutting and dropping pieces, the timeline, and the WAV writer;
- the transcript and Markdown format, splitting long transcripts, the timeout;
- the right-⌘ rule;
- deleting a meeting's folder.

`make ui-snapshots` renders the panel in each state, in English and Chinese.

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
- **Crosstalk:** without headphones the other side also reaches the microphone and shows up under "Me". No de-duplication yet.
- **Microphone device changes aren't followed.** Only the system audio side is rebuilt; the timeline stays aligned, but "Me" is lost after the input disappears.
- **Orphaned folders stay:** a crash mid-recording leaves a folder without a History entry, and the Recordings sweep no longer deletes folders.
- **No "regenerate notes".** History's re-enhance uses the mode's normal prompt, not the meeting prompt.
- **Notes can use a provider you didn't expect.** They use the mode's resolved AI provider even when the mode's AI enhancement switch is off; on a fresh install that can be a local Ollama.
- **Storage and cost:** WAV only, no m4a. A cloud transcription model is called once per piece, which for an hour-long meeting means 150–250 billed calls (Yap Cloud included).
