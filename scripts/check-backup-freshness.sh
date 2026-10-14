#!/bin/bash
# Moppity backup freshness alert — BUG-15 / DEPLOY-06
#
# Cron runs this hourly (or at least once per day after backup.sh). If the
# newest moppity_*.dump is more than 36 hours old, OR if no dump is present,
# this script writes to stderr and exits 1 so cron emails the operator.
#
# Suggested cron:
#   0 2 * * * /opt/moppity/scripts/check-backup-freshness.sh
#
# Mail is delivered via the system MTA, so the host must have `mailutils`
# (or equivalent) configured AND a MAILTO= at the top of the crontab.

set -euo pipefail

BACKUP_DIR="/opt/moppity/backups"
MAX_AGE_HOURS=36
NOW_EPOCH="$(date -u +%s)"

if [[ ! -d "$BACKUP_DIR" ]]; then
    echo "ERROR: backup dir missing: $BACKUP_DIR" >&2
    exit 1
fi

# Newest moppity_*.dump (any tier — daily/weekly/monthly).
# Use find -printf '%T@ %p' (Linux); BSD find does not support -printf so we
# fall back to stat on macOS. Target host is Linux VPS, so printf path runs.
NEWEST_FILE=""
if find --version >/dev/null 2>&1; then
    NEWEST_LINE="$(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'moppity_*.dump' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -n1 || true)"
    if [[ -n "$NEWEST_LINE" ]]; then
        NEWEST_FILE="${NEWEST_LINE#* }"
    fi
else
    # macOS / BSD fallback for local dev testing
    NEWEST_FILE="$(ls -1t "$BACKUP_DIR"/moppity_*.dump 2>/dev/null | head -n1 || true)"
fi

if [[ -z "$NEWEST_FILE" ]]; then
    echo "ERROR: no moppity_*.dump found in $BACKUP_DIR" >&2
    exit 1
fi

# Portable mtime in seconds
if stat -c '%Y' "$NEWEST_FILE" >/dev/null 2>&1; then
    FILE_EPOCH="$(stat -c '%Y' "$NEWEST_FILE")"
else
    FILE_EPOCH="$(stat -f '%m' "$NEWEST_FILE")"
fi

AGE_SECONDS=$(( NOW_EPOCH - FILE_EPOCH ))
AGE_HOURS=$(( AGE_SECONDS / 3600 ))
MAX_AGE_SECONDS=$(( MAX_AGE_HOURS * 3600 ))

if (( AGE_SECONDS > MAX_AGE_SECONDS )); then
    echo "ERROR: latest backup is ${AGE_HOURS}h old (> ${MAX_AGE_HOURS}h): $NEWEST_FILE" >&2
    exit 1
fi

echo "OK: latest backup is ${AGE_HOURS}h old: $NEWEST_FILE"
exit 0
