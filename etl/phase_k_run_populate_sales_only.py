"""
Phase K — one-shot scope-narrow runner for populate_sales_transaction.

PARKED 2026-05-01 — DO NOT RUN. See BUG-145 resolution_note + schema/054.
The 2026-04-23 run of this script inserted 1,316 access_db rows carrying
$51.5M of inflated gross revenue (line-total-as-per-case). schema/054
reverted those rows on 2026-05-01.

populate_sales_transaction in etl/transform_to_core.py has been reverted to
pre-Phase-K state; this runner is kept on disk only as groundwork for a
future Phase K v2 (which must redesign the warehouse-column handling, the
BUG-115 sku lookup, and the BUG-114 wholesale_fee rule before re-running).

Run guard below raises unless --force-phase-k-v2 is passed, to prevent
accidental re-insertion of the same bad data.

---
Original docstring (for Phase K v2 reference):

Calls ONLY etl/transform_to_core.populate_sales_transaction in a single
transaction with pre/post counts and assertions. Other transform steps
(populate_sku, populate_customer, populate_from_vinsight, populate_from_xero)
are deferred — they would refresh 7 other tables outside Phase K's scope.

Per Phase K Option B (chosen 2026-04-30 to keep blast radius tight to the
"""
from __future__ import annotations

import logging
import os
import sys

import psycopg2

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from transform_to_core import populate_sales_transaction  # noqa: E402

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
log = logging.getLogger("phase_k_runner")


def main() -> int:
    if "--force-phase-k-v2" not in sys.argv:
        raise RuntimeError(
            "Phase K runner PARKED since 2026-05-01 (see BUG-145, schema/054). "
            "Re-running this script as-is will re-insert the 1,316 bad rows "
            "reverted by schema/054. If you're running Phase K v2 with a "
            "redesigned populate_sales_transaction, pass --force-phase-k-v2."
        )
    db_url = os.environ["DATABASE_URL"]
    conn = psycopg2.connect(db_url)
    conn.autocommit = False
    try:
        with conn.cursor() as cur:
            # --- PRE counts ---
            cur.execute("SELECT count(*) FROM sales_transaction")
            pre_st = cur.fetchone()[0]
            cur.execute("SELECT count(*) FROM sales_transaction WHERE source_system='access_db'")
            pre_st_access = cur.fetchone()[0]
            cur.execute("SELECT count(*) FROM sku_code_map")
            pre_scm = cur.fetchone()[0]
            cur.execute("""
                SELECT count(*) FROM sku_code_map scm
                JOIN sku s ON s.sku_id = scm.sku_id
                WHERE s.is_wine = FALSE
            """)
            pre_scm_nonwine = cur.fetchone()[0]
            log.info("PRE: sales_transaction=%d (access=%d); sku_code_map=%d (non-wine=%d)",
                     pre_st, pre_st_access, pre_scm, pre_scm_nonwine)

            # --- Run patched populate_sales_transaction inside this single txn ---
            inserted = populate_sales_transaction(cur)
            log.info("populate_sales_transaction returned inserted=%d", inserted)

            # --- POST counts (still inside txn) ---
            cur.execute("SELECT count(*) FROM sales_transaction")
            post_st = cur.fetchone()[0]
            cur.execute("SELECT count(*) FROM sales_transaction WHERE source_system='access_db'")
            post_st_access = cur.fetchone()[0]
            cur.execute("SELECT count(*) FROM sku_code_map")
            post_scm = cur.fetchone()[0]
            cur.execute("""
                SELECT count(*) FROM sku_code_map scm
                JOIN sku s ON s.sku_id = scm.sku_id
                WHERE s.is_wine = FALSE
            """)
            post_scm_nonwine = cur.fetchone()[0]
            log.info("POST: sales_transaction=%d (access=%d); sku_code_map=%d (non-wine=%d)",
                     post_st, post_st_access, post_scm, post_scm_nonwine)
            log.info("DELTA: sales_transaction=%+d (access=%+d); sku_code_map=%+d (non-wine=%+d)",
                     post_st - pre_st, post_st_access - pre_st_access,
                     post_scm - pre_scm, post_scm_nonwine - pre_scm_nonwine)

            # --- Assertions ---
            assert post_scm == pre_scm, (
                f"sku_code_map count changed ({pre_scm} -> {post_scm}); "
                "Phase K Option B is sales-only — should not touch sku_code_map."
            )
            # Non-wine sku_code_map should not GROW (the 84 pre-existing dry-goods
            # rows from recon_etl pre-BUG-91 remain; BUG-91 filter prevents NEW ones).
            assert post_scm_nonwine <= pre_scm_nonwine, (
                f"non-wine sku_code_map grew ({pre_scm_nonwine} -> {post_scm_nonwine}); "
                "BUG-91 dry-goods filter regression."
            )
            # access_db row delta upper bound: there are 120,343 access_combined_data
            # rows, 119,124 prior stored. Any growth beyond ~1,219 indicates
            # sku_lookup mismatch creating duplicate-identity rows.
            assert (post_st_access - pre_st_access) <= 2000, (
                f"access_db delta {post_st_access - pre_st_access} exceeds 2000 — "
                "suggests BUG-115 fix did not collapse identity hashes as expected."
            )

            log.info("All assertions PASSED. Committing transaction.")
        conn.commit()
        return 0
    except Exception:
        log.exception("Transaction failed; rolling back.")
        conn.rollback()
        return 2
    finally:
        conn.close()


if __name__ == "__main__":
    sys.exit(main())
