"""
DWS Monthly Report Importer for Moppity Vineyards.

Parses the monthly DWS sell-through Excel report and inserts validated rows
into the sales_transaction table. DWS is a consignment channel — Moppity
retains stock ownership until sell-through.

The DWS report uses non-standard column names (STOCKITEM, DRNAME, GROSSVAL,
DISCVAL, CARTONS, REFNO, etc.) — this importer maps them to our schema.

Note: "Y&R" (Young & Rashleigh) is the legacy name for DWS in the Access DB.

Usage:
    DATABASE_URL=postgresql://... python -m etl.import_dws path/to/dws_report.xlsx
"""

import datetime
import json
import logging
import os
import sys
import time
from decimal import Decimal, InvalidOperation

import openpyxl
import psycopg2
import psycopg2.extras

from etl.logger import log_etl_run, log_dead_letter

logger = logging.getLogger("moppity.etl.import_dws")

SOURCE_SYSTEM = "DWS"
SOURCE_SYSTEM_LOWER = "dws"

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
# R-001: warehouse is column 15 (positional), constant 'DWS' for this writer.
# Not part of content_hash (classifier, not identity). Required so /sales
# warehouse filter + chart-bar groupings see the row.
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


class DWSImporter:
    """Imports DWS monthly sell-through Excel reports into sales_transaction."""

    # Maps normalised column headers → internal field names.
    # Covers both generic names and DWS-specific names (STOCKITEM, DRNAME, etc.)
    EXPECTED_COLUMNS = {
        # SKU — DWS uses "STOCKITEM" or "STKALIAS"
        "sku": "sku_code",
        "sku code": "sku_code",
        "item code": "sku_code",
        "product code": "sku_code",
        "stockitem": "sku_code",
        "stkalias": "sku_code",
        # Customer — DWS uses "DRNAME" (debtor name)
        "customer": "customer_name",
        "customer name": "customer_name",
        "account": "customer_name",
        "account name": "customer_name",
        "drname": "customer_name",
        # Date
        "date": "sale_date",
        "sale date": "sale_date",
        "invoice date": "sale_date",
        # Quantity — DWS has QUANTITY (bottles), CARTONS (cases), BOTTLES, LITRES
        # We prefer CARTONS (cases) for consistency with other channels
        "cartons": "quantity",
        "quantity": "quantity_bottles",
        "cases": "quantity",
        "qty": "quantity",
        # Value fields — DWS uses GROSSVAL, DISCVAL, COSTVAL, WETVAL, GSTVAL
        "unit price": "unit_price",
        "price": "unit_price",
        "grossval": "gross_value",
        "discval": "discount_amount",
        "discount": "discount_amount",
        "discount amount": "discount_amount",
        "costval": "cost_value",
        "wetval": "wet_value",
        "gstval": "gst_value",
        "staxval": "stax_value",
        "rebate": "rebate_amount",
        "rebate amount": "rebate_amount",
        "wholesale fee": "wholesale_fee",
        "fee": "wholesale_fee",
        # Reference — DWS uses "REFNO"
        "refno": "source_ref",
        "invoice": "source_ref",
        "invoice number": "source_ref",
        "invoice no": "source_ref",
        "reference": "source_ref",
        "ref": "source_ref",
        # Informational (extracted but not required)
        "srepname": "rep_name",
        "srep": "rep_code",
        "sarea": "territory_code",
        "sareaname": "territory_name",
        "stkdesc1": "description",
    }

    def __init__(self, db_connection_string: str):
        self.db_connection_string = db_connection_string
        self._conn = None

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

    def _cache_sku_mapping(self, cursor, sku_id: int, external_code: str):
        """Auto-cache a resolved SKU mapping so future lookups are instant."""
        try:
            cursor.execute(
                "INSERT INTO sku_code_map (sku_id, source_system, external_code) "
                "VALUES (%s, %s, %s) ON CONFLICT (source_system, external_code) DO NOTHING",
                (sku_id, SOURCE_SYSTEM_LOWER, external_code),
            )
        except Exception:
            pass  # Non-critical — caching failure shouldn't block import

    def _lookup_sku(self, cursor, external_code: str, description: str = None) -> int | None:
        # 1. Try sku_code_map (fastest — cached mappings)
        cursor.execute(
            "SELECT sku_id FROM sku_code_map "
            "WHERE source_system = %s AND LOWER(external_code) = LOWER(%s)",
            (SOURCE_SYSTEM_LOWER, external_code),
        )
        row = cursor.fetchone()
        if row:
            return row[0]

        # 2. Fallback: try canonical sku table directly
        cursor.execute(
            "SELECT sku_id FROM sku WHERE LOWER(sku_code) = LOWER(%s)",
            (external_code,),
        )
        row = cursor.fetchone()
        if row:
            self._cache_sku_mapping(cursor, row[0], external_code)
            return row[0]

        # 3. Fallback: fuzzy match on description (for new/unknown DWS codes)
        if description:
            words = [w for w in description.upper().split() if len(w) > 2
                     and w not in ("750ML", "375ML", "200ML", "THE", "AND")]
            if len(words) >= 2:
                pattern = "%" + "%".join(words[:3]) + "%"
                cursor.execute(
                    "SELECT sku_id FROM sku WHERE UPPER(item_description) LIKE %s LIMIT 1",
                    (pattern,),
                )
                row = cursor.fetchone()
                if row:
                    self._cache_sku_mapping(cursor, row[0], external_code)
                    logger.info(
                        "Auto-mapped DWS code '%s' to sku_id=%d via description '%s'",
                        external_code, row[0], description,
                    )
                    return row[0]

        return None

    def _lookup_customer(self, cursor, external_name: str) -> int | None:
        # BUG-127 / ADR-017: this importer is LOOKUP-ONLY for customer rows —
        # it never INSERTs into customer. Unrecognised customers cause
        # sales_transaction rows to be inserted with customer_id=NULL and
        # surface via dead-letter for manual reconciliation. New customer
        # rows are created via /api/customers POST (Import Wizard "+ New
        # Customer"), which hardcodes warehouse_channel='DWS' when the
        # request body sets source_system='dws'. So warehouse_channel
        # invariant for DWS-origin customers holds without modification here.
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
            ("DWS",),
        )
        row = cursor.fetchone()
        if not row:
            raise RuntimeError("Channel 'DWS' not found in channel table.")
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
    def _normalise_header(header_value) -> str:
        if header_value is None:
            return ""
        return str(header_value).strip().lower()

    @staticmethod
    def _parse_date(value) -> datetime.date | None:
        if value is None:
            return None
        if isinstance(value, datetime.datetime):
            return value.date()
        if isinstance(value, datetime.date):
            return value
        text = str(value).strip()
        for fmt in ("%Y-%m-%d", "%d/%m/%Y", "%d-%m-%Y", "%m/%d/%Y", "%d %b %Y", "%d %B %Y"):
            try:
                return datetime.datetime.strptime(text, fmt).date()
            except ValueError:
                continue
        return None

    @staticmethod
    def _parse_decimal(value) -> Decimal | None:
        if value is None:
            return None
        if isinstance(value, (int, float)):
            return Decimal(str(value))
        text = str(value).strip().replace(",", "").replace("$", "")
        if not text:
            return None
        try:
            return Decimal(text)
        except InvalidOperation:
            return None

    @staticmethod
    def _derive_period(sale_date: datetime.date) -> str:
        return sale_date.strftime("%Y-%m")

    # ------------------------------------------------------------------
    # Column mapping
    # ------------------------------------------------------------------

    def _map_columns(self, header_row: list) -> dict[str, int]:
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
        """Run DWS XLSX import.

        excluded_rows (D3 / 2026-05-11 / JF-13): 1-based preview row numbers
        the user unchecked in the Import Wizard preview UI. Skipped before
        insert; counted in result['rows_excluded']. UI checkbox now matches
        backend reality.
        """
        logger.info("Starting DWS import from %s", file_path)
        excluded_rows = set(excluded_rows or [])
        if excluded_rows:
            logger.info(
                "DWS import: %d preview row(s) excluded by user (D3)",
                len(excluded_rows),
            )

        if not os.path.isfile(file_path):
            raise FileNotFoundError(f"DWS report file not found: {file_path}")

        conn = self._get_connection()
        result = {
            "rows_imported": 0, "rows_skipped": 0,
            "rows_excluded": 0, "errors": [],
        }
        run_id = None

        try:
            wb = openpyxl.load_workbook(file_path, read_only=True, data_only=True)
            ws = wb.active
            rows = list(ws.iter_rows(values_only=True))
            wb.close()

            if not rows:
                raise ValueError("DWS report is empty — no rows found.")

            header_row = rows[0]
            col_map = self._map_columns(list(header_row))

            if "sku_code" not in col_map:
                raise ValueError(
                    f"Cannot find SKU column in DWS report. "
                    f"Headers found: {[str(h) for h in header_row]}"
                )
            if "sale_date" not in col_map:
                raise ValueError(
                    f"Cannot find date column in DWS report. "
                    f"Headers found: {[str(h) for h in header_row]}"
                )

            data_rows = rows[1:]
            logger.info(
                "DWS report: %d data rows, columns mapped: %s",
                len(data_rows), list(col_map.keys()),
            )

            with conn.cursor() as cur:
                channel_id = self._lookup_channel_id(cur)

                # BUG-24: batch accumulator. Phase 1 (this loop) does all
                # lookups and builds tuples; Phase 2 (flush_batch) bulk-inserts
                # in chunks of BATCH_SIZE via execute_values, falling back to
                # per-row SAVEPOINTs on batch failure.
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
                            "DWS batch %d: %d rows in %.3fs",
                            batch_no, batch_size, elapsed,
                        )
                    except psycopg2.Error as batch_exc:
                        cur.execute("ROLLBACK TO SAVEPOINT batch_sp")
                        logger.warning(
                            "DWS batch %d failed (%s) — falling back to "
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
                                    f"DWS batch {batch_no} fallback row "
                                    f"(source_ref={tup[-1]!r}) failed: {row_exc}"
                                )
                        logger.info(
                            "DWS batch %d fallback: %d/%d rows landed",
                            batch_no, landed, batch_size,
                        )
                    finally:
                        pending_inserts.clear()

                # D3: preview UI uses 1-based row_num (start=1 in
                # etl/preview.py parse_dws_excel). Importer's row_num here
                # starts at 2 (matches Excel line). Maintain a parallel
                # preview_row_num to filter against excluded_rows.
                for preview_row_num, (row_num, row) in enumerate(
                    enumerate(data_rows, start=2), start=1
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
                source="dws_upload",
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
                        conn, run_id=run_id, source="dws_upload",
                        raw_data={"error": error_msg}, error_message=error_msg,
                    )

            logger.info(
                "DWS import complete: imported=%d skipped=%d errors=%d",
                result["rows_imported"], result["rows_skipped"], len(result["errors"]),
            )

        except Exception as exc:
            conn.rollback()
            error_msg = f"DWS import failed: {exc}"
            logger.error(error_msg)
            result["errors"].append(error_msg)
            try:
                log_etl_run(
                    conn, source="dws_upload",
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
        row: tuple,
        col_map: dict[str, int],
        channel_id: int,
        row_num: int,
        result: dict,
        seen_refs: set[str],
    ) -> tuple | None:
        """Validate a DWS row and return the sales_transaction tuple to insert.

        BUG-24: split from the old _process_row so INSERTs can be batched. The
        returned tuple is appended to pending_inserts in the caller and flushed
        via execute_values. Returns None if the row should be skipped (empty,
        duplicate, or validation failure).

        Preserves BUG-09/BUG-10 dead-letter semantics: rows with unknown SKU or
        customer still get queued for insert with sku_id=NULL / customer_id=NULL
        and an error appended to result["errors"] for dead-letter surfacing.

        `seen_refs` is the intra-file dedup set: if a source_ref was already
        queued earlier in this same file we skip the duplicate (previously the
        duplicate check ran against the open transaction's uncommitted rows;
        with batched inserts those rows don't exist yet, so we track in
        Python).
        """
        def _get(field: str):
            idx = col_map.get(field)
            if idx is None or idx >= len(row):
                return None
            return row[idx]

        # --- Extract fields ---
        raw_sku = _get("sku_code")
        raw_customer = _get("customer_name")
        raw_date = _get("sale_date")
        raw_qty = _get("quantity")             # CARTONS (cases) — preferred
        raw_qty_bottles = _get("quantity_bottles")  # QUANTITY (bottles) — fallback
        raw_price = _get("unit_price")
        raw_gross = _get("gross_value")        # GROSSVAL
        raw_discount = _get("discount_amount") # DISCVAL
        raw_rebate = _get("rebate_amount")
        raw_fee = _get("wholesale_fee")
        raw_ref = _get("source_ref")           # REFNO

        # --- Validate required fields ---
        sku_code = str(raw_sku).strip() if raw_sku is not None else ""
        customer_name = str(raw_customer).strip() if raw_customer is not None else ""

        # JR-081: Skip ALM warehouse rows that sometimes appear in DWS reports.
        # The UI auto-excludes these (ImportPreviewContext.tsx:438-460) but the
        # backend confirm path must enforce the same rule in case the UI is
        # bypassed (CLI, direct API, or wizard skip). Matches any customer
        # starting with "ALM " or containing any of the 4 known warehouse
        # names (Fyshwick / Huntingwood / Truganina / Crestmead) as a
        # belt-and-braces safety net against naming variants.
        if customer_name:
            upper_name = customer_name.upper()
            alm_warehouses = ("FYSHWICK", "HUNTINGWOOD", "TRUGANINA", "CRESTMEAD")
            if upper_name.startswith("ALM ") or any(w in upper_name for w in alm_warehouses):
                logger.info(
                    "Row %d: skipped ALM warehouse transfer — customer=%r",
                    row_num, customer_name,
                )
                result["rows_skipped"] += 1
                return None

        if not sku_code:
            # Skip fully empty rows silently (trailing rows in Excel)
            if raw_date is None and raw_qty is None and raw_gross is None:
                return None
            result["errors"].append(f"Row {row_num}: missing SKU code")
            return None

        sale_date = self._parse_date(raw_date)
        if sale_date is None:
            result["errors"].append(
                f"Row {row_num}: invalid or missing date — raw value: {raw_date!r}"
            )
            return None

        # --- Quantity: prefer CARTONS (cases), fall back to QUANTITY (bottles) ---
        # BUG-118 / ADR-014: track which column supplied the value so we can
        # write stock_unit at INSERT time. The owner 2026-04-22 Q2 confirmed DWS
        # can report in bottles when CARTONS is absent.
        quantity = self._parse_decimal(raw_qty)
        stock_unit = "case"
        if quantity is None or quantity == Decimal("0"):
            # Fall back to bottle count (if available)
            qty_bottles = self._parse_decimal(raw_qty_bottles)
            if qty_bottles is not None and qty_bottles != Decimal("0"):
                quantity = qty_bottles
                stock_unit = "bottle"
            else:
                result["errors"].append(
                    f"Row {row_num}: invalid or missing quantity — "
                    f"cartons={raw_qty!r} bottles={raw_qty_bottles!r}"
                )
                return None

        # --- Value fields ---
        gross_value = self._parse_decimal(raw_gross)
        discount_amount = self._parse_decimal(raw_discount) or Decimal("0")
        rebate_amount = self._parse_decimal(raw_rebate) or Decimal("0")
        wholesale_fee = self._parse_decimal(raw_fee) or Decimal("0")
        source_ref = str(raw_ref).strip() if raw_ref is not None else None

        # --- Derive unit_price from GROSSVAL / CARTONS ---
        unit_price = self._parse_decimal(raw_price)
        if unit_price is None and gross_value is not None and quantity and quantity != Decimal("0"):
            unit_price = (gross_value / quantity).quantize(Decimal("0.01"))

        # --- Gross revenue (before deductions) ---
        if gross_value is not None:
            gross_revenue = gross_value
        elif unit_price is not None:
            gross_revenue = (quantity * unit_price).quantize(Decimal("0.01"))
        else:
            gross_revenue = None

        # --- Net revenue = gross - discount - rebate - fee (M3-09) ---
        if gross_revenue is not None:
            net_revenue = gross_revenue - discount_amount - rebate_amount - wholesale_fee
        else:
            net_revenue = None

        # --- Generate unique source_ref ---
        # REFNO is shared across line items in the same invoice.
        # Append SKU code to make it unique per line.
        if source_ref:
            source_ref = f"{source_ref}-{sku_code}"
        else:
            source_ref = f"DWS-{sale_date.isoformat()}-{sku_code}-{row_num}"

        # --- Duplicate check: first against committed DB, then intra-file ---
        if self._is_duplicate(cursor, source_ref):
            result["rows_skipped"] += 1
            return None
        if source_ref in seen_refs:
            result["rows_skipped"] += 1
            return None
        seen_refs.add(source_ref)

        # --- SKU lookup (with description fallback for auto-mapping) ---
        # BUG-09/BUG-10: unknown SKUs still get inserted with sku_id=NULL so
        # the upload wizard can surface them for manual mapping.
        raw_desc = _get("description")
        desc_str = str(raw_desc).strip() if raw_desc else None
        sku_id = self._lookup_sku(cursor, sku_code, description=desc_str)
        if sku_id is None:
            result["errors"].append(
                f"Row {row_num}: unrecognised DWS SKU code '{sku_code}' — "
                f"row inserted with sku_id=NULL."
            )

        # --- Customer lookup ---
        customer_id = None
        if customer_name:
            customer_id = self._lookup_customer(cursor, customer_name)
            if customer_id is None:
                result["errors"].append(
                    f"Row {row_num}: unrecognised DWS customer '{customer_name}' — "
                    f"row inserted with customer_id=NULL."
                )

        period = self._derive_period(sale_date)

        # BUG-113 Option D: append 6 content_hash bindings in the exact order
        # expected by _SALES_VALUES_TEMPLATE's SHA256 expression:
        # (source_system, source_ref, sku_id, customer_id, sale_date, quantity).
        # BUG-118 / ADR-014: stock_unit is passed positionally before the hash
        # bindings (column 15 of _SALES_INSERT_COLUMNS). NOT in the hash.
        return (
            sku_id, customer_id, channel_id,
            sale_date, period, quantity, unit_price,
            discount_amount, rebate_amount, wholesale_fee,
            gross_revenue, net_revenue, SOURCE_SYSTEM, source_ref,
            "DWS",
            stock_unit,
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
        print("Usage: python -m etl.import_dws <path_to_dws_report.xlsx>", file=sys.stderr)
        sys.exit(1)

    file_path = sys.argv[1]

    importer = DWSImporter(db_url)
    try:
        result = importer.import_file(file_path)
        print(f"DWS import complete: {result['rows_imported']} imported, "
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
