# What happens to dictated text before AI cleanup

After the model returns its text, a dictation goes through four rule-based steps and two checks, in this order
(`DictationText.clean` and `DictationText.finish`, called from `TranscriptionPipeline`). No model is involved. AI
cleanup, when the mode turns it on, runs after all of them.

1. **Output filter** (`TranscriptionOutputFilter.filter`). Takes out whisper.cpp's no-speech marker `[BLANK_AUDIO]`
   and the filler words under AI Models › Model Settings › Remove Filler Words (uh, um, hmm… by default).
2. **Chinese cleanup** (`ChineseCleanup.apply`). Each part is its own switch: 嗯/呃 and a leading 那个 removed, spoken
   换行/新段落 become line breaks, Traditional → Simplified, an optional space between Chinese and Latin letters or
   digits.
3. Then the whole transcript is checked against known hallucinations ("Thank you for watching", 字幕由…提供); a match
   is reported as no speech. The text is trimmed and trigger words pick the mode.
4. **Paragraphs** (`ParagraphFormatter.format`), when the mode has paragraph formatting on: long text is split into
   paragraphs of up to four sentences or about 50 words.
5. **Replacement rules** from the Dictionary, longest first; rules for spaced languages match whole words, with `/`,
   `.` and other punctuation counting as word edges.

Imported audio files (their text and Whisper's timed segments) and meeting segments go through the output filter too
(not Chinese cleanup).

## What is kept

Text the user said stays as recognized:

- Paths and names that start with punctuation: `./scripts/build.sh`, `../src/main.swift`, `.env`,
  `.github/workflows/ci.yml`, `:wq`, at the start of the text, of a line, or after a spoken 换行.
- Flags (`--amend`, `-v`), calls (`foo.bar(userId)`, `console.log("hi")`), indexes (`items[0]`, `map[key]`), JSON,
  inline tags (`用 <b>粗体</b> 表示`), generics (`Map<String, Int>`), `yyyy-mm-dd`, Markdown links
  (`[the docs](https://…)`) and task boxes (`- [x] done`).
- Anything in brackets: asides (我明天(周三)有空, "The meeting (with Bob) is at 3pm.", 我觉得(笑)可以), placeholders
  (`[options]`, `Use [projectName] here`, `{name}`), `(Tuesday)` alone or on its own line, `<div>hello</div>`.
- Annotations shaped like the ones Whisper can write, such as `[Music]`, `(upbeat music)` or a `(laughs)` line, stay
  too (see below).
- Line breaks. Runs of spaces become one space; three or more line breaks become one blank line. Paragraph formatting
  splits each line on its own and keeps the breaks between them.

## What is taken out

- `[BLANK_AUDIO]` anywhere, or its whole line when it stands alone there. whisper.cpp writes it for a window without
  speech, and its own example (`examples/python/whisper_processor.py`) strips it. A subtitle segment that is only the
  marker is dropped too.
- A transcript that is entirely a known hallucination (above); the dictation reports that nothing was heard. A
  recording without sound is caught before transcription (`RecordedAudioIssue`).
- Filler words as words of their own (`um, so…`), not inside another token (the `mm` in `yyyy-mm-dd`).
- Punctuation left at the start of the text or a line with nothing attached: `。。好的` → 好的, `...` → empty.

## Annotations: why brackets stay

OpenAI's Whisper tokenizer describes non-speech annotations and speaker tags it can write, such as
`( SPEAKING FOREIGN LANGUAGE )` or `[DAVID] Hey there`, but not a list of them. They use the same brackets and the same
kind of words as text a user dictates: `[Music]` and `[options]`, `(laughs)` and `(Tuesday)` look alike. Until M6.3
the filter removed words in square brackets anywhere, and words in parentheses or braces, or a tag block, on a line of
their own; that deleted placeholders, dates and markup the user said. Now nothing is removed by its shape.

What is known (checked 2026-10-02):

- **whisper.cpp**: `[BLANK_AUDIO]` is the only marker its sources name; Yap doesn't turn on `suppress_nst`, which
  would suppress brackets, `/`, `:` and `_` at decoding and damage paths and code.
- **SenseVoice** (transcribe.cpp): Yap asks for its `<|…|>` tags to be left out (`keepSpecialTags: false`).
- **Soniox** streaming: its `<fin>` end marker is dropped by the SDK.
- **ElevenLabs**: batch requests set `tag_audio_events=false`, the parameter that tags "audio events like (laughter),
  (footsteps)" (ElevenLabs' API reference). The realtime (streaming) API lists no such parameter, and its docs don't
  say whether it writes event tags.
- In the recorded benchmark outputs (`setup/asr/results`, 24 model and provider setups, 11 clips each) no bracket
  annotation, `<|…|>` tag or line break appears.

Not known: whether and how often a given model writes `[Music]`, `(laughs)` and the like in real dictation. If one
does, the annotation now stays in the text, where the user or AI cleanup can remove it.

## Where line breaks come from

Since M6.2 the filter keeps line breaks (before, two or more in a row became a space; a single one already stayed).
They come from three places:

- **The user's own**: a spoken 换行/新段落 (Chinese cleanup) or a replacement rule with `\n`.
- **Paragraph formatting**, when the mode turns it on.
- **The model's text, as returned.** No engine joins its pieces with a line break: Whisper appends segments
  as they are, FluidAudio and transcribe.cpp return or join with a space, and streaming joins committed turns with a
  space. Cloud text fields are used as returned. Deepgram, asked for paragraphs, puts them only in
  `paragraphs.transcript`, not in the `transcript` field Yap reads (Deepgram's docs). Whether Speechmatics' plain-text
  transcript or another provider's text field can hold line breaks isn't known; none of the recorded outputs above has
  one.

A meeting transcript is one `[mm:ss] Speaker: …` line per piece. A piece with a line break in its text would continue
on a line without that prefix; meeting-files-check's real Whisper run had none.

## Changed in M6.2 and M6.3

Before M6.2, the output filter removed everything in `()`, `[]` and `{}` and every `<tag>…</tag>` block, and collapsed
line breaks into spaces; Chinese cleanup removed any punctuation at the start of a line; paragraph formatting joined
lines. `foo.bar(userId)` came out as `foo.bar`, `./build.sh` as `/build.sh`, a JSON object as nothing. M6.2 kept
brackets attached to code and asides inside a sentence but still removed bracketed words by their shape; M6.3 removes
only `[BLANK_AUDIO]` (see above). Imported audio files and meeting segments get the same filter, so a `(laughs)` in a
meeting transcript now stays too.

## Checking it

`make text-fidelity-check` runs these same functions on 76 fixed inputs and an imported file's timed segments
(`AudioTranscriptionManager.cleanedSegments`); no model, recording, clipboard or text field, mock identity under the
mock lock. It prints every step's output per case and compares the final text with
`scripts/text-fidelity-check.py`. It also runs the self-checks of the output filter, Chinese cleanup, paragraph
formatter, replacement text and subtitle segments. This says what the rules do to text that's already recognized; it
says nothing about how well a model recognizes speech or how AI cleanup rewrites it.
