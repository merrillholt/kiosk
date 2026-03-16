#!/usr/bin/env bash
# Smoke tests for the building-directory server.
#
# Runs a sequence of HTTP checks against a live server and reports pass/fail.
# Exits 0 if all pass, 1 if any fail.
#
# Usage:
#   tools/smoke-test.sh [--url URL] [--password PASS] [--no-color]
#   ssh host "bash -s -- [--url URL]" < tools/smoke-test.sh
#
# Defaults:
#   --url      http://127.0.0.1:3000   (direct to Node; use http://127.0.0.1 to test via nginx)
#   --password kiosk

set -euo pipefail

BASE_URL="http://127.0.0.1:3000"
PASSWORD="kiosk"
COLOR=1

while [[ $# -gt 0 ]]; do
    case "$1" in
        --url)      BASE_URL="$2"; shift 2 ;;
        --password) PASSWORD="$2"; shift 2 ;;
        --no-color) COLOR=0; shift ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done

if [[ $COLOR -eq 1 && -t 1 ]]; then
    GREEN='\033[0;32m'; RED='\033[0;31m'; DIM='\033[2m'; RESET='\033[0m'
else
    GREEN=''; RED=''; DIM=''; RESET=''
fi

PASS=0
FAIL=0
COOKIE_JAR=$(mktemp)
trap 'rm -f "$COOKIE_JAR"' EXIT

# ── Helpers ──────────────────────────────────────────────────────────────────

check() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        printf "${GREEN}PASS${RESET} %s\n" "$name"
        (( PASS++ )) || true
    else
        printf "${RED}FAIL${RESET} %s ${DIM}(expected %s, got %s)${RESET}\n" "$name" "$expected" "$actual"
        (( FAIL++ )) || true
    fi
}

status() {
    curl -s -o /dev/null -w "%{http_code}" "$@"
}

body() {
    curl -s "$@"
}

# ── Auth ─────────────────────────────────────────────────────────────────────

check "login correct password → 200" "200" \
    "$(status -X POST "$BASE_URL/api/auth/login" \
        -H "Content-Type: application/json" \
        -d "{\"password\":\"$PASSWORD\"}" \
        -c "$COOKIE_JAR")"

check "login wrong password → 401" "401" \
    "$(status -X POST "$BASE_URL/api/auth/login" \
        -H "Content-Type: application/json" \
        -d '{"password":"wrongpassword"}')"

check "GET /api/auth/me with session → authenticated:true" '"authenticated":true' \
    "$(body -b "$COOKIE_JAR" "$BASE_URL/api/auth/me" | grep -o '"authenticated":true' || echo '')"

check "GET /api/auth/me without session → authenticated:false" '"authenticated":false' \
    "$(body "$BASE_URL/api/auth/me" | grep -o '"authenticated":false' || echo '')"

# ── Kiosk read routes ─────────────────────────────────────────────────────────

check "GET /api/data-version → 200" "200" "$(status "$BASE_URL/api/data-version")"
check "GET /api/companies → 200"    "200" "$(status "$BASE_URL/api/companies")"
check "GET /api/building-info → 200" "200" "$(status "$BASE_URL/api/building-info")"
check "GET /api/revision → 200"     "200" "$(status "$BASE_URL/api/revision")"

# ── Auth enforcement ──────────────────────────────────────────────────────────

check "POST /api/companies without auth → 401" "401" \
    "$(status -X POST "$BASE_URL/api/companies" \
        -H "Content-Type: application/json" \
        -d '{"name":"smoke-test"}')"

check "POST /api/individuals without auth → 401" "401" \
    "$(status -X POST "$BASE_URL/api/individuals" \
        -H "Content-Type: application/json" \
        -d '{"first_name":"smoke","last_name":"test"}')"

# ── Authenticated CRUD ────────────────────────────────────────────────────────

CREATE_RESP=$(body -b "$COOKIE_JAR" -X POST "$BASE_URL/api/companies" \
    -H "Content-Type: application/json" \
    -d '{"name":"__smoke_test__","building":"Smoke","suite":"000"}')
CREATE_STATUS=$(echo "$CREATE_RESP" | grep -o '"id":[0-9]*' | head -1 | grep -qo '[0-9]*' && echo "201" || echo "fail")

# Re-run for actual HTTP status (body() consumed response above)
CREATE_STATUS=$(status -b "$COOKIE_JAR" -X POST "$BASE_URL/api/companies" \
    -H "Content-Type: application/json" \
    -d '{"name":"__smoke_test_2__","building":"Smoke","suite":"000"}')
check "POST /api/companies with auth → 200" "200" "$CREATE_STATUS"

# Extract id from first create for cleanup
CREATED_ID=$(echo "$CREATE_RESP" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*' || echo "")

if [[ -n "$CREATED_ID" ]]; then
    check "DELETE /api/companies/:id with auth → 200" "200" \
        "$(status -b "$COOKIE_JAR" -X DELETE "$BASE_URL/api/companies/$CREATED_ID")"
else
    printf "${RED}FAIL${RESET} DELETE /api/companies/:id (could not extract created id)\n"
    (( FAIL++ )) || true
fi

# Clean up the second test record by name (best effort)
CLEANUP_ID=$(body -b "$COOKIE_JAR" "$BASE_URL/api/companies/search?q=__smoke_test" \
    | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*' || echo "")
if [[ -n "$CLEANUP_ID" ]]; then
    curl -s -o /dev/null -b "$COOKIE_JAR" -X DELETE "$BASE_URL/api/companies/$CLEANUP_ID"
fi

# ── Backup ────────────────────────────────────────────────────────────────────

check "GET /api/backup.txt with auth → 200" "200" \
    "$(status -b "$COOKIE_JAR" "$BASE_URL/api/backup.txt")"

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
if [[ $FAIL -eq 0 ]]; then
    printf "${GREEN}All $PASS tests passed.${RESET}\n"
else
    printf "${RED}$FAIL test(s) failed${RESET}, $PASS passed.\n"
fi

[[ $FAIL -eq 0 ]]
