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
