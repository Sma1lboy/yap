# Dictation accuracy (Chinese–English code-switching)

How many English terms, names and numbers each transcription engine gets right when they are spoken inside Chinese sentences, cloud and local together. Every number here is in `setup/asr/results/`; `python3 setup/asr/bench.py score` prints them. Local models, memory and offline use are covered in [local-models.md](local-models.md), on the same clips.

## Method

- The 11 clips and 82 key terms in `setup/asr/clips.json`, rendered by macOS `say` (Tingting and Reed, rate 230) and committed as `setup/asr/clips/*.m4a`. Reed mispronounces many English words, so every engine loses about half of that voice's terms. The Tingting column is closer to real speech.
- A term counts when one of its spellings appears as whole words. Raw transcription only: no enhancement, no word replacements.
- Language `zh`. Local whisper runs the app's `LibWhisper.swift` with its `zh` prompt and VAD on. Cloud models get the app's own request.
- Real recordings dropped into `setup/asr/recordings/` are scored in their own column. There are none yet, so everything below is synthetic speech.

README's earlier "80/82" for mai-transcribe-2 came from a different, uncommitted set of clips and is not comparable.

## 2026-09-26

| engine | key terms /82 | Tingting /42 | Reed /40 | real-time factor |
|---|---|---|---|---|
| OpenRouter `microsoft/mai-transcribe-2` (Recommended setup) | **59** | 39 | 20 | 0.14 |
| local Large v3 Turbo (Quantized) + dictionary | 54 | 37 | 17 | 0.16 |
| local Small + dictionary | 53 | 34 | 19 | 0.08 |
| OpenRouter `openai/gpt-4o-mini-transcribe` | 52 | 40 | 12 | 0.15 |
| OpenRouter `google/gemini-3.5-transcribe` | 49 | 39 | 10 | 0.37 |
| OpenRouter `openai/whisper-large-v3` | 48 | 33 | 15 | 0.23 |
| local Large v3 / Large v2 | 47 | 33–34 | 13–14 | 0.21–0.22 |
| local Large v3 Turbo (Quantized), the local default | 45 | 32 | 13 | 0.11 |
| local Base + dictionary | 37 | 29 | 8 | 0.07 |
| local Small | 35 | 27 | 8 | 0.06 |
| local Base | 16 | 12 | 4 | 0.04 |

"+ dictionary" means every key term is in Yap's dictionary, which local whisper receives as its initial prompt (`WhisperPrompt.withVocabulary`). That's the best case for the dictionary: a real dictionary holds some of the words a user says, not all of them. Cloud engines get no dictionary here. Gemini returned an empty transcript for the `ml` clip on every try; it stays in its score.

What the numbers say:

- **mai-transcribe-2 is still the pick.** It has the best total and the best score on Reed, the voice that garbles English. gpt-4o-mini-transcribe and Gemini match it on Tingting (40 and 39 of 42) and fall behind on Reed.
- **For local whisper, the dictionary is worth more than a bigger model.** The default quantized Turbo gains 9 terms (45 → 54), more than the step up to Large v3 (47). Small gains 18 (35 → 53) and Base 21 (16 → 37). Turbo's gains are names and product words it otherwise misspells (Sarah, Kevin, Priya, IndexedDB, Redis, Tailwind) and it loses none. Small gains 20 and loses 2 ("pipeline", "refresh token").
- **Local Small + dictionary sits with the cloud models** at 0.08 real-time factor. Without a dictionary it's 35.

Rerun after touching the local whisper path, the default models or the dictionary prompt, and add a dated section.
