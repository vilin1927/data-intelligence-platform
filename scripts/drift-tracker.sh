#!/usr/bin/env bash
# drift-tracker.sh — L7 universal deploy-gate snapshot (Phase A, 2026-05-11)
#
# Snapshots ~30 key Postgres metrics to JSON. Runs before+after every deploy.
#
# Usage:
#   scripts/drift-tracker.sh snapshot [OUTPUT_FILE]
#       Writes one JSON snapshot. Default OUTPUT_FILE=/tmp/drift-${TIMESTAMP}.json.
#       Exit 0 success, 1 psql failure, 2 invalid args, 3 env missing.
#
# Env (DSN-style preferred, falls back to PG* libpq vars):
#   DATABASE_URL_READONLY (preferred)  e.g. postgresql://host:5432/moppity_db
#   DATABASE_URL                       fallback
#   PGHOST  PGUSER  PGDATABASE  PGPASSWORD   libpq vars when no DSN set
#   DEPLOY_ID                          tag stored in JSON; default = git short HEAD
#
#   - design says "sales_transaction.canonical_sku_id IS NULL"; schema/012 puts
#     canonical_sku_id on sku, NOT on sales_transaction → we count
#     sales_transaction rows whose sku has NULL canonical_sku_id (LEFT JOIN sku).
#   - design says "unmatched_skus pending count" / "unmatched_customers pending
#     count"; no such tables — closest analogues are sku rows + customer rows
#     with NULL canonical_*_id (the same "orphan" definition twice). We report
#     them under unmatched_sku_count + unmatched_customer_count so the metric
#     name still tells the operator "what needs canonical assignment".
#   - design says "distinct sku_cogs.cogs_per_unit values"; schema/001 sku_cogs
#     has GENERATED total_cogs_economic + total_cogs_accounting + COGS components.
#     master_cogs.cogs_value is the closest "per-unit ratchet" metric (Access
#     authority per JC-A8 baseline). We report distinct values from master_cogs.
#   - design says "canonical_customer.territory_name NOT NULL"; col confirmed
#     on schema/012 line 75. Matches as-is.
#   - design says "customer twin-pair count (bare + @ form same canonical)";
#     customer rows where ONE matches LIKE '% @ %' and another has the same
#     canonical_customer_id without the suffix. We count distinct canonical_ids
#     that have >=2 rows where some have '@' and some don't.

set -euo pipefail
trap 'echo -e "\033[0;31m[drift-tracker] ERROR at line $LINENO\033[0m" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ─── Arg parse ────────────────────────────────────────────────────────────
MODE="${1:-}"
if [[ "${MODE}" != "snapshot" ]]; then
    echo "Usage: $0 snapshot [OUTPUT_FILE]" >&2
    echo "  snapshot — write one JSON drift snapshot." >&2
    exit 2
fi

TS_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
TS_FILE="$(date -u +%Y%m%dT%H%M%SZ)"
OUT_FILE="${2:-/tmp/drift-${TS_FILE}.json}"

DEPLOY_ID="${DEPLOY_ID:-$(git -C "${REPO_ROOT}" rev-parse --short HEAD 2>/dev/null || echo unknown)}"

# ─── psql connection resolution ────────────────────────────────────────────
PSQL_DSN=""
if [[ -n "${DATABASE_URL_READONLY:-}" ]]; then
    PSQL_DSN="${DATABASE_URL_READONLY}"
elif [[ -n "${DATABASE_URL:-}" ]]; then
    PSQL_DSN="${DATABASE_URL}"
fi

run_psql() {
    # Pass through libpq env vars when no DSN; psql honors PGHOST/PGUSER/etc.
    if [[ -n "${PSQL_DSN}" ]]; then
        psql "${PSQL_DSN}" -v ON_ERROR_STOP=1 -X -q -A -t -F$'\t' "$@"
    else
        psql -v ON_ERROR_STOP=1 -X -q -A -t -F$'\t' "$@"
    fi
}

# ─── Query — all metrics in one round-trip via json_build_object ───────────
# Returns a single JSON line containing table_counts + known_bad + known_good.
# Uses LATERAL + format() to enumerate public.* tables for table_counts so we
# don't have to hardcode the table list.
SQL=$(cat <<'EOF'
WITH
-- universal table counts: every public table
all_tables AS (
    SELECT
        c.relname AS table_name,
        (xpath('/row/c/text()',
               query_to_xml(format('SELECT COUNT(*) AS c FROM public.%I',
                                   c.relname),
                            false, true, '')))[1]::text::bigint AS row_count
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relkind = 'r'  -- ordinary tables only (skip views/matviews)
),
table_counts_json AS (
    SELECT jsonb_object_agg(table_name, row_count) AS j
    FROM all_tables
),

-- known-bad metrics (rises = BLOCK)
m_orphan_customers AS (
    SELECT COUNT(*)::bigint AS v
    FROM customer
    WHERE canonical_customer_id IS NULL
),
m_null_region_sku AS (
    SELECT COUNT(*)::bigint AS v
    FROM sku
    WHERE region IS NULL OR region = ''
),
m_null_territory_cc AS (
    SELECT COUNT(*)::bigint AS v
    FROM canonical_customer
    WHERE territory_name IS NULL OR territory_name = ''
),
m_null_canonical_sku_st AS (
    -- sales_transaction.canonical_sku_id doesn't exist; count via JOIN sku.
    SELECT COUNT(*)::bigint AS v
    FROM sales_transaction st
    LEFT JOIN sku s ON s.sku_id = st.sku_id
    WHERE s.canonical_sku_id IS NULL
),
m_null_customer_st AS (
    SELECT COUNT(*)::bigint AS v
    FROM sales_transaction
    WHERE customer_id IS NULL
),
m_twin_pair_count AS (
    -- bare + "NAME @ SUBURB" form pointing to same canonical_customer_id
    SELECT COUNT(*)::bigint AS v
    FROM (
        SELECT canonical_customer_id
        FROM customer
        WHERE canonical_customer_id IS NOT NULL
        GROUP BY canonical_customer_id
        HAVING COUNT(*) FILTER (WHERE customer_name LIKE '% @ %') > 0
           AND COUNT(*) FILTER (WHERE customer_name NOT LIKE '% @ %') > 0
    ) p
),
m_null_warehouse_st AS (
    SELECT COUNT(*)::bigint AS v
    FROM sales_transaction
    WHERE warehouse IS NULL OR warehouse = ''
),
m_null_channel_st AS (
    SELECT COUNT(*)::bigint AS v
    FROM sales_transaction
    WHERE channel_id IS NULL
),
m_duplicate_source_ref AS (
    SELECT COUNT(*)::bigint AS v
    FROM (
        SELECT source_system, source_ref
        FROM sales_transaction
        WHERE source_ref IS NOT NULL AND source_system IS NOT NULL
        GROUP BY source_system, source_ref
        HAVING COUNT(*) > 1
    ) d
),
m_unmatched_sku_count AS (
    -- "unmatched sku" = sku row with NULL canonical_sku_id (review backlog)
    SELECT COUNT(*)::bigint AS v
    FROM sku
    WHERE canonical_sku_id IS NULL
),
m_unmatched_customer_count AS (
    -- "unmatched customer" = customer row with NULL canonical_customer_id
    SELECT COUNT(*)::bigint AS v
    FROM customer
    WHERE canonical_customer_id IS NULL
),

-- known-good metrics (drops > 5% = FLAG yellow)
g_distinct_cogs_values AS (
    -- design doc: sku_cogs.cogs_per_unit (no such col); use master_cogs.cogs_value
    -- per A8 master_cogs v2 baseline (commit 9935026).
    SELECT COUNT(DISTINCT cogs_value)::bigint AS v
    FROM master_cogs
),
g_canonical_sku_count AS (
    SELECT COUNT(*)::bigint AS v FROM canonical_sku
),
g_canonical_customer_count AS (
    SELECT COUNT(*)::bigint AS v FROM canonical_customer
),
g_sales_transaction_count AS (
    SELECT COUNT(*)::bigint AS v FROM sales_transaction
)

SELECT json_build_object(
    'timestamp',  :'ts_utc',
    'deploy_id',  :'deploy_id',
    'metrics', json_build_object(
        'table_counts', (SELECT j FROM table_counts_json),
        'known_bad', json_build_object(
            'orphan_customers',                  (SELECT v FROM m_orphan_customers),
            'null_region_sku',                   (SELECT v FROM m_null_region_sku),
            'null_territory_canonical_customer', (SELECT v FROM m_null_territory_cc),
            'null_canonical_sku_sales_transaction', (SELECT v FROM m_null_canonical_sku_st),
            'null_customer_sales_transaction',   (SELECT v FROM m_null_customer_st),
            'twin_pair_count',                   (SELECT v FROM m_twin_pair_count),
            'null_warehouse_sales_transaction',  (SELECT v FROM m_null_warehouse_st),
            'null_channel_sales_transaction',    (SELECT v FROM m_null_channel_st),
            'duplicate_source_ref',              (SELECT v FROM m_duplicate_source_ref),
            'unmatched_skus_pending',            (SELECT v FROM m_unmatched_sku_count),
            'unmatched_customers_pending',       (SELECT v FROM m_unmatched_customer_count)
        ),
        'known_good', json_build_object(
            'distinct_cogs_values',         (SELECT v FROM g_distinct_cogs_values),
            'canonical_sku_count',          (SELECT v FROM g_canonical_sku_count),
            'canonical_customer_count',     (SELECT v FROM g_canonical_customer_count),
            'sales_transaction_count',      (SELECT v FROM g_sales_transaction_count)
        )
    )
)::text
EOF
)

# ─── Probe DB reachability first ──────────────────────────────────────────
if ! run_psql -c "SELECT 1" >/dev/null 2>&1; then
    if [[ -z "${PSQL_DSN}" ]] && [[ -z "${PGHOST:-}${PGUSER:-}${PGDATABASE:-}" ]]; then
        echo -e "${RED}[drift-tracker] ERROR: no DB connection — set DATABASE_URL_READONLY, DATABASE_URL, or PGHOST/PGUSER/PGDATABASE.${NC}" >&2
        exit 3
    fi
    echo -e "${RED}[drift-tracker] ERROR: psql probe failed; check DSN + credentials.${NC}" >&2
    exit 1
fi

# ─── Run snapshot query ───────────────────────────────────────────────────
echo -e "${YELLOW}[drift-tracker] snapshotting at ${TS_UTC} (deploy_id=${DEPLOY_ID})${NC}" >&2

RAW_JSON=$(printf '%s' "${SQL}" | run_psql \
    -v "ts_utc=${TS_UTC}" \
    -v "deploy_id=${DEPLOY_ID}" 2>&1) || {
    echo -e "${RED}[drift-tracker] ERROR: snapshot query failed:${NC}" >&2
    echo "${RAW_JSON}" >&2
    exit 1
}
# L7 fix 2026-05-11: pipe SQL via stdin so psql client-side :'var'
# substitution actually fires. With `-c "${SQL}"` psql sees the literal
# `:'ts_utc'` and throws `syntax error at or near ":"` — :vars only
# interpolate from `-f file` or stdin.

# Strip leading/trailing whitespace; psql -A -t returns a single line of JSON.
RAW_JSON="$(echo "${RAW_JSON}" | tr -d '\r')"

# Validate JSON via jq if present, fall back to crude check.
if command -v jq >/dev/null 2>&1; then
    if ! echo "${RAW_JSON}" | jq . >/dev/null 2>&1; then
        echo -e "${RED}[drift-tracker] ERROR: psql returned invalid JSON.${NC}" >&2
        echo "${RAW_JSON}" >&2
        exit 1
    fi
    # Pretty-print to output file.
    echo "${RAW_JSON}" | jq . > "${OUT_FILE}"
else
    case "${RAW_JSON}" in
        '{'*'}') echo "${RAW_JSON}" > "${OUT_FILE}" ;;
        *)
            echo -e "${RED}[drift-tracker] ERROR: jq unavailable + psql output not JSON-shaped.${NC}" >&2
            echo "${RAW_JSON}" >&2
            exit 1
            ;;
    esac
fi

echo -e "${GREEN}[drift-tracker] OK — snapshot written: ${OUT_FILE}${NC}" >&2
# Echo the path to stdout so callers can capture via $(...).
echo "${OUT_FILE}"
exit 0
