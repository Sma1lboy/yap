# Dictation accuracy (Chinese–English code-switching)

How many English terms, names and numbers each transcription engine gets right when they are spoken inside Chinese sentences. Numbers come from `setup/asr/bench.py`; rerun it after touching the local whisper path, the default models, or the dictionary prompt, and add a dated section here.

## Method

- 11 clips from `setup/asr/clips.json`: the 9 sentences in `setup/cases.json` plus new ones aimed at earlier misses (PR, useEffect, userID, names, numbers, "帮我回一下", Kubernetes units, versions). **82 key terms**, marked `[term]` or `[term|accepted alternative]`.
- Audio is macOS `say` at rate 220, Tingting (zh_CN) and Meijia (zh_TW), converted to 16 kHz mono 16-bit WAV like Yap records. The Eloquence voices (Eddy, Flo, Sandy) were dropped: they turn English words into noise ("bun dev" → "blend off", "3000" → "3 天"), so they measure the voice, not the model.
- A term counts when one of its spellings appears in the transcript, compared case-insensitively with whitespace removed ("user ID" matches "userID"). Raw transcription only: no enhancement, no word replacements.
- Local whisper runs the app's own `LibWhisper.swift` and `WhisperChunking.swift` (compiled into `setup/asr/harness/`), VAD on, language auto. OpenRouter models get the same multipart request as the app.
- Latency is wall time per clip (clips are 3–14 s). Local models ran on Jackson's Mac, Metal, at low load. Cloud calls went from the same Mac (China mainland network) to OpenRouter.
- `say` has no accent, no fillers and no room noise. Real speech will score lower. Real recordings go in `setup/asr/recordings/` (`<name>.m4a` + `<name>.txt` with the same bracket markup), and the bench picks them up automatically.

The README's earlier figures (MAI-Transcribe-2 80/82) came from a different set of clips and terms that was never committed. They are not comparable with these.

## 2026-09-26

| engine | key terms /82 | p50 per clip | notes |
|---|---|---|---|
| OpenRouter `google/gemini-3.5-transcribe` | **77** | 2.41 s | slowest cloud option |
| OpenRouter `openai/gpt-4o-mini-transcribe` | 74 | 1.02 s | |
| OpenRouter `microsoft/mai-transcribe-2` (Recommended setup) | 73 | 0.57–0.80 s | same 73 in three runs, same misses |
| local large-v3-turbo q5_0 + dictionary prompt | 73 | 1.19 s | every key term in the dictionary: an upper bound |
| local small + dictionary prompt | 72 | 0.51 s | same |
| local large-v3-turbo q5_0 | 65 | 1.18 s | |
| OpenRouter `openai/whisper-large-v3` | 64 | 4.01 s | |
| local base + dictionary prompt | 56 | 0.23 s | same |
| local small | 53 | 0.46 s | |
| local base | 26 | 0.22 s | also writes most Chinese in Traditional characters |

Yap Cloud serves the same `microsoft/mai-transcribe-2` through paygate. It wasn't run here because that needs an account token (`yapcloud:<model>` with `YAP_CLOUD_TOKEN`).

What the numbers say:

- **Terms every engine misses are mostly the voice.** "bun install" / "bun dev" (Tingting says "ban"), "512Mi" / "1Gi", "readiness probe" and "on-call" fail everywhere.
- **The dictionary prompt is worth as much as a bigger model for local whisper.** Since `f8950a2` local whisper gets the user's dictionary words as its initial prompt. With every term listed: base 26 → 56, small 53 → 72, turbo 65 → 73. When the prompt holds only half the clips' terms, the listed terms go from 11 → 34 of 45 (base), 27 → 44 (small), 34 → 41 (turbo), and the unlisted ones stay level (15 → 19, 26 → 25, 31 → 30). A prompted word showed up where it wasn't said in 0–2 of 11 clips.
- **Local small + a dictionary is close to the cloud pick on this set** (72 vs 73, 0.5 s, no network). Without a dictionary it trails badly (53).

## Long recordings (local whisper)

Related numbers from the same machine, for recordings longer than one 28 s window. Setup: `say` Samantha / Tingting plus pink noise, 3–4 min, turbo q5_0. The original code is `26c6893`, before the dictation-core fixes.

| recording | CER original → now | time original → now |
|---|---|---|
| English ×3, 238 s | 0.006 → 0.000 | 9.90 → 9.99 s |
| Chinese ×3, 177 s | 0.065 → 0.066 | 9.73 → 10.18 s |
| en + zh + en, clean, 218 s | 0.206 → 0.036 | 12.34 → 15.08 s |
| en + zh + en, noise, 218 s | 0.158 → 0.026 | 11.74 → 16.70 s |

The original decoded the whole recording in one language (the Chinese stretch came out translated into English) and could skip sentences between 30 s windows. Mixed recordings now cost 1.2–1.4× the time, because each window's language detection is a full encoder pass. See the commit messages of `37b4e9a` and `67a6e7a`.
