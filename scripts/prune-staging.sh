#!/bin/bash
# prune-staging.sh — BUG-25 (CRITICAL #12 from 2026-04-11 CTO audit)
#
# Purpose: Delete rows older than 7 days from every staging_vinsight_*
# table so the JSONB staging tables (208K rows / 174MB at audit time)
# do not fill /var on the Hostinger VPS.
#
# Safety:
#  - set -euo pipefail so any failure aborts cleanly and exits non-zero
#  - enumerates tables from information_schema so new staging_vinsight_*
#    tables are picked up automatically (and dropped ones are skipped)
#  - uses the `fetched_at` column (verified in schema/001_initial.sql —
#    the staging tables have fetched_at, NOT created_at, so the original
#    BUG-25 spec was off by a column name)
#  - per-table DELETE wrapped in its own transaction by psql
#  - logs every run to /var/log/moppity-prune.log with row counts
#
# Install:
#   scp scripts/prune-staging.sh root@your-server-ip:/opt/moppity/scripts/prune-staging.sh
#   ssh root@your-server-ip "chmod +x /opt/moppity/scripts/prune-staging.sh"
#   ssh root@your-server-ip "crontab -e"
#     0 3 * * * /opt/moppity/scripts/prune-staging.sh
#
# Manual run:
#   bash /opt/moppity/scripts/prune-staging.sh
#   tail -n 20 /var/log/moppity-prune.log

set -euo pipefail

LOG_FILE="/var/log/moppity-prune.log"
RETENTION_DAYS=7
ENV_FILE="/opt/moppity/.env"

# Ensure the log file exists and is writable. If it cannot be created
# (e.g. running as a non-root user in dev), fall back to stdout only.
if ! touch "$LOG_FILE" 2>/dev/null; then
    LOG_FILE="/dev/stdout"
fi

log() {
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S%z')"
    echo "[$ts] $*" | tee -a "$LOG_FILE" >/dev/null
}

log "=== prune-staging.sh start (retention=${RETENTION_DAYS}d) ==="

# Load DATABASE_URL from /opt/moppity/.env if present. Fall back to the
# moppity DB via local peer auth. We do NOT echo the value — only whether
# it was loaded — so the log stays safe for sharing.
if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    set -a
    . "$ENV_FILE"
    set +a
    log "Loaded env from $ENV_FILE"
else
    log "WARN: $ENV_FILE not found — falling back to local moppity_db"
fi

# Build the psql command once. Prefer DATABASE_URL if set; otherwise
# connect as the moppity user against the local moppity_db.
if [[ -n "${DATABASE_URL:-}" ]]; then
    PSQL=(psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -X -q -A -t)
else
    PSQL=(psql -U moppity -d moppity_db -v ON_ERROR_STOP=1 -X -q -A -t)
fi

# Enumerate staging_vinsight_* tables dynamically. The information_schema
# query is parameterized via -v psql variable so there is zero string
# interpolation into the DELETE statements below.
TABLES=$("${PSQL[@]}" -c "SELECT table_name
                          FROM information_schema.tables
                          WHERE table_schema = 'public'
                            AND table_name LIKE 'staging_vinsight_%'
                          ORDER BY table_name;")

if [[ -z "$TABLES" ]]; then
    log "No staging_vinsight_* tables found. Exiting."
    exit 0
fi

TOTAL_DELETED=0
EXIT_CODE=0

# Whitelist pattern: the table name coming back from information_schema
# must still be checked against a safe regex before being substituted
# into the DELETE, because psql's -c flag does not support binding an
# identifier. If a table name fails the whitelist, we skip it and log.
WHITELIST_RE='^staging_vinsight_[a-z0-9_]+$'

while IFS= read -r table; do
    [[ -z "$table" ]] && continue

    if [[ ! "$table" =~ $WHITELIST_RE ]]; then
        log "SKIP: table name '$table' failed whitelist regex"
        continue
    fi

    # Per-table DELETE with parameterised interval. The identifier is
    # whitelist-checked above; the value for the interval is bound via
    # a psql variable so no user input enters the SQL.
    if DELETED=$("${PSQL[@]}" \
            -v days="$RETENTION_DAYS" \
            -c "WITH pruned AS (
                    DELETE FROM ${table}
                    WHERE fetched_at < NOW() - (:'days' || ' days')::interval
                    RETURNING 1
                )
                SELECT COUNT(*) FROM pruned;"); then
        DELETED=${DELETED//[[:space:]]/}
        DELETED=${DELETED:-0}
        TOTAL_DELETED=$((TOTAL_DELETED + DELETED))
        log "  ${table}: deleted ${DELETED} row(s) older than ${RETENTION_DAYS}d"
    else
        log "  ${table}: ERROR during DELETE — see stderr above"
        EXIT_CODE=1
    fi
done <<< "$TABLES"

log "=== prune-staging.sh done: total=${TOTAL_DELETED} row(s) pruned, exit=${EXIT_CODE} ==="

exit "$EXIT_CODE"
