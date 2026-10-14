"""
B5 — import territory_override (tblNewTerritory 2295) + samples_territory (35).

Tickets
-------
JC-067 (tblNewTerritory 2,295 rows)   — replicate Access verbatim.
JC-070 (territory lookup via Rep)     — secondary rep_territory_xref entries
                                         derived from territory_override.Rep.
JC-073 (territories defaulted to states bug) — territory_override
                                         supersedes state-defaults.
JC-074 / JC-509 (Vinsight rows missing Territory; backfill)
                                       — `--backfill-combined-data` mode UPDATEs
                                         sales_transaction.territory_id where
                                         source_system='vinsight' AND territory_id IS NULL,
                                         joining via canonical_customer +
                                         territory_override + canonical_territory.
JC-075 (tblSamplesTerritory 35 rows)  — replicate Access verbatim.

Idempotent: ON CONFLICT (access_id) DO UPDATE for territory_override;
ON CONFLICT (rep_customer_name) DO UPDATE for samples_territory.

The --backfill-combined-data step is destructive (UPDATEs existing
sales_transaction rows) — defaults to dry-run; explicit --commit required
plus the AC8 verification SQL is logged so the operator can spot-check.

Usage
-----
    DATABASE_URL=postgresql://... \\
    python -m etl.import_territory_overrides \\
        --backfill-combined-data \\
        --dry-run            # default; pass --commit to mutate

Exit codes
----------
    0  success (dry-run or committed)
    1  guard violation (aborted before mutating)
    2  DB error (transaction rolled back)
    3  input error
"""
from __future__ import annotations

import argparse
import csv
import logging
import os
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Optional

import psycopg2
import psycopg2.extras

logger = logging.getLogger("moppity.etl.import_territory_overrides")

EXPECTED_NEW_TERRITORY_ROWS = 2295  # HARD source: extract-accdb-0036
EXPECTED_SAMPLES_ROWS = 35          # HARD source: extract-accdb-0057

VALID_TERRITORY_GROUPS = {
    "ACT", "DWS", "Export", "Head Office", "Majors & Wine Clubs",
    "NSW", "QLD", "SA", "VIC", "Victoria Off", "WA", "Young & Rashleigh",
}


@dataclass
class RunStats:
    nt_rows_read: int = 0
    nt_inserted: int = 0
    nt_updated: int = 0
    nt_unchanged: int = 0
    sa_rows_read: int = 0
    sa_inserted: int = 0
    sa_updated: int = 0
    sa_unchanged: int = 0
    xref_secondary_added: int = 0
    backfill_candidates: int = 0
    backfill_applied: int = 0
    backfill_unresolved: int = 0
    invalid_territory_groups: list[str] = field(default_factory=list)


def parse_args() -> argparse.Namespace:
    base = Path(__file__).resolve().parent.parent
    p = argparse.ArgumentParser(description=__doc__.strip().splitlines()[0])
    p.add_argument(
        "--new-territory-csv", type=Path,
        default=base / "audit" / "tblNewTerritory-jan2026-accdb-2026-04-27.csv",
    )
    p.add_argument(
        "--samples-csv", type=Path,
        default=base / "audit" / "tblSamplesTerritory-jan2026-accdb-2026-04-27.csv",
    )
    p.add_argument(
        "--backfill-combined-data", action="store_true", default=False,
        help="After loading territory_override, UPDATE sales_transaction.territory_id for "
             "Vinsight rows where territory_id IS NULL. AC8 of bundle B5.",
    )
    g = p.add_mutually_exclusive_group()
    g.add_argument("--dry-run", dest="dry_run", action="store_true", default=True,
                   help="ROLLBACK at end of run (default)")
    g.add_argument("--commit", dest="dry_run", action="store_false",
                   help="COMMIT changes (explicit opt-in)")
    return p.parse_args()


def safe_int(v: Any) -> Optional[int]:
    if v is None:
        return None
    s = str(v).strip()
    if not s:
        return None
    try:
        return int(s)
    except ValueError:
        return None


def safe_str(v: Any) -> Optional[str]:
    if v is None:
        return None
    s = str(v).strip()
    return s or None


def load_csv(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        raise FileNotFoundError(f"CSV not found: {path}")
    # Access mdb-export sometimes emits cp1252 / latin-1 chars (e.g. CafΘ).
    with open(path, newline="", encoding="utf-8", errors="replace") as f:
        return list(csv.DictReader(f))


# ─────────────────────────────────────────────────────────────────────────────
# territory_override loader
# ─────────────────────────────────────────────────────────────────────────────

def load_territory_overrides(cur, rows: list[dict[str, Any]], stats: RunStats) -> None:
    for row in rows:
        access_id   = safe_int(row.get("ID"))
        cust_name   = safe_str(row.get("CustomerName"))
        old_terr    = safe_str(row.get("Old Territory"))
        suburb      = safe_str(row.get("Suburb"))
        rep         = safe_str(row.get("Rep"))
        new_terr    = safe_str(row.get("New territory"))
        terr_group  = safe_str(row.get("Territory Group"))

        if not cust_name or not new_terr:
            raise ValueError(f"row missing CustomerName/New territory: {row}")

        if terr_group is not None and terr_group not in VALID_TERRITORY_GROUPS:
            stats.invalid_territory_groups.append(terr_group)
            # Don't drop the row — leave territory_group NULL so CHECK constraint passes.
            terr_group = None

        cur.execute(
            """
            INSERT INTO territory_override
                (access_id, customer_name, old_territory, suburb, rep, new_territory, territory_group)
            VALUES (%s, %s, %s, %s, %s, %s, %s)
            ON CONFLICT (access_id) DO UPDATE SET
                customer_name   = EXCLUDED.customer_name,
                old_territory   = EXCLUDED.old_territory,
                suburb          = EXCLUDED.suburb,
                rep             = EXCLUDED.rep,
                new_territory   = EXCLUDED.new_territory,
                territory_group = EXCLUDED.territory_group,
                updated_at      = now()
            RETURNING (xmax = 0) AS inserted
            """,
            (access_id, cust_name, old_terr, suburb, rep, new_terr, terr_group),
        )
        result = cur.fetchone()
        if result and result["inserted"]:
            stats.nt_inserted += 1
        else:
            stats.nt_updated += 1


# ─────────────────────────────────────────────────────────────────────────────
# samples_territory loader
# ─────────────────────────────────────────────────────────────────────────────

def load_samples_territory(cur, rows: list[dict[str, Any]], stats: RunStats) -> None:
    for row in rows:
        rep_cust    = safe_str(row.get("RepCustomerName"))
        sample_terr = safe_str(row.get("SampleTerritory"))
        terr_group  = safe_str(row.get("TerritoryGroup"))

        if not rep_cust or not sample_terr:
            raise ValueError(f"row missing RepCustomerName/SampleTerritory: {row}")

        if terr_group is not None and terr_group not in VALID_TERRITORY_GROUPS:
            stats.invalid_territory_groups.append(terr_group)
            terr_group = None

        cur.execute(
            """
            INSERT INTO samples_territory
                (rep_customer_name, sample_territory, territory_group)
            VALUES (%s, %s, %s)
            ON CONFLICT (rep_customer_name) DO UPDATE SET
                sample_territory = EXCLUDED.sample_territory,
                territory_group  = EXCLUDED.territory_group
            RETURNING (xmax = 0) AS inserted
            """,
            (rep_cust, sample_terr, terr_group),
        )
        result = cur.fetchone()
        if result and result["inserted"]:
            stats.sa_inserted += 1
        else:
            stats.sa_updated += 1


# ─────────────────────────────────────────────────────────────────────────────
# rep_territory_xref secondary coverage
# ─────────────────────────────────────────────────────────────────────────────

def add_secondary_xref(cur, stats: RunStats) -> None:
    """
    Insert secondary (is_primary=false) rep_territory_xref rows derived from
    territory_override.Rep × territory_override.new_territory pairs. Covers
    the JC-070 requirement that a rep can be looked up across multiple
    territories.
    """
    cur.execute(
        """
        INSERT INTO rep_territory_xref (rep_id, territory_id, is_primary, source)
        SELECT DISTINCT cr.id, ct.id, FALSE, 'territory_override'
        FROM territory_override tov
        JOIN canonical_representative cr
          ON UPPER(TRIM(cr.full_rep_display)) = UPPER(TRIM(tov.rep))
        JOIN canonical_territory ct
          ON UPPER(TRIM(ct.territory_name)) = UPPER(TRIM(tov.new_territory))
        ON CONFLICT (rep_id, territory_id) DO NOTHING
        """
    )
    stats.xref_secondary_added = cur.rowcount


# ─────────────────────────────────────────────────────────────────────────────
# AC8 — sales_transaction.territory_id backfill for Vinsight rows
# ─────────────────────────────────────────────────────────────────────────────

def backfill_combined_data_territory(cur, stats: RunStats) -> None:
    """
    Resolve sales_transaction.territory_id for Vinsight rows currently NULL.

    Strategy (preference order):
      1. Direct match: sales_transaction.customer_id → canonical_customer →
         territory_override.customer_name → canonical_territory.id →
         legacy territory.territory_id (via canonical_territory_id bridge).
      2. Fallback: sales_transaction.customer_id → customer.territory_id
         (existing direct attribution; covered by older ETLs but worth a
         safety net here).

    Only operates on source_system='vinsight' AND territory_id IS NULL.
    """
    # Count candidates first (safety: log size before mutation).
    cur.execute(
        """
        SELECT count(*) AS n
        FROM sales_transaction
        WHERE source_system = 'vinsight'
          AND territory_id IS NULL
        """
    )
    stats.backfill_candidates = cur.fetchone()["n"]
    logger.info("Vinsight rows with NULL territory_id: %d", stats.backfill_candidates)

    if stats.backfill_candidates == 0:
        logger.info("No backfill needed.")
        return

    # Strategy 1 — match through territory_override + canonical_territory.
    cur.execute(
        """
        WITH resolved AS (
          SELECT
            st.transaction_id,
            t.territory_id AS new_territory_id
          FROM sales_transaction st
          JOIN customer c               ON c.customer_id = st.customer_id
          JOIN canonical_customer cc    ON cc.id = c.canonical_customer_id
          JOIN territory_override tov   ON UPPER(TRIM(tov.customer_name)) = UPPER(TRIM(cc.customer_name))
          JOIN canonical_territory ctn  ON UPPER(TRIM(ctn.territory_name)) = UPPER(TRIM(tov.new_territory))
          JOIN territory t              ON t.canonical_territory_id = ctn.id
          WHERE st.source_system = 'vinsight'
            AND st.territory_id IS NULL
        )
        UPDATE sales_transaction st
        SET territory_id = r.new_territory_id
        FROM resolved r
        WHERE st.transaction_id = r.transaction_id
        """
    )
    s1 = cur.rowcount
    stats.backfill_applied += s1
    logger.info("Strategy 1 (territory_override join): %d rows updated", s1)

    # Strategy 2 — fall back to customer.territory_id (residual NULLs).
    cur.execute(
        """
        UPDATE sales_transaction st
        SET territory_id = c.territory_id
        FROM customer c
        WHERE st.customer_id = c.customer_id
          AND st.source_system = 'vinsight'
          AND st.territory_id IS NULL
          AND c.territory_id IS NOT NULL
        """
    )
    s2 = cur.rowcount
    stats.backfill_applied += s2
    logger.info("Strategy 2 (customer.territory_id fallback): %d rows updated", s2)

    # Re-check residuals.
    cur.execute(
        """
        SELECT count(*) AS n
        FROM sales_transaction
        WHERE source_system = 'vinsight'
          AND territory_id IS NULL
        """
    )
    stats.backfill_unresolved = cur.fetchone()["n"]
    logger.info("Residual unresolved Vinsight rows: %d", stats.backfill_unresolved)


# ─────────────────────────────────────────────────────────────────────────────
# main
# ─────────────────────────────────────────────────────────────────────────────

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
        nt_rows = load_csv(args.new_territory_csv)
        sa_rows = load_csv(args.samples_csv)
    except FileNotFoundError as exc:
        logger.error("%s", exc)
        return 3

    stats = RunStats()
    stats.nt_rows_read = len(nt_rows)
    stats.sa_rows_read = len(sa_rows)

    if stats.nt_rows_read != EXPECTED_NEW_TERRITORY_ROWS:
        logger.error(
            "tblNewTerritory CSV has %d rows but HARD source expects %d — aborting",
            stats.nt_rows_read, EXPECTED_NEW_TERRITORY_ROWS,
        )
        return 1
    if stats.sa_rows_read != EXPECTED_SAMPLES_ROWS:
        logger.error(
            "tblSamplesTerritory CSV has %d rows but HARD source expects %d — aborting",
            stats.sa_rows_read, EXPECTED_SAMPLES_ROWS,
        )
        return 1

    conn = psycopg2.connect(db_url)
    conn.autocommit = False
    try:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            load_territory_overrides(cur, nt_rows, stats)
            load_samples_territory(cur, sa_rows, stats)
            add_secondary_xref(cur, stats)

            if args.backfill_combined_data:
                backfill_combined_data_territory(cur, stats)
            else:
                logger.info("--backfill-combined-data NOT set; skipping AC8 sales_transaction UPDATE")

            cur.execute("SELECT count(*) AS n FROM territory_override")
            terr_total = cur.fetchone()["n"]
            cur.execute("SELECT count(*) AS n FROM samples_territory")
            samp_total = cur.fetchone()["n"]
            cur.execute(
                "SELECT count(DISTINCT territory_id) AS n FROM rep_territory_xref"
            )
            xref_distinct_terr = cur.fetchone()["n"]

            for line in [
                f"new_territory rows_read:        {stats.nt_rows_read}",
                f"new_territory inserted:         {stats.nt_inserted}",
                f"new_territory updated:          {stats.nt_updated}",
                f"samples_territory rows_read:    {stats.sa_rows_read}",
                f"samples_territory inserted:     {stats.sa_inserted}",
                f"samples_territory updated:      {stats.sa_updated}",
                f"xref_secondary_added:           {stats.xref_secondary_added}",
                f"territory_override total:       {terr_total}  (target {EXPECTED_NEW_TERRITORY_ROWS})",
                f"samples_territory total:        {samp_total}  (target {EXPECTED_SAMPLES_ROWS})",
                f"rep_territory_xref distinct territory_id: {xref_distinct_terr}  (AC4 target ≥ 30)",
                f"backfill candidates:            {stats.backfill_candidates}",
                f"backfill applied:               {stats.backfill_applied}",
                f"backfill unresolved:            {stats.backfill_unresolved}",
                f"invalid territory_groups (skipped): {sorted(set(stats.invalid_territory_groups))}",
            ]:
                logger.info(line)

            # Hard guards before commit
            if terr_total != EXPECTED_NEW_TERRITORY_ROWS:
                logger.error(
                    "post-load territory_override count=%d (expected %d)",
                    terr_total, EXPECTED_NEW_TERRITORY_ROWS,
                )
                conn.rollback()
                return 1
            if samp_total != EXPECTED_SAMPLES_ROWS:
                logger.error(
                    "post-load samples_territory count=%d (expected %d)",
                    samp_total, EXPECTED_SAMPLES_ROWS,
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
