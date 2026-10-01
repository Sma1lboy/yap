#!/bin/bash
# make dictation-latency MODEL=<path to ggml-*.bin> [ROUNDS=12] [LANGUAGE=auto] [CLIPS=latency]: from "the user
# stopped" to the ⌘V that pastes, per step, with a local Whisper model already loaded and AI cleanup off. Same mock
# identity and fresh install as scripts/offline-check.sh (me.sma1lboy.yap.mock: its own defaults, Application Support
# and keychain), one mode on MODEL with LANGUAGE (auto, or a Whisper code such as zh or en). The Debug app is launched
# with --dictation-latency (DictationLatencyCheck.swift): it dictates the clips ROUNDS times each through the normal
# stop → transcribe → deliver path. CLIPS=latency: five clips (three Chinese with English terms from setup/asr/clips,
# two English made with `say`). CLIPS=all: all eleven Chinese clips, three English ones and four that switch between
# an English and a Chinese sentence, plus each category's character error rate and key terms (setup/asr/bench.py's
# scoring, on round 1's text). Paste is a dry run: the clipboard and every wait up to ⌘V are real, the key events are
# not posted, so nothing is typed into the app in front. The times are read back from each dictation's
# SessionMetric. Prints p50/p95 per step and for the total, and fails unless every History save came after its ⌘V,
# the model loads once per press when it was released first, and a failed paste still lands in History. The dev and
# release apps' settings are never read or written.
set -euo pipefail

APP_DIR="$1"
MODEL="${2:?usage: dictation-latency.sh <app dir> <ggml-*.bin> [rounds] [language] [latency|all]}"
ROUNDS="${3:-12}"
LANGUAGE="${4:-auto}"
CLIPS="${5:-latency}"
case "$CLIPS" in latency | all) ;; *) echo "CLIPS must be latency or all, not $CLIPS"; exit 2 ;; esac
ID=me.sma1lboy.yap.mock
WORK=/tmp/yap-dictation-latency
APP="$WORK/Yap Mock.app"
SUPPORT="$HOME/Library/Application Support/$ID"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

cleanup() {
	defaults delete "$ID" >/dev/null 2>&1 || true
	while security delete-generic-password -s "$ID" >/dev/null 2>&1; do :; done
	rm -rf "$SUPPORT" "$HOME/Library/Caches/$ID" "$HOME/Library/HTTPStorages/$ID" \
		"$HOME/Library/Saved Application State/$ID.savedState" "$HOME/Library/WebKit/$ID"
}
trap 'cleanup; rm -rf "$WORK"' EXIT

rm -rf "$WORK" && mkdir -p "$WORK/config/yap" "$WORK/clips"
ditto "$APP_DIR/VoiceInk Dev.app" "$APP"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $ID" -c "Set :CFBundleName Yap Mock" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Delete :CFBundleURLTypes" "$APP/Contents/Info.plist" 2>/dev/null || true
codesign --force --deep --sign - "$APP" >/dev/null 2>&1

# English clips: the text `say` speaks, with the key terms marked as in setup/asr/clips.json.
english() {
	case "$1" in
	review) echo "Can you review the [pull request] before lunch? The [migration] renames two columns, so the [dashboard] query needs the new names." ;;
	standup) echo "Yesterday I fixed the login timeout on [Safari]. Today I'm moving the billing page to the new [API] and writing tests for the [retry] logic." ;;
	infra) echo "After the [Kubernetes] upgrade two [pods] keep crashing, because the [ConfigMap] path changed and the [Helm] chart still points at the old one." ;;
	short) echo "Sounds good, let's ship it." ;;
	esac
}
zh_clips="security standup perf"
en_clips="review standup"
if [ "$CLIPS" = all ]; then
	zh_clips="security standup perf deploy bug meeting ml frontend infra product email"
	en_clips="review standup infra"
fi
for c in $zh_clips; do
	afconvert -f WAVE -d LEI16@16000 -c 1 "$ROOT/setup/asr/clips/$c.m4a" "$WORK/clips/zh-$c.wav"
done
for c in $en_clips $([ "$CLIPS" = all ] && echo short); do
	english "$c" >"$WORK/clips/en-$c.ref"
	sed -E 's/\[([^]|]*)[^]]*\]/\1/g' "$WORK/clips/en-$c.ref" >"$WORK/clips/en-$c.txt"
	say -v Samantha -o "$WORK/clips/en-$c.aiff" -f "$WORK/clips/en-$c.txt"
	afconvert -f WAVE -d LEI16@16000 -c 1 "$WORK/clips/en-$c.aiff" "$WORK/clips/en-$c.wav"
done
# Code-switched: a whole English sentence and a whole Chinese one, 0.5 s apart. Three are 13–16 s, long enough for
# the app to split the recording by language (LibWhisper.languagePieces); mix-short (7 s) isn't.
mixes="mix-en-zh:en-review,zh-security mix-zh-en:zh-security,en-review mix-en-zh2:en-standup,zh-standup mix-short:en-short,zh-perf"
[ "$CLIPS" = all ] || mixes=""
for m in $mixes; do
	python3 - "$WORK/clips" "${m%%:*}" "${m#*:}" <<'PY'
import sys, wave
folder, name, parts = sys.argv[1], sys.argv[2], sys.argv[3].split(",")
with wave.open(f"{folder}/{name}.wav", "wb") as out:
    out.setnchannels(1); out.setsampwidth(2); out.setframerate(16000)
    for i, part in enumerate(parts):
        if i:
            out.writeframes(b"\0\0" * 8000)
        with wave.open(f"{folder}/{part}.wav") as w:
            out.writeframes(w.readframes(w.getnframes()))
PY
	echo "${m#*:}" >"$WORK/clips/${m%%:*}.parts"
done
clips=()
for c in $zh_clips; do clips+=(--dictate-file "$WORK/clips/zh-$c.wav"); done
for c in $en_clips; do clips+=(--dictate-file "$WORK/clips/en-$c.wav"); done
for m in $mixes; do clips+=(--dictate-file "$WORK/clips/${m%%:*}.wav"); done

cleanup
mkdir -p "$SUPPORT/WhisperModels"
cp -c "$MODEL" "$SUPPORT/WhisperModels/" 2>/dev/null || cp "$MODEL" "$SUPPORT/WhisperModels/"
defaults write "$ID" hasCompletedOnboardingV2 -bool true
cat >"$WORK/config/yap/config.json" <<EOF
{ "modes": [ { "id": "0FF11E00-0000-4000-8000-000000000003", "name": "Latency", "isDefault": true,
    "selectedTranscriptionModelName": "$(basename "$MODEL" .bin)", "selectedLanguage": "$LANGUAGE", "isAIEnhancementEnabled": false,
    "useClipboardContext": false, "useSelectedTextContext": false, "useScreenCapture": false } ] }
EOF

echo "$(sysctl -n hw.model), $(sysctl -n machdep.cpu.brand_string), $(($(sysctl -n hw.memsize) / 1073741824)) GB," \
	"macOS $(sw_vers -productVersion), $(basename "$MODEL"), language $LANGUAGE, $ROUNDS rounds × $((${#clips[@]} / 2)) clips"
XDG_CONFIG_HOME="$WORK/config" "$APP/Contents/MacOS/VoiceInk Dev" --dictation-latency "$ROUNDS" "${clips[@]}" \
	>"$WORK/out.txt" 2>"$WORK/err.txt" || { echo "app exited with $?:"; grep -v '^\s*$' "$WORK/err.txt" | tail -5; exit 1; }

python3 - "$WORK/out.txt" "$WORK/clips" "$ROOT/setup/asr" <<'PY'
import json, os, re, sys
sys.path.insert(0, sys.argv[3])
import bench  # setup/asr's key-term scoring
rows = [json.loads(l.split(": ", 1)[1]) for l in open(sys.argv[1]) if l.startswith("dictation-latency: ")]
loads = [r for r in rows if "loads" in r]  # model released first: one load from the press to the paste
failed = [r for r in rows if "inHistory" in r]  # a paste that fails
rows = [r for r in rows if "loads" not in r and "inHistory" not in r]
if not rows:
    sys.exit("FAIL: no dictations reported")
steps = ["recorderStopped", "modelReady", "transcribed", "processed", "enhanced", "pasteCommand"]
names = {"recorderStopped": "recorder stop", "modelReady": "model load",
         "transcribed": "→ transcribed (reads the WAV, decodes)", "processed": "→ filters and replacements done",
         "enhanced": "→ AI cleanup", "pasteCommand": "→ ⌘V (sound, panel, clipboard, waits)"}
bad = [r for r in rows + loads if r.get("status") != "completed" or r.get("pasteOutcome") != "pasted" or "pasteCommand" not in r]
if bad:
    sys.exit(f"FAIL: {len(bad)} dictation(s) without a paste time: {bad[0]}")
if len(loads) != 6 or any(r["loads"] != 1 for r in loads):
    sys.exit(f"FAIL: the model must load once per press, got {[(r['clip'], r.get('loads')) for r in loads]}")
early = [r for r in rows + loads if not r.get("savedAfterPaste", -1) >= 0]
if early:
    sys.exit(f"FAIL: History saved before ⌘V: {early[0]}")
if len(failed) != 1 or failed[0].get("pasteOutcome") != "failed" or not failed[0]["inHistory"]:
    sys.exit(f"FAIL: a failed paste must still be saved to History: {failed}")

def pct(values, p):  # nearest rank
    values = sorted(values)
    return values[min(len(values), max(1, -(-p * len(values) // 100))) - 1]

def stages(r):  # each step from the previous one that happened, as DictationTimeline.stages
    out, previous = {}, 0.0
    for s in steps:
        if s in r:
            out[s] = r[s] - previous
            previous = r[s]
    return out

for r in rows:
    st = stages(r)
    assert all(v >= 0 for v in st.values()), f"negative step: {r}"
    assert abs(sum(st.values()) - r["pasteCommand"]) < 1e-6, f"steps don't add up: {r}"
    if r["round"] == 1:
        recorded = f" [{r['languages']}]" if "languages" in r else ""
        print(f"  {r['clip']}: {r['audio']:.1f} s audio{recorded} → {r['text']}")

print(f"\n{len(rows)} dictations, stop source {sorted({r['stopSource'] for r in rows})}, "
      f"waited for a model load: {sum('modelReady' in r for r in rows)}\n")
print("| step | n | p50 ms | p95 ms |")
print("|---|---|---|---|")
for s in steps:
    values = [stages(r)[s] * 1000 for r in rows if s in r]
    if values:
        print(f"| {names[s]} | {len(values)} | {pct(values, 50):.0f} | {pct(values, 95):.0f} |")
categories = [("Chinese clips", "zh-"), ("English clips", "en-"), ("code-switched clips", "mix-")]
for label, subset in [("total, stop → ⌘V", rows)] + [(l, [r for r in rows if r["clip"].startswith(p)]) for l, p in categories]:
    values = [r["pasteCommand"] * 1000 for r in subset]
    if values:
        print(f"| **{label}** | {len(values)} | {pct(values, 50):.0f} | {pct(values, 95):.0f} |")
# With language auto, what the SessionMetric recorded (SessionMetric.detectedLanguages, languageDetectionDuration).
detections = [r["languageDetection"] * 1000 for r in rows if "languageDetection" in r]
if detections:
    print(f"| language detection (recorded) | {len(detections)} | {pct(detections, 50):.0f} | {pct(detections, 95):.0f} |")
recorded = sum("languages" in r for r in rows)
print(f"\nLanguage recorded on {recorded} of {len(rows)} dictations")

# Accuracy of round 1's text: character error rate (letters, digits and CJK characters; case, spaces and
# punctuation ignored) and key terms (bench.hits), against the text each clip says.
folder = sys.argv[2]
zh = {c["id"]: c["text"] for c in json.load(open(os.path.join(sys.argv[3], "clips.json")))}
def reference(clip):  # marked text, as in clips.json
    if clip.startswith("zh-"):
        return zh[clip[3:]]
    if clip.startswith("en-"):
        return open(f"{folder}/{clip}.ref").read().strip()
    return " ".join(reference(part) for part in open(f"{folder}/{clip}.parts").read().strip().split(","))
def chars(text):
    return re.sub(r"[\W_]+", "", text.lower())
def edits(a, b):
    previous = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        current = [i]
        for j, y in enumerate(b, 1):
            current.append(min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (x != y)))
        previous = current
    return previous[-1]
first = [r for r in rows if r["round"] == 1]
print("\n| clips | n | character error rate | key terms |")
print("|---|---|---|---|")
for label, prefix in categories:
    subset = [r for r in first if r["clip"].startswith(prefix)]
    if not subset:
        continue
    wrong = sum(edits(chars(bench.spoken(reference(r["clip"]))), chars(r["text"])) for r in subset)
    total = sum(len(chars(bench.spoken(reference(r["clip"])))) for r in subset)
    found = [h for r in subset for h in bench.hits({"keywords": bench.keywords(reference(r["clip"]))}, r["text"])]
    print(f"| {label} | {len(subset)} | {wrong / total:.1%} ({wrong}/{total}) | {sum(found)}/{len(found)} |")
print("\nModel released before the press (Keep model loaded: After Each Dictation); one load each:")
for r in loads:
    ready = f"waited {r['modelReady'] * 1000:.0f} ms for it" if "modelReady" in r else "loaded before the stop"
    print(f"  {r['clip']} {r['round']}: {r['loads']} load, {ready}, ⌘V at {r['pasteCommand'] * 1000:.0f} ms")
saved = [r["savedAfterPaste"] * 1000 for r in rows]
print(f"\nHistory saved after ⌘V in every dictation: p50 {pct(saved, 50):.0f} ms, p95 {pct(saved, 95):.0f} ms later")
print(f"Paste failed: outcome {failed[0]['pasteOutcome']}, in History: {failed[0]['inHistory']}")
PY
