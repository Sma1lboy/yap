#!/usr/bin/env python3
"""Enhancement (cleanup) bench: RecommendedPrompt.md over code-switched dictation, scored automatically.

    python3 setup/bench.py run yapcloud|openrouter <model> [--rounds 3]
    python3 setup/bench.py score

Cases: cases.json (the original 9, kept comparable) and cases_extra.json (16 more: self-corrections, lists,
code identifiers, recognition errors, questions to be left unanswered, short replies). Each case's
`expect` says what a correct cleanup has:
    has       every item must appear ("a|b" = either); case-insensitive for Latin letters
    not       none may appear
    list      true = a bullet or numbered list, "numbered" = numbered, false = no list lines
    max_len   at most this many characters (short inputs must not be expanded or answered)
Every output must also avoid code fences, bold, headings and the <TRANSCRIPT> tags.

Requests are the app's: yapcloud sends YapCloud.chatBody (streamed; temperature only where supported,
lowest reasoning effort, throughput routing) with YAP_CLOUD_TOKEN, else ~/.config/yap/bench-cloud-token.
Its per-call cost is read from the account ledger by generation id. openrouter sends
OpenRouterRequestPolicy.lowLatency's body (:nitro, reasoning off, temperature 0.3) and reads usage.cost.
Results: setup/enhance-results/<engine>-<model>.jsonl, which docs/cloud-models.md quotes.
"""
import argparse, glob, json, os, re, statistics, sys, time, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
PROMPT = open(os.path.join(HERE, "..", "VoiceInk", "Resources", "RecommendedPrompt.md")).read()
CASES = json.load(open(os.path.join(HERE, "cases.json"))) + json.load(open(os.path.join(HERE, "cases_extra.json")))
ORIGINAL = {c["id"] for c in json.load(open(os.path.join(HERE, "cases.json")))}
RESULTS = os.path.join(HERE, "enhance-results")
CLOUD = os.environ.get("YAP_CLOUD_URL", "https://cloud.yap.sma1lboy.me")
LIST_LINE = re.compile(r"^\s*(?:[-•*]|\d+[.、)])\s", re.M)
NUMBERED_LINE = re.compile(r"^\s*\d+[.、)]\s", re.M)


def failures(expect, text):
    """Names of the checks `text` fails; empty = pass."""
    low = text.lower()
    found = lambda item: any(alt.lower() in low for alt in item.split("|"))
    out = [f"missing {h!r}" for h in expect.get("has", []) if not found(h)]
    out += [f"has {n!r}" for n in expect.get("not", []) if found(n)]
    want = expect.get("list")
    if want is False and LIST_LINE.search(text):
        out.append("unwanted list")
    if want is True and not LIST_LINE.search(text):
        out.append("no list")
    if want == "numbered" and len(NUMBERED_LINE.findall(text)) < 3:
        out.append("no numbered list")
    if "max_len" in expect and len(text) > expect["max_len"]:
        out.append(f"longer than {expect['max_len']}")
    if re.search(r"```|\*\*|^#|<TRANSCRIPT|</TRANSCRIPT", text, re.M):
        out.append("formatting")
    return out


def messages(text):
    return [{"role": "system", "content": PROMPT}, {"role": "user", "content": f"\n<TRANSCRIPT>\n{text}\n</TRANSCRIPT>"}]


def token():
    return os.environ.get("YAP_CLOUD_TOKEN") or open(os.path.expanduser("~/.config/yap/bench-cloud-token")).read().strip()


def cloud_get(path):
    request = urllib.request.Request(CLOUD + path, headers={"Authorization": "Bearer " + token()})
    return json.load(urllib.request.urlopen(request, timeout=30))


def yapcloud_body(model, metadata, text):
    """YapCloud.chatBody + latencyEffort (YapCloudClient.swift)."""
    supported = set(metadata.get("supported_parameters") or [])
    body = {"model": model, "messages": messages(text), "stream": True}
    provider = {"sort": "throughput", "preferred_max_latency": {"p90": 2.5}, "allow_fallbacks": True}
    if "temperature" in supported:
        body["temperature"] = 0.3
    reasoning = metadata.get("reasoning")
    if reasoning and "reasoning" in supported:
        order = ["minimal", "low", "medium", "high", "xhigh", "max"]
        effort = "none" if not reasoning.get("mandatory") else min(
            (e for e in reasoning.get("supported_efforts", []) if e in order), key=order.index, default=None)
        if effort:
            body["reasoning"] = {"effort": effort, "exclude": True}
    if supported:
        provider["require_parameters"] = True
    body["provider"] = provider
    return body


def call_yapcloud(model, metadata, text):
    request = urllib.request.Request(CLOUD + "/v1/chat/completions", json.dumps(yapcloud_body(model, metadata, text)).encode(),
                                     {"Authorization": "Bearer " + token(), "Content-Type": "application/json"})
    start = time.time()
    parts, generation = [], None
    with urllib.request.urlopen(request, timeout=60) as response:
        for raw in response:
            line = raw.decode().strip()
            if not line.startswith("data:") or line == "data: [DONE]":
                continue
            chunk = json.loads(line[5:])
            generation = generation or chunk.get("id")
            for choice in chunk.get("choices", []):
                parts.append((choice.get("delta") or {}).get("content") or "")
    return "".join(parts).strip(), time.time() - start, {"generation": generation}


def call_openrouter(model, _metadata, text):
    key = next(l.split("=", 1)[1].strip().strip('"') for l in open(os.path.expanduser("~/.env"))
               if l.startswith("OPENROUTER_API_KEY="))
    body = {"model": model + ":nitro", "temperature": 0.3, "reasoning": {"effort": "none", "exclude": True},
            "provider": {"sort": "throughput", "allow_fallbacks": True}, "messages": messages(text)}
    request = urllib.request.Request("https://openrouter.ai/api/v1/chat/completions", json.dumps(body).encode(),
                                     {"Authorization": f"Bearer {key}", "Content-Type": "application/json"})
    start = time.time()
    response = json.load(urllib.request.urlopen(request, timeout=60))
    return (response["choices"][0]["message"]["content"].strip(), time.time() - start,
            {"cost_micros": round(response.get("usage", {}).get("cost", 0) * 1e6)})


def ledger_costs(generations):
    """generation id → micros charged, from the ledger (newest first, paged)."""
    costs, before = {}, None
    while generations - costs.keys():
        page = cloud_get("/v1/ledger?limit=100" + (f"&before={before}" if before else ""))
        for entry in page["entries"]:
            generation = (entry.get("meta") or {}).get("generationId")
            if generation in generations:
                costs[generation] = -entry["amountMicros"]
        before = page.get("nextBefore")
        if not before:
            break
    return costs


def run(engine, model, rounds):
    metadata = {}
    if engine == "yapcloud":
        metadata = next((m for m in cloud_get("/v1/models")["models"] if m["id"] == model), None)
        if metadata is None:
            sys.exit(f"{model} is not on the Yap Cloud allowlist")
        balance = cloud_get("/v1/me")["balanceMicros"]
        print(f"balance before: ${balance / 1e6:.4f}")
        if balance < 200_000:
            sys.exit("balance under $0.20; stopping")
    call = call_yapcloud if engine == "yapcloud" else call_openrouter
    rows = []
    for round_number in range(1, rounds + 1):
        for case in CASES:
            try:
                text, secs, extra = call(model, metadata, case["in"])
            except Exception as error:  # a failed call is a failed case, not a crashed run
                text, secs, extra = f"ERROR {error}", 0.0, {}
            fails = failures(case["expect"], text)
            rows.append({"id": case["id"], "round": round_number, "text": text, "secs": round(secs, 3),
                         "fails": fails, **extra})
            print(f"[{round_number} {case['id']}] {secs:.2f}s {'ok' if not fails else '; '.join(fails)}", flush=True)
    if engine == "yapcloud":
        time.sleep(3)  # the ledger row can land a moment after the stream ends
        costs = ledger_costs({r["generation"] for r in rows if r.get("generation")})
        for r in rows:
            r["cost_micros"] = costs.get(r.pop("generation", None))
    os.makedirs(RESULTS, exist_ok=True)
    with open(os.path.join(RESULTS, f"{engine}-{model.replace('/', '_')}.jsonl"), "w") as out:
        for r in rows:
            out.write(json.dumps(r, ensure_ascii=False) + "\n")


def score():
    print(f"{'result':44} {'all 25 (per round)':>20} {'original 9':>12} {'p50 s':>6} {'p95 s':>6} {'cost/call':>10}")
    for f in sorted(glob.glob(os.path.join(RESULTS, "*.jsonl"))):
        expect = {c["id"]: c["expect"] for c in CASES}
        rows = [{**r, "fails": failures(expect[r["id"]], r["text"])} for r in map(json.loads, open(f))]
        rounds = sorted({r["round"] for r in rows})
        per_round = [sum(not r["fails"] for r in rows if r["round"] == n) for n in rounds]
        original = [sum(not r["fails"] for r in rows if r["round"] == n and r["id"] in ORIGINAL) for n in rounds]
        secs = sorted(r["secs"] for r in rows if not r["text"].startswith("ERROR"))
        costs = [r["cost_micros"] for r in rows if r.get("cost_micros")]
        cost = f"${statistics.mean(costs) / 1e6:.6f}" if costs else "-"
        print(f"{os.path.basename(f)[:-6]:44} {'/'.join(map(str, per_round)):>16} /{len(CASES)} "
              f"{'/'.join(map(str, original)):>9} /9 {secs[len(secs) // 2]:>6.2f} {secs[int(len(secs) * 0.95)]:>6.2f} {cost:>10}")


if __name__ == "__main__":
    assert failures({"has": ["PR", "3点|三点"], "not": ["不对"], "list": False}, "三点 PR") == []
    assert failures({"list": "numbered"}, "步骤：\n1. a\n2. b\n3. c") == []
    assert failures({"list": False}, "- a\n- b") == ["unwanted list"]
    assert failures({"max_len": 5}, "**太长了太长了**") == ["longer than 5", "formatting"]
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["run", "score"])
    parser.add_argument("engine", nargs="?", choices=["yapcloud", "openrouter"])
    parser.add_argument("model", nargs="?")
    parser.add_argument("--rounds", type=int, default=3)
    args = parser.parse_args()
    score() if args.command == "score" else run(args.engine, args.model, args.rounds)
