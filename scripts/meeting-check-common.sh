# Sourced by scripts/meeting-files-check.sh, meeting-echo-check.sh and meeting-long-check.sh (not run on its own).
# Sets up the Debug app re-identified as me.sma1lboy.yap.mock as a fresh install (see scripts/mock.sh) in $WORK,
# with the Whisper model $MODEL in its support folder and a mode that uses it; converts setup/asr/clips to 16 kHz
# WAVs in $WORK/clips. NOTES=1 gives the mode OpenRouter (deepseek-v4.1-flash) for notes; OPENROUTER_API_KEY comes
# from the environment or ~/.env and is passed only to the mock app, as YAP_MOCK_API_KEY_OPENROUTER.
# The caller sets APP_DIR, MODEL, NOTES and WORK before sourcing.
source "$(dirname "${BASH_SOURCE[0]}")/mock-lock.sh"
ID=me.sma1lboy.yap.mock
APP="$WORK/Yap Mock.app"
SUPPORT="$HOME/Library/Application Support/$ID"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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

for clip in "$ROOT"/setup/asr/clips/*.m4a; do
	afconvert -f WAVE -d LEI16@16000 -c 1 "$clip" "$WORK/clips/$(basename "$clip" .m4a).wav"
done

# say_clip <name> <voice> <text>: a line spoken with a macOS voice, as $WORK/clips/<name>.wav.
say_clip() {
	say -v "$2" -r 230 -o "$WORK/clips/$1.aiff" "$3"
	afconvert -f WAVE -d LEI16@16000 -c 1 "$WORK/clips/$1.aiff" "$WORK/clips/$1.wav"
}

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

# run_app <output file> <arguments…>: the mock app with the check's config; stderr goes to $WORK/err.txt.
run_app() {
	local out="$1"
	shift
	XDG_CONFIG_HOME="$WORK/config" "$APP/Contents/MacOS/VoiceInk Dev" "$@" >"$out" 2>>"$WORK/err.txt" \
		|| { echo "app exited with $?"; grep -v '^\s*$' "$WORK/err.txt" | tail -5; exit 1; }
}

# show <output file> [prefix]: the app's meeting-check lines, without whisper.cpp's log.
show() {
	sed -n '/^meeting-check: /,$p' "$1" | grep -v '^\[.*\] *$' | grep -v "^ggml_\|^whisper_\| --> " | sed "s/^meeting-check: /${2:-}/"
}
