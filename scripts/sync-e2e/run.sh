#!/bin/bash
# `make sync-e2e`: registers a throwaway Yap Cloud account with two devices (two tokens = two Macs), runs the
# sync scenarios against live paygate, then deletes the account (the binary does it; the trap is the fallback).
# Needs the Railway CLI logged in: sign-in codes are read from paygate's log (no email is sent while
# RESEND_API_KEY is unset).
set -euo pipefail
BASE="${YAP_CLOUD_SMOKE_URL:-https://paygate-production-2502.up.railway.app}"
RAILWAY_PROJECT="${PAYGATE_RAILWAY_PROJECT:-8651e3c3-6d6c-4d56-a8e8-df9d89ed3f34}"  # paygate-yap
BIN="$1"
EMAIL="sync-e2e+$(date +%s)@sma1lboy.me"

code_for() {  # latest sign-in code for $EMAIL that isn't $1
    for _ in $(seq 1 20); do
        local code
        code=$(railway logs -p "$RAILWAY_PROJECT" -s paygate -e production --since 5m 2>/dev/null \
            | grep "code for $EMAIL:" | tail -1 | sed -E 's/.*: ([0-9]{6}).*/\1/' || true)
        if [ -n "$code" ] && [ "$code" != "${1:-}" ]; then echo "$code"; return; fi
        sleep 3
    done
    echo "no sign-in code for $EMAIL in paygate's log" >&2
    return 1
}

sign_in() {  # $1 = device name, $2 = code to skip → prints "<code> <token>"
    curl -sf -X POST "$BASE/v1/auth/start" -H 'Content-Type: application/json' -d "{\"email\":\"$EMAIL\"}" >/dev/null
    local code response token
    code=$(code_for "${2:-}")
    response=$(curl -s -X POST "$BASE/v1/auth/verify" -H 'Content-Type: application/json' \
        -d "{\"email\":\"$EMAIL\",\"code\":\"$code\",\"deviceName\":\"$1\"}")
    token=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("token", ""))' "$response" 2>/dev/null || true)
    if [ -z "$token" ]; then
        echo "sign-in for $1 failed: $response" >&2
        return 1
    fi
    echo "$code $token"
}

TOKEN_A=""
cleanup() {
    if [ -n "$TOKEN_A" ]; then
        curl -s -o /dev/null -X DELETE "$BASE/v1/me" -H "Authorization: Bearer $TOKEN_A" \
            -H 'Content-Type: application/json' -d "{\"confirm\":\"$EMAIL\"}" || true
    fi
}
trap cleanup EXIT

# `read <<<"$(…)"` would swallow a failed sign-in, so each step is checked.
SIGNED_IN_A=$(sign_in "sync-e2e Mac A") || exit 1
read -r CODE_A TOKEN_A <<<"$SIGNED_IN_A"
SIGNED_IN_B=$(sign_in "sync-e2e Mac B" "$CODE_A") || exit 1
read -r _ TOKEN_B <<<"$SIGNED_IN_B"
echo "     account                     $EMAIL (deleted at the end)"
SYNC_E2E_EMAIL="$EMAIL" SYNC_E2E_TOKEN_A="$TOKEN_A" SYNC_E2E_TOKEN_B="$TOKEN_B" YAP_CLOUD_SMOKE_URL="$BASE" "$BIN"
