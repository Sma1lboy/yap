#!/bin/bash
# make first-run-check: a new user's first local dictation. Fresh install as the mock identity (me.sma1lboy.yap.mock:
# its own defaults, Application Support and keychain; see scripts/offline-check.sh) with no model on disk and one
# mode on the default local model. The Debug app is launched with --first-run-check <model> --dictate-file <clip>
# (OfflineCheck.swift): it downloads the model through WhisperModelManager, prints what the shortcut's preflight
# says mid-download, then dictates the clip twice (cold, then warm) and quits. Needs the network (Hugging Face).
# WAIT=1: wait for the post-download warmup before dictating (what a user who waits a moment sees).
# The dev and release apps' settings are never read or written.
set -euo pipefail

APP_DIR="$1"
MODEL_NAME="${2:-ggml-large-v3-turbo-q5_0}"
ID=me.sma1lboy.yap.mock
WORK=/tmp/yap-first-run-check
APP="$WORK/Yap Mock.app"
SUPPORT="$HOME/Library/Application Support/$ID"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

cleanup() {
	defaults delete "$ID" >/dev/null 2>&1 || true
	while security delete-generic-password -s "$ID" >/dev/null 2>&1; do :; done
	rm -rf "$SUPPORT" "$HOME/Library/Caches/$ID" "$HOME/Library/HTTPStorages/$ID" \
		"$HOME/Library/Saved Application State/$ID.savedState" "$HOME/Library/WebKit/$ID" \
		"$(getconf DARWIN_USER_CACHE_DIR)$ID"  # Metal shader cache: a fresh install compiles whisper's shaders
}
trap 'cleanup; rm -rf "$WORK"' EXIT

rm -rf "$WORK" && mkdir -p "$WORK/config/yap"
ditto "$APP_DIR/VoiceInk Dev.app" "$APP"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $ID" -c "Set :CFBundleName Yap Mock" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Delete :CFBundleURLTypes" "$APP/Contents/Info.plist" 2>/dev/null || true
codesign --force --deep --sign - "$APP" >/dev/null 2>&1
afconvert -f WAVE -d LEI16@16000 -c 1 "$ROOT/setup/asr/clips/security.m4a" "$WORK/clip.wav"

cleanup
mkdir -p "$SUPPORT/WhisperModels"
defaults write "$ID" hasCompletedOnboardingV2 -bool true
cat >"$WORK/config/yap/config.json" <<JSON
{ "modes": [ { "id": "0FF11E00-0000-4000-8000-000000000002", "name": "Dictation", "isDefault": true,
    "selectedTranscriptionModelName": "$MODEL_NAME", "selectedLanguage": "auto", "isAIEnhancementEnabled": false,
    "useClipboardContext": false, "useSelectedTextContext": false, "useScreenCapture": false } ] }
JSON
XDG_CONFIG_HOME="$WORK/config" "$APP/Contents/MacOS/VoiceInk Dev" --first-run-check "$MODEL_NAME" ${WAIT:+--wait-for-warmup} \
	--dictate-file "$WORK/clip.wav" >"$WORK/out.txt" 2>"$WORK/err.txt" || { echo "app exited with $?:"; tail -5 "$WORK/err.txt"; }
sed -n 's/^first-run: //p' "$WORK/out.txt"
ls "$SUPPORT/WhisperModels" | sed 's/^/models folder: /'
