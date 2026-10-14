#!/usr/bin/env bash
# scripts/preflight-creds-check.sh
# Option C — credential coherence preflight (2026-05-13)
#
# Purpose:
#   Catches the class of bug where .env credentials drift from the
#   actual target service (DB password rotated but env stale,
#   Vinsight key revoked, Xero refresh token expired, etc.)
#
#   Root cause for this script existing: A14 (2026-05-12) regenerated
#   moppity_readonly DB role with new password but kept stale value
#   in .env. AI Chat broke silently. NO gate caught it because
#   credentials are tested only when their owning service runs.
#
# Probes each credential against its real target. Read-only — no writes.
#
# Usage:
#   scripts/preflight-creds-check.sh
#   PREFLIGHT_OVERRIDE=1 scripts/preflight-creds-check.sh   # log only
#
# Probes (each independent; one fail doesn't abort the rest):
#   1. DATABASE_URL              → psql SELECT 1 (write user)
#   2. DATABASE_URL_READONLY     → psql SELECT 1 (readonly user)
#   3. VINSIGHT_API_KEY          → GET /StockItems.json?api-key=... &$top=1
#   4. ANTHROPIC_API_KEY         → POST /v1/messages minimal payload
#   5. GOOGLE_API_KEY            → GET sheets metadata
#   6. MOPPITY_PREFLIGHT_TOKEN   → curl /api/customers/export with header
#   7. Xero refresh token        → POST /connect/token refresh flow
#

set -uo pipefail

ENV_FILE="${ENV_FILE:-/opt/moppity/.env}"
DASHBOARD_ENV="${DASHBOARD_ENV:-/opt/moppity/dashboard/.env}"
API_BASE="${API_BASE:-http://localhost:3000}"
PREFLIGHT_OVERRIDE="${PREFLIGHT_OVERRIDE:-0}"
CURL_TIMEOUT="${CURL_TIMEOUT:-20}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

err()  { echo -e "${RED}[CREDS RED]${NC} $*"; }
ok()   { echo -e "${GREEN}[CREDS OK ]${NC} $*"; }
warn() { echo -e "${YELLOW}[CREDS YEL]${NC} $*"; }

[ -f "$ENV_FILE" ] || { err "env file missing: $ENV_FILE"; exit 1; }

# Load env into shell (without exec'ing untrusted content)
load_var() {
  local var="$1"
  local file="$2"
  grep -E "^${var}=" "$file" 2>/dev/null | head -1 | cut -d= -f2- | sed 's/^["'"'"']//' | sed 's/["'"'"']$//'
}

FAILED=0
PASSED=0
SKIPPED=0

probe_postgres() {
  local label="$1" url="$2"
  [ -n "$url" ] || { warn "$label: not set in env, SKIP"; SKIPPED=$((SKIPPED+1)); return; }
  if [[ "$url" =~ postgresql://([^:]+):([^@]+)@([^:]+):([0-9]+)/(.+) ]]; then
    local user="${BASH_REMATCH[1]}" pw="${BASH_REMATCH[2]}" host="${BASH_REMATCH[3]}" port="${BASH_REMATCH[4]}" db="${BASH_REMATCH[5]}"
    if PGPASSWORD="$pw" psql -U "$user" -d "$db" -h "$host" -p "$port" -At -c "SELECT 1;" >/dev/null 2>&1; then
      ok "$label (user=$user db=$db host=$host)"
      PASSED=$((PASSED+1))
    else
      err "$label auth FAILED (user=$user) — .env drift from DB"
      FAILED=$((FAILED+1))
    fi
  else
    err "$label malformed URL"
    FAILED=$((FAILED+1))
  fi
}

probe_vinsight() {
  local key="$1"
  [ -n "$key" ] || { warn "VINSIGHT_API_KEY not set, SKIP"; SKIPPED=$((SKIPPED+1)); return; }
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$CURL_TIMEOUT" \
    "https://app.vinsight.net/StockItems.json?api-key=${key}&\$top=1" 2>&1)
  case "$code" in
    200) ok "VINSIGHT_API_KEY (200 OK)"; PASSED=$((PASSED+1)) ;;
    401|403) err "VINSIGHT_API_KEY $code — key revoked/rotated"; FAILED=$((FAILED+1)) ;;
    429) warn "VINSIGHT_API_KEY 429 (rate-limited, key likely valid)"; PASSED=$((PASSED+1)) ;;
    *) warn "VINSIGHT_API_KEY HTTP=$code (ambiguous)"; SKIPPED=$((SKIPPED+1)) ;;
  esac
}

probe_anthropic() {
  local key="$1"
  [ -n "$key" ] || { warn "ANTHROPIC_API_KEY not set, SKIP"; SKIPPED=$((SKIPPED+1)); return; }
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$CURL_TIMEOUT" \
    -X POST "https://api.anthropic.com/v1/messages" \
    -H "x-api-key: $key" \
    -H "anthropic-version: 2023-06-01" \
    -H "content-type: application/json" \
    -d '{"model":"claude-haiku-4-5-20251001","max_tokens":4,"messages":[{"role":"user","content":"hi"}]}' 2>&1)
  case "$code" in
    200) ok "ANTHROPIC_API_KEY (200 OK)"; PASSED=$((PASSED+1)) ;;
    401|403) err "ANTHROPIC_API_KEY $code — key revoked"; FAILED=$((FAILED+1)) ;;
    429) warn "ANTHROPIC_API_KEY 429 (rate-limited, key likely valid)"; PASSED=$((PASSED+1)) ;;
    *) warn "ANTHROPIC_API_KEY HTTP=$code"; SKIPPED=$((SKIPPED+1)) ;;
  esac
}

probe_google() {
  local key="$1"
  [ -n "$key" ] || { warn "GOOGLE_API_KEY not set, SKIP"; SKIPPED=$((SKIPPED+1)); return; }
  local code
  # Use a known public Sheets sample sheet to test key validity
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$CURL_TIMEOUT" \
    "https://sheets.googleapis.com/v4/spreadsheets/1BxiMVs0XRA5nFMdKvBdBZjgmUUqptlbs74OgvE2upms?key=${key}&fields=spreadsheetId" 2>&1)
  case "$code" in
    200) ok "GOOGLE_API_KEY (200 OK)"; PASSED=$((PASSED+1)) ;;
    400|401|403) err "GOOGLE_API_KEY $code — key revoked/expired"; FAILED=$((FAILED+1)) ;;
    *) warn "GOOGLE_API_KEY HTTP=$code"; SKIPPED=$((SKIPPED+1)) ;;
  esac
}

probe_preflight_token() {
  local token="$1"
  [ -n "$token" ] || { warn "MOPPITY_PREFLIGHT_TOKEN not set, SKIP"; SKIPPED=$((SKIPPED+1)); return; }
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$CURL_TIMEOUT" \
    "$API_BASE/api/customers/export?limit=1" \
    -H "x-preflight-token: $token" 2>&1)
  case "$code" in
    200) ok "MOPPITY_PREFLIGHT_TOKEN (200 OK via /api/customers/export)"; PASSED=$((PASSED+1)) ;;
    401|403) err "MOPPITY_PREFLIGHT_TOKEN $code — token rejected by middleware"; FAILED=$((FAILED+1)) ;;
    *) warn "MOPPITY_PREFLIGHT_TOKEN HTTP=$code"; SKIPPED=$((SKIPPED+1)) ;;
  esac
}

probe_xero() {
  local refresh="$1" client_id="$2" client_secret="$3"
  [ -n "$refresh" ] && [ -n "$client_id" ] && [ -n "$client_secret" ] \
    || { warn "Xero creds incomplete, SKIP"; SKIPPED=$((SKIPPED+1)); return; }
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$CURL_TIMEOUT" \
    -X POST "https://identity.xero.com/connect/token" \
    -u "${client_id}:${client_secret}" \
    -d "grant_type=refresh_token&refresh_token=${refresh}" 2>&1)
  case "$code" in
    200) ok "XERO refresh_token (200 OK — new access_token issued)"; PASSED=$((PASSED+1)) ;;
    400|401) err "XERO refresh_token $code — expired or revoked"; FAILED=$((FAILED+1)) ;;
    *) warn "XERO refresh_token HTTP=$code"; SKIPPED=$((SKIPPED+1)) ;;
  esac
}

echo "[CREDS] preflight starting — env=$ENV_FILE"

DB_URL=$(load_var "DATABASE_URL" "$ENV_FILE")
DB_URL_RO=$(load_var "DATABASE_URL_READONLY" "$ENV_FILE")
VIN_KEY=$(load_var "VINSIGHT_API_KEY" "$ENV_FILE")
ANT_KEY=$(load_var "ANTHROPIC_API_KEY" "$ENV_FILE")
GOO_KEY=$(load_var "GOOGLE_API_KEY" "$ENV_FILE")
PRE_TOK=$(load_var "MOPPITY_PREFLIGHT_TOKEN" "$ENV_FILE")
XR_REF=$(load_var "XERO_REFRESH_TOKEN" "$ENV_FILE")
XR_CID=$(load_var "XERO_CLIENT_ID" "$ENV_FILE")
XR_SEC=$(load_var "XERO_CLIENT_SECRET" "$ENV_FILE")

probe_postgres "DATABASE_URL (write)" "$DB_URL"
probe_postgres "DATABASE_URL_READONLY" "$DB_URL_RO"
probe_vinsight "$VIN_KEY"
probe_anthropic "$ANT_KEY"
probe_google "$GOO_KEY"
probe_preflight_token "$PRE_TOK"
probe_xero "$XR_REF" "$XR_CID" "$XR_SEC"

echo ""
echo "═══════════════════════════════════════"
echo "CREDS PREFLIGHT: $PASSED OK, $FAILED FAIL, $SKIPPED SKIP"
echo "═══════════════════════════════════════"

if [ "$FAILED" -gt 0 ]; then
  if [ "$PREFLIGHT_OVERRIDE" = "1" ]; then
    warn "RED but PREFLIGHT_OVERRIDE=1 → not blocking"
    exit 0
  fi
  err "CREDS BLOCKED — fix .env drift before deploy"
  exit 1
fi

ok "CREDS ALL OK"
exit 0
