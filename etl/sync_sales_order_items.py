"""
Vinsight Sales Order Items Sync — Step 1 of M2-COGS-ENGINE.

Fetches all SalesOrderItems from Vinsight API (flat, no $expand needed),
then denormalizes by joining with existing staging data to get:
- StockItemCode + vintage (from staging_vinsight_stock_items)
- DateDespatched + ContactCode (from staging_vinsight_sales_orders)

Usage:
    DATABASE_URL=postgresql://... VINSIGHT_API_KEY=... python -m etl.sync_sales_order_items
"""

import json
import logging
import os
import re
import sys
import time

import psycopg2
import psycopg2.extras
import requests

from etl.logger import log_etl_run

logger = logging.getLogger("moppity.etl.sync_sales_order_items")

BASE_URL = "https://app.vinsight.net"
MAX_RETRIES = 3
BACKOFF_SECONDS = [2, 4, 8]


def extract_vintage(stock_item_code: str | None, description: str | None) -> int | None:
    """Extract vintage year from StockItemCode or Description.

    StockItemCode patterns:
      - COPRSANB24 → 24 → 2024
      - MVLKSHZB21 → 21 → 2021
      - R-MVLKCABB15 → 15 → 2015

    Description patterns:
      - "Procella Sangiovese 2024" → 2024
      - "Lock & Key Cabernet Sauv 2015" → 2015
    """
    # Try StockItemCode first — last 2 digits before any suffix
    if stock_item_code:
        # Remove common prefixes like "R-"
        code = re.sub(r'^R-', '', stock_item_code)
        # Match 2-digit year at end of code (possibly followed by a letter suffix)
        m = re.search(r'(\d{2})[A-Z]?$', code)
        if m:
            year_2d = int(m.group(1))
            if 0 <= year_2d <= 30:
                return 2000 + year_2d
            elif 90 <= year_2d <= 99:
                return 1900 + year_2d

    # Fallback: 4-digit year in description
    if description:
        m = re.search(r'\b(19\d{2}|20[0-3]\d)\b', description)
        if m:
            return int(m.group(1))

    return None


class SalesOrderItemSyncer:
    """Syncs Vinsight SalesOrderItems and denormalizes with existing staging data."""

    def __init__(self, api_key: str, db_connection_string: str) -> None:
        self.api_key = api_key
        self.db_conn = psycopg2.connect(db_connection_string)
        self.db_conn.autocommit = False
        self._session = requests.Session()
        logger.info("SalesOrderItemSyncer initialised")

    def sync(self) -> dict[str, int]:
        """Full sync: fetch from API → store flat → denormalize with staging data."""
        results = {}

        # Step 1: Fetch all SalesOrderItems from Vinsight
        items = self._fetch_all_items()
        results["fetched"] = len(items)
        logger.info("Fetched %d SalesOrderItems from Vinsight", len(items))

        # Step 2: Insert into vinsight_sales_order_item table
        results["inserted"] = self._insert_items(items)
        logger.info("Inserted %d items into vinsight_sales_order_item", results["inserted"])

        # Step 3: Denormalize — join with staging data to fill in StockItemCode, dates, contact
        results["denormalized"] = self._denormalize()
        logger.info("Denormalized %d items with StockItemCode + order data", results["denormalized"])

        # Step 4: Extract vintage from StockItemCode/Description
        results["vintages_extracted"] = self._extract_vintages()
        logger.info("Extracted vintage for %d items", results["vintages_extracted"])

        # Log ETL run
        log_etl_run(
            db_conn=self.db_conn,
            source="vinsight_cogs",
            endpoint="/SalesOrderItems.json",
            status="success",
            rows_processed=results["inserted"],
            rows_skipped=results["fetched"] - results["inserted"],
            error_count=0,
            error_detail=None,
        )

        return results

    def _fetch_all_items(self) -> list[dict]:
        """Fetch all SalesOrderItems from Vinsight using $select (no expand needed).

        BUG-33: UnitPrice + Discount now included — they were silently omitted
        before, which forced `schema/018_vinsight_direct_sync.sql` to substitute
        `canonical_sku.base_wholesale` (LIST wholesale) and inflated every
        Direct-channel row by the negotiated-discount factor (2-3x on average).
        """
        url = (
            f"{BASE_URL}/SalesOrderItems.json"
            f"?api-key={self.api_key}"
            f"&$top=99999"
            f"&$select=EntryNum,Quantity,StockItemNum,OrderNum,UnitOfMeasureCode,"
            f"UnitPrice,Discount,DiscountNumeric"
        )

        for attempt in range(MAX_RETRIES):
            try:
                response = self._session.get(url, timeout=60)
                if response.status_code == 200:
                    data = response.json()
                    if isinstance(data, list):
                        return data
                    return data.get("List") or data.get("Items") or []

                if response.status_code == 429 or response.status_code >= 500:
                    backoff = BACKOFF_SECONDS[min(attempt, len(BACKOFF_SECONDS) - 1)]
                    logger.warning("HTTP %d, retrying in %ds", response.status_code, backoff)
                    time.sleep(backoff)
                    continue

                logger.error("HTTP %d: %s", response.status_code, response.text[:500])
                return []

            except requests.RequestException as exc:
                backoff = BACKOFF_SECONDS[min(attempt, len(BACKOFF_SECONDS) - 1)]
                logger.warning("Request error: %s. Retrying in %ds", exc, backoff)
                time.sleep(backoff)

        logger.error("All retries exhausted for SalesOrderItems")
        return []

    def _insert_items(self, items: list[dict]) -> int:
        """Insert raw SalesOrderItems into vinsight_sales_order_item table."""
        rows = 0
        try:
            with self.db_conn.cursor() as cur:
                cur.execute("TRUNCATE vinsight_sales_order_item RESTART IDENTITY")

                for item in items:
                    entry_num = item.get("EntryNum")
                    if not entry_num:
                        continue
                    # BUG-33: persist UnitPrice + Discount so the SQL sync can
                    # use the actual invoice-line net price. The Vinsight API
                    # returns `Discount` as a FRACTION (0.60 = 60% = 40% off list).
                    # `DiscountNumeric` is a stale/alternate field that ships as
                    # 0.0 on discounted lines — DO NOT use it. Verified via live
                    # probe of OrderNum 21124 line 43785 (Customer 10):
                    # Discount=0.6, DiscountNumeric=0.0, CSV Net Price $124 == 310*(1-0.6).
                    unit_price = item.get("UnitPrice")
                    discount_pct = item.get("Discount")
                    cur.execute("""
                        INSERT INTO vinsight_sales_order_item
                            (entry_num, order_num, stock_item_num, quantity, uom_code,
                             unit_price, discount_pct)
                        VALUES (%s, %s, %s, %s, %s, %s, %s)
                        ON CONFLICT (entry_num) DO UPDATE
                        SET unit_price   = EXCLUDED.unit_price,
                            discount_pct = EXCLUDED.discount_pct
                    """, (
                        entry_num,
                        item.get("OrderNum"),
                        item.get("StockItemNum"),
                        item.get("Quantity"),
                        item.get("UnitOfMeasureCode"),
                        unit_price,
                        discount_pct,
                    ))
                    rows += 1

            self.db_conn.commit()
        except Exception as exc:
            self.db_conn.rollback()
            logger.error("Insert failed: %s", exc)
            raise

        return rows

    def _denormalize(self) -> int:
        """Join vinsight_sales_order_item with staging data to fill in denormalized fields."""
        try:
            with self.db_conn.cursor() as cur:
                # Fill StockItemCode + Description from staging_vinsight_stock_items
                cur.execute("""
                    UPDATE vinsight_sales_order_item vsoi
                    SET
                        stock_item_code = si.raw_data->>'StockItemCode',
                        description = si.raw_data->>'Description'
                    FROM staging_vinsight_stock_items si
                    WHERE (si.raw_data->>'StockItemNum')::integer = vsoi.stock_item_num
                """)
                stock_matched = cur.rowcount
                logger.info("Matched %d items to StockItemCode", stock_matched)

                # Fill DateDespatched + ContactCode from staging_vinsight_sales_orders
                cur.execute("""
                    UPDATE vinsight_sales_order_item vsoi
                    SET
                        date_despatched = (so.raw_data->>'DateDespatched')::timestamp,
                        invoice_date = (so.raw_data->>'InvoiceDate')::timestamp,
                        contact_code = so.raw_data->'Contact'->>'ContactCode',
                        contact_num = (so.raw_data->>'ContactNum')::integer
                    FROM staging_vinsight_sales_orders so
                    WHERE (so.raw_data->>'SalesOrderNum')::integer = vsoi.order_num
                """)
                order_matched = cur.rowcount
                logger.info("Matched %d items to SalesOrder data", order_matched)

            self.db_conn.commit()
            return stock_matched

        except Exception as exc:
            self.db_conn.rollback()
            logger.error("Denormalize failed: %s", exc)
            raise

    def _extract_vintages(self) -> int:
        """Extract vintage year from StockItemCode/Description for each item."""
        try:
            with self.db_conn.cursor() as cur:
                # Fetch items that need vintage extraction
                cur.execute("""
                    SELECT id, stock_item_code, description
                    FROM vinsight_sales_order_item
                    WHERE vintage IS NULL
                      AND (stock_item_code IS NOT NULL OR description IS NOT NULL)
                """)
                rows = cur.fetchall()

                updated = 0
                for row_id, code, desc in rows:
                    vintage = extract_vintage(code, desc)
                    if vintage:
                        cur.execute(
                            "UPDATE vinsight_sales_order_item SET vintage = %s WHERE id = %s",
                            (vintage, row_id)
                        )
                        updated += 1

            self.db_conn.commit()
            return updated

        except Exception as exc:
            self.db_conn.rollback()
            logger.error("Vintage extraction failed: %s", exc)
            raise

    def get_stats(self) -> dict:
        """Get summary stats after sync."""
        with self.db_conn.cursor() as cur:
            cur.execute("""
                SELECT
                    count(*) as total,
                    count(stock_item_code) as with_stock_code,
                    count(date_despatched) as with_despatch_date,
                    count(contact_code) as with_contact,
                    count(vintage) as with_vintage,
                    count(DISTINCT order_num) as unique_orders,
                    count(DISTINCT stock_item_num) as unique_stock_items,
                    min(date_despatched) as earliest_despatch,
                    max(date_despatched) as latest_despatch
                FROM vinsight_sales_order_item
            """)
            row = cur.fetchone()
            return {
                "total_items": row[0],
                "with_stock_code": row[1],
                "with_despatch_date": row[2],
                "with_contact": row[3],
                "with_vintage": row[4],
                "unique_orders": row[5],
                "unique_stock_items": row[6],
                "earliest_despatch": str(row[7]),
                "latest_despatch": str(row[8]),
            }

    def close(self):
        self._session.close()
        if self.db_conn and not self.db_conn.closed:
            self.db_conn.close()


if __name__ == "__main__":
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )

    api_key = os.environ.get("VINSIGHT_API_KEY")
    database_url = os.environ.get("DATABASE_URL")

    if not api_key:
        logger.error("VINSIGHT_API_KEY not set")
        sys.exit(1)
    if not database_url:
        logger.error("DATABASE_URL not set")
        sys.exit(1)

    syncer = SalesOrderItemSyncer(api_key=api_key, db_connection_string=database_url)
    try:
        print("=== Syncing Vinsight SalesOrderItems ===")
        results = syncer.sync()
        print(f"Results: {json.dumps(results, indent=2)}")

        print("\n=== Stats ===")
        stats = syncer.get_stats()
        for k, v in stats.items():
            print(f"  {k}: {v}")

    except Exception as exc:
        logger.error("Sync failed: %s", exc, exc_info=True)
        sys.exit(1)
    finally:
        syncer.close()
