#!/bin/bash
# make mcp-perf: how long yap-mcp's tools take on a big history (docs/mcp.md › Speed). A copy of the Debug app under
# its own bundle id (me.sma1lboy.yap.perf, both agent-access switches on, deleted afterwards) writes two years of
# heavy use with --mcp-fixture-large (MCPEvalFixture.swift: 20,000 dictations, 200 hour-long meetings), kept in
# /tmp/yap-mcp-perf/data between runs (FRESH=1 writes it again). The copy's helper is then swapped for a Release
# build of yap-mcp (optimized, as shipped). scripts/mcp-perf.py times every tool in a new helper process each time
# (cold) and many times in one process (warm), with the helper's --log-timing breakdown (copying the store, opening
# the copy, reading), and the data folder's SHA-256 must be the same afterwards.
set -euo pipefail

APP_DIR="$1"
WORK=/tmp/yap-mcp-perf
ID=me.sma1lboy.yap.perf
APP="$WORK/Yap Perf.app"

cleanup() {
	defaults delete "$ID" >/dev/null 2>&1 || true
	rm -rf "$HOME/Library/Application Support/$ID" "$APP"
}
trap cleanup EXIT
cleanup
mkdir -p "$WORK"
ditto "$APP_DIR/VoiceInk Dev.app" "$APP"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $ID" -c "Set :CFBundleName Yap Perf" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Delete :CFBundleURLTypes" "$APP/Contents/Info.plist" 2>/dev/null || true
codesign --force --deep --sign - "$APP" >/dev/null 2>&1
defaults write "$ID" AppleLanguages -array en
defaults write "$ID" agentAccessEnabled -bool true
defaults write "$ID" agentAccessIncludesDictations -bool true

# HELPER=<yap-mcp binary> times that build instead, e.g. one built from an older commit.
HELPER="${HELPER:-$WORK/release/sym/Release/yap-mcp}"
if [ "$HELPER" = "$WORK/release/sym/Release/yap-mcp" ]; then
	xcodebuild -project VoiceInk.xcodeproj -target yap-mcp -configuration Release CODE_SIGN_IDENTITY="" CODE_SIGNING_ALLOWED=NO \
		SYMROOT="$WORK/release/sym" OBJROOT="$WORK/release/obj" build >"$WORK/release.log" 2>&1 \
		|| { echo "FAIL: the Release build of yap-mcp"; grep error: "$WORK/release.log"; exit 1; }
fi

if [ "${FRESH:-0}" = 1 ] || [ ! -s "$WORK/data/default.store" ]; then
	rm -rf "$WORK/data"
	"$APP/Contents/MacOS/VoiceInk Dev" --mcp-fixture-large "$WORK/data" >"$WORK/fixture.txt" 2>/dev/null \
		|| { echo "FAIL: the fixture app exited with $?"; cat "$WORK/fixture.txt"; exit 1; }
	grep -q '^mcp-fixture: entries 20200$' "$WORK/fixture.txt" || { echo "FAIL: no fixture"; cat "$WORK/fixture.txt"; exit 1; }
fi
echo "data: $(grep '^mcp-fixture: entries' "$WORK/fixture.txt" | cut -d' ' -f3) History entries, written in $(grep '^mcp-fixture: seconds' "$WORK/fixture.txt" | cut -d' ' -f3) s;" \
	"default.store $(du -k "$WORK/data/default.store" | cut -f1) KB + -wal $(du -k "$WORK/data/default.store-wal" | cut -f1) KB"
cp "$HELPER" "$APP/Contents/Helpers/yap-mcp"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1

hashes() { (cd "$1" && find . -type f -print0 | sort -z | xargs -0 shasum -a 256); }
copies() { find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'yap-mcp-*' 2>/dev/null | sort; }
hashes "$WORK/data" >"$WORK/before.txt"
copies >"$WORK/copies-before.txt"
python3 "$(dirname "$0")/mcp-perf.py" "$APP/Contents/Helpers/yap-mcp" "$WORK/data" "$WORK"
hashes "$WORK/data" >"$WORK/after.txt"
cmp -s "$WORK/before.txt" "$WORK/after.txt" || { echo "FAIL: the data folder changed"; exit 1; }
echo "SHA-256 of all $(wc -l <"$WORK/before.txt" | tr -d ' ') files in the data folder unchanged"
copies | cmp -s - "$WORK/copies-before.txt" || { echo "FAIL: a helper left its copy in ${TMPDIR:-/tmp}"; copies; exit 1; }
echo "no copy left behind in ${TMPDIR:-/tmp}"
