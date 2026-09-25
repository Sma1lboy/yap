# 用和 VoiceInk 一样的请求参数（:nitro、关推理、temperature 0.3、按吞吐量选节点）对比润色模型。
# 用法: python3 bench.py [model ...]
import json, os, sys, time, urllib.request
from concurrent.futures import ThreadPoolExecutor

KEY = next(l.split("=", 1)[1].strip().strip('"') for l in open(os.path.expanduser("~/.env")) if l.startswith("OPENROUTER_API_KEY="))
PROMPT = open(os.path.join(os.path.dirname(__file__), "prompt.md")).read()
CASES = json.load(open(os.path.join(os.path.dirname(__file__), "cases.json")))
MODELS = sys.argv[1:] or ["openai/gpt-6-luna", "openai/gpt-5.6-luna", "google/gemini-3.1-flash-lite",
                          "google/gemini-2.5-flash-lite", "deepseek/deepseek-v4-flash", "qwen/qwen3.7-flash"]

def call(model, text):
    body = {"model": model + ":nitro", "temperature": 0.3,
            "reasoning": {"effort": "none", "exclude": True},
            "provider": {"sort": "throughput", "allow_fallbacks": True},
            "messages": [{"role": "system", "content": PROMPT},
                         {"role": "user", "content": f"\n<TRANSCRIPT>\n{text}\n</TRANSCRIPT>"}]}
    req = urllib.request.Request("https://openrouter.ai/api/v1/chat/completions", json.dumps(body).encode(),
                                 {"Authorization": f"Bearer {KEY}", "Content-Type": "application/json"})
    t = time.time()
    try:
        r = json.load(urllib.request.urlopen(req, timeout=30))
        out = r["choices"][0]["message"]["content"].strip()
        cost = r.get("usage", {}).get("cost", 0)
    except Exception as e:
        out, cost = f"ERROR {getattr(e, 'read', lambda: str(e))()[:200]}", 0
    return time.time() - t, cost, out

for m in MODELS:
    with ThreadPoolExecutor(len(CASES)) as ex:
        res = list(ex.map(lambda c: call(m, c["in"]), CASES))
    lat = sorted(r[0] for r in res)
    print(f"\n######## {m}  p50={lat[len(lat)//2]:.2f}s max={lat[-1]:.2f}s  cost={sum(r[1] for r in res):.5f}")
    for c, (dt, _, out) in zip(CASES, res):
        print(f"--- [{c['id']} {dt:.2f}s]\n{out}")
