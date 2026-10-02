#!/bin/bash
# make text-fidelity-check: what the rule-based dictation text steps (filter → Chinese cleanup → paragraphs →
# replacement rules, DictationText.swift) do to text a model has already recognized: paths, flags, calls, indexes,
# JSON, tags, code, mixed Chinese and English, spacing, and real noise annotations. Runs the Debug app's own code
# (TextFidelityCheck.swift) from a copy re-identified as me.sma1lboy.yap.mock (see scripts/mock.sh) under the mock lock.
# No model, recording, clipboard or text field. Prints every case step by step, then fails if any output differs
# from scripts/text-fidelity-check.py.
set -euo pipefail
source "$(dirname "$0")/mock-lock.sh"

APP_DIR="$1"
WORK=/tmp/yap-text-fidelity-check
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

"$APP/Contents/MacOS/VoiceInk Dev" -AppleLanguages "(en)" --text-fidelity-check >"$WORK/out.txt" 2>"$WORK/err.txt" \
	|| { echo "app exited with $?"; tail -5 "$WORK/err.txt"; exit 1; }
python3 "$(dirname "$0")/text-fidelity-check.py" "$WORK/out.txt"
grep '^text-check-selfchecks: ' "$WORK/out.txt" || { echo "self-checks didn't finish"; exit 1; }
echo "text-fidelity-check: OK"
