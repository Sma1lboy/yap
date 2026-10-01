#!/bin/bash
# make mcp-check: yap-mcp, the read-only MCP server in Yap.app/Contents/Helpers (docs/mcp.md), against fixture
# data. Uses a copy of the Debug app re-identified as me.sma1lboy.yap.mock (see scripts/mock.sh): launched with
# --mcp-fixture (MCPFixture.swift) it writes a data folder (three meetings, one with renamed speakers, and a
# dictation, left with the store's -wal as a running Yap has it) plus History's Markdown export of each meeting,
# and quits. Then the copy's own Contents/Helpers/yap-mcp is fed initialize → notifications/initialized → tools/list
# → tools/call list_meetings / get_meeting and the error cases, and the run checks: every stdout line is JSON-RPC,
# only read-only tools are listed, get_meeting is byte for byte the app's export (in English and, with the mock
# app's language set to Chinese, in Chinese), unknown ids are tool errors, every file in the data folder has the
# same SHA-256 afterwards, `lsof -a -p <pid> -i` shows no socket, and closing stdin ends the process.
set -euo pipefail

APP_DIR="$1"
WORK=/tmp/yap-mcp-check
ID=me.sma1lboy.yap.mock
APP="$WORK/Yap Mock.app"
HELPER="$APP/Contents/Helpers/yap-mcp"

cleanup() {
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
	[ "$(grep -c '^mcp-fixture: ' "$dir/fixture.txt")" = 4 ] || { echo "FAIL: no fixture"; cat "$dir/fixture.txt"; exit 1; }
	[ -s "$dir/data/default.store-wal" ] || { echo "FAIL: the fixture store has no -wal to read through"; exit 1; }
	echo "$lang: fixture with $(ls "$dir/expected" | wc -l | tr -d ' ') meetings, default.store-wal $(stat -f %z "$dir/data/default.store-wal") bytes"
	hashes "$dir/data" >"$dir/before.txt"
	python3 - "$HELPER" "$dir" "$APP_VERSION" "$lang" <<'PY'
import datetime, json, os, subprocess, sys, uuid

helper, folder, version, lang = sys.argv[1:5]
roles = {}
for line in open(os.path.join(folder, "fixture.txt")):
    if line.startswith("mcp-fixture: "):
        _, role, entry = line.split()
        roles[role] = entry


class Session:
    """One yap-mcp process; every stdout line it writes is read here and must be one JSON-RPC message."""

    def __init__(self, data):
        self.stderr = open(os.path.join(folder, "helper-stderr.txt"), "a")
        self.process = subprocess.Popen([helper, "--data-dir", data], stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=self.stderr, bufsize=0)
        self.lines = 0
        self.next_id = 0

    def fail(self, message):
        print("FAIL (%s): %s" % (lang, message))
        self.process.kill()
        sys.exit(1)

    def write(self, text):
        self.process.stdin.write((text + "\n").encode())

    def read(self):
        line = self.process.stdout.readline()
        if not line:
            self.fail("stdout closed early")
        self.lines += 1
        try:
            message = json.loads(line)
        except ValueError:
            self.fail("stdout line %d isn't JSON: %r" % (self.lines, line[:200]))
        if not isinstance(message, dict) or message.get("jsonrpc") != "2.0" or ("result" in message) == ("error" in message):
            self.fail("stdout line %d isn't a JSON-RPC response: %r" % (self.lines, line[:200]))
        return message

    def rpc(self, method, params=None):
        request = {"jsonrpc": "2.0", "id": self.next_id, "method": method}
        if params is not None:
            request["params"] = params
        self.next_id += 1
        self.write(json.dumps(request))
        answer = self.read()
        if answer.get("id") != request["id"]:
            self.fail("%s: answer for id %r, expected %r" % (method, answer.get("id"), request["id"]))
        return answer

    def call(self, name, **arguments):
        answer = self.rpc("tools/call", {"name": name, "arguments": arguments})
        if "result" not in answer:
            self.fail("%s: %r" % (name, answer))
        return answer["result"]

    def close(self):
        """Closing stdin must end the process, with nothing more on stdout."""
        self.process.stdin.close()
        try:
            code = self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.fail("still running 5 s after stdin closed")
        if code != 0:
            self.fail("exited with %d" % code)
        rest = self.process.stdout.read()
        if rest:
            self.fail("wrote after stdin closed: %r" % rest[:200])


def check(condition, message):
    if not condition:
        print("FAIL (%s): %s" % (lang, message))
        sys.exit(1)


s = Session(os.path.join(folder, "data"))
init = s.rpc("initialize", {"protocolVersion": "2025-11-25", "capabilities": {},
                            "clientInfo": {"name": "mcp-check", "version": "1"}})["result"]
check(init["protocolVersion"] == "2025-11-25", "initialize: %r" % init)
check(init["capabilities"] == {"tools": {}}, "capabilities other than tools: %r" % init["capabilities"])
check(init["serverInfo"]["version"] == version, "serverInfo.version %r, app %s" % (init["serverInfo"], version))
s.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}))
check(s.rpc("ping")["result"] == {}, "ping")
check(s.rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "x", "version": "1"}})
      ["result"]["protocolVersion"] == "2025-06-18", "an older supported version isn't kept")
check(s.rpc("initialize", {"protocolVersion": "1999-01-01", "capabilities": {}, "clientInfo": {"name": "x", "version": "1"}})
      ["result"]["protocolVersion"] == "2025-11-25", "an unknown version doesn't get the newest")

tools = s.rpc("tools/list")["result"]["tools"]
check([t["name"] for t in tools] == ["list_meetings", "get_meeting"], "tools: %r" % [t["name"] for t in tools])
check(all(t["annotations"]["readOnlyHint"] is True and t["annotations"]["destructiveHint"] is False for t in tools),
      "a tool isn't marked read-only")

listed = s.call("list_meetings")
check(listed["isError"] is False, "list_meetings: %r" % listed)
check(json.loads(listed["content"][0]["text"]) == listed["structuredContent"], "text and structuredContent differ")
meetings = listed["structuredContent"]["meetings"]
by_id = {m["id"]: m for m in meetings}
check([m["id"] for m in meetings] == [roles["pending"], roles["renamed"], roles["failed"]],
      "not the three meetings, newest first: %r" % [m["id"] for m in meetings])
check(listed["structuredContent"]["more"] is False, "more with everything listed")
renamed, pending, failed = by_id[roles["renamed"]], by_id[roles["pending"]], by_id[roles["failed"]]
check(renamed["speakers"] == ["Tingting", "Reed", "Shelley"], "renamed speakers: %r" % renamed["speakers"])
check(renamed["has_notes"] and renamed["untranscribed_parts"] == 1 and renamed["speaker_separation"] == "done"
      and renamed["duration_seconds"] == 3634, "renamed meeting: %r" % renamed)
check(datetime.datetime.fromisoformat(renamed["started_at"]) == datetime.datetime(2026, 9, 29, 15, 0).astimezone(),
      "started_at %s" % renamed["started_at"])
check(pending["speaker_separation"] == "pending" and not pending["has_notes"] and len(pending["speakers"]) == 2
      and "untranscribed_parts" not in pending, "pending meeting: %r" % pending)
check(failed["speaker_separation"] == "failed" and failed["has_notes"], "failed meeting: %r" % failed)
check(all(m["title"] for m in meetings), "a meeting without a title")

one = s.call("list_meetings", limit=1)["structuredContent"]
check([m["id"] for m in one["meetings"]] == [roles["pending"]] and one["more"] is True, "limit 1: %r" % one)
day = s.call("list_meetings", since="2026-09-29", until="2026-09-29")["structuredContent"]["meetings"]
check([m["id"] for m in day] == [roles["renamed"]], "one day: %r" % day)
later = s.call("list_meetings", since=renamed["started_at"])["structuredContent"]["meetings"]
check([m["id"] for m in later] == [roles["pending"], roles["renamed"]], "since a date-time: %r" % later)
for bad in [{"limit": 0}, {"limit": 101}, {"limit": "5"}, {"limit": True}, {"since": "yesterday"}, {"until": "2026-13-01"},
            {"query": "x"}]:
    check(s.call("list_meetings", **bad)["isError"] is True, "not a tool error: %r" % bad)

same = 0
for role in ["renamed", "pending", "failed"]:
    entry = roles[role]
    want = open(os.path.join(folder, "expected", entry + ".md"), "rb").read()
    got = s.call("get_meeting", id=entry)
    check(got["isError"] is False and got["content"][0]["text"].encode() == want,
          "get_meeting %s isn't History's export:\n--- got\n%s\n--- want\n%s"
          % (role, got["content"][0]["text"], want.decode()))
    notes = s.call("get_meeting", id=entry.lower(), include_transcript=False)["content"][0]["text"]
    check(want.decode().startswith(notes[:-1] + "\n\n## ") and "**[" not in notes, "notes only, %s: %r" % (role, notes))
    same += 1
renamed_md = open(os.path.join(folder, "expected", roles["renamed"] + ".md")).read()
check("**[00:21] Reed**" in renamed_md and "Tingting" in renamed_md and "Others" not in renamed_md,
      "the export doesn't have the new names")
if lang != "en":
    check(not renamed_md.startswith("# Meeting\n"), "the %s export is in English" % lang)

for bad in [{"id": str(uuid.uuid4())}, {"id": roles["dictation"]}, {"id": "not-an-id"}, {},
            {"id": roles["renamed"], "include_transcript": "no"}]:
    check(s.call("get_meeting", **bad)["isError"] is True, "not a tool error: %r" % bad)
check(s.rpc("tools/call", {"name": "delete_meeting", "arguments": {}})["error"]["code"] == -32602, "unknown tool")
check(s.rpc("resources/list")["error"]["code"] == -32601, "unknown method")
check(s.rpc("server/discover")["error"]["code"] == -32601, "server/discover")
s.write("{not json")
check(s.read() == {"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "Parse error"}}, "parse error")

sockets = subprocess.run(["lsof", "-a", "-p", str(s.process.pid), "-i"], capture_output=True, text=True).stdout
check(sockets == "", "network sockets open:\n" + sockets)
s.close()
print("%s: %d stdout lines, all JSON-RPC; tools: %s (read-only); list_meetings: %d meetings, newest first, no "
      "dictation; get_meeting = History's export byte for byte for %d meetings; unknown ids are tool errors; "
      "no network socket (lsof -i); exited when stdin closed"
      % (lang, s.lines, ", ".join(t["name"] for t in tools), len(meetings), same))

# No data folder at all: empty list, unknown id, no crash.
e = Session(os.path.join(folder, "no-such-folder"))
e.rpc("initialize", {"protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {"name": "x", "version": "1"}})
check(e.call("list_meetings")["structuredContent"] == {"meetings": [], "more": False}, "missing folder: not empty")
check(e.call("get_meeting", id=roles["renamed"])["isError"] is True, "missing folder: get_meeting")
e.close()
check(not os.path.exists(os.path.join(folder, "no-such-folder")), "the missing folder was created")
print("%s: missing data folder: empty list, get_meeting a tool error" % lang)
PY
	hashes "$dir/data" >"$dir/after.txt"
	cmp -s "$dir/before.txt" "$dir/after.txt" || { echo "FAIL: the data folder changed"; diff "$dir/before.txt" "$dir/after.txt"; exit 1; }
	echo "$lang: SHA-256 of all $(wc -l <"$dir/before.txt" | tr -d ' ') files in the data folder unchanged"
done
echo "mcp-check: OK"
