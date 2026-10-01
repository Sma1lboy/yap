# Dictation latency: from letting go to the paste

What the user waits for after a dictation: from the moment they stop it to the ⌘V that puts the text in front of
them. Yap records this for every dictation on this Mac; `make dictation-latency` measures it without a microphone.

M3 in four lines (M4 Pro, Debug build, local Large v3 Turbo (Quantized); details below):

- **Default, language on Auto-detect:** stop → ⌘V p50 went from 1343 to 1181 ms, −12 % ("Results"). Transcripts
  didn't change. This is what every user gets.
- **A fixed language, opt-in** (the mode's picker, or Yap's suggestion after 20 one-language dictations): about
  0.45 s less again, but at a cost. Chinese character errors go from 22.4 % to 24.4 %, and a whole sentence in the other
  language comes out wrong (61.5 % errors with `zh` on code-switched recordings, against 14.6 % on auto). Fixed English
  is faster and more accurate for English-only speech (1.3 → 0.3 %). See "Auto-detect or a fixed language".
- **Home** shows this Mac's stop → ⌘V median: the time to Yap sending ⌘V, not to the text appearing in the app.
- **Not measured:** a paste arriving in a real app, the recorder's stop with a real microphone, and Auto Learn's reads
  in real apps. The checks here dry-run the paste and read no app.

## What every dictation records

`DictationTimeline` follows one dictation; `SessionMetricRecorder` copies it onto the dictation's `SessionMetric` in
stats.store. Nothing leaves the Mac.

The stop (`stopSource`), on the clock of `ProcessInfo.systemUptime`:

| `stopSource` | When | Time used |
|---|---|---|
| `shortcutRelease` | push-to-talk, hybrid held past 0.5 s, double tap, Rewrite Last Dictation | the key-up event's own timestamp |
| `shortcutPress` | toggle mode, hybrid tapped: the second press stops | the second key-down event's timestamp |
| `recorderButton` | the recorder's record button | when the click was handled |
| `finishAndSend` | the recorder's Finish and Send | when it was handled |
| `other` | menu bar, Shortcuts app, anything else that toggles the recorder | when the stop was triggered |
| `file` | DEBUG `make dictation-latency` only | once the file is in place |

Shortcut event times come from the CGEvent itself (mach ticks converted to uptime, `ShortcutMonitor`), so a busy main
thread doesn't make the stop look later than it was. An event without a usable timestamp falls back to the time it
was handled and logs that once.

Then, in seconds after the stop (nil when the step didn't happen):

| Field | Step |
|---|---|
| `stopToRecorderStopped` | the recorder drained its buffers, flushed the resampler and closed the WAV (`CoreAudioRecorder.stopRecording`) |
| `stopToModelReady` | only when the transcription waited for the model: a load still running from the press (Keep model loaded: After Each Dictation releases it after every dictation), or one it had to start (no preload, or another model) |
| `stopToTranscribed` | the model returned its text |
| `stopToProcessed` | output filter, Chinese cleanup, trigger words, paragraph formatting and word replacements done |
| `stopToEnhanced` | AI cleanup returned or failed |
| `stopToPasteCommand` | the V key-down of ⌘V (AppleScript paste: when the script returned) |

`pasteOutcome`: `pasted` (⌘V sent), `clipboardOnly` (no Accessibility permission: the text was left on the clipboard
with a notification), `scratchpad` (no editable field had focus: the text went to the Scratchpad and the clipboard),
`failed` (clipboard couldn't be set or the key events couldn't be sent). Nil when the text wasn't pasted: a response
in the recorder, a custom command, "scratch that".

With the mode's language on Auto-detect and a local Whisper model, the SessionMetric also has `detectedLanguages`
(the languages Whisper decoded the dictation in, in order, comma-separated: `zh`, `en`, `en,zh`) and
`languageDetectionDuration` (seconds the detection passes took). Every metric has `modeID`, the mode whose language
setting the transcription used. All three are nil with a fixed language, on cloud models and Parakeet, and for
meetings, imported files and the live preview, which run outside a dictation's DictationTimeline.

Metrics from before these fields existed read nil (optional attributes, SwiftData lightweight migration). Home shows
the stop → ⌘V median ("On Home" below); Insights only takes the measured waits off its time saved. The History entry
and the SessionMetric are saved once, after ⌘V (or after the paste failed); without a paste (a response, a custom
command, a failure) before the pipeline returns.

## On Home

Home's week panel (`HomeWeekPanel`, `WeekStats`) has a **Stop to paste** card: the median `stopToPasteCommand` of
this week's dictations, in seconds. It is the time to Yap sending ⌘V, not to the text showing up in the app in front:
nothing confirms the insert, and no desktop paste success rate has been measured.

- **What counts** (`SessionMetric.isRealPaste`, `measuredPasteWait`): `source` `recorder`, a `stopSource` other than
  `file` (so not `make dictation-latency`, and not older metrics or recovered recordings, which have none),
  `pasteOutcome` `pasted`, and a `stopToPasteCommand` that is there, finite and ≥ 0. Scratchpad, clipboard-only and
  failed pastes, responses and commands don't count. New metrics come only from the dictation pipeline (meetings and
  the Transcribe Audio page don't run it); metrics the stats migration rebuilt from History have no `stopSource`, so
  they don't count either. A missing time is left out, never taken as 0.
- **Week**: Monday 00:00 to now on the dashboard calendar (this Mac's time zone). Last week is cut at the same weekday
  and time.
- **At least 5**: with fewer than 5 timed pastes the card shows how many so far and that it needs 5, no median. Only
  older dictations this week: it says they weren't timed. The change against last week, in seconds, shows only when
  both weeks have 5; otherwise the card says there isn't enough to compare.

**Time saved** (Home's tile and Insights, one formula, `DashboardTimeSaving.timeSaved`) is an estimate:
`words / 40 wpm − recording time − sum of the measured stop → ⌘V waits`, never below 0. Dictations without a measured
wait take nothing off for it; the line under the panel (and under Insights' summary) says how many of the dictations
were timed, that editing time isn't counted, and that Chinese word counts don't compare directly with an English
typing speed. Words are `WordCounter`'s: `NLTokenizer` words, so Chinese is counted in segmented words, not characters
("我们今天下午三点开会" is 5 words, 10 characters). The Chinese interface says 词 (word) for these counts, and 40 wpm is 40
词 a minute, not 40 字. Insights' snapshot cache (`dashboard-stats-snapshot.json`) went to version 3 for the new totals;
an older one is dropped and recomputed. stats.store itself is unchanged.

`make home-feedback-check` writes six fixed weeks of SessionMetrics to an in-memory store, loads each through
`WeekStatsLoader` and checks the numbers; `make ui-snapshots` renders them (`home-feedback-*`).

### A long history

`make home-feedback-perf` (`HomeFeedbackPerf`) writes 20,000 SessionMetrics over the 60 days before a fixed Thursday
to a stats.store on disk, built the way the app builds it, with the same random seed every time: 15 % from versions
before the timeline, the rest across four modes, 10 % on a fixed language and the others with detected languages
(`zh`, `en`, `en,zh`), Scratchpad, clipboard-only and failed pastes, missing stop → ⌘V times, and every kind of edit
outcome including none and incomplete ones. Each of ROUNDS launches copies the file, opens it in a new process and
loads the week through `WeekStatsLoader` (cold), then 30 more times (warm), with a 5 ms main-thread timer measuring
the longest block. It also saves 20 late edit outcomes through `SessionEditRecorder` on the main context, and puts
the real `HomeWeekPanel` in an offscreen window to count its fetches. The week it loads is the same before and after
(1209 dictations this week, 823 pasted, 786 timed, 469 watched, a 61-day streak).

Mac16,7 (M4 Pro, 48 GB), macOS 15.1, Debug build, 2026-10-01, with the release build idle (load average 3–5 from
other work). Before is 3 launches of the 60-day fetch; after is `make home-feedback-perf ROUNDS=10` on the final code:

| | before (60 days fetched) | after |
|---|---|---|
| open the store | 8–10 ms | p50 10 ms |
| first load in a new process | 2741–2755 ms | p50 528 / p95 547 ms |
| later loads (p50 of 30) | 2720–2737 ms | p50 507 / p95 511 ms |
| main thread, longest block | 13 ms | 24 ms (opening), 14 ms (loads) |
| a late edit outcome saved on the main thread | p50 2.1–2.2 ms | p50 2.2, p95 3.5 ms |
| the mode editor's detection-time look-up | 4 ms | 3.9 ms |
| Home updated after a dictation and its outcome 300 ms later | not within 1.5 s | 1 fetch, with the outcome |

The load ran off the main thread before too, so Home didn't freeze; it was late. A SwiftData fetch costs about 0.1 ms a
row whether `propertiesToFetch` lists 3 properties or 10 (2.3 s for 20,000 rows in a standalone build, the same at
`-O`), so the 60 days were 2.7 s of work after every dictation, every Auto Learn outcome and every minute Home was
open, and the panel showed the old week for that long. The loader now fetches from last week's Monday (what the
numbers use) and asks earlier days only for a count, one day at a time while the streak lasts (`fetchCount`, ~1 ms).
What's left is this fixture's ~3,500 rows since last Monday; at 333 dictations a day it is the extreme case.

The panel waits 500 ms after the last change: a dictation and its Auto Learn outcome within that are one fetch, read
after the outcome is saved; an outcome 2 s later is a second fetch. Turning Auto Learn off fetches nothing (the card
just says new pastes aren't watched). No cache was added.

## The wait before ⌘V

`CursorPaster.pasteTiming`. The clipboard is written and read back before the wait (`ClipboardManager.setClipboard`),
so a local app that reads it on ⌘V already has the new text; upstream VoiceInk posted ⌘V right after the write, with
no wait and its recorder still on screen, until caca8c4d (May 2026). The wait counts from the clipboard write.

| Before the paste | Wait | Why |
|---|---|---|
| Remote desktop, VM or XQuartz in front (Screen Sharing, Windows App, Parallels, VMware Fusion, UTM, TeamViewer, AnyDesk, Jump Desktop, Citrix, VNC Viewer, XQuartz) | 500 ms, clipboard restored after 5 s at the earliest | these copy the clipboard to the other side asynchronously (upstream #928); XQuartz's pbproxy copies it to X11's clipboard the same way |
| Stopped with the shortcut, no Yap window key | 20 ms, then until shift, control, option and fn are up (100 ms at most) | focus never left the app in front: the recorder is a non-activating panel nobody clicked. The 20 ms is margin, not measured. A toggle-mode stop is a key press, and a modifier still held would turn ⌘V into ⇧⌘V or ⌥⌘V |
| Stopped from the recorder (record button, Finish and Send), the menu bar or anything else; a Yap window was key; History's paste; Undo and Rewrite Last Paste | 100 ms, as before | a click in Yap's windows may have taken keyboard focus; Undo and Rewrite set the selection through Accessibility first, which web views apply asynchronously |

No app was tested by pasting into it: that needs desktop automation. The shortcut case is the one dictation takes
by far most often; everything that involves Yap's own windows or Accessibility kept its wait.

## Measuring it

```bash
make dictation-latency MODEL=~/path/to/ggml-large-v3-turbo-q5_0.bin [ROUNDS=12] [LANGUAGE=auto] [CLIPS=latency]
```

`scripts/dictation-latency.sh` runs the Debug app as the mock identity (its own defaults, Application Support and
keychain, as `make offline-check`) with one mode: MODEL, LANGUAGE (auto, or a Whisper code such as `zh` or `en`), no
AI cleanup. `DictationLatencyCheck` then dictates five clips ROUNDS times each: `security`, `standup` and `perf` from
`setup/asr/clips` (Chinese with English terms, 5–8 s) and two English sentences made with `say -v Samantha` (7 s).
`CLIPS=all` dictates all eleven Chinese clips, three English sentences and four code-switched recordings (a whole
English sentence and a whole Chinese one, 0.5 s apart: three of 13–16 s, one of 7 s), and scores round 1's text per
kind: character error rate (letters, digits and CJK characters; case, spaces and punctuation ignored) and key terms
(`setup/asr/bench.py`'s `hits`). Before each dictation it loads the model
the way a press does while the user speaks and lets the recording's context capture finish; after it, the times are
read back from the SessionMetric. One untimed dictation goes first.

Every script that runs the app as the mock identity takes `/tmp/yap-mock.flock` first (`scripts/mock-lock.sh`), so
two worktrees on one Mac take turns instead of deleting each other's store.

The path after the stop is the real one (`runPipeline` → `TranscriptionPipeline` → `TranscriptionDelivery` →
`CursorPaster`), including the stop sound, the panel dismissal, the clipboard and every wait; the stop counts as a
shortcut stop (the 20 ms wait). `CursorPaster.dryRun` leaves out what touches the app in front: the check that a text
field has focus, the read of the selection the paste will replace (Undo Last Paste), and the key events. The ⌘V time
is when V would have gone down; nothing is read from or typed into the app in front, and Auto Learn and Last Paste
aren't told about it.

After the rounds the script also checks, and fails otherwise:

- every History save came after its ⌘V (`savedAfterPaste`);
- six dictations with the model released first, as After Each Dictation does: three stopped while the press's preload
  is still loading, three pressed while the release is still running. Each must load the model once (`loads`);
- a paste that fails (`CursorPaster.dryRunResult`) still leaves the dictation in History, saved to the store.

Not covered:

- **Recorder stop.** It needs the microphone, which the mock app doesn't have and shouldn't ask for. Real dictations
  record `stopToRecorderStopped`; read it from stats.store.
- **Cloud transcription.** The mock identity has no provider keys and the script doesn't borrow the dev app's.
  Yap Cloud's network latency is in [cloud-latency.md](cloud-latency.md).
- **Waits other than the shortcut one** (see the table above).
- **The focused-field check and the selection read before ⌘V.** Both run before the wait starts or during it; ⌘V
  waits for the selection read. It reads only the selected text (`AutoLearnAXTextReader.focusedSelection`), no longer
  the whole field. Real dictations include both.

## Auto-detect or a fixed language

Mac16,7 (M4 Pro, 48 GB), macOS 15.1, Debug build, Large v3 Turbo (Quantized), 2026-10-01. `make dictation-latency
CLIPS=all ROUNDS=3` with LANGUAGE auto, zh and en run back to back, three times over. Latency is the median of the three
runs' stop → ⌘V p50 (one auto run was slowed by other work on the Mac: 1501 / 1713 / 3147 ms against about 1200 /
1150 / 2735 in the other two). Accuracy is round 1's text and came out the same in all three runs.

| clips | auto | fixed Chinese (`zh`) | fixed English (`en`) |
|---|---|---|---|
| Chinese with English terms (11) | 1230 ms, CER 22.4 %, 44/82 terms | **756 ms**, 24.4 %, 45/82 | 764 ms, 34.5 %, 36/82 |
| English (3) | 1153 ms, 1.3 %, 10/10 | 715 ms, 32.3 %, 7/10 | **695 ms**, 0.3 %, 10/10 |
| Code-switched, whole sentences (4) | 2735 ms, **14.6 %**, 25/41 | 862 ms, 61.5 %, 19/41 | 825 ms, 33.9 %, 22/41 |

On M3.2's five clips (`CLIPS=latency ROUNDS=12`, two runs each): auto 1200 / 1186 ms, zh 746 / 738 ms, en 725 / 731
ms. That is 0.45 s less per dictation than auto. Against M3.1's 1343 ms it would be −45 %, but only for a user who
opts in and accepts the accuracy cost below; the default's gain is the −12 % in "Results". The language detection Yap
now records took 475–477 ms p50 in every auto run. What a fixed language saves is that pass and nothing else.

- **One main language (Chinese with English terms, or English):** fixing it is about 0.45 s faster. In English it is
  also more accurate (0.3 % character errors instead of 1.3 %). In Chinese it is not free: character errors go from
  22.4 % to 24.4 % (the zh prompt), key terms from 44 to 45 of 82, so the English terms come through about as often
  as on auto. That is what the `zh` column of the first row measures; it is not "no worse".
- **Whole sentences in both languages:** a fixed language breaks them. With `zh` the English sentence comes out as
  Chinese (61.5 % errors), with `en` the Chinese one as English (33.9 %). Auto splits a recording of 12 s or more at
  the switch and decodes each piece in its language (`LibWhisper.languagePieces`), which is why it takes 2.7 s here.
- **Short code-switched recordings** (7 s, an English phrase then a Chinese sentence): auto decodes them in one
  language and drops the other half ("Sounds good. Let's ship it." with the Chinese gone), the same as a fixed `en`
  would. Not changed here.

New installs keep auto: onboarding sets the first mode to Auto-detect, and a fixed default is a product decision.
For the record, by these numbers a Chinese-locale default of `zh` would save 0.45 s per dictation for one-language
users and cost a code-switching user most of their English sentences until they change it.

### Fixing the language

`LanguagePinSuggestion`. After a dictation is pasted and saved, when the mode's language is auto and its model is local
Whisper, Yap looks at that mode's last 20 dictations with a recorded language (`SessionMetric.modeID`,
`detectedLanguages`). It suggests fixing the language once, in a notification (15 s), when:

- all 20 were decoded in one language and nothing else (an `en,zh` dictation counts against it);
- that language is one the model can be set to;
- none of their transcripts in History holds a whole sentence in another script: four or more words without CJK in a
  Chinese, Japanese or Korean dictation, or four or more CJK characters in another. Terms and short phrases don't
  count; a dictation deleted from History counts against it;
- the mode hasn't said No Thanks, and no other notification is on screen (then the next dictation asks).

The text gives this Mac's own number: the median detection time of those 20 dictations, rounded to 0.1 s, and the
cost: whole sentences in another language, or switching languages mid-dictation, may come out wrong, and the mode can
go back to Auto-detect at any time. It no longer says English terms are still recognized: the terms held up, but the
character errors didn't.

- **Set to Chinese** fixes the mode's language, as the menu bar's language menu does. A confirmation follows with
  **Back to Auto-detect**, which puts auto back and stops the suggestion for that mode.
- **No Thanks** stops it for that mode. Either is stored per mode on this Mac (UserDefaults
  `LanguagePinSuggestionDeclinedModes`), not in config.json, so it doesn't sync.
- **Ignored:** it is asked again only after 20 more dictations (`LanguagePinSuggestionShownAt`).

Why 20: the code-switched clips above show what a mixed speaker's dictations look like to the rule. Every recording
long enough to split records two languages, and a short one in the other language records that language. Either one
ends the run of 20. Someone who switches whole sentences in one dictation out of ten gets 20 clean ones in a row 12 %
of the time, in one out of five 1 %. A one-language user sees the suggestion after about a day of dictating, having
waited about 9 s for detection by then.

Cloud models, Parakeet, Apple Speech, meetings, imported files and the live preview never record a language, so they
never trigger it.

In the mode's settings, under the language picker while it is on Auto-detect with a local Whisper model: "On this
Mac, Auto-detect adds about 0.5 s to every dictation with this model. A fixed language skips that, but whole
sentences in another language, or switching languages mid-dictation, may come out wrong. You can switch back any
time." The number is the median of this Mac's last 20 recorded detections with that model. Before there are any, the
line says the same without a number. Cloud and Parakeet modes don't show it.

## Results

Mac16,7 (M4 Pro, 48 GB), macOS 15.1, Debug build, language auto, 2026-09-30. Before is main at 39d1c150 (M3.1), after
is this change; the two were run alternately, each pair of runs back to back.

| model | rounds × clips | before p50 / p95 ms | after p50 / p95 ms | p50 |
|---|---|---|---|---|
| Large v3 Turbo (Quantized) `ggml-large-v3-turbo-q5_0.bin` | 12 × 5 | 1343 / 1383 | 1181 / 1231 | −12.1 % |
| same, second pair | 12 × 5 | 1344 / 1382 | 1184 / 1220 | −11.9 % |
| Base (Quantized) `ggml-base-q5_1.bin` | 24 × 5 | 393 / 423 | 225 / 255 | −42.7 % |
| same, second pair | 24 × 5 | 394 / 424 | 225 / 254 | −42.9 % |

One more Turbo pair, run before these, gave 1348 → 1223 with an after p95 of 1586: something else on the Mac slowed
some decodes in that run (its decode step p95 was 1550 against 1195 in the others).

With the model released before the press and the stop coming while it still loads, the dictation waits for that
load (`stopToModelReady` 43–85 ms in the released-model dictations of "Measuring it") and ⌘V comes at 1.20–1.34 s.

Turbo by step (second pair, p50 ms):

| step | before | after |
|---|---|---|
| → transcribed (reads the WAV, decodes) | 1183 | 1146 |
| → filters and replacements done | 2 | 2 |
| → ⌘V (sound, panel, clipboard, waits) | 158 | 35 |

Transcripts didn't change: every dictation in every run had the same text before and after (5 clips' text compared,
character counts of all 60 and 120), and nothing in the decode was changed (see below). Every paste was `pasted`.

### What changed (Turbo, p50 ms saved, from temporary timing around each call)

| change | ms |
|---|---|
| Pre-paste wait after a shortcut stop: 100 → 20 ms (table above) | ~80 |
| The paste is prepared (checks, clipboard, Undo's selection read) when it is started, and the wait counts from the clipboard write, so main-thread work queued before the paste task (session cleanup, model release) runs inside the wait | ~17 |
| History save, SessionMetric and the second audio-duration read after ⌘V | ~25 |
| The recording context snapshot is read only when AI cleanup can run | ~11 |
| Stop → decode start: the loaded context is read from a lock-protected snapshot and dictionary words through the service's own ModelContext, instead of three waits for the main thread, which is busy with the recorder and History right after the stop | 47 → 8 |
| The WAV is converted with vDSP through a lookup table: 8 ms → 0.5 ms, the same floats (selfCheck compares all 65,536 values; vDSP's own division differs in the last bit) | (in the line above) |

Also changed, not visible in these numbers:

- **One model load per press.** Main already waited for the press's preload (`finishPendingLoad`, since #102; the
  M3.1 note about a second copy predates it). What remained: a transcription that found the model missing loaded a
  private copy, freed after the dictation and invisible to the live preview. That happened when the press came while
  the last dictation's release was still running (the preload saw the old context and skipped), or when the mode
  wanted a different model than the one preloaded (two models in memory). Now every load goes through
  `WhisperModelManager.context(forModelNamed:)`: a load in flight is waited for, a different model is released
  first, and the release clears the context before freeing it. The warmup after a download keeps a context of its
  own. `WhisperModelManager.selfCheck` and the six released-model dictations above cover it; with the old release
  order the selfCheck traps.
- **Undo Last Paste's selection read** reads only the selection, not up to 100,000 characters of the field.

### Where the 1.18 s goes now

Turbo, language auto, p50 ms, from temporary timing around each call:

| block | ms |
|---|---|
| stop → decode starts (pipeline, silence check, WAV read) | 8 |
| VAD (Silero) | 18 |
| language detection: one full encoder pass | 476 |
| decode (`whisper_full`: another encoder pass and the tokens) | 647 |
| filters, replacements | 5 |
| → ⌘V: 20 ms wait, ⌘ down → V down 10 ms, timer slack | 36 |

1141 of 1184 ms is whisper.cpp. Even with everything else at zero the total would be 15 % under M3.1's 1343, short of
20 %; reaching 20 % (≤ 1074 ms) needs the decode itself to get shorter. What was tried there, all on the 11 clips of
`setup/asr` (82 key terms) plus the two English clips, with the app's `LibWhisper.swift` through `whisperbench`:

| decode setting | 5 latency clips, decode time (sum, ms) | CER, auto (13 clips) | CER, zh (11 clips) | key terms auto / zh | transcripts changed (of 24) |
|---|---|---|---|---|---|
| as shipped: temperature 0.2, best_of 5, 8 threads | 5471 | 17.6 % | 24.4 % | 45 / 45 | – |
| temperature 0 (fallback +0.2 kept) | 5504 | 17.0 % | 23.3 % | 46 / 45 | 12 |
| best_of 1 | 5325 | 18.3 % | 25.0 % | 46 / 44 | 15 |
| 4 threads | 6486 | 17.6 % | 24.4 % | 45 / 45 | 0 |
| 12 threads | 6132 | 17.6 % | 24.4 % | 45 / 45 | 0 |
| `no_timestamps` | 5446 | 18.7 % | 23.0 % | 45 / 46 | 13 |
| `single_segment` | 5509 | 17.6 % | 24.4 % | 45 / 45 | 0 |
| `audio_ctx` = audio length + 64 frames | 3890 | 71.3 % | 44.6 % | 4 / 30 | 24 |
| language detection with `audio_ctx` = audio length (+64) | 3623 | 41.2 % (40.1 %) | 24.4 % | 39 / 45 (40 / 45) | 9 |

None was kept. The thread count is already the fastest. temperature 0 is no faster with language auto and changes
half the transcripts (better on the whole, worse on two clips); best_of 1 saves 3 % and gets worse. A shorter
encoder window is the only large saving, and it breaks Turbo: shorter decodes hallucinate, and a shorter language
detection calls 9 of the 11 Chinese clips English (p 0.6–0.94, against 0.99 zh with the full window).

Two other ways to skip the 476 ms language detection:

- **The live preview's language** (Live Text Display, on by default, detects on the first 3 s while recording). It
  agreed with the final detection on all 13 clips but not on code-switched recordings: on an English sentence
  followed by a Chinese one, and on the reverse (15.6 s each), the whole-recording detection is unsure and the window
  is split into an English and a Chinese piece, each decoded in its language; the preview's language (from the first
  3 s) would decode the whole recording as one. Not kept: it changes exactly the transcripts this app is for.
- **Reusing the detection's encoder pass for the decode.** whisper.cpp's `whisper_full` always encodes again; skipping
  that needs a whisper.cpp change, and the framework is built from upstream whisper.cpp head (`make whisper`), cached
  in CI under a key in `.github/`.

What would make the decode itself shorter, as M3.2 found it:

- **A language in the mode.** With Chinese (or English) set instead of auto there is no detection pass: about 0.45 s
  less per dictation. Yap now suggests it to users whose dictations are all in one language, and the mode's language
  picker says what auto costs; see "Auto-detect or a fixed language" above.
- **Large v3 Turbo unquantized** (1.6 GB against 547 MB): p50 0.60 s against 0.66 s on the bench with language zh,
  46 against 45 key terms. It also has a Core ML encoder, which wasn't measured.

## M3.1 numbers (main as of 1.11.0, before the changes above)

Same Mac, Large v3 Turbo (Quantized), 12 rounds × 5 clips, 2026-09-30:

| step | n | p50 ms | p95 ms |
|---|---|---|---|
| stop → transcribed (checks and reads the WAV, decodes) | 60 | 1178 | 1223 |
| → filters and replacements done | 60 | 2 | 3 |
| → ⌘V (sound, panel, clipboard, waits) | 60 | 158 | 163 |
| **total, stop → ⌘V** | 60 | 1337 | 1381 |
| Chinese clips | 36 | 1361 | 1392 |
| English clips | 24 | 1306 | 1317 |

A Debug build with Swift optimization on (`-O`, whole module) gave the same total as the plain Debug build run just
before it (p50 1326 ms against 1330 ms); the decode runs in the prebuilt whisper.cpp framework either way.

With Base (Quantized) `ggml-base-q5_1.bin`, one round, the total p50 was 369 ms, 148 ms of it from the processed
text to ⌘V. Split with temporary timing (30 dictations, p50) the Turbo total was 1130 ms decode (85 %), 117 ms of
waits before ⌘V (9 %) and 77 ms of code path (6 %): 25 ms to the Whisper service reading the WAV, 15 ms of paste
task waiting behind the save, 10 ms reading the audio duration again, 9 ms for the context snapshot, 18 ms WAV read,
silence check and filters. All of these are addressed above.
