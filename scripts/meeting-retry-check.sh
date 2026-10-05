#!/bin/bash
# make meeting-retry-check MODEL=<ggml-*.bin>: Transcribe Meeting (MeetingRetranscription.swift) at its edges: a normal
# Quit while it runs, a live meeting started while it runs (and it started while a meeting is starting), a recording
# that can't be read, an old segments.json that can't be read, a kill between segments.json and the entry's save, the
# entry deleted or History's store unreadable meanwhile, notes requested with the mode changed meanwhile and a
# cancel while the notes are awaited; and recovery reading a recording that can't be read. Plus the earlier
# cancel / failed save / kill mid-way / success / failed piece cases on a meeting of its own.
#
# Every meeting here is "Me" only (the system audio is silence), so nobody is told apart and no speaker model is
# needed or downloaded; every launch runs under scripts/offline.sb (no IP traffic). Notes come from
# --meeting-fake-notes (fixed text, no request); the mode's AI key is a fake one given only to the mock app. The
# microphone permission is answered by the check (MeetingFilesCheck.microphoneAccess): never asked, never granted.
# Uses the Debug app as me.sma1lboy.yap.mock under the mock lock (scripts/meeting-check-common.sh). For each case it
# prints the entry before/after, the requests made, the recordings' SHA-256, segments.json and the saved folder.
set -euo pipefail

APP_DIR="$1"
MODEL="${2:?usage: meeting-retry-check.sh <app dir> <ggml-*.bin>}"
NOTES=""
WORK=/tmp/yap-meeting-retry-check
source "$(dirname "$0")/meeting-check-common.sh"
OFFLINE="$ROOT/scripts/offline.sb"
OUT="${OUT:-/tmp/yap-meeting-retry-check-out}"  # each launch's output is kept here
rm -rf "$OUT" && mkdir -p "$OUT"
trap 'cp "$WORK"/*.txt "$OUT"/ 2>/dev/null; cleanup; rm -rf "$WORK"' EXIT
export YAP_MOCK_API_KEY_ANTHROPIC="fake-key-for-meeting-retry-check"

# Offline: no IP traffic at all, so nothing can be downloaded or sent.
run_app() {
	local out="$1"
	shift
	XDG_CONFIG_HOME="${CONFIG_HOME:-$WORK/config}" sandbox-exec -f "$OFFLINE" "$APP/Contents/MacOS/VoiceInk Dev" -AppleLanguages "(en)" "$@" \
		>"$out" 2>>"$WORK/err.txt" || { echo "app exited with $?"; grep -v '^\s*$' "$WORK/err.txt" | tail -5; exit 1; }
}
failed=0
fail() { echo "FAIL: $*"; failed=$((failed + 1)); }  # every case runs; the result is at the end
die() { echo "FAIL: $*"; exit 1; }

ARCHIVE="$WORK/archive"
mkdir -p "$ARCHIVE"
defaults write "$ID" meetingAutoArchiveFolder "$ARCHIVE"
defaults write "$ID" meetingAutoArchiveEnabled -bool true

# A "Me"-only meeting: Tingting's clips twice with a second between, ~80 s; the system audio is silence as long.
python3 - "$WORK" <<'PY'
import sys, wave
work = sys.argv[1]
def frames(name):
    with wave.open(f"{work}/clips/{name}.wav") as w:
        return w.readframes(w.getnframes())
silence = lambda seconds: b"\0\0" * int(16000 * seconds)
mic = b"".join(frames(n) + silence(1) for n in ["deploy", "bug", "perf", "meeting"] * 2)
for name, data in [("mic", mic), ("system", b"\0" * len(mic))]:
    with wave.open(f"{work}/{name}.wav", "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000); w.writeframes(data)
print(f"test meeting: {len(mic) / 32000:.1f} s, system audio silent")
PY

MEETINGS="$SUPPORT/Recordings/meetings"
new_meeting() {  # prints the folder
	local folder="$MEETINGS/$(uuidgen)"
	mkdir -p "$folder" && cp "$WORK/mic.wav" "$WORK/system.wav" "$folder/"
	echo "$folder"
}
sums() { (cd "$1" && chmod u+r mic.wav system.wav 2>/dev/null; shasum -a 256 mic.wav system.wav | awk '{print $1}' | tr '\n' ' '); }
files_in_archive() { ls "$ARCHIVE" | wc -l | tr -d ' '; }
requests() { sed -n 's/^meeting-check: requests //p' "$1"; }
line() { sed -n "s/^meeting-check: $2 //p" "$1" | head -1; }
status_of() { sed -n "s/^meeting-check: $2 id [0-9A-F-]* timestamp [0-9.]* status \([a-z]*\) failed-pieces \([0-9]*\) .*/\1 \2/p" "$1"; }
mkdir -p "$WORK/config-nomodel/yap" "$WORK/config-notes/yap"
sed 's/"selectedTranscriptionModelName": "[^"]*",//' "$WORK/config/yap/config.json" >"$WORK/config-nomodel/yap/config.json"
sed 's/"isAIEnhancementEnabled": false,/"isAIEnhancementEnabled": true, "selectedAIProvider": "Anthropic", "selectedAIModel": "claude-check-snapshot",/' \
	"$WORK/config/yap/config.json" >"$WORK/config-notes/yap/config.json"
report() { echo "  $*"; }

# R. Recovery (the mode has a model) of an interrupted meeting whose microphone file can't be read.
R=$(new_meeting)
r_before=$(sums "$R")
chmod 000 "$R/mic.wav"
run_app "$WORK/r.txt" --meeting-recovery-check
chmod u+rw "$R"/mic.wav* 2>/dev/null || true
r_mic="$R/mic.wav"; [ -e "$r_mic" ] || r_mic="$R/mic.wav.orig"
echo "R. recovery, microphone unreadable: $(sed -n 's/^meeting-check: audio-only \(.*\)/audio-only \1/p' "$WORK/r.txt" | head -1)"
report "files: $(ls "$R" | tr '\n' ' ')"
report "mic.wav SHA-256 before $(echo "$r_before" | cut -c1-16) after $( [ -e "$r_mic" ] && shasum -a 256 "$r_mic" | cut -c1-16 || echo gone)"
report "$(sed -n '/^meeting-check: transcript-begin$/,/^meeting-check: transcript-end$/p' "$WORK/r.txt" | sed '1d;$d' | head -1)"
grep -q '^meeting-check: audio-only true save-error none' "$WORK/r.txt" && [ -e "$R/mic.wav" ] && [ "$(sums "$R")" = "$r_before" ] \
	|| fail "R: recovery saved a meeting it couldn't read, or its recording was lost"

# Audio-only entries for the rest (no model in the mode): recovery saves them with their audio only.
for name in Q A S U K D F N C Z P; do eval "$name=\$(new_meeting)"; sleep 1; done
CONFIG_HOME="$WORK/config-nomodel" run_app "$WORK/setup.txt" --meeting-recovery-check
[ "$(grep -c '^meeting-check: audio-only true save-error none' "$WORK/setup.txt")" = 11 ] || die "setup: 11 audio-only meetings expected"
before_sums=$(sums "$Q")  # every folder has the same recordings
work_root="$SUPPORT/MeetingRetranscription"

# untouched <out> <folder>: the entry still audio-only, recordings byte for byte, no segments.json, nothing archived
# by this case (archive_count is taken when each case's run starts, in retry).
archive_count=$(files_in_archive)
untouched() {
	local why=""
	[ "$(status_of "$1" after)" = "failed 0" ] || why="$why entry($(status_of "$1" after))"
	[ "$(sums "$2")" = "$before_sums" ] || why="$why recordings"
	[ ! -e "$2/segments.json" ] || why="$why segments.json"
	[ "$(files_in_archive)" = "$archive_count" ] || why="$why archive($(files_in_archive)/$archive_count)"
	[ ! -e "$work_root/$(line "$1" 'before id' | cut -d' ' -f1)" ] || why="$why work-folder"
	[ -z "$why" ] || echo "  not as before:$why"
	[ -z "$why" ]
}
done_ok() {  # <out> <failed pieces>: transcribed into the same entry, one more archived file
	[ "$(line "$1" 'retranscribe outcome' | cut -d' ' -f1)" = done ] && [ "$(status_of "$1" after)" = "completed $2" ] \
		&& [ "$(files_in_archive)" = $((archive_count + 1)) ]
}
retry() { archive_count=$(files_in_archive); run_app "$WORK/$1.txt" --meeting-retranscribe-check "$(basename "$2")" "${@:3}"; }

# Q. Quit (NSApplication.terminate through AppDelegate) after the first piece's request.
q_archive=$(files_in_archive)
retry q "$Q" --meeting-retranscribe-quit-after 1
echo "Q. quit while transcribing: $(line "$WORK/q.txt" 'retranscription ended') | $(grep '^meeting-check: will terminate' "$WORK/q.txt" | sed 's/^meeting-check: //')"
report "after the quit: $(sed -n '/^meeting-check: quit after/,$p' "$WORK/q.txt" | grep '^meeting-check: \(retranscription ended\|quit: \|will terminate\|piece failed\)' | sed 's/^meeting-check: //' | cut -c1-60 | tr '\n' ';')"
report "at exit: $(status_of "$WORK/q.txt" at-exit) | pieces failed: $(grep -c '^meeting-check: piece failed' "$WORK/q.txt")"
retry q-relaunch "$Q" --meeting-retranscribe-inspect
archive_count=$q_archive
report "relaunched: $(status_of "$WORK/q-relaunch.txt" before); segments.json $([ -e "$Q/segments.json" ] && echo present || echo none); recordings $([ "$(sums "$Q")" = "$before_sums" ] && echo unchanged || echo CHANGED); archive $(files_in_archive)/$archive_count"
# The run is canceled and has ended before the models start closing; no piece failed.
# (AppDelegate's selfCheck drives the same Quit with stand-ins at launch, so only the lines after the quit count.)
q_order=$(sed -n '/^meeting-check: quit after/,$p' "$WORK/q.txt" | grep '^meeting-check: \(retranscription ended\|quit: \|will terminate\)' \
	| sed 's/^meeting-check: //; s/,.*//; s/ state .*//' | tr '\n' ';')
[ "$(status_of "$WORK/q-relaunch.txt" before)" = "failed 0" ] && [ ! -e "$Q/segments.json" ] && [ "$(files_in_archive)" = "$archive_count" ] \
	&& [ "$q_order" = "quit: closing local models;retranscription ended canceled;quit: local models closed;will terminate;" ] && ! grep -q '^meeting-check: piece failed' "$WORK/q.txt" \
	|| fail "Q: a Quit during Transcribe Meeting: the run wasn't ended before the models closed, or a result was saved ($q_order)"
retry q-again "$Q"
done_ok "$WORK/q-again.txt" 0 || fail "Q: Transcribe Meeting after the Quit"
report "transcribed again after the relaunch: $(line "$WORK/q-again.txt" 'retranscribe outcome')"

# A. A live meeting and Transcribe Meeting refuse each other, in both orders.
retry a "$A" --meeting-admission-check
echo "A. admission:"
grep '^meeting-check: admission\|^meeting-check: notification' "$WORK/a.txt" | sed 's/^meeting-check: /  /'
grep -q '^meeting-check: admission meeting-starting retranscribe A meeting is being recorded or recovered' "$WORK/a.txt" \
	&& grep -q '^meeting-check: admission meeting-start ended: permission asked 1 recording false$' "$WORK/a.txt" \
	&& grep -q '^meeting-check: admission retranscribing meeting-start: permission asked 0 recording false running true$' "$WORK/a.txt" \
	&& grep -q '^meeting-check: admission after the run: permission asked 2 running false$' "$WORK/a.txt" \
	&& done_ok "$WORK/a.txt" 0 || fail "A: a meeting and Transcribe Meeting didn't refuse each other"

# S. The microphone recording can't be read: nothing is saved, it can be tried again.
chmod 000 "$S/mic.wav"
retry s "$S"
chmod u+rw "$S/mic.wav"
echo "S. recording unreadable: $(line "$WORK/s.txt" 'retranscribe outcome') | requests $(requests "$WORK/s.txt") | after $(status_of "$WORK/s.txt" after)"
untouched "$WORK/s.txt" "$S" && [ "$(requests "$WORK/s.txt")" = 0 ] || fail "S: an unreadable recording was transcribed as a meeting"

# U. An old segments.json that can't be read, and the entry's save fails: the old file stays.
printf '[{"speaker":"me","start":0,"end":1,"text":"left by an earlier try"}]' >"$U/segments.json"
u_old=$(shasum -a 256 "$U/segments.json" | cut -c1-16)
chmod 000 "$U/segments.json"
retry u "$U" --meeting-fail-save
chmod u+rw "$U/segments.json" 2>/dev/null || true
echo "U. old segments.json unreadable, save fails: $(line "$WORK/u.txt" 'retranscribe outcome') | requests $(requests "$WORK/u.txt")"
report "old segments.json: $([ -e "$U/segments.json" ] && echo "$(shasum -a 256 "$U/segments.json" | cut -c1-16) (was $u_old)" || echo "GONE (was $u_old)")"
[ -e "$U/segments.json" ] && [ "$(shasum -a 256 "$U/segments.json" | cut -c1-16)" = "$u_old" ] && [ "$(status_of "$WORK/u.txt" after)" = "failed 0" ] \
	&& [ "$(requests "$WORK/u.txt")" = 0 ] || fail "U: an unreadable segments.json was lost or ignored"

# K. Killed between segments.json and the entry's save.
k_archive=$(files_in_archive)
XDG_CONFIG_HOME="$WORK/config" sandbox-exec -f "$OFFLINE" "$APP/Contents/MacOS/VoiceInk Dev" -AppleLanguages "(en)" \
	--meeting-retranscribe-check "$(basename "$K")" --meeting-retranscribe-kill-at-commit >"$WORK/k.txt" 2>>"$WORK/err.txt" || true
grep -q '^meeting-check: killed at commit' "$WORK/k.txt" || die "K: not killed at the commit"
retry k-relaunch "$K" --meeting-retranscribe-inspect
archive_count=$k_archive
k_json=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$K/segments.json" 2>/dev/null || echo unreadable)
echo "K. killed at commit: relaunched $(status_of "$WORK/k-relaunch.txt" before); segments.json $k_json segments; recordings $([ "$(sums "$K")" = "$before_sums" ] && echo unchanged || echo CHANGED); work folder $([ -e "$work_root" ] && echo left || echo removed); archive $(files_in_archive)/$archive_count"
[ "$(status_of "$WORK/k-relaunch.txt" before)" = "failed 0" ] && [ "$(sums "$K")" = "$before_sums" ] && [ ! -e "$work_root" ] \
	&& [ "$(files_in_archive)" = "$archive_count" ] || fail "K: the kill at commit changed the entry or the recordings"
retry k-again "$K"
done_ok "$WORK/k-again.txt" 0 || fail "K: Transcribe Meeting after the kill"
report "transcribed again: $(line "$WORK/k-again.txt" 'retranscribe outcome'); segments.json $(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$K/segments.json") segments"

# D. The meeting is deleted from History (its folder, then the entry, as History does) after the first request:
# nothing is written, its folder isn't made again.
retry d "$D" --meeting-retranscribe-delete-after 1
echo "D. deleted meanwhile: $(line "$WORK/d.txt" 'retranscribe outcome') | after $(grep '^meeting-check: after id' "$WORK/d.txt" | sed 's/^meeting-check: //' | cut -c1-60)"
grep -q 'outcome failed The meeting was deleted from History' "$WORK/d.txt" && grep -q '^meeting-check: after id .* gone$' "$WORK/d.txt" \
	&& [ ! -e "$D" ] && [ "$(files_in_archive)" = "$archive_count" ] \
	|| fail "D: a deleted meeting was written to, or its folder made again"

# F. History's store can't be read at the commit.
retry f "$F" --meeting-fail-fetch
echo "F. store read fails: $(line "$WORK/f.txt" 'retranscribe outcome')"
untouched "$WORK/f.txt" "$F" && ! grep -q 'outcome failed The meeting was deleted' "$WORK/f.txt" \
	|| fail "F: a store read error was reported as a deletion, or something was saved"

# N. Notes: the run keeps the mode it started with when the mode is changed meanwhile.
CONFIG_HOME="$WORK/config-notes" retry n "$N" --meeting-fake-notes 1 --meeting-change-mode-during
echo "N. notes, mode changed meanwhile: $(line "$WORK/n.txt" 'mode changed to') | asked $(line "$WORK/n.txt" 'notes request') | $(line "$WORK/n.txt" 'retranscribe outcome' | cut -d' ' -f1-6)"
report "after: $(grep '^meeting-check: after notes' "$WORK/n.txt" | sed 's/^meeting-check: //')"
[ "$(line "$WORK/n.txt" 'notes request')" = "provider Anthropic model claude-check-snapshot" ] \
	&& grep -q '^meeting-check: after notes true notes-model claude-check-snapshot ' "$WORK/n.txt" && done_ok "$WORK/n.txt" 0 \
	|| fail "N: the notes didn't come from the mode the run started with"

# C. Canceled while the notes are awaited; the answer comes late anyway.
CONFIG_HOME="$WORK/config-notes" retry c "$C" --meeting-fake-notes 2 --meeting-retranscribe-cancel-in-notes
echo "C. canceled during the notes: $(line "$WORK/c.txt" 'retranscribe outcome') | late answer $(grep -c '^meeting-check: notes answered' "$WORK/c.txt")"
grep -q '^meeting-check: retranscribe outcome canceled$' "$WORK/c.txt" && untouched "$WORK/c.txt" "$C" \
	|| fail "C: a canceled run saved its late notes"

# Z. The earlier cases, on one meeting: started twice and canceled after the first request; the save fails; killed
# after the first request; then transcribed. P: a piece fails and is marked.
retry z-cancel "$Z" --meeting-retranscribe-twice --meeting-retranscribe-cancel-after 1
retry z-fail "$Z" --meeting-fail-save
XDG_CONFIG_HOME="$WORK/config" sandbox-exec -f "$OFFLINE" "$APP/Contents/MacOS/VoiceInk Dev" -AppleLanguages "(en)" \
	--meeting-retranscribe-check "$(basename "$Z")" --meeting-retranscribe-kill-after 1 >"$WORK/z-kill.txt" 2>>"$WORK/err.txt" || true
retry z-done "$Z"
echo "Z. cancel: requests $(requests "$WORK/z-cancel.txt") $(line "$WORK/z-cancel.txt" 'retranscribe outcome') | failed save: requests $(requests "$WORK/z-fail.txt") | kill: $(grep -c '^meeting-check: killed after 1' "$WORK/z-kill.txt") | then $(line "$WORK/z-done.txt" 'retranscribe outcome' | cut -d' ' -f1-3)"
grep -q 'outcome canceled$' "$WORK/z-cancel.txt" && [ "$(requests "$WORK/z-cancel.txt")" = 1 ] \
	&& grep -q 'retranscribe again same run running true' "$WORK/z-cancel.txt" \
	&& grep -q 'outcome failed ' "$WORK/z-fail.txt" && [ "$(status_of "$WORK/z-fail.txt" after)" = "failed 0" ] \
	&& grep -q '^meeting-check: killed after 1' "$WORK/z-kill.txt" && done_ok "$WORK/z-done.txt" 0 \
	|| fail "Z: cancel / failed save / kill / transcribe"
retry p "$P" --meeting-fail-pieces 1
marker=$(sed -n 's/^meeting-check: failed-marker //p' "$WORK/p.txt")
echo "P. a piece fails: $(line "$WORK/p.txt" 'retranscribe outcome' | cut -d' ' -f1-3) | marked lines $(sed -n '/^meeting-check: after-text-begin$/,/^meeting-check: after-text-end$/p' "$WORK/p.txt" | grep -cF -- "$marker")"
done_ok "$WORK/p.txt" 1 || fail "P: a failed piece"

grep -q "Downloading speaker" "$WORK/err.txt" && fail "a speaker model download was started"
[ "$failed" = 0 ] || { echo "meeting-retry-check: $failed case(s) failed"; exit 1; }
echo "meeting-retry-check: OK"
