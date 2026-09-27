#!/bin/bash
# scripts/dev-defaults-guard.sh <command…>: runs the command and fails if the Debug app's own settings
# (defaults domain me.sma1lboy.yap.dev) differ afterwards. make ui-snapshots, mock, offline-check and first-run-check
# run through it: they launch copies of the Debug app under their own bundle ids and must never write the dev
# app's settings. The export from before the run is kept for `defaults import`. A dev app running at the same
# time can also change its settings, which shows up here too.
set -uo pipefail
DOMAIN="${YAP_DEFAULTS_GUARD_DOMAIN:-me.sma1lboy.yap.dev}"  # override only to test the guard itself
BEFORE="${TMPDIR:-/tmp}/yap-dev-defaults-before.plist"
AFTER="${TMPDIR:-/tmp}/yap-dev-defaults-after.plist"

defaults export "$DOMAIN" "$BEFORE" 2>/dev/null || plutil -create xml1 "$BEFORE"
"$@"
status=$?
defaults export "$DOMAIN" "$AFTER" 2>/dev/null || plutil -create xml1 "$AFTER"
changed=$(python3 - "$BEFORE" "$AFTER" <<'PY'
import plistlib, sys
before, after = (plistlib.load(open(p, "rb")) for p in sys.argv[1:3])
print(" ".join(sorted(k for k in before.keys() | after.keys() if before.get(k) != after.get(k))))
PY
)
if [ -n "$changed" ]; then
	echo "FAIL: the dev app's settings ($DOMAIN) changed during the run: $changed" >&2
	echo "      put them back with: defaults import $DOMAIN $BEFORE" >&2
	exit 1
fi
exit "$status"
