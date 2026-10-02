#!/bin/bash
# make mic-fallback-check: which microphone Yap records from when the chosen one isn't there
# (AudioDeviceManager's selection and fallback, MicFallbackCheck.swift), run from a copy of the Debug app
# re-identified as me.sma1lboy.yap.mock (see scripts/mock.sh) under the mock lock.
# 1. matrix: fixture device lists (transport types, lid, system default) through the app's own selection code, each
#    case checked against the expected microphone; the whole table is printed before any failure.
# 2. smoke: this Mac's real input devices, read only: transport of each, and what the app would record from. Nothing
#    is recorded, no device or system default is changed (the mock identity's own settings only).
set -euo pipefail
source "$(dirname "$0")/mock-lock.sh"

APP_DIR="$1"
WORK=/tmp/yap-mic-fallback-check
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

BIN="$APP/Contents/MacOS/VoiceInk Dev"
"$BIN" -AppleLanguages "(en)" --mic-fallback-check matrix >"$WORK/matrix.txt" 2>"$WORK/matrix-err.txt" \
	|| { echo "app exited with $?"; tail -5 "$WORK/matrix-err.txt"; exit 1; }
matrix_ok=0
python3 "$(dirname "$0")/mic-fallback-check.py" "$WORK/matrix.txt" || matrix_ok=$?

cleanup
"$BIN" -AppleLanguages "(en)" --mic-fallback-check smoke >"$WORK/smoke.txt" 2>"$WORK/smoke-err.txt" \
	|| { echo "smoke: app exited with $?"; tail -5 "$WORK/smoke-err.txt"; exit 1; }
echo "smoke (this Mac, read only):"
sed -n 's/^mic-check: /  /p' "$WORK/smoke.txt"

[ "$matrix_ok" = 0 ] || exit 1
echo "mic-fallback-check: OK"
