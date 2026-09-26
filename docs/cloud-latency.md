# Yap Cloud latency

How long a dictation takes through Yap Cloud, where the time goes, and what each optimisation changed. Numbers come from `make cloud-latency`; rerun it after anything that touches the request path and add a section here.

## Method

`make cloud-latency PAYGATE_DIR=<railway-linked paygate checkout>` (`scripts/cloud-latency/main.swift`):

- Compiles the real client files (`YapCloudClient.swift`, `YapCloudProvider.swift`) like `make cloud-smoke`, no app launch.
- Creates its own throwaway account with paygate's `scripts/issue-token.ts` (`latency+<timestamp>@…`, no sign-up credit), funds it $0.05 with `scripts/adjust.ts`, and at the end waits until the balance stops moving (a call the client gave up on is still billed when it finishes), adjusts it back to exactly $0 and deletes the account. The shared smoke account is never used.
- Three code-switched clips spoken by macOS `say` (Chinese voice), 16 kHz mono 16-bit WAV like Yap records: **short 2.7 s (90 KB), medium 14.6 s (459 KB), long 40.4 s (1267 KB)**.
- Per clip, 5 runs, interleaved:
  - **via Yap Cloud**: `YapCloudProvider.transcribe` (MAI-Transcribe-2), then `YapCloud.chatCompletion` with the Recommended enhancement model (DeepSeek V4.1 Flash) and `RecommendedPrompt.md`. Wall-clock time of the real client call, including its connection setup.
  - **direct**: the same request bodies sent straight to OpenRouter with a personal key (`OPENROUTER_API_KEY`, or `~/.env`), on a fresh connection like the client's. The difference is paygate's hop.
- `HEAD /healthz` on a new connection vs a reused one: what connection setup (TCP + TLS) costs per call.
- Tables are p50 / p95 in milliseconds. With 5 runs, p95 is effectively the slowest run.
- Measured from Jackson's Mac (China mainland network) against `https://cloud.yap.sma1lboy.me`; absolute numbers depend on that path, comparisons between rows don't.

## Where paygate spends time (from `src/proxy.ts`, not changed)

Before forwarding: token lookup, reading and `JSON.parse` of the whole request body, then two sequential DB queries (balance, monthly cap). The upstream request starts only after the full body has arrived. After a non-streaming response with a known cost, the ledger insert (`settle`) is awaited before paygate answers; for streams it runs after the stream is passed through.

## Baseline (2026-09-26)

| clip | audio | STT via Yap Cloud | STT direct | enhance via Yap Cloud | enhance direct | STT+enhance via Yap Cloud |
|---|---|---|---|---|---|---|
| short | 2.7 s, 90 KB | 346 / 409 | 658 / 1588 | 1233 / 2462 | 1919 / 2331 | 1569 / 2828 |
| medium | 14.6 s, 459 KB | 534 / 582 | 985 / 1348 | 584 / 715 | 749 / 1256 | 1104 / 1296 |
| long | 40.4 s, 1267 KB | 768 / 859 | 804 / 1293 | 8078 / 11260 | 6062 / 9465 | 8847 / 12114 |

| HEAD /healthz | new connection | reused connection |
|---|---|---|
| p50 / p95 ms | 115 / 119 | 74 / 84 |

Findings:

- **paygate's hop is not the bottleneck.** Transcription through Yap Cloud is as fast as or faster than going to OpenRouter directly from this Mac (p50 346 vs 658 ms, 534 vs 985, 768 vs 804): paygate's server-side connection to OpenRouter is short and warm, and that outweighs buffering the body. Enhancement through Yap Cloud and direct are within noise of each other.
- **Enhancement dominates, and it's the model's reasoning.** The client sent DeepSeek V4.1 Flash a plain request, so it reasons at its default effort ("high"; ledger rows show `reasoning_tokens`). That is 8 s at p50 on the long clip and up to 11 s, and it varies with the input: an earlier run with a 27 s clip took 23 s at p50 and hit the 30 s client timeout (still billed). The app's own OpenRouter path turns reasoning off (`OpenRouterRequestPolicy.lowLatency`); the Yap Cloud path didn't.
- **A new connection costs ~40 ms** (115 vs 74 ms for `/healthz`), paid on every call today because each Yap Cloud call opens its own ephemeral `URLSession`.

## 1. Enhancement without reasoning (2026-09-26)

`YapCloud.chatCompletion` now sends the same low-latency shape as the app's OpenRouter path (`YapCloud.chatBody`): `reasoning: {enabled: false, exclude: true}`, providers required to honour it and sorted by throughput with a p90 target. paygate's `/v1/models` carries no reasoning metadata, so a model that can't disable reasoning answers 400 (unbilled) once, is remembered, and is sent again without the setting. The direct column uses the identical body.

| clip | audio | STT via Yap Cloud | STT direct | enhance via Yap Cloud | enhance direct | STT+enhance via Yap Cloud |
|---|---|---|---|---|---|---|
| short | 2.7 s, 90 KB | 387 / 484 | 342 / 423 | 298 / 369 | 249 / 485 | 692 / 766 |
| medium | 14.6 s, 459 KB | 578 / 600 | 833 / 1053 | 459 / 977 | 361 / 430 | 1024 / 1578 |
| long | 40.4 s, 1267 KB | 698 / 993 | 771 / 1355 | 564 / 590 | 552 / 649 | 1274 / 1557 |

Enhancement on the long clip: **8078 → 564 ms p50, 11260 → 590 ms p95**; a whole long dictation (transcribe + enhance) 8847 → 1274 ms p50. Enhancement now costs about the same through Yap Cloud as direct (≈ +50–100 ms: paygate's DB checks and the awaited ledger insert on a small body). Output quality: the setup bench (`setup/bench.py`) scored this model 9/9 with reasoning off, which is how the app's OpenRouter path always ran it.
