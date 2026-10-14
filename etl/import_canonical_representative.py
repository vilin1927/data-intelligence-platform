"""
Phase G — canonical_representative importer.

Tickets: BUG-100 (importer + populate + delta report), BUG-108 AC3 (HARD-source
import from Jan 2026 accdb), BUG-124 AC3 (30 DWS / 72 all-channel cross-link).

Purpose
-------
Populate the freshly-created canonical_representative table (schema/053) with
74 union rows from the Jan 2026 accdb:
    - 30 DWS reps (accdb Representative table, TerritoryGroup='DWS')
    - 72 all-channel reps (accdb Customers.Rep UPPER-distinct)
    - 28 overlap → 74 unique
Per-source flags (is_active_dws, is_active_allchannel) indicate provenance.
framing; Vladimir directive 2026-04-25.

Territory FK resolution: case-insensitive UPPER(TRIM(territory_hint)) =
UPPER(TRIM(canonical_territory.territory_name)). 4 rows expected to land with
  - CHARGE THROUGH (pseudo-rep, no real territory)
  - REP C (QLD CBD not in canonical — data drift)
  - CUSTOMER 08 (Tasmania not in canonical — new hire)
  - REP H (no territory hint)

Input
-----
        Columns: rep_name, full_rep_display, short_rep, territory_hint,
                 territory_source, is_active_dws, is_active_allchannel
        74 rows, pre-built by scripts/build_canonical_rep_import_csv.py.

Usage
-----
    DATABASE_URL=postgresql://... \\
    python -m etl.import_canonical_representative \\
        --dry-run          # default TRUE; pass --commit to mutate.

Exit codes
----------
    0  success (dry-run or committed)
    1  guard violation (aborted before mutating)
    2  DB error (transaction rolled back)
    3  input error (missing CSV, bad args)
"""
from __future__ import annotations

import argparse
import csv
import logging
import os
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

import psycopg2
import psycopg2.extras

logger = logging.getLogger("moppity.etl.import_canonical_representative")

EXPECTED_ROWS = 74
EXPECTED_DWS = 30
EXPECTED_ALLCHANNEL = 72
GUARD_MAX_NULL_TERRITORY = 6  # 4 observed + 2 slack for drift


@dataclass
class RunStats:
    rows_read: int = 0
    rows_inserted: int = 0
    territory_matched: int = 0
    territory_null_empty_hint: int = 0
    territory_null_unmatched: int = 0
    dws_flagged: int = 0
    allchannel_flagged: int = 0
    both_flagged: int = 0
    unmatched_territory_names: list[str] = field(default_factory=list)

    def summary_lines(self) -> list[str]:
        return [
            f"rows_read:                     {self.rows_read}",
            f"rows_inserted:                 {self.rows_inserted}",
            f"territory_matched:             {self.territory_matched}",
            f"territory_null_empty_hint:     {self.territory_null_empty_hint}",
            f"territory_null_unmatched:      {self.territory_null_unmatched}",
            f"is_active_dws=TRUE:            {self.dws_flagged}",
            f"is_active_allchannel=TRUE:     {self.allchannel_flagged}",
            f"both flags TRUE (overlap):     {self.both_flagged}",
            f"unmatched_territory_names:     {sorted(set(self.unmatched_territory_names))}",
        ]


def parse_args() -> argparse.Namespace:
    default_csv = (
        Path(__file__).resolve().parent.parent
        / "audit"
        / "canonical-representative-import-2026-04-25.csv"
    )
    p = argparse.ArgumentParser(description=__doc__.strip().splitlines()[0])
    p.add_argument("--import-csv", type=Path, default=default_csv)
    group = p.add_mutually_exclusive_group()
    group.add_argument(
        "--dry-run",
        dest="dry_run",
        action="store_true",
        default=True,
        help="Perform INSERTs inside transaction then ROLLBACK (default)",
    )
    group.add_argument(
        "--commit",
        dest="dry_run",
        action="store_false",
        help="COMMIT the transaction. Requires explicit opt-in.",
    )
    return p.parse_args()


def load_territory_lookup(cur) -> dict[str, int]:
    cur.execute("SELECT id, territory_name FROM canonical_territory")
    return {
        row["territory_name"].strip().upper(): row["id"]
        for row in cur.fetchall()
    }


def load_import_rows(csv_path: Path) -> list[dict]:
    if not csv_path.exists():
        raise FileNotFoundError(f"import CSV not found: {csv_path}")
    with open(csv_path, newline="") as f:
        return list(csv.DictReader(f))


def resolve_territory_id(
    hint: str,
    territory_lookup: dict[str, int],
    stats: RunStats,
) -> Optional[int]:
    h = (hint or "").strip()
    if not h:
        stats.territory_null_empty_hint += 1
        return None
    tid = territory_lookup.get(h.upper())
    if tid is None:
        stats.territory_null_unmatched += 1
        stats.unmatched_territory_names.append(h)
        return None
    stats.territory_matched += 1
    return tid


def insert_rep(cur, row: dict, territory_id: Optional[int]) -> None:
    cur.execute(
        """
        INSERT INTO canonical_representative
            (rep_name, full_rep_display, short_rep, territory_id,
             is_active_dws, is_active_allchannel)
        VALUES (%s, %s, %s, %s, %s, %s)
        """,
        (
            row["rep_name"].strip(),
            (row.get("full_rep_display") or "").strip() or None,
            (row.get("short_rep") or "").strip() or None,
            territory_id,
            (row.get("is_active_dws") or "").strip().lower() == "true",
            (row.get("is_active_allchannel") or "").strip().lower() == "true",
        ),
    )


def guard_pre_mutation(stats: RunStats) -> tuple[bool, list[str]]:
    errors: list[str] = []
    if stats.rows_read != EXPECTED_ROWS:
        errors.append(
            f"rows_read={stats.rows_read} (expected {EXPECTED_ROWS})"
        )
    if stats.dws_flagged != EXPECTED_DWS:
        errors.append(
            f"dws_flagged={stats.dws_flagged} (expected {EXPECTED_DWS})"
        )
    if stats.allchannel_flagged != EXPECTED_ALLCHANNEL:
        errors.append(
            f"allchannel_flagged={stats.allchannel_flagged} "
            f"(expected {EXPECTED_ALLCHANNEL})"
        )
    null_terr = stats.territory_null_empty_hint + stats.territory_null_unmatched
    if null_terr > GUARD_MAX_NULL_TERRITORY:
        errors.append(
            f"null_territory_count={null_terr} (guard max {GUARD_MAX_NULL_TERRITORY})"
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

    try:
        rows = load_import_rows(args.import_csv)
    except FileNotFoundError as exc:
        logger.error("%s", exc)
        return 3

    conn = psycopg2.connect(db_url)
    conn.autocommit = False
    try:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            # Pre-assert table empty (re-runs must start clean).
            cur.execute("SELECT count(*) AS n FROM canonical_representative")
            pre_count = cur.fetchone()["n"]
            if pre_count != 0:
                logger.error(
                    "canonical_representative has %d rows; expected 0 at import start.",
                    pre_count,
                )
                conn.rollback()
                return 1

            territory_lookup = load_territory_lookup(cur)
            logger.info(
                "Loaded territory lookup (%d canonical territories)",
                len(territory_lookup),
            )

            stats = RunStats()
            stats.rows_read = len(rows)

            for row in rows:
                tid = resolve_territory_id(
                    row.get("territory_hint", ""), territory_lookup, stats
                )
                is_dws = (row.get("is_active_dws") or "").strip().lower() == "true"
                is_all = (row.get("is_active_allchannel") or "").strip().lower() == "true"
                if is_dws:
                    stats.dws_flagged += 1
                if is_all:
                    stats.allchannel_flagged += 1
                if is_dws and is_all:
                    stats.both_flagged += 1
                insert_rep(cur, row, tid)
                stats.rows_inserted += 1

            for line in stats.summary_lines():
                logger.info(line)

            ok, errors = guard_pre_mutation(stats)
            if not ok:
                logger.error("Guard violation — aborting:")
                for e in errors:
                    logger.error("  %s", e)
                conn.rollback()
                return 1

            if args.dry_run:
                logger.info("DRY-RUN: rolling back (no changes persisted)")
                conn.rollback()
            else:
                logger.info(
                    "COMMIT: persisting %d canonical_representative rows",
                    stats.rows_inserted,
                )
                conn.commit()
    except psycopg2.Error as exc:
        conn.rollback()
        logger.exception("DB error — transaction rolled back: %s", exc)
        return 2

    return 0


if __name__ == "__main__":
    sys.exit(main())
