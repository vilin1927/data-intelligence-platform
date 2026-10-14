#!/usr/bin/env bash
# scripts/api-smoke-probe.sh
# L8 universal API smoke probe — Phase A universal harness (2026-05-11)
#
# Purpose:
#   Auto-discovers every Next.js /api/*/route.ts in dashboard/src/app/api,
#   HTTP-probes GET, asserts 200 + JSON parse + schema-stable vs baseline.
#   Catches BREAKING API changes that L1-L4 miss (response schema drift →
#   frontend silently breaks → discovered days later via the owner complaint).
#
# Usage:
#   scripts/api-smoke-probe.sh
#     → probes every dashboard/src/app/api/**/route.ts via GET
#     → asserts 200 + JSON + schema-stable vs tests/api-smoke-baseline/*.keys
#     → exits 0 GREEN / 1 RED
#
# Env vars:
#   API_BASE=http://localhost:3000   (default — overridable for prod probe)
#   L8_OVERRIDE=1                    (skip schema-drift block, log YELLOW only)
#
# Behavior:
#   - New route → baseline auto-recorded, logged YELLOW (informational)
#   - Schema drift → RED + BLOCKS unless $L8_OVERRIDE=1
#   - Dynamic routes ([id], [table], etc.) → SKIPPED with YELLOW log (v1)
#   - 405 (method not allowed, mutation-only) → SKIPPED with YELLOW log
#   - jq missing → RED + clear error message
#

set -euo pipefail

# ────────────────────────────────────────────────────────────────────────────
# Config
# ────────────────────────────────────────────────────────────────────────────
API_BASE="${API_BASE:-http://localhost:3000}"
BASELINE_DIR="tests/api-smoke-baseline"
L8_OVERRIDE="${L8_OVERRIDE:-0}"
ROUTE_ROOT="dashboard/src/app/api"

# L8 fix 2026-05-11: readonly-subset path.
# If MOPPITY_PREFLIGHT_TOKEN is set, send `x-preflight-token` header so the
# 4 INFRA-04 preflight-bypass routes (customers/export, skus/export,
# export/combined-data, legacy-data) reach handler instead of returning 401.
# Other auth-protected routes that still return 401 are now treated as
# YELLOW SKIPPED (not RED) — they require session cookies the smoke probe
# does not own. Schema-drift guard fires only on routes that responded 200.
PREFLIGHT_TOKEN="${MOPPITY_PREFLIGHT_TOKEN:-}"
CURL_AUTH_ARGS=()
if [ -n "$PREFLIGHT_TOKEN" ]; then
    CURL_AUTH_ARGS=(-H "x-preflight-token: ${PREFLIGHT_TOKEN}")
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ────────────────────────────────────────────────────────────────────────────
# Pre-flight
# ────────────────────────────────────────────────────────────────────────────
if ! command -v jq >/dev/null 2>&1; then
    echo -e "${RED}L8 RED: jq not installed${NC}" >&2
    echo "  Install: brew install jq  (macOS) | apt-get install jq  (Linux)" >&2
    exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
    echo -e "${RED}L8 RED: curl not installed${NC}" >&2
    exit 1
fi

if [ ! -d "$ROUTE_ROOT" ]; then
    echo -e "${RED}L8 RED: route root not found: $ROUTE_ROOT${NC}" >&2
    echo "  Run from project root (moppity-vineyards/)" >&2
    exit 1
fi

mkdir -p "$BASELINE_DIR"

# ────────────────────────────────────────────────────────────────────────────
# Route discovery
# ────────────────────────────────────────────────────────────────────────────
ROUTES=$(find "$ROUTE_ROOT" -name "route.ts" -type f | \
         sed "s|${ROUTE_ROOT}/||; s|/route.ts||" | \
         sort)

TOTAL=0
GREEN_COUNT=0
YELLOW_COUNT=0
RED_COUNT=0
SKIPPED_DYNAMIC=0
SKIPPED_MUTATION=0
SKIPPED_AUTH=0
NEW_BASELINE=0
DRIFT=0

echo "=== L8 API smoke probe ==="
echo "API_BASE: $API_BASE"
echo "BASELINE_DIR: $BASELINE_DIR"
echo "L8_OVERRIDE: $L8_OVERRIDE"
echo "Preflight token: $([ -n "$PREFLIGHT_TOKEN" ] && echo present || echo absent)"
echo ""

# ────────────────────────────────────────────────────────────────────────────
# Per-route probe
# ────────────────────────────────────────────────────────────────────────────
for ROUTE in $ROUTES; do
    TOTAL=$((TOTAL + 1))

    # Skip dynamic routes (contain [...] segments — v1 limitation, see README)
    if [[ "$ROUTE" == *"["* ]] || [[ "$ROUTE" == *"]"* ]]; then
        echo -e "${YELLOW}⚠ SKIPPED${NC} /api/${ROUTE} (dynamic route, v1 limitation)"
        SKIPPED_DYNAMIC=$((SKIPPED_DYNAMIC + 1))
        continue
    fi

    URL="${API_BASE}/api/${ROUTE}"
    BASELINE_FILE="${BASELINE_DIR}/${ROUTE//\//_}.keys"

    # curl: -s silent, -w append HTTP code on new line, --max-time 30s safety
    RESPONSE=$(curl -s -w "\n%{http_code}" --max-time 30 "${CURL_AUTH_ARGS[@]}" "$URL" 2>&1 || echo -e "\n000")
    HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
    BODY=$(echo "$RESPONSE" | sed '$d')

    # 405 = method not allowed (mutation-only route — POST/PATCH/DELETE)
    if [ "$HTTP_CODE" = "405" ]; then
        echo -e "${YELLOW}⚠ SKIPPED${NC} /api/${ROUTE} (HTTP 405, mutation-only)"
        SKIPPED_MUTATION=$((SKIPPED_MUTATION + 1))
        continue
    fi

    # 401 = unauthorized — session-cookie-protected. L8 readonly-subset
    # design (2026-05-11): treat as SKIPPED YELLOW. Schema-drift guard is
    # not the right tool for auth-only endpoints; cover those via L4
    # chrome-devtools UI flows that own session cookies.
    if [ "$HTTP_CODE" = "401" ]; then
        echo -e "${YELLOW}⚠ SKIPPED${NC} /api/${ROUTE} (HTTP 401, auth-protected)"
        SKIPPED_AUTH=$((SKIPPED_AUTH + 1))
        continue
    fi

    # 000 = curl could not connect (dev server not running, network error)
    if [ "$HTTP_CODE" = "000" ]; then
        echo -e "${RED}🔴 RED${NC} /api/${ROUTE}: connection failed (server up at ${API_BASE}?)"
        RED_COUNT=$((RED_COUNT + 1))
        continue
    fi

    # Assert HTTP 200
    if [ "$HTTP_CODE" != "200" ]; then
        echo -e "${RED}🔴 RED${NC} /api/${ROUTE}: HTTP $HTTP_CODE (expected 200)"
        RED_COUNT=$((RED_COUNT + 1))
        continue
    fi

    # Assert JSON parses
    if ! echo "$BODY" | jq . >/dev/null 2>&1; then
        echo -e "${RED}🔴 RED${NC} /api/${ROUTE}: invalid JSON response"
        RED_COUNT=$((RED_COUNT + 1))
        continue
    fi

    # Extract key paths (sorted, deduped)
    CURRENT_KEYS=$(echo "$BODY" | jq -r 'paths(scalars)|join(".")' 2>/dev/null | sort -u)

    # Compare against baseline
    if [ -f "$BASELINE_FILE" ]; then
        BASELINE_KEYS=$(cat "$BASELINE_FILE")
        if [ "$CURRENT_KEYS" = "$BASELINE_KEYS" ]; then
            echo -e "${GREEN}✅ GREEN${NC} /api/${ROUTE}"
            GREEN_COUNT=$((GREEN_COUNT + 1))
        else
            DIFF=$(diff <(echo "$CURRENT_KEYS") <(echo "$BASELINE_KEYS") || true)
            if [ "$L8_OVERRIDE" = "1" ]; then
                echo -e "${YELLOW}🟡 YELLOW${NC} /api/${ROUTE}: schema drift (L8_OVERRIDE=1, not blocking)"
                echo "$DIFF" | head -20 | sed 's/^/    /'
                YELLOW_COUNT=$((YELLOW_COUNT + 1))
                DRIFT=$((DRIFT + 1))
            else
                echo -e "${RED}🔴 RED${NC} /api/${ROUTE}: schema drift vs baseline"
                echo "$DIFF" | head -20 | sed 's/^/    /'
                echo -e "    ${YELLOW}override:${NC} L8_OVERRIDE=1 scripts/api-smoke-probe.sh"
                echo -e "    ${YELLOW}update baseline:${NC} cp <(...current keys...) ${BASELINE_FILE}"
                RED_COUNT=$((RED_COUNT + 1))
                DRIFT=$((DRIFT + 1))
            fi
        fi
    else
        # New route — auto-record baseline
        echo "$CURRENT_KEYS" > "$BASELINE_FILE"
        echo -e "${YELLOW}🟡 NEW${NC} /api/${ROUTE}: baseline recorded → $BASELINE_FILE"
        YELLOW_COUNT=$((YELLOW_COUNT + 1))
        NEW_BASELINE=$((NEW_BASELINE + 1))
    fi
done

# ────────────────────────────────────────────────────────────────────────────
# Summary
# ────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== L8 summary ==="
echo "  Total routes discovered:  $TOTAL"
echo "  GREEN (schema stable):    $GREEN_COUNT"
echo "  YELLOW (new/drift/skip):  $YELLOW_COUNT"
echo "    - new baseline:         $NEW_BASELINE"
echo "    - schema drift:         $DRIFT"
echo "    - skipped (dynamic):    $SKIPPED_DYNAMIC"
echo "    - skipped (mutation):   $SKIPPED_MUTATION"
echo "    - skipped (auth-only):  $SKIPPED_AUTH"
echo "  RED (failures):           $RED_COUNT"
echo ""

if [ "$RED_COUNT" -gt 0 ]; then
    echo -e "${RED}❌ L8 RED — $RED_COUNT route(s) failed${NC}"
    exit 1
fi

echo -e "${GREEN}✅ L8 smoke probe GREEN${NC}"
exit 0
