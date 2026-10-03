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
# Saving meetings to a folder automatically is on throughout, into $WORK/archive: every History entry the run saves
# must have its Markdown there, each change a new version, and the failed save none. SPEAKER_CACHE=<folder> reuses
# speaker models kept by an earlier run (see meeting-check-common.sh) instead of downloading them.
# Last, Transcribe Meeting (History's action for a meeting saved with its audio only) through
# --meeting-retranscribe-check, which calls what History's button calls: which entries can be transcribed (audio
# only, from no model and from a cut-off recovery; mix only; recordings gone; transcribed), refused with no model in
# the mode, canceled after 2 piece requests, a failed save, the app killed mid-run, then a successful run and a
# relaunch, and another meeting with its first piece failing. Every run that doesn't finish must leave the entry, its
# mic.wav / system.wav / mix.wav (by SHA-256) and the saved folder as they were; a finished run changes that entry
# only, once, and keeps the recordings byte for byte.
set -euo pipefail

APP_DIR="$1"
MODEL="${2:?usage: meeting-files-check.sh <app dir> <ggml-*.bin> [notes]}"
NOTES="${3:-}"
WORK=/tmp/yap-meeting-check
source "$(dirname "$0")/meeting-check-common.sh"
restore_speaker_models
ARCHIVE="$WORK/archive"
mkdir -p "$ARCHIVE"
defaults write "$ID" meetingAutoArchiveFolder "$ARCHIVE"
defaults write "$ID" meetingAutoArchiveEnabled -bool true

# A second remote voice (Shelley) speaks twice, so "others" holds two people: Reed (A) and Shelley (B).
say_clip b1 "Shelley (Chinese (China mainland))" "我补充一点，[Kubernetes] 那边的 rollout 我已经在测试环境跑过了，没有问题。"
say_clip b2 "Shelley (Chinese (China mainland))" "我这边的排期是下周三，需要 design 先确认一下 API 的字段。"
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

# The save is made to fail, so a meeting saved without its speakers would never get them: wait for them here (the
# background path is meeting-long-check's).
run_app "$WORK/out.txt" --meeting-files "$WORK/mic.wav" "$WORK/system.wav" --meeting-fail-pieces 1 --meeting-fail-save \
	--meeting-speaker-wait 600
show "$WORK/out.txt"
grep -q '^meeting-check: transcript-begin' "$WORK/out.txt" || { echo "FAIL: no result"; exit 1; }
# This meeting has no echo (the microphone is silent while the others speak): no "Me" piece may be taken out.
grep -q '^meeting-check: echo-removed 0$' "$WORK/out.txt" || { echo "FAIL: echo taken out of a meeting without echo"; exit 1; }
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
	run_app "$WORK/recovery$run.txt" --meeting-recovery-check
	show "$WORK/recovery$run.txt" "recovery $run: "
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
run_app "$WORK/recovery3.txt" --meeting-recovery-check
show "$WORK/recovery3.txt" "recovery 3: "
grep -q '^meeting-check: recovered 1$' "$WORK/recovery3.txt" && grep -q '^meeting-check: audio-only true save-error none' "$WORK/recovery3.txt" \
	&& [ -s "$cut/mix.wav" ] && [ -f "$cut/mic.wav" ] && [ ! -e "$cut/mic.wav.orig" ] \
	|| { echo "FAIL: the cut-off recovery wasn't saved with its audio"; exit 1; }
echo "recovery: OK"

# Speaker names and regenerating the notes, on the two recovered meetings.
edit() {
	run_app "$WORK/edit.txt" --meeting-edit-check "$@"
	show "$WORK/edit.txt" "edit: "
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

# Saved to the folder automatically: nothing for the failed save; one file for each of the three meetings recovered
# (two transcribed, one audio only), and a new version for each of the two renames (the failed regenerate added
# nothing). File names carry the History entry's id, not the recording folder's, so versions are counted per id.
speaker_models_source "$WORK/err.txt"
python3 - "$ARCHIVE" <<'PY3'
import collections, os, re, sys
files = sorted(os.listdir(sys.argv[1]))
for f in files:
    print("archived: %s" % f)
per = collections.Counter(re.search(r"meeting-([0-9a-f-]{36})-", f).group(1) for f in files if f.endswith(".md"))
print("archive: %d files, versions per meeting %s" % (len(files), sorted(per.values())))
sys.exit(0 if sorted(per.values()) == [1, 2, 2] and len(files) == 5 else 1)
PY3
echo "auto-archive: OK"

# Transcribe Meeting. More audio-only meetings, saved by recovery with no transcription model in the mode: one stays,
# one keeps only its mix, one loses its folder.
meetings="$(dirname "$unsaved")"
for name in nomodel mixonly gone; do
	folder="$meetings/$(uuidgen)"
	mkdir -p "$folder"
	cp "$WORK/mic.wav" "$folder/mic.wav" && cp "$WORK/system.wav" "$folder/system.wav"
	eval "$name=\$folder"
	sleep 1  # recovery goes oldest first, by the folder's creation time
done
mkdir -p "$WORK/config-nomodel/yap"
sed 's/"selectedTranscriptionModelName": "[^"]*",//' "$WORK/config/yap/config.json" >"$WORK/config-nomodel/yap/config.json"
CONFIG_HOME="$WORK/config-nomodel" run_app "$WORK/rt-nomodel.txt" --meeting-retranscribe-check "$(basename "$nomodel")"
show "$WORK/rt-nomodel.txt" "transcribe meeting, no model: "
for folder in "$nomodel" "$mixonly" "$gone" "$cut"; do
	grep -q "^meeting-check: eligibility $(basename "$folder") .* eligible mic=mic.wav system=system.wav$" "$WORK/rt-nomodel.txt" \
		|| { echo "FAIL: audio-only meeting $(basename "$folder") isn't eligible"; exit 1; }
done
for folder in "$unsaved" "$crashed"; do
	grep -q "^meeting-check: eligibility $(basename "$folder") .* transcribed$" "$WORK/rt-nomodel.txt" \
		|| { echo "FAIL: transcribed meeting $(basename "$folder") is offered again"; exit 1; }
done
# Refused before anything runs: the app quits right there, with no piece requested (no "requests" line at all).
grep -q '^meeting-check: retranscribe refused no-model; running false$' "$WORK/rt-nomodel.txt" \
	&& ! grep -q '^meeting-check: requests' "$WORK/rt-nomodel.txt" \
	|| { echo "FAIL: started without a model"; exit 1; }
rm "$mixonly/mic.wav" "$mixonly/system.wav"
rm -rf "$gone"

# The meeting whose recovery was cut off is the one transcribed. Its recordings, and the saved folder, must stay
# exactly as they are until a run succeeds.
target=$(basename "$cut")
sums() { (cd "$cut" && shasum -a 256 mic.wav system.wav mix.wav); }
sums >"$WORK/sums-before.txt"
archived() { ls "$ARCHIVE" | grep -ci "$1" || true; }  # file names have the id in lower case
id=$(sed -n "s/^meeting-check: eligibility $target \([0-9A-F-]*\) .*/\1/p" "$WORK/rt-nomodel.txt")
files_in_archive() { ls "$ARCHIVE" | wc -l | tr -d ' '; }
archive_before=$(files_in_archive)
work_root="$SUPPORT/MeetingRetranscription"
unchanged() {  # <output file> <case>
	block_of() { sed -n "/^meeting-check: $1-text-begin$/,/^meeting-check: $1-text-end$/p" "$2" | sed '1d;$d'; }
	grep -q "^meeting-check: after id $id .* status failed failed-pieces 0 model none " "$1" \
		&& [ "$(block_of before "$1")" = "$(block_of after "$1")" ] && sums | cmp -s - "$WORK/sums-before.txt" \
		&& [ ! -e "$cut/segments.json" ] && [ ! -e "$work_root/$id" ] && [ "$(files_in_archive)" = "$archive_before" ] \
		&& grep -q "^meeting-check: entries-after 6$" "$1" \
		|| { echo "FAIL: $2 changed the meeting, its files or the saved folder"; exit 1; }
}
requests() { sed -n 's/^meeting-check: requests //p' "$1"; }

# Started twice, canceled right after the second piece's request: one run, no further requests, nothing saved.
run_app "$WORK/rt-cancel.txt" --meeting-retranscribe-check "$target" --meeting-retranscribe-twice --meeting-retranscribe-cancel-after 2
show "$WORK/rt-cancel.txt" "transcribe meeting, canceled: "
grep -q "^meeting-check: eligibility $(basename "$mixonly") .* mix-only$" "$WORK/rt-cancel.txt" \
	&& grep -q "^meeting-check: eligibility $(basename "$gone") .* audio-gone$" "$WORK/rt-cancel.txt" \
	|| { echo "FAIL: mix-only / recordings gone not told apart"; exit 1; }
grep -q '^meeting-check: retranscribe again same run running true$' "$WORK/rt-cancel.txt" \
	&& grep -q '^meeting-check: retranscribe outcome canceled$' "$WORK/rt-cancel.txt" && [ "$(requests "$WORK/rt-cancel.txt")" = 2 ] \
	|| { echo "FAIL: cancel (or the second click) didn't stop at 2 requests"; exit 1; }
unchanged "$WORK/rt-cancel.txt" "a canceled run"

# The entry's save fails: every piece was transcribed, nothing is kept.
run_app "$WORK/rt-fail.txt" --meeting-retranscribe-check "$target" --meeting-fail-save
show "$WORK/rt-fail.txt" "transcribe meeting, save fails: "
full=$(requests "$WORK/rt-fail.txt")
grep -q '^meeting-check: retranscribe outcome failed ' "$WORK/rt-fail.txt" && [ "$full" -ge 4 ] \
	|| { echo "FAIL: a failed save wasn't reported"; exit 1; }
unchanged "$WORK/rt-fail.txt" "a failed save"

# Killed after the third piece's request, as a crash or a forced quit: its work folder is left; the next launch
# removes it, recovers nothing and transcribes nothing by itself.
XDG_CONFIG_HOME="$WORK/config" "$APP/Contents/MacOS/VoiceInk Dev" --meeting-retranscribe-check "$target" \
	--meeting-retranscribe-kill-after 3 >"$WORK/rt-kill.txt" 2>>"$WORK/err.txt" || true
grep -q '^meeting-check: killed after 3 requests$' "$WORK/rt-kill.txt" && [ -d "$work_root/$id" ] \
	|| { echo "FAIL: the run wasn't killed mid-way"; exit 1; }
run_app "$WORK/rt-relaunch.txt" --meeting-recovery-check
show "$WORK/rt-relaunch.txt" "after the kill: "
grep -q '^meeting-check: recovered 0$' "$WORK/rt-relaunch.txt" && [ ! -e "$work_root" ] && sums | cmp -s - "$WORK/sums-before.txt" \
	&& [ ! -e "$cut/segments.json" ] && [ "$(files_in_archive)" = "$archive_before" ] \
	|| { echo "FAIL: the killed run left something behind or was picked up"; exit 1; }
echo "transcribe meeting, canceled / failed save / killed: OK (requests 2 / $full / 3, entry and files unchanged)"

# Transcribed: the same entry (id, date, audio) gets a timestamped transcript with both speakers and segments.json;
# its recordings stay byte for byte; saving to a folder writes one new file for it.
run_app "$WORK/rt-done.txt" --meeting-retranscribe-check "$target"
show "$WORK/rt-done.txt" "transcribe meeting: "
before=$(sed -n "s/^meeting-check: before id $id timestamp \([0-9.]*\) .* audio \(.*\)$/\1 \2/p" "$WORK/rt-done.txt")
after=$(sed -n "s/^meeting-check: after id $id timestamp \([0-9.]*\) .* audio \(.*\)$/\1 \2/p" "$WORK/rt-done.txt")
text=$(sed -n '/^meeting-check: after-text-begin$/,/^meeting-check: after-text-end$/p' "$WORK/rt-done.txt" | sed '1d;$d')
# No AI provider in the mode: the result says why there are no notes, as the panel does after a meeting.
grep -q '^meeting-check: retranscribe outcome done failed-pieces 0 notes false notes-problem true speakers-skipped none echo-removed 0$' "$WORK/rt-done.txt" \
	&& [ "$(requests "$WORK/rt-done.txt")" = "$full" ] && [ -n "$before" ] && [ "$before" = "$after" ] \
	&& grep -q "^meeting-check: after id $id .* status completed failed-pieces 0 model $(sed -n 's/^meeting-check: retranscribe plan model \(.*\) language .*/\1/p' "$WORK/rt-done.txt") " "$WORK/rt-done.txt" \
	&& grep -q '^meeting-check: entries-after 6$' "$WORK/rt-done.txt" \
	|| { echo "FAIL: the meeting wasn't transcribed into the same entry"; exit 1; }
echo "$text" | grep -q '^\[00:00\] Me: ' && echo "$text" | grep -q '^\[[0-9:]*\] Others' \
	&& [ "$(echo "$text" | grep -c '^\[')" -ge 4 ] && [ -s "$cut/segments.json" ] && sums | cmp -s - "$WORK/sums-before.txt" \
	&& [ ! -e "$work_root/$id" ] && [ "$(archived "$id")" = 2 ] && [ "$(files_in_archive)" = $((archive_before + 1)) ] \
	|| { echo "FAIL: transcript, segments.json, recordings or the saved folder not as expected"; exit 1; }

# Relaunched: the entry kept it, nothing is recovered or offered again, nothing is transcribed.
run_app "$WORK/rt-reload.txt" --meeting-retranscribe-check "$target"
show "$WORK/rt-reload.txt" "transcribe meeting, relaunched: "
[ "$(sed -n '/^meeting-check: before-text-begin$/,/^meeting-check: before-text-end$/p' "$WORK/rt-reload.txt" | sed '1d;$d')" = "$text" ] \
	&& grep -q "^meeting-check: eligibility $target .* transcribed$" "$WORK/rt-reload.txt" \
	&& grep -qF 'meeting-check: retranscribe outcome failed This meeting already has its transcript.' "$WORK/rt-reload.txt" \
	&& [ "$(requests "$WORK/rt-reload.txt")" = 0 ] && grep -q '^meeting-check: entries-after 6$' "$WORK/rt-reload.txt" \
	|| { echo "FAIL: the transcribed meeting didn't survive a relaunch as it was"; exit 1; }
echo "transcribe meeting: OK ($full requests, same entry, recordings unchanged, 1 archived version)"

# A piece that fails (the first, --meeting-fail-pieces 1) on the other audio-only meeting: it's saved with one
# marked line and counted, as any meeting is, not reported as complete.
other=$(basename "$nomodel")
other_id=$(sed -n "s/^meeting-check: eligibility $other \([0-9A-F-]*\) .*/\1/p" "$WORK/rt-nomodel.txt")
run_app "$WORK/rt-piece.txt" --meeting-retranscribe-check "$other" --meeting-fail-pieces 1
show "$WORK/rt-piece.txt" "transcribe meeting, a piece fails: "
marker=$(sed -n 's/^meeting-check: failed-marker //p' "$WORK/rt-piece.txt")
grep -q '^meeting-check: retranscribe outcome done failed-pieces 1 ' "$WORK/rt-piece.txt" \
	&& grep -q "^meeting-check: after id $other_id .* status completed failed-pieces 1 " "$WORK/rt-piece.txt" \
	&& [ "$(sed -n '/^meeting-check: after-text-begin$/,/^meeting-check: after-text-end$/p' "$WORK/rt-piece.txt" | grep -cF -- "$marker")" = 1 ] \
	&& [ "$(archived "$other_id")" = 2 ] && [ "$(files_in_archive)" = $((archive_before + 2)) ] \
	&& grep -q '^meeting-check: entries-after 6$' "$WORK/rt-piece.txt" \
	|| { echo "FAIL: a failed piece wasn't marked and counted"; exit 1; }
echo "transcribe meeting, a piece fails: OK (1 marked line, failed-pieces 1)"
