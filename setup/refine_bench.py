# Yap Refine（本地润色，MLX）跑 cases.json：和 VoiceInkRefineXPC 一样的 system prompt、temperature 0.3、关 thinking、
# 输出上限 min(max(输入 token×2, 256), 4096)。模型按 app 固定的 revision 下载到 HF_HOME。
# 用法: uvx --with mlx-lm python setup/refine_bench.py [cases.json]
import json, os, sys, time
from mlx_lm import load, generate
from mlx_lm.sample_utils import make_sampler

# VoiceInkRefineService.systemPrompt
SYS = ("Transform raw ASR input into polished text. Preserve the original meaning and tone. Handle punctuation, "
       "capitalization, and spoken formatting cues properly. Remove fillers, repetitions, false starts, and discarded "
       "self-corrections. Output only the final text.")
CASES = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "cases.json")

t = time.time()
model, tok = load("beingpax/VoiceInk-Refine-V1", revision="ad665418d3850e379e29236e66be3ddc0ac0bf04")
print(f"load {time.time() - t:.2f}s", flush=True)
for c in json.load(open(CASES)):
    prompt = tok.apply_chat_template([{"role": "system", "content": SYS}, {"role": "user", "content": c["in"]}],
                                     add_generation_prompt=True, tokenize=False, enable_thinking=False)
    limit = min(max(len(tok.encode(c["in"])) * 2, 256), 4096)
    t = time.time()
    out = generate(model, tok, prompt, max_tokens=limit, sampler=make_sampler(temp=0.3))
    print(f"--- [{c['id']} {time.time() - t:.2f}s]\nIN:  {c['in']}\nOUT: {out.strip()}", flush=True)
