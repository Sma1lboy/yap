# 转写 bench：把 clips/ 里 11 段中英混说音频交给一个转写引擎，按 cases.json 的 82 个关键词打分。
# 用法:
#   python3 bench.py run whisper <ggml-*.bin>      需要 WHISPER_CLI（whisper.cpp 的 whisper-cli）
#   python3 bench.py run tcpp <*.gguf> [itn]        需要 TCPP_BENCH（harness/ 里的 tcppbench）
#   python3 bench.py run nemotron <model dir>       需要 FLUID_BENCH（harness/ 里的 fluidbench）
#   python3 bench.py run openrouter <model>         读 ~/.env 的 OPENROUTER_API_KEY
#   python3 bench.py score                          汇总 results/*.jsonl
# 语言统一用 zh（中英混说的用户会选中文）；whisper 带上 app 对 zh 的默认 prompt。
import base64, glob, json, os, re, subprocess, sys, tempfile, time, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
CASES = json.load(open(os.path.join(HERE, "cases.json")))
WHISPER_ZH_PROMPT = "你好，最近好吗？见到你很高兴。"  # VoiceInk/.../WhisperPrompt.swift


def wavs():
    """16 kHz mono WAV of every clip, in a temp dir; returns [(case, path, seconds)]."""
    out = tempfile.mkdtemp(prefix="yap-asr-")
    rows = []
    for c in CASES:
        src, dst = os.path.join(HERE, "clips", c["id"] + ".m4a"), os.path.join(out, c["id"] + ".wav")
        subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", src, dst], check=True)
        secs = (os.path.getsize(dst) - 44) / 32000  # 16-bit mono 16 kHz, 44-byte header (afconvert may pad; close enough)
        rows.append((c, dst, secs))
    return rows


def run_whisper(model, clips):
    cli = os.environ["WHISPER_CLI"]
    threads = str(max(1, min(8, os.cpu_count() - 2)))  # LibWhisper.swift
    for c, wav, _ in clips:
        p = subprocess.run([cli, "-m", model, "-l", "zh", "--prompt", WHISPER_ZH_PROMPT, "-t", threads,
                            "-tp", "0.2", "-nt", "-f", wav], capture_output=True, text=True, check=True)
        ms = lambda k: float(re.search(k + r" time =\s*([\d.]+) ms", p.stderr).group(1)) / 1000
        yield c, p.stdout.strip(), ms("total") - ms("load"), ms("load")


def run_json_lines(cmd, clips):
    """Programs that load once, then print {file, text, secs} per clip; load time on stderr as 'load <secs>'."""
    p = subprocess.run(cmd + [w for _, w, _ in clips], capture_output=True, text=True)
    rows = {json.loads(l)["file"]: json.loads(l) for l in p.stdout.splitlines() if l.startswith("{")}
    load = float(re.search(r"^load ([\d.]+)", p.stderr, re.M).group(1))
    for c, wav, _ in clips:
        yield c, rows[wav]["text"], rows[wav]["secs"], load


def run_openrouter(model, clips):
    key = next(l.split("=", 1)[1].strip().strip('"') for l in open(os.path.expanduser("~/.env"))
               if l.startswith("OPENROUTER_API_KEY="))
    for c, wav, _ in clips:
        body = {"model": model, "input_audio": {"data": base64.b64encode(open(wav, "rb").read()).decode(), "format": "wav"}}
        req = urllib.request.Request("https://openrouter.ai/api/v1/audio/transcriptions", json.dumps(body).encode(),
                                     {"Authorization": f"Bearer {key}", "Content-Type": "application/json"})
        t = time.time()
        text = json.load(urllib.request.urlopen(req, timeout=60))["text"]
        yield c, text.strip(), time.time() - t, 0.0


def hits(case, text):
    """A keyword counts when any spelling appears as whole words; case, spaces/hyphens/dots and a plural s don't matter."""
    def pattern(alt):
        chars = [re.escape(ch) for ch in re.sub(r"[\s\-_.]", "", alt.lower())]
        return r"(?<![a-z0-9])" + r"[\s\-_.]?".join(chars) + r"s?(?![a-z0-9])"
    t = text.lower()
    return [any(re.search(pattern(alt), t) for alt in kw) for kw in case["keywords"]]


def score():
    print(f"{'model':42} {'hits':>6} {'RTF':>6} {'p50 s':>6} {'load s':>7}")
    for f in sorted(glob.glob(os.path.join(HERE, "results", "*.jsonl"))):
        rows = [json.loads(l) for l in open(f)]
        by_id = {c["id"]: c for c in CASES}
        n = sum(sum(hits(by_id[r["id"]], r["text"])) for r in rows)
        total = sum(len(by_id[r["id"]]["keywords"]) for r in rows)
        rtf = sum(r["secs"] for r in rows) / sum(r["audio"] for r in rows)
        p50 = sorted(r["secs"] for r in rows)[len(rows) // 2]
        print(f"{os.path.basename(f)[:-6]:42} {n:>3}/{total:<2} {rtf:>6.3f} {p50:>6.2f} {rows[0]['load']:>7.2f}")


def main():
    if sys.argv[1:2] == ["score"]:
        return score()
    engine, model, *rest = sys.argv[2:]
    clips = wavs()
    audio = {c["id"]: s for c, _, s in clips}
    if engine == "whisper":
        rows = run_whisper(model, clips)
    elif engine == "tcpp":
        rows = run_json_lines([os.environ["TCPP_BENCH"], model, "zh", rest[0] if rest else "0"], clips)
    elif engine == "nemotron":
        rows = run_json_lines([os.environ["FLUID_BENCH"], model, "zh-CN"], clips)
    else:
        rows = run_openrouter(model, clips)
    name = "nemotron-multilingual" if engine == "nemotron" else f"{engine}-{os.path.basename(model).replace('/', '_')}"
    os.makedirs(os.path.join(HERE, "results"), exist_ok=True)
    with open(os.path.join(HERE, "results", name + ".jsonl"), "w") as out:
        for c, text, secs, load in rows:
            h = hits(c, text)
            print(f"[{c['id']}] {sum(h)}/{len(h)} {secs:.2f}s  {text}")
            out.write(json.dumps({"id": c["id"], "text": text, "secs": secs, "load": load, "audio": audio[c["id"]]},
                                 ensure_ascii=False) + "\n")


if __name__ == "__main__":
    assert hits({"keywords": [["GitHub Actions"], ["CI"], ["layer"]]}, "改 github-actions 的 decision，layers 顺序") == [True, False, True]
    main()
