#!/bin/bash
# Release preflight: run before pushing a vX.Y.Z tag.
#   scripts/preflight.sh 1.2.0
# Runs every check even when one fails, prints a PASS/FAIL table, exits 1 if anything failed.
#   1. make build (Debug)                        4. make sync-e2e
#   2. Release build with MARKETING_VERSION      5. docs/releases/<version>.md exists
#   3. make cloud-smoke                           6. /v1/info numbers vs release notes, READMEs, site, app code
# The Release build goes to .local-build/preflight (incremental after the first run) and is never copied to
# ~/Downloads. cloud-smoke uses YAP_CLOUD_SMOKE_TOKEN when set; otherwise it issues a token for the smoke account
# with paygate's scripts/issue-token.ts and signs that device out afterwards. Needs the Railway CLI logged in
# (sync-e2e and the token) and gh (nothing else).
set -uo pipefail

VERSION="${1:-}"
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "usage: scripts/preflight.sh X.Y.Z" >&2
    exit 2
fi
cd "$(dirname "$0")/.."
BASE="${YAP_CLOUD_SMOKE_URL:-https://cloud.yap.sma1lboy.me}"
RAILWAY_PROJECT="${PAYGATE_RAILWAY_PROJECT:-8651e3c3-6d6c-4d56-a8e8-df9d89ed3f34}"  # paygate-yap
SMOKE_EMAIL="smoke+yap@sma1lboy.me"
LOGS="$(pwd)/.local-build/preflight-logs"
mkdir -p "$LOGS"

RESULTS=()
FAILED=0
record() {  # status, name, detail
    RESULTS+=("$1|$2|$3")
    [ "$1" = FAIL ] && FAILED=1
    printf '%-4s %-26s %s\n' "$1" "$2" "$3"
}
run_step() {  # name, log file, command...
    local name="$1" log="$2"
    shift 2
    echo "---- $name (log: $log)"
    if "$@" >"$log" 2>&1; then
        record PASS "$name" "$(grep -v '^[[:space:]]*$' "$log" | tail -1 | cut -c1-90)"
    else
        record FAIL "$name" "see $log: $(grep -m1 -E 'error:|FAIL' "$log" | cut -c1-80)"
    fi
}

# 1. Debug build
run_step "make build" "$LOGS/build.log" make build

# 2. Release build, same settings as `make local` (ad-hoc signed), without the copy to ~/Downloads
release_build() {
    xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Release \
        -derivedDataPath .local-build/preflight -xcconfig LocalBuild.xcconfig \
        CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES DEVELOPMENT_TEAM="" \
        CODE_SIGN_ENTITLEMENTS="$(pwd)/VoiceInk/VoiceInk.local.entitlements" \
        SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) LOCAL_BUILD' MARKETING_VERSION="$VERSION" \
        -skipPackagePluginValidation -skipMacroValidation build || return 1
    local app=.local-build/preflight/Build/Products/Release/Yap.app
    local built
    built=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app/Contents/Info.plist") || return 1
    [ "$built" = "$VERSION" ] || { echo "FAIL: built version $built, expected $VERSION"; return 1; }
    cmp -s "$app/Contents/Resources/releases/$VERSION.md" "docs/releases/$VERSION.md" \
        || { echo "FAIL: releases/$VERSION.md missing from Yap.app or different from docs/releases"; return 1; }
    echo "Yap.app $built, releases/$VERSION.md bundled"
}
run_step "Release build $VERSION" "$LOGS/release-build.log" release_build

# 3. cloud-smoke
SMOKE_TOKEN="${YAP_CLOUD_SMOKE_TOKEN:-}"
ISSUED_TOKEN=""
if [ -z "$SMOKE_TOKEN" ]; then
    ISSUED_TOKEN=$(railway ssh -p "$RAILWAY_PROJECT" -s paygate -e production -- \
        bun run scripts/issue-token.ts "$SMOKE_EMAIL" --device-name "preflight" 2>/dev/null | tr -d '[:space:]' || true)
    SMOKE_TOKEN="$ISSUED_TOKEN"
fi
sign_out_issued() {  # the device this run added to the smoke account
    [ -n "$ISSUED_TOKEN" ] || return 0
    local id
    id=$(curl -s -H "Authorization: Bearer $ISSUED_TOKEN" "$BASE/v1/me/devices" | python3 -c '
import json, sys
d = json.load(sys.stdin); d = d.get("devices", d) if isinstance(d, dict) else d
print(next((str(x["id"]) for x in d if x.get("current")), ""))' 2>/dev/null)
    [ -n "$id" ] && curl -s -o /dev/null -X DELETE -H "Authorization: Bearer $ISSUED_TOKEN" "$BASE/v1/me/devices/$id"
}
trap sign_out_issued EXIT
if [ -n "$SMOKE_TOKEN" ]; then
    run_step "make cloud-smoke" "$LOGS/cloud-smoke.log" env YAP_CLOUD_SMOKE_TOKEN="$SMOKE_TOKEN" make cloud-smoke
else
    record FAIL "make cloud-smoke" "no YAP_CLOUD_SMOKE_TOKEN and issue-token.ts gave none (railway login?)"
fi

# 4. sync-e2e
run_step "make sync-e2e" "$LOGS/sync-e2e.log" make sync-e2e

# 5. release notes
NOTES="docs/releases/$VERSION.md"
if [ -s "$NOTES" ]; then
    record PASS "release notes" "$NOTES ($(wc -l <"$NOTES" | tr -d ' ') lines)"
else
    record FAIL "release notes" "$NOTES is missing or empty"
fi

# 6. /v1/info numbers vs what users read and what the app hard-codes
numbers() {
    curl -sf "$BASE/v1/info" -o "$LOGS/info.json" || { echo "FAIL: GET /v1/info"; return 1; }
    python3 - "$LOGS/info.json" "$NOTES" <<'PY'
import json, re, sys
info = json.load(open(sys.argv[1]))
read = lambda p: open(p, encoding="utf-8").read() if __import__("os").path.exists(p) else ""
notes, readme, readme_zh, site = read(sys.argv[2]), read("README.md"), read("README.zh-CN.md"), read("site/index.html")
client = read("VoiceInk/Infrastructure/Cloud/YapCloudClient.swift")

def usd(x):
    x = float(x)
    return f"${int(x):,}" if x == int(x) else f"${x:,.2f}"
credit, lo, hi = usd(info["signupCreditUsd"]), usd(info["minTopupUsd"]), usd(info["maxTopupUsd"])
pct = f"{round(float(info['markup']) * 100):g}%"
presets = [int(p) for p in re.search(r"checkoutPresets = \[([^\]]*)\]", client).group(1).split(",")]
cap = int(re.search(r"maximumMonthlyCapMicros: Int64 = ([\d_]+)", client).group(1).replace("_", "")) // 1_000_000

checks = [
    ("notes: sign-up credit", f"{credit} of free credit" in notes, f"'{credit} of free credit'"),
    ("notes (中文): sign-up credit", f"赠送 {credit}" in notes, f"'赠送 {credit}'"),
    ("notes: top-up maximum", f"up to {hi}" in notes, f"'up to {hi}'"),
    ("notes (中文): top-up maximum", f"最高 {hi}" in notes, f"'最高 {hi}'"),
    ("notes: smallest preset", f"({usd(presets[0])}," in notes and presets[0] == float(info["minTopupUsd"]),
     f"presets {presets} start at the minimum {lo}"),
    ("app: presets inside range", all(float(info["minTopupUsd"]) <= p <= float(info["maxTopupUsd"]) for p in presets),
     f"{presets} within {lo}–{hi}"),
    ("notes: monthly cap", f"$0 to ${cap:,}" in notes and f"$0 到 ${cap:,}" in notes, f"'$0 to ${cap:,}' (app limit)"),
    ("README: markup", f"plus {pct}" in readme and f"加 {pct}" in readme_zh, f"'plus {pct}' / '加 {pct}'"),
    ("README: sign-up credit", f"{credit} of credit" in readme and f"{credit} 的额度" in readme_zh, f"'{credit} of credit'"),
    ("site: credit and markup", (not site) or (f">{credit} <small" in site and f"plus {pct}" in site and f"加 {pct}" in site),
     f"{credit}, {pct}" if site else "no site/index.html"),
]
bad = [(n, want) for n, ok, want in checks if not ok]
for n, ok, want in checks:
    print(("ok   " if ok else "FAIL ") + n + ": " + want)
print(f"/v1/info: credit {credit}, top-up {lo}–{hi}, markup {pct}; legal draft {info.get('legal', {}).get('draft')}, "
      f"support {info.get('supportEmail')}")
sys.exit(1 if bad else 0)
PY
}
if numbers >"$LOGS/numbers.log" 2>&1; then
    record PASS "/v1/info vs docs & app" "$(tail -1 "$LOGS/numbers.log" | cut -c1-90)"
else
    record FAIL "/v1/info vs docs & app" "$(grep -m3 '^FAIL' "$LOGS/numbers.log" | tr '\n' ' ' | cut -c1-90)"
fi

echo
echo "Preflight for $VERSION"
printf '| %-4s | %-26s | %s\n' "" "Check" "Detail"
for row in "${RESULTS[@]}"; do
    IFS='|' read -r status name detail <<<"$row"
    printf '| %-4s | %-26s | %s\n' "$status" "$name" "$detail"
done
if [ "$FAILED" -eq 0 ]; then
    echo "preflight: all checks passed. Also go through docs/release-checklist.md (manual checks)."
else
    echo "preflight: some checks failed; logs in $LOGS"
fi
exit "$FAILED"
