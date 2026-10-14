"""
ALM Monthly Report Importer for Moppity Vineyards.

Parses ALM (Australian Liquor Marketers) weekly withdrawal reports and inserts
validated rows into the sales_transaction table. ALM is a wholesale channel —
ALM buys stock, revenue recognised on invoice.

ALM reports are pipe-delimited EDI text files, typically delivered as nested
zip archives (a .zip containing weekly .zip files, each containing the EDI
data file). This importer handles:
  - .zip files (outer zip with nested zips inside)
  - Individual pipe-delimited data files

EDI Record Types:
  5|0|... — File header (supplier, state, date)
  5|1|... — Batch header
  5|2|... — Transaction record (the actual sales data)
  5|3|... — Batch trailer (record count)

Transaction record fields (pipe-delimited, 0-indexed):
  [4]  = transaction_id
  [8]  = withdrawal_date (YYYYMMDD)
  [11] = alm_product_code
  [12] = product_description
  [18] = pack_size
  [20] = outlet_name (customer)
  [37] = qty_delivered (individual units)
  [43] = gross_value (in cents)
  [44] = cost_value (in cents)
  [45] = discount (in cents)
  [46] = WET/levy (in cents)
  [47] = GST (in cents)

Usage:
    DATABASE_URL=postgresql://... python -m etl.import_alm path/to/alm_report.zip
"""

import datetime
import io
import json
import logging
import os
import sys
import time
import zipfile
from decimal import Decimal, InvalidOperation

import psycopg2
import psycopg2.extras

from etl.logger import log_etl_run, log_dead_letter

logger = logging.getLogger("moppity.etl.import_alm")

SOURCE_SYSTEM = "ALM"
SOURCE_SYSTEM_LOWER = "alm"

# BUG-24: batch size for execute_values — 500 rows per round-trip.
BATCH_SIZE = 500

# Column list for sales_transaction inserts. Keep in sync with the tuple
# ordering produced by _prepare_transaction.
#
# BUG-113 Option D: content_hash is the 15th column, computed SQL-side by
# SHA256 over (source_system, source_ref, sku_id, customer_id, sale_date,
# quantity). The hash bindings are appended to every row tuple (6 extra
# values after the 14 column values — see _prepare_transaction). ON CONFLICT
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
# R-001: warehouse is column 15 (positional), constant 'ALM' for this writer.
# Not in content_hash. Required so /sales warehouse filter + chart bars work.
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

# BUG-63a: ALM vintage estimation rule. Mirrors schema/082 backfill so
# newly-imported ALM rows get attributed without a separate ETL pass.
# Rule (the owner 2026-04-26 DOCX 1196 + Mar 19 / Mar 31 / Apr 3 transcripts):
#   Tier 1 — most recent Vinsight dispatch vintage of same wine_product to any
#            ALM contact, dispatched on/before sale_date+7d. Method label
#            'alm_estimated_by_dispatch_date', confidence 0.95.
#   Tier 2 — fallback to newest released vintage from wine_product.vintages_seen
#            <= sale_year (else sale_year-1). Method label
#            'alm_estimated_newest_released', confidence 0.70.
# Idempotent UPSERT — safe to run on every import. See schema/082 for the same
# logic with PRE/POST coverage assertions.
_ALM_VINTAGE_TIER1_SQL = """
INSERT INTO sale_vintage_attribution
    (sales_transaction_id, attributed_vintage, attribution_method,
     confidence, vinsight_order_num, notes)
SELECT DISTINCT ON (st.transaction_id)
    st.transaction_id,
    vsoi.vintage,
    'alm_estimated_by_dispatch_date',
    0.95,
    vsoi.order_num,
    'BUG-63a tier 1: ALM dispatch ' || vsoi.date_despatched::date
        || ' to ' || vsoi.contact_code || ' (sale ' || st.sale_date::date || ')'
FROM sales_transaction st
JOIN channel c ON c.channel_id = st.channel_id
JOIN sku_wine_product_map swpm ON swpm.sku_id = st.sku_id
JOIN vinsight_sales_order_item vsoi
    ON LEFT(REGEXP_REPLACE(vsoi.stock_item_code, '^[A-Z]-', ''),
            LENGTH(REGEXP_REPLACE(vsoi.stock_item_code, '^[A-Z]-', '')) - 2)
       = swpm.wine_product_code
WHERE c.channel_name = 'ALM'
  AND vsoi.vintage IS NOT NULL
  AND vsoi.date_despatched IS NOT NULL
  AND vsoi.date_despatched <= st.sale_date + interval '7 days'
  AND vsoi.contact_code IN ('ALM Fyshwick', 'ALM Charge Thru', 'ALM Truganina (Vic)')
ORDER BY st.transaction_id, vsoi.date_despatched DESC
ON CONFLICT (sales_transaction_id) DO UPDATE
    SET attributed_vintage = EXCLUDED.attributed_vintage,
        attribution_method = EXCLUDED.attribution_method,
        confidence         = EXCLUDED.confidence,
        vinsight_order_num = EXCLUDED.vinsight_order_num,
        notes              = EXCLUDED.notes,
        updated_at         = NOW()
"""

_ALM_VINTAGE_TIER2_SQL = """
WITH alm_unmatched AS (
    SELECT
        st.transaction_id,
        EXTRACT(YEAR FROM st.sale_date)::int AS sale_year,
        swpm.wine_product_code,
        wp.vintages_seen
    FROM sales_transaction st
    JOIN channel c ON c.channel_id = st.channel_id
    JOIN sku_wine_product_map swpm ON swpm.sku_id = st.sku_id
    LEFT JOIN wine_product wp ON wp.wine_product_code = swpm.wine_product_code
    LEFT JOIN sale_vintage_attribution sva
        ON sva.sales_transaction_id = st.transaction_id
       AND sva.attribution_method = 'alm_estimated_by_dispatch_date'
    WHERE c.channel_name = 'ALM'
      AND sva.id IS NULL
)
INSERT INTO sale_vintage_attribution
    (sales_transaction_id, attributed_vintage, attribution_method,
     confidence, notes)
SELECT
    transaction_id,
    COALESCE(
        (SELECT MAX(v) FROM unnest(vintages_seen) AS v WHERE v <= sale_year),
        sale_year - 1
    ) AS attributed_vintage,
    'alm_estimated_newest_released',
    0.70,
    'BUG-63a tier 2: newest released <= sale_year=' || sale_year
        || ' from wine_product.vintages_seen='
        || COALESCE(array_to_string(vintages_seen, ','), 'NULL')
FROM alm_unmatched
ON CONFLICT (sales_transaction_id) DO UPDATE
    SET attributed_vintage = EXCLUDED.attributed_vintage,
        attribution_method = EXCLUDED.attribution_method,
        confidence         = EXCLUDED.confidence,
        vinsight_order_num = NULL,
        notes              = EXCLUDED.notes,
        updated_at         = NOW()
"""


class ALMImporter:
    """Imports ALM weekly withdrawal EDI reports into sales_transaction."""

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

    def _lookup_sku_by_description(self, cursor, description: str) -> int | None:
        """Try to match ALM product description to a canonical SKU.

        ALM uses internal product codes (e.g. 00870170) and descriptions
        (e.g. 'MOPPITY BLOCK M1 CAB SAUV750ML'). We try matching on
        description keywords against sku.sku_name.
        """
        # Try sku_code_map first (ALM product code)
        cursor.execute(
            "SELECT sku_id FROM sku_code_map "
            "WHERE source_system = %s AND LOWER(external_code) = LOWER(%s)",
            (SOURCE_SYSTEM_LOWER, description),
        )
        row = cursor.fetchone()
        if row:
            return row[0]

        # Fallback: fuzzy match on item_description containing description keywords
        # Extract meaningful words from description (skip short ones)
        words = [w for w in description.upper().split() if len(w) > 2
                 and w not in ("750ML", "375ML", "200ML", "THE", "AND")]
        if words:
            # Try matching first 2-3 significant words
            search_pattern = "%".join(words[:3])
            cursor.execute(
                "SELECT sku_id FROM sku WHERE UPPER(item_description) LIKE %s LIMIT 1",
                (f"%{search_pattern}%",),
            )
            row = cursor.fetchone()
            if row:
                return row[0]

        return None

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

    def _lookup_sku_by_code(self, cursor, alm_code: str) -> int | None:
        """Look up an ALM product code in sku_code_map."""
        cursor.execute(
            "SELECT sku_id FROM sku_code_map "
            "WHERE source_system = %s AND LOWER(external_code) = LOWER(%s)",
            (SOURCE_SYSTEM_LOWER, alm_code),
        )
        row = cursor.fetchone()
        return row[0] if row else None

    def _lookup_customer(self, cursor, external_name: str) -> int | None:
        # BUG-127 / ADR-017: this importer is LOOKUP-ONLY for customer rows —
        # it never INSERTs into customer. Unrecognised customers cause
        # sales_transaction rows to be inserted with customer_id=NULL and
        # surface via dead-letter for manual reconciliation. New customer
        # rows are created via /api/customers POST (Import Wizard "+ New
        # Customer"), which hardcodes warehouse_channel='ALM' when the
        # request body sets source_system='alm'. So warehouse_channel
        # invariant for ALM-origin customers holds without modification here.
        cursor.execute(
            "SELECT customer_id FROM customer_code_map "
            "WHERE source_system = %s AND LOWER(external_name) = LOWER(%s)",
            (SOURCE_SYSTEM_LOWER, external_name),
        )
        row = cursor.fetchone()
        if row:
            return row[0]
        # Fallback: direct match on customer name
        cursor.execute(
            "SELECT customer_id FROM customer WHERE LOWER(customer_name) = LOWER(%s)",
            (external_name,),
        )
        row = cursor.fetchone()
        return row[0] if row else None

    def _lookup_channel_id(self, cursor) -> int:
        cursor.execute(
            "SELECT channel_id FROM channel WHERE channel_name = %s",
            ("ALM",),
        )
        row = cursor.fetchone()
        if not row:
            raise RuntimeError("Channel 'ALM' not found in channel table.")
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
    # BUG-63a — ALM vintage attribution (post-import)
    # ------------------------------------------------------------------

    def _attribute_alm_vintages(self, conn) -> dict:
        # Re-attribute every ALM row using the BUG-63a rule. Idempotent
        # (UPSERT) so each import keeps attribution in sync with the latest
        # Vinsight dispatch state.
        stats = {"tier1": 0, "tier2": 0, "total_alm": 0, "coverage_pct": 0.0}
        try:
            with conn.cursor() as cur:
                cur.execute(_ALM_VINTAGE_TIER1_SQL)
                stats["tier1"] = cur.rowcount
                cur.execute(_ALM_VINTAGE_TIER2_SQL)
                stats["tier2"] = cur.rowcount
                cur.execute(
                    """
                    SELECT
                        (SELECT COUNT(*) FROM sales_transaction st
                          JOIN channel c ON c.channel_id = st.channel_id
                          WHERE c.channel_name = 'ALM') AS total_alm,
                        (SELECT COUNT(*) FROM sales_transaction st
                          JOIN channel c ON c.channel_id = st.channel_id
                          JOIN sale_vintage_attribution sva
                            ON sva.sales_transaction_id = st.transaction_id
                          WHERE c.channel_name = 'ALM'
                            AND sva.attribution_method LIKE 'alm_estimated%%') AS attributed
                    """
                )
                total_alm, attributed = cur.fetchone()
                stats["total_alm"] = total_alm
                stats["coverage_pct"] = (
                    round((attributed / total_alm) * 100, 2) if total_alm else 0.0
                )
            conn.commit()
            logger.info(
                "ALM vintage attribution: tier1=%d tier2=%d total_alm=%d coverage=%.2f%%",
                stats["tier1"], stats["tier2"], stats["total_alm"], stats["coverage_pct"],
            )
            return stats
        except Exception as exc:
            conn.rollback()
            logger.warning(
                "ALM vintage attribution failed (%s) — raw rows are still committed; "
                "re-run schema/082 or attribute_vintages.py to recover", exc,
            )
            return stats

    # ------------------------------------------------------------------
    # Parsing helpers
    # ------------------------------------------------------------------

    @staticmethod
    def _parse_edi_date(value: str) -> datetime.date | None:
        """Parse ALM EDI date format: YYYYMMDD."""
        text = value.strip()
        if len(text) != 8 or text == "00000000":
            return None
        try:
            return datetime.datetime.strptime(text, "%Y%m%d").date()
        except ValueError:
            # Try DDMMYYYY format (header uses this)
            try:
                return datetime.datetime.strptime(text, "%d%m%Y").date()
            except ValueError:
                return None

    @staticmethod
    def _parse_cents(value: str) -> Decimal | None:
        """Parse a value in cents (e.g. '000021477') to dollars."""
        text = value.strip()
        if not text:
            return None
        try:
            cents = int(text)
            return Decimal(cents) / Decimal("100")
        except (ValueError, InvalidOperation):
            return None

    @staticmethod
    def _derive_period(sale_date: datetime.date) -> str:
        return sale_date.strftime("%Y-%m")

    # ------------------------------------------------------------------
    # File extraction
    # ------------------------------------------------------------------

    def _extract_edi_lines(self, file_path: str) -> list[str]:
        """Extract all EDI data lines from a file or zip archive.

        Handles:
        - Direct text file (pipe-delimited)
        - Zip containing data files directly
        - Zip containing nested zips containing data files
        """
        all_lines = []

        if zipfile.is_zipfile(file_path):
            with zipfile.ZipFile(file_path, "r") as outer_zip:
                for name in outer_zip.namelist():
                    data = outer_zip.read(name)
                    if name.lower().endswith(".zip"):
                        # Nested zip — extract data file from inside
                        try:
                            with zipfile.ZipFile(io.BytesIO(data), "r") as inner_zip:
                                for inner_name in inner_zip.namelist():
                                    inner_data = inner_zip.read(inner_name)
                                    lines = inner_data.decode("utf-8", errors="replace").splitlines()
                                    all_lines.extend(lines)
                        except zipfile.BadZipFile:
                            logger.warning("Skipping invalid nested zip: %s", name)
                    else:
                        # Direct data file in outer zip
                        lines = data.decode("utf-8", errors="replace").splitlines()
                        all_lines.extend(lines)
        else:
            # Plain text file
            with open(file_path, "r", encoding="utf-8", errors="replace") as f:
                all_lines = f.readlines()

        return all_lines

    # ------------------------------------------------------------------
    # Parse transaction records
    # ------------------------------------------------------------------

    def _parse_transaction(self, fields: list[str]) -> dict | None:
        """Parse a 5|2 transaction record into a dict."""
        if len(fields) < 44:
            return None

        transaction_id = fields[4].strip()
        date_str = fields[8].strip()
        alm_product_code = fields[11].strip()
        product_description = fields[12].strip()

        # Pack size for unit conversion
        try:
            pack_size = int(fields[18].strip()) if fields[18].strip() else 12
        except ValueError:
            pack_size = 12

        outlet_name = fields[20].strip()

        # Quantity delivered (in individual units/bottles)
        try:
            qty_delivered = int(fields[37].strip()) if len(fields) > 37 else 0
        except ValueError:
            qty_delivered = 0

        # Convert to cases for consistency with DWS/Direct channels
        if pack_size > 0 and qty_delivered > 0:
            quantity_cases = Decimal(qty_delivered) / Decimal(pack_size)
        else:
            quantity_cases = Decimal("0")

        # Financial fields (in cents)
        gross_value = self._parse_cents(fields[43]) if len(fields) > 43 else None
        cost_value = self._parse_cents(fields[44]) if len(fields) > 44 else None
        discount = self._parse_cents(fields[45]) if len(fields) > 45 else None
        wet_value = self._parse_cents(fields[46]) if len(fields) > 46 else None
        gst_value = self._parse_cents(fields[47]) if len(fields) > 47 else None

        sale_date = self._parse_edi_date(date_str)

        return {
            "transaction_id": transaction_id,
            "sale_date": sale_date,
            "alm_product_code": alm_product_code,
            "product_description": product_description,
            "outlet_name": outlet_name,
            "quantity": quantity_cases,
            "qty_units": qty_delivered,
            "pack_size": pack_size,
            "gross_value": gross_value,
            "cost_value": cost_value,
            "discount": discount or Decimal("0"),
            "wet_value": wet_value or Decimal("0"),
            "gst_value": gst_value or Decimal("0"),
        }

    # ------------------------------------------------------------------
    # Main import logic
    # ------------------------------------------------------------------

    def import_file(
        self,
        file_path: str,
        *,
        excluded_rows: set[int] | None = None,
    ) -> dict:
        """Run ALM EDI import.

        excluded_rows (D3 / 2026-05-11 / JF-13): 1-based preview row numbers
        the user unchecked in the Import Wizard preview UI. Skipped before
        insert; counted in result['rows_excluded']. Preview row_num for ALM
        is 1-based on 5|2 transaction lines (etl/preview.py:parse_alm_zip
        enumerate start=1) — matches this importer's row_num start=1.
        """
        logger.info("Starting ALM import from %s", file_path)
        excluded_rows = set(excluded_rows or [])
        if excluded_rows:
            logger.info(
                "ALM import: %d preview row(s) excluded by user (D3)",
                len(excluded_rows),
            )

        if not os.path.isfile(file_path):
            raise FileNotFoundError(f"ALM report file not found: {file_path}")

        conn = self._get_connection()
        result = {
            "rows_imported": 0, "rows_skipped": 0,
            "rows_excluded": 0, "errors": [],
        }
        run_id = None

        try:
            all_lines = self._extract_edi_lines(file_path)
            logger.info("ALM: extracted %d lines from %s", len(all_lines), file_path)

            # Filter to 5|2 transaction records only
            transaction_lines = []
            for line in all_lines:
                line = line.strip()
                if not line:
                    continue
                fields = line.split("|")
                if len(fields) >= 2 and fields[0].strip() == "5" and fields[1].strip() == "2":
                    transaction_lines.append(fields)

            logger.info("ALM: found %d transaction records", len(transaction_lines))

            if not transaction_lines:
                logger.warning("ALM: no transaction records found in %s", file_path)
                log_etl_run(
                    conn, source="alm_upload",
                    endpoint=os.path.basename(file_path),
                    status="success", rows_processed=0, rows_skipped=0,
                )
                return result

            with conn.cursor() as cur:
                channel_id = self._lookup_channel_id(cur)

                # BUG-24: batch accumulator. Phase 1 does lookups + tuple
                # builds; Phase 2 bulk-inserts with execute_values in chunks
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
                            "ALM batch %d: %d rows in %.3fs",
                            batch_no, batch_size, elapsed,
                        )
                    except psycopg2.Error as batch_exc:
                        cur.execute("ROLLBACK TO SAVEPOINT batch_sp")
                        logger.warning(
                            "ALM batch %d failed (%s) — falling back to "
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
                                    f"ALM batch {batch_no} fallback row "
                                    f"(source_ref={tup[-1]!r}) failed: {row_exc}"
                                )
                        logger.info(
                            "ALM batch %d fallback: %d/%d rows landed",
                            batch_no, landed, batch_size,
                        )
                    finally:
                        pending_inserts.clear()

                # D3: preview parse_alm_zip uses start=1; this loop also
                # starts at 1 → row_num matches the preview UI row_num. No
                # offset needed; check against excluded_rows directly.
                for row_num, fields in enumerate(transaction_lines, start=1):
                    if row_num in excluded_rows:
                        result["rows_excluded"] += 1
                        continue
                    try:
                        txn = self._parse_transaction(fields)
                        if txn is None:
                            result["errors"].append(
                                f"Row {row_num}: could not parse transaction (too few fields)"
                            )
                            continue

                        # Lookups stay row-level SAVEPOINT-protected so
                        # lookup failures don't abort the whole open txn.
                        cur.execute("SAVEPOINT row_sp")
                        tup = self._prepare_transaction(
                            cur, txn, channel_id, row_num, result, seen_refs,
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

            # BUG-63a: attribute vintage to ALM rows post-commit. Failure here
            # does NOT abort the import — raw rows are already persisted, and
            # schema/082 or attribute_vintages.py can recover the state.
            if result["rows_imported"] > 0:
                attribution_stats = self._attribute_alm_vintages(conn)
                result["alm_vintage_attribution"] = attribution_stats

            status = "success" if not result["errors"] else "partial"
            error_detail = "\n".join(result["errors"][:50]) if result["errors"] else None
            run_id = log_etl_run(
                conn, source="alm_upload",
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
                        conn, run_id=run_id, source="alm_upload",
                        raw_data={"error": error_msg}, error_message=error_msg,
                    )

            logger.info(
                "ALM import complete: imported=%d skipped=%d errors=%d",
                result["rows_imported"], result["rows_skipped"], len(result["errors"]),
            )

        except Exception as exc:
            conn.rollback()
            error_msg = f"ALM import failed: {exc}"
            logger.error(error_msg)
            result["errors"].append(error_msg)
            try:
                log_etl_run(
                    conn, source="alm_upload",
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

    def _prepare_transaction(
        self,
        cursor,
        txn: dict,
        channel_id: int,
        row_num: int,
        result: dict,
        seen_refs: set[str],
    ) -> tuple | None:
        """Validate an ALM transaction and return the sales_transaction tuple.

        BUG-24: split from the old _process_transaction so INSERTs can be
        batched. Returns None if the row should be skipped (empty, duplicate,
        or validation failure). Preserves BUG-09/BUG-10 dead-letter semantics:
        unknown SKU/outlet still yields an insert tuple with NULL and an error
        appended to result["errors"].

        `seen_refs` tracks intra-file source_refs (previously caught by the
        duplicate check against the open txn's uncommitted rows, which no
        longer works with batched inserts).
        """
        sale_date = txn["sale_date"]
        if sale_date is None:
            result["errors"].append(f"Row {row_num}: invalid date in ALM record")
            return None

        quantity = txn["quantity"]
        if quantity is None or quantity == Decimal("0"):
            result["errors"].append(f"Row {row_num}: zero quantity")
            return None

        gross_value = txn["gross_value"]
        discount = txn["discount"]
        product_desc = txn["product_description"]
        outlet_name = txn["outlet_name"]
        alm_code = txn["alm_product_code"]

        # Source ref: combine transaction_id + date for uniqueness
        source_ref = f"ALM-{txn['transaction_id']}-{sale_date.isoformat()}-{alm_code}"

        # Duplicate check: committed DB first, then intra-file
        if self._is_duplicate(cursor, source_ref):
            result["rows_skipped"] += 1
            return None
        if source_ref in seen_refs:
            result["rows_skipped"] += 1
            return None
        seen_refs.add(source_ref)

        # SKU lookup — try ALM product code first, then description match
        sku_id = self._lookup_sku_by_code(cursor, alm_code)
        if sku_id is None:
            sku_id = self._lookup_sku_by_description(cursor, product_desc)
            if sku_id is not None and alm_code:
                # Auto-cache: fuzzy match succeeded, save for instant future lookups
                self._cache_sku_mapping(cursor, sku_id, alm_code)
                logger.info(
                    "Auto-mapped ALM code '%s' (%s) to sku_id=%d",
                    alm_code, product_desc, sku_id,
                )
        if sku_id is None:
            # BUG-09/BUG-10: surface unknown SKU as dead-letter, still insert
            # with sku_id=NULL so the upload wizard can surface it.
            result["errors"].append(
                f"Row {row_num}: unrecognised ALM product '{product_desc}' "
                f"(code={alm_code}) — row inserted with sku_id=NULL."
            )

        # Customer lookup
        customer_id = None
        if outlet_name:
            # BUG-88: reject numeric-only outlet names. These come from ALM EDI
            # when DRNAME is missing and the raw account code leaks through as
            # the name. Surface as dead-letter instead of creating a junk row.
            if outlet_name.isdigit():
                result["errors"].append(
                    f"Row {row_num}: ALM outlet name is numeric-only '{outlet_name}' — "
                    f"likely missing DRNAME in EDI. Row inserted with customer_id=NULL."
                )
            else:
                customer_id = self._lookup_customer(cursor, outlet_name)
                if customer_id is None:
                    result["errors"].append(
                        f"Row {row_num}: unrecognised ALM outlet '{outlet_name}' — "
                        f"row inserted with customer_id=NULL."
                    )

        # Derive unit_price from gross_value / quantity
        unit_price = None
        if gross_value is not None and quantity != Decimal("0"):
            unit_price = (gross_value / quantity).quantize(Decimal("0.01"))

        # Gross revenue (before deductions)
        gross_revenue = gross_value  # ALM gross_value = wholesale value total

        # Net revenue = gross - discount - rebate - fee (M3-09)
        net_revenue = None
        if gross_revenue is not None:
            net_revenue = gross_revenue - discount

        period = self._derive_period(sale_date)

        # BUG-113 Option D: append 6 content_hash bindings in the exact order
        # expected by _SALES_VALUES_TEMPLATE's SHA256 expression:
        # (source_system, source_ref, sku_id, customer_id, sale_date, quantity).
        # BUG-118 / ADR-014: ALM importer divides bottles by pack_size at
        # ingest (line ~317), so quantity is always in cases.
        return (
            sku_id, customer_id, channel_id,
            sale_date, period, quantity, unit_price,
            discount, Decimal("0"), Decimal("0"),
            gross_revenue, net_revenue, SOURCE_SYSTEM, source_ref,
            "ALM",
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
        print("Usage: python -m etl.import_alm <path_to_alm_report.zip>", file=sys.stderr)
        sys.exit(1)

    file_path = sys.argv[1]

    importer = ALMImporter(db_url)
    try:
        result = importer.import_file(file_path)
        print(f"ALM import complete: {result['rows_imported']} imported, "
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
