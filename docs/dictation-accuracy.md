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
| Yap Cloud `microsoft/mai-transcribe-2` (the Yap Cloud setup) | **59** | 39 | 20 | 0.10 |
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

- **Yap Cloud is the same model, same result.** Through paygate mai-transcribe-2 scores the same 59 as through OpenRouter, with the same per-voice split. 10 of 11 transcripts are character-for-character identical; the eleventh (`infra`, which both get wrong) differs by a few words. Neither request sends a language (the app sends one only when a mode pins it) or a prompt, so there is nothing to explain. It was faster from this Mac: p50 0.53 s per clip against 0.84 s direct, as in [cloud-latency.md](cloud-latency.md). The run cost $0.0022 for 11 clips (65 s of audio), from the account's ledger: 11 entries, billed in whole seconds at $0.11/h (OpenRouter's $0.10/h plus the 10% markup).
- **mai-transcribe-2 is still the pick.** It has the best total and the best score on Reed, the voice that garbles English. gpt-4o-mini-transcribe and Gemini match it on Tingting (40 and 39 of 42) and fall behind on Reed.
- **For local whisper, the dictionary is worth more than a bigger model.** The default quantized Turbo gains 9 terms (45 → 54), more than the step up to Large v3 (47). Small gains 18 (35 → 53) and Base 21 (16 → 37). Turbo's gains are names and product words it otherwise misspells (Sarah, Kevin, Priya, IndexedDB, Redis, Tailwind) and it loses none. Small gains 20 and loses 2 ("pipeline", "refresh token").
- **Local Small + dictionary sits with the cloud models** at 0.08 real-time factor. Without a dictionary it's 35.

Rerun after touching the local whisper path, the default models or the dictionary prompt, and add a dated section.

## 2026-09-26: the dictionary on cloud transcription

OpenRouter and Yap Cloud now send the dictionary and the language (`TranscriptionHints`). The language goes in OpenRouter's top-level `language` field, and only when the user picked one. Terms go in `provider.options`, under the field of the provider that serves the model. A probe clip with three invented words (Kwyntel, Zorvex, Brisquo) showed which fields work:

| model (provider) | field | invented terms right, without → with |
|---|---|---|
| mai-transcribe-2 (Azure) | `azure.phraseList.phrases` | 0 → 3 (`azure.prompt` is ignored) |
| gpt-4o-transcribe (OpenAI) | `openai.prompt` | 0 → 2 |
| gpt-4o-mini-transcribe (OpenAI) | `openai.prompt` | 0 → 1 |
| whisper-large-v3 (Groq / DeepInfra / Together) | `prompt` | 0 → 1 |
| qwen3-asr-flash (Alibaba) | `context` | 0 → 0: no terms sent |
| gemini-3.5-transcribe (Google AI Studio) | `prompt` | HTTP 400: no terms sent |

On this bench, with every key term in the dictionary (`bench.py run openrouter|yapcloud <model> --vocab`):

| engine | key terms (of 82) | p50 s |
|---|---|---|
| mai-transcribe-2 via OpenRouter | 59 → 68 | 0.84 → 0.97 |
| mai-transcribe-2 via Yap Cloud | 59 → 68 | 0.53 → 0.66 |

paygate forwards `provider.options` unchanged, so Yap Cloud needs no paygate change. The other models' `--vocab` runs are still to do; a model that gains nothing there should be dropped from `TranscriptionHints.providerOptions`.

## Dictionary as a prompt for cloud transcription (2026-09-27)

`bench.py run openrouter|yapcloud <model> --vocab` sends every key term, comma separated, as a `prompt` field:
a multipart field on OpenRouter, a JSON key on Yap Cloud. Neither rejects it.

| engine | without prompt | with prompt | transcripts identical |
|---|---|---|---|
| OpenRouter `microsoft/mai-transcribe-2` | 59 | 59 | 9 of 11 |
| Yap Cloud `microsoft/mai-transcribe-2` | 59 | 59 | 11 of 11 |
| OpenRouter `openai/gpt-4o-mini-transcribe`, 3 runs each | 52, 45, 46 (mean 47.7) | 49, 50, 48 (mean 49.0) | 0 of 11 |

mai-transcribe-2 ignores the prompt. The two OpenRouter transcripts that differ differ the same way two runs
without a prompt do. gpt-4o-mini-transcribe does read it, but the gain is smaller than its run-to-run spread
(45–52 without a prompt). So on the cloud path the dictionary is only worth sending to the cleanup model, where it
already goes. Passing it to transcription isn't worth changing the client or paygate for the default model.
Results committed: the first run of each (`*-vocab-prompt.jsonl`).

Superseded by the section above: `prompt` is the wrong field for mai-transcribe-2 (Azure reads `azure.phraseList.phrases`), and with the right field it goes 59 → 68.
