#!/usr/bin/env python3
"""make mcp-perf's driver (scripts/mcp-perf.sh writes the data and runs it).

  mcp-perf.py <helper> <data folder> <work folder>

Times each call from writing the request to reading the answer. Cold: a new helper process per call (what an agent
pays for its first call, and for every call when it starts the server per request). Warm: one process, the call
repeated. The helper's --log-timing lines give each call's copy / open / read split. Writes perf.md to <work folder>.
"""
import json, os, re, statistics, subprocess, sys, time

COLD, WARM = int(os.environ.get("COLD", "10")), int(os.environ.get("WARM", "20"))


class Helper:
    def __init__(self, helper, data, log):
        self.log = log
        self.stderr = open(log, "w")
        # A helper from before --log-timing (to time an older build the same way) runs without it.
        timing = ["--log-timing"] if "--log-timing" in subprocess.run([helper, "--help"], capture_output=True, text=True).stdout else []
        self.process = subprocess.Popen([helper, "--data-dir", data] + timing, stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=self.stderr, bufsize=0)
        self.next_id = 0
        self.rpc("initialize", {"protocolVersion": "2025-11-25", "capabilities": {},
                                "clientInfo": {"name": "mcp-perf", "version": "1"}})

    def rpc(self, method, params):
        self.next_id += 1
        self.process.stdin.write((json.dumps({"jsonrpc": "2.0", "id": self.next_id, "method": method,
                                              "params": params}) + "\n").encode())
        answer = json.loads(self.process.stdout.readline())
        if "result" not in answer:
            sys.exit("FAIL: %s: %r" % (method, answer))
        return answer["result"]

    def call(self, name, arguments):
        started = time.perf_counter()
        result = self.rpc("tools/call", {"name": name, "arguments": arguments})
        elapsed = (time.perf_counter() - started) * 1000
        if result.get("isError"):
            sys.exit("FAIL: %s %r: %s" % (name, arguments, result["content"][0]["text"]))
        return elapsed, result

    def close(self):
        self.process.stdin.close()
        self.process.wait(timeout=10)
        self.stderr.close()
        return open(self.log).read()


def splits(log):
    """The --log-timing store lines: [(copy, open, read)] in ms."""
    return [tuple(float(x) for x in m) for m in
            re.findall(r"timing \S+\.store: copy ([\d.]+) ms, open ([\d.]+) ms, read ([\d.]+) ms", log)]


def percentile(values, p):
    values = sorted(values)
    return values[min(len(values) - 1, max(0, round(p / 100 * len(values) + 0.5) - 1))]


def main(helper, data, work):
    probe = Helper(helper, data, os.path.join(work, "probe.log"))
    _, newest = probe.call("list_meetings", {"limit": 1})
    meeting = newest["structuredContent"]["meetings"][0]["id"]
    _, found = probe.call("search_history", {"query": "staging", "kind": "dictation", "limit": 1})
    dictation = found["structuredContent"]["results"][0]["id"]
    probe.close()

    cases = [
        ("list_meetings", {}, "20 newest"),
        ("list_meetings", {"since": "2026-01-01", "limit": 100}, "100 since a date"),
        ("get_meeting", {"id": meeting}, "an hour's transcript"),
        ("get_meeting", {"id": meeting, "include_transcript": False}, "notes only"),
        ("search_history", {"query": "Kubernetes"}, "common word"),
        ("search_history", {"query": "flaky test", "kind": "dictation", "limit": 50}, "50 dictations"),
        ("search_history", {"query": "oncall", "kind": "meeting"}, "meetings only"),
        ("search_history", {"query": "Terraform"}, "no match: every row read"),
        ("get_dictation", {"id": dictation}, ""),
        ("get_dictionary", {}, ""),
    ]
    rows = []
    for name, arguments, note in cases:
        cold, cold_splits = [], []
        for run in range(COLD):
            session = Helper(helper, data, os.path.join(work, "cold.log"))
            cold.append(session.call(name, arguments)[0])
            cold_splits += splits(session.close())
        session = Helper(helper, data, os.path.join(work, "warm.log"))
        warm = [session.call(name, arguments)[0] for _ in range(WARM)]
        warm_splits = splits(session.close())
        rows.append((name, note, cold, warm, cold_splits, warm_splits))
        print("%-15s %-26s cold p50 %6.0f p95 %6.0f | warm p50 %6.0f p95 %6.0f ms | copy/open/read cold %s, warm %s"
              % (name, note, percentile(cold, 50), percentile(cold, 95), percentile(warm, 50), percentile(warm, 95),
                 medians(cold_splits), medians(warm_splits)))

    lines = ["| tool | case | cold p50 | cold p95 | warm p50 | warm p95 | copy / open / read, cold | warm |",
             "|---|---|---|---|---|---|---|---|"]
    for name, note, cold, warm, cold_splits, warm_splits in rows:
        lines.append("| `%s` | %s | %.0f | %.0f | %.0f | %.0f | %s | %s |" % (
            name, note, percentile(cold, 50), percentile(cold, 95), percentile(warm, 50), percentile(warm, 95),
            medians(cold_splits), medians(warm_splits)))
    lines.append("")
    lines.append("All times in ms, from writing the request to reading the answer; cold over %d new helper processes, "
                 "warm over %d calls in one process. The last two columns are the helper's own medians for copying "
                 "the store, opening the copy and reading it." % (COLD, WARM))
    open(os.path.join(work, "perf.md"), "w").write("\n".join(lines) + "\n")
    print("\n".join(lines))


def medians(store_splits):
    if not store_splits:
        return "–"
    return " / ".join("%.0f" % statistics.median(s[i] for s in store_splits) for i in range(3))


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    main(*sys.argv[1:])
