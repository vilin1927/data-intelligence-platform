#!/bin/bash
# Moppity ETL log grep alert — BUG-17 / DEPLOY-09
#
# Scan every /var/log/moppity-*.log for error markers written in the last
# ~65 minutes. If anything matches, emit to stderr and exit 1 so cron emails
# the operator.
#
# Intended cron (hourly, 5 past the hour):
#   5 * * * * /opt/moppity/scripts/etl-log-grep.sh 2>&1 | mail -s 'Moppity ETL alert' ops@example.com
#
# or with MAILTO= at the top of the crontab:
#   5 * * * * /opt/moppity/scripts/etl-log-grep.sh
#
# We use -mmin -65 (not -60) so the hourly run has 5 minutes of overlap and
# never drops an error sitting right on the boundary.

set -euo pipefail

LOG_GLOB="/var/log/moppity-*.log"
WINDOW_MIN=65
# Patterns we treat as hard errors. Extend sparingly — noise defeats the alert.
ERROR_REGEX='(ERROR|FAILED|TypeError|Traceback|CRITICAL|UNAUTHORIZED)'

# Find modified-recently log files
shopt -s nullglob
candidates=()
for f in $LOG_GLOB; do
    candidates+=("$f")
done
shopt -u nullglob

if (( ${#candidates[@]} == 0 )); then
    # Not an alertable condition — we may legitimately have zero logs on a
    # fresh VPS. Exit 0 quietly.
    exit 0
fi

# Restrict to files touched in the window.
recent_files=()
for f in "${candidates[@]}"; do
    if find "$f" -mmin "-${WINDOW_MIN}" -print 2>/dev/null | grep -q .; then
        recent_files+=("$f")
    fi
done

if (( ${#recent_files[@]} == 0 )); then
    # No recent activity — that may itself be a problem (Sheets sync silently
    # dead was the original audit finding) but the freshness alert is a
    # separate concern. For now, exit clean; rely on freshness check in
    # check-backup-freshness.sh for DB-side dead-air.
    exit 0
fi

# Grep recent files; use `tail` to approximate "only recent lines" for files
# that have old history. We pull the last 500 lines per file — plenty for an
# hourly scan at our ETL volume.
matches=""
for f in "${recent_files[@]}"; do
    block="$(tail -n 500 "$f" | grep -E "$ERROR_REGEX" || true)"
    if [[ -n "$block" ]]; then
        matches+="=== ${f} ==="$'\n'"${block}"$'\n\n'
    fi
done

if [[ -n "$matches" ]]; then
    {
        printf 'Moppity ETL log grep alert — %s\n\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        printf '%s' "$matches"
    } >&2
    exit 1
fi

exit 0
