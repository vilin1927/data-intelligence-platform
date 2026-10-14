#!/bin/bash
# Moppity Postgres backup — BUG-15 / DEPLOY-06
#
# Daily pg_dump of moppity_db, offsite sync via rclone, retention cleanup.
# Intended to run as root on the VPS under cron at 01:00 UTC:
#   0 1 * * * /opt/moppity/scripts/backup.sh >> /var/log/moppity-backup.log 2>&1
#
# Requires on VPS:
#   - /opt/moppity/.env with DATABASE_URL + BACKUP_RCLONE_REMOTE + BACKUP_BUCKET
#   - /opt/moppity/backups/ directory writable
#   - /var/log/moppity-backup.log writable
#
# Exits non-zero on ANY failure so cron / freshness check surfaces the issue.

set -euo pipefail

# ---- Config ----------------------------------------------------------------
BACKUP_DIR="/opt/moppity/backups"
LOG_FILE="/var/log/moppity-backup.log"
ENV_FILE="/opt/moppity/.env"
DB_NAME="moppity_db"
TS="$(date -u +%Y%m%d_%H%M%S)"
DAY_OF_WEEK="$(date -u +%u)"   # 1=Mon .. 7=Sun
DAY_OF_MONTH="$(date -u +%d)"

# ---- Logging helper --------------------------------------------------------
log() {
    local msg="$1"
    printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$msg" | tee -a "$LOG_FILE"
}

fail() {
    log "ERROR: $1"
    exit 1
}

trap 'fail "backup.sh aborted unexpectedly at line $LINENO"' ERR

# ---- Preconditions ---------------------------------------------------------
mkdir -p "$BACKUP_DIR"
touch "$LOG_FILE"

if [[ ! -f "$ENV_FILE" ]]; then
    fail "env file not found: $ENV_FILE"
fi

# Source env so DATABASE_URL / BACKUP_RCLONE_REMOTE / BACKUP_BUCKET are available.
# shellcheck disable=SC1090
set -a
. "$ENV_FILE"
set +a

if [[ -z "${DATABASE_URL:-}" ]]; then
    fail "DATABASE_URL not set in $ENV_FILE"
fi

# ---- Classify backup (daily / weekly / monthly) ----------------------------
# Filename prefix drives retention policy later in this script.
if [[ "$DAY_OF_MONTH" == "01" ]]; then
    PREFIX="moppity_monthly"
elif [[ "$DAY_OF_WEEK" == "7" ]]; then
    PREFIX="moppity_weekly"
else
    PREFIX="moppity_daily"
fi

DUMP_FILE="${BACKUP_DIR}/${PREFIX}_${TS}.dump"

log "START backup ${PREFIX} target=${DUMP_FILE}"

# ---- pg_dump ---------------------------------------------------------------
# -Fc = custom format (compressed, restore-friendly).
# Use DATABASE_URL directly so credentials never appear on CLI.
if ! pg_dump -Fc --no-owner --no-acl --dbname="$DATABASE_URL" --file="$DUMP_FILE"; then
    fail "pg_dump failed for $DB_NAME"
fi

if [[ ! -s "$DUMP_FILE" ]]; then
    fail "dump file empty or missing: $DUMP_FILE"
fi

DUMP_SIZE="$(du -h "$DUMP_FILE" | awk '{print $1}')"
log "pg_dump ok size=${DUMP_SIZE}"

# ---- Offsite copy (rclone) -------------------------------------------------
# Accepts Backblaze B2 or Cloudflare R2; remote is named in /opt/moppity/.env
# as BACKUP_RCLONE_REMOTE (e.g. "b2-moppity") and bucket as BACKUP_BUCKET
# (e.g. "moppity-backups").
if [[ -n "${BACKUP_RCLONE_REMOTE:-}" && -n "${BACKUP_BUCKET:-}" ]]; then
    if command -v rclone >/dev/null 2>&1; then
        if rclone copy "$DUMP_FILE" "${BACKUP_RCLONE_REMOTE}:${BACKUP_BUCKET}/" --quiet; then
            log "rclone copy ok remote=${BACKUP_RCLONE_REMOTE}:${BACKUP_BUCKET}"
        else
            fail "rclone copy failed to ${BACKUP_RCLONE_REMOTE}:${BACKUP_BUCKET}"
        fi
    else
        fail "rclone binary not found on PATH"
    fi
else
    log "WARN offsite sync skipped (BACKUP_RCLONE_REMOTE or BACKUP_BUCKET unset)"
fi

# ---- Retention -------------------------------------------------------------
# Daily: keep last 7 days
# Weekly: keep last 4 weeks (~28 days)
# Monthly: keep indefinitely (never deleted here)
#
# We rely on filename prefix + mtime so a manually-copied file does not get
# reclassified. Monthly files are explicitly NOT matched by any -delete rule.

log "retention sweep"

# Daily cleanup — older than 7 days
find "$BACKUP_DIR" -maxdepth 1 -type f -name 'moppity_daily_*.dump' -mtime +7 -print -delete \
    | while read -r removed; do log "retention removed daily: $(basename "$removed")"; done || true

# Weekly cleanup — older than 28 days
find "$BACKUP_DIR" -maxdepth 1 -type f -name 'moppity_weekly_*.dump' -mtime +28 -print -delete \
    | while read -r removed; do log "retention removed weekly: $(basename "$removed")"; done || true

# Monthly: intentionally untouched. Operators may prune manually.

log "retention done"
log "DONE backup ${PREFIX} size=${DUMP_SIZE}"

exit 0
