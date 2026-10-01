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
2. `VoiceInkEngine.closeLocalModels`: `WhisperModelManager.closeForQuit` refuses any load from then on (a preload or a dictation after Quit fails instead of loading again), waits for a load in flight, then frees the context. Freeing goes through the `WhisperContext` actor, so it waits for a decode in flight to finish; it doesn't abort it. A decode is one actor call per dictation, per imported file and per meeting piece, so Quit during a long file import waits for the whole file, with nothing on screen meanwhile; End Meeting and Quit already waited for the notes request. Then `serviceRegistry.releaseAll()` as the idle release does (FluidAudio, transcribe.cpp).
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
| Always | dictation decoding | SIGABRT | exit 0, waited 1.1 s for the decode; the dictation finished first |
| Always | Quit, then Quit again 10 ms later | SIGABRT | exit 0, released once |
| Always | menu bar icon › Quit Yap | not run | exit 0 |
| Always | app menu › Quit (the ⌘Q item) | not run | exit 0 |
| Always | quit Apple event from another process | not run | exit 0 |

Not verified by a run:

- The Release build: CI compiles it; every run above is the Debug app.
- End Meeting and Quit: needs a real microphone. `AppDelegate.quitSelfCheck` (DEBUG, at launch) checks with stand-ins that Keep Recording closes nothing and that the order is meeting saved → models freed → reply.
- transcribe.cpp and FluidAudio models: none on this Mac. They're released through the same `releaseAll` as the idle release. transcribe.cpp links its own ggml; an unload is skipped while it transcribes (`activeTranscriptionCount`), so a Quit mid-transcription there may still crash.
- The launch prewarm (`ModelPrewarmService`) has its own `TranscriptionServiceRegistry`; its FluidAudio and transcribe.cpp services aren't released on Quit (nor by the idle release). Its Whisper model is the shared one and is.
- The warm-up right after a model download (`WhisperModelWarmupCoordinator`) uses a context of its own for a few seconds; a Quit during it isn't covered.

## Reproduce

- Clips: `python3 setup/asr/make_clips.py` (macOS `say`, voices Tingting and Reed (Chinese, mainland), rate 230, from `setup/asr/clips.json`).
- Transcription: build `setup/asr/harness` once (`swift build -c release`), then `python3 setup/asr/bench.py run whisper <ggml-*.bin>` / `run tcpp <gguf> [--itn]` / `run nemotron <model dir>` / `run openrouter microsoft/mai-transcribe-2` / `run yapcloud microsoft/mai-transcribe-2` (with `YAP_CLOUD_TOKEN`), and `python3 setup/asr/bench.py score`, which prints the table's columns. Model files come from the URLs and revisions in `WhisperModelManager`, `TranscribeCppModelCatalog` and `FluidAudioModelManager`. Pass `fluidbench` a model directory you downloaded yourself, so the app's own model cache isn't touched.
- Live text: `LIVE=0` / `LIVE=1` (optionally `LIVE_PRINT=1`, `LIVE_INTERVAL_MS`) in the environment of `setup/asr/harness/.build/release/whisperbench <model> <silero> auto "" <wavs…>` prints final time, CPU seconds and joules per file. In the app: `PREVIEW=1 WAIT=1 scripts/first-run-check.sh <app dir>`.
- Cleanup: `uvx --with mlx-lm python setup/refine_bench.py`.
- Offline: `make offline-check MODEL=…`.
- Quit: `make quit-check MODEL=…` (`CASES="0:twice"` for one case; `OUT=<dir>` keeps each case's output and log).
