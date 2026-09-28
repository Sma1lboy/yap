# First local dictation: what a new user goes through

From installing Yap to the first dictation with the default local model, Whisper Large v3 Turbo (Quantized),
`ggml-large-v3-turbo-q5_0.bin`, 547 MB (574,041,195 bytes). Checked 2026-09-27 against main e59edf1 by reading
`WhisperModelManager`, the onboarding model step and the recording preflight, then measured with the Debug app run
as the mock identity (`scripts/mock.sh`: its own defaults, Application Support and keychain; the dev app's defaults
domain was exported before and compared after each run; it stayed the same except during the last run, when
another session working on the dev app rewrote its modes. None of the changes carried this check's settings).

## Checklist (before the fixes)

| # | Area | Finding | Status |
|---|---|---|---|
| 1 | Progress | Percent only. No bytes, speed or time left. | fixed |
| 2 | Resume | None. A dropped connection or Cancel restarts from 0 %, yet the button then reads "Resume Download". | fixed within a session: a failed or cancelled download keeps URLSession's resume data (also on disk) and Retry continues from there. A quit during the download still restarts |
| 3 | Integrity | Only the HTTP status is checked. No size or sha256 check; any 200 body (a captive portal page) would be saved as `<name>.bin`, and every `.bin` in the folder is treated as a model. | fixed: size and sha256 from Hugging Face's `x-linked-size` / `x-linked-etag` |
| 4 | Disk space | Not checked. The finished download was read back into memory and written again, so it needed about twice the model size, and a full disk showed a raw system error. | fixed: checked up front with a plain message, and the file is moved instead of copied |
| 5 | Leftovers | The final write was atomic, but the intermediate copy sat in the models folder under a random name. Errors removed it; a quit mid-copy left it forever. | fixed: `<name>.bin.part` until verified, stale parts removed at launch |
| 6 | Hotkey during the download | Preflight blocks the recording before it starts (no audio lost), but the toast says the model "is not available" and says nothing about the running download. | fixed: says it's still downloading, with the percentage |
| 7 | Timing | See below. | measured |
| 8 | First dictation after the download | 17.8 s instead of 1.5 s: the first run of whisper.cpp compiles its Metal shaders (cached per app afterwards). The app's post-download warmup, which would pay this in the background, skipped quantized models, including the default; it was written for the Core ML encoder, which only non-quantized models have. | fixed: every downloaded model is warmed up |

## Timing

`make first-run-check` (`scripts/first-run-check.sh`) does a fresh install as the mock identity: its own defaults,
Application Support, keychain and Metal shader cache, no model on disk, one mode on the default model. It starts
the download the way onboarding's Download button does and asks the shortcut's preflight mid-download. When the
model is in, it dictates the `security` clip twice. `WAIT=1` waits for the warmup first. M4 Pro, 65 MB/s
connection, 2026-09-27:

| step | before | after |
|---|---|---|
| Download + verify (547 MB) | not verified | 9.2–26 s (network; curl alone 8.7 s, sha256 1.0 s) |
| Shortcut pressed mid-download | "'Large v3 Turbo (Quantized)' is not available for the Dictation mode" | "Large v3 Turbo (Quantized) is still downloading (6%). Dictation works as soon as it finishes." |
| First dictation right after the download | 17.8 s | 17.9 s (the warmup and the dictation both wait on the same shader compile) |
| Warmup after the download | skipped | 17.0 s in the background |
| First dictation once the warmup is done | – | 2.5 s |
| Later dictations | 1.4–1.5 s | 1.3–1.5 s |

So from clicking Download to the first finished dictation is about 9 s of download, 17 s of shader compilation,
and 1.5–2.5 s of dictation. The compilation now happens right after the download, while onboarding moves on to its
next screens, instead of inside the first dictation. A user who dictates the moment the download ends still waits
the full 17 s once. The shader cache survives relaunches.
