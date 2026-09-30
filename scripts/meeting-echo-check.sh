#!/bin/bash
# make meeting-echo-check MODEL=<ggml-*.bin>: a meeting without headphones, where the other side comes out of the
# speakers and into the microphone. Builds a two-minute meeting from setup/asr/clips and `say`: Tingting's clips are
# "me", and "others" are Reed's clips and lines by Shelley (Chinese) and Eddy (English); once, the user talks over
# Reed. The microphone gets room noise (−60 dBFS) and, in two of three runs, the system audio delayed and quieter
# (30 ms and 12 dB quieter, then 80 ms and 20 dB with a second reflection), as a laptop's speakers would put it there.
# Each run goes through --meeting-files (scripts/meeting-check-common.sh), and the kept "Me" text is compared with
# what each line really said:
# - without echo nothing is taken out (every "Me" piece stays a "Me" line);
# - with echo, what the others said while the user was quiet isn't under "Me" any more (it was, before), the pieces
#   are marked in segments.json, and every line the user said, the one said over Reed included, is still there.
set -euo pipefail

APP_DIR="$1"
MODEL="${2:?usage: meeting-echo-check.sh <app dir> <ggml-*.bin>}"
NOTES=""
WORK=/tmp/yap-meeting-echo-check
source "$(dirname "$0")/meeting-check-common.sh"

say_clip b1 "Shelley (Chinese (China mainland))" "我补充一点，Kubernetes 那边的 rollout 我已经在测试环境跑过了，没有问题。"
say_clip b2 "Shelley (Chinese (China mainland))" "我这边的排期是下周三，需要 design 先确认一下 API 的字段。"
say_clip c1 "Eddy (English (US))" "Quick question on the rollout: do we still need the feature flag after Friday?"
say_clip c2 "Eddy (English (US))" "The customer asked for the export in CSV, not JSON, so the endpoint has to change."
cat >"$WORK/lines.txt" <<'EOF'
b1 我补充一点，Kubernetes 那边的 rollout 我已经在测试环境跑过了，没有问题。
b2 我这边的排期是下周三，需要 design 先确认一下 API 的字段。
c1 Quick question on the rollout: do we still need the feature flag after Friday?
c2 The customer asked for the export in CSV, not JSON, so the endpoint has to change.
EOF

# fixture <name> <delay ms> <attenuation dB> [reflection]: mic.wav and system.wav in $WORK/<name>/, truth.json.
fixture() {
	python3 - "$WORK" "$@" <<'PY'
import array, json, os, random, sys, wave
work, run, delay, attenuation = sys.argv[1], sys.argv[2], int(sys.argv[3]), float(sys.argv[4])
reflection = len(sys.argv) > 5
def clip(name):
    with wave.open(f"{work}/clips/{name}.wav") as w:
        return array.array("h", w.readframes(w.getnframes()))
# (who, clip, start in seconds); "me" is the microphone, the others the system audio.
timeline, t = [], 0.5
def say(who, name, gap=1.0, at=None):
    global t
    start = t if at is None else at
    timeline.append((who, name, start, start + len(clip(name)) / 16000))
    if at is None: t = start + len(clip(name)) / 16000 + gap
for name in ["deploy", "bug"]: say("me", name, 0.5)
for name in ["standup", "infra", "perf"]: say("A", name, 0.5)
say("B", "b1"); say("B", "b2")
for name in ["meeting", "frontend"]: say("me", name, 0.5)
say("C", "c1", 0.5); say("C", "c2")
# The user talks over Reed: "security" starts two seconds into "ml".
overlap = t
say("A", "ml", 0.5); say("me", "security", at=overlap + 2); say("A", "email")
t = max(t, timeline[-2][3] + 1)
say("me", "product"); say("B", "b2"); say("me", "deploy")
length = int((t + 1) * 16000)
mic, system = [0.0] * length, [0.0] * length
for who, name, start, _ in timeline:
    target = mic if who == "me" else system
    offset = int(start * 16000)
    for i, sample in enumerate(clip(name)): target[offset + i] += sample
random.seed(7)
for i in range(length): mic[i] += random.gauss(0, 32768 * 10 ** (-60 / 20))
if delay:
    for lag, gain in [(delay, 10 ** (-attenuation / 20))] + ([(delay + 35, 10 ** (-(attenuation + 9) / 20))] if reflection else []):
        shift = lag * 16
        for i in range(shift, length): mic[i] += system[i - shift] * gain
os.makedirs(f"{work}/{run}", exist_ok=True)
for channel, data in [("mic", mic), ("system", system)]:
    with wave.open(f"{work}/{run}/{channel}.wav", "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000)
        w.writeframes(array.array("h", (max(-32768, min(32767, int(round(x)))) for x in data)).tobytes())
json.dump([{"who": w, "clip": c, "start": s, "end": e} for w, c, s, e in timeline], open(f"{work}/{run}/truth.json", "w"))
print(f"{run}: {length / 16000:.0f} s, echo {'none' if not delay else f'{delay} ms, -{attenuation:g} dB' + (' + reflection' if reflection else '')}")
PY
}

# judge <name>: what the kept "Me" text holds of each line: the share of the line's letters found in order, in runs
# of 3 or more (so two unrelated Chinese sentences, which share many single characters, score near 0).
judge() {
	python3 - "$WORK" "$ROOT" "$@" <<'PY'
import json, re, sys, unicodedata
work, root, name = sys.argv[1], sys.argv[2], sys.argv[3]
texts = {c["id"]: re.sub(r"\[([^]|]*)[^]]*\]", r"\1", c["text"]) for c in json.load(open(f"{root}/setup/asr/clips.json"))}
for line in open(f"{work}/lines.txt"):
    key, text = line.rstrip("\n").split(" ", 1)
    texts[key] = text
norm = lambda s: [c for c in unicodedata.normalize("NFKC", s).lower() if c.isalnum()]
def covered(reference, hypothesis):
    a, b = norm(reference), norm(hypothesis)
    if not a or not b: return 0.0
    table = [[0] * (len(b) + 1) for _ in range(len(a) + 1)]
    for i in range(len(a)):
        for j in range(len(b)):
            table[i + 1][j + 1] = table[i][j] + 1 if a[i] == b[j] else max(table[i][j + 1], table[i + 1][j])
    pairs, i, j = [], len(a), len(b)
    while i and j:
        if a[i - 1] == b[j - 1]: pairs.append((i - 1, j - 1)); i -= 1; j -= 1
        elif table[i - 1][j] >= table[i][j - 1]: i -= 1
        else: j -= 1
    pairs.reverse()
    total, run = 0, 1
    for k in range(1, len(pairs) + 1):
        if k < len(pairs) and pairs[k][0] == pairs[k - 1][0] + 1 and pairs[k][1] == pairs[k - 1][1] + 1:
            run += 1
            continue
        if run >= 3: total += run
        run = 1
    return total / len(a)
out = open(f"{work}/{name}/out.txt").read()
folder = re.search(r"^meeting-check: folder (.*)$", out, re.M).group(1)
segments = json.load(open(f"{folder}/segments.json"))
me = [s for s in segments if s["speaker"] == "me"]
echo = [s for s in me if s.get("echo") or s.get("textWithEcho") is not None]
result = {"echo-marked": len(echo), "me-pieces": len(me), "lines": {}}
for line in json.load(open(f"{work}/{name}/truth.json")):
    near = [s for s in me if s["start"] < line["end"] + 1 and s["end"] > line["start"] - 1]
    kept = " ".join(s["text"] for s in near if not s.get("echo"))
    heard = " ".join(s.get("textWithEcho") or s["text"] for s in near)
    result["lines"][f'{line["who"]} {line["clip"]} {line["start"]:.0f}s'] = {
        "kept": round(covered(texts[line["clip"]], kept), 2), "heard": round(covered(texts[line["clip"]], heard), 2)}
json.dump(result, open(f"{work}/{name}/judged.json", "w"), ensure_ascii=False, indent=1)
for key, value in result["lines"].items(): print(f"  {key:<24} Me keeps {value['kept']:.2f} (transcribed {value['heard']:.2f})")
PY
}

fixture clean 0 0
fixture near 30 12
fixture far 80 20 reflection
for name in clean near far; do
	run_app "$WORK/$name/out.txt" --meeting-files "$WORK/$name/mic.wav" "$WORK/$name/system.wav"
	echo "$name: $(grep -E '^meeting-check: echo-removed' "$WORK/$name/out.txt" | sed 's/^meeting-check: //')"
	grep -E '^meeting-check: echo (coupling|me)' "$WORK/$name/out.txt" | sed 's/^meeting-check: echo /  /'
	judge "$name"
done

python3 - "$WORK" <<'PY'
import json, sys
work = sys.argv[1]
clean = json.load(open(f"{work}/clean/judged.json"))
problems = []
if clean["echo-marked"]:
    problems.append(f"clean: {clean['echo-marked']} of {clean['me-pieces']} Me pieces taken out without any echo")
for name in ["near", "far"]:
    run = json.load(open(f"{work}/{name}/judged.json"))
    if not run["echo-marked"]:
        problems.append(f"{name}: no Me piece marked as echo in segments.json")
    echoed = 0
    for key, value in run["lines"].items():
        if key.startswith("me "):
            # Every line the user said is still under "Me": nothing of it was cut as echo, and it was transcribed.
            if value["kept"] < value["heard"] - 0.15:
                problems.append(f"{name}: Me line {key} was cut as echo ({value['heard']:.2f} -> {value['kept']:.2f})")
            elif value["kept"] < min(0.4, clean["lines"][key]["kept"] - 0.25):
                problems.append(f"{name}: Me line {key} missing ({value['kept']:.2f}, clean {clean['lines'][key]['kept']:.2f})")
        elif "security" not in key and not key.startswith("A ml"):
            # What the others said while the user was quiet: under "Me" before, not any more.
            echoed += value["heard"] >= 0.5
            if value["kept"] > 0.25:
                problems.append(f"{name}: {key} is still under Me ({value['kept']:.2f})")
    if not echoed:
        problems.append(f"{name}: the echo was never transcribed under Me, so this run checks nothing")
    print(f"{name}: {run['echo-marked']} of {run['me-pieces']} Me pieces marked as echo; {echoed} of the others' lines were transcribed under Me and taken out")
print("echo:", "OK" if not problems else "FAIL")
for problem in problems: print("  " + problem)
sys.exit(1 if problems else 0)
PY
