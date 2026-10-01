#!/bin/bash
# make dictation-latency MODEL=<path to ggml-*.bin> [ROUNDS=12]: from "the user stopped" to the ⌘V that pastes, per
# step, with a local Whisper model already loaded and AI cleanup off. Same mock identity and fresh install as
# scripts/offline-check.sh (me.sma1lboy.yap.mock: its own defaults, Application Support and keychain), one mode on
# MODEL, language auto. The Debug app is launched with --dictation-latency (DictationLatencyCheck.swift): it dictates
# five clips (three Chinese with English terms from setup/asr/clips, two English made with `say`) ROUNDS times each
# through the normal stop → transcribe → deliver path. Paste is a dry run: the clipboard and every wait up to ⌘V are
# real, the key events are not posted, so nothing is typed into the app in front. The times are read back from each
# dictation's SessionMetric. Prints p50/p95 per step and for the total. The dev and release apps' settings are never
# read or written.
set -euo pipefail

APP_DIR="$1"
MODEL="${2:?usage: dictation-latency.sh <app dir> <ggml-*.bin> [rounds]}"
ROUNDS="${3:-12}"
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

clips=()
for c in security standup perf; do
	afconvert -f WAVE -d LEI16@16000 -c 1 "$ROOT/setup/asr/clips/$c.m4a" "$WORK/clips/zh-$c.wav"
	clips+=(--dictate-file "$WORK/clips/zh-$c.wav")
done
say -v Samantha -o "$WORK/clips/en-review.aiff" \
	"Can you review the pull request before lunch? The migration renames two columns, so the dashboard query needs the new names."
say -v Samantha -o "$WORK/clips/en-standup.aiff" \
	"Yesterday I fixed the login timeout on Safari. Today I'm moving the billing page to the new API and writing tests for the retry logic."
for c in review standup; do
	afconvert -f WAVE -d LEI16@16000 -c 1 "$WORK/clips/en-$c.aiff" "$WORK/clips/en-$c.wav"
	clips+=(--dictate-file "$WORK/clips/en-$c.wav")
done

cleanup
mkdir -p "$SUPPORT/WhisperModels"
cp -c "$MODEL" "$SUPPORT/WhisperModels/" 2>/dev/null || cp "$MODEL" "$SUPPORT/WhisperModels/"
defaults write "$ID" hasCompletedOnboardingV2 -bool true
cat >"$WORK/config/yap/config.json" <<EOF
{ "modes": [ { "id": "0FF11E00-0000-4000-8000-000000000003", "name": "Latency", "isDefault": true,
    "selectedTranscriptionModelName": "$(basename "$MODEL" .bin)", "selectedLanguage": "auto", "isAIEnhancementEnabled": false,
    "useClipboardContext": false, "useSelectedTextContext": false, "useScreenCapture": false } ] }
EOF

echo "$(sysctl -n hw.model), $(sysctl -n machdep.cpu.brand_string), $(($(sysctl -n hw.memsize) / 1073741824)) GB," \
	"macOS $(sw_vers -productVersion), $(basename "$MODEL"), $ROUNDS rounds × $((${#clips[@]} / 2)) clips"
XDG_CONFIG_HOME="$WORK/config" "$APP/Contents/MacOS/VoiceInk Dev" --dictation-latency "$ROUNDS" "${clips[@]}" \
	>"$WORK/out.txt" 2>"$WORK/err.txt" || { echo "app exited with $?:"; grep -v '^\s*$' "$WORK/err.txt" | tail -5; exit 1; }

python3 - "$WORK/out.txt" <<'PY'
import json, sys
rows = [json.loads(l.split(": ", 1)[1]) for l in open(sys.argv[1]) if l.startswith("dictation-latency: ")]
if not rows:
    sys.exit("FAIL: no dictations reported")
steps = ["recorderStopped", "modelReady", "transcribed", "processed", "enhanced", "pasteCommand"]
names = {"recorderStopped": "recorder stop", "modelReady": "model load",
         "transcribed": "→ transcribed (reads the WAV, decodes)", "processed": "→ filters and replacements done",
         "enhanced": "→ AI cleanup", "pasteCommand": "→ ⌘V (sound, panel, clipboard, waits)"}
bad = [r for r in rows if r.get("status") != "completed" or r.get("pasteOutcome") != "pasted" or "pasteCommand" not in r]
if bad:
    sys.exit(f"FAIL: {len(bad)} dictation(s) without a paste time: {bad[0]}")

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
        print(f"  {r['clip']}: {r['audio']:.1f} s audio → {r['text']}")

print(f"\n{len(rows)} dictations, stop source {sorted({r['stopSource'] for r in rows})}, "
      f"model loads inside the dictation: {sum('modelReady' in r for r in rows)}\n")
print("| step | n | p50 ms | p95 ms |")
print("|---|---|---|---|")
for s in steps:
    values = [stages(r)[s] * 1000 for r in rows if s in r]
    if values:
        print(f"| {names[s]} | {len(values)} | {pct(values, 50):.0f} | {pct(values, 95):.0f} |")
for label, subset in [("total, stop → ⌘V", rows),
                      ("Chinese clips", [r for r in rows if r["clip"].startswith("zh-")]),
                      ("English clips", [r for r in rows if r["clip"].startswith("en-")])]:
    values = [r["pasteCommand"] * 1000 for r in subset]
    if values:
        print(f"| **{label}** | {len(values)} | {pct(values, 50):.0f} | {pct(values, 95):.0f} |")
PY
