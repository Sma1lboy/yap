# Dictation latency: from letting go to the paste

What the user waits for after a dictation: from the moment they stop it to the ⌘V that puts the text in front of
them. Yap records this for every dictation on this Mac; `make dictation-latency` measures it without a microphone.

## What every dictation records

`DictationTimeline` follows one dictation; `SessionMetricRecorder` copies it onto the dictation's `SessionMetric` in
stats.store. Nothing leaves the Mac.

The stop (`stopSource`), on the clock of `ProcessInfo.systemUptime`:

| `stopSource` | When | Time used |
|---|---|---|
| `shortcutRelease` | push-to-talk, hybrid held past 0.5 s, double tap, Rewrite Last Dictation | the key-up event's own timestamp |
| `shortcutPress` | toggle mode, hybrid tapped: the second press stops | the second key-down event's timestamp |
| `recorderButton` | the recorder's record button | when the click was handled |
| `finishAndSend` | the recorder's Finish and Send | when it was handled |
| `other` | menu bar, Shortcuts app, anything else that toggles the recorder | when the stop was triggered |
| `file` | DEBUG `make dictation-latency` only | once the file is in place |

Shortcut event times come from the CGEvent itself (mach ticks converted to uptime, `ShortcutMonitor`), so a busy main
thread doesn't make the stop look later than it was. An event without a usable timestamp falls back to the time it
was handled and logs that once.

Then, in seconds after the stop (nil when the step didn't happen):

| Field | Step |
|---|---|
| `stopToRecorderStopped` | the recorder drained its buffers, flushed the resampler and closed the WAV (`CoreAudioRecorder.stopRecording`) |
| `stopToModelReady` | only when the transcription had to load the model first (preload hadn't finished, or a model it doesn't preload) |
| `stopToTranscribed` | the model returned its text |
| `stopToProcessed` | output filter, Chinese cleanup, trigger words, paragraph formatting and word replacements done |
| `stopToEnhanced` | AI cleanup returned or failed |
| `stopToPasteCommand` | the V key-down of ⌘V (AppleScript paste: when the script returned) |

`pasteOutcome`: `pasted` (⌘V sent), `clipboardOnly` (no Accessibility permission: the text was left on the clipboard
with a notification; Yap has no Scratchpad to fall back to), `failed` (clipboard couldn't be set or the key events
couldn't be sent). Nil when the text wasn't pasted: a response in the recorder, a custom command, "scratch that".

Metrics from before these fields existed read nil (optional attributes, SwiftData lightweight migration). Home and
Insights don't show any of this yet.

## Measuring it

```bash
make dictation-latency MODEL=~/path/to/ggml-large-v3-turbo-q5_0.bin [ROUNDS=12]
```

`scripts/dictation-latency.sh` runs the Debug app as the mock identity (its own defaults, Application Support and
keychain, as `make offline-check`) with one mode: MODEL, language auto, no AI cleanup. `DictationLatencyCheck` then
dictates five clips ROUNDS times each: `security`, `standup` and `perf` from `setup/asr/clips` (Chinese with English
terms, 5–8 s) and two English sentences made with `say -v Samantha` (7 s). Before each dictation it loads the model
the way a press does while the user speaks and lets the recording's context capture finish; after it, the times are
read back from the SessionMetric. One untimed dictation goes first.

The path after the stop is the real one (`runPipeline` → `TranscriptionPipeline` → `TranscriptionDelivery` →
`CursorPaster`), including the stop sound, the panel dismissal, the clipboard and every wait. Only the key events are
not posted (`CursorPaster.dryRun`): the ⌘V time is when V would have gone down, nothing is typed into the app in
front, and Auto Learn and Last Paste aren't told about it.

Not covered:

- **Recorder stop.** It needs the microphone, which the mock app doesn't have and shouldn't ask for. Real dictations
  record `stopToRecorderStopped`; read it from stats.store.
- **Cloud transcription.** The mock identity has no provider keys and the script doesn't borrow the dev app's.
  Yap Cloud's network latency is in [cloud-latency.md](cloud-latency.md).
- **Remote-desktop apps**, which get a 500 ms pre-paste wait instead of 100 ms (`CursorPaster.pasteTiming`).

## Results

Mac16,7 (M4 Pro, 48 GB), macOS 15.1, Large v3 Turbo (Quantized) `ggml-large-v3-turbo-q5_0.bin`, 12 rounds × 5 clips,
2026-09-30:

| step | n | p50 ms | p95 ms |
|---|---|---|---|
| stop → transcribed (checks and reads the WAV, decodes) | 60 | 1167 | 1207 |
| → filters and replacements done | 60 | 2 | 3 |
| → ⌘V (sound, panel, clipboard, waits) | 60 | 153 | 160 |
| **total, stop → ⌘V** | 60 | 1322 | 1362 |
| Chinese clips | 36 | 1338 | 1369 |
| English clips | 24 | 1286 | 1302 |

A Debug build with Swift optimization on (`-O`, whole module) gave the same total as the plain Debug build run just
before it (p50 1326 ms against 1330 ms), so unoptimized Swift doesn't move these numbers; the decode runs in the
prebuilt whisper.cpp framework either way.

When the model isn't loaded yet at the stop (stopped before the press-time preload finished), the transcription
loads it itself: `stopToModelReady` ≈ 220 ms and the total ≈ 1.5 s, about 180 ms more.

### Where the 1.3 s goes

Split further with temporary timing around each call (30 dictations, p50):

| # | Block | ms | share | Kind |
|---|---|---|---|---|
| 1 | Whisper decode (`whisper_full`) | 1130 | 85 % | compute; depends on model and audio length |
| 2 | Waits before ⌘V: `prePasteDelay` 100 ms + ⌘-down → V-down 10 ms (`pasteShortcutEventDelay`), as slept | 117 | 9 % | fixed constants |
| 3 | Everything else between the stop and ⌘V | 77 | 6 % | code path |
|   | · from the silence check to the Whisper service reading the WAV (service dispatch, loaded-model lookup; not split further) | 25 | | |
|   | · the paste task waits while the pipeline saves the transcription and SessionMetric and posts `transcriptionCompleted` | 15 | | |
|   | · audio duration read again (`AVURLAsset`) after the text is ready | 10 | | |
|   | · recording context snapshot hop | 9 | | |
|   | · WAV read into samples 8, silence check 5, filters 2, the rest 3 | 18 | | |

Stop sound, panel dismissal and setting the clipboard are each under 1 ms.

What could shrink (M3.2; nothing here was changed):

- The decode is the bulk. Options: a faster model or decode settings, trimming silence before the decode, or using
  the text the live preview already decoded while the user spoke.
- The 100 ms pre-paste wait gives the target app time to see the new clipboard; whether it can be shorter needs
  testing per app. The 10 ms between key events is small.
- Saving the transcription before the paste task runs, and reading the audio duration again, could move after ⌘V.
- The model is released after every dictation (`cleanupResources`) and loaded again at the next press, about 180 ms
  while the user speaks. A dictation stopped before that load finishes loads a second copy in
  `WhisperTranscriptionService` instead of waiting for the one in progress.
