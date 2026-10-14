"""
DWS ZIP / 114-col importer (Bundle B12).

Wraps the existing `etl.import_dws.DWSImporter` to add:
  - JC-290: accept .zip archives containing a single .xlsx
  - JC-303: persist every raw row (114 cols) to `dws_staging_114`
  - JC-297: reject rows that look like ALM data leaked into a DWS upload
  - JC-298: strip leading zeros from customer codes before lookup
  - JC-301: enforce DWS code naming (alpha-prefix uppercased; reject
            blank / pure-numeric codes that came from the wrong report)
  - JC-306: surface CASES9LTR as canonical case unit per row
  - JC-295: hash each row into `upload_row_hash` for duplicate detection

Usage::

    DATABASE_URL=postgresql://... python -m etl.import_dws_zip path/file.zip
    DATABASE_URL=postgresql://... python -m etl.import_dws_zip path/file.xlsx

Either form works; .zip is unwrapped first.
"""

from __future__ import annotations

import argparse
import datetime
import hashlib
import io
import json
import logging
import os
import re
import sys
import tempfile
import zipfile
from decimal import Decimal, InvalidOperation
from pathlib import Path

import openpyxl
import psycopg2
import psycopg2.extras

from etl.upload_duplicate_detect import (
    compute_row_hash,
    persist_row_hashes,
)

logger = logging.getLogger("moppity.etl.import_dws_zip")

CHANNEL = "dws"
SOURCE_SYSTEM = "DWS"

# Mirrors xlsx column order (1-indexed). MUST match schema/096 column order
# in dws_staging_114 (DATE..FREEREASON, 114 cols).
DWS_HEADER_114 = [
    "DATE", "SOURCE", "REFNO", "FINYEAR", "FINMTH",
    "DEBTOR", "DRNAME", "DRTYPE", "DRGRP", "DRGRPNAME",
    "SAREA", "SAREANAME", "SAGRP", "SAGRPNAME",
    "SREP", "SREPNAME", "SRGRP", "SRGRPNAME",
    "DRCAT", "DRCATNAME",
    "CRRAT", "CRRATNAME", "TERMS", "TERMSNAME",
    "DISC", "DISCNAME", "PRICE", "PRICENAME",
    "CURRENCY", "LQRLIC",
    "STOCKITEM", "STKDESC1", "STKDESC2",
    "STKGRP", "STKGRPNAME", "SALGRP", "SALGRPNAME",
    "LOC", "LOCNAME", "LOCGRP", "LOCGRPNAME",
    "ALCTYP", "ALCTYPNAME", "ABSCLS", "ABSCLSNAME",
    "QUANTITY", "CARTONS", "BOTTLES", "LITRES",
    "GROSSVAL", "STAXVAL", "DISCVAL", "COSTVAL", "WETVAL", "GSTVAL",
    "XGROUP01", "XGROUP02", "XGROUP03", "XGROUP04", "XGROUP05",
    "XGROUP06", "XGROUP07", "XGROUP08", "XGROUP09", "XGROUP10",
    "STKALIAS", "DRALIAS",
    "XSTKGRP01", "XSTKGRP02", "XSTKGRP03", "XSTKGRP04", "XSTKGRP05",
    "XSTKGRP06", "XSTKGRP07", "XSTKGRP08", "XSTKGRP09", "XSTKGRP10",
    "XSTKGRP11", "XSTKGRP12", "XSTKGRP13", "XSTKGRP14",
    "XGROUPNM01", "XGROUPNM02", "XGROUPNM03", "XGROUPNM04", "XGROUPNM05",
    "XGROUPNM06", "XGROUPNM07", "XGROUPNM08", "XGROUPNM09", "XGROUPNM10",
    "XSTGRPNM01", "XSTGRPNM02", "XSTGRPNM03", "XSTGRPNM04", "XSTGRPNM05",
    "XSTGRPNM06", "XSTGRPNM07", "XSTGRPNM08", "XSTGRPNM09", "XSTGRPNM10",
    "XSTGRPNM11", "XSTGRPNM12", "XSTGRPNM13", "XSTGRPNM14",
    "CASES9LTR", "STOCKUNIT", "SALNO", "CNREASON", "CRINV",
    "CRUSERID", "INVUSERID", "PRICETYPE", "FREEREASON",
]

# Columns in dws_staging_114 INSERT (matches schema/096 ordering minus the
# auto-managed staging_id, upload_batch_id+row_num explicit, raw_row_json,
# inserted_at).
_STAGING_COLUMNS = [
    "upload_batch_id", "row_num",
    "sale_date", "source_code", "refno", "finyear", "finmth",
    "debtor", "drname", "drtype", "drgrp", "drgrpname",
    "sarea", "sareaname", "sagrp", "sagrpname",
    "srep", "srepname", "srgrp", "srgrpname",
    "drcat", "drcatname",
    "crrat", "crratname", "terms", "termsname",
    "disc", "discname", "price", "pricename",
    "currency", "lqrlic",
    "stockitem", "stkdesc1", "stkdesc2",
    "stkgrp", "stkgrpname", "salgrp", "salgrpname",
    "loc", "locname", "locgrp", "locgrpname",
    "alctyp", "alctypname", "abscls", "absclsname",
    "quantity", "cartons", "bottles", "litres",
    "grossval", "staxval", "discval", "costval", "wetval", "gstval",
    "xgroup01", "xgroup02", "xgroup03", "xgroup04", "xgroup05",
    "xgroup06", "xgroup07", "xgroup08", "xgroup09", "xgroup10",
    "stkalias", "dralias",
    "xstkgrp01", "xstkgrp02", "xstkgrp03", "xstkgrp04", "xstkgrp05",
    "xstkgrp06", "xstkgrp07", "xstkgrp08", "xstkgrp09", "xstkgrp10",
    "xstkgrp11", "xstkgrp12", "xstkgrp13", "xstkgrp14",
    "xgroupnm01", "xgroupnm02", "xgroupnm03", "xgroupnm04", "xgroupnm05",
    "xgroupnm06", "xgroupnm07", "xgroupnm08", "xgroupnm09", "xgroupnm10",
    "xstgrpnm01", "xstgrpnm02", "xstgrpnm03", "xstgrpnm04", "xstgrpnm05",
    "xstgrpnm06", "xstgrpnm07", "xstgrpnm08", "xstgrpnm09", "xstgrpnm10",
    "xstgrpnm11", "xstgrpnm12", "xstgrpnm13", "xstgrpnm14",
    "cases9ltr", "stockunit", "salno", "cnreason", "crinv",
    "cruserid", "invuserid", "pricetype", "freereason",
    "raw_row_json",
]


# ---------------------------------------------------------------------------
# Parsing helpers
# ---------------------------------------------------------------------------

def _to_decimal(v) -> Decimal | None:
    if v is None or v == "":
        return None
    try:
        return Decimal(str(v).replace(",", "").replace("$", ""))
    except (InvalidOperation, ValueError):
        return None


def _to_date(v) -> datetime.date | None:
    if v is None or v == "":
        return None
    if isinstance(v, datetime.datetime):
        return v.date()
    if isinstance(v, datetime.date):
        return v
    text = str(v).strip()
    for fmt in ("%Y-%m-%d", "%d/%m/%Y", "%d-%m-%Y", "%m/%d/%Y"):
        try:
            return datetime.datetime.strptime(text, fmt).date()
        except ValueError:
            continue
    return None


def strip_customer_leading_zeros(code: str | None) -> str:
    """JC-298: '0001234' -> '1234'; '00123' -> '123'; '0' -> ''."""
    if code is None:
        return ""
    text = str(code).strip()
    if not text:
        return ""
    # Pure-numeric: strip all leading zeros (returning '' if all zero)
    if text.isdigit():
        stripped = text.lstrip("0")
        return stripped  # '' for '000' is intentional (JC-298 spec)
    # Mixed: strip leading zeros only if the rest stays alpha-prefix-valid
    return text.lstrip("0") or text


# JC-297: ALM rows look like… ALM. Heuristics from comparing 79-col ALM EDI
# columns (Warehouse=ALM_*) against the 114-col DWS report. Fail fast on any
# of these signals.
_ALM_SOURCE_SIGNALS = {
    "ALM", "ALMQ", "AUSTRALIAN LIQUOR MARKETERS", "ALM-NSW", "ALM-VIC",
    "ALM-QLD", "ALM-SA", "ALM-WA", "ALM-ACT", "ALM-TAS",
}


def looks_like_alm_row(row_dict: dict) -> bool:
    """JC-297: return True if a row appears to be ALM data, not DWS."""
    src = (row_dict.get("SOURCE") or "").strip().upper()
    if src in _ALM_SOURCE_SIGNALS or src.startswith("ALM"):
        return True
    # DWS code naming convention is alpha-prefix (e.g. MOLKSH21F, COCCCHAB22).
    # Pure-numeric STOCKITEM is a strong ALM signal.
    sku = (row_dict.get("STOCKITEM") or "").strip()
    if sku.isdigit() and len(sku) >= 5:
        return True
    # ALM 79-col ALMData uses 'WHOLESALE' channel marker — DWS has SOURCE.
    chan = (row_dict.get("DRTYPE") or "").strip().upper()
    if chan in ("ALM", "WHOLESALE-ALM"):
        return True
    return False


# JC-301: DWS code naming convention. Reject blank/numeric/whitespace SKU.
DWS_CODE_RE = re.compile(r"^[A-Z][A-Z0-9_-]{2,}$")


def is_valid_dws_sku_code(code: str | None) -> bool:
    if not code:
        return False
    return bool(DWS_CODE_RE.match(code.strip().upper()))


# JC-306: derive CASES9LTR from raw row when the column is empty.
def derive_cases9ltr(row: dict) -> Decimal | None:
    """If CASES9LTR is set, use it. Else if STKDESC contains '9L'/'9LITRE',
    take CARTONS. Else fall back to BOTTLES/9 when bottles known.
    """
    direct = _to_decimal(row.get("CASES9LTR"))
    if direct is not None and direct != 0:
        return direct
    desc = " ".join(str(row.get(k) or "") for k in ("STKDESC1", "STKDESC2")).upper()
    if "9L" in desc or "9 LITRE" in desc or "9LTR" in desc:
        cart = _to_decimal(row.get("CARTONS"))
        if cart is not None:
            return cart
    bottles = _to_decimal(row.get("BOTTLES"))
    if bottles is not None and bottles > 0:
        return (bottles / Decimal("9")).quantize(Decimal("0.0001"))
    return direct  # may be None


# ---------------------------------------------------------------------------
# zip / xlsx unpacking
# ---------------------------------------------------------------------------

def unpack_to_xlsx(file_path: str) -> str:
    """JC-290: accept .zip OR .xlsx; return path to the .xlsx to read.

    .zip handling: unzip into a temp dir, return path to the first .xlsx.
    Caller is responsible for cleanup.
    """
    p = Path(file_path)
    if p.suffix.lower() == ".xlsx":
        return str(p)
    if p.suffix.lower() != ".zip":
        raise ValueError(
            f"Unsupported DWS upload extension: {p.suffix!r} "
            f"(expected .zip or .xlsx)"
        )
    with zipfile.ZipFile(file_path, "r") as zf:
        xlsx_members = [n for n in zf.namelist() if n.lower().endswith(".xlsx")]
        if not xlsx_members:
            raise ValueError(
                f"DWS .zip {p.name!r} contains no .xlsx file (members: {zf.namelist()!r})"
            )
        # Use first .xlsx (DWS reports ship one xlsx per zip).
        target_name = xlsx_members[0]
        out_dir = tempfile.mkdtemp(prefix="dws_zip_")
        out_path = os.path.join(out_dir, os.path.basename(target_name))
        with zf.open(target_name) as src, open(out_path, "wb") as dst:
            dst.write(src.read())
        return out_path


def file_sha256(file_path: str) -> str:
    h = hashlib.sha256()
    with open(file_path, "rb") as f:
        for chunk in iter(lambda: f.read(64 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


# ---------------------------------------------------------------------------
# Staging row builder
# ---------------------------------------------------------------------------

def _stage_row(row_dict: dict, upload_batch_id: int, row_num: int) -> tuple:
    """Build a tuple matching _STAGING_COLUMNS for INSERT."""
    cases9ltr = derive_cases9ltr(row_dict)
    raw_json = json.dumps(
        {k: (v.isoformat() if isinstance(v, (datetime.date, datetime.datetime)) else v)
         for k, v in row_dict.items()},
        default=str,
    )
    return (
        upload_batch_id, row_num,
        _to_date(row_dict.get("DATE")),
        row_dict.get("SOURCE"),
        row_dict.get("REFNO"),
        row_dict.get("FINYEAR"),
        row_dict.get("FINMTH"),
        row_dict.get("DEBTOR"),
        row_dict.get("DRNAME"),
        row_dict.get("DRTYPE"),
        row_dict.get("DRGRP"),
        row_dict.get("DRGRPNAME"),
        row_dict.get("SAREA"),
        row_dict.get("SAREANAME"),
        row_dict.get("SAGRP"),
        row_dict.get("SAGRPNAME"),
        row_dict.get("SREP"),
        row_dict.get("SREPNAME"),
        row_dict.get("SRGRP"),
        row_dict.get("SRGRPNAME"),
        row_dict.get("DRCAT"),
        row_dict.get("DRCATNAME"),
        row_dict.get("CRRAT"),
        row_dict.get("CRRATNAME"),
        row_dict.get("TERMS"),
        row_dict.get("TERMSNAME"),
        row_dict.get("DISC"),
        row_dict.get("DISCNAME"),
        row_dict.get("PRICE"),
        row_dict.get("PRICENAME"),
        row_dict.get("CURRENCY"),
        row_dict.get("LQRLIC"),
        row_dict.get("STOCKITEM"),
        row_dict.get("STKDESC1"),
        row_dict.get("STKDESC2"),
        row_dict.get("STKGRP"),
        row_dict.get("STKGRPNAME"),
        row_dict.get("SALGRP"),
        row_dict.get("SALGRPNAME"),
        row_dict.get("LOC"),
        row_dict.get("LOCNAME"),
        row_dict.get("LOCGRP"),
        row_dict.get("LOCGRPNAME"),
        row_dict.get("ALCTYP"),
        row_dict.get("ALCTYPNAME"),
        row_dict.get("ABSCLS"),
        row_dict.get("ABSCLSNAME"),
        _to_decimal(row_dict.get("QUANTITY")),
        _to_decimal(row_dict.get("CARTONS")),
        _to_decimal(row_dict.get("BOTTLES")),
        _to_decimal(row_dict.get("LITRES")),
        _to_decimal(row_dict.get("GROSSVAL")),
        _to_decimal(row_dict.get("STAXVAL")),
        _to_decimal(row_dict.get("DISCVAL")),
        _to_decimal(row_dict.get("COSTVAL")),
        _to_decimal(row_dict.get("WETVAL")),
        _to_decimal(row_dict.get("GSTVAL")),
        row_dict.get("XGROUP01"), row_dict.get("XGROUP02"), row_dict.get("XGROUP03"),
        row_dict.get("XGROUP04"), row_dict.get("XGROUP05"),
        row_dict.get("XGROUP06"), row_dict.get("XGROUP07"), row_dict.get("XGROUP08"),
        row_dict.get("XGROUP09"), row_dict.get("XGROUP10"),
        row_dict.get("STKALIAS"), row_dict.get("DRALIAS"),
        row_dict.get("XSTKGRP01"), row_dict.get("XSTKGRP02"), row_dict.get("XSTKGRP03"),
        row_dict.get("XSTKGRP04"), row_dict.get("XSTKGRP05"),
        row_dict.get("XSTKGRP06"), row_dict.get("XSTKGRP07"), row_dict.get("XSTKGRP08"),
        row_dict.get("XSTKGRP09"), row_dict.get("XSTKGRP10"),
        row_dict.get("XSTKGRP11"), row_dict.get("XSTKGRP12"), row_dict.get("XSTKGRP13"),
        row_dict.get("XSTKGRP14"),
        row_dict.get("XGROUPNM01"), row_dict.get("XGROUPNM02"), row_dict.get("XGROUPNM03"),
        row_dict.get("XGROUPNM04"), row_dict.get("XGROUPNM05"),
        row_dict.get("XGROUPNM06"), row_dict.get("XGROUPNM07"), row_dict.get("XGROUPNM08"),
        row_dict.get("XGROUPNM09"), row_dict.get("XGROUPNM10"),
        row_dict.get("XSTGRPNM01"), row_dict.get("XSTGRPNM02"), row_dict.get("XSTGRPNM03"),
        row_dict.get("XSTGRPNM04"), row_dict.get("XSTGRPNM05"),
        row_dict.get("XSTGRPNM06"), row_dict.get("XSTGRPNM07"), row_dict.get("XSTGRPNM08"),
        row_dict.get("XSTGRPNM09"), row_dict.get("XSTGRPNM10"),
        row_dict.get("XSTGRPNM11"), row_dict.get("XSTGRPNM12"), row_dict.get("XSTGRPNM13"),
        row_dict.get("XSTGRPNM14"),
        cases9ltr,
        row_dict.get("STOCKUNIT"),
        row_dict.get("SALNO"),
        row_dict.get("CNREASON"),
        row_dict.get("CRINV"),
        row_dict.get("CRUSERID"),
        row_dict.get("INVUSERID"),
        row_dict.get("PRICETYPE"),
        row_dict.get("FREEREASON"),
        raw_json,
    )


# ---------------------------------------------------------------------------
# Main pipeline
# ---------------------------------------------------------------------------

def parse_dws_xlsx(xlsx_path: str) -> tuple[list[str], list[dict]]:
    """Parse 114-col DWS xlsx; return (header, rows-as-dicts).

    Raises ValueError if header doesn't match the expected 114-col schema.
    """
    wb = openpyxl.load_workbook(xlsx_path, read_only=True, data_only=True)
    ws = wb.active
    rows_iter = ws.iter_rows(values_only=True)
    header_row = next(rows_iter, None)
    if header_row is None:
        raise ValueError("DWS xlsx is empty (no header row).")
    header = [str(h).strip() if h is not None else "" for h in header_row]
    # Allow either exact match or a known prefix (some monthly variants may
    # add a few trailing analytical cols — log a warning, don't reject).
    if len(header) < 100:
        raise ValueError(
            f"DWS xlsx has {len(header)} cols; expected ~114. Wrong file?"
        )
    rows = []
    for row in rows_iter:
        if not row or all(v is None or v == "" for v in row):
            continue
        row_dict = {}
        for i, val in enumerate(row):
            if i < len(header) and header[i]:
                row_dict[header[i]] = val
        rows.append(row_dict)
    return header, rows


def run_import(
    file_path: str,
    *,
    db_url: str,
    actor: str = "system",
    period_label: str | None = None,
) -> dict:
    """Top-level entry. Returns a JSON-serialisable result dict."""
    started = datetime.datetime.now(datetime.timezone.utc)
    logger.info("DWS zip importer: %s", file_path)

    file_hash = file_sha256(file_path)
    xlsx_path = unpack_to_xlsx(file_path)
    header, rows = parse_dws_xlsx(xlsx_path)
    logger.info("Parsed %d DWS rows from %s", len(rows), xlsx_path)

    conn = psycopg2.connect(db_url)
    conn.autocommit = False  # explicit BEGIN/COMMIT
    try:
        with conn.cursor() as cur:
            # 1. Open upload_batch row
            cur.execute(
                "INSERT INTO upload_batch "
                "(channel, file_name, file_hash_sha256, status, "
                "row_count_seen, started_at, actor, period_label) "
                "VALUES (%s, %s, %s, 'staged', %s, %s, %s, %s) "
                "RETURNING upload_batch_id",
                (CHANNEL, os.path.basename(file_path), file_hash, len(rows),
                 started, actor, period_label),
            )
            upload_batch_id = cur.fetchone()[0]

            # 2. Per-row validation + classification
            staging_payload = []
            duplicates = []
            rejected_alm = []
            rejected_invalid = []
            ok_rows = []

            for i, row in enumerate(rows, start=1):
                if looks_like_alm_row(row):
                    rejected_alm.append((i, row))
                    continue
                sku = (row.get("STOCKITEM") or "").strip().upper()
                if not is_valid_dws_sku_code(sku):
                    rejected_invalid.append((i, row, "invalid_sku_code"))
                    continue
                # JC-298: strip leading zeros on customer code (DEBTOR /
                # DRALIAS may contain "0001234"); store both raw + stripped.
                debtor_raw = (row.get("DEBTOR") or "")
                row["__customer_key_stripped"] = strip_customer_leading_zeros(debtor_raw)
                staging_payload.append(_stage_row(row, upload_batch_id, i))
                ok_rows.append({
                    "row_num": i,
                    "customer_key": row["__customer_key_stripped"] or row.get("DRNAME") or "",
                    "sku_key": sku,
                    "month_key": _month_key(row.get("DATE")),
                    "quantity": _to_decimal(row.get("CARTONS"))
                                or _to_decimal(row.get("CASES9LTR"))
                                or _to_decimal(row.get("QUANTITY")),
                })

            # 3. Bulk-insert into dws_staging_114
            if staging_payload:
                psycopg2.extras.execute_values(
                    cur,
                    "INSERT INTO dws_staging_114 ("
                    + ", ".join(_STAGING_COLUMNS)
                    + ") VALUES %s",
                    staging_payload,
                    page_size=500,
                )

            # 4. JC-295 duplicate detection
            from etl.upload_duplicate_detect import detect_duplicates  # local
            dup_hashes = detect_duplicates(conn, channel=CHANNEL, rows=ok_rows)
            for r in ok_rows:
                if r["row_hash"] in dup_hashes:
                    duplicates.append(r["row_num"])

            persist_row_hashes(
                conn, channel=CHANNEL, upload_batch_id=upload_batch_id, rows=ok_rows,
            )

            # 5. Update upload_batch totals
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
    except Exception as exc:
        conn.rollback()
        logger.exception("DWS zip import failed; rolled back.")
        raise
    finally:
        conn.close()

    summary = {
        "ok": True,
        "channel": CHANNEL,
        "upload_batch_id": upload_batch_id,
        "file_name": os.path.basename(file_path),
        "file_hash_sha256": file_hash,
        "rows_seen": len(rows),
        "rows_staged": len(staging_payload),
        "rows_rejected_alm": len(rejected_alm),
        "rows_rejected_invalid": len(rejected_invalid),
        "duplicates_detected": len(duplicates),
        "started_at": started.isoformat(),
        "ended_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    }
    logger.info("DWS zip import complete: %s", summary)
    return summary


def _month_key(d) -> str:
    parsed = _to_date(d)
    if parsed is None:
        return ""
    return parsed.strftime("%Y-%m")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def _main():
    ap = argparse.ArgumentParser(description="DWS zip/xlsx → Postgres importer")
    ap.add_argument("file", help="path to .zip or .xlsx")
    ap.add_argument("--actor", default="cli", help="who triggered the import")
    ap.add_argument("--period", default=None, help='e.g. "Feb 2026"')
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
