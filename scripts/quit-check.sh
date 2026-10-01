#!/bin/bash
# make quit-check MODEL=<path to ggml-*.bin>: Quit Yap the way the menu bar's Quit does (NSApplication.terminate,
# through applicationShouldTerminate) while its local Whisper model is loaded, still loading, or decoding, under each
# "Keep model loaded" setting. ggml frees its Metal device in a static destructor at exit() and aborts if any model
# buffer is still allocated then, so a model left loaded at Quit is a crash report. The Debug app re-identified as
# me.sma1lboy.yap.mock (own defaults, Application Support and keychain; see scripts/offline-check.sh) runs
# QuitCheck's --quit-check <state> once per case. Per case: exit status 0, no crash report for that process, the
# release logged before the app's willTerminate, and the release run once. Results and each case's unified log stay
# in $OUT (default /tmp/yap-quit-check).
set -euo pipefail
source "$(dirname "$0")/mock-lock.sh"

APP_DIR="$1"
MODEL="${2:?usage: quit-check.sh <app dir> <ggml-*.bin>}"
ID=me.sma1lboy.yap.mock
OUT="${OUT:-/tmp/yap-quit-check}"
WORK="$OUT/work"
APP="$WORK/Yap Mock.app"
SUPPORT="$HOME/Library/Application Support/$ID"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPORTS="$HOME/Library/Logs/DiagnosticReports"

cleanup() {
	defaults delete "$ID" >/dev/null 2>&1 || true
	while security delete-generic-password -s "$ID" >/dev/null 2>&1; do :; done
	rm -rf "$SUPPORT" "$HOME/Library/Caches/$ID" "$HOME/Library/HTTPStorages/$ID" \
		"$HOME/Library/Saved Application State/$ID.savedState" "$HOME/Library/WebKit/$ID"
}
trap 'cleanup; rm -rf "$WORK"' EXIT

rm -rf "$OUT" && mkdir -p "$WORK/config/yap"
ditto "$APP_DIR/VoiceInk Dev.app" "$APP"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $ID" -c "Set :CFBundleName Yap Mock" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Delete :CFBundleURLTypes" "$APP/Contents/Info.plist" 2>/dev/null || true
# Nested bundles first, then the app: `codesign --deep` fails on the XPC service under a full disk.
for nested in "$APP"/Contents/Frameworks/*.framework "$APP"/Contents/XPCServices/*.xpc; do
	for _ in 1 2 3; do codesign --force --sign - "$nested" >/dev/null 2>&1 && break; sleep 2; done
done
codesign --force --sign - "$APP" >/dev/null 2>&1
afconvert -f WAVE -d LEI16@16000 -c 1 "$ROOT/setup/asr/clips/security.m4a" "$WORK/clip.wav"
name=$(basename "$MODEL" .bin)
cat >"$WORK/config/yap/config.json" <<EOF
{ "modes": [ { "id": "0FF11E00-0000-4000-8000-000000000001", "name": "Offline", "isDefault": true,
    "selectedTranscriptionModelName": "$name", "selectedLanguage": "auto", "isAIEnhancementEnabled": false,
    "useClipboardContext": false, "useSelectedTextContext": false, "useScreenCapture": false } ] }
EOF
# `appleevent`: the quit Apple event the Dock, logout and Sparkle's installer send (NSRunningApplication.terminate).
cat >"$WORK/quit-event.swift" <<'EOF'
import AppKit
let pid = pid_t(CommandLine.arguments[1])!
guard let app = NSRunningApplication(processIdentifier: pid) else { print("no running application \(pid)"); exit(1) }
print("quit Apple event sent: \(app.terminate())")
EOF

version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
# Keep model loaded (seconds; 0 Always, -1 After each dictation) and the state Quit comes in.
CASES="${CASES:-0:dictated 900:dictated -1:dictated -1:preloaded 0:loading 0:decoding 0:twice 0:menubar 0:appmenu 0:appleevent}"
failed=0
for case in $CASES; do
	keep=${case%%:*} state=${case#*:} dir="$OUT/keep${keep}-$state"
	mkdir -p "$dir"
	cleanup
	mkdir -p "$SUPPORT/WhisperModels"
	cp -c "$MODEL" "$SUPPORT/WhisperModels/" 2>/dev/null || cp "$MODEL" "$SUPPORT/WhisperModels/"
	defaults write "$ID" hasCompletedOnboardingV2 -bool true
	# This version already launched once: no release-notes sheet. AppKit ignores terminate: while a sheet is attached.
	defaults write "$ID" lastLaunchedVersion "$version"
	defaults write "$ID" ModelKeepLoadedSeconds -int "$keep"
	# The launch-time prewarm loads the model by itself; `loading` needs it unloaded until its own preload.
	if [ "$state" = loading ]; then defaults write "$ID" PrewarmModelOnWake -bool false; fi
	start=$(date '+%Y-%m-%d %H:%M:%S') && touch "$dir/started"
	status=0
	XDG_CONFIG_HOME="$WORK/config" "$APP/Contents/MacOS/VoiceInk Dev" --dictate-file "$WORK/clip.wav" \
		--quit-check "$state" >"$dir/out.txt" 2>"$dir/err.txt" &
	pid=$!
	# Not `timeout`: a Quit that hangs is itself the failure, reported as such.
	sent=""
	for _ in $(seq 1 600); do
		kill -0 "$pid" 2>/dev/null || break
		if [ "$state" = appleevent ] && [ -z "$sent" ] && grep -q "quit-check: terminate," "$dir/out.txt"; then
			xcrun swift "$WORK/quit-event.swift" "$pid" >"$dir/sender.txt" 2>&1 &
			sent=1
		fi
		sleep 0.1
	done
	if kill -0 "$pid" 2>/dev/null; then
		kill -9 "$pid"
		echo "hung" >"$dir/hung"
	fi
	wait "$pid" || status=$?
	sleep 5  # ReportCrash writes the report a moment after the process ends
	log show --start "$start" --style compact --info \
		--predicate "processIdentifier == $pid AND (category == 'ModelResidency' OR category == 'AppDelegate' \
			OR composedMessage CONTAINS 'releaseModels' OR composedMessage CONTAINS 'cleanupResources')" \
		>"$dir/log.txt" 2>/dev/null || true
	# This run's process: written since the case started, with its pid.
	crash=$(find "$REPORTS" -name 'VoiceInk Dev-*.ips' -newer "$dir/started" -print0 2>/dev/null \
		| xargs -0 grep -lE "\"pid\" *: *$pid," 2>/dev/null | head -1 || true)
	[ -n "$crash" ] && cp "$crash" "$dir/"
	python3 - "$dir" "$keep" "$state" "$status" "${crash:-}" <<'PY' || failed=1
import datetime, pathlib, re, sys
d, keep, state, status, crash = pathlib.Path(sys.argv[1]), *sys.argv[2:]
out = (d / "out.txt").read_text()
# Only what the log says from the Quit on: launch-time selfChecks log the same lines, ~10 s before. The unified log's
# clock runs a few ms off print()'s Date(), hence the second of slack.
quit_at = next((float(l.split()[-1]) for l in out.splitlines() if l.startswith("quit-check: terminate,")), None)
def after_quit(line):
    try: return datetime.datetime.strptime(line[:23], "%Y-%m-%d %H:%M:%S.%f").timestamp() >= quit_at - 1
    except ValueError: return False
log = "".join(l for l in (d / "log.txt").read_text().splitlines(True) if quit_at and after_quit(l))
problems = []
if (d / "hung").exists(): problems.append("still running a minute later")
if status != "0": problems.append(f"exit status {status}")
if crash: problems.append(f"crash report {pathlib.Path(crash).name}")
if "quit-check: terminate, YapApplication" not in out: problems.append("never reached Quit through YapApplication")
if "quit-check: will terminate" not in out: problems.append("no willTerminate")
if "will terminate, model loaded true" in out: problems.append("model still loaded at willTerminate")
closing = log.count("quit: closing local models")
if closing != 1: problems.append(f"release on Quit logged {closing} times")
# Right after the release starts: the Whisper context is freed, then AppKit is told to go on.
order = re.findall(r"quit: closing local models|WhisperModelManager.cleanupResources: completed|quit: local models closed", log)
want = ["quit: closing local models", "WhisperModelManager.cleanupResources: completed", "quit: local models closed"]
if want[0] not in order or order[order.index(want[0]):][:3] != want: problems.append(f"release order {order}")
marks = [l.split(",")[0].split(":")[1].strip() for l in out.splitlines() if l.startswith("quit-check:")]
# A decode running at Quit finishes before the exit, not under a freed context.
finished = next((i for i, m in enumerate(marks) if m == "dictation finished"), None)
if state == "decoding" and "will terminate" in marks and (finished is None or finished > marks.index("will terminate")):
    problems.append("exited before the decode in flight finished")
if state == "twice" and "terminate again" not in " ".join(marks): problems.append("second Quit never sent")
verdict = "ok" if not problems else "FAIL: " + "; ".join(problems)
print(f"keep {keep:>4} {state:10} {verdict}")
for line in out.splitlines():
    if line.startswith("quit-check:"): print("    " + line)
if (d / "sender.txt").exists(): print("    sender: " + (d / "sender.txt").read_text().strip())
sys.exit(1 if problems else 0)
PY
done
exit $failed
