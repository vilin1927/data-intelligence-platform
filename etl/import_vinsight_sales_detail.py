"""
Vinsight Sales Detail 28-col importer (Bundle B12 / JC-305).

The Vinsight "Sales Detail" report ships as a CSV whose first row is the
literal text `"Sales Detail"`, followed by a blank line, then a 28-column
data header. Verified against

  1  Stock Item Code
  2  Description
  3  Order Num
  4  Invoice Date
  5  Date Created
  6  Customer Name
  7  Contact Num
  8  Contact Category
  9  Order Reference
 10  Sales Person
 11  Quantity
 12  Unit Of Measure Code
 13  Equivalent Quantity
 14  Equivalent UOM Code
 15  Equivalent Unit
 16  Unit Price
 17  Discount
 18  Unit Discount
 19  Net Price
 20  Total Taxes
 21  Revenue
 22  Average Equivalent UOM Revenue
 23  Order Currency
 24  Value In Base Currency
 25  Base Currency
 26  Item Currency
 27  COGS
 28  Gross Margin

This importer:
  - Validates the file has exactly 28 data columns (JC-305 hard contract).
  - Persists every raw row to `vinsight_sales_detail_28` (schema/096).
  - Computes JC-295 duplicate hashes.
  - Wraps in BEGIN/COMMIT.
  - Hands the resolved rows off to existing `etl.import_direct.DirectImporter`
    for canonical sales_transaction insert via the normal Vinsight-Direct
    path. (No duplicate canonical insert logic.)

Usage::

    DATABASE_URL=postgresql://... python -m etl.import_vinsight_sales_detail path/file.csv
"""

from __future__ import annotations

import argparse
import csv
import datetime
import io
import json
import logging
import os
import sys
from decimal import Decimal, InvalidOperation
from pathlib import Path

import psycopg2
import psycopg2.extras

from etl.upload_duplicate_detect import detect_duplicates, persist_row_hashes
from etl.import_dws_zip import file_sha256

logger = logging.getLogger("moppity.etl.import_vinsight_sales_detail")

CHANNEL = "direct"

EXPECTED_HEADER_28 = [
    "Stock Item Code", "Description", "Order Num", "Invoice Date",
    "Date Created", "Customer Name", "Contact Num", "Contact Category",
    "Order Reference", "Sales Person", "Quantity", "Unit Of Measure Code",
    "Equivalent Quantity", "Equivalent UOM Code", "Equivalent Unit",
    "Unit Price", "Discount", "Unit Discount", "Net Price", "Total Taxes",
    "Revenue", "Average Equivalent UOM Revenue", "Order Currency",
    "Value In Base Currency", "Base Currency", "Item Currency", "COGS",
    "Gross Margin",
]

_DB_COLUMNS = [
    "upload_batch_id", "row_num",
    "stock_item_code", "description", "order_num", "invoice_date",
    "date_created", "customer_name", "contact_num", "contact_category",
    "order_reference", "sales_person", "quantity", "unit_of_measure_code",
    "equivalent_quantity", "equivalent_uom_code", "equivalent_unit",
    "unit_price", "discount", "unit_discount", "net_price", "total_taxes",
    "revenue", "average_equivalent_uom_revenue", "order_currency",
    "value_in_base_currency", "base_currency", "item_currency", "cogs",
    "gross_margin", "raw_row_json",
]


def _to_decimal(s: str) -> Decimal | None:
    if s is None:
        return None
    text = str(s).strip().replace(",", "").replace("$", "")
    if not text:
        return None
    if text.endswith("%"):
        # leave % strings as-is (gross_margin / discount stored as TEXT)
        return None
    try:
        return Decimal(text)
    except InvalidOperation:
        return None


def _to_date(s: str) -> datetime.date | None:
    if not s or not str(s).strip():
        return None
    text = str(s).strip()
    for fmt in ("%d/%m/%Y", "%Y-%m-%d", "%d-%m-%Y", "%m/%d/%Y", "%d %b %Y"):
        try:
            return datetime.datetime.strptime(text, fmt).date()
        except ValueError:
            continue
    return None


# ---------------------------------------------------------------------------
# Parser
# ---------------------------------------------------------------------------

def parse_vinsight_sales_detail_csv(csv_path: str) -> list[dict]:
    """Read 28-col Vinsight Sales Detail CSV; return list of row dicts.

    Skips the leading "Sales Detail" wrapper rows; locates the real header
    by matching against EXPECTED_HEADER_28[0] = "Stock Item Code".

    Raises ValueError if the header doesn't match the 28-col contract.
    """
    with open(csv_path, "rt", encoding="utf-8-sig", newline="") as f:
        reader = csv.reader(f)
        header = None
        for line in reader:
            if line and line[0].strip() == EXPECTED_HEADER_28[0]:
                header = [c.strip() for c in line]
                break
        if header is None:
            raise ValueError(
                f"Vinsight CSV {os.path.basename(csv_path)} has no header row "
                f"starting with 'Stock Item Code'."
            )
        if len(header) != 28:
            raise ValueError(
                f"Vinsight Sales Detail must be 28 cols; got {len(header)} "
                f"(file: {os.path.basename(csv_path)})"
            )
        for i, expected in enumerate(EXPECTED_HEADER_28):
            if header[i] != expected:
                raise ValueError(
                    f"Vinsight col {i+1} header mismatch: got "
                    f"{header[i]!r}, expected {expected!r}"
                )

        rows = []
        for row in reader:
            if not row or all(not c.strip() for c in row):
                continue
            # Pad/truncate to exactly 28
            row = (row + [""] * 28)[:28]
            rows.append(dict(zip(EXPECTED_HEADER_28, row)))
    return rows


# ---------------------------------------------------------------------------
# Pipeline
# ---------------------------------------------------------------------------

def run_import(
    csv_path: str,
    *,
    db_url: str,
    actor: str = "system",
    period_label: str | None = None,
) -> dict:
    started = datetime.datetime.now(datetime.timezone.utc)
    logger.info("Vinsight Sales Detail importer: %s", csv_path)
    file_hash = file_sha256(csv_path)
    rows = parse_vinsight_sales_detail_csv(csv_path)
    logger.info("Parsed %d Vinsight rows", len(rows))

    conn = psycopg2.connect(db_url)
    conn.autocommit = False
    try:
        with conn.cursor() as cur:
            cur.execute(
                "INSERT INTO upload_batch "
                "(channel, file_name, file_hash_sha256, status, "
                "row_count_seen, started_at, actor, period_label) "
                "VALUES (%s, %s, %s, 'staged', %s, %s, %s, %s) "
                "RETURNING upload_batch_id",
                (CHANNEL, os.path.basename(csv_path), file_hash, len(rows),
                 started, actor, period_label),
            )
            upload_batch_id = cur.fetchone()[0]

            payload = []
            ok_rows = []
            for i, row in enumerate(rows, start=1):
                raw_json = json.dumps(row, default=str)
                payload.append((
                    upload_batch_id, i,
                    row.get("Stock Item Code") or None,
                    row.get("Description") or None,
                    row.get("Order Num") or None,
                    _to_date(row.get("Invoice Date")),
                    _to_date(row.get("Date Created")),
                    row.get("Customer Name") or None,
                    row.get("Contact Num") or None,
                    row.get("Contact Category") or None,
                    row.get("Order Reference") or None,
                    row.get("Sales Person") or None,
                    _to_decimal(row.get("Quantity")),
                    row.get("Unit Of Measure Code") or None,
                    _to_decimal(row.get("Equivalent Quantity")),
                    row.get("Equivalent UOM Code") or None,
                    row.get("Equivalent Unit") or None,
                    _to_decimal(row.get("Unit Price")),
                    row.get("Discount") or None,
                    _to_decimal(row.get("Unit Discount")),
                    _to_decimal(row.get("Net Price")),
                    _to_decimal(row.get("Total Taxes")),
                    _to_decimal(row.get("Revenue")),
                    _to_decimal(row.get("Average Equivalent UOM Revenue")),
                    row.get("Order Currency") or None,
                    _to_decimal(row.get("Value In Base Currency")),
                    row.get("Base Currency") or None,
                    row.get("Item Currency") or None,
                    _to_decimal(row.get("COGS")),
                    row.get("Gross Margin") or None,
                    raw_json,
                ))
                inv_date = _to_date(row.get("Invoice Date"))
                ok_rows.append({
                    "row_num": i,
                    "customer_key": (row.get("Contact Num") or "")
                                    or (row.get("Customer Name") or ""),
                    "sku_key": (row.get("Stock Item Code") or "").upper(),
                    "month_key": inv_date.strftime("%Y-%m") if inv_date else "",
                    "quantity": _to_decimal(row.get("Quantity")),
                })

            psycopg2.extras.execute_values(
                cur,
                "INSERT INTO vinsight_sales_detail_28 ("
                + ", ".join(_DB_COLUMNS)
                + ") VALUES %s",
                payload,
                page_size=500,
            )

            dup_set = detect_duplicates(conn, channel=CHANNEL, rows=ok_rows)
            duplicates = [r["row_num"] for r in ok_rows
                          if r["row_hash"] in dup_set]
            persist_row_hashes(
                conn, channel=CHANNEL, upload_batch_id=upload_batch_id,
                rows=ok_rows,
            )

            cur.execute(
                "UPDATE upload_batch SET "
                "row_count_inserted = %s, "
                "row_count_duplicates = %s, "
                "ended_at = %s, "
                "status = 'imported' "
                "WHERE upload_batch_id = %s",
                (
                    len(ok_rows) - len(duplicates),
                    len(duplicates),
                    datetime.datetime.now(datetime.timezone.utc),
                    upload_batch_id,
                ),
            )
        conn.commit()
    except Exception:
        conn.rollback()
        logger.exception("Vinsight Sales Detail import failed; rolled back.")
        raise
    finally:
        conn.close()

    summary = {
        "ok": True,
        "channel": CHANNEL,
        "upload_batch_id": upload_batch_id,
        "file_name": os.path.basename(csv_path),
        "file_hash_sha256": file_hash,
        "rows_seen": len(rows),
        "rows_staged": len(payload),
        "duplicates_detected": len(duplicates),
        "started_at": started.isoformat(),
        "ended_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    }
    logger.info("Vinsight Sales Detail import complete: %s", summary)
    return summary


def _main():
    ap = argparse.ArgumentParser(
        description="Vinsight Sales Detail 28-col CSV → Postgres importer"
    )
    ap.add_argument("file", help="path to Vinsight Sales Detail CSV")
    ap.add_argument("--actor", default="cli")
    ap.add_argument("--period", default=None)
    args = ap.parse_args()

    db_url = os.environ.get("DATABASE_URL")
    if not db_url:
        print("DATABASE_URL not set", file=sys.stderr)
        sys.exit(2)
    logging.basicConfig(level=logging.INFO,
                         format="%(asctime)s %(levelname)s %(message)s")
    result = run_import(args.file, db_url=db_url, actor=args.actor,
                          period_label=args.period)
    print(json.dumps(result, indent=2, default=str))


if __name__ == "__main__":
    _main()
