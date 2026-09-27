#!/bin/bash
# make ui-snapshots: renders every page, Settings group, onboarding screen and sheet (UISnapshots.swift) to
# /tmp/yap-ui/snapshots, in English and then Chinese. Runs a copy of the Debug app re-identified as
# me.sma1lboy.yap.snapshots (AppIdentity), offline (scripts/offline.sb): the managers it builds write fake modes
# and providers into that throwaway defaults domain, which is deleted afterwards with everything else it created.
set -euo pipefail

APP_DIR="$1"                                  # BUILT_PRODUCTS_DIR of the Debug build
ID=me.sma1lboy.yap.snapshots
WORK=/tmp/yap-ui/app
APP="$WORK/Yap Snapshots.app"

cleanup() {
	defaults delete "$ID" >/dev/null 2>&1 || true
	while security delete-generic-password -s "$ID" >/dev/null 2>&1; do :; done
	rm -rf "$HOME/Library/Application Support/$ID" "$HOME/Library/Caches/$ID" "$HOME/Library/HTTPStorages/$ID" \
		"$HOME/Library/Saved Application State/$ID.savedState" "$HOME/Library/WebKit/$ID" "$WORK"
}
cleanup                                       # leftovers from a run that was killed
trap cleanup EXIT

mkdir -p "$WORK"
ditto "$APP_DIR/VoiceInk Dev.app" "$APP"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $ID" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Delete :CFBundleURLTypes" "$APP/Contents/Info.plist" 2>/dev/null || true
codesign --force --deep --sign - "$APP" >/dev/null 2>&1

rm -rf /tmp/yap-ui/snapshots
BIN="$APP/Contents/MacOS/VoiceInk Dev"
sandbox-exec -f "$(dirname "$0")/offline.sb" "$BIN" --render-snapshots
sandbox-exec -f "$(dirname "$0")/offline.sb" "$BIN" --render-snapshots -AppleLanguages '(zh-Hans)'
