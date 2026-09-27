# Yap Cloud model allowlist

Yap Cloud (paygate) serves only the models in its `MODEL_ALLOWLIST` env var on Railway. Every other id gets
400 `MODEL_NOT_ALLOWED`, and `/v1/models` lists only these, so the app's "All Models" list shows the same set.

| Use | Model | Why it is here |
|---|---|---|
| Transcription (default) | `microsoft/mai-transcribe-2` | 59/82 key terms, p50 0.53 s via Yap Cloud (docs/dictation-accuracy.md) |
| Transcription | `openai/gpt-4o-mini-transcribe` | 52/82 |
| Transcription | `google/gemini-3.5-transcribe` | 49/82 (returns empty on the `ml` clip) |
| Transcription | `openai/whisper-large-v3` | 48/82, cheapest per minute |
| Transcription | `openai/gpt-4o-transcribe` | shown in YapCloudPicks; synthetic check 49/52 |
| Transcription | `qwen/qwen3-asr-flash-2026-02-10` | shown in YapCloudPicks; synthetic check 46/52 |
| Enhancement (default) | `deepseek/deepseek-v4.1-flash` | setup/bench.py 9/9, p50 0.44 s |
| Enhancement | `openai/gpt-6-luna` | setup/bench.py 8/9, p50 0.86 s |
| Enhancement | `deepseek/deepseek-v4-flash` | cheap; not benchmarked yet |

## Changing the list

1. Bench the candidate: `setup/asr/bench.py run yapcloud|openrouter <id>` for transcription, `setup/bench.py` for
   enhancement. Add the result to the table above.
2. Set the whole list (comma separated, exact OpenRouter ids) on the service; Railway redeploys on change:
   `railway variables -s paygate --set "MODEL_ALLOWLIST=<id>,<id>,…"` (run in the paygate repo).
3. If the model should be shown up front, add it to `YapCloudPicks` in
   `VoiceInk/Infrastructure/Cloud/YapCloudClient.swift` (`make cloud-smoke` fails if a pick isn't on the live list). Never drop the `RecommendedSetup` models from the list: a choice outside it runs on them (the app falls back at call time and on a 400 `MODEL_NOT_ALLOWED`, and Yap Cloud's page lists which modes to change).
