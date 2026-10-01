#!/bin/bash
# make home-feedback-perf: Home's week panel on 20,000 SessionMetrics in the last 60 days (HomeFeedbackPerf.swift).
# The data is written once to /tmp/yap-home-perf/data (FRESH=1 writes it again); then ROUNDS launches (default 10) of
# the Debug app each copy it and time the fetch cold (a new process) and warm, a late edit outcome's save, the mode
# editor's detection-time look-up, and count the panel's fetches. Results: /tmp/yap-home-perf/runs.txt, summed up
# below. The app exits before anything writes settings; nothing is read from or written to the dev app's data.
set -euo pipefail

BIN="$1/VoiceInk Dev.app/Contents/MacOS/VoiceInk Dev"
ROUNDS="${2:-10}"
WORK=/tmp/yap-home-perf
mkdir -p "$WORK"

if [ "${FRESH:-0}" = 1 ] || [ ! -s "$WORK/data/stats.store" ]; then
	"$BIN" --home-feedback-perf "$WORK/data" --write | grep '^home-feedback-perf:' | tee "$WORK/write.txt"
fi
echo "data: $(du -k "$WORK/data/stats.store" | cut -f1) KB stats.store + $(du -k "$WORK/data/stats.store-wal" 2>/dev/null | cut -f1 || echo 0) KB -wal;" \
	"$(sysctl -n hw.model), $(sysctl -n machdep.cpu.brand_string), $(($(sysctl -n hw.memsize) / 1073741824)) GB, macOS $(sw_vers -productVersion)"

: >"$WORK/runs.txt"
for round in $(seq "$ROUNDS"); do
	"$BIN" --home-feedback-perf "$WORK/data" | grep '^home-feedback-perf:' >>"$WORK/runs.txt" \
		|| { echo "FAIL: round $round"; exit 1; }
done
python3 - "$WORK/runs.txt" <<'EOF'
import json, sys
rows = [json.loads(line.split(": ", 1)[1]) for line in open(sys.argv[1])]
def pct(values, p):
    values = sorted(values)
    return values[max(0, -(-len(values) * p // 100) - 1)]
def summary(values):
    return f"p50 {pct(values, 50):g} / p95 {pct(values, 95):g} / max {max(values):g}"
by = lambda phase: [r for r in rows if r["phase"] == phase]
cold, warm, edit, cost, panel = by("cold"), by("warm"), by("late-edit"), by("detection-cost"), by("panel")
print(f"rounds: {len(cold)}; metrics in the store: {cold[0]['metricsInStore']}; this week: {cold[0]['thisWeek']} dictations, "
      f"{cold[0]['pasted']} pasted, {cold[0]['timed']} timed, {cold[0]['watched']} watched, {cold[0]['untimed']} untimed")
print(f"open container ms: {summary([r['openMs'] for r in cold])}")
print(f"cold fetch + aggregate ms (first load per process): {summary([r['loadMs'] for r in cold])}")
print(f"warm fetch + aggregate ms (p50 of 30 per process): {summary([r['loadMs']['p50'] for r in warm])}; "
      f"p95 per process: {summary([r['loadMs']['p95'] for r in warm])}")
print(f"main thread longest block ms: cold {max(r['mainBlockMs'] for r in cold):g}, warm {max(r['mainBlockMs'] for r in warm):g}, "
      f"late edits {max(r['mainBlockMs'] for r in edit):g}")
print(f"late edit save on the main thread ms (p50 / p95 per process): {summary([r['mainMs']['p50'] for r in edit])}; "
      f"{summary([r['mainMs']['p95'] for r in edit])}")
if cost:
    print(f"mode editor detection-time look-up ms: {summary([r['mainMs']['p50'] for r in cost])}")
p = panel[0]
assert all(r == p for r in panel), "panel fetch counts differ between rounds"
print(f"panel fetches: {p['initialFetches']} on appear, {p['fetchesForDictationAndOutcome300msApart']} for a dictation and its "
      f"outcome 300 ms apart, {p['fetchesForDictationAndOutcome2sApart']} when 2 s apart, "
      f"{p['fetchesWhenAutoLearnTurnedOff']} when Auto Learn is turned off; every reload after an outcome saw it")
EOF
