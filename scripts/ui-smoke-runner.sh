#!/usr/bin/env bash
# UI Smoke Runner — quick HTTP 200 + label-present sanity for L4 playbook.
# Usage: bash scripts/ui-smoke-runner.sh [RUN_DIR]
#
# Does NOT replace chrome-devtools playbook walk. This is the curl/grep
# pre-flight: catches dead pages and missing labels before operator opens
#
# Exit code: 0 = all green, 1 = any RED.

set -euo pipefail

PROD_URL="${PROD_URL:-http://${SERVER_HOST:-your-server-ip}}"
RUN_DIR="${1:-out/ui-smoke/$(date +%Y-%m-%d-%H%M)}"
mkdir -p "$RUN_DIR"
LOG="$RUN_DIR/ui-smoke-runner.log"
RED_COUNT=0

log()   { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }
green() { log "  GREEN  $*"; }
amber() { log "  AMBER  $*"; }
red()   { log "  RED    $*"; RED_COUNT=$((RED_COUNT + 1)); }

# ---------------------------------------------------------------------------
# Helper: GET a URL, expect HTTP 200, optionally grep for a label
# Args: <step-id> <url-path> <expect-label-or-empty>
# ---------------------------------------------------------------------------
check() {
  local step="$1"
  local path="$2"
  local label="${3:-}"
  local url="${PROD_URL}${path}"
  local body status

  status=$(curl -sk -o "$RUN_DIR/${step}-body.html" -w "%{http_code}" "$url" || echo "000")
  body=$(cat "$RUN_DIR/${step}-body.html" 2>/dev/null || echo "")

  if [[ "$status" != "200" ]]; then
    red "$step ${path} HTTP=$status (expected 200)"
    return
  fi

  if [[ -z "$label" ]]; then
    green "$step ${path} HTTP=200"
    return
  fi

  if grep -qF "$label" <<< "$body"; then
    green "$step ${path} label=\"$label\" present"
  else
    red "$step ${path} HTTP=200 BUT label=\"$label\" missing"
  fi
}

# ---------------------------------------------------------------------------
# Helper: GET a URL, REJECT a string (e.g. calendar icon)
# Args: <step-id> <url-path> <forbidden-string>
# ---------------------------------------------------------------------------
check_absent() {
  local step="$1"
  local path="$2"
  local forbidden="$3"
  local url="${PROD_URL}${path}"
  local body

  body=$(curl -sk "$url" 2>/dev/null || echo "")
  if grep -qF "$forbidden" <<< "$body"; then
    red "$step ${path} forbidden=\"$forbidden\" PRESENT"
  else
    green "$step ${path} forbidden=\"$forbidden\" absent"
  fi
}

# ---------------------------------------------------------------------------
# Steps — only steps that CAN be checked via curl/grep without JS render.
# Most playbook steps require chrome-devtools (interactive) so they are NOT
# represented here.
# ---------------------------------------------------------------------------

log "L4 UI smoke runner — $(date +%Y-%m-%d\ %H:%M)"
log "Target: $PROD_URL"
log "RUN_DIR: $RUN_DIR"
log ""

log "--- Domain A (overview + margin) ---"
check        "A1-page"      "/"             "Reports as at"
check        "A2-page"      "/margin"       "Econ COGS"
check        "A4-page"      "/margin"       "From"
check        "A10-page"     "/margin"       "GP%"

log ""
log "--- Domain B (what-if) ---"
check        "B4-page"      "/what-if"      "Grape Prices"

log ""
log "--- Domain C (admin upload) ---"
check        "C-admin"      "/admin"        "Upload"
# C-stub: /admin/upload should ideally redirect or render rich UI; today returns JSON
check        "C-stub"       "/admin/upload" ""

log ""
log "--- Domain E (reference / customer table) ---"
check        "E1-page"      "/reference"    "Customers"
# E6: backend SQL only (no admin UI per scope). Verified via L2/L3 data assertions, not URL probe.

log ""
log "--- Cross-cutting checks ---"
# Check bundled JS for the lucide Calendar SVG path signature (rough heuristic).
check_absent "no-cal-icon" "/" "lucide-calendar"

# Page-crash sniff: look for "Application error" or "client-side exception" anywhere.
for page in "/" "/margin" "/what-if" "/legacy-data" "/reference" "/admin"; do
  body=$(curl -sk "${PROD_URL}${page}" 2>/dev/null || echo "")
  if grep -qiE "(application error|client-side exception|TypeError)" <<< "$body"; then
    red "crash-sniff $page contains error text"
  else
    green "crash-sniff $page clean"
  fi
done

log ""
log "================================================================="
log "Summary: RED=$RED_COUNT (incl any unexpected; expected REDs are operator-walked)"
log "Full log: $LOG"
log "================================================================="

if [[ "$RED_COUNT" -gt 0 ]]; then
  log "EXIT 1 — RED detected. Walk full chrome-devtools playbook before deploy."
  exit 1
else
  log "EXIT 0 — bash sanity GREEN. Now walk chrome-devtools playbook."
  exit 0
fi
