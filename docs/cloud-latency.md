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

## 2. Streamed enhancement (2026-09-26)

`chatCompletion` sends `stream: true` and reads the SSE stream to the end before returning, so Yap still pastes one finished result. paygate answers a stream without first awaiting its ledger insert (it settles after the stream ends). Errors before the stream starts (402, 401, 429, a passed-through OpenRouter 4xx) are mapped from the status and body exactly as before (`make cloud-smoke` "402 chat" passes); an `{"error"}` chunk after the 200 throws and is not retried, since output had started and the call may be billed. The generation id comes from the chunks' `id`, so History's per-dictation cost still works (the harness now fails if any call returns no text or no id). The direct column still sends a non-streamed request.

| clip | audio | STT via Yap Cloud | STT direct | enhance via Yap Cloud | enhance direct | STT+enhance via Yap Cloud |
|---|---|---|---|---|---|---|
| short | 2.7 s, 90 KB | 436 / 519 | 563 / 1094 | 330 / 460 | 307 / 635 | 769 / 837 |
| medium | 14.6 s, 459 KB | 561 / 659 | 619 / 1187 | 496 / 808 | 358 / 732 | 1045 / 1309 |
| long | 40.4 s, 1267 KB | 766 / 1005 | 857 / 1136 | 695 / 1612 | 572 / 977 | 1462 / 2617 |

No measurable gain: enhancement p50 is 330 / 496 / 695 ms against 298 / 459 / 564 ms non-streamed, which is within this link's run-to-run noise (the direct column moved by about as much, and `/healthz` itself was ~8 ms slower this run). With reasoning off, a dictation's enhancement is a few hundred tokens, so time to the last token is almost all of it and the ledger insert paygate no longer waits on is a few ms. It stays because it costs nothing and no call waits on paygate's DB after the model is done.

## 3. One pooled connection, opened while the user speaks (2026-09-26)

Every paygate request (proxy calls, account reads, `/healthz`) now goes through one long-lived ephemeral `URLSession`, so a dictation's transcription and enhancement share one connection instead of a new TCP + TLS handshake each. The per-call sessions were copied from custom endpoints, where a shared session learns `Alt-Svc` and moves uploads to HTTP/3 that stalls behind some VPNs; paygate on Railway sends no `Alt-Svc` (`curl -sI …/healthz`: HTTP/2, no header), so this stays on HTTP/2.

Prewarm: when a recording starts in a mode that uses Yap Cloud and the preflight passes (signed in, balance and cap OK), the client sends `HEAD /healthz` on that session, so the connection is open before the user stops speaking. Most dictations start from a hotkey in another app, so recording start is the moment that precedes a call; app activation already refreshes the account through the same session and needs nothing extra. The harness now does the same per run: prewarm, wait the clip's length, then transcribe and enhance. The direct columns still open a new connection per call.

| clip | audio | STT via Yap Cloud | STT direct | enhance via Yap Cloud | enhance direct | STT+enhance via Yap Cloud |
|---|---|---|---|---|---|---|
| short | 2.7 s, 90 KB | 290 / 412 | 648 / 1199 | 273 / 430 | 275 / 329 | 582 / 681 |
| medium | 14.6 s, 459 KB | 464 / 917 | 1083 / 1342 | 350 / 377 | 348 / 439 | 834 / 1251 |
| long | 40.4 s, 1267 KB | 633 / 706 | 1203 / 1712 | 615 / 648 | 620 / 796 | 1252 / 1292 |

Transcription p50 is 100–150 ms lower than in §2 (436 → 290, 561 → 464, 766 → 633 ms), and a whole dictation 769 → 582, 1045 → 834, 1462 → 1252 ms p50. Enhancement through Yap Cloud is now level with direct.

## 4. Before the upload: nothing to drop

- `CoreAudioRecorder` converts to 16 kHz mono 16-bit PCM in its render callback while recording, so the WAV is final when recording stops. No resampling or re-encoding happens after that.
- `CloudTranscriptionService` reads the file's bytes (`Data(contentsOf:)`), and `YapCloudProvider` base64-encodes them into paygate's JSON body. Base64 is the required format: paygate accepts only OpenRouter's JSON transcription body, not multipart.
- The sleeps between stop and paste are on other paths: Yap Refine's 450 ms model-prep debounce, and the 150 ms before an auto-send key press after pasting.
- What's left is the upload size. The long clip is 1.27 MB (1.7 MB in base64) and transcribes about 340 ms slower than the short one. Compressing before upload (FLAC is lossless, about half the size) could save part of that, but it adds encode time and needs checking that OpenRouter's transcription models accept the format. It's not done here, since the gain would be under ~200 ms on a 40 s dictation.

## 5. Reasoning chosen per model from `/v1/models` (2026-09-26)

paygate's `/v1/models` now passes through OpenRouter's `supported_parameters` and `reasoning` (`{mandatory, supported_efforts, default_effort}`) per model (paygate 3259c5c, client-guide §4). The fixed `reasoning: {enabled: false}` and the rule that learned models from their 400 are gone. `YapCloud.chatBody` now reads the metadata:

- `reasoning` is null, or the model isn't in the catalog: no reasoning parameters.
- `mandatory: false`: `{effort: "none", exclude: true}`. Checked directly on DeepSeek V4.1 Flash, where `supported_efforts` doesn't list `none`: 0 reasoning tokens, ~0.4 s. `low` still reasons (~270 tokens, 1.5–2.6 s).
- `mandatory: true`: the lowest effort in `supported_efforts`. For gpt-5-mini that's `minimal`: 0 reasoning tokens, no 400, ~1 s.
- Only parameters in `supported_parameters` are sent (gpt-5-mini doesn't list `temperature`), with `require_parameters` whenever the list is known.

The catalog is now refreshed on every launch, not only from Account. Otherwise a catalog cached before paygate published this metadata would send the recommended model with no reasoning setting, back to the baseline's 8 s.

| clip | audio | STT via Yap Cloud | STT direct | enhance via Yap Cloud | enhance direct | STT+enhance via Yap Cloud |
|---|---|---|---|---|---|---|
| short | 2.7 s, 90 KB | 436 / 650 | 1228 / 1378 | 315 / 362 | 324 / 400 | 743 / 1012 |
| medium | 14.6 s, 459 KB | 456 / 525 | 1039 / 3077 | 400 / 557 | 356 / 419 | 925 / 1007 |
| long | 40.4 s, 1267 KB | 1143 / 1359 | 1347 / 3092 | 604 / 660 | 627 / 969 | 1737 / 2015 |

This change affects enhancement only, and enhancement didn't regress: 315 / 400 / 604 ms p50 against 273 / 350 / 615 ms in §3, and level with direct. Transcription was slower on this run's network, direct included (STT direct p95 3 s, a new connection 143 vs 115 ms), so the long-clip total is higher for reasons outside this change.

## Summary

The long clip (40 s), transcribe + enhance through Yap Cloud, p50 / p95 in ms:

| stage | p50 | p95 |
|---|---|---|
| baseline | 8847 | 12114 |
| reasoning off (§1) | 1274 | 1557 |
| streamed (§2) | 1462 | 2617 |
| pooled + prewarmed (§3) | 1252 | 1292 |

The streamed row is noise on this link (see §2), not a regression. paygate is not the bottleneck: through Yap Cloud, transcription is faster than calling OpenRouter directly from this Mac, and enhancement matches direct once the connection is reused. paygate now publishes each model's reasoning metadata in `/v1/models`, and the client sets reasoning from it before the call (§5).
