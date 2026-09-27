#!/bin/bash
# make paygate-local / paygate-local-stop: a throwaway paygate on this Mac for make sync-e2e, cloud-smoke and
# cloud-latency (PAYGATE=local, the default), so they don't create accounts on production.
#   scripts/paygate-local.sh start   copy the paygate source, start Postgres and paygate (no-op if already up)
#   scripts/paygate-local.sh stop    stop both; the database is kept for the next start
# Source: PAYGATE_SRC (default ~/i/paygate), copied into .local-build/paygate-local/paygate; the original checkout is
# only read. Postgres (Homebrew `postgres`) listens on TCP 55432 only, paygate on http://localhost:8787.
# MODEL_ALLOWLIST defaults to the model table in docs/cloud-models.md, like production; OPENROUTER_API_KEY comes
# from the environment or ~/.env (needed only for the checks that make real calls). Sign-up credit is off.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="$ROOT/.local-build/paygate-local"
SRC="${PAYGATE_SRC:-$HOME/i/paygate}"
PG_PORT=55432
PORT=8787
URL="http://localhost:$PORT"

pg_bin() {
	local postgres
	postgres=$(command -v postgres) || { echo "paygate-local: needs postgres (brew install postgresql)" >&2; exit 1; }
	dirname "$(readlink -f "$postgres")"
}

allowlist() {  # backticked model ids in the first column after "Use" in docs/cloud-models.md's table
	sed -n 's/^| [A-Za-z ()]* | `\([^`]*\)` |.*/\1/p' "$ROOT/docs/cloud-models.md" | paste -sd, -
}

start() {
	if curl -sf "$URL/healthz" >/dev/null 2>&1; then
		echo "paygate-local: already running at $URL"
		return
	fi
	[ -f "$SRC/package.json" ] || { echo "paygate-local: no paygate checkout at $SRC (set PAYGATE_SRC)" >&2; exit 1; }
	mkdir -p "$DIR"
	rsync -a --delete --exclude node_modules --exclude .git --exclude .env "$SRC/" "$DIR/paygate/"
	(cd "$DIR/paygate" && bun install --frozen-lockfile >/dev/null 2>&1)

	local bin
	bin=$(pg_bin)
	if [ ! -d "$DIR/pg" ]; then
		"$bin/initdb" -D "$DIR/pg" -U postgres -A trust >/dev/null
	fi
	# -k '': TCP only; the Unix socket path under .local-build would exceed macOS's 103-byte limit.
	if ! "$bin/pg_ctl" -D "$DIR/pg" status >/dev/null 2>&1; then
		"$bin/pg_ctl" -D "$DIR/pg" -o "-p $PG_PORT -k ''" -l "$DIR/postgres.log" -w start >/dev/null
	fi
	"$bin/createdb" -h localhost -p "$PG_PORT" -U postgres paygate 2>/dev/null || true

	local key="${OPENROUTER_API_KEY:-}"
	if [ -z "$key" ] && [ -f "$HOME/.env" ]; then
		key=$(sed -n 's/^OPENROUTER_API_KEY=//p' "$HOME/.env" | tr -d '"' | head -1)
	fi
	[ -n "$key" ] || echo "paygate-local: no OPENROUTER_API_KEY; checks that make real calls will fail" >&2
	local models="${MODEL_ALLOWLIST:-$(allowlist)}"
	[ -n "$models" ] || { echo "paygate-local: no model ids found in docs/cloud-models.md" >&2; exit 1; }
	(umask 077 && cat >"$DIR/paygate/.env" <<EOF
DATABASE_URL=postgres://postgres@localhost:$PG_PORT/paygate
OPENROUTER_API_KEY=$key
AUTH_CODE_PEPPER=$(openssl rand -hex 32)
PRODUCT_NAME=Yap
LEGAL_DRAFT=true
MARKUP=0.10
MIN_TOPUP_USD=5
SIGNUP_CREDIT_USD=0
MODEL_ALLOWLIST=$models
PORT=$PORT
EOF
	)
	(cd "$DIR/paygate" && exec nohup bun src/index.ts >"$DIR/paygate.log" 2>&1 </dev/null) &
	echo $! >"$DIR/paygate.pid"
	for _ in $(seq 1 60); do
		if curl -sf "$URL/healthz" >/dev/null 2>&1; then
			echo "paygate-local: $URL (models: $models)"
			return
		fi
		sleep 0.5
	done
	echo "paygate-local: paygate didn't come up; see $DIR/paygate.log" >&2
	tail -5 "$DIR/paygate.log" >&2
	exit 1
}

stop() {
	if [ -f "$DIR/paygate.pid" ]; then
		kill "$(cat "$DIR/paygate.pid")" 2>/dev/null || true
		rm -f "$DIR/paygate.pid"
	fi
	if [ -d "$DIR/pg" ]; then
		"$(pg_bin)/pg_ctl" -D "$DIR/pg" -m fast stop >/dev/null 2>&1 || true
	fi
	echo "paygate-local: stopped"
}

case "${1:-}" in
start) start ;;
stop) stop ;;
*) echo "usage: scripts/paygate-local.sh start|stop" >&2; exit 2 ;;
esac
