#!/usr/bin/env bash
# scripts/ai-chat-smoke.sh
# L9 AI Chat smoke test — Phase A universal harness extension (2026-05-13)
#
# Purpose:
#   Fire 7 baseline questions through /api/chat. Catches the class of bug
#   where chat tools fail silently behind try/catch error handlers
#   (e.g. DB credential drift, schema column rename, AI key rotation).
#
#   Root cause for this layer existing: A14 (2026-05-12) regenerated
#   `moppity_readonly` DB password but never updated `.env`. AI Chat
#   tools failed for ~12 hours with "password authentication failed",
#   surfaced to users as a "DB connection issue" wall. L1-L8 ALL missed it:
#     - L8 api-smoke-probe.sh treats POST+auth routes as YELLOW SKIP
#     - L4 ui-playbook doesn't walk /chat
#     - No layer asserts AI Chat tool calls actually return data
#
# Usage:
#   scripts/ai-chat-smoke.sh
#     → exits 0 GREEN / 1 RED
#
# Env vars:
#   API_BASE=http://localhost:3000   (default — overridable for prod probe)
#   DASHBOARD_PASSWORD=<pw>          (required for login)
#   L9_OVERRIDE=1                    (skip block, log YELLOW only)
#
# Behavior:
#   - For each Q: POST /api/chat with session cookie, capture SSE stream
#   - Assert [DONE] marker present
#   - Assert response chars >= min_response_chars from baseline
#   - Assert 0 forbidden_error_patterns in raw SSE stream
#   - Assert at least one expected_tool from the any_of list was called
#   - Assert at least one must_have keyword present in response text
#   - Exit 1 if any Q is RED unless $L9_OVERRIDE=1
#

set -euo pipefail

API_BASE="${API_BASE:-http://localhost:3000}"
BASELINE="${BASELINE:-tests/ai-chat-baseline/questions.json}"
L9_OVERRIDE="${L9_OVERRIDE:-0}"
DASHBOARD_PASSWORD="${DASHBOARD_PASSWORD:-}"
OUT_DIR="${OUT_DIR:-/tmp/l9-ai-chat-smoke}"
CURL_TIMEOUT="${CURL_TIMEOUT:-90}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

err() { echo -e "${RED}[L9 RED]${NC} $*" >&2; }
ok()  { echo -e "${GREEN}[L9 GREEN]${NC} $*"; }
warn(){ echo -e "${YELLOW}[L9 YELLOW]${NC} $*"; }

# Preflight checks
command -v jq >/dev/null || { err "jq missing"; exit 1; }
command -v curl >/dev/null || { err "curl missing"; exit 1; }
[ -f "$BASELINE" ] || { err "baseline file missing: $BASELINE"; exit 1; }
[ -n "$DASHBOARD_PASSWORD" ] || { err "DASHBOARD_PASSWORD env var required"; exit 1; }

mkdir -p "$OUT_DIR"

# Login
echo "[L9] logging in via $API_BASE/api/auth/login..."
LOGIN_RESP=$(curl -s -i -X POST "$API_BASE/api/auth/login" \
  -H "Content-Type: application/json" \
  -d "{\"password\":\"$DASHBOARD_PASSWORD\"}" 2>&1)
COOKIE=$(echo "$LOGIN_RESP" | grep -i "^set-cookie" | head -1 | sed 's/.*moppity_session=\([^;]*\).*/\1/')
[ -n "$COOKIE" ] || { err "login failed — no session cookie"; echo "$LOGIN_RESP" | tail -10; exit 1; }
ok "login successful, cookie acquired"

# Parse baseline
N_QS=$(jq '.questions | length' "$BASELINE")
echo "[L9] firing $N_QS baseline questions..."

# Build forbidden pattern regex (joined with |)
FORBIDDEN_RE=$(jq -r '.forbidden_error_patterns | join("|")' "$BASELINE")

FAILED=0
PASSED=0

for i in $(seq 0 $((N_QS-1))); do
  QID=$(jq -r ".questions[$i].id" "$BASELINE")
  QTEXT=$(jq -r ".questions[$i].question" "$BASELINE")
  MIN_CHARS=$(jq -r ".questions[$i].min_response_chars" "$BASELINE")
  EXPECTED_TOOLS=$(jq -r ".questions[$i].expected_tools_any_of | join(\"|\")" "$BASELINE")
  MUST_HAVE=$(jq -r ".questions[$i].must_have_any_of | join(\"|\")" "$BASELINE")

  echo ""
  echo "─── Q[$QID] ───"
  echo "  question: ${QTEXT:0:80}..."

  PAYLOAD=$(jq -n --arg q "$QTEXT" '{messages:[{role:"user",content:$q}]}')
  SSE_FILE="$OUT_DIR/$QID.sse"
  HTTP_CODE=$(curl -s -X POST "$API_BASE/api/chat" \
    -H "Content-Type: application/json" \
    -H "Cookie: moppity_session=$COOKIE" \
    -d "$PAYLOAD" \
    --max-time "$CURL_TIMEOUT" \
    -o "$SSE_FILE" \
    -w "%{http_code}" 2>&1) || HTTP_CODE="curl_fail"

  # Per-Q assertions
  REASONS=""

  # Assert 1: HTTP 200
  if [ "$HTTP_CODE" != "200" ]; then
    REASONS="${REASONS}HTTP=$HTTP_CODE; "
  fi

  # Assert 2: [DONE] marker
  if ! grep -q '\[DONE\]' "$SSE_FILE" 2>/dev/null; then
    REASONS="${REASONS}no [DONE] marker; "
  fi

  # Assert 3: no forbidden error patterns
  if grep -E -i "$FORBIDDEN_RE" "$SSE_FILE" >/dev/null 2>&1; then
    HIT=$(grep -E -i -o "$FORBIDDEN_RE" "$SSE_FILE" | head -1)
    REASONS="${REASONS}forbidden pattern '$HIT'; "
  fi

  # Extract response text via parse-sse.py helper
  PARSE_OUT=$(python3 "$(dirname "$0")/lib/parse-sse.py" "$SSE_FILE" 2>/dev/null)
  TOOLS_USED=$(echo "$PARSE_OUT" | grep '^TOOLS=' | head -1 | cut -d= -f2-)
  RESPONSE_CHARS=$(echo "$PARSE_OUT" | grep '^TEXT_CHARS=' | head -1 | cut -d= -f2-)
  RESPONSE_TEXT=$(echo "$PARSE_OUT" | grep '^TEXT_START=' | head -1 | cut -d= -f2-)
  RESPONSE_CHARS=${RESPONSE_CHARS:-0}

  # Assert 4: min response chars
  if [ "$RESPONSE_CHARS" -lt "$MIN_CHARS" ]; then
    REASONS="${REASONS}response too short ($RESPONSE_CHARS < $MIN_CHARS); "
  fi

  # Assert 5: at least one expected tool called
  TOOL_MATCH=0
  for t in $(echo "$EXPECTED_TOOLS" | tr '|' ' '); do
    if echo "$TOOLS_USED" | grep -q "$t"; then TOOL_MATCH=1; break; fi
  done
  if [ "$TOOL_MATCH" -eq 0 ]; then
    REASONS="${REASONS}no expected tool called (got: $TOOLS_USED); "
  fi

  # Assert 6: at least one must_have keyword in response
  if ! echo "$RESPONSE_TEXT" | grep -E -q "$MUST_HAVE"; then
    REASONS="${REASONS}no must_have keyword; "
  fi

  if [ -z "$REASONS" ]; then
    ok "Q[$QID] PASS (${RESPONSE_CHARS} chars, tools: $TOOLS_USED)"
    PASSED=$((PASSED+1))
  else
    err "Q[$QID] FAIL — $REASONS"
    FAILED=$((FAILED+1))
  fi
done

echo ""
echo "═══════════════════════════════════"
echo "L9 SUMMARY: $PASSED/$N_QS PASS, $FAILED FAIL"
echo "═══════════════════════════════════"

if [ "$FAILED" -gt 0 ]; then
  if [ "$L9_OVERRIDE" = "1" ]; then
    warn "L9 RED but L9_OVERRIDE=1 → not blocking"
    exit 0
  fi
  err "L9 BLOCKED — fix AI Chat before deploy"
  exit 1
fi

ok "L9 ALL GREEN — AI Chat baseline holds"
exit 0
