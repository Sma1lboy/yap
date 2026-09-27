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

## Local cleanup

Yap has no Apple Intelligence path. Its local cleanup options are Yap Refine (a fine-tuned Qwen 3.5 run with MLX in `VoiceInkRefineXPC`, 1.06 GB download, needs 16 GB of memory), Ollama and a local CLI. Ollama and the local CLI run whatever model you install yourself, so they aren't benched here.

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
| Config sync pulls | on activation, on wake and periodically, only with Sync via Yap Cloud on | cloud.yap.sma1lboy.me |

The last two weren't in the measured run (the check can't hold a real sign-in); they come from reading `AppDelegate` and `CloudConfigSync`. Neither is triggered by a dictation. A fully offline user who never signs in sends nothing but the update check.

## Reproduce

- Clips: `python3 setup/asr/make_clips.py` (macOS `say`, voices Tingting and Reed (Chinese, mainland), rate 230, from `setup/asr/clips.json`).
- Transcription: build `setup/asr/harness` once (`swift build -c release`), then `python3 setup/asr/bench.py run whisper <ggml-*.bin>` / `run tcpp <gguf> [--itn]` / `run nemotron <model dir>` / `run openrouter microsoft/mai-transcribe-2` / `run yapcloud microsoft/mai-transcribe-2` (with `YAP_CLOUD_TOKEN`), and `python3 setup/asr/bench.py score`, which prints the table's columns. Model files come from the URLs and revisions in `WhisperModelManager`, `TranscribeCppModelCatalog` and `FluidAudioModelManager`. Pass `fluidbench` a model directory you downloaded yourself, so the app's own model cache isn't touched.
- Cleanup: `uvx --with mlx-lm python setup/refine_bench.py`.
- Offline: `make offline-check MODEL=…`.
