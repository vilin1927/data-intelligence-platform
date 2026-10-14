#!/usr/bin/env bash
# pg-backup.sh — Daily Postgres backup for moppity_db
# BUG-47 / JR-108. Phase 1 close plan item.
#
# - Uses sudo -u postgres pg_dump (local peer auth; no password in script).
# - Custom format (-Fc), compressed.
# - Writes to /var/backups/postgres/moppity_db_YYYYMMDD_HHMMSS.dump
# - Rotates: deletes dumps older than 14 days.
# - Logs to /var/log/moppity-pg-backup.log (start ts, size on success, errors).
# - Exits non-zero on failure.
#
# Cron: 0 3 * * * /opt/moppity/scripts/pg-backup.sh >> /var/log/moppity-pg-backup.log 2>&1

set -u
set -o pipefail

DB_NAME="moppity_db"
BACKUP_DIR="/var/backups/postgres"
LOG_FILE="/var/log/moppity-pg-backup.log"
RETENTION_DAYS=14

TS="$(date -u +%Y%m%d_%H%M%S)"
DUMP_FILE="${BACKUP_DIR}/${DB_NAME}_${TS}.dump"

log() {
    # ISO-8601 UTC timestamp prefix, written to both stdout (for cron mail) and log file.
    local line
    line="$(date -u +'%Y-%m-%dT%H:%M:%SZ') [pg-backup] $*"
    echo "$line"
    echo "$line" >> "$LOG_FILE" 2>/dev/null || true
}

fail() {
    log "ERROR: $*"
    exit 1
}

# Pre-flight: backup dir must exist and be writable by root.
if [ ! -d "$BACKUP_DIR" ]; then
    mkdir -p "$BACKUP_DIR" || fail "Cannot create $BACKUP_DIR"
    chmod 700 "$BACKUP_DIR" || true
fi

# Ensure log file exists.
if [ ! -f "$LOG_FILE" ]; then
    touch "$LOG_FILE" 2>/dev/null || true
    chmod 640 "$LOG_FILE" 2>/dev/null || true
fi

log "START dump -> ${DUMP_FILE}"

# pg_dump runs as postgres user (peer auth, no password in script), but the
# postgres user cannot write into /var/backups/postgres/ (root-only, 700).
# Workaround: dump to a postgres-writable staging path under /var/lib/postgresql,
# then move into the secure backup dir as root.
STAGE_DIR="/var/lib/postgresql/backup-stage"
STAGE_FILE="${STAGE_DIR}/${DB_NAME}_${TS}.dump"

install -d -o postgres -g postgres -m 700 "$STAGE_DIR" || fail "Cannot prepare stage dir $STAGE_DIR"

if ! sudo -u postgres pg_dump -Fc "$DB_NAME" -f "$STAGE_FILE" 2>>"$LOG_FILE"; then
    [ -f "$STAGE_FILE" ] && rm -f "$STAGE_FILE"
    fail "pg_dump failed for $DB_NAME"
fi

if [ ! -s "$STAGE_FILE" ]; then
    rm -f "$STAGE_FILE"
    fail "Dump file missing or empty: $STAGE_FILE"
fi

# Move into secure backup dir as root.
mv "$STAGE_FILE" "$DUMP_FILE" || fail "Failed to move dump to $DUMP_FILE"
chown root:root "$DUMP_FILE" 2>/dev/null || true
chmod 600 "$DUMP_FILE" || true

SIZE_BYTES=$(stat -c%s "$DUMP_FILE" 2>/dev/null || stat -f%z "$DUMP_FILE")
SIZE_HUMAN=$(du -h "$DUMP_FILE" | awk '{print $1}')
log "OK dump complete size=${SIZE_HUMAN} (${SIZE_BYTES} bytes) file=${DUMP_FILE}"

# Rotate: delete dumps older than RETENTION_DAYS.
DELETED=$(find "$BACKUP_DIR" -maxdepth 1 -type f -name "${DB_NAME}_*.dump" -mtime +"$RETENTION_DAYS" -print -delete | wc -l | tr -d ' ')
log "ROTATE deleted=${DELETED} (retention=${RETENTION_DAYS}d)"

REMAINING=$(find "$BACKUP_DIR" -maxdepth 1 -type f -name "${DB_NAME}_*.dump" | wc -l | tr -d ' ')
log "DONE remaining_dumps=${REMAINING}"

exit 0
