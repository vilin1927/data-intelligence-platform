"""
Phase H — customer.canonical_rep_id backfill.

Ticket: BUG-95 — customer.canonical_rep_id schema column + ETL populate.

Purpose
-------
Populate customer.canonical_rep_id (added by schema/055, nullable FK to
canonical_representative(id)) by joining customer.rep_id → representative →
canonical_representative on UPPER(TRIM(rep_name)).

Fill-NULL-only: UPDATEs rows where canonical_rep_id IS NULL. Safe to re-run;

    - 8,147 rows UPDATEd (customer.rep_id → representative → canonical match)
    - 2,826 rows stay NULL
        - 2,191 rows: customer.rep_id IS NULL → no source
        - 635 rows: rep_id set but representative.rep_name has no canonical
          match (608 Vinsight synth + 27 historical deprecated/sentinel —
    - 0 overwrites (column is fresh from schema/055)

Usage
-----
    DATABASE_URL=postgresql://... \\
    python -m etl.backfill_customer_canonical_rep \\
        --dry-run          # default TRUE; pass --commit to mutate.

Exit codes
----------
    0  success (dry-run or committed)
    1  guard violation (aborted before mutating)
    2  DB error (transaction rolled back)
    3  env error (missing DATABASE_URL)
"""
from __future__ import annotations

import argparse
import logging
import os
import sys
from dataclasses import dataclass

import psycopg2
import psycopg2.extras

logger = logging.getLogger("moppity.etl.backfill_customer_canonical_rep")

EXPECTED_UPDATES = 8147
EXPECTED_NULL_RESIDUAL = 2826  # 2191 null rep_id + 635 rep_id with no canonical
GUARD_UPDATE_SLACK = 50  # tolerate ±50 drift vs 8147 for day-over-day Vinsight churn


@dataclass
class RunStats:
    pre_total: int = 0
    pre_canonical_rep_id_non_null: int = 0
    pre_candidate_null: int = 0
    pre_mappable: int = 0  # customers whose rep_id → representative → canonical has a match
    pre_gap: int = 0  # customers whose rep_id set but no canonical match
    pre_no_rep_id: int = 0  # customers with rep_id IS NULL
    rows_updated: int = 0
    post_canonical_rep_id_non_null: int = 0
    post_canonical_rep_id_null: int = 0

    def summary_lines(self) -> list[str]:
        return [
            f"pre_total (customer rows):        {self.pre_total}",
            f"pre_canonical_rep_id_non_null:    {self.pre_canonical_rep_id_non_null}",
            f"pre_candidate_null:               {self.pre_candidate_null}",
            f"pre_mappable (expect UPDATE):     {self.pre_mappable}",
            f"pre_gap (stays NULL, rep_id set): {self.pre_gap}",
            f"pre_no_rep_id (stays NULL):       {self.pre_no_rep_id}",
            f"rows_updated:                     {self.rows_updated}",
            f"post_canonical_rep_id_non_null:   {self.post_canonical_rep_id_non_null}",
            f"post_canonical_rep_id_null:       {self.post_canonical_rep_id_null}",
        ]


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__.strip().splitlines()[0])
    group = p.add_mutually_exclusive_group()
    group.add_argument(
        "--dry-run",
        dest="dry_run",
        action="store_true",
        default=True,
        help="UPDATE inside transaction then ROLLBACK (default)",
    )
    group.add_argument(
        "--commit",
        dest="dry_run",
        action="store_false",
        help="COMMIT the transaction. Requires explicit opt-in.",
    )
    return p.parse_args()


def capture_pre_stats(cur, stats: RunStats) -> None:
    cur.execute("SELECT count(*) AS n FROM customer")
    stats.pre_total = cur.fetchone()["n"]

    cur.execute(
        "SELECT count(*) AS n FROM customer WHERE canonical_rep_id IS NOT NULL"
    )
    stats.pre_canonical_rep_id_non_null = cur.fetchone()["n"]

    cur.execute(
        "SELECT count(*) AS n FROM customer WHERE canonical_rep_id IS NULL"
    )
    stats.pre_candidate_null = cur.fetchone()["n"]

    cur.execute(
        """
        SELECT count(*) AS n
        FROM customer c
        JOIN representative r ON c.rep_id = r.rep_id
        JOIN canonical_representative cr
          ON UPPER(TRIM(cr.rep_name)) = UPPER(TRIM(r.rep_name))
        WHERE c.canonical_rep_id IS NULL
        """
    )
    stats.pre_mappable = cur.fetchone()["n"]

    cur.execute(
        """
        SELECT count(*) AS n
        FROM customer c
        JOIN representative r ON c.rep_id = r.rep_id
        LEFT JOIN canonical_representative cr
          ON UPPER(TRIM(cr.rep_name)) = UPPER(TRIM(r.rep_name))
        WHERE cr.id IS NULL AND c.canonical_rep_id IS NULL
        """
    )
    stats.pre_gap = cur.fetchone()["n"]

    cur.execute(
        """
        SELECT count(*) AS n
        FROM customer
        WHERE rep_id IS NULL AND canonical_rep_id IS NULL
        """
    )
    stats.pre_no_rep_id = cur.fetchone()["n"]


def execute_backfill(cur) -> int:
    # ETL guard 2026-05-12 (post A14 Rep A E6 root-cause): refuse to auto-derive
    # canonical_rep_id when canonical_customer_rep_history has a manual rep
    # assignment for the linked canonical_customer. Defense-in-depth against
    # rep_name-JOIN re-derive overwriting a downstream manual reassignment
    # (E6 class — Rep A NCC reassignment was overwritten across 326
    # rows pre-schema/171 because no history-aware guard existed).
    cur.execute(
        """
        UPDATE customer
        SET canonical_rep_id = cr.id
        FROM representative r
        JOIN canonical_representative cr
          ON UPPER(TRIM(cr.rep_name)) = UPPER(TRIM(r.rep_name))
        WHERE customer.rep_id = r.rep_id
          AND customer.canonical_rep_id IS NULL
          AND NOT EXISTS (
              SELECT 1
              FROM canonical_customer_rep_history h
              WHERE h.customer_id = customer.canonical_customer_id
          )
        """
    )
    return cur.rowcount


def capture_post_stats(cur, stats: RunStats) -> None:
    cur.execute(
        "SELECT count(*) AS n FROM customer WHERE canonical_rep_id IS NOT NULL"
    )
    stats.post_canonical_rep_id_non_null = cur.fetchone()["n"]

    cur.execute(
        "SELECT count(*) AS n FROM customer WHERE canonical_rep_id IS NULL"
    )
    stats.post_canonical_rep_id_null = cur.fetchone()["n"]


def guard_pre_mutation(stats: RunStats) -> tuple[bool, list[str]]:
    errors: list[str] = []
    # Pre-state must be clean: no pre-existing canonical_rep_id (schema/055 just landed).
    if stats.pre_canonical_rep_id_non_null != 0:
        errors.append(
            f"pre_canonical_rep_id_non_null={stats.pre_canonical_rep_id_non_null} "
            f"(expected 0; column should be fresh from schema/055)"
        )
    # Pre-mappable must match expected UPDATE count within slack.
    delta = abs(stats.pre_mappable - EXPECTED_UPDATES)
    if delta > GUARD_UPDATE_SLACK:
        errors.append(
            f"pre_mappable={stats.pre_mappable} deviates from EXPECTED_UPDATES={EXPECTED_UPDATES} "
            f"by {delta} (guard slack={GUARD_UPDATE_SLACK})"
        )
    # Internal consistency: pre_candidate_null = pre_mappable + pre_gap + pre_no_rep_id
    reconstructed = stats.pre_mappable + stats.pre_gap + stats.pre_no_rep_id
    if reconstructed != stats.pre_candidate_null:
        errors.append(
            f"pre_candidate_null={stats.pre_candidate_null} != "
            f"pre_mappable+pre_gap+pre_no_rep_id={reconstructed} "
            f"(internal inconsistency — investigate before mutating)"
        )
    return (not errors), errors


def guard_post_mutation(stats: RunStats) -> tuple[bool, list[str]]:
    errors: list[str] = []
    # UPDATE count must equal pre_mappable exactly (fill-NULL-only → no missed matches).
    if stats.rows_updated != stats.pre_mappable:
        errors.append(
            f"rows_updated={stats.rows_updated} != pre_mappable={stats.pre_mappable} "
            f"(UPDATE missed rows or double-counted)"
        )
    # Post non-NULL count must equal rows_updated (no pre-existing non-NULL, guarded pre-mutation).
    if stats.post_canonical_rep_id_non_null != stats.rows_updated:
        errors.append(
            f"post_canonical_rep_id_non_null={stats.post_canonical_rep_id_non_null} != "
            f"rows_updated={stats.rows_updated}"
        )
    # Post-NULL residual = pre_gap + pre_no_rep_id (identity check).
    expected_null_residual = stats.pre_gap + stats.pre_no_rep_id
    if stats.post_canonical_rep_id_null != expected_null_residual:
        errors.append(
            f"post_canonical_rep_id_null={stats.post_canonical_rep_id_null} != "
            f"pre_gap+pre_no_rep_id={expected_null_residual}"
        )
    return (not errors), errors


def main() -> int:
    logging.basicConfig(
        level=os.environ.get("LOG_LEVEL", "INFO"),
        format="%(asctime)s %(name)s %(levelname)s %(message)s",
    )
    args = parse_args()

    db_url = os.environ.get("DATABASE_URL")
    if not db_url:
        logger.error("DATABASE_URL env var required")
        return 3

    conn = psycopg2.connect(db_url)
    conn.autocommit = False
    try:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            stats = RunStats()

            capture_pre_stats(cur, stats)
            logger.info("=== PRE-MUTATION STATE ===")
            for line in stats.summary_lines()[:6]:
                logger.info(line)

            ok, errors = guard_pre_mutation(stats)
            if not ok:
                logger.error("Pre-mutation guard violation — aborting before UPDATE:")
                for e in errors:
                    logger.error("  %s", e)
                conn.rollback()
                return 1

            logger.info("=== EXECUTING UPDATE ===")
            stats.rows_updated = execute_backfill(cur)
            logger.info("UPDATE affected %d rows", stats.rows_updated)

            capture_post_stats(cur, stats)
            logger.info("=== POST-MUTATION STATE ===")
            for line in stats.summary_lines():
                logger.info(line)

            ok, errors = guard_post_mutation(stats)
            if not ok:
                logger.error("Post-mutation guard violation — rolling back:")
                for e in errors:
                    logger.error("  %s", e)
                conn.rollback()
                return 1

            if args.dry_run:
                logger.info("DRY-RUN: rolling back (no changes persisted)")
                conn.rollback()
            else:
                logger.info(
                    "COMMIT: persisting %d canonical_rep_id updates",
                    stats.rows_updated,
                )
                conn.commit()
    except psycopg2.Error as exc:
        conn.rollback()
        logger.exception("DB error — transaction rolled back: %s", exc)
        return 2

    return 0


if __name__ == "__main__":
    sys.exit(main())
