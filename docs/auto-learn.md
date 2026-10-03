# Auto Learn: what it reads and what it doesn't

Auto Learn (Settings → Dictionary, on by default) notices when you correct a word Yap pasted and proposes a
replacement or vocabulary entry. It works through macOS Accessibility only: no keyboard event tap, no Input
Monitoring, no screen capture.

## What it reads

After a dictation is pasted with ⌘V (`CursorPaster` → `AutoLearnService.pasteDidFinish`):

1. 120 ms later, in the app the text was pasted into (never Yap itself), it looks at the focused element: the app's
   focused element and the system-wide one if it belongs to the same app (`AutoLearnAXTextReader.focusedText`).
2. Before reading any value it checks what each element says about itself (role, subrole, character count) and stops
   if the field must not be read; see below.
3. Otherwise it reads that editable field's text, up to 100,000 UTF-16 characters, and the selection, to find where
   the pasted text landed. In Chromium and Electron apps it turns on `AXManualAccessibility` for the read and puts the
   previous value back afterwards.
4. It reads the same field once more when focus leaves it, when the next recording starts, or after 60 s, whichever
   comes first. The same checks run again first.
5. It compares only the pasted span. A changed word or phrase (up to 256 characters each side) becomes a candidate
   pair, "what Yap pasted" → "what you changed it to", queued in `auto-learn-pending-corrections.json` in Yap's
   Application Support folder. The rest of the field's text is kept in memory only between steps 3 and 5 and is never
   written anywhere.
6. The candidate pairs, and nothing else from the field, go to the AI provider of your cleanup settings for review.
   With Review set to Manually they wait until you press Review Now.

## What it never reads

The field is refused, with nothing read from it, when:

| Reason (`AutoLearnUnobservableReason`) | How it's detected |
|---|---|
| `secureInput` | Secure keyboard entry is on (`IsSecureEventInputEnabled`). macOS turns it on while any password field has focus; Terminal's Secure Keyboard Entry and some password managers turn it on too, so Auto Learn also skips pastes made while one of those is active. |
| `secureField` | The focused element's role or subrole is `AXSecureTextField`. Native `NSSecureTextField` and password inputs in Safari, Chrome and Electron report it. It's the only secure or protected marker in the macOS SDK's Accessibility headers. |
| `fieldTooLong` | The element reports more than 100,000 characters (`AXNumberOfCharacters`). |

Paste-side rejections are counted the same way: `accessibilityNotTrusted`, `targetIsYap`, `emptyPaste`,
`pasteTooLong` (over 12,000 characters), `noReadableField` (no editable focused field, or the final read got no
value), `pastedTextNotFound` (the pasted text isn't where the paste should have put it, or at the end the text around
it no longer locates it), `fieldCleared` (the field was empty at the end) and `autoSent` (Finish and Send's key went
out right after the paste; counted only once its target check passed, see dictation-latency.md, "Where the paste goes").

For each refusal Yap keeps only a count per reason, in the `AutoLearnUnobservableCounts` user default, on this Mac.
No text, app name or window title is stored or logged with it.

Text Around the Cursor (cleanup context) and Undo / Rewrite Last Paste read the focused field through the same
reader, so the same refusals apply to them (without the counts). While secure keyboard entry is on anywhere, cleanup
gets no text around the cursor, and Undo / Rewrite Last Paste can't find the last paste and say so.

## Correction rate

For every dictation it pastes with ⌘V, Auto Learn records on that dictation's `SessionMetric` how much of the pasted
text you changed before the watch ended (focus left the field, the next recording started, or 60 s passed):

| Field | Value |
|---|---|
| `editObserved` | `true`: Auto Learn read the field at the end and found the pasted text. `false`: it couldn't. |
| `editUnobservableReason` | When `false`: one of the reasons above (`secureField`, `noReadableField`, `fieldCleared`…). |
| `editDistance` | When `true`: 0 untouched … 1 deleted or rewritten. |
| `editChanged` | When `true`: `editDistance > 0`. |

All four stay nil when Auto Learn didn't watch: it's off, the text wasn't pasted with ⌘V (Scratchpad, clipboard only,
a failed paste, the clipboard changed before ⌘V,
a response), or the next dictation started within 120 ms of the paste. Turning Auto Learn off turns this off too:
the correction rate needs the same reads of the field, and Yap doesn't read it for anything else.

**Distance** (`AutoLearnEditMeasure`, `FinalSnapshotDiffEngine.observe`):

- The pasted text and what's now between the text that was right before and right after it are split into units:
  each Chinese, Japanese, Korean, Thai, Lao, Myanmar or Khmer character; each word (letters and digits, with `'`, `-`
  or `_` inside); each other character such as punctuation. Whitespace isn't a unit, so spacing-only edits count as
  untouched. Line endings, non-breaking and zero-width spaces are normalized first.
- `editDistance = levenshtein(units before, units after) / max(count before, count after)`: insertions, deletions and
  substitutions of a unit cost 1 each. Changing one word of a 7-word sentence is 1/7 ≈ 0.14, one character of an
  11-character Chinese sentence is 1/11 ≈ 0.09.
- When the part that differs (after the common start and end) is over 4,000,000 unit pairs, the edit count is taken as
  the longer side's unit count instead of computed, which reads as a full rewrite.

**Edge cases:**

| What happened in the field | Recorded |
|---|---|
| Nothing changed before focus left | observed, distance 0 |
| Text typed before or after the pasted text, which is still there unchanged | observed, distance 0 |
| The pasted text deleted, the text around it kept | observed, distance 1 |
| The whole field emptied | not observed, `fieldCleared`: chat apps empty the field when you send, so a send can't be told from a deletion |
| The text around the paste changed too, so the paste can't be located | not observed, `pastedTextNotFound` |
| Edits after focus left the field | not seen: the field is read once, when focus leaves, and the first outcome recorded for a dictation stands |

`make edit-rate-check` prints the outcome for each of these on fixed text and runs the self-checks.

**Where it's stored and who sees it.** Only in `stats.store` in Yap's Application Support folder, on this Mac. That
store is never synced (no CloudKit), not part of exports or Yap Cloud config sync, and `yap-mcp` doesn't read it. No
text is stored with it, only the numbers and the reason. Home shows part of it ("On Home" below), read from that
store on this Mac; nothing new is stored for it.

The correction rate is then, over pasted dictations: the share with `editObserved == false` (couldn't be watched),
and among the rest, the share with `editChanged == true` and the mean `editDistance`.

### On Home

Home's week panel has an **Unchanged after paste** card (`WeekStats`, `WeekPastes`). It is not an accuracy score and
doesn't say dictations need no editing: it only counts what Auto Learn saw in the field for up to 60 s after the
paste, until focus left it. An edit after that isn't seen.

- **Denominator**: this week's real ⌘V pastes (the same filter as the Stop to paste card,
  [dictation-latency.md](dictation-latency.md#on-home)) with `editObserved == true` and a complete result:
  `editChanged` and `editDistance` both set, the distance finite and in 0…1, and `editChanged == (editDistance > 0)`.
- **Numerator**: of those, `editChanged == false`.
- **Not counted either way**: nil (Auto Learn off, an older metric, the next dictation within 120 ms), every
  `editObserved == false` reason (`fieldCleared`, which can be a chat app sending; `autoSent`; `pastedTextNotFound`;
  `secureField`; …) and incomplete results. A paste rewritten by typing new text after a send within 60 s can count
  as changed; that's a known limit.
- **Coverage**, on its own line: watched / real ⌘V pastes this week.
- **At least 5** watched pastes before a share; fewer shows how many so far. The change against last week (cut at the
  same weekday and time) is in percentage points, and only when both weeks have 5.
- **Auto Learn off**: Home says new pastes aren't watched, and doesn't ask to turn it on. Nothing new reads the
  field: the card only reads stats.store.

A late outcome (up to 60 s after the paste) is saved on the metric and then posts `sessionEditOutcomeDidChange`, so
Home reloads without waiting for its 60 s refresh. `make home-feedback-check` covers the filter and the boundaries;
`make home-feedback-perf` checks on 20,000 metrics that the reload comes after the outcome is saved, that a dictation
and its outcome within 500 ms are one fetch, and that turning Auto Learn off fetches nothing
([dictation-latency.md](dictation-latency.md#a-long-history)).

## Recently Learned

When Auto Learn adds rules, the notification names them: one rule as before, several as the first two (three when
there are three) and how many more. Undo in the notification takes back the whole batch.

Dictionary › Recently Learned lists what Auto Learn added in the last 7 days (50 at most), newest first, with the edit
each came from (the candidate pair it reviewed: the changed words and up to three words either side, before → after)
and when. Undo removes just what Auto Learn added: the learned source from its replacement (the replacement itself
if that was its only source) and the vocabulary word it created. A rule you removed from the dictionary yourself
isn't listed.

The list is kept in `auto-learn-recently-learned.json` in Yap's Application Support folder, on this Mac only, and
entries drop out after 7 days. Those before → after snippets are the same text that was already queued in
`auto-learn-pending-corrections.json` and sent for review.
