#!/bin/bash
# make paste-session-check: CursorPaster's clipboard handling (PasteSessionCheck.swift): overlapping pastes, the user
# copying before or after ⌘V, a rewrite of the same text and paste session, an empty clipboard, restore off, a failed
# clipboard write, ⌘V that can't be sent, remote-desktop timing, a close with a restore pending. Every scenario runs
# on a private pasteboard of its own (NSPasteboard(name:)) that it releases at the end; the general pasteboard (what
# the user copies to) is never read or written, no key is sent and nothing is read from the app in front. Runs from a
# copy re-identified as me.sma1lboy.yap.mock (see scripts/mock.sh) under the mock lock. The raw lines are kept in
# $OUT (default /tmp/yap-paste-session-check.txt); fails if any scenario does.
set -euo pipefail
source "$(dirname "$0")/mock-lock.sh"

APP_DIR="$1"
WORK=/tmp/yap-paste-session-check
OUT="${OUT:-/tmp/yap-paste-session-check.txt}"
ID=me.sma1lboy.yap.mock
APP="$WORK/Yap Mock.app"

cleanup() {
	defaults delete "$ID" >/dev/null 2>&1 || true
	rm -rf "$HOME/Library/Application Support/$ID"
}
trap 'cleanup; rm -rf "$WORK"' EXIT
cleanup
rm -rf "$WORK" && mkdir -p "$WORK"

ditto "$APP_DIR/VoiceInk Dev.app" "$APP"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $ID" -c "Set :CFBundleName Yap Mock" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Delete :CFBundleURLTypes" "$APP/Contents/Info.plist" 2>/dev/null || true
codesign --force --deep --sign - "$APP" >/dev/null 2>&1

"$APP/Contents/MacOS/VoiceInk Dev" -AppleLanguages "(en)" --paste-session-check >"$OUT" 2>"$WORK/err.txt" \
	|| { echo "app exited with $?"; tail -5 "$WORK/err.txt"; exit 1; }
python3 - "$OUT" <<'PY'
import json, sys
rows = [json.loads(l.split(": ", 1)[1]) for l in open(sys.argv[1]) if l.startswith("paste-check: ")]
done = [l for l in open(sys.argv[1]) if l.startswith("paste-check-done: ")]
for r in rows:
    print(("ok  " if r["pass"] else "FAIL") + "  " + r["scenario"])
    for f in r["failures"]:
        print("        " + f)
if not done or not rows:
    sys.exit("paste-session-check: the app didn't finish the scenarios")
failed = sum(not r["pass"] for r in rows)
print(done[0].strip())
sys.exit(1 if failed else 0)
PY
echo "paste-session-check: OK ($OUT)"
