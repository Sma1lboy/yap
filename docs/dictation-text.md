# What happens to dictated text before AI cleanup

After the model returns its text, a dictation goes through four rule-based steps and two checks, in this order
(`DictationText.clean` and `DictationText.finish`, called from `TranscriptionPipeline`). No model is involved. AI
cleanup, when the mode turns it on, runs after all of them.

1. **Output filter** (`TranscriptionOutputFilter.filter`). Takes out what a model writes in place of speech, and the
   filler words under AI Models › Model Settings › Remove Filler Words (uh, um, hmm… by default).
2. **Chinese cleanup** (`ChineseCleanup.apply`). Each part is its own switch: 嗯/呃 and a leading 那个 removed, spoken
   换行/新段落 become line breaks, Traditional → Simplified, an optional space between Chinese and Latin letters or
   digits.
3. Then the whole transcript is checked against known hallucinations ("Thank you for watching", 字幕由…提供); a match
   is reported as no speech. The text is trimmed and trigger words pick the mode.
4. **Paragraphs** (`ParagraphFormatter.format`), when the mode has paragraph formatting on: long text is split into
   paragraphs of up to four sentences or about 50 words.
5. **Replacement rules** from the Dictionary, longest first; rules for spaced languages match whole words, with `/`,
   `.` and other punctuation counting as word edges.

Imported audio files and meeting segments go through the output filter too (not Chinese cleanup).

## What is kept

Text the user said stays as recognized:

- Paths and names that start with punctuation: `./scripts/build.sh`, `../src/main.swift`, `.env`,
  `.github/workflows/ci.yml`, `:wq`, at the start of the text, of a line, or after a spoken 换行.
- Flags (`--amend`, `-v`), calls (`foo.bar(userId)`, `console.log("hi")`), indexes (`items[0]`, `map[key]`), JSON,
  inline tags (`用 <b>粗体</b> 表示`), generics (`Map<String, Int>`), `yyyy-mm-dd`, Markdown links
  (`[the docs](https://…)`) and task boxes (`- [x] done`).
- Asides in brackets inside a sentence: 我明天(周三)有空, "The meeting (with Bob) is at 3pm.", 我觉得(笑)可以.
- Line breaks. Runs of spaces become one space; three or more line breaks become one blank line. Paragraph formatting
  splits each line on its own and keeps the breaks between them.

## What is taken out

- Two or more letters in square brackets, wherever they are, unless attached to the word before or followed by `(`
  (a link): `[Music]`, `[BLANK_AUDIO]`, `Hello [inaudible] world`.
- A parenthesized or braced annotation, or a `<tag>…</tag>` block on one line, on a line of its own or as the whole
  transcript: `(upbeat music)`, a `(laughs)` line between two sentences, `<div>hello</div>` alone. The line goes with
  it.
- Filler words as words of their own (`um, so…`), not inside another token (the `mm` in `yyyy-mm-dd`).
- Punctuation left at the start of the text or a line with nothing attached: `。。好的` → 好的, `...` → empty.

## Changed in M6.2

Before, the output filter removed everything in `()`, `[]` and `{}` and every `<tag>…</tag>` block, and collapsed line
breaks into spaces; Chinese cleanup removed any punctuation at the start of a line; paragraph formatting joined lines.
`foo.bar(userId)` came out as `foo.bar`, `./build.sh` as `/build.sh`, a JSON object as nothing. The rule now is
by shape and position, not a list of identifiers. Intended changes: an annotation in parentheses inside a sentence,
such as `(laughs) So anyway` or 我觉得(笑)可以, now stays (a stray annotation can be deleted, a lost word can't be
recovered); a tag block spanning several lines is no longer removed. Imported audio files and meeting segments get the
same filter, so an inline `(laughs)` in a meeting transcript now stays too.

## Checking it

`make text-fidelity-check` runs these same functions on 65 fixed inputs (no model, recording, clipboard or text field;
mock identity under the mock lock), prints every step's output per case, and compares the final text with
`scripts/text-fidelity-check.py`. It also runs the self-checks of the output filter, Chinese cleanup, paragraph
formatter and replacement text. This says what the rules do to text that's already recognized; it says nothing about
how well a model recognizes speech or how AI cleanup rewrites it.
