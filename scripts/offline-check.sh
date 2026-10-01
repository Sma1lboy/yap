#!/bin/bash
# make offline-check MODEL=<path to ggml-*.bin>: does one dictation with a local Whisper model and cleanup off touch
# the network? Uses the Debug app re-identified as me.sma1lboy.yap.mock (its own defaults, Application Support and
# keychain; see scripts/mock.sh), set up as a fresh install with one mode: that model, language auto, no cleanup.
# The app is launched with --dictate-file (OfflineCheck.swift), which runs a bench clip through the normal pipeline
# 10 s after launch, prints the result and quits.
#   1. under scripts/offline.sb (all IP traffic denied): the dictation must still produce text;
#   2. with the network allowed, polling the app's sockets every 0.2 s: every connection is listed, marked
#      by whether it was opened during the dictation and whether it's loopback (Ollama on localhost). ponytail: a connection opened and closed
#      between two polls is missed; run 1 is what proves the dictation doesn't need the network.
# The dev and release apps' settings are never read or written. Delivery copies the text to the pasteboard;
# OfflineCheck puts the previous contents back.
set -euo pipefail
source "$(dirname "$0")/mock-lock.sh"

APP_DIR="$1"                                  # BUILT_PRODUCTS_DIR of the Debug build
MODEL="${2:?usage: offline-check.sh <app dir> <ggml-*.bin>}"
ID=me.sma1lboy.yap.mock
WORK=/tmp/yap-offline-check
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

fresh_install() {
	cleanup
	mkdir -p "$SUPPORT/WhisperModels" "$WORK/config/yap"
	cp -c "$MODEL" "$SUPPORT/WhisperModels/" 2>/dev/null || cp "$MODEL" "$SUPPORT/WhisperModels/"
	defaults write "$ID" hasCompletedOnboardingV2 -bool true
	local name
	name=$(basename "$MODEL" .bin)
	cat >"$WORK/config/yap/config.json" <<EOF
{ "modes": [ { "id": "0FF11E00-0000-4000-8000-000000000001", "name": "Offline", "isDefault": true,
    "selectedTranscriptionModelName": "$name", "selectedLanguage": "auto", "isAIEnhancementEnabled": false,
    "useClipboardContext": false, "useSelectedTextContext": false, "useScreenCapture": false } ] }
EOF
}

launch() {  # prefix command..., app stdout goes to $WORK/out.txt
	XDG_CONFIG_HOME="$WORK/config" "$@" "$APP/Contents/MacOS/VoiceInk Dev" --dictate-file "$WORK/clip.wav" \
		>"$WORK/out.txt" 2>"$WORK/err.txt" || { echo "app exited with $?:"; grep -v '^\s*$' "$WORK/err.txt" | tail -5; }
}

report() {  # run name
	local text
	text=$(sed -n 's/^offline-check: text //p' "$WORK/out.txt")
	echo "$1: model $(sed -n 's/^offline-check: model //p' "$WORK/out.txt"), cleanup used: $(sed -n 's/^offline-check: enhanced //p' "$WORK/out.txt"), transcription $(sed -n 's/^offline-check: seconds //p' "$WORK/out.txt" | cut -c1-5) s"
	echo "  text: $text"
	[ -n "$text" ] && [[ "$text" != *"Failed"* ]]
}

rm -rf "$WORK" && mkdir -p "$WORK"
ditto "$APP_DIR/VoiceInk Dev.app" "$APP"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $ID" -c "Set :CFBundleName Yap Mock" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Delete :CFBundleURLTypes" "$APP/Contents/Info.plist" 2>/dev/null || true
codesign --force --deep --sign - "$APP" >/dev/null 2>&1
afconvert -f WAVE -d LEI16@16000 -c 1 "$ROOT/setup/asr/clips/security.m4a" "$WORK/clip.wav"

echo "== 1. network denied (scripts/offline.sb)"
fresh_install
launch sandbox-exec -f "$ROOT/scripts/offline.sb"
report "offline" || { echo "FAIL: no transcript without network"; exit 1; }

echo "== 2. network allowed, sockets logged"
fresh_install
launch &
pid=""
while [ -z "$pid" ]; do pid=$(pgrep -nf "$APP/Contents/MacOS/VoiceInk Dev" || true); sleep 0.1; done
while kill -0 "$pid" 2>/dev/null; do
	lsof -nP -a -p "$pid" -i 2>/dev/null | awk -v t="$(perl -MTime::HiRes=time -e 'printf "%.2f", time')" \
		'NR > 1 { print t, $8, $9 }' >>"$WORK/sockets.txt" || true  # lsof exits 1 when there are no sockets
	sleep 0.2
done
wait || true
report "online" || { echo "FAIL: no transcript with network"; exit 1; }
python3 - "$WORK/out.txt" "$WORK/sockets.txt" <<'PY'
import socket, sys
marks = {l.split()[1]: float(l.split()[2]) for l in open(sys.argv[1]) if l.split()[1:2] and l.split()[1] in ("start", "end")}
known = {}
for host in ["cloud.yap.sma1lboy.me", "yap.sma1lboy.me", "raw.githubusercontent.com", "github.com", "api.github.com",
             "objects.githubusercontent.com", "huggingface.co", "openrouter.ai"]:
    try:
        for info in socket.getaddrinfo(host, 443):
            known[info[4][0]] = host
    except OSError:
        pass
seen = {}
for line in open(sys.argv[2]):
    t, proto, name = line.split(maxsplit=2)
    if "->" not in name:
        continue
    remote = name.split("->")[1].split()[0]
    first, last = seen.get(remote, (float(t), float(t)))
    seen[remote] = (min(first, float(t)), max(last, float(t)))
start, end = marks.get("start"), marks.get("end")
if not (start and end):
    sys.exit("FAIL: no start/end markers")
print(f"dictation window: {end - start:.2f} s")
opened_during = []
for remote, (first, last) in sorted(seen.items(), key=lambda x: x[1]):
    ip = remote.rsplit(":", 1)[0].strip("[]")
    where = "loopback" if ip in ("127.0.0.1", "::1") else known.get(ip, "?")
    when = "opened DURING the dictation" if start <= first <= end else "opened outside the dictation"
    print(f"  {remote:40} {where:28} {when}, seen {first - start:+.1f}s to {last - start:+.1f}s")
    if start <= first <= end and where != "loopback":
        opened_during.append(remote)
if opened_during:
    sys.exit("FAIL: network connections opened during the dictation")
print("no network connection was opened during the dictation")
PY
