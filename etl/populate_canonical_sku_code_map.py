"""

Derives canonical_sku_code_map rows by joining the existing populated
`sku_code_map` (2,195 rows on prod) to `sku.canonical_sku_id` (535 set rows on
prod). Each (sku.canonical_sku_id, sku_code_map.source_system,
sku_code_map.external_code) tuple becomes one canonical_sku_code_map row.

Folded into B6a from the deferred B2 work per
("populate_canonical_sku_code_map.py — ~80 LOC, JOIN sku_code_map.sku_id →
sku.canonical_sku_id, INSERT one row per (canonical_sku_id, source_system,
external_code, confidence)").

Idempotent: ON CONFLICT (canonical_sku_id, external_code) DO NOTHING per
schema/173 UNIQUE constraint canonical_sku_code_map_canonical_code_uniq
(PHASE1-CLOSE-B1-CSCM-DEDUP, 2026-05-13). Earlier UNIQUE
(source_system, external_code) from schema/012 was DROPPED by schema/173 —
do NOT reintroduce as the ON CONFLICT target or this writer will error
post-deploy. Re-running is safe; cross-source attestation rows for the
same (canonical, external_code) collapse to first-encountered source.


Usage:
    DATABASE_URL=postgresql://... python -m etl.populate_canonical_sku_code_map
"""

import logging
import os
import sys

import psycopg2

from etl.logger import log_etl_run

logger = logging.getLogger("moppity.etl.populate_canonical_sku_code_map")

SOURCE = "populate_canonical_sku_code_map"
ENDPOINT = "sku_code_map -> canonical_sku_code_map"


def populate(conn) -> dict:
    """JOIN sku_code_map → sku.canonical_sku_id and INSERT into canonical_sku_code_map.

    The single-statement INSERT lets Postgres derive everything in one pass
    and reports the affected-row count cleanly. ON CONFLICT keeps it
    idempotent.
    """
    with conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO canonical_sku_code_map
                (canonical_sku_id, source_system, external_code, confidence, notes)
            SELECT DISTINCT
                s.canonical_sku_id,
                scm.source_system,
                scm.external_code,
                1.00 AS confidence,
                'derived from sku_code_map by populate_canonical_sku_code_map.py' AS notes
              FROM sku_code_map scm
              JOIN sku s ON s.sku_id = scm.sku_id
             WHERE s.canonical_sku_id IS NOT NULL
            ON CONFLICT (canonical_sku_id, external_code) DO NOTHING
            """,
        )
        inserted = cur.rowcount

        cur.execute("SELECT count(*) FROM canonical_sku_code_map")
        total = cur.fetchone()[0]

        cur.execute(
            "SELECT count(*) FROM canonical_sku_code_map WHERE source_system = 'dws'"
        )
        dws_total = cur.fetchone()[0]

        cur.execute(
            "SELECT count(DISTINCT canonical_sku_id) FROM canonical_sku_code_map WHERE source_system = 'dws'"
        )
        dws_distinct_canonical = cur.fetchone()[0]

    return {
        "inserted_this_run": inserted,
        "total_after": total,
        "dws_rows_after": dws_total,
        "dws_distinct_canonical_after": dws_distinct_canonical,
    }


def main():
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    )

    db_url = os.environ.get("DATABASE_URL")
    if not db_url:
        print("ERROR: DATABASE_URL not set.", file=sys.stderr)
        sys.exit(1)

    conn = psycopg2.connect(db_url)
    try:
        try:
            stats = populate(conn)
            conn.commit()
        except Exception:
            conn.rollback()
            raise

        print(f"INSERTED this run: {stats['inserted_this_run']}")
        print(f"TOTAL canonical_sku_code_map: {stats['total_after']}")
        print(f"  of which DWS rows: {stats['dws_rows_after']}")
        print(f"  DWS distinct canonical_sku_id: {stats['dws_distinct_canonical_after']} (cap = 27)")

        log_etl_run(
            conn,
            source=SOURCE,
            endpoint=ENDPOINT,
            status="success",
            rows_processed=stats["inserted_this_run"],
            rows_skipped=0,
            error_count=0,
            error_detail=None,
        )

        # AC-A11 floor check (informational; mini-CTO is the gate on prod)
        if stats["total_after"] < 200:
            print(
                f"WARN: total_after = {stats['total_after']} < AC-A11 floor of 200. "
                f"Check that B2 populated sku.canonical_sku_id and sku_code_map.",
                file=sys.stderr,
            )
        sys.exit(0)
    except Exception as exc:
        print(f"FATAL: {exc}", file=sys.stderr)
        try:
            log_etl_run(
                conn, source=SOURCE, endpoint=ENDPOINT, status="error",
                rows_processed=0, error_count=1, error_detail=str(exc),
            )
        except Exception:
            pass
        sys.exit(1)
    finally:
        conn.close()


if __name__ == "__main__":
    main()
