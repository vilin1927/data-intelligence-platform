"""
B5 — refresh canonical_representative from accdb Representative master.

Tickets
-------
JC-054 (rep master = 31 rows) — adds the missing 31st row (SNEWB / Sara
  Newberry / Queensland Metro) that B2's import deduped because of FullRep
  collision with SNEWBE.
JC-055 (26 Access columns)   — backfills the 23 metric/Field cols added by
JC-057 (MAT per-member)      — populates SalesPerMemberMAT,
  SalesGrowthPerMemberMAT, RangesPerMember, DistrnPerMember.
JC-058 (rep:territory N:M)   — primes rep_territory_xref with one
  is_primary=true row per rep (FK to canonical_territory via the rep's
  current territory_id). Secondary coverage is added by
  etl/import_territory_overrides.py.
JC-060 (refresh from Access master) — re-derives all 23 cols on every run.
JC-066 (TerritoryGroup canonical = 10 values) — sets canonical_representative.territory_group from accdb (always 'DWS' for the 31 master reps).

Idempotent: run any number of times. UPDATE-only on existing rows; INSERT

Usage
-----
    DATABASE_URL=postgresql://... \\
    python -m etl.refresh_reps_from_access \\
        --dry-run        # default; pass --commit to mutate

Exit codes
----------
    0  success (dry-run or committed)
    1  guard violation (aborted before mutating)
    2  DB error (transaction rolled back)
    3  input error (missing CSV / bad args)
"""
from __future__ import annotations

import argparse
import csv
import logging
import os
import re
import sys
from dataclasses import dataclass, field
from decimal import Decimal, InvalidOperation
from pathlib import Path
from typing import Any, Optional

import psycopg2
import psycopg2.extras

logger = logging.getLogger("moppity.etl.refresh_reps_from_access")

EXPECTED_ACCESS_REPS = 31           # HARD source: representative-jan2026-accdb CSV
EXPECTED_DWS_AFTER = 31             # post-fix target

# Map Access CSV column → canonical_representative DB column.
COL_MAP: dict[str, str] = {
    "ShortRep":                  "short_rep",
    "FullRep":                   "full_rep_display",
    "Territory":                 "territory_hint",       # resolve via canonical_territory
    "TerritoryGroup":            "territory_group",
    "Representative Details":    "representative_details",
    "MembersGrowth":             "members_growth",
    "TYDistrn":                  "ty_distrn",
    "RangeMTD":                  "range_mtd",
    "LYDollar":                  "ly_dollar",
    "TYDollar":                  "ty_dollar",
    "YDollarPer":                "y_dollar_per",
    "LYMTD$":                    "ly_mtd_dollar",
    "TYMTD$":                    "ty_mtd_dollar",
    "MTDPer":                    "mtd_per",
    "LYMQTDollar":               "ly_mqt_dollar",
    "TYMQTDollar":               "ty_mqt_dollar",
    "MQTDollarPer":              "mqt_dollar_per",
    "RangesPerMember":           "ranges_per_member",
    "DistrnPerMember":           "distrn_per_member",
    "SalesPerMemberMAT":         "sales_per_member_mat",
    "SalesGrowthPerMemberMAT":   "sales_growth_per_member_mat",
    "Field1":                    "field1",
    "Field2":                    "field2",
    "Field3":                    "field3",
    "Field4":                    "field4",
    "Field5":                    "field5",
}

NUMERIC_COLS = {
    "members_growth", "ty_distrn", "range_mtd", "ly_dollar", "ty_dollar",
    "y_dollar_per", "ly_mtd_dollar", "ty_mtd_dollar", "mtd_per",
    "ly_mqt_dollar", "ty_mqt_dollar", "mqt_dollar_per",
    "ranges_per_member", "distrn_per_member",
    "sales_per_member_mat", "sales_growth_per_member_mat",
}


@dataclass
class RunStats:
    rows_read: int = 0
    rows_inserted: int = 0
    rows_updated: int = 0
    rows_unchanged: int = 0
    xref_inserted: int = 0
    xref_skipped: int = 0
    territory_resolved: int = 0
    territory_unresolved: int = 0
    unresolved_territories: list[str] = field(default_factory=list)
    short_reps_inserted: list[str] = field(default_factory=list)


def parse_args() -> argparse.Namespace:
    default_csv = (
        Path(__file__).resolve().parent.parent
        / "audit"
        / "representative-jan2026-accdb-2026-04-25.csv"
    )
    p = argparse.ArgumentParser(description=__doc__.strip().splitlines()[0])
    p.add_argument("--import-csv", type=Path, default=default_csv)
    g = p.add_mutually_exclusive_group()
    g.add_argument("--dry-run", dest="dry_run", action="store_true", default=True,
                   help="ROLLBACK at end of run (default)")
    g.add_argument("--commit", dest="dry_run", action="store_false",
                   help="COMMIT changes (explicit opt-in)")
    return p.parse_args()


def parse_numeric(v: Any) -> Optional[Decimal]:
    if v is None:
        return None
    s = str(v).strip()
    if not s:
        return None
    # Access exports occasionally use "0.0000" plus stray quotes.
    s = s.replace(",", "")
    try:
        return Decimal(s)
    except (InvalidOperation, ValueError):
        return None


def normalize_value(db_col: str, raw: Any) -> Any:
    if raw is None:
        return None
    s = str(raw).strip()
    if s == "":
        return None
    if db_col in NUMERIC_COLS:
        return parse_numeric(s)
    return s


def load_territory_lookup(cur) -> dict[str, int]:
    cur.execute("SELECT id, territory_name FROM canonical_territory")
    return {row["territory_name"].strip().upper(): row["id"] for row in cur.fetchall()}


def load_csv(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        raise FileNotFoundError(f"import CSV not found: {path}")
    with open(path, newline="") as f:
        reader = csv.DictReader(f)
        return list(reader)


def row_to_db_payload(
    row: dict[str, Any],
    territory_lookup: dict[str, int],
    stats: RunStats,
) -> dict[str, Any]:
    """Convert one Access CSV row into a dict of canonical_representative columns."""
    payload: dict[str, Any] = {}

    short_rep = (row.get("ShortRep") or "").strip()
    full_rep = (row.get("FullRep") or "").strip()
    if not short_rep or not full_rep:
        raise ValueError(f"row missing ShortRep/FullRep: {row}")
    payload["short_rep"] = short_rep
    payload["full_rep_display"] = full_rep
    # canonical_representative.rep_name is the UPPER-collapsed key (legacy).
    payload["rep_name"] = full_rep.upper()

    territory_hint = (row.get("Territory") or "").strip()
    if territory_hint:
        tid = territory_lookup.get(territory_hint.upper())
        if tid is not None:
            payload["territory_id"] = tid
            stats.territory_resolved += 1
        else:
            payload["territory_id"] = None
            stats.territory_unresolved += 1
            stats.unresolved_territories.append(territory_hint)
    else:
        payload["territory_id"] = None

    # Map remaining Access cols → canonical cols.
    for src, db_col in COL_MAP.items():
        if db_col in {"short_rep", "full_rep_display", "territory_hint"}:
            continue
        payload[db_col] = normalize_value(db_col, row.get(src))

    # 31 master reps are all DWS-active per HARD source.
    payload["is_active_dws"] = True
    return payload


def upsert_rep(cur, payload: dict[str, Any], stats: RunStats) -> str:
    """Returns 'inserted' | 'updated' | 'unchanged'."""
    cur.execute(
        """
        SELECT id, full_rep_display, territory_id, members_growth, ty_distrn,
               range_mtd, ly_dollar, ty_dollar, y_dollar_per, ly_mtd_dollar,
               ty_mtd_dollar, mtd_per, ly_mqt_dollar, ty_mqt_dollar,
               mqt_dollar_per, ranges_per_member, distrn_per_member,
               sales_per_member_mat, sales_growth_per_member_mat,
               territory_group, representative_details,
               field1, field2, field3, field4, field5,
               is_active_dws
        FROM canonical_representative
        WHERE short_rep = %s AND full_rep_display = %s
        """,
        (payload["short_rep"], payload["full_rep_display"]),
    )
    existing = cur.fetchone()

    if existing is None:
        cur.execute(
            """
            INSERT INTO canonical_representative (
                rep_name, full_rep_display, short_rep, territory_id,
                is_active_dws, is_active_allchannel,
                territory_group, representative_details,
                members_growth, ty_distrn, range_mtd, ly_dollar, ty_dollar,
                y_dollar_per, ly_mtd_dollar, ty_mtd_dollar, mtd_per,
                ly_mqt_dollar, ty_mqt_dollar, mqt_dollar_per,
                ranges_per_member, distrn_per_member,
                sales_per_member_mat, sales_growth_per_member_mat,
                field1, field2, field3, field4, field5
            )
            VALUES (
                %(rep_name)s, %(full_rep_display)s, %(short_rep)s, %(territory_id)s,
                %(is_active_dws)s, FALSE,
                %(territory_group)s, %(representative_details)s,
                %(members_growth)s, %(ty_distrn)s, %(range_mtd)s, %(ly_dollar)s, %(ty_dollar)s,
                %(y_dollar_per)s, %(ly_mtd_dollar)s, %(ty_mtd_dollar)s, %(mtd_per)s,
                %(ly_mqt_dollar)s, %(ty_mqt_dollar)s, %(mqt_dollar_per)s,
                %(ranges_per_member)s, %(distrn_per_member)s,
                %(sales_per_member_mat)s, %(sales_growth_per_member_mat)s,
                %(field1)s, %(field2)s, %(field3)s, %(field4)s, %(field5)s
            )
            """,
            payload,
        )
        stats.short_reps_inserted.append(payload["short_rep"])
        return "inserted"

    # Build UPDATE only for changed cols (idempotency: avoid no-op writes).
    update_cols: dict[str, Any] = {}
    for col in (
        "territory_id", "territory_group", "representative_details",
        "members_growth", "ty_distrn", "range_mtd", "ly_dollar", "ty_dollar",
        "y_dollar_per", "ly_mtd_dollar", "ty_mtd_dollar", "mtd_per",
        "ly_mqt_dollar", "ty_mqt_dollar", "mqt_dollar_per",
        "ranges_per_member", "distrn_per_member",
        "sales_per_member_mat", "sales_growth_per_member_mat",
        "field1", "field2", "field3", "field4", "field5",
    ):
        new_val = payload.get(col)
        old_val = existing[col]
        if new_val != old_val:
            update_cols[col] = new_val

    # Always ensure is_active_dws=true for the 31 Access master reps.
    if not existing["is_active_dws"]:
        update_cols["is_active_dws"] = True

    if not update_cols:
        return "unchanged"

    set_clauses = ", ".join(f"{col} = %({col})s" for col in update_cols)
    update_cols["_id"] = existing["id"]
    cur.execute(
        f"UPDATE canonical_representative SET {set_clauses}, updated_at = now() WHERE id = %(_id)s",
        update_cols,
    )
    return "updated"


def upsert_xref(cur, stats: RunStats) -> None:
    """Insert primary rep_territory_xref rows from canonical_representative.territory_id."""
    cur.execute(
        """
        SELECT id AS rep_id, territory_id
        FROM canonical_representative
        WHERE territory_id IS NOT NULL
          AND is_active_dws = TRUE
        """
    )
    rows = cur.fetchall()
    for r in rows:
        cur.execute(
            """
            INSERT INTO rep_territory_xref (rep_id, territory_id, is_primary, source)
            VALUES (%s, %s, TRUE, 'representative_table')
            ON CONFLICT (rep_id, territory_id) DO UPDATE
                SET is_primary = TRUE,
                    source = 'representative_table'
            """,
            (r["rep_id"], r["territory_id"]),
        )
        if cur.rowcount == 1:
            stats.xref_inserted += 1
        else:
            stats.xref_skipped += 1


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
        rows = load_csv(args.import_csv)
    except FileNotFoundError as exc:
        logger.error("%s", exc)
        return 3

    stats = RunStats()
    stats.rows_read = len(rows)
    if stats.rows_read != EXPECTED_ACCESS_REPS:
        logger.error(
            "rows_read=%d but expected %d from accdb (HARD source CSV row count drift?)",
            stats.rows_read, EXPECTED_ACCESS_REPS,
        )
        return 1

    conn = psycopg2.connect(db_url)
    conn.autocommit = False
    try:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            territory_lookup = load_territory_lookup(cur)
            logger.info("Loaded %d canonical_territory rows for FK resolution", len(territory_lookup))

            for raw in rows:
                payload = row_to_db_payload(raw, territory_lookup, stats)
                outcome = upsert_rep(cur, payload, stats)
                if outcome == "inserted":
                    stats.rows_inserted += 1
                elif outcome == "updated":
                    stats.rows_updated += 1
                else:
                    stats.rows_unchanged += 1

            # Post-load row-cap assertion (matches schema/085 trigger).
            cur.execute(
                "SELECT count(*) AS n FROM canonical_representative WHERE is_active_dws = TRUE"
            )
            dws_count = cur.fetchone()["n"]
            if dws_count != EXPECTED_DWS_AFTER:
                logger.error(
                    "post-update is_active_dws count=%d (expected %d) — aborting",
                    dws_count, EXPECTED_DWS_AFTER,
                )
                conn.rollback()
                return 1

            upsert_xref(cur, stats)

            for line in [
                f"rows_read:                 {stats.rows_read}",
                f"rows_inserted:             {stats.rows_inserted}",
                f"rows_updated:              {stats.rows_updated}",
                f"rows_unchanged:            {stats.rows_unchanged}",
                f"xref_inserted:             {stats.xref_inserted}",
                f"xref_skipped (existing):   {stats.xref_skipped}",
                f"territory_resolved:        {stats.territory_resolved}",
                f"territory_unresolved:      {stats.territory_unresolved}",
                f"unresolved_territories:    {sorted(set(stats.unresolved_territories))}",
                f"new_short_reps:            {stats.short_reps_inserted}",
                f"is_active_dws (final):     {dws_count}",
            ]:
                logger.info(line)

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
