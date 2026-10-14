"""
B9 JC-266 + JC-280 — DWS inventory bottle → case unit converter.

DWS reports inventory in BOTTLES (UnitsInStock = bottle count).
Vinsight (canonical) reports in CASES.
This ETL ingests a DWS stock-on-hand snapshot and writes cases-units rows
into inventory_stocks_on_hand with units_in_stock_uom='cases'.

JC-280 timing rule: DWS consignment stock leaves Moppity warehouse BEFORE
revenue is recorded. So a DWS-located row in inventory_stocks_on_hand
represents Moppity-owned stock physically held at DWS — included in
Moppity inventory until DWS reports sell-through (consumed via
sales_transaction with channel='DWS').

JC-262 enforcement: ALM is NEVER inserted here. ALM warehouses are not
part of Moppity inventory (ALM takes ownership on purchase).

Conversion rule:
    units_per_case lookup priority:
        1. canonical_sku.units_per_case where canonical_sku links to the
           DWS stock_item_code via sku_code_map (source_system='dws').
        2. SKU-code regex hint: codes containing '9LTR' / '6PK' → 6;
           otherwise default 12.
    cases = bottles / units_per_case  (rounded to 3 decimals)

Usage:
    DATABASE_URL=postgresql://... python -m etl.dws_inventory_bottles_to_cases \\
        path/to/dws_stock_on_hand.csv  [--snapshot-date 2026-04-27]

CSV columns expected (case-insensitive, common DWS headings):
    StockItemCode | Description | Bottles  (or UnitsInStock) | LocationCode (optional)
"""

import argparse
import csv
import datetime
import logging
import os
import sys
import re
from decimal import Decimal, InvalidOperation

import psycopg2

from etl.logger import log_etl_run

logger = logging.getLogger("moppity.etl.dws_inventory_bottles_to_cases")


DEFAULT_BOTTLES_PER_CASE = Decimal("12")
DWS_LOCATION_PREFIX = "DWS-"
SOURCE_SYSTEM = "dws"


def _normalise_header(h: str) -> str:
    return re.sub(r"[^a-z0-9]", "", (h or "").strip().lower())


_HEADER_MAP = {
    "stockitemcode":   "stock_item_code",
    "stockcode":       "stock_item_code",
    "skucode":         "stock_item_code",
    "code":            "stock_item_code",
    "description":     "description",
    "productname":     "description",
    "wine":            "description",
    "bottles":         "bottles",
    "unitsinstock":    "bottles",
    "qty":             "bottles",
    "quantity":        "bottles",
    "stockonhand":     "bottles",
    "locationcode":    "stock_location_code",
    "stocklocation":   "stock_location_code",
    "warehouse":       "stock_location_code",
}


def _parse_decimal(val):
    if val is None:
        return None
    s = str(val).strip().replace(",", "")
    if not s:
        return None
    try:
        return Decimal(s)
    except (InvalidOperation, ValueError):
        return None


def _units_per_case_for_code(cur, code: str) -> Decimal:
    """canonical_sku.units_per_case (linked via sku_code_map source=dws),
    else SKU-pattern hint, else default 12."""
    cur.execute(
        """
        SELECT cs.units_per_case
        FROM sku_code_map scm
        JOIN sku s            ON s.sku_id          = scm.sku_id
        JOIN canonical_sku cs ON cs.id             = s.canonical_sku_id
        WHERE scm.source_system = %s
          AND scm.external_code = %s
          AND cs.units_per_case IS NOT NULL
          AND cs.units_per_case > 0
        ORDER BY s.sku_id
        LIMIT 1
        """,
        (SOURCE_SYSTEM, code),
    )
    row = cur.fetchone()
    if row and row[0]:
        return Decimal(str(row[0]))

    upper = (code or "").upper()
    if "9LTR" in upper or "6PK" in upper:
        return Decimal("6")
    return DEFAULT_BOTTLES_PER_CASE


def _read_csv(path: str) -> list[dict]:
    with open(path, newline="", encoding="utf-8-sig") as fh:
        reader = csv.reader(fh)
        try:
            raw_headers = next(reader)
        except StopIteration:
            return []
        headers = [_HEADER_MAP.get(_normalise_header(h), None) for h in raw_headers]
        rows = []
        for raw_row in reader:
            row = {}
            for h, v in zip(headers, raw_row):
                if h:
                    row[h] = v
            if row.get("stock_item_code") and row.get("bottles"):
                rows.append(row)
        return rows


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("csv_path", help="DWS stock-on-hand CSV")
    parser.add_argument(
        "--snapshot-date",
        type=lambda s: datetime.date.fromisoformat(s),
        default=datetime.date.today(),
        help="ISO date for the snapshot (defaults to today).",
    )
    parser.add_argument(
        "--default-location",
        default=f"{DWS_LOCATION_PREFIX}HUB",
        help="Stock location code when CSV omits it.",
    )
    args = parser.parse_args(argv)

    database_url = os.environ.get("DATABASE_URL")
    if not database_url:
        print("ERROR: DATABASE_URL not set", file=sys.stderr)
        sys.exit(1)

    if not os.path.exists(args.csv_path):
        print(f"ERROR: file not found: {args.csv_path}", file=sys.stderr)
        sys.exit(1)

    raw_rows = _read_csv(args.csv_path)
    logger.info("Parsed %d DWS stock rows from %s", len(raw_rows), args.csv_path)

    if not raw_rows:
        print("WARNING: no rows parsed — header mapping may have failed.", file=sys.stderr)
        sys.exit(0)

    conn = psycopg2.connect(database_url)
    conn.autocommit = False  # explicit BEGIN/COMMIT per HARD-RULES

    rows_inserted = 0
    rows_skipped = 0

    try:
        with conn.cursor() as cur:
            cur.execute("""
                SELECT 1 FROM information_schema.tables
                WHERE table_schema = 'public'
                  AND table_name = 'inventory_stocks_on_hand'
            """)
            if cur.fetchone() is None:
                raise RuntimeError(
                    "inventory_stocks_on_hand missing — apply schema/095 first."
                )

            for r in raw_rows:
                code     = (r.get("stock_item_code") or "").strip()
                bottles  = _parse_decimal(r.get("bottles"))
                location = (r.get("stock_location_code") or args.default_location).strip()
                desc     = (r.get("description") or "").strip() or None

                if not code or bottles is None:
                    rows_skipped += 1
                    continue

                # JC-262 hard rule: never accept ALM rows here.
                if location.upper().startswith("ALM"):
                    logger.warning("Skipping ALM row %s (ALM excluded by JC-262)", code)
                    rows_skipped += 1
                    continue

                # Force DWS location prefix unless the file already specified one.
                if not location.upper().startswith(DWS_LOCATION_PREFIX):
                    location = f"{DWS_LOCATION_PREFIX}{location}"

                upc = _units_per_case_for_code(cur, code)
                cases = (bottles / upc).quantize(Decimal("0.001"))

                cur.execute(
                    """
                    INSERT INTO inventory_stocks_on_hand (
                        stock_item_code,
                        description,
                        product_categories,
                        asset_ledger_code,
                        stock_location_code,
                        units_in_stock,
                        units_in_stock_uom,
                        cost_per_unit,
                        status,
                        source_system,
                        snapshot_date
                    )
                    VALUES (%s, %s, NULL, NULL, %s, %s, 'cases', NULL, 'active', %s, %s)
                    ON CONFLICT (stock_item_code, stock_location_code, snapshot_date)
                    DO UPDATE SET
                        description     = EXCLUDED.description,
                        units_in_stock  = EXCLUDED.units_in_stock,
                        updated_at      = NOW()
                    """,
                    (code, desc, location, cases, SOURCE_SYSTEM, args.snapshot_date),
                )
                rows_inserted += 1

            log_etl_run(
                db_conn=conn,
                source="dws",
                endpoint="dws_inventory_bottles_to_cases",
                status="success" if rows_inserted > 0 else "partial",
                rows_processed=rows_inserted,
                rows_skipped=rows_skipped,
                error_count=0,
                error_detail=None,
            )

        conn.commit()
        logger.info(
            "DWS inventory load: inserted=%d skipped=%d snapshot_date=%s",
            rows_inserted, rows_skipped, args.snapshot_date,
        )
        return rows_inserted

    except Exception:
        conn.rollback()
        logger.exception("dws_inventory_bottles_to_cases failed; rolled back")
        raise
    finally:
        conn.close()


if __name__ == "__main__":
    logging.basicConfig(
        level=os.environ.get("LOG_LEVEL", "INFO"),
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    main()
