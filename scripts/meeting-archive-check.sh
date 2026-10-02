#!/bin/bash
# make meeting-archive-check: History's Save Meetings to Folder… (MeetingArchive) writing real files, run from a copy
# of the Debug app re-identified as me.sma1lboy.yap.mock (see scripts/mock.sh) under the mock lock, on a History
# store in a test folder (--meeting-archive-check, MeetingArchiveCheck.swift). The time zone (TZ), language and
# locale (-AppleLanguages, -AppleLocale) are set explicitly on every launch, since they change the Markdown's bytes.
# scripts/meeting-archive-check.py runs the cases and checks every file's bytes and identity; see there.
set -euo pipefail
source "$(dirname "$0")/mock-lock.sh"

APP_DIR="$1"
WORK=/tmp/yap-archive-check
ID=me.sma1lboy.yap.mock
APP="$WORK/Yap Mock.app"

cleanup() {
	defaults delete "$ID" >/dev/null 2>&1 || true
	# Case 7k launches the whole app once (settings export and import), which can leave these too.
	while security delete-generic-password -s "$ID" >/dev/null 2>&1; do :; done
	rm -rf "$HOME/Library/Application Support/$ID" "$HOME/Library/Caches/$ID" "$HOME/Library/HTTPStorages/$ID" \
		"$HOME/Library/Saved Application State/$ID.savedState" "$HOME/Library/WebKit/$ID"
	chmod -R u+rwx "$WORK" 2>/dev/null || true   # the read-only and unreadable cases
}
trap 'cleanup; rm -rf "$WORK"' EXIT
cleanup
rm -rf "$WORK" && mkdir -p "$WORK"

ditto "$APP_DIR/VoiceInk Dev.app" "$APP"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $ID" -c "Set :CFBundleName Yap Mock" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Delete :CFBundleURLTypes" "$APP/Contents/Info.plist" 2>/dev/null || true
codesign --force --deep --sign - "$APP" >/dev/null 2>&1

python3 "$(dirname "$0")/meeting-archive-check.py" "$APP/Contents/MacOS/VoiceInk Dev" "$WORK"
