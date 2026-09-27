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
| Enhancement (default) | `deepseek/deepseek-v4.1-flash` | 25/25 cleanup cases in 3 of 3 rounds, p50 0.57 s, $0.00013 per call (see below) |
| Enhancement | `openai/gpt-6-luna` | 24–25/25, p50 1.11 s, $0.00003 per call |
| Enhancement | `deepseek/deepseek-v4-flash` | 23–25/25, p50 1.24 s, $0.00006 per call |

## Changing the list

1. Bench the candidate: `setup/asr/bench.py run yapcloud|openrouter <id>` for transcription, `setup/bench.py run
   yapcloud <id>` for enhancement. Add the result to the table above.
2. Set the whole list (comma separated, exact OpenRouter ids) on the service; Railway redeploys on change:
   `railway variables -s paygate --set "MODEL_ALLOWLIST=<id>,<id>,…"` (run in the paygate repo).
3. If the model should be shown up front, add it to `YapCloudPicks` in
   `VoiceInk/Features/Account/YapCloudModelBrowser.swift`. Never drop the `RecommendedSetup` models from the list.

## Enhancement bench (2026-09-27)

`python3 setup/bench.py run yapcloud <model>` then `python3 setup/bench.py score`. It runs 25 dictations through
`RecommendedPrompt.md`, 3 rounds per model. The original 9 are in `setup/cases.json`. The 16 added in
`setup/cases_extra.json` cover self-corrections (numbers, names, list items), lists from "首先/其次", bullet and
step lists, code identifiers, recognition errors ("P 二", "use effect"), English terms that must not be translated,
requests that must not be answered, and short replies. Each case has automatic checks: required and forbidden
text, list or no list, maximum length. Requests are the app's own Yap Cloud body (streamed, reasoning off,
throughput routing), sent through production paygate with the bench account. Cost per call comes from the
account ledger, markup included. The table below is the first run, on the prompt before the change described
further down; `setup/enhance-results/` holds the runs on the current prompt.

| model | passed per round (of 25) | original 9 | p50 | p95 | cost per call |
|---|---|---|---|---|---|
| `deepseek/deepseek-v4.1-flash` (default) | 23, 23, 24 | 8 | **0.53 s** | 0.94 s | $0.000188 |
| `openai/gpt-6-luna` | **25, 24, 25** | **9** | 1.05 s | 1.42 s | $0.000118 |
| `deepseek/deepseek-v4-flash` | 23, 23, 23 | 8 | 1.24 s | 1.56 s | **$0.000041** |

Where each one fails:
- **deepseek-v4.1-flash** keeps the retracted part of a correction ("周四下午三点，不是周三", every round). It writes
  "首先…其次…最后" as prose instead of a list (2 of 3 rounds).
- **gpt-6-luna** once wrote a three-item shopping list as a sentence.
- **deepseek-v4-flash** writes lists as prose, every round: the `spec` case (five items) and "首先/其次". Unlike
  v4.1 it drops the retracted "不是周三".

Against the old hand-judged numbers: v4.1-flash was "9/9" on the original 9. The automatic check fails its
`correct` output because the prompt says to drop the negated part, and "不是周三" is that part (the same thing
counted against Yap Refine in local-models.md).

Cost: none of the three produced reasoning tokens. v4.1-flash costs the most even though its listed price is the
lowest: throughput routing sends it to a provider that bills about 4× the listed per-token price. That provider
is also why it's the fastest. At these prices 1,000 dictations cost about $0.19 (v4.1), $0.12 (gpt-6-luna) or
$0.04 (v4). The whole bench (225 calls) cost $0.026.

**Recommendation: keep deepseek-v4.1-flash as the default.** It is twice as fast as the other two at p50, and
enhancement time is what the user waits for after they stop talking. Its two failure types leave text in a
readable state (an extra "不是周三", prose instead of a list). gpt-6-luna is the most accurate and would be the
pick if the default ever moves toward accuracy over speed; the 0.5 s it adds is the cost. v4-flash is the
cheapest but the slowest, and fails more format cases, so it isn't a default candidate. The prompt change
below fixed v4.1's two failure types without switching models.

### After the prompt change (2026-09-27)

`RecommendedPrompt.md` gained three things aimed at v4.1-flash's two failure types:
- Rule 4: a retracted part must not survive as "不是……".
- Rule 6: "最后" joins the ordinal words, and a list is required even when the items are short.
- Rule 5: "超时六十秒"→超时 60 秒, so durations of 10 or more use digits.
- Two examples: a correction with a number, and an ordinal list whose items keep their English terms.

Three example drafts made other models worse and were replaced. A correction example with a Chinese time led
gpt-6-luna to write "六十秒". A list example with only Chinese items led it to translate "pull" as 拉取. A
correction example that ran on into a second topic taught v4-flash to stop splitting topics into paragraphs.

| model | before | after |
|---|---|---|
| `deepseek/deepseek-v4.1-flash` | 23, 23, 24 | **25, 25, 25** |
| `deepseek/deepseek-v4-flash` | 23, 23, 23 | 23, 25, 25 |
| `openai/gpt-6-luna` | 25, 24, 25 | 24, 25, 24 |

v4.1-flash now passes every case in every round, in each of the three separate runs made on the final prompt's
versions. gpt-6-luna is one pass lower over 3 rounds, with the misses in different cases each time (`retro`,
`command`). Over 6 rounds the old prompt scored 148/150, so a difference of one is within what repeated runs
of the same prompt show, but it isn't proven equal. The tables above (latency, cost) are from these final runs.
