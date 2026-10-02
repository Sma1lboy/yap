#!/usr/bin/env python3
"""Run by scripts/text-fidelity-check.sh: <app output>. Each `text-check: {json}` line holds one case
(TextFidelityCheck.swift) with the output of every step: filter, chineseCleanup, paragraphs (when the case turns
paragraphs on), replacements, and the final output. Prints every case step by step, then which ones differ from what
they should give and the first step that differs from the input it should have kept.

The contract (docs/dictation-text.md):
- Recognized text is the user's: the steps don't remove characters that belong to it. Paths (./, ../, dotfiles),
  flags, calls, indexes, JSON, tags and asides in brackets stay as recognized.
- Noise annotations a model writes in place of speech go: a word or words in square brackets ([Music],
  [BLANK_AUDIO], [inaudible]) wherever they are, a parenthesized or braced annotation or tag block on a line of its
  own, and the whole transcript when it's a known hallucination (the pipeline then reports silence).
- Spacing: runs of spaces become one; line breaks stay, three or more become a blank line.
- What the user turned on applies as set: filler words (English list, Chinese 嗯/呃/…), spoken line breaks,
  Traditional → Simplified, spaces between Chinese and Latin, paragraphs, replacement rules (longest first,
  word-bounded for spaced languages).
"""
import json
import sys

# Each case: the final output; optional per-step expectations ("filter", "chineseCleanup", "paragraphs") so a
# failure says which step broke the text; "hallucination" for the whole-transcript check.
EXPECTED = {
    # Paths, dotfiles, flags: kept wherever they are (alone, mid-sentence, after a line break).
    "path-dot": {"filter": "./scripts/build.sh", "output": "./scripts/build.sh"},
    "path-dotdot": {"filter": "../src/main.swift", "output": "../src/main.swift"},
    "paths-in-chinese": {"output": "运行 ./scripts/build.sh 然后看 ../src/main.swift"},
    "path-after-spoken-line-break": {"output": "先运行\n./configure --prefix=/usr/local"},
    "path-on-second-line": {"output": "Steps:\n../build/run.sh"},
    "dotfile": {"output": ".env"},
    "dotfile-dir": {"output": ".github/workflows/ci.yml"},
    "dotfile-in-chinese": {"output": "打开 .gitignore 文件"},
    "vim-command": {"output": ":wq"},
    "flag": {"output": "--flag"},
    "git-flags": {"output": "git commit --amend --no-edit"},
    "short-flag": {"output": "-v"},
    # Calls, indexes, JSON, tags, code.
    "call": {"filter": "foo.bar(userId)", "output": "foo.bar(userId)"},
    "call-in-chinese": {"filter": "调用 foo.bar(userId) 拿到结果", "output": "调用 foo.bar(userId) 拿到结果"},
    "call-two-args": {"filter": "f(x, y)", "output": "f(x, y)"},
    "call-string-arg": {"output": "console.log(\"hi\")"},
    "index": {"filter": "items[0]", "output": "items[0]"},
    "index-names": {"filter": "args[i] = map[key]", "output": "args[i] = map[key]"},
    "json": {"filter": "{\"name\": \"yap\", \"tags\": [1, 2]}", "output": "{\"name\": \"yap\", \"tags\": [1, 2]}"},
    "inline-tag": {"filter": "用 <b>粗体</b> 表示", "output": "用 <b>粗体</b> 表示"},
    "generic": {"output": "Map<String, Int>"},
    "code-if": {"filter": "if (a > b) { return a }", "output": "if (a > b) { return a }"},
    "date-format": {"filter": "date format yyyy-mm-dd", "output": "date format yyyy-mm-dd"},
    # Ordinary speech, brackets included.
    "mixed-prose": {"output": "我用 React 写了 3 个组件, 然后 deploy 到 Vercel."},
    "aside-chinese": {"filter": "我明天(周三)有空", "output": "我明天(周三)有空"},
    "aside-english": {"filter": "The meeting (with Bob) is at 3pm.", "output": "The meeting (with Bob) is at 3pm."},
    "aside-laugh-inline": {"output": "我觉得(笑)可以"},
    # Spacing and lines.
    "repeated-spaces": {"output": "a b c"},
    "line-break": {"output": "第一行\n第二行"},
    "paragraph-break": {"filter": "第一段。\n\n第二段。", "output": "第一段。\n\n第二段。"},
    "many-line-breaks": {"output": "a\n\nb"},
    # Noise and hallucinations: still taken out.
    "noise-music": {"output": ""},
    "noise-blank-audio": {"output": ""},
    "noise-paren-alone": {"output": ""},
    "noise-inline-square": {"output": "Hello world"},
    "noise-leading-square": {"output": "Hello there"},
    "noise-own-line": {"output": "Okay.\nSo anyway"},
    "noise-tag-alone": {"output": ""},
    "hallucination-outro": {"hallucination": True},
    "hallucination-in-sentence": {"hallucination": False, "output": "Thank you for watching the kids while I was out."},
    "orphan-punctuation": {"output": "好的"},
    "only-dots": {"output": ""},
    "english-filler": {"output": "so the plan is fine"},
    "english-filler-off": {"output": "um, so the plan is fine"},
    # Chinese cleanup options, on and off.
    "chinese-fillers": {"output": "我觉得这个方案，还行"},
    "chinese-fillers-off": {"output": "嗯，我觉得这个方案，呃，还行"},
    "spoken-line-break": {"output": "标题\n正文"},
    "spoken-line-break-off": {"output": "标题换行正文"},
    "traditional": {"output": "我们明天开会"},
    "traditional-kept": {"output": "我們明天開會"},
    # The option spaces Han from Latin letters and digits; ")" is neither, so no space after it.
    "spacing-on": {"output": "调用 foo.bar(userId)拿到 3 个结果"},
    "spacing-off": {"output": "调用foo.bar(userId)拿到3个结果"},
    # Paragraphs (a mode setting): line breaks the user dictated stay; long text is split; code kept.
    "paragraphs-keep-spoken-line-break": {"output": "第一点是速度\n第二点是成本"},
    "paragraphs-keep-line-break": {"output": "Line one.\nLine two."},
    "paragraphs-long": {"same-words": True, "paragraph-break": True},
    "paragraphs-code": {"output": "Run ./scripts/build.sh first. Then call foo.bar(userId) again."},
    # Replacement rules: applied as the user set them (existing word-boundary rule: / and . are boundaries).
    "replace-word": {"output": "deploy to Kubernetes now, not k8sctl"},
    "replace-longest-first": {"output": "Yap Cloud and Yap"},
    "replace-inside-path": {"output": "open ./API/index.ts"},
    "replace-line-break": {"output": "hello\n\nworld"},
    "replace-chinese": {"output": "我们先看一下日志"},
    "replace-to-dotfile": {"output": "打开 .env"},
    "replace-after-paragraphs": {"output": "Use Kubernetes here."},
}

STEPS = ["filter", "chineseCleanup", "paragraphs", "replacements"]

rows = {}
for line in open(sys.argv[1], encoding="utf-8"):
    if line.startswith("text-check: "):
        row = json.loads(line[len("text-check: "):])
        rows[row["case"]] = row


def show(text):
    return json.dumps(text, ensure_ascii=False)


bad = []
for case, expected in EXPECTED.items():
    row = rows.get(case)
    if row is None:
        bad.append((case, "missing"))
        continue
    print("%s" % case)
    print("  input           %s" % show(row["input"]))
    for step in STEPS:
        if step in row:
            print("  %-15s %s" % (step, show(row[step])))
    print("  hallucination   %s" % row["hallucination"])
    problems = []
    for step in ("filter", "chineseCleanup", "paragraphs"):
        if step in expected and row.get(step) != expected[step]:
            problems.append("%s: expected %s, got %s" % (step, show(expected[step]), show(row.get(step))))
    if "output" in expected and row["output"] != expected["output"]:
        # When the case should come out as it went in, the first step that changed it is the one that broke it.
        broke = next((s for s in STEPS if s in row and row[s] != row["input"]), None) \
            if expected["output"] == row["input"] else None
        problems.append("output: expected %s, got %s%s" % (
            show(expected["output"]), show(row["output"]), " (first changed by %s)" % broke if broke else ""))
    if "hallucination" in expected and row["hallucination"] != expected["hallucination"]:
        problems.append("hallucination: expected %s" % expected["hallucination"])
    if expected.get("same-words") and row["output"].split() != row["input"].split():
        problems.append("words changed")
    if expected.get("paragraph-break") and "\n\n" not in row["output"]:
        problems.append("no paragraph break")
    for p in problems:
        print("  FAIL %s" % p)
    if problems:
        bad.append((case, "; ".join(problems)))
    print()

print("text-fidelity: %d of %d cases as expected" % (len(EXPECTED) - len(bad), len(EXPECTED)))
for case, why in bad:
    print("FAIL %-36s %s" % (case, why))
sys.exit(1 if bad else 0)
