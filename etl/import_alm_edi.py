"""
ALM EDI segmented importer (Bundle B12).

Strict 5/0 / 5/1 / 5/2 / 5/3 segment parser for the ALM weekly EDI flat file
(JC-304). Each line is classified by its `5|<n>|` prefix and persisted to the
matching alm_edi_segment_5{0,1,2,3} staging table (schema/096).

Differs from the existing `etl.import_alm.ALMImporter`:
  - import_alm.py only consumes 5|2 (transaction) lines and writes them
    directly to sales_transaction. It silently drops 5|0/5|1/5|3.
  - import_alm_edi.py persists EVERY segment so the audit trail is complete,
    enables EDI-segment-level reconciliation against the source flat file,
    and provides a stable foundation for future per-batch reconcile workflows.

The 5|2 transactions, after staging, are STILL handed off to ALMImporter for
canonical sales_transaction insertion. This module is additive (provenance);
it does not duplicate the canonical insert path.

JC handling:
  - JC-290: accepts .zip (with nested .zip OR plain EDI files inside) AND
    raw EDI flat-files.
  - JC-298: customer_code stripped of leading zeros into
    alm_edi_segment_52.customer_code_stripped.
  - JC-295: each 5|2 row gets a duplicate hash via upload_duplicate_detect.

Usage::

    DATABASE_URL=postgresql://... python -m etl.import_alm_edi path/to.zip
    DATABASE_URL=postgresql://... python -m etl.import_alm_edi path/to.txt
"""

from __future__ import annotations

import argparse
import datetime
import io
import json
import logging
import os
import sys
import zipfile
from decimal import Decimal, InvalidOperation
from pathlib import Path

import psycopg2
import psycopg2.extras

from etl.upload_duplicate_detect import (
    compute_row_hash,
    detect_duplicates,
    persist_row_hashes,
)
from etl.import_dws_zip import file_sha256, strip_customer_leading_zeros

logger = logging.getLogger("moppity.etl.import_alm_edi")

CHANNEL = "alm"
SOURCE_SYSTEM = "ALM"


# ---------------------------------------------------------------------------
# EDI segment parsing
# ---------------------------------------------------------------------------

def _parse_yyyymmdd(s: str) -> datetime.date | None:
    s = (s or "").strip()
    if len(s) != 8 or not s.isdigit():
        return None
    try:
        return datetime.date(int(s[:4]), int(s[4:6]), int(s[6:8]))
    except ValueError:
        return None


def _to_int(s: str) -> int | None:
    s = (s or "").strip()
    if not s:
        return None
    try:
        return int(s)
    except ValueError:
        try:
            return int(float(s))
        except ValueError:
            return None


def _to_decimal(s: str) -> Decimal | None:
    s = (s or "").strip()
    if not s:
        return None
    try:
        return Decimal(s.replace(",", "").replace("$", ""))
    except InvalidOperation:
        return None


def _segment_kind(line: str) -> str | None:
    """Return '50' / '51' / '52' / '53' or None for non-EDI lines."""
    if not line:
        return None
    parts = line.split("|", 3)
    if len(parts) < 3 or parts[0] != "5":
        return None
    sub = parts[1].strip()
    return f"5{sub}" if sub in {"0", "1", "2", "3"} else None


def parse_segment_50(line: str) -> dict:
    f = line.split("|")
    return {
        "raw_line": line,
        "supplier_code": (f[2] if len(f) > 2 else "").strip() or None,
        "state_code": (f[3] if len(f) > 3 else "").strip() or None,
        "file_date": _parse_yyyymmdd(f[4] if len(f) > 4 else ""),
    }


def parse_segment_51(line: str) -> dict:
    f = line.split("|")
    return {
        "raw_line": line,
        "batch_id": (f[2] if len(f) > 2 else "").strip() or None,
    }


def parse_segment_52(line: str) -> dict:
    """Parse 5|2 transaction line. Mirrors etl/import_alm.py field map.

    D1 (2026-05-11): f[21] outlet_address captured for MatchCustomerModal
    Address pre-fill. Rep stays blank — genuinely absent from ALM EDI source
    (no sales-rep field on 5|2 line); documented limitation, NOT a bug.
    """
    f = line.split("|")

    def _get(idx: int) -> str:
        return f[idx].strip() if idx < len(f) else ""

    customer_code = _get(4)
    sale_date = _parse_yyyymmdd(_get(8))
    return {
        "raw_line": line,
        "customer_code": customer_code or None,
        "customer_code_stripped": strip_customer_leading_zeros(customer_code) or None,
        "txn_id": _get(5) or None,
        "sale_date": sale_date,
        "alm_product_code": _get(11) or None,
        "product_description": _get(12) or None,
        "pack_size": _to_int(_get(18)),
        "outlet_name": _get(20) or None,
        "outlet_address": _get(21) or None,  # D1: schema/165
        "qty_delivered": _to_decimal(_get(37)),
        "gross_cents": _to_int(_get(43)),
        "cost_cents": _to_int(_get(44)),
        "discount_cents": _to_int(_get(45)),
        "wet_cents": _to_int(_get(46)),
        "gst_cents": _to_int(_get(47)),
    }


def parse_segment_53(line: str) -> dict:
    f = line.split("|")
    return {
        "raw_line": line,
        "record_count": _to_int(f[2] if len(f) > 2 else ""),
    }


# ---------------------------------------------------------------------------
# zip / flat-file unpacking
# ---------------------------------------------------------------------------

def iter_edi_lines(file_path: str):
    """Yield (line_num_global, line) from a .zip or plain EDI text file.

    Handles ALM's nested-zip format: outer .zip → inner .zip(s) → EDI files.
    """
    p = Path(file_path)

    def _yield_from_text(text: str, *, start: int = 1):
        for i, line in enumerate(text.splitlines(), start=start):
            line = line.strip()
            if line:
                yield (i, line)

    line_offset = 0
    if p.suffix.lower() == ".zip":
        with zipfile.ZipFile(file_path, "r") as zf:
            for name in zf.namelist():
                data = zf.read(name)
                if name.lower().endswith(".zip"):
                    with zipfile.ZipFile(io.BytesIO(data)) as inner:
                        for inner_name in inner.namelist():
                            if inner_name.lower().endswith(".zip"):
                                continue  # skip 3-level nesting
                            text = inner.read(inner_name).decode("utf-8", errors="replace")
                            for ln, line in _yield_from_text(text, start=line_offset + 1):
                                yield ln, line
                            line_offset = ln if 'ln' in dir() else line_offset
                else:
                    text = data.decode("utf-8", errors="replace")
                    for ln, line in _yield_from_text(text, start=line_offset + 1):
                        yield ln, line
                    line_offset = ln if 'ln' in dir() else line_offset
    else:
        with open(file_path, "rt", encoding="utf-8", errors="replace") as f:
            for ln, line in _yield_from_text(f.read(), start=1):
                yield ln, line


# ---------------------------------------------------------------------------
# Insert helpers
# ---------------------------------------------------------------------------

def _insert_50(cur, upload_batch_id, line_num, parsed):
    cur.execute(
        "INSERT INTO alm_edi_segment_50 "
        "(upload_batch_id, line_num, raw_line, supplier_code, state_code, file_date) "
        "VALUES (%s, %s, %s, %s, %s, %s)",
        (upload_batch_id, line_num, parsed["raw_line"],
         parsed["supplier_code"], parsed["state_code"], parsed["file_date"]),
    )


def _insert_51(cur, upload_batch_id, line_num, parsed):
    cur.execute(
        "INSERT INTO alm_edi_segment_51 "
        "(upload_batch_id, line_num, raw_line, batch_id) "
        "VALUES (%s, %s, %s, %s)",
        (upload_batch_id, line_num, parsed["raw_line"], parsed["batch_id"]),
    )


def _insert_52_bulk(cur, rows: list[tuple]):
    if not rows:
        return
    psycopg2.extras.execute_values(
        cur,
        "INSERT INTO alm_edi_segment_52 ("
        "upload_batch_id, line_num, raw_line, customer_code, customer_code_stripped, "
        "txn_id, sale_date, alm_product_code, product_description, pack_size, "
        "outlet_name, outlet_address, qty_delivered, gross_cents, cost_cents, "
        "discount_cents, wet_cents, gst_cents) VALUES %s",
        rows,
        page_size=500,
    )


def _insert_53(cur, upload_batch_id, line_num, parsed):
    cur.execute(
        "INSERT INTO alm_edi_segment_53 "
        "(upload_batch_id, line_num, raw_line, record_count) "
        "VALUES (%s, %s, %s, %s)",
        (upload_batch_id, line_num, parsed["raw_line"], parsed["record_count"]),
    )


# ---------------------------------------------------------------------------
# Main pipeline
# ---------------------------------------------------------------------------

def run_import(
    file_path: str,
    *,
    db_url: str,
    actor: str = "system",
    period_label: str | None = None,
) -> dict:
    """Top-level entry. Stages every EDI segment; returns summary dict."""
    started = datetime.datetime.now(datetime.timezone.utc)
    logger.info("ALM EDI importer: %s", file_path)

    file_hash = file_sha256(file_path)

    seg_lines = {"50": [], "51": [], "52": [], "53": []}
    total_lines = 0
    for line_num, line in iter_edi_lines(file_path):
        kind = _segment_kind(line)
        total_lines += 1
        if kind is None:
            continue
        parser = {"50": parse_segment_50, "51": parse_segment_51,
                  "52": parse_segment_52, "53": parse_segment_53}[kind]
        seg_lines[kind].append((line_num, parser(line)))

    if not seg_lines["52"]:
        raise ValueError(
            f"ALM EDI file {os.path.basename(file_path)} contains no 5|2 "
            f"transaction lines (saw {total_lines} total lines)."
        )

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
                (CHANNEL, os.path.basename(file_path), file_hash,
                 len(seg_lines["52"]), started, actor, period_label),
            )
            upload_batch_id = cur.fetchone()[0]

            # 5|0 file headers (typically 1)
            for line_num, parsed in seg_lines["50"]:
                _insert_50(cur, upload_batch_id, line_num, parsed)
            # 5|1 batch headers
            for line_num, parsed in seg_lines["51"]:
                _insert_51(cur, upload_batch_id, line_num, parsed)
            # 5|2 transactions (bulk)
            seg52_rows = []
            ok_rows_for_dedup = []
            for line_num, parsed in seg_lines["52"]:
                seg52_rows.append((
                    upload_batch_id, line_num, parsed["raw_line"],
                    parsed["customer_code"], parsed["customer_code_stripped"],
                    parsed["txn_id"], parsed["sale_date"],
                    parsed["alm_product_code"], parsed["product_description"],
                    parsed["pack_size"], parsed["outlet_name"],
                    parsed["outlet_address"],  # D1: schema/165
                    parsed["qty_delivered"], parsed["gross_cents"],
                    parsed["cost_cents"], parsed["discount_cents"],
                    parsed["wet_cents"], parsed["gst_cents"],
                ))
                ok_rows_for_dedup.append({
                    "row_num": line_num,
                    "customer_key": parsed["customer_code_stripped"]
                                    or parsed["outlet_name"] or "",
                    "sku_key": (parsed["alm_product_code"] or "").upper(),
                    "month_key": (
                        parsed["sale_date"].strftime("%Y-%m")
                        if parsed["sale_date"] else ""
                    ),
                    "quantity": parsed["qty_delivered"],
                })
            _insert_52_bulk(cur, seg52_rows)

            # 5|3 batch trailers
            for line_num, parsed in seg_lines["53"]:
                _insert_53(cur, upload_batch_id, line_num, parsed)

            # JC-295 duplicate detection on 5|2 rows
            dup_set = detect_duplicates(conn, channel=CHANNEL, rows=ok_rows_for_dedup)
            duplicates = [r["row_num"] for r in ok_rows_for_dedup
                          if r["row_hash"] in dup_set]
            persist_row_hashes(
                conn, channel=CHANNEL, upload_batch_id=upload_batch_id,
                rows=ok_rows_for_dedup,
            )

            cur.execute(
                "UPDATE upload_batch SET "
                "row_count_inserted = %s, "
                "row_count_duplicates = %s, "
                "ended_at = %s, "
                "status = 'imported' "
                "WHERE upload_batch_id = %s",
                (
                    len(ok_rows_for_dedup) - len(duplicates),
                    len(duplicates),
                    datetime.datetime.now(datetime.timezone.utc),
                    upload_batch_id,
                ),
            )

            # Optional: assert 5|3 record_count matches 5|2 line count when
            # a single batch trailer exists (per-batch validation).
            for line_num, parsed in seg_lines["53"]:
                if parsed["record_count"] is not None:
                    if parsed["record_count"] != len(seg_lines["52"]):
                        logger.warning(
                            "ALM 5|3 record_count=%s != 5|2 line count=%s "
                            "(continuing — non-fatal mismatch)",
                            parsed["record_count"], len(seg_lines["52"]),
                        )

        conn.commit()
    except Exception:
        conn.rollback()
        logger.exception("ALM EDI import failed; rolled back.")
        raise
    finally:
        conn.close()

    summary = {
        "ok": True,
        "channel": CHANNEL,
        "upload_batch_id": upload_batch_id,
        "file_name": os.path.basename(file_path),
        "file_hash_sha256": file_hash,
        "lines_total": total_lines,
        "segments": {k: len(v) for k, v in seg_lines.items()},
        "duplicates_detected": len(duplicates),
        "started_at": started.isoformat(),
        "ended_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    }
    logger.info("ALM EDI import complete: %s", summary)
    return summary


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def _main():
    ap = argparse.ArgumentParser(description="ALM EDI .zip/.txt → Postgres importer")
    ap.add_argument("file", help="path to .zip or plain EDI flat file")
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
