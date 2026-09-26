#!/bin/bash
# make mock: runs the Debug app with fake data (signed in to Yap Cloud with $4.21, 20 transcripts, 5 modes,
# a custom provider, dictionary entries) for clicking through the UI.
#
# The app is copied and re-identified as me.sma1lboy.yap.mock, so it has its own defaults domain, Application
# Support folder and keychain service (AppIdentity.isMock); the dev and release settings are never read or written.
# It runs under a sandbox profile that denies all IP network traffic, and the fake data is seeded on every launch
# (MockEnvironment). Everything it created is deleted when it quits, so the next run starts from the same state.
set -euo pipefail

APP_DIR="$1"                                  # BUILT_PRODUCTS_DIR of the Debug build
ID=me.sma1lboy.yap.mock
WORK=/tmp/yap-mock
MOCK_APP="$WORK/Yap Mock.app"

cleanup() {
	defaults delete "$ID" >/dev/null 2>&1 || true
	while security delete-generic-password -s "$ID" >/dev/null 2>&1; do :; done
	rm -rf "$HOME/Library/Application Support/$ID" "$HOME/Library/Caches/$ID" "$HOME/Library/HTTPStorages/$ID" \
		"$HOME/Library/Saved Application State/$ID.savedState" "$HOME/Library/WebKit/$ID"
	if [ -d "$MOCK_APP" ]; then
		/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
			-u "$MOCK_APP" >/dev/null 2>&1 || true
	fi
	rm -rf "$WORK"
}

cleanup                                       # leftovers from a run that was killed
trap cleanup EXIT

mkdir -p "$WORK/config"
ditto "$APP_DIR/VoiceInk Dev.app" "$MOCK_APP"
PLIST="$MOCK_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $ID" -c "Set :CFBundleName Yap Mock" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Yap Mock" "$PLIST" 2>/dev/null || true
# The dev app's yap-dev:// sign-in callback stays with the dev app.
/usr/libexec/PlistBuddy -c "Delete :CFBundleURLTypes" "$PLIST" 2>/dev/null || true
codesign --force --deep --sign - "$MOCK_APP" >/dev/null 2>&1

echo "Yap Mock is running (offline, fake data). Quit it from the menu bar to clean up."
# XDG_CONFIG_HOME: config.json (and "Write Current Settings to File") go to the throwaway folder.
XDG_CONFIG_HOME="$WORK/config" sandbox-exec -f "$(dirname "$0")/offline.sb" "$MOCK_APP/Contents/MacOS/VoiceInk Dev" || true
