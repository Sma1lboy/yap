# Local models: what to run fully offline

Every local transcription model Yap offers that can handle Chinese, run on the same 11 code-switched clips (82 key terms) as a cloud reference, plus the local cleanup option. Measured 2026-09-26 on an M4 Pro (14 cores, 48 GB). Raw transcripts: `setup/asr/results/`.

## Recommendation

| For | Model | Why |
|---|---|---|
| **Default** (onboarding's Local option) | Whisper **Large v3 Turbo (Quantized)** | 45/82 key terms, within 2 of the best local model; 547 MB download, 0.9 GB peak memory; about 0.7 s for a 6 s clip. Add your terms to the dictionary: with them in the prompt it gets 54/82. |
| **8 GB Macs** | the same model | 0.9 GB peak memory fits alongside other apps. Nothing smaller comes close: SenseVoice Small (0.4 GB) gets 26/82. |
| **Most accurate** | Whisper **Large v3** (or Large v2) | 47/82, the best local score, but a 3.1 GB download, about 4.2 GB peak memory and 2× slower than the default. Only on 16 GB+ Macs, and only if the 2 extra key terms matter to you. |
| **Cleanup** | off | Yap Refine (the only local cleanup model Yap ships) passed 6 of 9 cleanup cases; the cloud pick passes 8 of those 9 in the automatic check (23–24 of 25 overall, docs/cloud-models.md). Its two failure types change meaning, see below. |

Onboarding's Local option used to download Parakeet V3, which has no Chinese; it now downloads Large v3 Turbo (Quantized), and starter modes fall back to it.

## Transcription results

Language `zh` for every model (what a Chinese–English user picks); onboarding sets `auto`, which scored 44/82 on the default model, within one of `zh`. Whisper runs the app's own `LibWhisper.swift` (VAD on, the app's `zh` prompt, greedy decoding, temperature 0.2, `min(8, cores − 2)` threads) with an empty dictionary.

| Model | Engine | Key terms (of 82) | Tingting voice (42) | Reed voice (40) | Real-time factor | Download | Peak memory | Load |
|---|---|---|---|---|---|---|---|---|
| Large v3 | whisper.cpp | **47** | 33 | 14 | 0.22 | 3.1 GB | 4.2 GB | 1.0 s |
| Large v2 | whisper.cpp | **47** | 34 | 13 | 0.21 | 3.1 GB | ≈4.2 GB¹ | 1.0 s |
| Large v3 Turbo | whisper.cpp | 46 | 32 | 14 | 0.10 | 1.6 GB | 1.9 GB | 0.5 s |
| **Large v3 Turbo (Quantized)** | whisper.cpp | **45** | 32 | 13 | **0.11** | **547 MB** | **0.9 GB** | 0.2 s |
| Cohere Transcribe | transcribe.cpp | 37 | 30 | 7 | 0.10 | 1.56 GB | 1.8 GB | 2.6 s |
| SenseVoice Small | transcribe.cpp | 26 | 18 | 8 | 0.03 | 241 MB | 0.4 GB | 7.8 s² |
| Base | whisper.cpp | 16 | 12 | 4 | 0.04 | 142 MB | 0.4 GB | 0.1 s |
| Nemotron Multilingual | FluidAudio (Core ML) | 8 | 4 | 4 | 0.03 | 672 MB | – | 19.9 s² |
| Tiny | whisper.cpp | 10 | 9 | 1 | 0.07 | 75 MB | – | 0.1 s |
| *mai-transcribe-2 (cloud reference)* | *OpenRouter* | *59* | *39* | *20* | *0.14³* | – | – | – |
| *mai-transcribe-2 (cloud reference)* | *Yap Cloud* | *59* | *39* | *20* | *0.10³* | – | – | – |

¹ Large v2 wasn't measured; it is the same size as v3. ² First load includes Metal shader or Core ML compilation. ³ Includes the network round trip.

Real-time factor is processing time ÷ audio length: 0.11 means a 6 s clip takes 0.7 s. Load is the time from process start to model ready, with the file already in the disk cache.

**How to read the scores.** These clips are harder than the README's set (mai-transcribe-2 gets 80/82 there and 59/82 here), so compare models within this table, not with the README. Almost all of the difference is the Reed voice: its TTS mispronounces English words inside Chinese sentences, and every model, cloud included, loses about half of those terms. The Tingting column is closer to how people actually talk: there the default gets 32/42 and the cloud 39/42.

**What the local models get wrong.** Names and rarer terms: "GitHub Actions" came out as "Gtop Actions", "Kubernetes" as "Coubernetos", "build cache" as "BuildCash", "Dockerfile" as "Decre file". Common terms (API, CI, React Query, XSS, CSRF, OAuth, roadmap, onboarding) come through.

**Not run:**
- **Parakeet V2, V3, Unified and Nemotron Latin**: their language lists have no Chinese, so they can't transcribe the Chinese half of a sentence.
- **Apple Speech**: needs Speech Recognition permission, which only a system dialog can grant; this run didn't use UI automation.

Whisper here is the app's `LibWhisper.swift` (setup/asr/harness `whisperbench`) on Metal, linked against the whisper.xcframework `make whisper` builds. An earlier version of this table used `whisper-cli`, which defaults to 5-beam search where the app decodes greedily: key terms matched within one on every model except tiny (7 vs 10), but it took about twice as long. The app also downloads a Core ML encoder for the non-quantized models (not for q5_0), so Large v3 / v2 / Turbo may run somewhat faster in the app than the table shows.

The table's Whisper rows use language `zh`. With a mode on Auto-detect, Whisper first spends a full encoder pass detecting the language: about 0.48 s per dictation on Large v3 Turbo (Quantized), M4 Pro. Fixing the language skips it; Yap suggests that after 20 dictations all in one language, and the mode's language picker shows this Mac's own number ([dictation-latency.md](dictation-latency.md#auto-detect-or-a-fixed-language)).

## Live text while recording

Whisper can't stream, so with "Live Text Display" on (Settings → Interface, on by default) a local Whisper model re-decodes the recording every 1.5 s once there's at least 1 s of new audio (`WhisperLivePreview`). The recorder shows that text. When you release the key, the preview stops and the whole recording goes through the normal path: windows, language detection and VAD. That final text is what gets pasted.

Preview decodes use greedy search with no temperature fallback and one segment. They're capped at about 8 tokens per second of audio, run on their own `whisper_state` outside the `WhisperContext` actor, and get no initial prompt; the app's zh prompt made them repeat "好,好,好". With language on auto, the first decode waits for 3 s of audio and its detected language is reused. Past 20 s the text so far is kept and a new piece starts, so each decode fits in one 30 s window. Releasing the key aborts the decode in flight and frees its state.

Large v3 Turbo q5_0, language auto, audio fed in real time:

| | Preview off | Preview on |
|---|---|---|
| Final, 11 clips (sum of per-clip medians, 5 interleaved rounds, harness) | 21.61 s | 22.70 s (+5.0%) |
| CPU / energy, 11 clips (51 s of audio) | 2.8 s / 8.0 J | 3.7 s / 9.0 J |
| Final, 65 s recording (mean of 5, harness) | 5.51 s | 5.74 s (+4.2%) |
| CPU / energy, 65 s recording | 2.3 s / 7 J | 4.8–5.2 s / 12.4–13.6 J |
| Final, 65 s recording, in the app (mean of 4, off/on interleaved) | 10.55 s | 10.54 s |

On the 65 s recording: 26–29 previews, none looping. The last preview's character error rate against the final is 0.25. The final text is identical with the preview on and off. In the app the final includes the session path around the decode, which is why it's slower than the harness. A 2.5 s interval saved little (3.3 s CPU, 8.4 J for the 11 clips) and showed text less often, so the interval stays at 1.5 s.

In the app (`WAIT=1 PREVIEW=1 make first-run-check MODEL=ggml-tiny`, the 65 s recording fed in real time, "After each dictation", load average 3–5 during the run): the preview sessions showed 33 and 34 previews, the four finals (two with the preview, two without) printed the same text, and the model stayed loaded throughout. Time from release to final: 1.1 s for the first session, 7.7–8.3 s for the next three, with or without previews; most of it was before the decode starts (3–3.5 s) and a 4.8 s decode where the first session's took 1 s. That slowdown is the same with the preview off, so it isn't the preview's; its cause is unknown. The check itself was why #62's run showed no preview text and main took 85–87 s: it didn't count the recording as a use for `ModelResidency`, so "After each dictation" freed the model 30 s in, every preview decode found no model, and the final waited for a reload. It now holds the model as a real recording does (seen on #63's branch in the log; main's 85 s is the same check, not rerun).

## Local cleanup

On macOS 26, Apple Intelligence (Foundation Models) is an experimental cleanup option behind Models > Advanced, until it passes the bench in [cloud-models.md](cloud-models.md#on-device-2026-09-27). The other local cleanup options are Yap Refine (a fine-tuned Qwen 3.5 run with MLX in `VoiceInkRefineXPC`, 1.06 GB download, needs 16 GB of memory), Ollama and a local CLI. Ollama and the local CLI run whatever model you install yourself, so they aren't benched here.

Yap Refine on `setup/cases.json`, with its own fixed system prompt (it ignores the mode's prompt), temperature 0.3 and thinking off:

| | |
|---|---|
| Passed | 6 of 9 (reply, question, short, two topics, steps, deploy) |
| Time per case | 0.7–3.8 s; model load 1.0 s once cached |
| Translates English terms | "roadmap" became "路线图", "senior front end" "高级前端", "extract" "提取" |
| Keeps self-corrections | "不对，不对，我刚刚说错了，应该是周四…不是周三" stays in the output instead of becoming "周四" |

The cloud cleanup pick (deepseek-v4.1-flash with `RecommendedPrompt.md`) passes 8 of those 9 in `setup/bench.py`'s automatic check (it keeps "不是周三" in the correction case) and 23–24 of 25 overall. Translating the English terms is exactly what a code-switching user doesn't want, so the fully offline setup leaves cleanup off.

## Is it really offline?

`make offline-check MODEL=<path to ggml-large-v3-turbo-q5_0.bin>` (`scripts/offline-check.sh`) runs the Debug app as the mock identity (its own defaults, Application Support and keychain) set up as a fresh install with one mode: local Whisper, language auto, cleanup off. It launches with `--dictate-file`, which feeds a bench clip through the same pipeline a finished recording takes, so no microphone permission or hotkey is needed.

1. **Network denied.** Run under `scripts/offline.sb`, which denies all IP traffic. The dictation must still return text.
2. **Network allowed.** The app's sockets are listed every 0.2 s with `lsof`; a connection that opens while the dictation runs fails the check. A connection that opens and closes between two polls would be missed, which is why run 1 exists: it shows nothing is *needed*.

Result on 2026-09-26 (default model, `security` clip):

```
== 1. network denied (scripts/offline.sb)
offline: model Large v3 Turbo (Quantized), cleanup used: false, transcription 1.390 s
  text: OAuth Refresh Token现在存在Local Storage里,有XSS风险,改成HTTP-only的Cookie,再加上CSRF Token效应。
== 2. network allowed, sockets logged
online: model Large v3 Turbo (Quantized), cleanup used: false, transcription 4.844 s
dictation window: 4.90 s
  127.0.0.1:11434   loopback   opened outside the dictation, seen -10.2s to +9.9s
no network connection was opened during the dictation
```

**What does touch the network** (besides the update check and telemetry):

| What | When | Where it goes |
|---|---|---|
| Ollama availability probe | every launch (`AIService.refreshOllamaAvailabilityInBackground`) | `localhost:11434` only; never leaves the Mac |
| Model download | once, when you download a model | Hugging Face |
| Yap Cloud account refresh | at launch and when Yap becomes active, only if signed in | cloud.yap.sma1lboy.me |
| Config sync pulls | on activation, on wake and periodically, only with Sync Settings Across Macs on | cloud.yap.sma1lboy.me |

The last two weren't in the measured run (the check can't hold a real sign-in); they come from reading `AppDelegate` and `CloudConfigSync`. Neither is triggered by a dictation. A fully offline user who never signs in sends nothing but the update check.

## Quitting with a model loaded

whisper.cpp frees its Metal device in a C++ static destructor when the process calls `exit()`, and aborts (`GGML_ASSERT([rsets->data count] == 0)` in `ggml_metal_rsets_free`) if any model buffer is still allocated then. Quit ends in `exit()` inside `-[NSApplication terminate:]`, so up to 1.13.0 quitting with a Whisper model in memory crashed: with Keep model loaded set to a time or Always, right after launch (the launch prewarm loads the model), within 30 s of a dictation's preload under After Each Dictation, or mid-dictation.

Now `AppDelegate.applicationShouldTerminate` answers `.terminateLater` and, before replying:

1. During a meeting, asks first as before (Keep Recording is the default and cancels the Quit with nothing closed; End Meeting and Quit finishes and saves the meeting).
2. The audio import queue is cancelled: the file being imported goes back to pending (the queue isn't kept across launches anyway) and its transcription task is cancelled instead of Quit waiting for the whole file (checked with Whisper; for transcribe.cpp and Nemotron it is the same task cancel the cancel checks below exercise, but an import on them wasn't run). Then `VoiceInkEngine.closeLocalModels`:
   - Whisper (`WhisperModelManager.closeForQuit`): refuses any load and any transcription's turn from then on (a preload or a dictation after Quit fails with an error instead of loading again; a transcription still waiting for its turn fails without decoding), aborts the decode of a post-download warm-up and waits for its context to be freed, waits for a load in flight, then frees the shared context in its own turn, after the decode in flight. A dictation or a meeting piece in flight is waited for, not aborted. End Meeting and Quit already waited for the remaining pieces and the notes request.
   - FluidAudio: no transcription or preload starts from then on; the managers and Core ML models are released after the transcription in its turn. Quit doesn't cancel that transcription, it waits for it (a cancel would stop a Nemotron decode within 0.02 s, see below): with the 22-minute clip transcribing (not an import, which is cancelled first), Quit took 37.7–39.3 s in five runs. The 170.01 s recorded in M4.3 was a run where macOS throttled Yap (see "Why one run was 20 times slower" below).
   - transcribe.cpp: no transcription or load starts from then on; it waits for the running ones to end (the 22-minute SenseVoice clip: 6.3–6.9 s in five runs) and frees the model. It links its own ggml: with that wait taken out, a Quit one second into a transcription crashed in `ggml_metal_rsets_free` (`GGML_ASSERT([rsets->data count] == 0)`, exit 134), as Whisper's did in 1.13.0.
   - While this takes longer than half a second, a small floating window (`QuitWaitPanel`, non-activating: it never takes focus) says "Quitting Yap", what it waits for ("Waiting for an earlier transcription", "Waiting for a cancelled dictation", "Waiting for the model to load"…), that work's step ("Detecting speech", "Detecting the language", "Transcribing", "Loading the model", "Unloading the model") with the time spent in it, "This step can't be stopped; it ends on its own." for a cancelled request in a step that can't stop, and "Yap quits as soon as this is done." No percentage or time left: no backend reports one. It closes once, right before the reply. In `make lifecycle-check` the main actor kept running the whole time (the check reads the panel every half second) and the panel showed "Waiting for an earlier transcription / Transcribing" during both Quits above; in `make quit-check` it came up during the `decoding` case (1.2 s) and in no case under half a second.
3. Replies, and AppKit exits.

A second ⌘Q (or Quit from the Dock) during those steps used to make AppKit exit at once without asking again, in the middle of the release (crash) or of a meeting being saved. `YapApplication`, the app's `NSApplication`, drops `terminate:` from the `.terminateLater` answer until just before the reply. (After a quit Apple event AppKit's own exit on the reply calls `terminate:` again; dropping that one too left Yap running.)

`terminate:` has to come from the run loop (a menu item, a quit Apple event from the Dock, logout or Sparkle). Called from inside a `Task` or `DispatchQueue.main.async`, AppKit's wait for the reply can't run the main actor and Quit never finishes. AppKit also ignores `terminate:` while a sheet is attached to a window, e.g. the release notes after an update; that is unchanged.

`make quit-check MODEL=<path to ggml-*.bin>` (`scripts/quit-check.sh`) launches the Debug app as the mock identity with `--quit-check <state>`, brings the model to that state and quits with nothing released first: `NSApplication.terminate` from a run loop block, the real "Quit Yap" item of the menu bar icon's menu or of the app menu (`NSMenu.performActionForItem`, which runs the app's own button action), or a quit Apple event sent from another process (`NSRunningApplication.terminate`). Per case it requires exit status 0, no crash report for that process, NSApp being `YapApplication`, the model gone at `willTerminate`, and in the unified log `quit: closing local models` → `WhisperModelManager.cleanupResources: completed` → `quit: local models closed`, once. Results with Large v3 Turbo (Quantized), 2026-10-01:

| Keep model loaded | State at Quit | Before (main, 1.13.0 code) | Now |
|---|---|---|---|
| Always | after a dictation, loaded | SIGABRT in `ggml_metal_rsets_free` | exit 0, freed in 11 ms |
| 900 s | after a dictation, loaded | SIGABRT | exit 0 |
| After Each Dictation | after a dictation, already released | exit 0 | exit 0 |
| After Each Dictation | shortcut preload finished | SIGABRT | exit 0 |
| Always (no launch prewarm) | preload still loading | not reached (check's own timing) | exit 0, waited 226 ms for the load, then freed |
| Always | dictation decoding | SIGABRT | exit 0, waited 1.1–1.2 s for the decode; the dictation finished first; the Quit panel came up after half a second |
| Always | Quit, then Quit again 10 ms later | SIGABRT | exit 0, released once |
| Always | menu bar icon › Quit Yap | not run | exit 0 |
| Always | app menu › Quit (the ⌘Q item) | not run | exit 0 |
| Always | quit Apple event from another process | not run | exit 0 |
| Always (no launch prewarm) | post-download warm-up running (the mode's model as the one just downloaded) | not run | exit 0; 0.12 s, or 16 s when it was compiling Metal shaders for the first time (that part can't be interrupted) |
| Always | 3-minute file being imported | not run | exit 0 after 0.9 s: the import was cancelled and its decode aborted |
| Always | 3 s into a recording with the live preview on | not run | exit 0 after 0.01 s |
| Always | meeting recording (fed from files), End Meeting and Quit | not run | exit 0 after 5.5 s: the remaining pieces, 0 failed, and the History entry were saved before the exit |

Not verified by a run:

- The Release build: CI compiles it; every run above is the Debug app.
- End Meeting and Quit with a real microphone and system audio: the `meeting` case feeds the same recording session from two files (`MeetingRecorder.startFromFiles`) and answers the alert by a DEBUG switch; capture itself isn't exercised.
- A Quit during a Sparkle update: Sparkle 2.9.2's installer sends the same quit Apple event the `appleevent` case sends, but no update was installed.
- Quit with a FluidAudio or transcribe.cpp transcription in flight waits for it (see below); that ran through `NSApplication.terminate` in `make lifecycle-check`, not through the menu items.
- The Quit panel was rendered in every language, light and dark (`make ui-snapshots ONLY=quit-wait`), and found on screen by the checks; nobody looked at it on a real desktop during a Quit.

## Transcriptions that overlap

A dictation, an imported file, History's Retranscribe, the launch prewarm, a meeting piece and the live preview's final text can all ask local Whisper at once. Up to 1.13.0 they shared one `WhisperContext` without owning it:

- **Same model.** Each request set the language, then the prompt, then decoded, then read the text and the timed segments, five separate actor calls another request could get between. `make isolation-check` (below) on 1.13.0's code, clip A (Chinese, `zh`, one prompt) and clip B (`en`, another prompt) started together: 3 of 10 B requests got A's text, word for word. The service also kept the last timed segments in a shared field that an imported file read after its decode.
- **Different models** (a meeting on Large v3 Turbo while dictation uses Base): a dictation released the meeting's model to load its own while a piece was decoding or about to, so the piece's decode found no model and failed (`whisperCoreFailed`), and the next piece released the dictation's. In the check every piece of both meetings failed (6 of 6, "This part couldn't be transcribed"), 10 of 12 dictations failed, and the two requests swapped models 22,481 times in 32 minutes instead of finishing.

Now:

- `WhisperContext.transcribe(samples:language:prompt:)` is one synchronous actor call that sets the request's language and prompt, decodes and returns a `Transcript` (text, timed segments, detected languages). Nothing else can run on that context in between. `TranscriptionServiceRegistry.transcribeWithSegments` returns the segments with the text (audio import saves them for subtitle export); the shared `lastSegments` is gone. `WhisperContext.setPrompt`/`setLanguage` and the prompt-change notification that set a default prompt on the loaded context are gone too: every decode passes its own.
- `WhisperModelManager.withContext(named:)` gives a request the model in a turn. Turns go one at a time in the order asked (FIFO): each transcription, with the switch to its model when another one is loaded, and each release (idle, memory pressure, Quit). A release or another model's load waits for the decode in its turn instead of freeing the context under it. A loaded model is taken without waiting for the main actor, as before.
- The prewarm, audio import and History's Retranscribe use the engine's registry, so they share the loaded models and their releases instead of each building its own services.

**Waiting instead of memory.** Still only one Whisper model in memory. With a meeting on one model and dictation on another they take turns, and every switch is a load: in two runs of the check (M4 Pro, models in the page cache, "After each dictation") a dictation that came during the meeting took 1.6 s (median) instead of 0.5–0.6 s alone, because it waited for the piece being decoded and then for its model to load; the 54 s test meeting (6 pieces, 6 dictations during it, 12 loads) finished in 10.1–10.2 s (12–15 s alone, as the first meeting of the run). Yap's footprint stayed at 0.85–0.92 GB with Large v3 Turbo loaded, apart from one sample of 1.5 GB per run while the earlier meetings' speakers were being told apart (FluidAudio, in the background). Keeping both models would save those loads but hold both for as long as a meeting runs, which for two large models doubles that; that's left out. Meeting pieces and dictations are equal in the queue: a dictation waits for at most the piece ahead of it, not for the whole meeting.

Not covered: the Release build (every run is the Debug app; CI compiles Release).

## Cancelling a local transcription

Cancel in the recorder while a dictation is transcribing, and Clear or Stop in the audio import queue, cancel the transcription's task (`TranscriptionPipeline.cancelTranscription`, `AudioTranscriptionManager.cancelProcessing`). Up to M4.2 the dictation's decode ran to its end first and was then thrown away, holding the model's turn meanwhile; in M4.3 a cancel during Whisper's speech detection still waited for it to finish. Now:

| Where the request is | Whisper | FluidAudio (Nemotron, Parakeet, Unified) | transcribe.cpp |
|---|---|---|---|
| waiting for its turn | leaves the queue at once, never decodes, holds nothing; the ones behind move up (within 0.01 s of the cancel in the check) | the same | no queue: native runs take turns per ≤30 s chunk, so a request between another one's chunks runs right away |
| its model loading | the load finishes (others may share it), then it stops without decoding; the model stays loaded | stops before decoding | stops before decoding |
| speech detection | stops between pieces of about a second of audio (below): cancels a tenth, half and nine tenths into speech detection over a 22-minute clip all stopped within 0.02 s | — (VAD off in the check) | — |
| language detection (language Auto) | stops before the next attempt; one attempt is an encoder pass whisper.cpp can't interrupt, so a cancel during it waits for that pass. Shown as a step that can't be stopped. Not timed in the check (its mode language is fixed) | — | — |
| decoding | whisper.cpp's abort callback before each graph computation, and a check before each window: cancels 0.5–5 s into a 65 s clip stopped within 0.18 s, and in the 22-minute clip's decode within 0.47 s (three runs) | Nemotron: its chunks run Core ML's async `prediction(from:)`, which throws for a cancelled task: cancels 0.7 s and 10 s into a ~39 s decode of the 22-minute clip stopped within 0.02 s. (M4.3 said Nemotron's decode couldn't be stopped; that was read from the SDK and missed the Core ML call.) Parakeet and Unified weren't run and are shown as steps that may not stop | transcribe.cpp's abort callback between decode steps: 0.02–0.15 s (0.7 s and 3 s into the 22-minute clip, three runs) |

A cancelled request throws `CancellationError`; the next request on the same model comes out as alone, and nothing frees the context another request uses. A cancelled dictation is saved as cancelled ("The transcription was canceled."), never as a transcript; a cancelled import goes back to pending and creates no History entry. Meeting pieces aren't cancelled: End Meeting waits for them.

**Speech detection a piece at a time.** whisper.cpp has no abort callback for its VAD (`whisper_vad_detect_speech` is one call over the whole recording), and that call took 82–86 s for 65 s of audio in M4.3's slowed-down run. `WhisperContext` now calls `whisper_vad_detect_speech_no_reset` on pieces of 16,384 samples (32 of Silero's 512-sample windows), checking the cancel flag between them. In whisper.cpp (d09f61a7, the build here) Silero's LSTM state lives in the VAD context and only `whisper_vad_reset_state` clears it, each window is computed from its own 512 samples, and only a window past the end is zero-padded; so pieces a whole number of windows long give the same probabilities as one call. whisper.cpp turns into segments only the probabilities of its last call, so `WhisperSpeechSegments` is its `whisper_vad_segments_from_probs` (threshold, minimum speech and silence, 200 ms merge, padding, centiseconds) for the joined ones. `make lifecycle-check` compares both on every clip (the 1 s, 8 s and 65 s clips, the two meeting channels and the 22-minute clip): probabilities equal to the bit, segments equal. Silero's window isn't exposed; it is read off the first piece's number of probabilities, and if it didn't divide a piece the app would fall back to one call. Up to one piece of audio is still one call.

**One VAD thread.** Silero's graph is a single 512-sample window, so whisper.cpp's default of four threads mostly makes them wait for each other. With one thread (`vadContextParams`) the probabilities are the same to the bit (the comparison above is against a four-thread call), 65 s takes 0.11 s instead of 0.15 s, and the 22-minute clip 2.1–2.3 s in the app instead of 3.8–4.0 s.

## What a wait shows

`LocalModelActivity` is where each backend reports the work holding a model (a transcription and who asked for it, a load, a warm-up, a release), its step (loading the model, detecting speech, detecting the language, transcribing, unloading) with when that step started, whether it was cancelled, and whether the step stops on a cancel; and each request waiting for its turn.

- **Recorder.** A dictation waiting more than a second for its local model shows a line above the controls: what it waits for ("Waiting for a cancelled dictation", "Waiting for the audio import", "Waiting for a meeting piece", "Waiting for an earlier transcription", "Waiting for the model to load"…), that work's step and the time spent in it, and "This step can't be stopped; it ends on its own." when it was cancelled in a step that can't stop. The line goes once the dictation's own transcription runs. Mini and notch recorders, rendered in every language, light and dark (`make ui-snapshots ONLY=recorder-wait`). In `make lifecycle-check` a dictation queued behind a request in speech detection showed "Waiting for an earlier transcription / Detecting speech"; that request was then cancelled and the dictation completed with the same text as alone.
- **Quit:** the panel above.
- No percentages and no time left: no backend reports progress. A cancelled request that already stopped isn't shown.

While any work runs, Yap holds a user-initiated activity (`ProcessInfo.beginActivity`, idle sleep still allowed), so macOS doesn't App Nap it (next section).

## FluidAudio and transcribe.cpp

What their SDKs (FluidAudio 762baf6, Transcribe-cpp-swift fb1c1ad) already do, and what changed:

- **FluidAudio.** Its managers are actors, but a batch transcription is several awaited calls on one shared manager: Nemotron's `setLanguage`, `reset`, `process`, `finish` keep one stream's language and audio on the manager, and Unified resets one shared decoder per window (read in the SDK). Two requests at once mixed them: with the turns taken out, the check's Chinese and English Nemotron requests started together crashed the app (heap corruption in `NemotronMelExtractor`, `free_medium_botch`). A release during a decode cleans the same managers up (read in the app and SDK; the crash came first in that run). `FluidAudioTranscriptionService` now takes a `ModelTurns` turn per transcription, preload and release, the same FIFO type Whisper uses: 20 of 20 overlapping requests came out as alone, and a release asked during a decode waited for it and then freed the models (38.7 s in M4.4's run, the decode's own length; 141 s in M4.3's throttled run). Streaming sessions build their own managers and take no turns.
- **transcribe.cpp.** Its `Model` already serializes native runs (one `runLock`) and each request has its own `Session`, so overlapping requests don't mix: 20 of 20 as alone, which comes from the SDK's lock, not from this change. Two things changed. The model was unloaded after every transcription whatever "Keep model loaded" said, and an unload asked for while one ran was skipped and never done; now it stays loaded until a release asks, and a release asked during a transcription happens after the last one ends. And Quit waits for the running transcriptions (above).
- Models: the FluidAudio download (`--fluidaudio-models <dir>` in DEBUG) now passes its folder to Nemotron's `downloadVariant` instead of relying on the SDK's default, which is the same `~/Library/Application Support/FluidAudio/Models` folder for production; Parakeet's and VAD's folders still come from the SDK.

Not run: Parakeet v2/v3, Unified and Cohere (only Nemotron Multilingual and SenseVoice Small were downloaded), FluidAudio and transcribe.cpp streaming sessions, FluidAudio's VAD (off in the check: its model folder can't be set, and the check must not write the shared FluidAudio folder).

### Why one run was 20 times slower

In M4.3's run of all four suites, the app slowed down partway through: the long Whisper request took 4.16 s alone at the start and 92 s later; Nemotron's took 171 s; and the cancel check failed at 82–86 s. That run's stderr has whisper.cpp's own VAD timing: speech detection over the 65 s clip took 0.14 s at the start and 86 s during the slow stretch (8 s clips: 0.02 s, then 10–12 s), while the decodes themselves slowed far less. So the 82–86 s were speech detection, not the decode.

What was found (M4 Pro, macOS 15.1, same fixtures, Large v3 Turbo, mode language Chinese, VAD on):

- **Reproduced in the app.** On M4.4's first commit, the `whisper` suite run in the background showed the same pattern: speech detection over 65 s at 0.16–0.19 s for the first minutes, then 0.7–1.4 s; the 22-minute clip took 20 s. The snapshots taken before and after each run showed nothing that explains it: load average 3.4–6.2, the CPUs 72–81% idle, no thermal or performance warning (`pmset -g therm`), swap at 2.6 of 4 GB and unchanged. (Their per-process CPU column was empty: `top` needs two samples; the script now takes two.) The thread's QoS class, now logged with each speech detection, stayed user-initiated (25) and the thermal state nominal.
- **The same work outside the app.** whisper.cpp's VAD on the same files from a small command-line tool: 0.145 s for 65 s, 2.9 s for 22 minutes, and 0.88–1.09 s for 65 s when run as a background-QoS process (`taskpolicy -b`), about the slowdown seen in the app.
- **A/B in the app.** The `whisper` suite twice in a row, same build, with and without the activity assertion (one run each, "with" first). With it: every speech detection over 65 s took 0.145–0.174 s, the 22-minute clip 3.8 and 4.0 s, and the long clip at the end of the run took as long as at the start (4.22 s vs 4.14 s). Without it: 65 s rose to 0.86–1.28 s partway through, the 22-minute clip took 9–20 s, and the long clip took 9.12 s at the end vs 4.20 s at the start (that run failed). The run before both, without the assertion, had slowed the same way, so it isn't just which run came second.

So Yap in the background, with no window in front, was being throttled while it worked; holding the activity stops it. That is what App Nap does to an app; macOS doesn't report App Nap to the process, so it isn't proven to be App Nap rather than another kind of background throttling. The CPU sampling of other processes during the M4.3 run was never taken (only the unified log, which had Spotlight's and the Photos analysis' daemons logging heavily during that window), so whether other load made it worse there is not known. A real dictation usually has the recorder on screen; an import, a meeting piece or a cancelled request's leftover work may not.

### The check

`scripts/lifecycle-check.py` gates cancels again: a cancelled request must stop within 2 s of the cancel, in its turn's queue, in speech detection (the 22-minute clip, cancelled a tenth, half and nine tenths in), in the 65 s clip's decode, in the 22-minute clip's decode, and in transcribe.cpp's and Nemotron's decodes; and each must have been cancelled in the step it was aimed at. The original failure (82–86 s) fails this. The suite also runs the long clip alone at the start and the end; if the end takes more than three times as long, the run fails as "ENVIRONMENT": a Mac that slowed down meanwhile, cause not established by the check, which makes every timing in it meaningless rather than a pass. Each suite writes what else the Mac was doing (`uptime`, `pmset -g therm`, swap, `vm_stat`, the top processes) next to its output, before and after. All four suites passed in one run on b7925efe (Debug; Large v3 Turbo and Base, SenseVoice Small Q8_0, Nemotron Multilingual), and `make quit-check` passed all 14 cases on the same build.

Still open: a language-detection attempt (an encoder pass) can't be interrupted, and wasn't timed; Parakeet and Unified decodes weren't run; Quit doesn't cancel a dictation or meeting piece in flight (it waits for it, with the panel up). transcribe.cpp has no turns (native runs interleave per chunk), so a dictation queued behind it shows no recorder line.

## Keep model loaded, against real work

`ModelResidency` releases on a timer or a memory-pressure warning, never while a recording, a transcription (`withUse`) or, now, a meeting (recording or finishing) is in progress. Before, the meeting's gaps between pieces counted as idle, so a memory-pressure warning freed the model between two pieces and the next piece loaded it again. In `make lifecycle-check`, Large v3 Turbo, after each of a live-preview final, an audio import, a 54 s meeting, the wake prewarm and a cancelled request:

| Keep model loaded | Right after | A while after |
|---|---|---|
| Always | loaded | loaded (9 s later) |
| 5 s | loaded | released (9 s later) |
| After each dictation | loaded | released (36 s later: these aren't dictations, so the 30 s grace applies) |

A memory-pressure warning one second into a meeting (with Always): the final `lifecycle.log` residency suite recorded 0 failed pieces and a successful release about 1.72 s after the meeting ended (`lifecycle/residency.txt`: `releasedAfterMeeting: true`, `releaseSeconds: 1.72265`); the next request loaded the model again. The earlier `lc-wr` run reached its 15.02 s observation limit with `releasedAfterMeeting: false` and failed the check. That 15 s was a failed wait, not a successful release delay. These are fixture measurements, not a fixed release deadline.

`make lifecycle-check MODEL=<ggml-*.bin> MODEL2=<another ggml-*.bin>` (`scripts/lifecycle-check.sh`, `LifecycleCheck.swift`, `scripts/lifecycle-check.py`) runs these as the mock identity, one launch per suite: `whisper` (speech detection in pieces against one call on every clip, the cancels above, a dictation queued behind speech detection and what it shows, the live-preview final alone and with a MODEL2 request in the middle of the recording, the long clip alone at the end), `residency`, `tcpp` (SenseVoice Small from the catalog URL, checked against its size and SHA-256, in `/tmp/yap-test-models`) and `fluid` (Nemotron Multilingual, downloaded once by the app's own download into `/tmp/yap-test-models/fluidaudio`; FluidAudio's shared folder stayed absent); both backend suites end with a Quit during a transcription, reading what the Quit panel shows every half second. The meetings' speaker models are downloaded once into `/tmp/yap-speaker-models` and copied in after that (isolation-check uses the same cache).

`make isolation-check MODEL=<ggml-*.bin> MODEL2=<another ggml-*.bin>` (`scripts/isolation-check.sh`, `IsolationCheck.swift`) runs the Debug app as the mock identity and compares every overlapping result, text and timed segments, with the same request run alone (twice, which must agree): ten same-model pairs started together, the second after 0, 0, 2, 10 or 50 ms, in both orders; an audio import (its segments read back from the saved entry) while clip A runs again and again; a model that isn't on disk failing alone and next to clip A, then clip A again; two 54 s two-channel meetings on MODEL while the mode is switched to MODEL2 and clip A is dictated until each meeting is done, each meeting with 0 failed pieces. It prints the median time, the loads and the footprint per phase. `WhisperModelManager.selfCheck` (DEBUG, at launch) pins the turn order with placeholder contexts: a piece, then a dictation on another model, then the next piece run in that order with each model still loaded at the end of its own decode; an idle release asked during a decode frees after it; a failed load doesn't stop the next one; after Quit a waiting transcription fails without running.

## Reproduce

- Clips: `python3 setup/asr/make_clips.py` (macOS `say`, voices Tingting and Reed (Chinese, mainland), rate 230, from `setup/asr/clips.json`).
- Transcription: build `setup/asr/harness` once (`swift build -c release`), then `python3 setup/asr/bench.py run whisper <ggml-*.bin>` / `run tcpp <gguf> [--itn]` / `run nemotron <model dir>` / `run openrouter microsoft/mai-transcribe-2` / `run yapcloud microsoft/mai-transcribe-2` (with `YAP_CLOUD_TOKEN`), and `python3 setup/asr/bench.py score`, which prints the table's columns. Model files come from the URLs and revisions in `WhisperModelManager`, `TranscribeCppModelCatalog` and `FluidAudioModelManager`. Pass `fluidbench` a model directory you downloaded yourself, so the app's own model cache isn't touched.
- Live text: `LIVE=0` / `LIVE=1` (optionally `LIVE_PRINT=1`, `LIVE_INTERVAL_MS`) in the environment of `setup/asr/harness/.build/release/whisperbench <model> <silero> auto "" <wavs…>` prints final time, CPU seconds and joules per file. In the app: `PREVIEW=1 WAIT=1 scripts/first-run-check.sh <app dir>`.
- Cleanup: `uvx --with mlx-lm python setup/refine_bench.py`.
- Offline: `make offline-check MODEL=…`.
- Quit: `make quit-check MODEL=…` (`CASES="0:twice"` for one case; `OUT=<dir>` keeps each case's output and log).
- Overlapping requests: `make isolation-check MODEL=… MODEL2=…` (`OUT=<dir>` keeps the output and footprint samples).
