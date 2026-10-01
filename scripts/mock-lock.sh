# Sourced first thing by every script that runs the Debug app as me.sma1lboy.yap.mock: mock, offline-check,
# mcp-check, first-run-check, model-residency-check, dictation-latency and the meeting checks (through
# meeting-check-common.sh). Each wipes that identity's defaults, Application Support, keychain and its /tmp folder
# before and after, so two at once (two worktrees on one Mac) delete each other's store and model mid-run.
#
# The lock is a flock(2) on $MOCK_LOCK through fd 9, which the script and everything it starts keep open: it is held
# until the last of them exits, after the script's EXIT trap has cleaned up, and the kernel drops it however they
# end (kill -9 included), so there is no stale lock to detect and no takeover to race. A script started by one that
# holds it (YAP_MOCK_LOCKED in its environment, fd 9 inherited) doesn't wait for it again.
MOCK_LOCK="${YAP_MOCK_LOCK_FILE:-/tmp/yap-mock.flock}"  # override only to test the lock itself
if [ "${YAP_MOCK_LOCKED:-}" != "$MOCK_LOCK" ]; then
	exec 9>>"$MOCK_LOCK"
	if ! python3 -c 'import fcntl; fcntl.flock(9, fcntl.LOCK_EX | fcntl.LOCK_NB)' 2>/dev/null; then
		echo "$(basename "$0"): waiting for another run as the mock identity to finish ($(cat "$MOCK_LOCK.owner" 2>/dev/null || echo unknown))…" >&2
		python3 -c 'import fcntl; fcntl.flock(9, fcntl.LOCK_EX)'
	fi
	echo "pid $$, $(basename "$0"), $(pwd)" >"$MOCK_LOCK.owner"
	export YAP_MOCK_LOCKED="$MOCK_LOCK"
fi
