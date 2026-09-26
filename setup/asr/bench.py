#!/usr/bin/env python3
"""Key-term accuracy of speech-to-text on Chinese–English code-switched dictation.

    python3 setup/asr/bench.py [engine ...] [--vocab-prompt] [--json out.json]

Engines (default: the OpenRouter pick plus every ggml model given with --models-dir):
    whisper:<path/to/ggml-*.bin>   the app's own LibWhisper.swift, run by harness/ (built on first use)
    openrouter:<model id>          same multipart request as the app (OPENROUTER_API_KEY, env or ~/.env)
    yapcloud:<model id>            same JSON request as the app (YAP_CLOUD_TOKEN; YAP_CLOUD_URL optional)

Audio:
    clips.json            11 clips rendered with macOS `say` (Tingting and Meijia, rate 220; the Eloquence voices
                          such as Eddy or Flo turn English words into noise), cached in
                          .local-build/asr/. `say` is not a person: accents, fillers and noise are missing.
    recordings/<name>.*   real recordings (m4a, wav, mp3, caf, aiff) next to <name>.txt holding what was said.
                          Both clips.json and the .txt files mark key terms in brackets: [PR], [useEffect],
                          and alternatives the scorer should also accept after a bar: [50|五十].

A term counts as recognised when one of its spellings appears in the transcript, compared case-insensitively
with whitespace removed ("user ID" matches "userID"). The score is recognised terms / all terms.

--vocab-prompt passes every key term, comma separated, to whisper as its initial prompt: the upper bound of
what the dictionary-as-prompt feature can do. Results go in docs/dictation-accuracy.md.
"""
import argparse, base64, glob, hashlib, json, os, re, statistics, subprocess, sys, time, urllib.request, uuid

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
CACHE = os.path.join(REPO, ".local-build", "asr")
SILERO = os.path.join(REPO, "VoiceInk", "Resources", "models", "ggml-silero-v5.1.2.bin")
WHISPER_FRAMEWORK = os.path.expanduser(
    "~/VoiceInk-Dependencies/whisper.cpp/build-apple/whisper.xcframework/macos-arm64_x86_64")
AUDIO_EXTENSIONS = ("m4a", "wav", "mp3", "caf", "aiff")


def terms_of(text):
    return [t.split("|") for t in re.findall(r"\[([^\]]+)\]", text)]


def spoken(text):
    return re.sub(r"\[([^\]|]+)[^\]]*\]", r"\1", text)


def to_wav16k(source, target):
    subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", source, target], check=True)


def load_items():
    os.makedirs(CACHE, exist_ok=True)
    items = []
    for clip in json.load(open(os.path.join(HERE, "clips.json"))):
        key = hashlib.sha1((clip["voice"] + clip["text"]).encode()).hexdigest()[:10]
        wav = os.path.join(CACHE, f"{clip['id']}-{key}.wav")
        if not os.path.exists(wav):
            aiff = wav[:-4] + ".aiff"
            subprocess.run(["say", "-v", clip["voice"], "-r", "220", "-o", aiff, spoken(clip["text"])], check=True)
            to_wav16k(aiff, wav)
            os.remove(aiff)
        items.append({"id": clip["id"], "wav": wav, "terms": terms_of(clip["text"])})
    for txt in sorted(glob.glob(os.path.join(HERE, "recordings", "*.txt"))):
        stem = txt[:-4]
        audio = next((f"{stem}.{e}" for e in AUDIO_EXTENSIONS if os.path.exists(f"{stem}.{e}")), None)
        if not audio:
            continue
        wav = os.path.join(CACHE, "rec-" + os.path.basename(stem) + ".wav")
        if not os.path.exists(wav) or os.path.getmtime(wav) < os.path.getmtime(audio):
            to_wav16k(audio, wav)
        items.append({"id": "rec:" + os.path.basename(stem), "wav": wav, "terms": terms_of(open(txt).read())})
    return items


def env_key(name):
    if os.environ.get(name):
        return os.environ[name]
    try:
        for line in open(os.path.expanduser("~/.env")):
            if line.startswith(name + "="):
                return line.split("=", 1)[1].strip().strip('"')
    except FileNotFoundError:
        pass
    sys.exit(f"{name} is not set (env or ~/.env)")


def harness():
    binary = os.path.join(CACHE, "asr-harness")
    sources = [os.path.join(HERE, "harness", "main.swift"), os.path.join(HERE, "harness", "Stubs.swift")] + [
        os.path.join(REPO, "VoiceInk", "Infrastructure", "Providers", "Transcription", "Whisper", f)
        for f in ("LibWhisper.swift", "WhisperChunking.swift")]
    if not os.path.exists(binary) or os.path.getmtime(binary) < max(map(os.path.getmtime, sources)):
        subprocess.run(["xcrun", "swiftc", "-O", "-F", WHISPER_FRAMEWORK, "-framework", "whisper",
                        "-Xlinker", "-rpath", "-Xlinker", WHISPER_FRAMEWORK, "-o", binary] + sources, check=True)
    return binary


def transcribe(engine, wav, prompt):
    kind, _, target = engine.partition(":")
    start = time.time()
    if kind == "whisper":
        args = [harness(), target, SILERO, wav] + ([f"prompt={prompt}"] if prompt else [])
        out = subprocess.run(args, capture_output=True, text=True, check=True).stdout.strip().splitlines()[-1]
        result = json.loads(out)
        return result["text"], result["seconds"]
    audio = open(wav, "rb").read()
    if kind == "openrouter":
        boundary = uuid.uuid4().hex
        body = b"".join([
            f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="audio.wav"\r\n'
            f"Content-Type: audio/wav\r\n\r\n".encode(), audio,
            f'\r\n--{boundary}\r\nContent-Disposition: form-data; name="model"\r\n\r\n{target}'
            f"\r\n--{boundary}--\r\n".encode()])
        request = urllib.request.Request("https://openrouter.ai/api/v1/audio/transcriptions", body, {
            "Authorization": f"Bearer {env_key('OPENROUTER_API_KEY')}",
            "Content-Type": f"multipart/form-data; boundary={boundary}"})
    elif kind == "yapcloud":
        base = os.environ.get("YAP_CLOUD_URL", "https://cloud.yap.sma1lboy.me")
        body = json.dumps({"model": target, "input_audio": {"data": base64.b64encode(audio).decode(), "format": "wav"}})
        request = urllib.request.Request(base + "/v1/audio/transcriptions", body.encode(), {
            "Authorization": f"Bearer {env_key('YAP_CLOUD_TOKEN')}", "Content-Type": "application/json"})
    else:
        sys.exit(f"unknown engine {engine}")
    text = json.load(urllib.request.urlopen(request, timeout=60)).get("text") or ""
    return text, time.time() - start


def hit(spellings, text):
    squash = lambda s: re.sub(r"\s+", "", s).lower()
    return any(squash(s) in squash(text) for s in spellings)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("engines", nargs="*")
    parser.add_argument("--models-dir", help="add whisper:<file> for every ggml-*.bin in this directory")
    parser.add_argument("--vocab-prompt", action="store_true")
    parser.add_argument("--json")
    args = parser.parse_args()
    engines = args.engines or ["openrouter:microsoft/mai-transcribe-2"]
    if args.models_dir:
        engines += [f"whisper:{p}" for p in sorted(glob.glob(os.path.join(args.models_dir, "ggml-*.bin")))
                    if "silero" not in p]

    items = load_items()
    total = sum(len(i["terms"]) for i in items)
    prompt = ", ".join(t[0] for i in items for t in i["terms"]) if args.vocab_prompt else None
    report = {}
    for engine in engines:
        hits, seconds, misses, texts = 0, [], [], {}
        for item in items:
            text, secs = transcribe(engine, item["wav"], prompt)
            seconds.append(secs)
            texts[item["id"]] = text
            for spellings in item["terms"]:
                if hit(spellings, text):
                    hits += 1
                else:
                    misses.append(f"{item['id']}:{spellings[0]}")
        report[engine] = {"hits": hits, "total": total, "p50_seconds": statistics.median(seconds),
                          "misses": misses, "texts": texts}
        print(f"{engine}  {hits}/{total}  p50 {statistics.median(seconds):.2f}s  missed: {', '.join(misses)}",
              flush=True)
    if args.json:
        json.dump(report, open(args.json, "w"), ensure_ascii=False, indent=1)


if __name__ == "__main__":
    main()
