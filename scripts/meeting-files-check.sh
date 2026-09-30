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
# The run also fails its first piece (--meeting-fail-pieces 1) and the save of its History entry
# (--meeting-fail-save): the transcript must keep one marked line for the piece. Then a meeting folder cut off by
# a crash (no History entry, WAV headers never finished) is put next to it, and the app is launched twice with
# --meeting-recovery-check: the first launch must recover both folders as meetings, the second nothing.
# Last, --meeting-edit-check names the speakers of the recovered meetings (Me → Tingting, Others 1 → Reed,
# Others 2 → Shelley; and Others → Reed on a segments.json in the old format, without speaker numbers) and
# regenerates the notes: once with a failure (no AI provider, or with NOTES=1 an injected failed request), which must
# keep the old notes, and with NOTES=1 once more, which must replace them with a prompt that has the names.
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
	--meeting-fail-pieces 1 --meeting-fail-save \
	>"$WORK/out.txt" 2>"$WORK/err.txt" || { echo "app exited with $?"; grep -v '^\s*$' "$WORK/err.txt" | tail -5; exit 1; }
sed -n '/^meeting-check: /,$p' "$WORK/out.txt" | grep -v '^\[.*\] *$' | grep -v "^ggml_\|^whisper_" | sed 's/^meeting-check: //'
grep -q '^meeting-check: transcript-begin' "$WORK/out.txt" || { echo "FAIL: no result"; exit 1; }
if [ -n "$NOTES" ] && grep -q '^meeting-check: notes-begin$' "$WORK/out.txt" \
	&& [ "$(sed -n '/^meeting-check: notes-begin$/,/^meeting-check: notes-end$/p' "$WORK/out.txt" | wc -l)" -le 2 ]; then
	echo "FAIL: NOTES=1 but no notes"
	exit 1
fi

# Speaker labels, from segments.json: a remote piece takes the voice that speaks most in it (truth.txt), and one
# label must map to one voice (a piece of 20-28 s can hold both voices; the longer speaker wins).
python3 - "$WORK" <<'PY'
import json, re, sys
work = sys.argv[1]
truth = [(l.split()[0], float(l.split()[1]), float(l.split()[2])) for l in open(f"{work}/truth.txt")]
folder = next(l.split(" ", 2)[2].strip() for l in open(f"{work}/out.txt") if l.startswith("meeting-check: folder "))
seen, bad = {}, 0
for seg in json.load(open(f"{folder}/segments.json")):
    if seg["speaker"] != "others" or seg.get("failed"): continue
    overlap = {}
    for who, s, e in truth:
        overlap[who] = overlap.get(who, 0) + max(0, min(e, seg["end"]) - max(s, seg["start"]))
    voice = max(overlap, key=overlap.get)
    label = seg.get("remote")
    print(f"labels: {seg['start']:.0f}-{seg['end']:.0f}s voice {voice} -> Others {label}")
    if label is None or seen.setdefault(label, voice) != voice: bad += 1
ok = bad == 0 and sorted(seen.values()) == ["A", "B"]
print("labels:", "OK" if ok else f"FAIL ({bad} pieces off, mapping {seen})")
sys.exit(0 if ok else 1)
PY

# The failed piece: one marked line in the transcript, counted in the result; the save failed as asked.
marker=$(sed -n 's/^meeting-check: failed-marker //p' "$WORK/out.txt")
marked=$(sed -n '/^meeting-check: transcript-begin$/,/^meeting-check: transcript-end$/p' "$WORK/out.txt" | grep -cF -- "$marker" || true)
echo "failed pieces: $(sed -n 's/^meeting-check: failed-pieces //p' "$WORK/out.txt"), marked lines: $marked"
[ "$marked" = 1 ] && grep -q '^meeting-check: failed-pieces 1$' "$WORK/out.txt" || { echo "FAIL: failed piece not marked once"; exit 1; }
grep -q '^meeting-check: save-error none$' "$WORK/out.txt" && { echo "FAIL: --meeting-fail-save didn't fail the save"; exit 1; }

# Recovery. A crashed recording: both channels with the WAV sizes still 0, a leftover pieces folder, no entry.
unsaved=$(sed -n 's/^meeting-check: folder //p' "$WORK/out.txt")
crashed="$(dirname "$unsaved")/$(uuidgen)"
mkdir -p "$crashed/pieces"
python3 - "$WORK" "$crashed" <<'PY'
import sys
work, folder = sys.argv[1], sys.argv[2]
for name in ["mic", "system"]:
    data = bytearray(open(f"{work}/{name}.wav", "rb").read())
    data[4:8] = data[40:44] = b"\0\0\0\0"
    open(f"{folder}/{name}.wav", "wb").write(data)
PY
for run in 1 2; do
	XDG_CONFIG_HOME="$WORK/config" "$APP/Contents/MacOS/VoiceInk Dev" --meeting-recovery-check \
		>"$WORK/recovery$run.txt" 2>>"$WORK/err.txt" || { echo "app exited with $?"; exit 1; }
	sed -n '/^meeting-check: /,$p' "$WORK/recovery$run.txt" | grep -v '^\[.*\] *$' | grep -v "^ggml_\|^whisper_\| --> " \
		| sed "s/^meeting-check: /recovery $run: /"
done
grep -q '^meeting-check: recovered 2$' "$WORK/recovery1.txt" || { echo "FAIL: expected 2 recovered meetings"; exit 1; }
for folder in "$unsaved" "$crashed"; do
	name=$(basename "$folder")
	grep -q "^meeting-check: recovered-folder $name$" "$WORK/recovery1.txt" || { echo "FAIL: $name not recovered"; exit 1; }
	ls "$folder" | tr '\n' ' ' | sed "s/^/recovered files $name: /"; echo
	[ -f "$folder/mix.wav" ] && [ -f "$folder/segments.json" ] && [ ! -e "$folder/mic.wav.orig" ] && [ ! -e "$folder/pieces" ] \
		|| { echo "FAIL: $name's folder isn't a finished meeting"; exit 1; }
done
[ "$(grep -c '^meeting-check: audio-only false save-error none failed-pieces 0$' "$WORK/recovery1.txt")" = 2 ] \
	|| { echo "FAIL: recovered meetings weren't transcribed and saved"; exit 1; }
[ "$(sed -n '/^meeting-check: transcript-begin$/,/^meeting-check: transcript-end$/p' "$WORK/recovery1.txt" | grep -c '^\[')" -ge 8 ] \
	|| { echo "FAIL: recovered transcripts are empty"; exit 1; }
grep -q '^meeting-check: recovered 0$' "$WORK/recovery2.txt" || { echo "FAIL: the second launch recovered again"; exit 1; }

# A folder whose recovery was cut off last time (it's in the attempted list, its originals moved aside) is saved
# with its audio only instead of being tried again.
cut="$(dirname "$unsaved")/$(uuidgen)"
mkdir -p "$cut"
cp "$WORK/mic.wav" "$cut/mic.wav.orig"
cp "$WORK/system.wav" "$cut/system.wav"
defaults write "$ID" RecoveryAttemptedMeetings -array "$(basename "$cut")"
XDG_CONFIG_HOME="$WORK/config" "$APP/Contents/MacOS/VoiceInk Dev" --meeting-recovery-check \
	>"$WORK/recovery3.txt" 2>>"$WORK/err.txt" || { echo "app exited with $?"; exit 1; }
sed -n '/^meeting-check: /,$p' "$WORK/recovery3.txt" | grep -v "^ggml_\|^whisper_\| --> " | sed "s/^meeting-check: /recovery 3: /"
grep -q '^meeting-check: recovered 1$' "$WORK/recovery3.txt" && grep -q '^meeting-check: audio-only true save-error none' "$WORK/recovery3.txt" \
	&& [ -s "$cut/mix.wav" ] && [ -f "$cut/mic.wav" ] && [ ! -e "$cut/mic.wav.orig" ] \
	|| { echo "FAIL: the cut-off recovery wasn't saved with its audio"; exit 1; }
echo "recovery: OK"

# Speaker names and regenerating the notes, on the two recovered meetings.
edit() {
	XDG_CONFIG_HOME="$WORK/config" "$APP/Contents/MacOS/VoiceInk Dev" --meeting-edit-check "$@" \
		>"$WORK/edit.txt" 2>>"$WORK/err.txt" || { echo "app exited with $?"; sed -n 's/^meeting-check: //p' "$WORK/edit.txt"; exit 1; }
	sed -n '/^meeting-check: /,$p' "$WORK/edit.txt" | grep -v "^ggml_\|^whisper_\| --> " | sed "s/^meeting-check: /edit: /"
}
block() { sed -n "/^meeting-check: $1-begin$/,/^meeting-check: $1-end$/p" "$WORK/edit.txt" | sed '1d;$d'; }
cp "$unsaved/segments.json" "$WORK/segments-before.json"
if [ -n "$NOTES" ]; then regenerate=(--meeting-regenerate 2 --meeting-fail-notes 1); else regenerate=(--meeting-regenerate 1); fi
edit "$(basename "$unsaved")" "me=Tingting,others-1=Reed,others-2=Shelley" "${regenerate[@]}"
grep -q "^meeting-check: speakers \[\"me\", \"others-1\", \"others-2\"\]$" "$WORK/edit.txt" \
	|| { echo "FAIL: expected speakers me, others-1, others-2"; exit 1; }
grep -q '^meeting-check: rename-error none$' "$WORK/edit.txt" || { echo "FAIL: renaming wasn't saved"; exit 1; }
cmp -s "$unsaved/segments.json" "$WORK/segments-before.json" || { echo "FAIL: renaming changed segments.json"; exit 1; }
[ "$(block transcript-before | grep -o '^\[[0-9:]*\]')" = "$(block transcript | grep -o '^\[[0-9:]*\]')" ] \
	|| { echo "FAIL: renaming changed the timeline"; exit 1; }
for name in Tingting Reed Shelley; do
	block transcript | grep -q "^\[[0-9:]*\] $name: " || { echo "FAIL: no $name line in the transcript"; exit 1; }
	block markdown | grep -q "^\*\*\[[0-9:]*\] $name\*\*: " || { echo "FAIL: no $name line in the Markdown"; exit 1; }
done
block transcript | grep -q '^\[[0-9:]*\] \(Me\|Others\)' && { echo "FAIL: a default label is left"; exit 1; }
grep -q '^meeting-check: regenerate 1 problem none' "$WORK/edit.txt" && { echo "FAIL: the first regenerate should fail"; exit 1; }
grep -q '^meeting-check: regenerate 1 .* changed false kept true$' "$WORK/edit.txt" \
	|| { echo "FAIL: a failed regenerate changed the notes"; exit 1; }
if [ -n "$NOTES" ]; then
	grep -q '^meeting-check: regenerate 2 problem none changed true kept true$' "$WORK/edit.txt" \
		|| { echo "FAIL: regenerating didn't replace the notes"; exit 1; }
	for name in Tingting Reed Shelley; do
		block prompt | grep -q "\"$name\"" || { echo "FAIL: the notes prompt doesn't name $name"; exit 1; }
	done
fi
echo "names: OK"

# A segments.json from before speaker numbers (no "remote" or "failed" fields): plain Others is renamed.
python3 - "$crashed/segments.json" <<'PY2'
import json, sys
path = sys.argv[1]
segments = [{k: s[k] for k in ("speaker", "start", "end", "text")} for s in json.load(open(path)) if not s.get("failed")]
json.dump(segments, open(path, "w"))
PY2
edit "$(basename "$crashed")" "others=Reed"
grep -q '^meeting-check: speakers \["me", "others"\]$' "$WORK/edit.txt" && grep -q '^meeting-check: rename-error none$' "$WORK/edit.txt" \
	&& block transcript | grep -q '^\[[0-9:]*\] Reed: ' && ! block transcript | grep -q '^\[[0-9:]*\] Others' \
	|| { echo "FAIL: the old segments.json wasn't renamed"; exit 1; }
echo "old segments.json: OK"
