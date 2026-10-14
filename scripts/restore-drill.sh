#!/bin/bash
# Moppity restore drill — BUG-15 / DEPLOY-06
#
# Picks the newest moppity_*.dump, restores it into a scratch database
# (moppity_db_drill), verifies row counts against production within 0.5%,
# then drops the scratch DB.
#
# Intended cadence: weekly, manually or via cron. Non-interactive, so cron
# will surface failures via email when exit != 0.
#
# Preconditions on VPS:
#   - /opt/moppity/.env with DATABASE_URL (production) + optional
#     DRILL_DATABASE_URL pointing at the scratch DB template (defaults
#     to postgresql://moppity@localhost/postgres for createdb/dropdb).
#   - User running the script can createdb/dropdb on localhost.
#   - pg_restore + psql on PATH.

set -euo pipefail

BACKUP_DIR="/opt/moppity/backups"
ENV_FILE="/opt/moppity/.env"
SCRATCH_DB="moppity_db_drill"
DRIFT_TOLERANCE_PCT="0.5"

log() { printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }

fail() {
    log "ERROR: $*"
    exit 1
}

cleanup() {
    # Best-effort drop of scratch DB on any exit path.
    if [[ -n "${SCRATCH_CREATED:-}" ]]; then
        log "cleanup: dropping ${SCRATCH_DB}"
        dropdb --if-exists "$SCRATCH_DB" >/dev/null 2>&1 || log "WARN dropdb failed"
    fi
}
trap cleanup EXIT

# ---- Load env --------------------------------------------------------------
if [[ ! -f "$ENV_FILE" ]]; then
    fail "env file not found: $ENV_FILE"
fi
# shellcheck disable=SC1090
set -a
. "$ENV_FILE"
set +a

if [[ -z "${DATABASE_URL:-}" ]]; then
    fail "DATABASE_URL not set"
fi

# ---- Pick newest dump ------------------------------------------------------
if find --version >/dev/null 2>&1; then
    NEWEST="$(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'moppity_*.dump' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -n1 | awk '{ $1=""; sub(/^ /, ""); print }')"
else
    NEWEST="$(ls -1t "$BACKUP_DIR"/moppity_*.dump 2>/dev/null | head -n1 || true)"
fi

if [[ -z "${NEWEST:-}" ]]; then
    fail "no backup file to drill"
fi
log "drill target: $NEWEST"

# ---- Create scratch DB -----------------------------------------------------
if psql -lqt | awk '{print $1}' | grep -qx "$SCRATCH_DB"; then
    log "scratch DB already exists; dropping first"
    dropdb "$SCRATCH_DB"
fi
createdb "$SCRATCH_DB"
SCRATCH_CREATED=1
log "created scratch DB ${SCRATCH_DB}"

# ---- Restore ---------------------------------------------------------------
if ! pg_restore --no-owner --no-acl --dbname="$SCRATCH_DB" "$NEWEST"; then
    fail "pg_restore into ${SCRATCH_DB} failed"
fi
log "pg_restore ok"

# ---- Verify row counts -----------------------------------------------------
# Compare counts of a few critical tables against production. If any table
# drifts more than DRIFT_TOLERANCE_PCT (default 0.5%), mark FAIL.
TABLES=(
    "sales_transaction"
    "combined_data"
    "sku"
    "customers"
)

FAIL_COUNT=0
for tbl in "${TABLES[@]}"; do
    # Existence check: if prod doesn't have the table, skip quietly (schema drift).
    PROD_EXISTS="$(psql -Atq --dbname="$DATABASE_URL" -c "SELECT to_regclass('public.${tbl}') IS NOT NULL;")"
    if [[ "$PROD_EXISTS" != "t" ]]; then
        log "skip ${tbl} (missing in prod)"
        continue
    fi

    PROD_COUNT="$(psql -Atq --dbname="$DATABASE_URL" -c "SELECT COUNT(*) FROM ${tbl};")"
    DRILL_COUNT="$(psql -Atq -d "$SCRATCH_DB" -c "SELECT COUNT(*) FROM ${tbl};")"

    # Use awk for float math; bail if prod has 0 rows (trivially OK).
    if [[ "$PROD_COUNT" == "0" && "$DRILL_COUNT" == "0" ]]; then
        log "OK ${tbl}: 0 / 0"
        continue
    fi

    DRIFT_PCT="$(awk -v p="$PROD_COUNT" -v d="$DRILL_COUNT" 'BEGIN {
        if (p == 0) { print (d == 0 ? 0 : 100); exit }
        diff = p - d; if (diff < 0) diff = -diff;
        printf "%.4f", (diff / p) * 100.0
    }')"

    WITHIN="$(awk -v drift="$DRIFT_PCT" -v tol="$DRIFT_TOLERANCE_PCT" 'BEGIN { print (drift+0 <= tol+0) ? 1 : 0 }')"
    if [[ "$WITHIN" == "1" ]]; then
        log "OK  ${tbl}: prod=${PROD_COUNT} drill=${DRILL_COUNT} drift=${DRIFT_PCT}%"
    else
        log "FAIL ${tbl}: prod=${PROD_COUNT} drill=${DRILL_COUNT} drift=${DRIFT_PCT}% > ${DRIFT_TOLERANCE_PCT}%"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
done

if (( FAIL_COUNT > 0 )); then
    fail "${FAIL_COUNT} table(s) exceeded ${DRIFT_TOLERANCE_PCT}% drift"
fi

log "restore drill PASSED against $NEWEST"
exit 0
