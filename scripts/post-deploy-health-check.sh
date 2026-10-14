#!/bin/bash
# Post-deploy health check for Moppity Vineyards
# Runs automated checks against the VPS after a deployment.
#
# Usage:  bash scripts/post-deploy-health-check.sh
# Exit:   0 if all critical checks pass, 1 if any critical check fails
#
# This script SSHs to the VPS and verifies:
#   - PM2 is online and recently restarted
#   - Database is accessible
#   - .env.local exists with required keys
#   - Disk space is under 80%
#   - Script permissions are correct
#   - Cron jobs exist
#   - ETL logs are recent
#   - Data integrity (row counts, COGS, revenue)

set -uo pipefail

# ── Config ─────────────────────────────────────────────────────────────────────
VPS_IP="${SERVER_HOST:-your-server-ip}"
VPS_USER="root"
SSH_CMD="ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new ${VPS_USER}@${VPS_IP}"
DB_CMD="sudo -u postgres psql -d moppity_db -t -A -c"

# ── Colors ─────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

# ── Counters ───────────────────────────────────────────────────────────────────
TOTAL=0
PASSED=0
FAILED=0
WARNED=0
CRITICAL_FAIL=0

# ── Helpers ────────────────────────────────────────────────────────────────────
pass() {
    TOTAL=$((TOTAL + 1))
    PASSED=$((PASSED + 1))
    printf "  ${GREEN}PASS${NC}  %s\n" "$1"
}

fail() {
    TOTAL=$((TOTAL + 1))
    FAILED=$((FAILED + 1))
    CRITICAL_FAIL=$((CRITICAL_FAIL + 1))
    printf "  ${RED}FAIL${NC}  %s\n" "$1"
    if [ -n "${2:-}" ]; then
        printf "        ${RED}-> %s${NC}\n" "$2"
    fi
}

warn() {
    TOTAL=$((TOTAL + 1))
    WARNED=$((WARNED + 1))
    printf "  ${YELLOW}WARN${NC}  %s\n" "$1"
    if [ -n "${2:-}" ]; then
        printf "        ${YELLOW}-> %s${NC}\n" "$2"
    fi
}

section() {
    echo ""
    echo -e "${BOLD}--- $1 ---${NC}"
}

# ── Pre-flight: SSH connectivity ───────────────────────────────────────────────
echo ""
echo -e "${BOLD}=== Moppity Post-Deploy Health Check -- $(date) ===${NC}"
echo -e "    Target: ${VPS_USER}@${VPS_IP}"

section "SSH Connectivity"
if $SSH_CMD "echo ok" > /dev/null 2>&1; then
    pass "SSH connection to ${VPS_IP}"
else
    fail "SSH connection to ${VPS_IP}" "Cannot reach VPS. All remaining checks skipped."
    echo ""
    echo -e "${RED}=== HEALTH CHECK ABORTED -- cannot reach VPS ===${NC}"
    exit 1
fi

# ══════════════════════════════════════════════════════════════════════════════
# SECTION 1: INFRASTRUCTURE CHECKS
# ══════════════════════════════════════════════════════════════════════════════

section "PM2 Status"

PM2_OUTPUT=$($SSH_CMD "pm2 jlist 2>/dev/null" 2>/dev/null || echo "[]")

# Check PM2 process is online
PM2_STATUS=$(echo "$PM2_OUTPUT" | python3 -c "
import json, sys
try:
    procs = json.load(sys.stdin)
    for p in procs:
        if p.get('name') == 'moppity-dashboard':
            print(p.get('pm2_env', {}).get('status', 'unknown'))
            sys.exit(0)
    print('not_found')
except: print('parse_error')
" 2>/dev/null | head -1 || echo "parse_error")

if [ "$PM2_STATUS" = "online" ]; then
    pass "PM2 moppity-dashboard is online"
elif [ "$PM2_STATUS" = "not_found" ]; then
    fail "PM2 moppity-dashboard process" "Process not found in PM2"
else
    fail "PM2 moppity-dashboard is online" "Status: $PM2_STATUS"
fi

# Check PM2 uptime (should be < 2 minutes if just deployed)
PM2_UPTIME_MS=$(echo "$PM2_OUTPUT" | python3 -c "
import json, sys, time
try:
    procs = json.load(sys.stdin)
    for p in procs:
        if p.get('name') == 'moppity-dashboard':
            start = p.get('pm2_env', {}).get('pm_uptime', 0)
            elapsed = int(time.time() * 1000) - start
            print(elapsed)
            sys.exit(0)
    print('-1')
except: print('-1')
" 2>/dev/null || echo "-1")

if [ "$PM2_UPTIME_MS" != "-1" ]; then
    UPTIME_SEC=$((PM2_UPTIME_MS / 1000))
    if [ "$UPTIME_SEC" -lt 120 ]; then
        pass "PM2 uptime < 2 minutes (recently restarted: ${UPTIME_SEC}s ago)"
    elif [ "$UPTIME_SEC" -lt 600 ]; then
        warn "PM2 uptime is ${UPTIME_SEC}s" "Expected < 120s after deploy. Was PM2 restarted?"
    else
        warn "PM2 uptime is ${UPTIME_SEC}s" "Looks like PM2 was NOT restarted during this deploy"
    fi
fi

# ── Database ───────────────────────────────────────────────────────────────────
section "Database"

DB_CHECK=$($SSH_CMD "$DB_CMD \"SELECT 1;\"" 2>/dev/null || echo "error")
if [ "$DB_CHECK" = "1" ]; then
    pass "PostgreSQL moppity_db is accessible"
else
    fail "PostgreSQL moppity_db is accessible" "Query returned: $DB_CHECK"
fi

# ── .env.local ─────────────────────────────────────────────────────────────────
section "Environment File"

ENV_EXISTS=$($SSH_CMD "test -f /var/www/moppity-dashboard/.env.local && echo yes || echo no" 2>/dev/null)
if [ "$ENV_EXISTS" = "yes" ]; then
    pass ".env.local exists at /var/www/moppity-dashboard/"
else
    fail ".env.local exists at /var/www/moppity-dashboard/" "File missing -- dashboard cannot connect to DB"
fi

# Check required keys are present (not their values, just that the keys exist)
for KEY in DATABASE_URL; do
    KEY_EXISTS=$($SSH_CMD "grep -q '^${KEY}=' /var/www/moppity-dashboard/.env.local 2>/dev/null && echo yes || echo no" 2>/dev/null)
    if [ "$KEY_EXISTS" = "yes" ]; then
        pass ".env.local contains ${KEY}"
    else
        fail ".env.local contains ${KEY}" "Key missing from .env.local"
    fi
done

# ANTHROPIC_API_KEY is optional (only needed for AI chat feature)
ANTHROPIC_EXISTS=$($SSH_CMD "grep -q '^ANTHROPIC_API_KEY=' /var/www/moppity-dashboard/.env.local 2>/dev/null && echo yes || echo no" 2>/dev/null)
if [ "$ANTHROPIC_EXISTS" = "yes" ]; then
    pass ".env.local contains ANTHROPIC_API_KEY"
else
    warn ".env.local contains ANTHROPIC_API_KEY" "AI chat feature will not work without this key"
fi

# ── Disk Space ─────────────────────────────────────────────────────────────────
section "Disk Space"

DISK_PCT=$($SSH_CMD "df / | tail -1 | awk '{print \$5}' | tr -d '%'" 2>/dev/null || echo "99")
if [ "$DISK_PCT" -lt 80 ]; then
    pass "Disk usage at ${DISK_PCT}% (under 80% threshold)"
elif [ "$DISK_PCT" -lt 90 ]; then
    warn "Disk usage at ${DISK_PCT}%" "Approaching capacity. Clean old backups/logs."
else
    fail "Disk usage at ${DISK_PCT}%" "Critical: server may run out of space"
fi

# ── Script Permissions ─────────────────────────────────────────────────────────
section "Script Permissions"

SCRIPTS_OUTPUT=$($SSH_CMD "ls -la /opt/moppity/scripts/*.sh 2>/dev/null" 2>/dev/null || echo "")
if [ -z "$SCRIPTS_OUTPUT" ]; then
    warn "Scripts in /opt/moppity/scripts/" "No .sh files found"
else
    # Check each script has execute permission
    NON_EXEC=$($SSH_CMD "find /opt/moppity/scripts/ -name '*.sh' ! -perm -u+x 2>/dev/null | wc -l | tr -d ' '" 2>/dev/null || echo "0")
    if [ "$NON_EXEC" = "0" ]; then
        pass "All scripts in /opt/moppity/scripts/ have execute permission"
    else
        fail "Script permissions" "${NON_EXEC} script(s) missing execute permission"
    fi
fi

# ── Cron Jobs ──────────────────────────────────────────────────────────────────
section "Cron Jobs"

CRON_COUNT=$($SSH_CMD "crontab -l 2>/dev/null | grep -cE 'python|bash'" 2>/dev/null | tr -d '[:space:]' || echo "0")
CRON_COUNT=${CRON_COUNT:-0}
if [ "$CRON_COUNT" -gt 0 ] 2>/dev/null; then
    pass "Found ${CRON_COUNT} cron job(s) with python/bash"
else
    warn "No cron jobs found" "ETL sync may not be running automatically"
fi

# ── ETL Log Recency ────────────────────────────────────────────────────────────
section "ETL Logs"

# Check log files
LATEST_LOG=$($SSH_CMD "ls -t /var/log/moppity/*.log 2>/dev/null | head -1" 2>/dev/null || echo "")
if [ -n "$LATEST_LOG" ]; then
    LOG_AGE_HOURS=$($SSH_CMD "echo \$(( ( \$(date +%s) - \$(stat -c %Y '$LATEST_LOG' 2>/dev/null || echo 0) ) / 3600 ))" 2>/dev/null || echo "999")
    if [ "$LOG_AGE_HOURS" -lt 24 ]; then
        pass "Latest ETL log is ${LOG_AGE_HOURS}h old ($(basename "$LATEST_LOG"))"
    elif [ "$LOG_AGE_HOURS" -lt 72 ]; then
        warn "Latest ETL log is ${LOG_AGE_HOURS}h old" "ETL may not have run recently"
    else
        warn "Latest ETL log is ${LOG_AGE_HOURS}h old" "ETL appears stale -- check cron and scripts"
    fi
else
    # Fall back to etl_run_log table
    LAST_ETL=$($SSH_CMD "$DB_CMD \"SELECT extract(epoch FROM now() - max(started_at))::int / 3600 FROM etl_run_log;\"" 2>/dev/null || echo "")
    if [ -n "$LAST_ETL" ] && [ "$LAST_ETL" != "" ]; then
        if [ "$LAST_ETL" -lt 24 ] 2>/dev/null; then
            pass "Latest ETL run was ${LAST_ETL}h ago (from etl_run_log)"
        else
            warn "Latest ETL run was ${LAST_ETL}h ago" "ETL may not have run recently"
        fi
    else
        warn "No ETL logs found" "Neither /var/log/moppity/ nor etl_run_log have entries"
    fi
fi

# ══════════════════════════════════════════════════════════════════════════════
# SECTION 2: DATA INTEGRITY CHECKS
# ══════════════════════════════════════════════════════════════════════════════

section "Data Integrity"

# Check 1: sales_transaction row count > 100,000
ROW_COUNT=$($SSH_CMD "$DB_CMD \"SELECT count(*) FROM sales_transaction;\"" 2>/dev/null || echo "0")
ROW_COUNT=$(echo "$ROW_COUNT" | tr -d '[:space:]')
if [ -n "$ROW_COUNT" ] && [ "$ROW_COUNT" -gt 100000 ] 2>/dev/null; then
    pass "sales_transaction has ${ROW_COUNT} rows (> 100K threshold)"
elif [ -n "$ROW_COUNT" ] && [ "$ROW_COUNT" -gt 0 ] 2>/dev/null; then
    warn "sales_transaction has ${ROW_COUNT} rows" "Expected > 100,000. Possible data loss."
else
    fail "sales_transaction row count" "Got: ${ROW_COUNT}. Table may be empty or missing."
fi

# Check 2: No flat $22.50 COGS (the bug from Incident 11)
FLAT_COGS=$($SSH_CMD "$DB_CMD \"
    SELECT count(DISTINCT round(economic_cogs_per_unit::numeric, 2))
    FROM sales_transaction
    WHERE economic_cogs_per_unit IS NOT NULL AND economic_cogs_per_unit > 0;
\"" 2>/dev/null || echo "0")
FLAT_COGS=$(echo "$FLAT_COGS" | tr -d '[:space:]')
if [ -n "$FLAT_COGS" ] && [ "$FLAT_COGS" -gt 5 ] 2>/dev/null; then
    pass "COGS has ${FLAT_COGS} distinct values (not flat)"
elif [ "$FLAT_COGS" = "1" ]; then
    fail "COGS variation check" "Only 1 distinct COGS value -- likely flat-rate bug (Incident 11)"
elif [ -n "$FLAT_COGS" ] && [ "$FLAT_COGS" -gt 1 ] 2>/dev/null; then
    warn "COGS has only ${FLAT_COGS} distinct values" "Expected more variation across SKUs"
else
    warn "COGS variation check" "Could not determine distinct COGS count (got: ${FLAT_COGS})"
fi

# Check 3: Revenue total is reasonable (> $0 and < $50M)
REVENUE=$($SSH_CMD "$DB_CMD \"
    SELECT round(sum(net_revenue)::numeric, 2)
    FROM sales_transaction
    WHERE net_revenue IS NOT NULL;
\"" 2>/dev/null || echo "0")
REVENUE=$(echo "$REVENUE" | tr -d '[:space:]')

if [ -n "$REVENUE" ] && [ "$REVENUE" != "0" ] && [ "$REVENUE" != "" ]; then
    # Parse as integer for comparison (strip decimals)
    REV_INT=$(echo "$REVENUE" | cut -d. -f1)
    if [ "$REV_INT" -gt 0 ] 2>/dev/null && [ "$REV_INT" -lt 50000000 ] 2>/dev/null; then
        # Format with commas for display
        REV_DISPLAY=$(printf "%'.2f" "$REVENUE" 2>/dev/null || echo "$REVENUE")
        pass "Total revenue: \$${REV_DISPLAY} (within reasonable range)"
    elif [ "$REV_INT" -le 0 ] 2>/dev/null; then
        fail "Revenue total" "Revenue is \$${REVENUE} -- expected positive value"
    else
        fail "Revenue total" "Revenue is \$${REVENUE} -- exceeds \$50M sanity check"
    fi
else
    warn "Revenue total check" "Could not calculate revenue (got: ${REVENUE})"
fi

# ══════════════════════════════════════════════════════════════════════════════
# SUMMARY
# ══════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${BOLD}=== Summary ===${NC}"
echo -e "  Total:    ${TOTAL}"
echo -e "  Passed:   ${GREEN}${PASSED}${NC}"
echo -e "  Warnings: ${YELLOW}${WARNED}${NC}"
echo -e "  Failed:   ${RED}${FAILED}${NC}"
echo ""

if [ "$CRITICAL_FAIL" -gt 0 ]; then
    echo -e "${RED}=== HEALTH CHECK FAILED -- ${CRITICAL_FAIL} critical issue(s) ===${NC}"
    echo -e "${RED}    Do NOT notify the owner until all failures are resolved.${NC}"
    exit 1
elif [ "$WARNED" -gt 0 ]; then
    echo -e "${YELLOW}=== HEALTH CHECK PASSED WITH WARNINGS ===${NC}"
    echo -e "${YELLOW}    Review warnings above before notifying the owner.${NC}"
    exit 0
else
    echo -e "${GREEN}=== ALL CHECKS PASSED ===${NC}"
    exit 0
fi
