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

## Which dictionary words a request carries (2026-10-03)

Sending a word to a model is a hint, not a guarantee: the model can still spell it differently, and nothing here was measured for accuracy. This section is about which words go out.

Every cloud request reads the dictionary when it starts (`DictionaryTerms.newestFirst`), so a word added or deleted counts from the next request. The words are trimmed, blank ones dropped, and spellings that differ only in case sent once. The list is ordered **most recently added first**; words added at the same moment go by spelling (Unicode order), so the order never depends on how SwiftData returns rows. A request that takes at most N words sends the first N, so once the dictionary is over N the oldest words are the ones left out. Before this, the list was alphabetical, so a 101st word that sorted late (say "ZNewestName" after A000…A099) was never sent. That is our choice, not a provider rule. Of two spellings that differ only in case, the newer one is sent, as typed.

So a word you just typed into the Dictionary is near the front, but whether it is sent depends on the consumer: some models take no words at all (table below), LLMkit leaves out words over a per-word length for xAI, AssemblyAI and ElevenLabs, and local Whisper takes only what fits its prompt budget (below). "Newest" is `dateAdded`, not when the word arrived: a word imported just now with an old `createdAt` counts as old.

`dateAdded` is when a word was added: typed in the Dictionary or added by Auto Learn, it's the moment it was saved (several words pasted together count as added in order). Words from an imported dictionary file keep the file's `createdAt`, or get the import time if the file has none, and so do words from a settings backup or config. Nothing updates `dateAdded` after that; a word's use isn't counted.

Who sends what (provider limits read in the providers' own docs on 2026-10-03, linked; "app" means our budget, not theirs):

| consumer | where the words are read | words sent | provider's documented limit |
|---|---|---|---|
| Deepgram batch `keyterm` (dictation, file import, History re-transcribe, meeting pieces) | `CloudTranscriptionService.swift:77` → `DeepgramProvider.swift:70` | first 100 (app; LLMkit also stops at 100) | [500 tokens across all keyterms, more is an error; "up to 100" is a recommendation](https://developers.deepgram.com/docs/keyterm) |
| Deepgram live `keyterm` | `DeepgramStreamingProvider.swift:33` | first 100 (app) | same |
| OpenRouter / Yap Cloud: mai-transcribe-2 `azure.phraseList.phrases`; gpt-4o(-mini)-transcribe `openai.prompt`; whisper-large-v3 `prompt` | `CloudTranscriptionService.swift:77` → `TranscriptionHints.apply` (`OpenRouterProvider.swift:89`, `YapCloudProvider.swift:36`) | first 100 (app, `TranscriptionHints.maxTerms`); for whisper-large-v3 written newest last, because Whisper keeps only a long prompt's last 224 tokens | Azure: [no more than 2,000 phrases suggested](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/improve-accuracy-phrase-list); OpenAI: [a prompt over the model's length (not published) rejects the request; whisper-1 takes up to 224 tokens](https://developers.openai.com/api/docs/guides/speech-to-text); Groq, DeepInfra and Together's own whisper-large-v3 limits not checked |
| OpenRouter / Yap Cloud: other models (gemini-3.5-transcribe answers 400, qwen3-asr-flash ignores it, the rest untested) | same | none; only `language` | — |
| xAI batch and live `keyterm` | `CloudTranscriptionService.swift:77`, `XAIStreamingProvider.swift:40` | whole list; LLMkit sends the first 100 of up to 50 characters | [100 terms of up to 50 characters](https://docs.x.ai/developers/rest-api-reference/inference/speech-to-text) |
| AssemblyAI live `keyterms_prompt` | `AssemblyAIStreamingProvider.swift:40` | whole list; LLMkit sends the first 100 (≤ 50 characters, ≤ 6 words) | [100, more is an error; longer than 50 characters ignored](https://www.assemblyai.com/docs/streaming/prompting-and-keyterms) |
| AssemblyAI batch `keyterms_prompt` | `CloudTranscriptionService.swift:77` | whole list; LLMkit caps at 200 (universal-2) or 1,000 | [Universal-2: 200; Universal-3.5 Pro: 1,000](https://www.assemblyai.com/docs/getting-started/models), [up to 6 words each](https://www.assemblyai.com/docs/pre-recorded-audio/universal-3-5-pro/prompting) |
| ElevenLabs batch / live `keyterms` | `CloudTranscriptionService.swift:77`, `ElevenLabsStreamingProvider.swift:41` | whole list; LLMkit caps at 1,000 (≤ 50 characters) / 50 (≤ 20 characters) | batch: [1,000, each under 50 characters and at most 5 words](https://elevenlabs.io/docs/api-reference/speech-to-text/convert); live: [50 of up to 20 characters](https://elevenlabs.io/docs/eleven-api/guides/how-to/speech-to-text/batch/keyterm-prompting) |
| Gemini batch / live `custom_vocabulary` | `CloudTranscriptionService.swift:77`, `GeminiStreamingProvider.swift:40` | whole list; LLMkit caps at 1,000 | [1,000 (best results with up to 100)](https://ai.google.dev/gemini-api/docs/transcribe), [live the same](https://ai.google.dev/gemini-api/docs/live-api/live-transcribe) |
| Soniox `context.terms`, Speechmatics `additional_vocab` (batch and live) | `CloudTranscriptionService.swift:77`, `SonioxStreamingProvider.swift:32`, `SpeechmaticsStreamingProvider.swift:32` | whole list | Soniox: [8,000 tokens for the whole context](https://soniox.com/docs/stt/concepts/context); Speechmatics: [1,000 suggested, over 20,000 rejected](https://docs.speechmatics.com/speech-to-text/features/custom-dictionary) |
| Groq, Mistral (batch and live), Cartesia live, custom OpenAI-compatible endpoints | — | none | — |
| Local Whisper prompt (Whisper models only) | `WhisperTranscriptionService.swift:80` (`initialPrompt`, each request) | after the base prompt, newest first while they fit about 200 estimated tokens; a word that doesn't fit is skipped; written newest last (below) | whisper.cpp keeps the prompt's last 223 tokens: half the 448-token text context, less one for the marker before it ([`max_prompt_ctx`, `n_take1`](https://github.com/ggml-org/whisper.cpp/blob/d09f61a708f3487afa956ff578e60eae5e7a233c/src/whisper.cpp#L7093), the build in use) |
| AI cleanup prompt, dictionary export, MCP | `AIEnhancementService.swift:158`, `DictionaryImportExportService`, `YapLibrary.swift:178` | whole dictionary, alphabetical, unchanged | — |

Dictation, file import, History re-transcribe and meeting pieces all reach cloud batch through `TranscriptionServiceRegistry` → `CloudTranscriptionService`; live dictation goes through the provider's streaming class. The 100 is unchanged: 100 long words can still pass Deepgram's 500-token total, which nothing checks before sending.

`make vocabulary-hints-check` runs these requests in the Debug app against an in-memory dictionary. Every request is recorded in-process and answered there, and IP traffic is denied. It checks the words in each request's URL, JSON body or form: over 100 words, after a delete and an add, blanks, case duplicates, CJK and mixed words, and 101 words with the same date inserted in two orders. For local Whisper it checks the prompt `WhisperTranscriptionService` builds (with the zh base prompt, no model loaded) for the same dictionaries, plus one whose two newest words, 900 letters and 120 CJK characters, are each over the budget. Not checked: what the provider does with the words, and whether OpenRouter's other upstream providers forward them.

### Local Whisper's prompt

Only Whisper models get the dictionary locally; Parakeet, Apple Speech and transcribe.cpp models don't, and live preview decodes get no prompt. For each request `WhisperTranscriptionService.initialPrompt` reads the dictionary through `DictionaryTerms.newestFirst` (same trimming, case duplicates and order as cloud) and `WhisperPrompt.withVocabulary` appends to the request's base prompt (the language's built-in prompt or the user's own, `WhisperPrompt.resolvedPrompt`, not changed) the words that fit a budget of 200 estimated tokens:

- The estimate isn't Whisper's tokenizer: about one token per 3 characters, two per CJK character (U+3000–U+9FFF), plus one per word for the `, ` before it. 200 leaves room under whisper.cpp's 223 for the estimate being off; it isn't exact. Scripts outside that range (Hangul, Cyrillic, Arabic…) are counted like Latin and can take more real tokens than estimated; if a prompt does go over, whisper.cpp drops its start, the base first.
- The base is counted first. A base at or over 200 gets no words and goes as it is, never cut.
- Words go newest first while they fit. A word bigger than what's left is skipped whole, never cut into a shorter made-up word, and older words that fit still go; nothing is removed from the dictionary. Until 2026-10-03 the first word that didn't fit ended the list, so one 900-letter newest word left the prompt with no words.
- Words with the same `dateAdded` go by spelling, as on cloud, so the prompt doesn't depend on SwiftData's row order.
- The words that fit are written oldest first, newest last, because whisper.cpp keeps a long prompt's tail.

So a word just added reaches local Whisper only with a Whisper model and only if it fits what the base and the newer words leave. Behind the zh base prompt (about 27 estimated tokens) that is about 56 short words like `A001`.

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
