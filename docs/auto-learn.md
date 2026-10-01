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
`pasteTooLong` (over 12,000 characters), `noReadableField` (no editable focused field), `pastedTextNotFound` (the
pasted text isn't where the paste should have put it).

For each refusal Yap keeps only a count per reason, in the `AutoLearnUnobservableCounts` user default, on this Mac.
No text, app name or window title is stored or logged with it. The counts are the denominator for a later correction
rate: of all pastes, how many could be observed at all.

Text Around the Cursor (cleanup context) and Undo / Rewrite Last Paste read the focused field through the same
reader, so the same refusals apply to them.
