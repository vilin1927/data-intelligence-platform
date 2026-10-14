"""
B7b — import master_cogs from Access tbl_Master_COGS (636 rows × 4 cols).

Tickets
-------
JC-202/JC-203 (replicate Access tbl_Master_COGS) — populate Postgres master_cogs
  from a CSV exported via mdb-export. Expected row count = 636
JC-208 (per-FY COGS) — financial_year is "FY_YYYY" string (AU FY Jul-Jun)
  preserved verbatim from Access (extract-accdb-0028).

Idempotent: TRUNCATE then INSERT inside a single BEGIN/COMMIT so a partial run

Usage
-----
    # 1. Export the table from Access:

    # 2. Dry-run (validates row count and column names; no DB writes):
    DATABASE_URL=postgresql://... \\
    python -m etl.import_master_cogs_from_access \\
        --dry-run

    # 3. Commit:
    DATABASE_URL=postgresql://... \\
    python -m etl.import_master_cogs_from_access \\
        --commit

Exit codes
----------
    0  success (dry-run or committed)
    1  guard violation (row count mismatch / bad columns) — aborted
    2  DB error (transaction rolled back)
    3  input error (missing CSV / bad args)
"""
from __future__ import annotations

import argparse
import csv
import logging
import os
import sys
from decimal import Decimal, InvalidOperation
from pathlib import Path
from typing import Iterable

EXPECTED_ROW_COUNT = 636
EXPECTED_COLUMNS = ("ID", "SKU", "FinancialYear", "COGS_Value")

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
log = logging.getLogger("import_master_cogs")


def _parse_args(argv: list[str]) -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--import-csv", required=True, help="Path to mdb-export CSV of tbl_Master_COGS")
    grp = p.add_mutually_exclusive_group()
    grp.add_argument("--dry-run", action="store_true", help="Default. Validate only, no DB writes.")
    grp.add_argument("--commit", action="store_true", help="Apply to database (TRUNCATE + INSERT in one txn).")
    p.add_argument("--expect-rows", type=int, default=EXPECTED_ROW_COUNT,
                   help=f"Override expected row count (default {EXPECTED_ROW_COUNT}).")
    return p.parse_args(argv)


def _read_rows(path: Path) -> list[dict[str, str]]:
    if not path.exists():
        log.error("CSV not found: %s", path)
        sys.exit(3)
    with path.open(newline="", encoding="utf-8") as fh:
        reader = csv.DictReader(fh)
        if reader.fieldnames is None or tuple(reader.fieldnames) != EXPECTED_COLUMNS:
            log.error(
                "Column mismatch. Expected %s, got %s",
                EXPECTED_COLUMNS,
                tuple(reader.fieldnames or ()),
            )
            sys.exit(1)
        return list(reader)


def _validate(rows: list[dict[str, str]], expected: int) -> list[tuple[int, str, str, Decimal]]:
    if len(rows) != expected:
        log.error("Row count mismatch: got %d, expected %d (HARD source: extract-accdb-0026).", len(rows), expected)
        sys.exit(1)

    cleaned: list[tuple[int, str, str, Decimal]] = []
    for i, row in enumerate(rows, start=2):  # row 1 = header
        try:
            id_ = int(row["ID"])
        except (TypeError, ValueError):
            log.error("Row %d: bad ID %r", i, row.get("ID"))
            sys.exit(1)
        sku = (row["SKU"] or "").strip()
        fy = (row["FinancialYear"] or "").strip()
        if not sku or not fy:
            log.error("Row %d (id=%s): empty SKU or FinancialYear", i, id_)
            sys.exit(1)
        try:
            cogs = Decimal(row["COGS_Value"])
        except (InvalidOperation, TypeError) as e:
            log.error("Row %d (id=%s): bad COGS_Value %r — %s", i, id_, row.get("COGS_Value"), e)
            sys.exit(1)
        cleaned.append((id_, sku, fy, cogs))

    # ID is the PK; (sku, financial_year) intentionally NOT unique because
    # Access has 6 duplicate pairs (Atrius Shiraz × 6 FYs, same cogs_value).
    seen_ids: set[int] = set()
    for id_, sku, fy, _ in cleaned:
        if id_ in seen_ids:
            log.error("Duplicate ID %d (PK violation in source).", id_)
            sys.exit(1)
        seen_ids.add(id_)

    return cleaned


def _apply(rows: Iterable[tuple[int, str, str, Decimal]]) -> None:
    try:
        import psycopg2
        from psycopg2.extras import execute_batch
    except ImportError:
        log.error("psycopg2 not installed. `pip install -r requirements-dev.txt` first.")
        sys.exit(2)

    dsn = os.environ.get("DATABASE_URL")
    if not dsn:
        log.error("DATABASE_URL env var not set.")
        sys.exit(3)

    conn = psycopg2.connect(dsn)
    try:
        conn.autocommit = False
        with conn.cursor() as cur:
            cur.execute("BEGIN;")
            cur.execute("TRUNCATE TABLE master_cogs RESTART IDENTITY;")
            execute_batch(
                cur,
                """
                INSERT INTO master_cogs (id, sku, financial_year, cogs_value)
                VALUES (%s, %s, %s, %s);
                """,
                rows,
                page_size=200,
            )
            cur.execute("SELECT count(*) FROM master_cogs;")
            (n,) = cur.fetchone()
            if n != EXPECTED_ROW_COUNT:
                log.error("Post-insert row count = %d, expected %d. Rolling back.", n, EXPECTED_ROW_COUNT)
                conn.rollback()
                sys.exit(1)
            conn.commit()
            log.info("Committed %d rows to master_cogs.", n)
    except Exception:
        conn.rollback()
        log.exception("DB error — transaction rolled back.")
        sys.exit(2)
    finally:
        conn.close()


def main(argv: list[str] | None = None) -> int:
    args = _parse_args(argv if argv is not None else sys.argv[1:])
    csv_path = Path(args.import_csv)
    rows_raw = _read_rows(csv_path)
    cleaned = _validate(rows_raw, args.expect_rows)
    log.info(
        "Validated %d rows from %s. Distinct SKUs=%d, distinct FYs=%d.",
        len(cleaned),
        csv_path,
        len({r[1] for r in cleaned}),
        len({r[2] for r in cleaned}),
    )

    if args.commit:
        _apply(cleaned)
    else:
        log.info("Dry-run complete. Pass --commit to apply.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
