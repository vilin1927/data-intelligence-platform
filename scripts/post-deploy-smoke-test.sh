#!/bin/bash
# Post-deploy smoke test for Moppity Vineyards dashboard
# Usage: bash scripts/post-deploy-smoke-test.sh [--verbose]
# Hits all 27 API endpoints and reports PASS/FAIL with response times.
# Exit code 0 if all pass, 1 if any fail.

set -euo pipefail

# ── Colors ──────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

# ── Config ──────────────────────────────────────────────────────────────────────
BASE_URL="http://${SERVER_HOST:-your-server-ip}"
COOKIE_JAR=$(mktemp)
VERBOSE=false
TOTAL=0
PASSED=0
FAILED=0
FAILURES=""

# Parse flags
for arg in "$@"; do
    case $arg in
        --verbose) VERBOSE=true ;;
        *) echo "Unknown flag: $arg"; exit 1 ;;
    esac
done

# ── Resolve password ────────────────────────────────────────────────────────────
# Priority: env var > credentials.md
if [ -n "${MOPPITY_DASHBOARD_PASSWORD:-}" ]; then
    PASSWORD="$MOPPITY_DASHBOARD_PASSWORD"
else
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
    CREDS_FILE="$PROJECT_ROOT/credentials.md"
    if [ -f "$CREDS_FILE" ]; then
        PASSWORD=$(grep -A2 "Dashboard Login" "$CREDS_FILE" | grep -i "Password" | head -1 | sed 's/.*: *//' | tr -d '`*' | xargs)
    fi
    if [ -z "${PASSWORD:-}" ]; then
        echo -e "${RED}ERROR: No password found.${NC}"
        echo "Set MOPPITY_DASHBOARD_PASSWORD or add 'Dashboard: <password>' to credentials.md"
        exit 1
    fi
fi

# ── Cleanup ─────────────────────────────────────────────────────────────────────
cleanup() {
    rm -f "$COOKIE_JAR"
}
trap cleanup EXIT

# ── Helper: test a GET endpoint ─────────────────────────────────────────────────
test_get() {
    local path="$1"
    local expect_code="${2:-200}"
    local url="${BASE_URL}${path}"
    TOTAL=$((TOTAL + 1))

    local response_file
    response_file=$(mktemp)

    local http_code
    local time_total
    http_code=$(curl -s -o "$response_file" -w "%{http_code}" \
        -b "$COOKIE_JAR" \
        --max-time 30 \
        "$url" 2>/dev/null || echo "000")
    time_total=$(curl -s -o /dev/null -w "%{time_total}" \
        -b "$COOKIE_JAR" \
        --max-time 30 \
        "$url" 2>/dev/null || echo "0")

    if [ "$http_code" = "$expect_code" ]; then
        PASSED=$((PASSED + 1))
        printf "  ${GREEN}PASS${NC}  %-40s  %s  %ss\n" "GET $path" "$http_code" "$time_total"
    else
        FAILED=$((FAILED + 1))
        printf "  ${RED}FAIL${NC}  %-40s  %s (expected %s)  %ss\n" "GET $path" "$http_code" "$expect_code" "$time_total"
        FAILURES="${FAILURES}\n  GET $path -> $http_code (expected $expect_code)"
        if [ "$VERBOSE" = true ]; then
            echo -e "  ${YELLOW}--- Response body ---${NC}"
            head -c 500 "$response_file" 2>/dev/null
            echo ""
            echo -e "  ${YELLOW}--- End body ---${NC}"
        fi
    fi

    rm -f "$response_file"
}

# ── Helper: test a POST endpoint ────────────────────────────────────────────────
# POST endpoints: we send a minimal or empty body.
# They should NOT return 404 — any of 200, 400, 401, 405 proves the route exists.
test_post() {
    local path="$1"
    local body="${2:-{\}}"
    local url="${BASE_URL}${path}"
    TOTAL=$((TOTAL + 1))

    local response_file
    response_file=$(mktemp)

    local http_code
    local time_total
    http_code=$(curl -s -o "$response_file" -w "%{http_code}" \
        -X POST \
        -H "Content-Type: application/json" \
        -b "$COOKIE_JAR" \
        -d "$body" \
        --max-time 30 \
        "$url" 2>/dev/null || echo "000")
    time_total=$(curl -s -o /dev/null -w "%{time_total}" \
        -X POST \
        -H "Content-Type: application/json" \
        -b "$COOKIE_JAR" \
        -d "$body" \
        --max-time 30 \
        "$url" 2>/dev/null || echo "0")

    # PASS if NOT 404 and NOT 000 (connection failure)
    if [ "$http_code" != "404" ] && [ "$http_code" != "000" ]; then
        PASSED=$((PASSED + 1))
        printf "  ${GREEN}PASS${NC}  %-40s  %s  %ss\n" "POST $path" "$http_code" "$time_total"
    else
        FAILED=$((FAILED + 1))
        printf "  ${RED}FAIL${NC}  %-40s  %s (route missing or unreachable)\n" "POST $path" "$http_code"
        FAILURES="${FAILURES}\n  POST $path -> $http_code"
        if [ "$VERBOSE" = true ]; then
            echo -e "  ${YELLOW}--- Response body ---${NC}"
            head -c 500 "$response_file" 2>/dev/null
            echo ""
            echo -e "  ${YELLOW}--- End body ---${NC}"
        fi
    fi

    rm -f "$response_file"
}

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}=== Moppity Post-Deploy Smoke Test — $(date) ===${NC}"
echo -e "    Target: ${BASE_URL}"
echo ""

# ── Step 1: Authenticate ────────────────────────────────────────────────────────
echo -e "${YELLOW}--- Authenticating ---${NC}"
AUTH_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    -c "$COOKIE_JAR" \
    -d "{\"password\":\"${PASSWORD}\"}" \
    --max-time 15 \
    "${BASE_URL}/api/auth/login" 2>/dev/null || echo "000")

if [ "$AUTH_CODE" = "200" ]; then
    echo -e "  ${GREEN}Authenticated OK${NC}"
else
    echo -e "  ${RED}Authentication FAILED (HTTP $AUTH_CODE)${NC}"
    echo -e "  ${RED}Cannot proceed without session cookie. Aborting.${NC}"
    exit 1
fi
echo ""

# ── Step 2: GET endpoints (expect 200) ──────────────────────────────────────────
echo -e "${YELLOW}--- GET Endpoints (expect 200) ---${NC}"
test_get "/api/overview"
test_get "/api/sales"
test_get "/api/inventory"
test_get "/api/reconciliation"
test_get "/api/admin"
test_get "/api/reference"
test_get "/api/margins"
test_get "/api/legacy-data"
test_get "/api/status"
test_get "/api/tables"
test_get "/api/insights" 400   # Requires query param
test_get "/api/browse" 400     # Requires query param
test_get "/api/customers"
test_get "/api/wholesale-prices"
test_get "/api/wines?sku_id=1"
echo ""

# ── Step 3: POST endpoints (expect NOT 404) ────────────────────────────────────
echo -e "${YELLOW}--- POST Endpoints (expect route exists, NOT 404) ---${NC}"
test_post "/api/auth/login"    "{\"password\":\"${PASSWORD}\"}"
test_post "/api/auth/logout"   "{}"
test_post "/api/upload"        "{}"
test_post "/api/upload/preview" "{}"
test_post "/api/upload/confirm" "{}"
test_post "/api/what-if"       "{}"
test_post "/api/chat"          "{}"
test_post "/api/query"         "{}"
test_post "/api/sync"          "{}"
test_post "/api/etl"           "{}"
test_post "/api/skus"          "{}"
test_post "/api/bottling"      "{}"
echo ""

# ── Summary ─────────────────────────────────────────────────────────────────────
echo -e "${BOLD}=== Summary ===${NC}"
echo -e "  Total:  ${TOTAL}"
echo -e "  Passed: ${GREEN}${PASSED}${NC}"
echo -e "  Failed: ${RED}${FAILED}${NC}"

if [ "$FAILED" -gt 0 ]; then
    echo ""
    echo -e "${RED}Failures:${NC}"
    echo -e "$FAILURES"
    echo ""
    echo -e "${RED}=== SMOKE TEST FAILED ===${NC}"
    exit 1
else
    echo ""
    echo -e "${GREEN}=== ALL 27 ENDPOINTS PASSED ===${NC}"
    exit 0
fi
