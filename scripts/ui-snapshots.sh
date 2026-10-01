#!/bin/bash
# make ui-snapshots: renders every page, Settings group, onboarding screen and sheet (UISnapshots.swift) to
# /tmp/yap-ui/snapshots, in English, then the main shots in Chinese (zh-Hans, zh-Hant), German and French (the
# longest labels, to catch cut-off text). Runs a copy of the Debug app re-identified as
# me.sma1lboy.yap.snapshots (AppIdentity), offline (scripts/offline.sb): the managers it builds write fake modes
# and providers into that throwaway defaults domain, which is deleted afterwards with everything else it created.
# YAP_UI_SNAPSHOTS_OUT=<dir> writes there instead, so a run in another worktree can't replace the shots before
# they're copied. Runs on one Mac take turns (lock below): they share the bundle id and its defaults.
set -euo pipefail
# The Home feedback shots write SessionMetric fixtures (HomeFeedbackFixture); like every fixture launch they run
# under /tmp/yap-mock.flock, waited for, never broken. Their stores are in memory, in this run's own identity.
source "$(dirname "$0")/mock-lock.sh"

APP_DIR="$1"                                  # BUILT_PRODUCTS_DIR of the Debug build
ID=me.sma1lboy.yap.snapshots
WORK=$(mktemp -d /tmp/yap-ui-app.XXXXXX)          # per run: an older script without the lock deletes /tmp/yap-ui/app
APP="$WORK/Yap Snapshots.app"

OUT="${YAP_UI_SNAPSHOTS_OUT:-/tmp/yap-ui/snapshots}"
LOCK=/tmp/yap-ui-snapshots.lock
until mkdir "$LOCK" 2>/dev/null; do
	holder=$(cat "$LOCK/pid" 2>/dev/null || true)
	if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then rm -rf "$LOCK"; continue; fi   # holder was killed
	echo "ui-snapshots: another run (pid ${holder:-?}) is rendering; waiting…"
	sleep 5
done
echo $$ > "$LOCK/pid"

cleanup() {
	defaults delete "$ID" >/dev/null 2>&1 || true
	while security delete-generic-password -s "$ID" >/dev/null 2>&1; do :; done
	rm -rf "$HOME/Library/Application Support/$ID" "$HOME/Library/Caches/$ID" "$HOME/Library/HTTPStorages/$ID" \
		"$HOME/Library/Saved Application State/$ID.savedState" "$HOME/Library/WebKit/$ID" "$WORK"
}
cleanup                                       # leftovers from a run that was killed
trap 'cleanup; rm -rf "$LOCK"' EXIT

mkdir -p "$WORK"
ditto "$APP_DIR/VoiceInk Dev.app" "$APP"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $ID" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Delete :CFBundleURLTypes" "$APP/Contents/Info.plist" 2>/dev/null || true
codesign --force --deep --sign - "$APP" >/dev/null 2>&1

rm -rf "$OUT"
export YAP_UI_SNAPSHOTS_OUT="$OUT"
BIN="$APP/Contents/MacOS/VoiceInk Dev"
sandbox-exec -f "$(dirname "$0")/offline.sb" "$BIN" --render-snapshots
sandbox-exec -f "$(dirname "$0")/offline.sb" "$BIN" --render-snapshots -AppleLanguages '(zh-Hans)'
sandbox-exec -f "$(dirname "$0")/offline.sb" "$BIN" --render-snapshots -AppleLanguages '(zh-Hant)'
sandbox-exec -f "$(dirname "$0")/offline.sb" "$BIN" --render-snapshots -AppleLanguages '(de)'
sandbox-exec -f "$(dirname "$0")/offline.sb" "$BIN" --render-snapshots -AppleLanguages '(fr)'
