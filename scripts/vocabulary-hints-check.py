#!/usr/bin/env python3
"""What each recorded request in make vocabulary-hints-check should carry (scripts/vocabulary-hints-check.sh).

Requests that send at most 100 terms (Deepgram batch and stream, OpenRouter and Yap Cloud models that take terms, xAI)
take the most recently added words; Speechmatics takes the whole dictionary; models that ignore or reject terms
get none. Order is newest first; words added at the same moment go by spelling.
"""
import json
import sys

OLDER = [f"A{i:03d}" for i in range(99, -1, -1)]  # newest first: A099 … A000
OVER = ["ZNewestName"] + OLDER[:99]  # A000, the oldest, is the one left out
AFTER_EDIT = ["YAnother"] + OLDER[:99]
SMALL = ["useEffect", "kubernetes", "React组件", "张三丰"]
SAME_DATE = [f"W{i:03d}" for i in range(100)]


def options(line):
    return line["json"].get("provider", {}).get("options")


def sent(line):
    """The dictionary terms the request carried, in order; None when it has no terms field."""
    consumer = line["consumer"]
    if consumer.endswith("/nova-3"):
        return line["query"].get("keyterm")
    if consumer.endswith("/mai-transcribe-2"):
        return options(line)["azure"]["phraseList"]["phrases"] if options(line) else None
    if consumer.endswith("/gpt-4o-transcribe"):
        return options(line)["openai"]["prompt"].split(", ") if options(line) else None
    if consumer.endswith("/whisper-large-v3"):
        prompts = {options(line)[slug]["prompt"] for slug in ("groq", "deepinfra/us", "together")} if options(line) else set()
        return prompts.pop().split(", ") if len(prompts) == 1 else None
    if consumer.endswith("/gemini-3.5-transcribe"):
        return options(line)
    if consumer.startswith("xAI/"):
        return line["form"].get("keyterm")
    if consumer.startswith("Speechmatics/"):
        config = json.loads(line["form"]["config"][0])["transcription_config"]
        return [entry["content"] for entry in config.get("additional_vocab", [])] or None
    return None


def check(line):
    """(expected, actual) pairs for one line."""
    case, consumer = line["case"], line["consumer"]
    terms = {"over-budget": OVER, "after-edit": AFTER_EDIT, "under-budget": SMALL}.get(case, SAME_DATE)
    if consumer.startswith("Speechmatics/") and case == "over-budget":
        terms = ["ZNewestName"] + OLDER  # takes the whole dictionary
    if consumer.endswith("/gemini-3.5-transcribe"):
        terms = None  # answers 400 to a prompt: only the language goes
    pairs = [(terms, sent(line))]
    if consumer.endswith("/nova-3"):
        stream_en = case == "under-budget" and consumer.startswith("deepgram-stream")
        pairs += [("nova-3", line["query"]["model"][0]), ("en" if stream_en else "multi", line["query"]["language"][0])]
    if consumer == "OpenRouter/microsoft/mai-transcribe-2":
        pairs.append(("zh", line["json"].get("language")))
    if consumer.endswith("/gemini-3.5-transcribe"):
        pairs.append(("en", line["json"].get("language")))
    if consumer.startswith("Yap Cloud/"):
        pairs.append(("cloud.yap.sma1lboy.me", line["url"].split("/")[2]))
    if consumer.startswith("xAI/"):
        pairs.append((["en"], line["form"].get("language")))
    return pairs


def main(path):
    lines = [json.loads(raw.split(": ", 1)[1]) for raw in open(path, encoding="utf-8") if raw.startswith("vocabulary-hints: ")]
    failures = 0
    for line in lines:
        problems = []
        if line["requests"] < 1:
            problems.append("no request was made")
        else:
            for expected, actual in check(line):
                if expected != actual:
                    problems.append(f"expected {json.dumps(expected, ensure_ascii=False)[:300]}\n"
                                    f"           got {json.dumps(actual, ensure_ascii=False)[:300]}")
        terms = sent(line) if line["requests"] else None
        summary = "no terms"
        if isinstance(terms, list):
            newest = {"over-budget": "ZNewestName", "after-edit": "YAnother"}.get(line["case"])
            summary = f"{len(terms):3} terms, first {terms[0]!r}, last {terms[-1]!r}"
            if newest:
                summary += f"; newest {newest} {'in' if newest in terms else 'MISSING'}"
                summary += f", oldest A000 {'in' if 'A000' in terms else 'out'}"
        status = "FAIL" if problems else "ok"
        print(f"{status:4} {line['case']:18} {line['consumer']:39} {summary}")
        for problem in problems:
            print(f"     {problem}")
        failures += bool(problems)
    expected_lines = 9 + 1 + 3 + 2  # over-budget, after-edit, under-budget, two same-date orders
    if len(lines) != expected_lines:
        print(f"FAIL expected {expected_lines} requests, got {len(lines)}")
        failures += 1
    print(f"{len(lines)} requests, {failures} failed")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main(sys.argv[1])
