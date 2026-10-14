"""
Direct Sales CSV Importer for Moppity Vineyards.

Parses a CSV file exported from Vinsight containing direct invoice sales data
and inserts validated rows into the sales_transaction table. Direct sales are
invoiced through Vinsight — revenue recognised on invoice.

Handles the Vinsight "Sales Detail" export format where the first row is a
title line ("Sales Detail"), followed by a blank row, then the actual CSV
header row.

Usage:
    DATABASE_URL=postgresql://... python -m etl.import_direct path/to/direct_export.csv
"""

import csv
import datetime
import json
import logging
import os
import sys
import time
from decimal import Decimal, InvalidOperation

import psycopg2
import psycopg2.extras

from etl.logger import log_etl_run, log_dead_letter
from connectors.vinsight_direct_filter import should_include_direct

logger = logging.getLogger("moppity.etl.import_direct")

SOURCE_SYSTEM = "DIRECT"
SOURCE_SYSTEM_LOWER = "direct"

# feed includes channel-transfer rows that are NOT genuine direct sales — they
# are intra-channel stock movements that belong to the DWS/ALM channels and
# would double-count revenue if imported as Direct. Per the owner's spec, exclude
# ONLY:
#   - ALM transfer dummies: ALM Fyshwick / Huntingwood / Laverton
#   - DWS transfer dummies: any customer name starting with "DWS " (covers
#     "DWS NSW", "DWS QLD", "DWS Victoria", "DWS WA", etc., plus the brand
#     "Domaine Wine Shippers")
#   - Mail-order: customer category ML (mail-order subscription drops handled
#     elsewhere)
# Match is case-insensitive, against the trimmed customer name.
CHANNEL_TRANSFER_EXACT = {
    "ALM FYSHWICK",
    "ALM HUNTINGWOOD",
    "ALM LAVERTON",
}
CHANNEL_TRANSFER_PREFIX = (
    "DWS ",  # DWS NSW, DWS QLD, DWS VICTORIA, DWS WA, ...
    "DOMAINE WINE SHIPPERS",
    "MAIL ORDER",
)


def is_channel_transfer_customer(customer_name: str) -> bool:
    """B4 JC-047: True if this Direct row is a channel-transfer dummy that
    should NOT be imported as Direct sales (would double-count vs DWS/ALM)."""
    if not customer_name:
        return False
    n = customer_name.strip().upper()
    if n in CHANNEL_TRANSFER_EXACT:
        return True
    return any(n.startswith(p) for p in CHANNEL_TRANSFER_PREFIX)

# BUG-24: batch size for execute_values — 500 rows per round-trip.
BATCH_SIZE = 500

# Column list for sales_transaction inserts. Keep in sync with the tuple
# ordering produced by _prepare_row.
#
# BUG-113 Option D: content_hash is the 15th column, computed SQL-side by
# SHA256 over (source_system, source_ref, sku_id, customer_id, sale_date,
# quantity). The hash bindings are appended to every row tuple (6 extra
# values after the 14 column values — see _prepare_row). ON CONFLICT
# (content_hash) DO NOTHING makes every INSERT idempotent across re-runs.
# Hash expression MUST byte-match schema/049 part1 backfill.
_SALES_INSERT_COLUMNS = (
    "sku_id", "customer_id", "channel_id",
    "sale_date", "period", "quantity", "unit_price",
    "discount_amount", "rebate_amount", "wholesale_fee",
    "gross_revenue", "net_revenue", "source_system", "source_ref",
    "warehouse",
    "stock_unit",
    "content_hash",
)
# R-001: warehouse is column 15 (positional), constant 'Direct' for this writer
# (note: SOURCE_SYSTEM is upper-case 'DIRECT' but warehouse is mixed-case
# 'Direct' to match the existing 16,217 already-populated rows).
_SALES_VALUES_TEMPLATE = (
    "(%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, "
    "%s, %s, "
    "encode("
    "sha256(("
    "coalesce(%s, '') || '|' || coalesce(%s, '') || '|' || "
    "coalesce((%s::int)::text, '') || '|' || "
    "coalesce((%s::int)::text, '') || '|' || "
    "(%s::date)::text || '|' || "
    "(%s::decimal(12,2))::text"
    ")::bytea), 'hex'))"
)
_SALES_INSERT_SQL_VALUES = (
    "INSERT INTO sales_transaction ("
    + ", ".join(_SALES_INSERT_COLUMNS)
    + ") VALUES %s ON CONFLICT (content_hash) DO NOTHING"
)
_SALES_INSERT_SQL_SINGLE = (
    "INSERT INTO sales_transaction ("
    + ", ".join(_SALES_INSERT_COLUMNS)
    + ") VALUES "
    + _SALES_VALUES_TEMPLATE
    + " ON CONFLICT (content_hash) DO NOTHING"
)


class DirectImporter:
    """Imports Vinsight direct sales CSV exports into sales_transaction."""

    # Expected columns in the Vinsight direct export CSV. Keys are normalised.
    EXPECTED_COLUMNS = {
        # SKU
        "sku": "sku_code",
        "sku code": "sku_code",
        "item code": "sku_code",
        "product code": "sku_code",
        "stockitemcode": "sku_code",
        "stock item code": "sku_code",
        "itemcode": "sku_code",
        # Customer
        "customer": "customer_name",
        "customer name": "customer_name",
        "contact": "customer_name",
        "contact name": "customer_name",
        "contactname": "customer_name",
        "account": "customer_name",
        # Date
        "date": "sale_date",
        "sale date": "sale_date",
        "invoice date": "sale_date",
        "invoicedate": "sale_date",
        "order date": "sale_date",
        "orderdate": "sale_date",
        # Quantity
        "quantity": "quantity",
        "qty": "quantity",
        "cases": "quantity",
        # Price
        "unit price": "unit_price",
        "unitprice": "unit_price",
        "price": "unit_price",
        # Discount (Vinsight exports percentage like "37%")
        "discount": "discount_pct",
        "discount amount": "discount_amount",
        "discountamount": "discount_amount",
        # Net price (per-unit price after discount)
        "net price": "net_price",
        # Revenue (total net value = qty * net_price)
        "revenue": "revenue",
        # Rebate
        "rebate": "rebate_amount",
        "rebate amount": "rebate_amount",
        # Reference
        "invoice": "source_ref",
        "invoice number": "source_ref",
        "invoice no": "source_ref",
        "invoicenumber": "source_ref",
        "reference": "source_ref",
        "ref": "source_ref",
        "order number": "source_ref",
        "order num": "source_ref",
        "ordernumber": "source_ref",
        "salesordernumber": "source_ref",
        "sales order number": "source_ref",
    }

    def __init__(self, db_connection_string: str):
        self.db_connection_string = db_connection_string
        self._conn = None
        # B12.1 / JC-047: per-customer-name lookup of (is_moppity_customer,
        # contact_category) loaded once from staging_vinsight_contacts so
        # _prepare_row can apply should_include_direct without a per-row JOIN.
        self._customer_filter_cache: dict[str, tuple[bool | None, str | None]] | None = None

    def _load_customer_filter(self, cursor) -> dict[str, tuple[bool | None, str | None]]:
        """B12.1 / JC-047: pull (is_moppity_customer, ContactCategory) keyed
        by uppercased contact name. Cached per importer instance.

        Returns an empty dict if the staging table is missing or has no
        rows — which leaves _prepare_row to fall back on its built-in
        name-based exclusions only."""
        if self._customer_filter_cache is not None:
            return self._customer_filter_cache
        cache: dict[str, tuple[bool | None, str | None]] = {}
        try:
            cursor.execute(
                """
                SELECT
                  COALESCE(raw_data->>'ContactCode',
                           raw_data->>'LegalName',
                           raw_data->>'CompanyName',
                           raw_data->>'ContactName')          AS contact_name,
                  is_moppity_customer,
                  raw_data->>'ContactCategory'                AS contact_category
                FROM staging_vinsight_contacts
                """
            )
            for name, flag, cat in cursor.fetchall():
                if not name:
                    continue
                key = name.strip().upper()
                if key and key not in cache:
                    cache[key] = (flag, cat)
        except psycopg2.Error as exc:
            logger.warning(
                "Could not load staging_vinsight_contacts customer filter "
                "(%s) — falling back to in-file rules only.", exc,
            )
            cache = {}
        self._customer_filter_cache = cache
        return cache

    def _get_connection(self) -> "psycopg2.extensions.connection":
        if self._conn is None or self._conn.closed:
            self._conn = psycopg2.connect(self.db_connection_string)
        return self._conn

    def _close_connection(self):
        if self._conn and not self._conn.closed:
            self._conn.close()
            self._conn = None

    # ------------------------------------------------------------------
    # Lookup helpers
    # ------------------------------------------------------------------

    def _lookup_sku(self, cursor, external_code: str) -> int | None:
        cursor.execute(
            "SELECT sku_id FROM sku_code_map "
            "WHERE source_system = %s AND LOWER(external_code) = LOWER(%s)",
            (SOURCE_SYSTEM_LOWER, external_code),
        )
        row = cursor.fetchone()
        if row:
            return row[0]
        # Fallback: Direct exports use Moppity canonical codes
        cursor.execute(
            "SELECT sku_id FROM sku WHERE LOWER(sku_code) = LOWER(%s)",
            (external_code,),
        )
        row = cursor.fetchone()
        return row[0] if row else None

    def _lookup_customer(self, cursor, external_name: str) -> int | None:
        # BUG-127 / ADR-017: this importer is LOOKUP-ONLY for customer rows —
        # it never INSERTs into customer. Unrecognised customers cause
        # sales_transaction rows to be inserted with customer_id=NULL and
        # surface via dead-letter for manual reconciliation. New customer
        # rows are created via /api/customers POST (Import Wizard "+ New
        # Customer"), which hardcodes warehouse_channel='Direct' when the
        # request body sets source_system='direct'. So warehouse_channel
        # invariant for Direct-origin customers holds without modification here.
        cursor.execute(
            "SELECT customer_id FROM customer_code_map "
            "WHERE source_system = %s AND LOWER(external_name) = LOWER(%s)",
            (SOURCE_SYSTEM_LOWER, external_name),
        )
        row = cursor.fetchone()
        if row:
            return row[0]
        # Fallback: direct match on canonical customer name
        cursor.execute(
            "SELECT customer_id FROM customer WHERE LOWER(customer_name) = LOWER(%s)",
            (external_name,),
        )
        row = cursor.fetchone()
        return row[0] if row else None

    def _lookup_channel_id(self, cursor) -> int:
        cursor.execute(
            "SELECT channel_id FROM channel WHERE channel_name = %s",
            ("Direct",),
        )
        row = cursor.fetchone()
        if not row:
            raise RuntimeError("Channel 'Direct' not found in channel table.")
        return row[0]

    def _is_duplicate(self, cursor, source_ref: str) -> bool:
        if not source_ref:
            return False
        cursor.execute(
            "SELECT 1 FROM sales_transaction "
            "WHERE source_system = %s AND source_ref = %s LIMIT 1",
            (SOURCE_SYSTEM, source_ref),
        )
        return cursor.fetchone() is not None

    # ------------------------------------------------------------------
    # Parsing helpers
    # ------------------------------------------------------------------

    @staticmethod
    def _normalise_header(header_value: str) -> str:
        if not header_value:
            return ""
        return header_value.strip().lower()

    @staticmethod
    def _parse_date(value: str) -> datetime.date | None:
        if not value or not value.strip():
            return None
        text = value.strip()
        for fmt in ("%Y-%m-%d", "%d/%m/%Y", "%d-%m-%Y", "%m/%d/%Y",
                     "%d %b %Y", "%d %B %Y", "%Y-%m-%dT%H:%M:%S",
                     "%Y-%m-%d %H:%M:%S"):
            try:
                return datetime.datetime.strptime(text, fmt).date()
            except ValueError:
                continue
        return None

    @staticmethod
    def _parse_decimal(value: str) -> Decimal | None:
        if not value or not value.strip():
            return None
        text = value.strip().replace(",", "").replace("$", "")
        if not text:
            return None
        try:
            return Decimal(text)
        except InvalidOperation:
            return None

    @staticmethod
    def _parse_percentage(value: str) -> Decimal | None:
        """Parse a percentage string like '37%' to Decimal('0.37')."""
        if not value or not value.strip():
            return None
        text = value.strip()
        if text.endswith("%"):
            text = text[:-1].strip()
            try:
                return Decimal(text) / Decimal("100")
            except InvalidOperation:
                return None
        return None

    @staticmethod
    def _derive_period(sale_date: datetime.date) -> str:
        return sale_date.strftime("%Y-%m")

    # ------------------------------------------------------------------
    # Column mapping
    # ------------------------------------------------------------------

    def _find_header_row(self, all_rows: list[list[str]]) -> tuple[int, list[str]]:
        """Find the actual header row, skipping title/blank lines.

        Vinsight exports start with a title line ("Sales Detail") and a blank
        row before the actual CSV headers. This method scans the first few
        rows to find the one that looks like column headers.
        """
        for idx, row in enumerate(all_rows[:10]):
            # A header row should have multiple non-empty cells
            non_empty = [c for c in row if c and c.strip()]
            if len(non_empty) < 3:
                continue
            # Check if any known column names are present
            normalised = [self._normalise_header(c) for c in row]
            matches = sum(1 for n in normalised if n in self.EXPECTED_COLUMNS)
            if matches >= 3:
                return idx, row
        # Fall back to first row
        return 0, all_rows[0]

    def _map_columns(self, header_row: list[str]) -> dict[str, int]:
        mapping = {}
        for idx, cell_value in enumerate(header_row):
            normalised = self._normalise_header(cell_value)
            if normalised in self.EXPECTED_COLUMNS:
                field = self.EXPECTED_COLUMNS[normalised]
                if field not in mapping:
                    mapping[field] = idx
        return mapping

    # ------------------------------------------------------------------
    # Main import logic
    # ------------------------------------------------------------------

    def import_file(
        self,
        file_path: str,
        *,
        excluded_rows: set[int] | None = None,
    ) -> dict:
        """Run Direct CSV import.

        excluded_rows (D3 / 2026-05-11 / JF-13): 1-based preview row numbers
        the user unchecked in the Import Wizard preview UI. Skipped before
        insert; counted in result['rows_excluded']. Preview row_num for
        Direct is 1-based on post-header rows (etl/preview.py:parse_direct_csv
        enumerate start=1); this importer uses CSV-line-number row_num (start=
        header_idx + 2) for error messages, so we maintain a parallel
        preview_row_num counter.
        """
        logger.info("Starting Direct import from %s", file_path)
        excluded_rows = set(excluded_rows or [])
        if excluded_rows:
            logger.info(
                "Direct import: %d preview row(s) excluded by user (D3)",
                len(excluded_rows),
            )

        if not os.path.isfile(file_path):
            raise FileNotFoundError(f"Direct sales CSV not found: {file_path}")

        conn = self._get_connection()
        result = {
            "rows_imported": 0, "rows_skipped": 0,
            "rows_excluded": 0, "errors": [],
        }
        run_id = None

        try:
            with open(file_path, "r", encoding="utf-8-sig", newline="") as f:
                sample = f.read(8192)
                f.seek(0)
                try:
                    dialect = csv.Sniffer().sniff(sample, delimiters=",\t;|")
                except csv.Error:
                    dialect = csv.excel
                reader = csv.reader(f, dialect)
                all_rows = list(reader)

            if not all_rows:
                raise ValueError("Direct CSV is empty — no rows found.")

            # --- Find actual header row (skip title/blank lines) ---
            header_idx, header_row = self._find_header_row(all_rows)
            col_map = self._map_columns(header_row)

            if "sku_code" not in col_map:
                raise ValueError(
                    f"Cannot find SKU column in Direct CSV. "
                    f"Headers found: {header_row}"
                )
            if "sale_date" not in col_map:
                raise ValueError(
                    f"Cannot find date column in Direct CSV. "
                    f"Headers found: {header_row}"
                )

            data_rows = all_rows[header_idx + 1:]
            data_rows = [r for r in data_rows if any(cell.strip() for cell in r)]

            logger.info(
                "Direct CSV: %d data rows (header at row %d), columns mapped: %s",
                len(data_rows), header_idx + 1, list(col_map.keys()),
            )

            with conn.cursor() as cur:
                channel_id = self._lookup_channel_id(cur)

                # BUG-24: batch accumulator. Phase 1 does lookups + tuple
                # builds; Phase 2 bulk-inserts via execute_values in chunks
                # of BATCH_SIZE, with per-row SAVEPOINT fallback on batch
                # failure (preserves BUG-09/10 dead-letter semantics).
                pending_inserts: list[tuple] = []
                seen_refs: set[str] = set()  # intra-file dedup
                batch_counter = {"n": 0}

                def flush_batch() -> None:
                    if not pending_inserts:
                        return
                    batch_counter["n"] += 1
                    batch_no = batch_counter["n"]
                    batch_size = len(pending_inserts)
                    t0 = time.monotonic()
                    try:
                        cur.execute("SAVEPOINT batch_sp")
                        psycopg2.extras.execute_values(
                            cur,
                            _SALES_INSERT_SQL_VALUES,
                            pending_inserts,
                            template=_SALES_VALUES_TEMPLATE,
                            page_size=BATCH_SIZE,
                        )
                        cur.execute("RELEASE SAVEPOINT batch_sp")
                        elapsed = time.monotonic() - t0
                        logger.info(
                            "Direct batch %d: %d rows in %.3fs",
                            batch_no, batch_size, elapsed,
                        )
                    except psycopg2.Error as batch_exc:
                        cur.execute("ROLLBACK TO SAVEPOINT batch_sp")
                        logger.warning(
                            "Direct batch %d failed (%s) — falling back to "
                            "per-row inserts for %d rows",
                            batch_no, batch_exc, batch_size,
                        )
                        landed = 0
                        for tup in pending_inserts:
                            try:
                                cur.execute("SAVEPOINT fallback_sp")
                                cur.execute(_SALES_INSERT_SQL_SINGLE, tup)
                                cur.execute("RELEASE SAVEPOINT fallback_sp")
                                landed += 1
                            except psycopg2.Error as row_exc:
                                cur.execute("ROLLBACK TO SAVEPOINT fallback_sp")
                                result["rows_imported"] -= 1
                                result["errors"].append(
                                    f"Direct batch {batch_no} fallback row "
                                    f"(source_ref={tup[-1]!r}) failed: {row_exc}"
                                )
                        logger.info(
                            "Direct batch %d fallback: %d/%d rows landed",
                            batch_no, landed, batch_size,
                        )
                    finally:
                        pending_inserts.clear()

                # D3: parallel preview_row_num (start=1) matches the UI's
                # 1-based row_num from etl/preview.py:parse_direct_csv.
                for preview_row_num, (row_num, row) in enumerate(
                    enumerate(data_rows, start=header_idx + 2), start=1
                ):
                    if preview_row_num in excluded_rows:
                        result["rows_excluded"] += 1
                        continue
                    try:
                        cur.execute("SAVEPOINT row_sp")
                        tup = self._prepare_row(
                            cur, row, col_map, channel_id, row_num, result,
                            seen_refs,
                        )
                        cur.execute("RELEASE SAVEPOINT row_sp")
                    except Exception as exc:
                        cur.execute("ROLLBACK TO SAVEPOINT row_sp")
                        error_msg = f"Row {row_num}: unexpected error — {exc}"
                        result["errors"].append(error_msg)
                        logger.error(error_msg)
                        continue

                    if tup is None:
                        continue

                    pending_inserts.append(tup)
                    result["rows_imported"] += 1
                    if len(pending_inserts) >= BATCH_SIZE:
                        flush_batch()

                # Final partial batch
                flush_batch()

            conn.commit()

            status = "success" if not result["errors"] else "partial"
            error_detail = "\n".join(result["errors"][:50]) if result["errors"] else None
            run_id = log_etl_run(
                conn,
                source="direct_upload",
                endpoint=os.path.basename(file_path),
                status=status,
                rows_processed=result["rows_imported"],
                rows_skipped=result["rows_skipped"],
                error_count=len(result["errors"]),
                error_detail=error_detail,
            )

            if run_id and result["errors"]:
                for error_msg in result["errors"]:
                    log_dead_letter(
                        conn, run_id=run_id, source="direct_upload",
                        raw_data={"error": error_msg}, error_message=error_msg,
                    )

            logger.info(
                "Direct import complete: imported=%d skipped=%d errors=%d",
                result["rows_imported"], result["rows_skipped"], len(result["errors"]),
            )

        except Exception as exc:
            conn.rollback()
            error_msg = f"Direct import failed: {exc}"
            logger.error(error_msg)
            result["errors"].append(error_msg)
            try:
                log_etl_run(
                    conn, source="direct_upload",
                    endpoint=os.path.basename(file_path) if file_path else "unknown",
                    status="error",
                    rows_processed=result["rows_imported"],
                    rows_skipped=result["rows_skipped"],
                    error_count=len(result["errors"]),
                    error_detail=error_msg,
                )
            except Exception:
                logger.exception("Failed to log ETL run after error")
            raise
        finally:
            self._close_connection()

        return result

    def _prepare_row(
        self,
        cursor,
        row: list[str],
        col_map: dict[str, int],
        channel_id: int,
        row_num: int,
        result: dict,
        seen_refs: set[str],
    ) -> tuple | None:
        """Validate a Direct row and return the sales_transaction tuple.

        BUG-24: split from the old _process_row so INSERTs can be batched.
        Returns None if the row should be skipped (empty, duplicate, or
        validation failure). Preserves BUG-09/BUG-10 dead-letter semantics:
        unknown SKU/customer still yields an insert tuple with NULL and an
        error appended to result["errors"].

        `seen_refs` tracks intra-file source_refs (previously caught by the
        duplicate check against the open txn's uncommitted rows, which no
        longer works with batched inserts).
        """
        def _get(field: str) -> str:
            idx = col_map.get(field)
            if idx is None or idx >= len(row):
                return ""
            return row[idx]

        # --- Extract fields ---
        raw_sku = _get("sku_code")
        raw_customer = _get("customer_name")
        raw_date = _get("sale_date")
        raw_qty = _get("quantity")
        raw_price = _get("unit_price")
        raw_discount_pct = _get("discount_pct")
        raw_discount_amt = _get("discount_amount")
        raw_rebate = _get("rebate_amount")
        raw_ref = _get("source_ref")
        raw_revenue = _get("revenue")

        # --- Validate required fields ---
        sku_code = raw_sku.strip()
        customer_name = raw_customer.strip()

        if not sku_code:
            result["errors"].append(f"Row {row_num}: missing SKU code")
            return None

        # B4 JC-046/JC-047: skip channel-transfer customers (DWS NSW/QLD/...,
        # ALM Fyshwick/Huntingwood/Laverton, mail-order). These are intra-
        # channel stock movements, not direct sales — importing them would
        # double-count against DWS/ALM channel imports.
        # B12.1 (2026-04-29): consult should_include_direct (which adds the
        # ContactCategory ML / DWS exclusion check) using the cached
        # staging_vinsight_contacts category lookup, plus the
        # is_moppity_customer flag set by filter_vinsight_moppity_customers.
        # Falls back to is_channel_transfer_customer when staging has no
        # entry for this customer (e.g. brand-new contact during a backfill).
        cust_filter = self._load_customer_filter(cursor)
        cust_key = customer_name.strip().upper() if customer_name else ""
        is_moppity, contact_category = cust_filter.get(cust_key, (None, None))
        if is_moppity is False:
            logger.debug(
                "Row %d: skipped non-Moppity Vinsight contact '%s' "
                "(is_moppity_customer=false)", row_num, customer_name,
            )
            result["rows_skipped"] += 1
            return None
        if not should_include_direct(customer_name, contact_category):
            logger.debug(
                "Row %d: skipped channel-transfer / mail-order customer '%s' "
                "(should_include_direct=False)", row_num, customer_name,
            )
            result["rows_skipped"] += 1
            return None
        # Belt-and-braces: keep original name-only check for any contact
        # missing from staging entirely.
        if is_moppity is None and is_channel_transfer_customer(customer_name):
            logger.debug(
                "Row %d: skipped channel-transfer customer '%s' (name-only)",
                row_num, customer_name,
            )
            result["rows_skipped"] += 1
            return None

        sale_date = self._parse_date(raw_date)
        if sale_date is None:
            result["errors"].append(
                f"Row {row_num}: invalid or missing date — raw value: {raw_date!r}"
            )
            return None

        quantity = self._parse_decimal(raw_qty)
        if quantity is None:
            result["errors"].append(
                f"Row {row_num}: invalid or missing quantity — raw value: {raw_qty!r}"
            )
            return None

        # --- Optional fields ---
        unit_price = self._parse_decimal(raw_price)
        rebate_amount = self._parse_decimal(raw_rebate) or Decimal("0")
        wholesale_fee = Decimal("0")
        source_ref = raw_ref.strip() if raw_ref else None

        # --- Discount: handle both percentage ("37%") and dollar amounts ---
        discount_amount = Decimal("0")
        discount_pct = self._parse_percentage(raw_discount_pct)
        if discount_pct is not None and unit_price is not None:
            discount_amount = (quantity * unit_price * discount_pct).quantize(Decimal("0.01"))
        elif raw_discount_amt:
            discount_amount = self._parse_decimal(raw_discount_amt) or Decimal("0")

        # --- Gross revenue (before deductions) ---
        if unit_price is not None:
            gross_revenue = (quantity * unit_price).quantize(Decimal("0.01"))
        else:
            gross_revenue = None

        # --- Net revenue = gross - discount - rebate - fee (M3-09) ---
        revenue = self._parse_decimal(raw_revenue)
        if revenue is not None:
            net_revenue = revenue
        elif gross_revenue is not None:
            net_revenue = gross_revenue - discount_amount - rebate_amount - wholesale_fee
        else:
            net_revenue = None

        # --- Generate unique source_ref ---
        # If source_ref came from "Order Num", it's shared across line items.
        # Append SKU code to make it unique per line.
        if source_ref:
            source_ref = f"{source_ref}-{sku_code}"
        else:
            source_ref = f"DIRECT-{sale_date.isoformat()}-{sku_code}-{row_num}"

        # --- Duplicate check: committed DB first, then intra-file ---
        if self._is_duplicate(cursor, source_ref):
            result["rows_skipped"] += 1
            return None
        if source_ref in seen_refs:
            result["rows_skipped"] += 1
            return None
        seen_refs.add(source_ref)

        # --- SKU lookup ---
        # BUG-09/BUG-10: unknown SKUs still get inserted with sku_id=NULL so
        # the upload wizard can surface them for manual mapping.
        sku_id = self._lookup_sku(cursor, sku_code)
        if sku_id is None:
            result["errors"].append(
                f"Row {row_num}: unrecognised Direct SKU code '{sku_code}' — "
                f"row inserted with sku_id=NULL."
            )

        # --- Customer lookup ---
        customer_id = None
        if customer_name:
            customer_id = self._lookup_customer(cursor, customer_name)
            if customer_id is None:
                result["errors"].append(
                    f"Row {row_num}: unrecognised Direct customer '{customer_name}' — "
                    f"row inserted with customer_id=NULL."
                )

        period = self._derive_period(sale_date)

        # BUG-113 Option D: append 6 content_hash bindings in the exact order
        # expected by _SALES_VALUES_TEMPLATE's SHA256 expression:
        # (source_system, source_ref, sku_id, customer_id, sale_date, quantity).
        # BUG-118 / ADR-014: Direct = Vinsight invoice export, always cases.
        return (
            sku_id, customer_id, channel_id,
            sale_date, period, quantity, unit_price,
            discount_amount, rebate_amount, wholesale_fee,
            gross_revenue, net_revenue, SOURCE_SYSTEM, source_ref,
            "Direct",
            "case",
            SOURCE_SYSTEM, source_ref, sku_id, customer_id, sale_date, quantity,
        )


if __name__ == "__main__":
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    )

    db_url = os.environ.get("DATABASE_URL")
    if not db_url:
        print("ERROR: DATABASE_URL environment variable is not set.", file=sys.stderr)
        sys.exit(1)

    if len(sys.argv) < 2:
        print("Usage: python -m etl.import_direct <path_to_direct_export.csv>", file=sys.stderr)
        sys.exit(1)

    file_path = sys.argv[1]

    importer = DirectImporter(db_url)
    try:
        result = importer.import_file(file_path)
        print(f"Direct import complete: {result['rows_imported']} imported, "
              f"{result['rows_skipped']} skipped, {len(result['errors'])} errors")
        if result["errors"]:
            print("\nErrors:")
            for err in result["errors"][:20]:
                print(f"  - {err}")
            if len(result["errors"]) > 20:
                print(f"  ... and {len(result['errors']) - 20} more")
    except Exception as exc:
        print(f"FATAL: {exc}", file=sys.stderr)
        sys.exit(1)
