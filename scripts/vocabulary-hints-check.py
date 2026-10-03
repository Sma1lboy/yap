#!/usr/bin/env python3
"""What each recorded request in make vocabulary-hints-check should carry (scripts/vocabulary-hints-check.sh).

Requests that send at most 100 terms (Deepgram batch and stream, OpenRouter and Yap Cloud models that take terms, xAI)
take the most recently added words; Speechmatics takes the whole dictionary; models that ignore or reject terms
get none. Order is newest first; words added at the same moment go by spelling.

Local Whisper's initial prompt is the base prompt, a space, then the words that fit about 200 estimated tokens,
chosen in the same order and written newest last. A word too long for what's left is skipped and older ones still go.
"""
import json
import sys

OLDER = [f"A{i:03d}" for i in range(99, -1, -1)]  # newest first: A099 … A000
OVER = ["ZNewestName"] + OLDER[:99]  # A000, the oldest, is the one left out
AFTER_EDIT = ["YAnother"] + OLDER[:99]
SMALL = ["useEffect", "kubernetes", "React组件", "张三丰"]
SAME_DATE = [f"W{i:03d}" for i in range(100)]

# Words over a provider's per-word limits, newest first, then 120 short older words. What LLMkit (pinned 7cb532e)
# keeps: xAI ≤ 50 characters, first 100; AssemblyAI live ≤ 50 characters and ≤ 6 words, first 100; ElevenLabs batch
# ≤ 50 characters (ElevenLabs documents "under 50") and ≤ 5 words, first 1,000; ElevenLabs live ≤ 20 characters,
# first 50. A word over a limit is left out and the older ones still fill the count.
M50, N20, O21 = "M" * 50, "N" * 20, "O" * 21  # the newest word, 51 "L"s, is over every limit here
SIX, SEVEN = "alpha beta gamma delta epsilon zeta", "one two three four five six seven"
SHORT = [f"S{i:03d}" for i in range(119, -1, -1)]
LIMITS = {
    "xAI/": [M50, SEVEN, SIX, O21, N20] + SHORT[:95],
    "assemblyai-stream/": [M50, SIX, O21, N20] + SHORT[:96],
    "ElevenLabs/": [M50, O21, N20] + SHORT,  # under its count: the uncut control
    "elevenlabs-stream/": [N20] + SHORT[:49],
}

# Local Whisper, behind the zh base prompt (about 27 estimated tokens, leaving 173): a word costs its estimate plus one
# for the ", " before it, so A### and W### cost 3, ZNewestName 5, YAnother 4.
LOCAL_BASE = "你好，最近好吗？见到你很高兴。"
LOCAL = {
    "over-budget": [f"A{i:03d}" for i in range(44, 100)] + ["ZNewestName"],
    "after-edit": [f"A{i:03d}" for i in range(44, 100)] + ["YAnother"],
    "under-budget": SMALL[::-1],
    "same-date-forward": [f"W{i:03d}" for i in range(56, -1, -1)],
    "same-date-reverse": [f"W{i:03d}" for i in range(56, -1, -1)],
    # The two newest (900 X, 120 CJK characters) are each over the budget: skipped whole, the older two still go.
    "oversized-newest": ["useEffect", "张三丰"],
}

# Yap Cloud with the small dictionary while paygate refuses some models (400 MODEL_NOT_ALLOWED): the outcome and, per
# request in order, its model, its provider.options and its language. The one retry goes to the Recommended model,
# mai-transcribe-2, and must carry that model's terms field, never the refused model's; a model without one gets none.
MAI = "microsoft/mai-transcribe-2"
GPT4O = "openai/gpt-4o-transcribe"
QWEN = "qwen/qwen3-asr-flash-2026-02-10"
AZURE = {"azure": {"phraseList": {"phrases": SMALL}}}
OPENAI = {"openai": {"prompt": ", ".join(SMALL)}}
FALLBACK = {
    "fallback-from-gpt-4o": ("ok", [(GPT4O, OPENAI, "zh"), (MAI, AZURE, "zh")]),
    "fallback-from-qwen": ("ok", [(QWEN, None, None), (MAI, AZURE, None)]),
    # The retry is refused too: no third request, the error goes to the caller.
    "fallback-also-refused": ("error", [(GPT4O, OPENAI, None), (MAI, AZURE, None)]),
    # The Recommended model itself refused: nothing to fall back to, one request.
    "recommended-refused": ("error", [(MAI, AZURE, None)]),
}


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
    if consumer.startswith("ElevenLabs/"):
        return line["form"].get("keyterms")
    if consumer.startswith("elevenlabs-stream/"):
        return line["query"].get("keyterms")
    if consumer.startswith("assemblyai-stream/"):
        return json.loads(line["query"]["keyterms_prompt"][0]) if "keyterms_prompt" in line["query"] else None
    if consumer.startswith("Speechmatics/"):
        config = json.loads(line["form"]["config"][0])["transcription_config"]
        return [entry["content"] for entry in config.get("additional_vocab", [])] or None
    return None


def check(line):
    """(expected, actual) pairs for one line."""
    case, consumer = line["case"], line["consumer"]
    if case == "provider-limits":
        return [(next(terms for prefix, terms in LIMITS.items() if consumer.startswith(prefix)), sent(line))]
    if case.startswith("reconnect-"):
        # The same stream object, connected again after a word was added: the new connection carries it.
        return [({"reconnect-before": ["Kwyntel"], "reconnect-after": ["Zorvex", "Kwyntel"]}[case], sent(line))]
    terms = {"over-budget": OVER, "after-edit": AFTER_EDIT, "under-budget": SMALL}.get(case, SAME_DATE)
    if consumer.startswith("Speechmatics/") and case == "over-budget":
        terms = ["ZNewestName"] + OLDER  # takes the whole dictionary
    if consumer.endswith("/whisper-large-v3"):
        terms = terms[::-1]  # Whisper keeps a long prompt's tail, so the newest go last
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
    expected_lines = 9 + 1 + 3 + 2 + 4 + 2  # over-budget, after-edit, under-budget, same-date ×2, provider-limits, reconnect
    if len(lines) != expected_lines:
        print(f"FAIL expected {expected_lines} requests, got {len(lines)}")
        failures += 1
    print(f"{len(lines)} requests, {failures} failed")
    failures += check_local(path)
    failures += check_fallback(path)
    sys.exit(1 if failures else 0)


def check_local(path):
    """Local Whisper's prompts; the number that failed."""
    lines = [json.loads(raw.split(": ", 1)[1]) for raw in open(path, encoding="utf-8")
             if raw.startswith("vocabulary-hints-local: ")]
    failures = 0
    for line in lines:
        words = LOCAL.get(line["case"])
        expected = f"{LOCAL_BASE} {', '.join(words)}" if words else LOCAL_BASE
        problems = []
        if line["base"] != LOCAL_BASE:
            problems.append(f"base {line['base']!r}, expected {LOCAL_BASE!r}")
        if line["prompt"] != expected:
            problems.append(f"expected {expected[:300]!r}\n           got {line['prompt'][:300]!r}")
        sent = line["prompt"][len(LOCAL_BASE):].strip().split(", ") if line["prompt"] != LOCAL_BASE else []
        summary = f"{len(sent):3} words, first {sent[0][:20]!r}, last {sent[-1][:20]!r}" if sent else "no words"
        print(f"{'FAIL' if problems else 'ok':4} {line['case']:18} {'whisper-local':39} {summary}")
        for problem in problems:
            print(f"     {problem}")
        failures += bool(problems)
    if sorted(line["case"] for line in lines) != sorted(LOCAL):
        print(f"FAIL expected local prompts for {sorted(LOCAL)}, got {[line['case'] for line in lines]}")
        failures += 1
    print(f"{len(lines)} local prompts, {failures} failed")
    return failures


def check_fallback(path):
    """Yap Cloud's model fallback, every request; the number of cases that failed."""
    lines = [json.loads(raw.split(": ", 1)[1]) for raw in open(path, encoding="utf-8")
             if raw.startswith("vocabulary-hints-fallback: ")]
    failures = 0
    for case, (outcome, attempts) in FALLBACK.items():
        got = sorted((line for line in lines if line["case"] == case), key=lambda line: line.get("attempt", 0))
        problems = []
        if len(got) != len(attempts) or any(line.get("requests") != len(attempts) for line in got):
            problems.append(f"expected {len(attempts)} requests, got {[line.get('requests') for line in got]}")
        for line, (model, provider_options, language) in zip(got, attempts):
            body = line["json"]
            actual = (body.get("model"), body.get("provider", {}).get("options"), body.get("language"))
            if actual != (model, provider_options, language):
                problems.append(f"request {line['attempt']}: expected {json.dumps((model, provider_options, language), ensure_ascii=False)}\n"
                                f"           got {json.dumps(actual, ensure_ascii=False)}")
            if line["url"] != "cloud.yap.sma1lboy.me/v1/audio/transcriptions":
                problems.append(f"request {line['attempt']} went to {line['url']}")
            if set(body) - {"model", "input_audio", "language", "provider"}:
                problems.append(f"request {line['attempt']} has extra fields {sorted(set(body))}")
        if len({json.dumps(line["json"].get("input_audio"), sort_keys=True) for line in got}) > 1:
            problems.append("the retry's audio differs from the first request's")
        if got and (got[0]["outcome"] == "ok") != (outcome == "ok"):
            problems.append(f"outcome {got[0]['outcome']!r}, expected {outcome}")
        sent_models = " → ".join(f"{(line['json'].get('model') or '').split('/')[-1]} "
                                 f"{'+'.join(line['json'].get('provider', {}).get('options', {})) or 'no terms'}" for line in got)
        print(f"{'FAIL' if problems else 'ok':4} {case:22} yapcloud-fallback   {sent_models}; {got[0]['outcome'][:40] if got else ''}")
        for problem in problems:
            print(f"     {problem}")
        failures += bool(problems)
    if sorted({line["case"] for line in lines}) != sorted(FALLBACK):
        print(f"FAIL expected fallback cases {sorted(FALLBACK)}, got {sorted({line['case'] for line in lines})}")
        failures += 1
    print(f"{len(lines)} fallback requests, {failures} failed")
    return failures


if __name__ == "__main__":
    main(sys.argv[1])
