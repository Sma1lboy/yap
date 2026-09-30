#!/bin/bash
# make meeting-files-check MODEL=<ggml-*.bin> [NOTES=1]: a meeting recording from two local files, end to end
# (chunking, transcription with the mode's local Whisper model, notes, History entry, files), no microphone or
# system audio permission needed. Uses the Debug app re-identified as me.sma1lboy.yap.mock as a fresh install
# (see scripts/mock.sh) and launches it with --meeting-files (MeetingFilesCheck.swift).
# The test meeting is built from setup/asr/clips: the Tingting clips are "me" (microphone), the Reed clips are
# "others" (system audio), taking turns with silence on the other channel, about a minute in all.
# NOTES=1 writes notes with OpenRouter (deepseek-v4.1-flash; OPENROUTER_API_KEY from the environment or ~/.env,
# passed only to the mock app as YAP_MOCK_API_KEY_OPENROUTER); without it the mode has no AI provider and the run
# checks the transcript-only path.
set -euo pipefail

APP_DIR="$1"
MODEL="${2:?usage: meeting-files-check.sh <app dir> <ggml-*.bin> [notes]}"
NOTES="${3:-}"
ID=me.sma1lboy.yap.mock
WORK=/tmp/yap-meeting-check
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
cleanup
rm -rf "$WORK" && mkdir -p "$WORK/config/yap" "$WORK/clips" "$SUPPORT/WhisperModels"

ditto "$APP_DIR/VoiceInk Dev.app" "$APP"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $ID" -c "Set :CFBundleName Yap Mock" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Delete :CFBundleURLTypes" "$APP/Contents/Info.plist" 2>/dev/null || true
codesign --force --deep --sign - "$APP" >/dev/null 2>&1
cp -c "$MODEL" "$SUPPORT/WhisperModels/" 2>/dev/null || cp "$MODEL" "$SUPPORT/WhisperModels/"
defaults write "$ID" hasCompletedOnboardingV2 -bool true

for clip in deploy bug perf standup meeting infra; do
	afconvert -f WAVE -d LEI16@16000 -c 1 "$ROOT/setup/asr/clips/$clip.m4a" "$WORK/clips/$clip.wav"
done
# A second remote voice (Shelley) speaks twice, so "others" holds two people: Reed (A) and Shelley (B).
say -v "Shelley (Chinese (China mainland))" -r 230 -o "$WORK/clips/b1.aiff" "我补充一点，[Kubernetes] 那边的 rollout 我已经在测试环境跑过了，没有问题。"
say -v "Shelley (Chinese (China mainland))" -r 230 -o "$WORK/clips/b2.aiff" "我这边的排期是下周三，需要 design 先确认一下 API 的字段。"
for clip in b1 b2; do afconvert -f WAVE -d LEI16@16000 -c 1 "$WORK/clips/$clip.aiff" "$WORK/clips/$clip.wav"; done
python3 - "$WORK" <<'PY'
import sys, wave
work = sys.argv[1]
def frames(name):
    with wave.open(f"{work}/clips/{name}.wav") as w:
        return w.readframes(w.getnframes())
silence = lambda seconds: b"\0\0" * int(16000 * seconds)
mic, system, truth = b"", b"", []
# Tingting (me) and the remote voices take turns, one second apart: me, then A (Reed) or B (Shelley).
for who, me_clip, other_clip in [("A", "deploy", "standup"), ("B", "bug", "b1"), ("A", "perf", "infra"), ("B", "meeting", "b2")]:
    a, b = frames(me_clip), frames(other_clip)
    start = len(system) / 32000 + len(a) / 32000 + 1
    truth.append(f"{who} {start:.1f} {start + len(b) / 32000:.1f}")
    mic += a + silence(1) + silence(len(b) / 32000) + silence(1)
    system += silence(len(a) / 32000) + silence(1) + b + silence(1)
for name, data in [("mic", mic), ("system", system)]:
    with wave.open(f"{work}/{name}.wav", "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000); w.writeframes(data)
open(f"{work}/truth.txt", "w").write("\n".join(truth) + "\n")
print(f"test meeting: {len(mic) / 32000:.1f} s per channel")
PY

model=$(basename "$MODEL" .bin)
if [ -n "$NOTES" ]; then
	key="${OPENROUTER_API_KEY:-$(sed -n 's/^OPENROUTER_API_KEY=//p' "$HOME/.env" 2>/dev/null | tr -d '"' | head -1)}"
	[ -n "$key" ] || { echo "NOTES=1 needs OPENROUTER_API_KEY (environment or ~/.env)"; exit 2; }
	export YAP_MOCK_API_KEY_OPENROUTER="$key"
	ai='"isAIEnhancementEnabled": true, "selectedAIProvider": "OpenRouter", "selectedAIModel": "deepseek/deepseek-v4.1-flash",'
else
	ai='"isAIEnhancementEnabled": false,'
fi
cat >"$WORK/config/yap/config.json" <<EOF
{ "modes": [ { "id": "0FF11E00-0000-4000-8000-000000000002", "name": "Meeting check", "isDefault": true,
    "selectedTranscriptionModelName": "$model", "selectedLanguage": "auto", $ai
    "useClipboardContext": false, "useSelectedTextContext": false, "useScreenCapture": false } ] }
EOF

XDG_CONFIG_HOME="$WORK/config" "$APP/Contents/MacOS/VoiceInk Dev" --meeting-files "$WORK/mic.wav" "$WORK/system.wav" \
	>"$WORK/out.txt" 2>"$WORK/err.txt" || { echo "app exited with $?"; grep -v '^\s*$' "$WORK/err.txt" | tail -5; exit 1; }
sed -n '/^meeting-check: /,$p' "$WORK/out.txt" | grep -v '^\[.*\] *$' | grep -v "^ggml_\|^whisper_" | sed 's/^meeting-check: //'
grep -q '^meeting-check: transcript-begin' "$WORK/out.txt" || { echo "FAIL: no result"; exit 1; }
if [ -n "$NOTES" ] && grep -q '^meeting-check: notes-begin$' "$WORK/out.txt" \
	&& [ "$(sed -n '/^meeting-check: notes-begin$/,/^meeting-check: notes-end$/p' "$WORK/out.txt" | wc -l)" -le 2 ]; then
	echo "FAIL: NOTES=1 but no notes"
	exit 1
fi

# Speaker labels: every remote line must sit in a truth interval (A or B), and one label must map to one voice.
python3 - "$WORK" <<'PY'
import re, sys
work = sys.argv[1]
truth = [(l.split()[0], float(l.split()[1]), float(l.split()[2])) for l in open(f"{work}/truth.txt")]
seen, bad = {}, 0
for line in open(f"{work}/out.txt"):
    m = re.match(r"\[(?:(\d+):)?(\d+):(\d+)\] [^:]*?(\d+): ", line.removeprefix("meeting-check: ")) if "Others" in line or "对方" in line else None
    if not m: continue
    t = int(m.group(1) or 0) * 3600 + int(m.group(2)) * 60 + int(m.group(3))
    voice = next((w for w, s, e in truth if s - 2 <= t <= e), "?")
    label = m.group(4)
    if seen.setdefault(label, voice) != voice or voice == "?": bad += 1
    print(f"labels: {t}s voice {voice} -> Others {label}")
labels = {l: v for l, v in seen.items()}
ok = bad == 0 and len(set(labels.values())) == 2 == len(labels)
print("labels:", "OK" if ok else f"FAIL ({bad} lines off, mapping {labels})")
sys.exit(0 if ok else 1)
PY
