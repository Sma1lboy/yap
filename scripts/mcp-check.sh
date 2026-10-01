#!/bin/bash
# make mcp-check: yap-mcp, the read-only MCP server in Yap.app/Contents/Helpers (docs/mcp.md), against fixture
# data. Uses a copy of the Debug app re-identified as me.sma1lboy.yap.mock (see scripts/mock.sh): launched with
# --mcp-fixture (MCPFixture.swift) it writes a data folder (three meetings, one with renamed speakers, dictations,
# and a dictionary, left with the stores' -wal as a running Yap has them) plus History's Markdown export of each
# meeting, and quits. Then scripts/mcp-check.py feeds the copy's own Contents/Helpers/yap-mcp every tool with
# Settings › Agent Access (MCP) all off, the main switch only, and both on (switched with `defaults write` in the
# copy's defaults, mid-session), in English and with the app's language set to Chinese. It checks every answer:
# every stdout line is JSON-RPC, only read-only tools are listed, get_meeting is byte for byte the app's export,
# search_history / get_dictation / get_dictionary return the fixture's entries, each switch's errors name it, every
# file in the data folder has the same SHA-256 afterwards, `lsof -a -p <pid> -i` shows no socket, and closing stdin
# ends the process. Last, the copy launched with --mcp-fixture-writer keeps saving dictations while the helper
# searches: every answer must be a consistent history or a "busy" error.
set -euo pipefail

APP_DIR="$1"
WORK=/tmp/yap-mcp-check
ID=me.sma1lboy.yap.mock
APP="$WORK/Yap Mock.app"
HELPER="$APP/Contents/Helpers/yap-mcp"

cleanup() {
	pkill -f -- "--mcp-fixture-writer $WORK" 2>/dev/null || true   # the concurrent writer, if the run was cut short
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

APP_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
HELPER_VERSION=$("$HELPER" --version 2>/dev/null)
echo "app $APP_VERSION, $HELPER_VERSION"
[ "$HELPER_VERSION" = "yap-mcp $APP_VERSION" ] || { echo "FAIL: the helper's version isn't the app's"; exit 1; }

# The helper picks the app's language only among the localizations its Info.plist declares (YapMCP/Info.plist).
APP_LANGS=$(cd "$APP/Contents/Resources" && ls -d *.lproj | sed 's/\.lproj$//' | grep -vx Base | sort | tr '\n' ' ')
HELPER_LANGS=$(launchctl plist __TEXT,__info_plist "$HELPER" | sed -n '/CFBundleLocalizations/,/);/p' | grep -o '"[^"]*";' \
	| tr -d '";' | sort | tr '\n' ' ')
[ "$APP_LANGS" = "$HELPER_LANGS" ] || { echo "FAIL: app languages ($APP_LANGS) aren't YapMCP/Info.plist's ($HELPER_LANGS)"; exit 1; }
echo "languages: $APP_LANGS"
# hashes <folder>: every file's SHA-256, by path.
hashes() { (cd "$1" && find . -type f -print0 | sort -z | xargs -0 shasum -a 256); }

for lang in en zh-Hans; do
	defaults write "$ID" AppleLanguages -array "$lang"
	dir="$WORK/$lang"
	mkdir -p "$dir"
	"$APP/Contents/MacOS/VoiceInk Dev" --mcp-fixture "$dir/data" "$dir/expected" >"$dir/fixture.txt" 2>"$dir/fixture-err.txt" \
		|| { echo "FAIL: the fixture app exited with $?"; cat "$dir/fixture.txt"; tail -5 "$dir/fixture-err.txt"; exit 1; }
	[ "$(grep -c '^mcp-fixture: ' "$dir/fixture.txt")" = 6 ] || { echo "FAIL: no fixture"; cat "$dir/fixture.txt"; exit 1; }
	[ -s "$dir/data/default.store-wal" ] || { echo "FAIL: the fixture store has no -wal to read through"; exit 1; }
	echo "$lang: fixture with $(ls "$dir/expected" | wc -l | tr -d ' ') meetings, default.store-wal $(stat -f %z "$dir/data/default.store-wal") bytes"
	hashes "$dir/data" >"$dir/before.txt"
	python3 "$(dirname "$0")/mcp-check.py" tools "$HELPER" "$dir" "$APP_VERSION" "$lang" "$ID"
	hashes "$dir/data" >"$dir/after.txt"
	cmp -s "$dir/before.txt" "$dir/after.txt" || { echo "FAIL: the data folder changed"; diff "$dir/before.txt" "$dir/after.txt"; exit 1; }
	echo "$lang: SHA-256 of all $(wc -l <"$dir/before.txt" | tr -d ' ') files in the data folder unchanged"
done

dir="$WORK/concurrent"
mkdir -p "$dir"
python3 "$(dirname "$0")/mcp-check.py" concurrent "$HELPER" "$APP/Contents/MacOS/VoiceInk Dev" "$dir" "$ID"
echo "mcp-check: OK"
