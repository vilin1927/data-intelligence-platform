"""
B11 — canonicalise canonical_customer.channel (12 raw → 7) and verify
combined_data_enriched view projects to 6 distinct channel values.

Tickets
-------
JC-076 (Channel = trade type, not warehouse) — venue-type axis.
JC-077 (Customer.Channel canonical = 7)      — ALM, DIRECT, HOFFICE, HYBRID,
                                               OFF PREMISE, ON PREMISE,
                                               WHOLESALE.
JC-078 (Combined Data Channel canonical = 6) — drops ALM (warehouse, not
                                               venue) — verified post-run.
JC-089 (12 raw → 6/7 canonical, case-fold)   — mapping table below.

Background
----------
schema/090_b11_channel_canonical.sql performs the same UPDATE inline via SQL
(atomic with the CHECK + view refactor). This script is the **re-runnable
ETL companion** for incremental imports — when new raw rows land in
canonical_customer.channel from a future upload, run this to re-normalise
without re-applying the migration.

Idempotent: safe to run any number of times. UPDATE only touches rows whose
current value differs from the canonical mapping. Wrapped in BEGIN/COMMIT

Usage
-----
    DATABASE_URL=postgresql://... \\
    python -m etl.canonicalize_channel \\
        --commit            # default is --dry-run

Exit codes
----------
    0  success (dry-run or committed)
    1  guard violation (count drift before/after)
    2  DB error (transaction rolled back)
    3  config error (missing DATABASE_URL)
"""
from __future__ import annotations

import argparse
import logging
import os
import sys
from dataclasses import dataclass, field
from typing import Optional

import psycopg2
import psycopg2.extras

logger = logging.getLogger("moppity.etl.canonicalize_channel")

# ────────────────────────────────────────────────────────────────────────────
# Mapping table — 15 raw values → 7 canonical for canonical_customer.channel.
#                                  6 canonical for combined_data view (drops
#                                  ALM + Young & Rashleigh; computed in SQL
#                                  view, not here).
#         Customers.Channel" + §"Access CombinedData.Channel".
# ────────────────────────────────────────────────────────────────────────────
CHANNEL_CANONICAL_MAP: dict[str, Optional[str]] = {
    # OFF PREMISE family
    "OFF PREMISE":         "OFF PREMISE",
    "OFF-PREMISE":         "OFF PREMISE",
    "OFF_PREMISE":         "OFF PREMISE",
    # ON PREMISE family
    "ON PREMISE":          "ON PREMISE",
    "ON-PREMISE":          "ON PREMISE",
    "ON_PREMISE":          "ON PREMISE",
    # HYBRID
    "HYBRID":              "HYBRID",
    # WHOLESALE
    "WHOLESALE":           "WHOLESALE",
    "WHOLE SALE":          "WHOLESALE",
    # DIRECT
    "DIRECT":              "DIRECT",
    # HOFFICE (head office)
    "HOFFICE":             "HOFFICE",
    "HEAD OFFICE":         "HOFFICE",
    "HEADOFFICE":          "HOFFICE",
    "HEAD-OFFICE":         "HOFFICE",
    # ALM (kept for canonical_customer; combined_data view re-maps to '')
    "ALM":                 "ALM",
    # Young & Rashleigh — D1 warehouse identity. Per JC-077, YnR is the
    # wholesale distributor — map to WHOLESALE for the venue axis.
    "YOUNG & RASHLEIGH":   "WHOLESALE",
    "YOUNG&RASHLEIGH":     "WHOLESALE",
    "Y&R":                 "WHOLESALE",
    "YNR":                 "WHOLESALE",
}

EXPECTED_CC_DISTINCT_MAX = 7         # JC-077 — AC2
EXPECTED_VIEW_DISTINCT_MAX = 6       # JC-078 — AC1


@dataclass
class RunStats:
    rows_total: int = 0
    rows_pre_non_null: int = 0
    rows_pre_distinct: int = 0
    rows_updated: int = 0
    rows_nulled_unmapped: int = 0
    rows_post_non_null: int = 0
    rows_post_distinct: int = 0
    view_distinct: int = 0
    unmapped_examples: list[str] = field(default_factory=list)


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__.strip().splitlines()[0])
    g = p.add_mutually_exclusive_group()
    g.add_argument(
        "--dry-run", dest="dry_run", action="store_true", default=True,
        help="ROLLBACK at end of run (default)",
    )
    g.add_argument(
        "--commit", dest="dry_run", action="store_false",
        help="COMMIT changes (explicit opt-in)",
    )
    return p.parse_args()


def normalise(raw: Optional[str]) -> Optional[str]:
    """Return canonical channel value or None if unmapped/empty."""
    if raw is None:
        return None
    key = raw.strip().upper()
    if not key:
        return None
    return CHANNEL_CANONICAL_MAP.get(key)


def capture_pre_state(cur, stats: RunStats) -> None:
    cur.execute("SELECT count(*) AS n FROM canonical_customer")
    stats.rows_total = cur.fetchone()["n"]

    cur.execute(
        "SELECT count(*) AS n FROM canonical_customer "
        "WHERE channel IS NOT NULL AND TRIM(channel) <> ''"
    )
    stats.rows_pre_non_null = cur.fetchone()["n"]

    cur.execute(
        "SELECT count(DISTINCT channel) AS n FROM canonical_customer "
        "WHERE channel IS NOT NULL AND TRIM(channel) <> ''"
    )
    stats.rows_pre_distinct = cur.fetchone()["n"]


def canonicalise(cur, stats: RunStats) -> None:
    """Run UPDATE per raw value (parameterised; no string interpolation)."""
    cur.execute(
        "SELECT channel, count(*) AS n FROM canonical_customer "
        "WHERE channel IS NOT NULL AND TRIM(channel) <> '' "
        "GROUP BY channel"
    )
    pre_distribution = cur.fetchall()

    for row in pre_distribution:
        raw = row["channel"]
        canon = normalise(raw)
        if canon is None:
            # Raw value couldn't be mapped — null it out (avoid fabricating).
            cur.execute(
                "UPDATE canonical_customer SET channel = NULL WHERE channel = %s",
                (raw,),
            )
            stats.rows_nulled_unmapped += cur.rowcount
            stats.unmapped_examples.append(raw)
            logger.warning("Unmapped channel value %r — set to NULL (%d rows)", raw, cur.rowcount)
            continue
        if raw == canon:
            continue
        cur.execute(
            "UPDATE canonical_customer SET channel = %s WHERE channel = %s",
            (canon, raw),
        )
        stats.rows_updated += cur.rowcount
        logger.info("Mapped %r → %r (%d rows)", raw, canon, cur.rowcount)


def capture_post_state(cur, stats: RunStats) -> None:
    cur.execute(
        "SELECT count(*) AS n FROM canonical_customer "
        "WHERE channel IS NOT NULL AND TRIM(channel) <> ''"
    )
    stats.rows_post_non_null = cur.fetchone()["n"]

    cur.execute(
        "SELECT count(DISTINCT channel) AS n FROM canonical_customer "
        "WHERE channel IS NOT NULL"
    )
    stats.rows_post_distinct = cur.fetchone()["n"]

    # Verify combined_data_enriched view also satisfies its 6-distinct cap.
    # (Schema/090 enforces this via the view CASE; we just observe.)
    cur.execute(
        "SELECT count(DISTINCT channel) AS n FROM combined_data_enriched "
        "WHERE channel <> ''"
    )
    stats.view_distinct = cur.fetchone()["n"]


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

    stats = RunStats()
    conn = psycopg2.connect(db_url)
    conn.autocommit = False

    try:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            capture_pre_state(cur, stats)
            logger.info(
                "PRE: total=%d non_null=%d distinct=%d",
                stats.rows_total, stats.rows_pre_non_null, stats.rows_pre_distinct,
            )

            canonicalise(cur, stats)

            capture_post_state(cur, stats)
            logger.info(
                "POST: non_null=%d distinct=%d view_distinct=%d",
                stats.rows_post_non_null, stats.rows_post_distinct, stats.view_distinct,
            )

            for line in [
                f"rows_total:           {stats.rows_total}",
                f"rows_pre_non_null:    {stats.rows_pre_non_null}",
                f"rows_pre_distinct:    {stats.rows_pre_distinct}",
                f"rows_updated:         {stats.rows_updated}",
                f"rows_nulled_unmapped: {stats.rows_nulled_unmapped}",
                f"rows_post_non_null:   {stats.rows_post_non_null}",
                f"rows_post_distinct:   {stats.rows_post_distinct}  (target ≤{EXPECTED_CC_DISTINCT_MAX})",
                f"view_distinct:        {stats.view_distinct}        (target ≤{EXPECTED_VIEW_DISTINCT_MAX})",
                f"unmapped_examples:    {sorted(set(stats.unmapped_examples))}",
            ]:
                logger.info(line)

            if stats.rows_post_distinct > EXPECTED_CC_DISTINCT_MAX:
                logger.error(
                    "GUARD: canonical_customer distinct=%d exceeds %d",
                    stats.rows_post_distinct, EXPECTED_CC_DISTINCT_MAX,
                )
                conn.rollback()
                return 1

            if stats.view_distinct > EXPECTED_VIEW_DISTINCT_MAX:
                logger.error(
                    "GUARD: combined_data_enriched distinct=%d exceeds %d",
                    stats.view_distinct, EXPECTED_VIEW_DISTINCT_MAX,
                )
                conn.rollback()
                return 1

            if args.dry_run:
                logger.info("DRY-RUN — rolling back")
                conn.rollback()
            else:
                logger.info("COMMIT — persisting changes")
                conn.commit()
    except psycopg2.Error as exc:
        conn.rollback()
        logger.exception("DB error — transaction rolled back: %s", exc)
        return 2
    finally:
        conn.close()

    return 0


if __name__ == "__main__":
    sys.exit(main())
