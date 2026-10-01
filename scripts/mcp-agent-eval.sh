#!/bin/bash
# make mcp-agent-eval [LABEL=<name>]: real agents (Codex CLI, and Claude Code when it isn't over its limit) answer ten
# questions about a month of fixture data through yap-mcp (docs/mcp.md › Verify › Agents). Three copies of the
# Debug app, each under its own bundle id and so its own Settings › Agent Access (MCP): both switches on, the main
# switch only, both off. Each copy writes the same month (--mcp-fixture-month, MCPEvalFixture.swift) and its own
# Contents/Helpers/yap-mcp is what the agents get, registered with `codex mcp add` in a throwaway CODEX_HOME (only
# auth.json is copied from ~/.codex; nothing there is written) and, for Claude Code, a --strict-mcp-config file.
# scripts/mcp-agent-eval.py asks the questions, records which tools each agent called and how often, and checks
# each answer against its expected facts. A CLI that's missing or not signed in is skipped with the reason.
# Results: /tmp/yap-mcp-eval/<LABEL>/ (results.md, one folder per agent with every transcript).
set -euo pipefail

APP_DIR="$1"
LABEL="${2:-run}"
WORK=/tmp/yap-mcp-eval
OUT="$WORK/$LABEL"
STATES=(all main off)

domain() { echo "me.sma1lboy.yap.eval-$1"; }
cleanup() {
	for state in "${STATES[@]}"; do
		defaults delete "$(domain "$state")" >/dev/null 2>&1 || true
		rm -rf "$HOME/Library/Application Support/$(domain "$state")"
	done
	rm -rf "$WORK/apps"
}
trap cleanup EXIT
cleanup
rm -rf "$OUT" && mkdir -p "$OUT" "$WORK/apps"

for state in "${STATES[@]}"; do
	id=$(domain "$state")
	app="$WORK/apps/$state/Yap Eval.app"
	mkdir -p "$WORK/apps/$state"
	ditto "$APP_DIR/VoiceInk Dev.app" "$app"
	/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $id" -c "Set :CFBundleName Yap Eval" "$app/Contents/Info.plist"
	/usr/libexec/PlistBuddy -c "Delete :CFBundleURLTypes" "$app/Contents/Info.plist" 2>/dev/null || true
	codesign --force --deep --sign - "$app" >/dev/null 2>&1
	# The questions are in Chinese, as the user who'd ask them would have Yap in Chinese.
	defaults write "$id" AppleLanguages -array "${EVAL_LANG:-zh-Hans}"
	case "$state" in
	all) defaults write "$id" agentAccessEnabled -bool true; defaults write "$id" agentAccessIncludesDictations -bool true ;;
	main) defaults write "$id" agentAccessEnabled -bool true ;;
	off) ;;
	esac
	"$app/Contents/MacOS/VoiceInk Dev" --mcp-fixture-month "$WORK/apps/$state/data" >"$OUT/fixture-$state.txt" 2>/dev/null \
		|| { echo "FAIL: the fixture app exited with $?"; cat "$OUT/fixture-$state.txt"; exit 1; }
	grep -q '^mcp-fixture: entries ' "$OUT/fixture-$state.txt" || { echo "FAIL: no fixture"; cat "$OUT/fixture-$state.txt"; exit 1; }
done
echo "fixture: $(grep '^mcp-fixture: entries' "$OUT/fixture-all.txt" | cut -d' ' -f3) History entries, today $(grep '^mcp-fixture: today' "$OUT/fixture-all.txt" | cut -d' ' -f3)"

python3 "$(dirname "$0")/mcp-agent-eval.py" "$WORK/apps" "$OUT"
