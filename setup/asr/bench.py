#!/usr/bin/env python3
"""Transcription bench: 11 Chinese–English code-switched clips, 82 key terms.

    python3 setup/asr/bench.py run whisper <ggml-*.bin> [--language auto] [--vocab]
    python3 setup/asr/bench.py run tcpp <*.gguf> [--itn]
    python3 setup/asr/bench.py run nemotron <model dir>
    python3 setup/asr/bench.py run openrouter <model id>      OPENROUTER_API_KEY (env or ~/.env)
    python3 setup/asr/bench.py run yapcloud <model id>        YAP_CLOUD_TOKEN, YAP_CLOUD_URL optional
    python3 setup/asr/bench.py score                          summarises results/*.jsonl

Engines make the app's own calls. whisper runs LibWhisper.swift and WhisperChunking.swift through
harness/'s whisperbench (VAD on, like the app), tcpp and nemotron the TranscribeCpp and FluidAudio calls,
openrouter and yapcloud the app's request bodies. Build the harness once: `swift build -c release` in
harness/. Language is `zh` unless --language says otherwise (a code-switching user picks Chinese); whisper
gets the app's zh prompt, plus every key term with --vocab (a dictionary holding all of them, the best case
for the dictionary prompt).

Audio: clips/<id>.m4a, made from clips.json by make_clips.py with macOS `say` and committed, so every run
hears the same audio. Key terms are marked in clips.json as [term] or [term|accepted alternative].
Real recordings: recordings/<name>.m4a (or wav / mp3 / caf / aiff) next to <name>.txt with the same
markup. They're transcribed with the clips and scored separately, since `say` has no accent or noise.

A key term counts when one spelling appears as whole words; case, spaces, hyphens, dots and a plural s
don't matter. Results go to results/<engine>-<model>[-<variant>].jsonl, which docs/local-models.md and
docs/dictation-accuracy.md quote.
"""
import argparse, base64, glob, json, os, re, subprocess, sys, tempfile, time, urllib.request, uuid

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
HARNESS = os.path.join(HERE, "harness", ".build", "release")
SILERO = os.path.join(REPO, "VoiceInk", "Resources", "models", "ggml-silero-v5.1.2.bin")
WHISPER_ZH_PROMPT = "你好，最近好吗？见到你很高兴。"  # WhisperPrompt.swift
AUDIO_EXTENSIONS = ("m4a", "wav", "mp3", "caf", "aiff")


def keywords(text):
    return [t.split("|") for t in re.findall(r"\[([^\]]+)\]", text)]


def spoken(text):
    return re.sub(r"\[([^\]|]+)[^\]]*\]", r"\1", text)


def cases():
    """Clips from clips.json, then recordings/; each {id, voice, keywords, audio}."""
    rows = [{"id": c["id"], "voice": c["voice"], "keywords": keywords(c["text"]),
             "audio": os.path.join(HERE, "clips", c["id"] + ".m4a")}
            for c in json.load(open(os.path.join(HERE, "clips.json")))]
    for txt in sorted(glob.glob(os.path.join(HERE, "recordings", "*.txt"))):
        stem = txt[:-4]
        audio = next((f"{stem}.{e}" for e in AUDIO_EXTENSIONS if os.path.exists(f"{stem}.{e}")), None)
        if audio:
            rows.append({"id": "rec:" + os.path.basename(stem), "voice": "recording",
                         "keywords": keywords(open(txt).read()), "audio": audio})
    return rows


def wavs(rows):
    """16 kHz mono WAV of every case in a temp dir; returns [(case, path, seconds)]."""
    out = tempfile.mkdtemp(prefix="yap-asr-")
    clips = []
    for c in rows:
        dst = os.path.join(out, re.sub(r"\W", "_", c["id"]) + ".wav")
        subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", c["audio"], dst], check=True)
        info = subprocess.run(["afinfo", dst], capture_output=True, text=True).stdout
        clips.append((c, dst, float(re.search(r"estimated duration: ([\d.]+)", info).group(1))))
    return clips


def run_json_lines(cmd, clips):
    """Programs that load once, then print {file, text, secs} per clip; load time on stderr as 'load <secs>'."""
    p = subprocess.run(cmd + [w for _, w, _ in clips], capture_output=True, text=True)
    rows = {json.loads(l)["file"]: json.loads(l) for l in p.stdout.splitlines() if l.startswith("{")}
    load = float(re.search(r"^load ([\d.]+)", p.stderr, re.M).group(1))
    for c, wav, _ in clips:
        yield c, rows[wav]["text"], rows[wav]["secs"], load


def env_key(name):
    if os.environ.get(name):
        return os.environ[name]
    for line in open(os.path.expanduser("~/.env")):
        if line.startswith(name + "="):
            return line.split("=", 1)[1].strip().strip('"')
    sys.exit(f"{name} is not set (env or ~/.env)")


def post(request):
    for attempt in range(3):
        try:
            return json.load(urllib.request.urlopen(request, timeout=60)).get("text") or ""
        except (OSError, ValueError) as error:  # timeouts, HTTP errors, bad JSON
            print(f"  {error} (attempt {attempt + 1})", file=sys.stderr)
    return ""


def run_openrouter(model, clips):
    """LLMkit's OpenRouterTranscriptionClient: multipart file + model."""
    for c, wav, _ in clips:
        boundary = uuid.uuid4().hex
        body = b"".join([
            f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="audio.wav"\r\n'
            f"Content-Type: audio/wav\r\n\r\n".encode(), open(wav, "rb").read(),
            f'\r\n--{boundary}\r\nContent-Disposition: form-data; name="model"\r\n\r\n{model}'
            f"\r\n--{boundary}--\r\n".encode()])
        request = urllib.request.Request("https://openrouter.ai/api/v1/audio/transcriptions", body, {
            "Authorization": f"Bearer {env_key('OPENROUTER_API_KEY')}",
            "Content-Type": f"multipart/form-data; boundary={boundary}"})
        t = time.time()
        text = post(request)
        yield c, text.strip(), time.time() - t, 0.0


def run_yapcloud(model, clips):
    """YapCloudProvider: JSON {model, input_audio} through paygate."""
    base = os.environ.get("YAP_CLOUD_URL", "https://cloud.yap.sma1lboy.me")
    for c, wav, _ in clips:
        body = {"model": model, "input_audio": {"data": base64.b64encode(open(wav, "rb").read()).decode(), "format": "wav"}}
        request = urllib.request.Request(base + "/v1/audio/transcriptions", json.dumps(body).encode(), {
            "Authorization": f"Bearer {env_key('YAP_CLOUD_TOKEN')}", "Content-Type": "application/json"})
        t = time.time()
        text = post(request)
        yield c, text.strip(), time.time() - t, 0.0


def hits(case, text):
    """A keyword counts when any spelling appears as whole words; case, spaces/hyphens/dots and a plural s don't matter."""
    def pattern(alt):
        chars = [re.escape(ch) for ch in re.sub(r"[\s\-_.]", "", alt.lower())]
        return r"(?<![a-z0-9])" + r"[\s\-_.]?".join(chars) + r"s?(?![a-z0-9])"
    t = text.lower()
    return [any(re.search(pattern(alt), t) for alt in kw) for kw in case["keywords"]]


def score():
    by_id = {c["id"]: c for c in cases()}
    voices = sorted({c["voice"] for c in by_id.values() if c["voice"] != "recording"})
    print(f"{'result':48} {'hits':>6} " + " ".join(f"{v.split(' ')[0]:>9}" for v in voices)
          + f" {'recordings':>10} {'RTF':>6} {'p50 s':>6} {'load s':>7}")
    for f in sorted(glob.glob(os.path.join(HERE, "results", "*.jsonl"))):
        rows = [r for r in map(json.loads, open(f)) if r["id"] in by_id]
        def tally(pick):
            picked = [r for r in rows if pick(by_id[r["id"]])]
            return (sum(sum(hits(by_id[r["id"]], r["text"])) for r in picked),
                    sum(len(by_id[r["id"]]["keywords"]) for r in picked))
        n, total = tally(lambda c: c["voice"] != "recording")
        per_voice = [tally(lambda c, v=v: c["voice"] == v) for v in voices]
        rec = tally(lambda c: c["voice"] == "recording")
        clips = [r for r in rows if by_id[r["id"]]["voice"] != "recording"]
        rtf = sum(r["secs"] for r in clips) / sum(r["audio"] for r in clips)
        p50 = sorted(r["secs"] for r in clips)[len(clips) // 2]
        print(f"{os.path.basename(f)[:-6]:48} {n:>3}/{total:<2} " + " ".join(f"{a:>6}/{b:<2}" for a, b in per_voice)
              + f" {(f'{rec[0]}/{rec[1]}' if rec[1] else '-'):>10} {rtf:>6.3f} {p50:>6.2f} {rows[0]['load']:>7.2f}")


def main():
    if sys.argv[1:2] == ["score"]:
        return score()
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["run"])
    parser.add_argument("engine", choices=["whisper", "tcpp", "nemotron", "openrouter", "yapcloud"])
    parser.add_argument("model")
    parser.add_argument("--language", default="zh")
    parser.add_argument("--vocab", action="store_true", help="whisper: every key term in the prompt")
    parser.add_argument("--itn", action="store_true", help="tcpp: inverse text normalization")
    args = parser.parse_args()

    rows = cases()
    clips = wavs(rows)
    audio = {c["id"]: s for c, _, s in clips}
    variant = ("-" + args.language if args.language != "zh" else "") + ("-vocab" if args.vocab else "")
    if args.engine == "whisper":
        prompt = WHISPER_ZH_PROMPT if args.language == "zh" else ""
        if args.vocab:
            prompt = " ".join(filter(None, [prompt, ", ".join(kw[0] for c in rows for kw in c["keywords"])]))
        results = run_json_lines([os.path.join(HARNESS, "whisperbench"), args.model, SILERO, args.language, prompt], clips)
    elif args.engine == "tcpp":
        results = run_json_lines([os.path.join(HARNESS, "tcppbench"), args.model, args.language, "1" if args.itn else "0"], clips)
    elif args.engine == "nemotron":
        results = run_json_lines([os.path.join(HARNESS, "fluidbench"), args.model,
                                  "zh-CN" if args.language == "zh" else args.language], clips)
    elif args.engine == "openrouter":
        results = run_openrouter(args.model, clips)
    else:
        results = run_yapcloud(args.model, clips)
    name = ("nemotron-multilingual" if args.engine == "nemotron"
            else f"{args.engine}-{os.path.basename(args.model.rstrip('/')).replace('/', '_')}") + variant
    os.makedirs(os.path.join(HERE, "results"), exist_ok=True)
    with open(os.path.join(HERE, "results", name + ".jsonl"), "w") as out:
        for c, text, secs, load in results:
            h = hits(c, text)
            print(f"[{c['id']}] {sum(h)}/{len(h)} {secs:.2f}s  {text}")
            out.write(json.dumps({"id": c["id"], "text": text, "secs": secs, "load": load, "audio": audio[c["id"]]},
                                 ensure_ascii=False) + "\n")


if __name__ == "__main__":
    assert hits({"keywords": [["GitHub Actions"], ["CI"], ["layer"]]}, "改 github-actions 的 decision，layers 顺序") == [True, False, True]
    assert keywords("预计[周四|星期四]能合进 [main]") == [["周四", "星期四"], ["main"]]
    assert spoken("预计[周四|星期四]能合进 [main]") == "预计周四能合进 main"
    main()
