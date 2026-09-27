# Yap Refine（本地润色，MLX）跑 cases.json：和 VoiceInkRefineXPC 一样的 system prompt、temperature 0.3、关 thinking、
# 输出上限 min(max(输入 token×2, 256), 4096)。模型按 app 固定的 revision 下载到 HF_HOME。
# 用法: uvx --with mlx-lm python setup/refine_bench.py [cases.json] [--rounds 3]
# 不带 cases.json 时跑 bench.py 的 25 条，结果写 enhance-results/local-yap-refine.jsonl，和云端模型一起 `bench.py score`。
import json, os, sys, time
from mlx_lm import load, generate
from mlx_lm.sample_utils import make_sampler

# VoiceInkRefineService.systemPrompt
SYS = ("Transform raw ASR input into polished text. Preserve the original meaning and tone. Handle punctuation, "
       "capitalization, and spoken formatting cues properly. Remove fillers, repetitions, false starts, and discarded "
       "self-corrections. Output only the final text.")
HERE = os.path.dirname(os.path.abspath(__file__))
args = [a for a in sys.argv[1:] if not a.startswith("--rounds")]
ROUNDS = int(sys.argv[sys.argv.index("--rounds") + 1]) if "--rounds" in sys.argv else 3
if "--rounds" in sys.argv:
    args.remove(str(ROUNDS))
CASES = (json.load(open(args[0])) if args else
         json.load(open(os.path.join(HERE, "cases.json"))) + json.load(open(os.path.join(HERE, "cases_extra.json"))))

t = time.time()
model, tok = load("beingpax/VoiceInk-Refine-V1", revision="ad665418d3850e379e29236e66be3ddc0ac0bf04")
print(f"load {time.time() - t:.2f}s", flush=True)
rows = []
for n in range(1, ROUNDS + 1):
    for c in CASES:
        prompt = tok.apply_chat_template([{"role": "system", "content": SYS}, {"role": "user", "content": c["in"]}],
                                         add_generation_prompt=True, tokenize=False, enable_thinking=False)
        limit = min(max(len(tok.encode(c["in"])) * 2, 256), 4096)
        t = time.time()
        out = generate(model, tok, prompt, max_tokens=limit, sampler=make_sampler(temp=0.3)).strip()
        secs = time.time() - t
        rows.append({"id": c["id"], "round": n, "text": out, "secs": round(secs, 3)})
        print(f"--- [{n} {c['id']} {secs:.2f}s]\nIN:  {c['in']}\nOUT: {out}", flush=True)
if not args:
    os.makedirs(os.path.join(HERE, "enhance-results"), exist_ok=True)
    with open(os.path.join(HERE, "enhance-results", "local-yap-refine.jsonl"), "w") as f:
        for r in rows:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
