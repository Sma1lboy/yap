#!/bin/bash
# make model-residency-check MODEL=<path to ggml-*.bin>: how much memory does Yap hold while a local Whisper model is
# loaded, and how long does the first dictation after the release wait? The Debug app re-identified as
# me.sma1lboy.yap.mock (own defaults, Application Support and keychain; see scripts/offline-check.sh) runs
# OfflineCheck's --residency-check with "Keep model loaded" set to KEEP seconds (default 5): dictate (load), idle until
# ModelResidency releases the model, dictate again, once without and once with the preload the shortcut press starts.
# `footprint` samples the process every second. The dev and release apps' settings are never read or written.
set -euo pipefail

APP_DIR="$1"
MODEL="${2:?usage: model-residency-check.sh <app dir> <ggml-*.bin>}"
KEEP="${KEEP:-5}"
ID=me.sma1lboy.yap.mock
WORK=/tmp/yap-residency-check
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

rm -rf "$WORK" && mkdir -p "$WORK/config/yap"
ditto "$APP_DIR/VoiceInk Dev.app" "$APP"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $ID" -c "Set :CFBundleName Yap Mock" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Delete :CFBundleURLTypes" "$APP/Contents/Info.plist" 2>/dev/null || true
# Nested bundles first, then the app: `codesign --deep` fails on the XPC service under a full disk.
for nested in "$APP"/Contents/Frameworks/*.framework "$APP"/Contents/XPCServices/*.xpc; do
	for _ in 1 2 3; do codesign --force --sign - "$nested" >/dev/null 2>&1 && break; sleep 2; done  # flaky when the disk is full
done
codesign --force --sign - "$APP" >/dev/null 2>&1
afconvert -f WAVE -d LEI16@16000 -c 1 "$ROOT/setup/asr/clips/security.m4a" "$WORK/clip.wav"

cleanup
mkdir -p "$SUPPORT/WhisperModels"
cp -c "$MODEL" "$SUPPORT/WhisperModels/" 2>/dev/null || cp "$MODEL" "$SUPPORT/WhisperModels/"
defaults write "$ID" hasCompletedOnboardingV2 -bool true
defaults write "$ID" ModelKeepLoadedSeconds -int "$KEEP"
name=$(basename "$MODEL" .bin)
cat >"$WORK/config/yap/config.json" <<EOF
{ "modes": [ { "id": "0FF11E00-0000-4000-8000-000000000001", "name": "Offline", "isDefault": true,
    "selectedTranscriptionModelName": "$name", "selectedLanguage": "auto", "isAIEnhancementEnabled": false,
    "useClipboardContext": false, "useSelectedTextContext": false, "useScreenCapture": false } ] }
EOF

XDG_CONFIG_HOME="$WORK/config" "$APP/Contents/MacOS/VoiceInk Dev" --dictate-file "$WORK/clip.wav" --residency-check \
	>"$WORK/out.txt" 2>"$WORK/err.txt" &
app=$!
pid=""
while [ -z "$pid" ] && kill -0 "$app" 2>/dev/null; do pid=$(pgrep -nf "$APP/Contents/MacOS/VoiceInk Dev" || true); sleep 0.1; done
while kill -0 "$pid" 2>/dev/null; do
	mb=$(footprint "$pid" 2>/dev/null | awk '/Footprint:/ { for (i = 1; i < NF; i++) if ($i == "Footprint:") { v = $(i+1); u = $(i+2) }
		if (u == "GB") v *= 1024; else if (u == "KB") v /= 1024; printf "%.0f", v; exit }' || true)
	[ -n "$mb" ] && echo "$(perl -MTime::HiRes=time -e 'printf "%.2f", time') $mb" >>"$WORK/footprint.txt"
	sleep 1
done
wait "$app" || { echo "app exited with $?:"; grep -v '^\s*$' "$WORK/err.txt" | tail -5; }
grep '^residency: dictation' "$WORK/out.txt" || { echo "FAIL: no dictation results"; exit 1; }
python3 - "$WORK/out.txt" "$WORK/footprint.txt" <<'PY'
import sys
marks = [(" ".join(l.split()[2:-1]), float(l.split()[-1])) for l in open(sys.argv[1]) if l.startswith("residency: mark ")]
samples = [tuple(map(float, l.split())) for l in open(sys.argv[2])]
print("footprint (MB, largest sample in the 2 s before each marker, and the peak):")
for name, t in marks:
    near = [mb for ts, mb in samples if t - 2 <= ts <= t]
    print(f"  {name:36} {max(near) if near else float('nan'):8.0f}")
print(f"  {'peak':36} {max(mb for _, mb in samples):8.0f}")
PY
