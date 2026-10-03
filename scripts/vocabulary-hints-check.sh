#!/bin/bash
# make vocabulary-hints-check: which dictionary words the cloud transcription requests carry when the dictionary holds
# more than a provider takes, after a word is added or deleted, and with blanks, case duplicates, same-date and
# CJK words. Runs the Debug app's own code (VocabularyHintsCheck.swift) from a copy re-identified as
# me.sma1lboy.yap.mock (see scripts/mock.sh) under the mock lock, with IP traffic denied (scripts/offline.sb): every
# request is recorded in-process and answered there. In-memory dictionary, fake keys from the environment, no model.
# Prints every request's terms, then fails if any differs from scripts/vocabulary-hints-check.py.
set -euo pipefail
source "$(dirname "$0")/mock-lock.sh"

APP_DIR="$1"
WORK=/tmp/yap-vocabulary-hints-check
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

YAP_MOCK_API_KEY_DEEPGRAM=fixture YAP_MOCK_API_KEY_OPENROUTER=fixture YAP_MOCK_API_KEY_XAI=fixture \
	YAP_MOCK_API_KEY_SPEECHMATICS=fixture \
	sandbox-exec -f "$(dirname "$0")/offline.sb" "$APP/Contents/MacOS/VoiceInk Dev" -AppleLanguages "(en)" \
	--vocabulary-hints-check >"$WORK/out.txt" 2>"$WORK/err.txt" \
	|| { echo "app exited with $?"; tail -5 "$WORK/err.txt"; exit 1; }
grep -q '^vocabulary-hints-done' "$WORK/out.txt" || { echo "the check didn't finish"; tail -5 "$WORK/err.txt"; exit 1; }
python3 "$(dirname "$0")/vocabulary-hints-check.py" "$WORK/out.txt"
echo "vocabulary-hints-check: OK"
