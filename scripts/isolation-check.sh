#!/bin/bash
# make isolation-check MODEL=<ggml-*.bin> MODEL2=<another ggml-*.bin>: local Whisper requests that overlap must each
# get what they'd get alone. The Debug app re-identified as me.sma1lboy.yap.mock as a fresh install (see
# scripts/meeting-check-common.sh), its mode on MODEL, runs IsolationCheck (--isolation-check):
# - same model, clip A in Chinese with one prompt and clip B in English with another, ten pairs started together;
# - clip B through the audio import queue (timed segments saved with the entry) while clip A is transcribed;
# - a model that isn't on disk fails, alone and beside clip A, and clip A still comes out as alone;
# - a meeting on MODEL while the mode is switched to MODEL2 and clip A is dictated until the meeting is done.
# Every overlapping result is compared, text and timed segments, with its request run alone; a meeting must have no
# failed piece. `footprint` samples the process every second. Results stay in $OUT (default /tmp/yap-isolation-check).
set -euo pipefail

APP_DIR="$1"
MODEL="${2:?usage: isolation-check.sh <app dir> <ggml-*.bin> <another ggml-*.bin>}"
MODEL2="${3:?usage: isolation-check.sh <app dir> <ggml-*.bin> <another ggml-*.bin>}"
NOTES=""
OUT="${OUT:-/tmp/yap-isolation-check}"
WORK="$OUT/work"
# Speaker models for the meetings' diarization: downloaded by the first run, reused from here after.
SPEAKER_CACHE="${SPEAKER_CACHE:-/tmp/yap-speaker-models}"
mkdir -p "$OUT"
source "$(dirname "$0")/meeting-check-common.sh"
cp -c "$MODEL2" "$SUPPORT/WhisperModels/" 2>/dev/null || cp "$MODEL2" "$SUPPORT/WhisperModels/"
restore_speaker_models

# The meeting: "me" and "others" take turns, one second apart, about 54 s per channel (six pieces).
python3 - "$WORK" <<'PY'
import sys, wave
work = sys.argv[1]
def frames(name):
    with wave.open(f"{work}/clips/{name}.wav") as w:
        return w.readframes(w.getnframes())
silence = lambda seconds: b"\0\0" * int(16000 * seconds)
mic, system = b"", b""
for me_clip, other_clip in [("deploy", "standup"), ("bug", "infra"), ("perf", "ml"), ("meeting", "product")]:
    a, b = frames(me_clip), frames(other_clip)
    mic += a + silence(1) + silence(len(b) / 32000) + silence(1)
    system += silence(len(a) / 32000) + silence(1) + b + silence(1)
for name, data in [("mic", mic), ("system", system)]:
    with wave.open(f"{work}/{name}.wav", "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000); w.writeframes(data)
print(f"test meeting: {len(mic) / 32000:.1f} s per channel")
PY

XDG_CONFIG_HOME="$WORK/config" "$APP/Contents/MacOS/VoiceInk Dev" --dictate-file "$WORK/clips/security.wav" \
	--isolation-check "$WORK/clips/email.wav" "$(basename "$MODEL2" .bin)" "$WORK/mic.wav" "$WORK/system.wav" \
	--meeting-speaker-wait 0 >"$OUT/out.txt" 2>"$OUT/err.txt" &
app=$!
pid=""
while [ -z "$pid" ] && kill -0 "$app" 2>/dev/null; do pid=$(pgrep -nf "$APP/Contents/MacOS/VoiceInk Dev" || true); sleep 0.1; done
: >"$OUT/footprint.txt"
while [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; do
	mb=$(footprint "$pid" 2>/dev/null | awk '/Footprint:/ { for (i = 1; i < NF; i++) if ($i == "Footprint:") { v = $(i+1); u = $(i+2) }
		if (u == "GB") v *= 1024; else if (u == "KB") v /= 1024; printf "%.0f", v; exit }' || true)
	[ -n "$mb" ] && echo "$(perl -MTime::HiRes=time -e 'printf "%.2f", time') $mb" >>"$OUT/footprint.txt"
	sleep 1
done
status=0
wait "$app" || status=$?
save_speaker_models "$OUT/err.txt"
speaker_models_source "$OUT/err.txt"
[ "$status" = 0 ] || { echo "FAIL: app exited with $status"; grep -v '^\s*$' "$OUT/err.txt" | tail -5; exit 1; }
grep -q '^isolation: .*"event":"done"' "$OUT/out.txt" || { echo "FAIL: the check didn't finish"; exit 1; }

python3 - "$OUT/out.txt" "$OUT/footprint.txt" <<'PY'
import json, sys
lines = [json.loads(l[len("isolation: "):]) for l in open(sys.argv[1]) if l.startswith("isolation: ")]
samples = [tuple(map(float, l.split())) for l in open(sys.argv[2]) if l.strip()]
results = [l for l in lines if "phase" in l]
def by(phase, request=None):
    return [r for r in results if r["phase"] == phase and (request is None or r["request"] == request)]
def same(r, base, keys=("text", "segments")):
    return r.get("ok") and all(r.get(k) == base.get(k) for k in keys)
failures = []
def check(cond, message):
    if not cond: failures.append(message)

# Baselines: each request run alone, twice, must agree with itself.
base = {}
for phase, request in [("same-serial", "A"), ("same-serial", "B"), ("import-serial", "import"),
                       ("dictation-serial", "dictation"), ("meeting-serial", "meeting")]:
    runs = by(phase, request)
    check(runs and all(r.get("ok") for r in runs), f"{phase} {request}: failed alone: {[r.get('error') for r in runs]}")
    check(all(same(r, runs[0], ("text", "segments", "model")) for r in runs), f"{phase} {request}: differs between two runs alone")
    base[request] = runs[0] if runs else {}
check(base["A"].get("text") != base["B"].get("text"), "A and B came out the same alone: the check can't tell them apart")
check(base["meeting"].get("failedPieces") == 0, f"meeting alone: {base['meeting'].get('failedPieces')} failed pieces")

def compare(phase, request, baseline, keys=("text", "segments")):
    runs = by(phase, request)
    bad = [r for r in runs if not same(r, baseline, keys)]
    for r in bad:
        other = [n for n, b in base.items() if n != request and r.get("text") == b.get("text")]
        failures.append(f"{phase} round {r['round']} {request}: " + (f"got {other[0]}'s text" if other else
            f"failed: {r.get('error', r.get('text'))!r}" if not r.get("ok") else
            "segments differ" if r.get("text") == baseline.get("text") else f"text differs: {r.get('text')!r}"))
    print(f"{phase:16} {request:9} {len(runs) - len(bad):3}/{len(runs)} as alone")

compare("same", "A", base["A"])
compare("same", "B", base["B"])
compare("import", "import", base["import"])
compare("import-other", "A", base["A"])
for r in by("fail-alone") + by("fail-beside", "missing"):
    check(r.get("ok") is False, f"{r['phase']}: the request for a model that isn't there didn't fail")
compare("fail-beside", "A", base["A"])
compare("fail-after", "A", base["A"])
compare("dictation", "dictation", base["dictation"], ("text", "model"))
compare("meeting", "meeting", base["meeting"], ("text", "failedPieces"))
for r in by("meeting"):
    print(f"meeting round {r['round']}: {r.get('failedPieces')} failed pieces, {r.get('seconds', 0):.1f} s, "
          f"{len([d for d in by('dictation') if d['round'] // 100 == r['round']])} dictations during it")
    check(r.get("failedPieces") == 0, f"meeting round {r['round']}: {r.get('failedPieces')} failed pieces")

# Per phase: median time per request, model loads (a load counts toward the next result), the footprint while it ran.
phase_loads, pending, spans, seconds = {}, [], {}, {}
for l in lines:
    if l.get("event") == "load":
        pending.append(l["model"])
    elif "phase" in l:
        phase_loads.setdefault(l["phase"], []).extend(pending)
        pending = []
        start, end = spans.get(l["phase"], (l["t"], l["t"]))
        spans[l["phase"]] = (min(start, l["t"] - l.get("seconds", 0)), max(end, l["t"]))
        seconds.setdefault((l["phase"], l["request"]), []).append(l.get("seconds", 0))
print("phase            request    median s   loads  peak footprint (MB)")
for (phase, request), times in seconds.items():
    start, end = spans[phase]
    near = [mb for t, mb in samples if start <= t <= end + 1]
    print(f"  {phase:16} {request:9} {sorted(times)[len(times) // 2]:7.2f} {len(phase_loads.get(phase, [])):7} "
          f"{max(near) if near else float('nan'):10.0f}")
if failures:
    print("FAIL:")
    for f in failures[:30]: print("  " + f)
    print(f"  ({len(failures)} in all)")
    sys.exit(1)
print("isolation-check: OK")
PY
