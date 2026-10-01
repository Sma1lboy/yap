#!/bin/bash
# make meeting-long-check MODEL=<ggml-*.bin>: the end of a long meeting. Builds an 11-minute two-channel meeting
# (Tingting's clips are "me"; "others" are three voices: Reed's clips, and lines said by Shelley and Eddy with `say`)
# and runs it through --meeting-files (the mock identity as a fresh install, scripts/meeting-check-common.sh):
# 1. cold: the speaker models are downloaded first. Prints how long transcribing and telling the speakers apart took.
# 2. warm, with --meeting-speaker-wait 0 so the meeting is saved before the speakers are ready: the saved entry says
#    plain "Others" and "pending", and once they arrive the same entry has "Others 1", "Others 2" and no status.
# 3. the first 3 minutes, saved the same way, and the app quits before the speakers are ready
#    (--meeting-exit-before-speakers); the next launch (--meeting-speakers-resume-check) finishes them.
set -euo pipefail

APP_DIR="$1"
MODEL="${2:?usage: meeting-long-check.sh <app dir> <ggml-*.bin>}"
NOTES=""
WORK=/tmp/yap-meeting-long-check
source "$(dirname "$0")/meeting-check-common.sh"

b=0
for line in "我补充一点，Kubernetes 那边的 rollout 我已经在测试环境跑过了，没有问题。" \
	"我这边的排期是下周三，需要 design 先确认一下 API 的字段。" \
	"监控这块我建议先把 Grafana 的 dashboard 统一一下，告警规则太多了。" \
	"数据库迁移我来负责，周五之前给大家一个方案。"; do
	b=$((b + 1)); say_clip "b$b" "Shelley (Chinese (China mainland))" "$line"
done
c=0
for line in "Quick question on the rollout: do we still need the feature flag after Friday?" \
	"I can take the load test, but I need access to the staging cluster first." \
	"Let's keep the retro short this week, we are already over time." \
	"The customer asked for the export in CSV, not JSON, so the endpoint has to change."; do
	c=$((c + 1)); say_clip "c$c" "Eddy (English (US))" "$line"
done

python3 - "$WORK" <<'PY'
import itertools, sys, wave
work = sys.argv[1]
def frames(name):
    with wave.open(f"{work}/clips/{name}.wav") as w:
        return w.readframes(w.getnframes())
silence = lambda seconds: b"\0\0" * int(16000 * seconds)
voices = {
    "me": itertools.cycle(["deploy", "bug", "meeting", "frontend", "product", "security"]),
    "A": itertools.cycle(["standup", "perf", "ml", "infra", "email"]),
    "B": itertools.cycle(["b1", "b2", "b3", "b4"]),
    "C": itertools.cycle(["c1", "c2", "c3", "c4"]),
}
order = itertools.cycle(["me", "A", "B", "me", "C", "A", "me", "B", "C"])
mic, system = b"", b""
while len(mic) < 32000 * 660:
    who = next(order)
    data = frames(next(voices[who])) + silence(0.8)
    quiet = silence(len(data) / 32000)
    mic += data if who == "me" else quiet
    system += quiet if who == "me" else data
for name, data in [("mic", mic), ("system", system)]:
    for suffix, part in [("", data), ("-short", data[:32000 * 180])]:
        with wave.open(f"{work}/{name}{suffix}.wav", "wb") as w:
            w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000); w.writeframes(part)
print(f"test meeting: {len(mic) / 32000 / 60:.1f} min per channel")
PY

run_app "$WORK/cold.txt" --meeting-files "$WORK/mic.wav" "$WORK/system.wav"
run_app "$WORK/warm.txt" --meeting-files "$WORK/mic.wav" "$WORK/system.wav" --meeting-speaker-wait 0
run_app "$WORK/quit.txt" --meeting-files "$WORK/mic-short.wav" "$WORK/system-short.wav" --meeting-speaker-wait 0 \
	--meeting-exit-before-speakers
run_app "$WORK/resume.txt" --meeting-speakers-resume-check
for run in cold warm quit resume; do
	grep -E '^meeting-check: (transcribed|diarized|seconds|speakers-|entry |panel )' "$WORK/$run.txt" | sed "s/^meeting-check: /$run: /"
done

python3 - "$WORK" <<'PY'
import re, sys
work = sys.argv[1]
problems = []
def entries(run):
    """(status, transcript) of each time the run printed the saved entry."""
    text = open(f"{work}/{run}.txt").read()
    statuses = re.findall(r"^meeting-check: entry \S+ speaker-status (\S+)$", text, re.M)
    transcripts = re.findall(r"^meeting-check: entry-transcript-begin\n(.*?)\nmeeting-check: entry-transcript-end$", text, re.M | re.S)
    return list(zip(statuses, transcripts))
def labels(transcript):
    return sorted(set(re.findall(r"^\[[0-9:]+\] (Others \d+):", transcript, re.M)))
def plain(transcript):
    return bool(re.search(r"^\[[0-9:]+\] Others:", transcript, re.M))

for run in ["cold", "warm"]:
    text = open(f"{work}/{run}.txt").read()
    transcribed = re.search(r"^meeting-check: transcribed in ([\d.]+) s; (\d+) pieces, (\d+) s per channel$", text, re.M)
    diarized = re.search(r"^meeting-check: diarized in ([\d.]+) s; system audio (\d+) s$", text, re.M)
    if not (transcribed and diarized):
        problems.append(f"{run}: no timing")
        continue
    seconds, pieces, audio = float(transcribed[1]), int(transcribed[2]), int(transcribed[3])
    diarize = float(diarized[1])
    print(f"{run}: transcribing {seconds:.1f} s for {pieces} pieces ({seconds / pieces:.1f} s each); telling speakers apart "
          f"{diarize:.1f} s for {audio / 60:.1f} min, {diarize / (audio / 60):.2f} s per minute of audio, "
          f"{diarize / (audio / 60) * 60:.0f} s for an hour")

# Saved before the speakers were ready: plain "Others" and pending; then the same entry has them.
warm = entries("warm")
if len(warm) != 2:
    problems.append(f"warm: expected the entry printed at saving and after the speakers arrived, got {len(warm)}")
else:
    (saved_status, saved), (after_status, after) = warm
    if saved_status != "pending" or labels(saved) or not plain(saved):
        problems.append(f"warm: at saving expected pending with plain Others, got {saved_status} {labels(saved)}")
    if after_status != "none" or len(labels(after)) < 2 or plain(after):
        problems.append(f"warm: after the speakers expected Others 1, 2…, got {after_status} {labels(after)}")
    else:
        print(f"background: saved with plain Others, then the same entry got {', '.join(labels(after))}")
    if "meeting-check: panel pending false labeled-later true" not in open(f"{work}/warm.txt").read():
        problems.append("warm: the panel didn't take the speakers")

# Quit before the speakers were ready: saved pending; the next launch finishes the same entry.
quit, resumed = entries("quit"), entries("resume")
if len(quit) != 1 or quit[0][0] != "pending" or "meeting-check: speakers-arrived" in open(f"{work}/quit.txt").read():
    problems.append(f"quit: expected one pending entry and no speakers, got {[s for s, _ in quit]}")
if "meeting-check: speakers-resumed 1\n" not in open(f"{work}/resume.txt").read() or len(resumed) != 1:
    problems.append("resume: expected the one pending meeting to be resumed")
elif resumed[0][0] != "none" or len(labels(resumed[0][1])) < 2:
    problems.append(f"resume: expected Others 1, 2…, got {resumed[0][0]} {labels(resumed[0][1])}")
else:
    print(f"resume: the meeting cut off by quitting got {', '.join(labels(resumed[0][1]))} at the next launch")

print("long:", "OK" if not problems else "FAIL")
for problem in problems: print("  " + problem)
sys.exit(1 if problems else 0)
PY
