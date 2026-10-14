"""
B6a / JC-137: Import SKU master Access-first, Vinsight-fills.

Reads the Access SKU table (99 rows, 10 cols) from the .accdb via mdb-export
and UPSERTs into canonical_sku. Access is the authoritative source for
sku_name + range + range_group + units_per_case + cogs + base_wholesale +
transfer_cost + note. Vinsight stock-item fields fill any rows Access does not
cover (delegated to existing sync_vinsight_cogs.py — out of scope here).

Falls back to the openpyxl path used by import_canonical_sku.py when the
.accdb file is not on disk (so this script is safe to run in CI / local dev
where the binary accdb may be missing).

Usage:
    DATABASE_URL=postgresql://... python -m etl.import_sku_from_access_first

Optional env:
    ACCDB_PATH=/abs/path/to/accessdb.accdb
    XLSX_PATH=/abs/path/to/Database reconciliation (1).xlsx  (fallback)
"""

import csv
import io
import logging
import os
import subprocess
import sys
from decimal import Decimal, InvalidOperation

import psycopg2

from etl.logger import log_etl_run

logger = logging.getLogger("moppity.etl.import_sku_from_access_first")

DEFAULT_ACCDB_PATH = os.path.join(
    os.path.dirname(os.path.dirname(__file__)),
    "audit", "external-sources", "accessdb.accdb",
)
DEFAULT_XLSX_PATH = os.path.join(
    os.path.dirname(os.path.dirname(__file__)),
    "reference", "owner-feedback-mar26", "Database reconciliation (1).xlsx",
)
SOURCE = "access_sku_first"
ENDPOINT = "Access.SKU"
ACCESS_TABLE = "SKU"


def _parse_decimal(value) -> Decimal | None:
    if value is None or value == "":
        return None
    text = str(value).strip().replace(",", "").replace("$", "")
    if not text:
        return None
    try:
        return Decimal(text)
    except InvalidOperation:
        return None


def _parse_int(value) -> int | None:
    if value is None or value == "":
        return None
    try:
        return int(float(value))
    except (ValueError, TypeError):
        return None


def read_accdb_sku(accdb_path: str) -> list[dict]:
    """Run mdb-export against Access SKU table and return list of dicts.

    Header order (from extract-accdb.md row extract-accdb-0016):
        ID, SKU, Range, RangeGroup, UnitsperCase, Cogs, BaseWholesale,
        TransferCost, Note, Units
    """
    proc = subprocess.run(
        ["mdb-export", accdb_path, ACCESS_TABLE],
        check=True, capture_output=True, text=True,
    )
    reader = csv.DictReader(io.StringIO(proc.stdout))
    rows = []
    for raw in reader:
        sku_name = (raw.get("SKU") or "").strip()
        if not sku_name:
            continue  # JC-160: skip empty rows. The "N/A" sentinel row is preserved (sku_name="N/A") since it is non-empty.
        rows.append({
            "sku_name":       sku_name,
            "range_name":     (raw.get("Range") or "").strip() or None,
            "range_group":    (raw.get("RangeGroup") or "").strip() or None,
            "units_per_case": _parse_int(raw.get("UnitsperCase")),
            "cogs":           _parse_decimal(raw.get("Cogs")),
            "base_wholesale": _parse_decimal(raw.get("BaseWholesale")),
            "transfer_cost":  _parse_decimal(raw.get("TransferCost")),
            "note":           (raw.get("Note") or "").strip() or None,
        })
    return rows


def read_xlsx_sku(xlsx_path: str) -> list[dict]:
    """Fallback: read SKU table tab from reconciliation xlsx (same shape).

    Mirrors etl/import_canonical_sku.py.read_sku_rows but returns the same
    dict shape as read_accdb_sku (with `note` set to None since the xlsx tab
    does not carry the Note column).
    """
    import openpyxl
    wb = openpyxl.load_workbook(xlsx_path, read_only=True, data_only=True)
    ws = wb["SKU table"]
    raw_rows = list(ws.iter_rows(values_only=True))
    wb.close()
    if len(raw_rows) < 2:
        raise ValueError(f"SKU table has {len(raw_rows)} rows — expected header + data.")
    header = [str(h).strip().lower() if h else "" for h in raw_rows[0]]
    col = {h: idx for idx, h in enumerate(header)}
    rows = []
    for r in raw_rows[1:]:
        sku_name = r[col.get("sku", 1)]
        if sku_name is None or str(sku_name).strip() == "":
            continue
        rows.append({
            "sku_name":       str(sku_name).strip(),
            "range_name":     str(r[col.get("range", 2)]).strip() if r[col.get("range", 2)] else None,
            "range_group":    str(r[col.get("rangegroup", 3)]).strip() if r[col.get("rangegroup", 3)] else None,
            "units_per_case": _parse_int(r[col.get("unitspercase", 4)]),
            "cogs":           _parse_decimal(r[col.get("cogs", 5)]),
            "base_wholesale": _parse_decimal(r[col.get("basewholesale", 6)]),
            "transfer_cost":  _parse_decimal(r[col.get("transfercost", 7)]),
            "note":           None,
        })
    return rows


def upsert_canonical_skus(conn, sku_rows: list[dict]) -> dict:
    """UPSERT into canonical_sku. Wrapped in BEGIN/COMMIT."""
    inserted = 0
    updated = 0
    errors: list[str] = []

    try:
        with conn.cursor() as cur:
            for row in sku_rows:
                cur.execute(
                    """
                    INSERT INTO canonical_sku
                        (sku_name, range_name, range_group, units_per_case,
                         cogs, base_wholesale, transfer_cost, note, updated_at)
                    VALUES (%s, %s, %s, %s, %s, %s, %s, %s, NOW())
                    ON CONFLICT (sku_name) DO UPDATE SET
                        range_name     = EXCLUDED.range_name,
                        range_group    = EXCLUDED.range_group,
                        units_per_case = EXCLUDED.units_per_case,
                        cogs           = EXCLUDED.cogs,
                        base_wholesale = EXCLUDED.base_wholesale,
                        transfer_cost  = EXCLUDED.transfer_cost,
                        note           = EXCLUDED.note,
                        updated_at     = NOW()
                    RETURNING (xmax = 0) AS is_insert
                    """,
                    (
                        row["sku_name"], row["range_name"], row["range_group"],
                        row["units_per_case"], row["cogs"], row["base_wholesale"],
                        row["transfer_cost"], row["note"],
                    ),
                )
                if cur.fetchone()[0]:
                    inserted += 1
                else:
                    updated += 1
        conn.commit()
    except Exception as exc:
        conn.rollback()
        errors.append(f"transaction rolled back: {exc}")
        raise

    return {"inserted": inserted, "updated": updated, "errors": errors}


def main():
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    )

    db_url = os.environ.get("DATABASE_URL")
    if not db_url:
        print("ERROR: DATABASE_URL environment variable is not set.", file=sys.stderr)
        sys.exit(1)

    accdb_path = os.environ.get("ACCDB_PATH", DEFAULT_ACCDB_PATH)
    xlsx_path = os.environ.get("XLSX_PATH", DEFAULT_XLSX_PATH)

    if os.path.isfile(accdb_path):
        print(f"Source: {accdb_path} (Access table {ACCESS_TABLE})")
        sku_rows = read_accdb_sku(accdb_path)
        source_label = "accdb"
    elif os.path.isfile(xlsx_path):
        print(f"Source: {xlsx_path} (xlsx fallback — accdb not found at {accdb_path})")
        sku_rows = read_xlsx_sku(xlsx_path)
        source_label = "xlsx"
    else:
        print(f"ERROR: neither accdb ({accdb_path}) nor xlsx ({xlsx_path}) found.", file=sys.stderr)
        sys.exit(1)

    print(f"Read {len(sku_rows)} SKU rows ({source_label}).")

    conn = psycopg2.connect(db_url)
    try:
        stats = upsert_canonical_skus(conn, sku_rows)
        print(f"  Inserted: {stats['inserted']}  Updated: {stats['updated']}")

        log_etl_run(
            conn,
            source=SOURCE,
            endpoint=f"{ENDPOINT}::{source_label}",
            status="success",
            rows_processed=stats["inserted"] + stats["updated"],
            rows_skipped=0,
            error_count=len(stats["errors"]),
            error_detail="\n".join(stats["errors"][:50]) if stats["errors"] else None,
        )
        print("DONE.")
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
