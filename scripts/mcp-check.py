#!/usr/bin/env python3
"""make mcp-check's driver (scripts/mcp-check.sh runs it): feeds yap-mcp over stdio and checks every answer.

  mcp-check.py tools <helper> <folder> <app version> <lang> <defaults domain>
      Against the fixture in <folder> (data/, expected/, fixture.txt), with Settings › Agent Access (MCP) all off,
      then the main switch only, then both: every tool, its arguments and its errors.
  mcp-check.py concurrent <helper> <app binary> <folder> <defaults domain>
      While the app's --mcp-fixture-writer keeps saving dictations into <folder>/data, the helper must answer with
      a consistent state of the history or a "busy" tool error, never a torn one, and must not crash.
"""
import datetime, glob, json, os, re, subprocess, sys, tempfile, threading, time, uuid

TOOLS = ["list_meetings", "get_meeting", "search_history", "get_dictation", "get_dictionary"]
# Settings › Agent Access (MCP) as Yap shows it; the helper's "turn this on" errors quote these.
TITLES = {
    "en": {"section": "Agent Access (MCP)", "enabled": "Let Agents Read Yap's Data", "dictations": "Include Dictation History"},
    "zh-Hans": {"section": "Agent 访问（MCP）", "enabled": "让 agent 读取 Yap 的数据", "dictations": "包括听写历史"},
}
ENABLED, DICTATIONS = "agentAccessEnabled", "agentAccessIncludesDictations"
WRITER_FILLER = "0123456789abcdef" * 512
lang = "en"


def fail(message):
    print("FAIL (%s): %s" % (lang, message))
    sys.exit(1)


def check(condition, message):
    if not condition:
        fail(message)


def switches(domain, enabled, dictations):
    """Sets the app's two switches the way its Settings toggles store them; None removes the value (never set)."""
    for key, value in ((ENABLED, enabled), (DICTATIONS, dictations)):
        if value is None:
            subprocess.run(["defaults", "delete", domain, key], capture_output=True)
        else:
            subprocess.run(["defaults", "write", domain, key, "-bool", "true" if value else "false"], check=True)


class Session:
    """One yap-mcp process; every stdout line it writes is read here and must be one JSON-RPC message."""

    def __init__(self, helper, data, stderr):
        self.stderr = open(stderr, "a")
        self.process = subprocess.Popen([helper, "--data-dir", data], stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=self.stderr, bufsize=0)
        self.lines = 0
        self.next_id = 0

    def fail(self, message):
        self.process.kill()
        fail(message)

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

    def initialize(self):
        return self.rpc("initialize", {"protocolVersion": "2025-11-25", "capabilities": {},
                                       "clientInfo": {"name": "mcp-check", "version": "1"}})["result"]

    def call(self, name, **arguments):
        answer = self.rpc("tools/call", {"name": name, "arguments": arguments})
        if "result" not in answer:
            self.fail("%s: %r" % (name, answer))
        return answer["result"]

    def ok(self, name, **arguments):
        """A successful call's structuredContent (whose JSON is also the first text item)."""
        result = self.call(name, **arguments)
        check(result["isError"] is False, "%s %r: %r" % (name, arguments, result))
        if "structuredContent" in result:
            check(json.loads(result["content"][0]["text"]) == result["structuredContent"],
                  "%s: text and structuredContent differ" % name)
            return result["structuredContent"]
        return result

    def error(self, name, **arguments):
        """A tool error's message."""
        result = self.call(name, **arguments)
        check(result["isError"] is True, "not a tool error: %s %r: %r" % (name, arguments, result))
        return result["content"][0]["text"]

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


def tools(helper, folder, version, domain):
    roles = {}
    for line in open(os.path.join(folder, "fixture.txt")):
        if line.startswith("mcp-fixture: "):
            _, role, entry = line.split()
            roles[role] = entry
    titles = TITLES[lang]
    stderr = os.path.join(folder, "helper-stderr.txt")

    switches(domain, None, None)
    s = Session(helper, os.path.join(folder, "data"), stderr)
    init = s.initialize()
    check(init["protocolVersion"] == "2025-11-25", "initialize: %r" % init)
    check(init["capabilities"] == {"tools": {}}, "capabilities other than tools: %r" % init["capabilities"])
    check(init["serverInfo"]["version"] == version, "serverInfo.version %r, app %s" % (init["serverInfo"], version))
    s.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}))
    check(s.rpc("ping")["result"] == {}, "ping")
    check(s.rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "x", "version": "1"}})
          ["result"]["protocolVersion"] == "2025-06-18", "an older supported version isn't kept")
    check(s.rpc("initialize", {"protocolVersion": "1999-01-01", "capabilities": {}, "clientInfo": {"name": "x", "version": "1"}})
          ["result"]["protocolVersion"] == "2025-11-25", "an unknown version doesn't get the newest")

    listed_tools = s.rpc("tools/list")["result"]["tools"]
    check([t["name"] for t in listed_tools] == TOOLS, "tools: %r" % [t["name"] for t in listed_tools])
    check(all(t["annotations"]["readOnlyHint"] is True and t["annotations"]["destructiveHint"] is False
              for t in listed_tools), "a tool isn't marked read-only")

    # 1. Both switches off, as installed: the session works, every call is a tool error saying where to turn it on.
    valid = {"list_meetings": {}, "get_meeting": {"id": roles["renamed"]}, "search_history": {"query": "CI"},
             "get_dictation": {"id": roles["mixed"]}, "get_dictionary": {}}
    for name in TOOLS:
        message = s.error(name, **valid[name])
        check(titles["enabled"] in message and titles["section"] in message and "Yap ›" in message,
              "all off, %s: %r" % (name, message))
    check(s.rpc("tools/call", {"name": "delete_meeting", "arguments": {}})["error"]["code"] == -32602, "unknown tool, off")
    switches(domain, None, True)
    check(titles["enabled"] in s.error("get_dictionary"), "the dictations switch alone opened something")
    print("%s: all switches off: initialize and tools/list answer, all 5 tools are tool errors naming \"%s\""
          % (lang, titles["enabled"]))

    # 2. The main switch only, in the same session (the next call sees it): meetings and the dictionary.
    switches(domain, True, None)
    listed = s.ok("list_meetings")
    meetings = listed["meetings"]
    by_id = {m["id"]: m for m in meetings}
    check([m["id"] for m in meetings] == [roles["pending"], roles["renamed"], roles["failed"]],
          "not the three meetings, newest first: %r" % [m["id"] for m in meetings])
    check(listed["more"] is False, "more with everything listed")
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
    # The notes' first line that isn't a heading, without its list marker; none without notes.
    check(renamed.get("summary") == "Ship on Friday." and failed.get("summary") == "Budget approved."
          and "summary" not in pending, "summaries: %r" % [m.get("summary") for m in meetings])

    one = s.ok("list_meetings", limit=1)
    check([m["id"] for m in one["meetings"]] == [roles["pending"]] and one["more"] is True, "limit 1: %r" % one)
    day = s.ok("list_meetings", since="2026-09-29", until="2026-09-29")["meetings"]
    check([m["id"] for m in day] == [roles["renamed"]], "one day: %r" % day)
    later = s.ok("list_meetings", since=renamed["started_at"])["meetings"]
    check([m["id"] for m in later] == [roles["pending"], roles["renamed"]], "since a date-time: %r" % later)
    for bad in [{"limit": 0}, {"limit": 101}, {"limit": "5"}, {"limit": True}, {"since": "yesterday"},
                {"until": "2026-13-01"}, {"query": "x"}]:
        s.error("list_meetings", **bad)

    same = 0
    archive = os.path.join(folder, "archive")
    for role in ["renamed", "pending", "failed"]:
        entry = roles[role]
        want = open(os.path.join(folder, "expected", entry + ".md"), "rb").read()
        got = s.call("get_meeting", id=entry)
        check(got["isError"] is False and got["content"][0]["text"].encode() == want,
              "get_meeting %s isn't History's export:\n--- got\n%s\n--- want\n%s"
              % (role, got["content"][0]["text"], want.decode()))
        # Save Meetings to Folder…: one file for this meeting, the same bytes.
        saved = [n for n in os.listdir(archive) if "meeting-%s-" % entry.lower() in n]
        check(len(saved) == 1 and open(os.path.join(archive, saved[0]), "rb").read() == want,
              "the archived %s isn't History's export: %r" % (role, saved))
        notes = s.ok("get_meeting", id=entry.lower(), include_transcript=False)["content"][0]["text"]
        check(want.decode().startswith(notes[:-1] + "\n\n## ") and "**[" not in notes, "notes only, %s: %r" % (role, notes))
        same += 1
    check(len(os.listdir(archive)) == 3, "the archive has a file per meeting and none for dictations: %r" % os.listdir(archive))
    renamed_md = open(os.path.join(folder, "expected", roles["renamed"] + ".md")).read()
    check("**[00:21] Reed**" in renamed_md and "Tingting" in renamed_md and "Others" not in renamed_md,
          "the export doesn't have the new names")
    if lang != "en":
        check(not renamed_md.startswith("# Meeting\n"), "the %s export is in English" % lang)
    for bad in [{"id": str(uuid.uuid4())}, {"id": roles["dictation"]}, {"id": "not-an-id"}, {},
                {"id": roles["renamed"], "include_transcript": "no"}]:
        s.error("get_meeting", **bad)

    meetings_only = s.call("search_history", query="先看一下 ci")
    found = meetings_only["structuredContent"]
    check(meetings_only["isError"] is False and [r["id"] for r in found["results"]] == [roles["renamed"]]
          and found["dictations_excluded"] is True, "main switch only, search: %r" % found)
    check(len(meetings_only["content"]) == 2 and titles["dictations"] in meetings_only["content"][1]["text"],
          "no note that dictations weren't searched: %r" % meetings_only["content"])
    check([r["id"] for r in s.ok("search_history", query="先看一下 ci", kind="meeting")["results"]] == [roles["renamed"]],
          "main switch only, meetings")
    for name, arguments in [("search_history", {"query": "CI", "kind": "dictation"}),
                            ("get_dictation", {"id": roles["mixed"]})]:
        message = s.error(name, **arguments)
        check(titles["dictations"] in message and titles["section"] in message,
              "main switch only, %s: %r" % (name, message))
    dictionary = s.ok("get_dictionary")
    check(len(dictionary["words"]) == 3 and len(dictionary["replacements"]) == 2, "main switch only, dictionary")
    print("%s: main switch only: list_meetings (%d meetings), get_meeting = History's export = Save Meetings to Folder…'s file, byte for byte, for %d "
          "meetings, get_dictionary; search_history finds meetings only (dictations_excluded); dictations are tool "
          "errors naming \"%s\"" % (lang, len(meetings), same, titles["dictations"]))

    # 3. Both switches on: dictations too.
    switches(domain, True, True)
    mixed_text = "好的，我们先看一下 CI 再合并。"
    found = s.ok("search_history", query="先看一下 ci")
    check(found["dictations_excluded"] is False and found["more"] is False, "search flags: %r" % found)
    results = found["results"]
    check([r["id"] for r in results] == [roles["mixed"], roles["renamed"]], "mixed query, newest first: %r" % results)
    mixed, meeting = results
    check(datetime.datetime.fromisoformat(mixed["at"]) == datetime.datetime(2026, 9, 30, 10, 5).astimezone(),
          "mixed dictation's time: %s" % mixed["at"])
    check({k: v for k, v in mixed.items() if k != "at"} == {
        "id": roles["mixed"], "kind": "dictation", "app": "Slack", "mode": "Chat", "field": "enhanced",
        "snippet": mixed_text, "length": len(mixed_text), "read_with": "get_dictation"}, "mixed dictation: %r" % mixed)
    check(meeting["kind"] == "meeting" and meeting["field"] == "transcript" and meeting["read_with"] == "get_meeting"
          and "先看一下 CI" in meeting["snippet"] and "\n" not in meeting["snippet"]
          and meeting["length"] >= len(meeting["snippet"].strip("…")) and "app" not in meeting,
          "meeting result: %r" % meeting)
    check(s.call("get_meeting", id=meeting["id"])["isError"] is False, "read_with get_meeting")
    check([r["id"] for r in s.ok("search_history", query="先看一下 ci", kind="dictation")["results"]] == [roles["mixed"]],
          "kind dictation")
    check([r["id"] for r in s.ok("search_history", query="先看一下 ci", kind="meeting")["results"]] == [roles["renamed"]],
          "kind meeting")
    check([r["id"] for r in s.ok("search_history", query="先看一下 CI", since="2026-09-30")["results"]] == [roles["mixed"]],
          "since a day")
    check([r["id"] for r in s.ok("search_history", query="先看一下 CI", until="2026-09-29")["results"]] == [roles["renamed"]],
          "until a day")
    notes = s.ok("search_history", query="ship on friday")["results"]
    check([(r["id"], r["field"]) for r in notes] == [(roles["renamed"], "notes")] and "Ship on Friday" in notes[0]["snippet"],
          "a meeting's notes: %r" % notes)

    # Snippets: cut on both sides around a hit in the middle.
    long = s.ok("search_history", query="kubernetes ROLLOUT", kind="dictation")["results"]
    long_text = s.ok("get_dictation", id=roles["long"])["enhanced"]
    hit = long_text.index("Kubernetes rollout")
    check([r["id"] for r in long] == [roles["long"]] and long[0]["field"] == "enhanced"
          and long[0]["snippet"] == "…" + long_text[hit - 80:hit + len("Kubernetes rollout") + 80] + "…"
          and long[0]["length"] == len(long_text), "long dictation's snippet: %r" % long)
    both = s.ok("search_history", query="Kubernetes")["results"]
    check([r["id"] for r in both] == [roles["renamed"], roles["long"]], "a word in a meeting and a dictation: %r" % both)

    # limit: 20 by default, at most 50.
    notes20 = s.ok("search_history", query="STANDUP NOTE")
    check(len(notes20["results"]) == 20 and notes20["more"] is True and notes20["results"][0]["snippet"] == "Standup note 54",
          "default limit: %d, %r" % (len(notes20["results"]), notes20["results"][:1]))
    for asked, got in [(500, 50), (51, 50), (3, 3), (0, 1)]:
        page = s.ok("search_history", query="standup note", limit=asked)
        check(len(page["results"]) == got and page["more"] is True, "limit %d: %d results" % (asked, len(page["results"])))
    check(s.ok("search_history", query="zzzz nothing") == {"results": [], "more": False, "dictations_excluded": False},
          "no match")
    for bad in [{}, {"query": ""}, {"query": "   "}, {"query": 5}, {"query": "a", "kind": "notes"}, {"query": "a", "kind": 1},
                {"query": "a", "limit": "5"}, {"query": "a", "limit": 2.5}, {"query": "a", "limit": True},
                {"query": "a", "since": "yesterday"}, {"query": "a", "app": "Slack"}]:
        s.error("search_history", **bad)

    dictation = s.ok("get_dictation", id=roles["mixed"].lower())
    check(dictation == {"id": roles["mixed"], "at": mixed["at"], "duration_seconds": 4, "app": "Slack", "mode": "Chat",
                        "original": "好的 我们先看一下 ci 再合并", "enhanced": mixed_text}, "get_dictation: %r" % dictation)
    plain = s.ok("get_dictation", id=roles["dictation"])
    check(plain["original"] == "A dictation, not a meeting." and "enhanced" not in plain and "app" not in plain,
          "plain dictation: %r" % plain)
    check("get_meeting" in s.error("get_dictation", id=roles["renamed"]), "a meeting id doesn't point to get_meeting")
    for bad in [{"id": str(uuid.uuid4())}, {"id": "nope"}, {}, {"id": roles["mixed"], "include_transcript": True}]:
        s.error("get_dictation", **bad)

    dictionary = s.ok("get_dictionary")
    k8s = {"originals": ["k8s", "kates"], "replacement": "Kubernetes", "auto_added": False}
    typo = {"originals": ["先看下"], "replacement": "先看一下", "auto_added": True}
    # Sorted in the app's language: Latin first in English, Chinese first in Chinese.
    check(dictionary == {
        "words": [{"word": "Kubernetes", "auto_added": False}, {"word": "Shelley", "auto_added": False},
                  {"word": "Tingting", "auto_added": True}],
        "replacements": [k8s, typo] if lang == "en" else [typo, k8s],
    }, "get_dictionary: %r" % dictionary)
    check(s.ok("get_dictionary", query="KUBE") == {"words": [dictionary["words"][0]], "replacements": [k8s]},
          "dictionary query")
    check(s.ok("get_dictionary", query="看")["replacements"] == [typo], "dictionary query, Chinese")
    check(s.ok("get_dictionary", query="zzz") == {"words": [], "replacements": []}, "dictionary, no match")
    for bad in [{"query": 5}, {"word": "x"}]:
        s.error("get_dictionary", **bad)

    check(s.rpc("tools/call", {"name": "delete_meeting", "arguments": {}})["error"]["code"] == -32602, "unknown tool")
    check(s.rpc("resources/list")["error"]["code"] == -32601, "unknown method")
    check(s.rpc("server/discover")["error"]["code"] == -32601, "server/discover")
    s.write("{not json")
    check(s.read() == {"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "Parse error"}}, "parse error")
    print("%s: both switches on: search_history (Chinese and English in one query, kinds, dates, snippets cut at "
          "80 characters, limit 20 by default and 50 at most), get_dictation, get_dictionary with and without query"
          % lang)

    # Turned off again mid-session: the next call is refused.
    switches(domain, False, True)
    check(titles["enabled"] in s.error("list_meetings"), "turning the switch off didn't apply to the next call")
    sockets = subprocess.run(["lsof", "-a", "-p", str(s.process.pid), "-i"], capture_output=True, text=True).stdout
    check(sockets == "", "network sockets open:\n" + sockets)
    s.close()
    print("%s: switch turned off mid-session: next call refused; %d stdout lines, all JSON-RPC; no network socket "
          "(lsof -i); exited when stdin closed" % (lang, s.lines))

    # No data folder at all: empty results, unknown ids, no crash.
    switches(domain, True, True)
    e = Session(helper, os.path.join(folder, "no-such-folder"), stderr)
    e.initialize()
    check(e.ok("list_meetings") == {"meetings": [], "more": False}, "missing folder: not empty")
    check(e.ok("search_history", query="a") == {"results": [], "more": False, "dictations_excluded": False},
          "missing folder: search")
    check(e.ok("get_dictionary") == {"words": [], "replacements": []}, "missing folder: dictionary")
    e.error("get_meeting", id=roles["renamed"])
    e.error("get_dictation", id=roles["mixed"])
    e.close()
    switches(domain, None, None)
    check(not os.path.exists(os.path.join(folder, "no-such-folder")), "the missing folder was created")
    print("%s: missing data folder: empty lists, ids are tool errors" % lang)

    # A client that ends the session with SIGTERM instead of closing stdin: the copy the helper kept is deleted too.
    switches(domain, True, True)
    before = set(glob.glob(os.path.join(tempfile.gettempdir(), "yap-mcp-*")))
    t = Session(helper, os.path.join(folder, "data"), stderr)
    t.initialize()
    t.ok("list_meetings")
    t.ok("get_dictionary")
    kept = set(glob.glob(os.path.join(tempfile.gettempdir(), "yap-mcp-*"))) - before
    check(len(kept) == 2, "copies kept between calls (history, dictionary): %r" % sorted(kept))
    t.process.terminate()
    check(t.process.wait(timeout=5) == 0, "SIGTERM: exit code %r" % t.process.returncode)
    left = set(glob.glob(os.path.join(tempfile.gettempdir(), "yap-mcp-*"))) - before
    check(not left, "SIGTERM left copies: %r" % sorted(left))
    switches(domain, None, None)
    print("%s: two copies kept between calls; SIGTERM deleted them and exited 0" % lang)


def concurrent(helper, app, folder, domain):
    """The writer saves a dictation every few milliseconds. A consistent state of the history holds dictations
    1…n for some n, each whole: so the newest 50 are n, n-1, … with their full text, and get_dictation of the newest
    has its matching enhanced text. A "busy" answer is allowed; anything else is not."""
    data = os.path.join(folder, "data")
    stderr = os.path.join(folder, "helper-stderr.txt")
    leftovers = set(glob.glob(os.path.join(tempfile.gettempdir(), "yap-mcp-*")))
    writer = subprocess.Popen([app, "--mcp-fixture-writer", data], stdout=subprocess.PIPE,
                              stderr=open(os.path.join(folder, "writer-err.txt"), "w"), text=True)
    written = [0]

    def follow():
        for line in writer.stdout:
            if line.startswith("mcp-writer: ") and line.split()[1].isdigit():
                written[0] = int(line.split()[1])
    threading.Thread(target=follow, daemon=True).start()
    try:
        started = time.time()
        while written[0] < 1:
            check(writer.poll() is None, "the writer exited with %r" % writer.returncode)
            check(time.time() - started < 30, "the writer saved nothing in 30 s")
            time.sleep(0.05)
        switches(domain, True, True)
        s = Session(helper, data, stderr)
        s.initialize()
        consistent = busy = 0
        newest = []
        deadline = time.time() + 8
        while time.time() < deadline:
            result = s.call("search_history", query="writer-seq-", kind="dictation", limit=50)
            if result["isError"]:
                check("kept writing" in result["content"][0]["text"], "not a busy error: %r" % result)
                busy += 1
                continue
            rows = result["structuredContent"]["results"]
            numbers = [int(re.match(r"writer-seq-(\d+) ", r["snippet"]).group(1)) for r in rows]
            check(numbers and numbers == list(range(numbers[0], numbers[0] - len(numbers), -1))
                  and len(numbers) == min(50, numbers[0]), "not dictations n…n-49: %r" % numbers)
            check(all(r["length"] == len("writer-seq-%d " % n) + len(WRITER_FILLER) for r, n in zip(rows, numbers)),
                  "a dictation's text is cut short")
            whole = s.call("get_dictation", id=rows[0]["id"])
            if whole["isError"]:
                check("kept writing" in whole["content"][0]["text"], "not a busy error: %r" % whole)
                busy += 1
            else:
                body = whole["structuredContent"]
                check(body["original"] == "writer-seq-%d " % numbers[0] + WRITER_FILLER
                      and body["enhanced"] == "writer-check-%d" % numbers[0], "dictation %d is torn" % numbers[0])
            consistent += 1
            newest.append(numbers[0])
        check(consistent > 0, "every answer was busy")
        check(newest[-1] > newest[0], "the helper's view didn't move while the writer wrote: %r" % newest[:3])
        s.close()
    finally:
        writer.kill()
        writer.wait()
        switches(domain, None, None)
    retries = sum("changed while it was copied" in line for line in open(stderr))
    left = set(glob.glob(os.path.join(tempfile.gettempdir(), "yap-mcp-*"))) - leftovers
    check(not left, "temporary copies left: %r" % sorted(left))
    print("concurrent writer: %d dictations saved during the session; %d searches gave a consistent history "
          "(newest went from %d to %d), %d answers were busy, %d copies were redone because the store changed "
          "mid-copy; the helper exited normally and left no temporary copy"
          % (written[0], consistent, newest[0], newest[-1], busy, retries))


if __name__ == "__main__":
    mode = sys.argv[1]
    if mode == "tools":
        helper, folder, version, lang, domain = sys.argv[2:7]
        tools(helper, folder, version, domain)
    elif mode == "concurrent":
        helper, app, folder, domain = sys.argv[2:6]
        concurrent(helper, app, folder, domain)
    else:
        sys.exit("usage: see the docstring")
