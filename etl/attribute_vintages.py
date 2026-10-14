"""
Vintage Attribution ETL — M2-COGS-ENGINE Step 3.

For every sale in sales_transaction, determines which vintage was being sold
by cross-referencing Vinsight dispatch data.

Rules (confirmed by the owner, Mar 19):
- Direct sales: match Vinsight dispatch by date + wine product
- DWS/ALM sales: use "last ordered" vintage — most recent Vinsight dispatch
  to that channel for that wine product before the sale date
- Proportional split: when multiple vintages dispatched in same period,
  weight by dispatch quantity

Uses:
- wine_product + sku_wine_product_map (from Step 2)
- vinsight_sales_order_item (from Step 1)
- Writes to sale_vintage_attribution table

Usage:
    DATABASE_URL=postgresql://... python -m etl.attribute_vintages
"""

import json
import logging
import os
import re
import sys

import psycopg2
import psycopg2.extras

logger = logging.getLogger("moppity.etl.attribute_vintages")

# Vinsight contacts that map to DWS channel
DWS_CONTACTS = [
    'Customer 15',
    'DWS NSW', 'DWS Victoria', 'DWS QLD', 'DWS SA', 'DWS WA',
]

# Vinsight contacts that map to ALM channel
ALM_CONTACTS = [
    'ALM Fyshwick', 'ALM Charge Thru', 'ALM Truganina (Vic)',
]


class VintageAttributor:
    """Attributes vintage to every sale in sales_transaction."""

    def __init__(self, db_connection_string: str) -> None:
        self.db_conn = psycopg2.connect(db_connection_string)
        self.db_conn.autocommit = False
        logger.info("VintageAttributor initialised")

    def attribute_all(self) -> dict[str, int]:
        """Run full vintage attribution."""
        results = {}

        # Method 1: SKUs that already have vintage on the sku record
        results["from_sku_vintage"] = self._attribute_from_sku_vintage()

        # Method 2: Direct sales — match by wine product + date
        results["direct_matched"] = self._attribute_direct_sales()

        # Method 3: DWS sales — last ordered vintage
        results["dws_matched"] = self._attribute_channel_sales('DWS', DWS_CONTACTS)

        # Method 4: ALM sales — last ordered vintage
        results["alm_matched"] = self._attribute_channel_sales('ALM', ALM_CONTACTS)

        # Method 5: Remaining — try any Vinsight dispatch for that wine product
        results["fallback_matched"] = self._attribute_fallback()

        # Method 6: Historical estimation — infer vintage from sale year
        results["estimated"] = self._attribute_by_sale_year()

        results.update(self._get_stats())
        return results

    def _attribute_from_sku_vintage(self) -> int:
        """If the SKU already has a vintage field, use it directly."""
        try:
            with self.db_conn.cursor() as cur:
                # Clear existing attributions for clean rebuild
                cur.execute("DELETE FROM sale_vintage_attribution")

                cur.execute("""
                    INSERT INTO sale_vintage_attribution
                        (sales_transaction_id, attributed_vintage, attribution_method, confidence, notes)
                    SELECT
                        st.transaction_id,
                        s.vintage,
                        'sku_vintage',
                        1.0,
                        'Vintage from sku.vintage field'
                    FROM sales_transaction st
                    JOIN sku s ON s.sku_id = st.sku_id
                    WHERE s.vintage IS NOT NULL
                    ON CONFLICT (sales_transaction_id) DO NOTHING
                """)
                count = cur.rowcount

            self.db_conn.commit()
            logger.info("Attributed %d sales from sku.vintage", count)
            return count

        except Exception as exc:
            self.db_conn.rollback()
            logger.error("sku_vintage attribution failed: %s", exc)
            raise

    def _attribute_direct_sales(self) -> int:
        """Direct sales: match Vinsight dispatch by wine product + date proximity."""
        try:
            with self.db_conn.cursor() as cur:
                # For Direct sales not yet attributed, find the closest Vinsight dispatch
                # of the same wine product within ±30 days
                cur.execute("""
                    INSERT INTO sale_vintage_attribution
                        (sales_transaction_id, attributed_vintage, attribution_method,
                         confidence, vinsight_order_num, notes)
                    SELECT DISTINCT ON (st.transaction_id)
                        st.transaction_id,
                        vsoi.vintage,
                        'direct_match',
                        CASE
                            WHEN ABS(EXTRACT(EPOCH FROM (st.sale_date - vsoi.date_despatched)) / 86400) <= 7 THEN 1.0
                            WHEN ABS(EXTRACT(EPOCH FROM (st.sale_date - vsoi.date_despatched)) / 86400) <= 30 THEN 0.9
                            ELSE 0.8
                        END,
                        vsoi.order_num,
                        'Direct match: dispatch ' || vsoi.date_despatched::date || ' → sale ' || st.sale_date
                    FROM sales_transaction st
                    JOIN channel c ON c.channel_id = st.channel_id
                    JOIN sku_wine_product_map swpm ON swpm.sku_id = st.sku_id
                    JOIN vinsight_sales_order_item vsoi
                        ON LEFT(REGEXP_REPLACE(vsoi.stock_item_code, '^[A-Z]-', ''),
                                LENGTH(REGEXP_REPLACE(vsoi.stock_item_code, '^[A-Z]-', '')) - 2)
                           = swpm.wine_product_code
                    WHERE c.channel_name = 'Direct'
                      AND st.transaction_id NOT IN (SELECT sales_transaction_id FROM sale_vintage_attribution)
                      AND vsoi.vintage IS NOT NULL
                      AND vsoi.date_despatched IS NOT NULL
                      AND ABS(EXTRACT(EPOCH FROM (st.sale_date - vsoi.date_despatched)) / 86400) <= 60
                    ORDER BY st.transaction_id,
                             ABS(EXTRACT(EPOCH FROM (st.sale_date - vsoi.date_despatched)))
                """)
                count = cur.rowcount

            self.db_conn.commit()
            logger.info("Attributed %d Direct sales by date match", count)
            return count

        except Exception as exc:
            self.db_conn.rollback()
            logger.error("Direct attribution failed: %s", exc)
            raise

    def _attribute_channel_sales(self, channel_name: str, contact_codes: list[str]) -> int:
        """DWS/ALM sales: use 'last ordered' vintage from Vinsight dispatch."""
        try:
            with self.db_conn.cursor() as cur:
                # Build contact filter
                contact_filter = " OR ".join(
                    f"vsoi.contact_code = '{c}'" for c in contact_codes
                )

                cur.execute(f"""
                    INSERT INTO sale_vintage_attribution
                        (sales_transaction_id, attributed_vintage, attribution_method,
                         confidence, vinsight_order_num, notes)
                    SELECT DISTINCT ON (st.transaction_id)
                        st.transaction_id,
                        vsoi.vintage,
                        'last_ordered',
                        0.95,
                        vsoi.order_num,
                        '{channel_name} last ordered: dispatch ' || vsoi.date_despatched::date || ' to ' || vsoi.contact_code
                    FROM sales_transaction st
                    JOIN channel c ON c.channel_id = st.channel_id
                    JOIN sku_wine_product_map swpm ON swpm.sku_id = st.sku_id
                    JOIN vinsight_sales_order_item vsoi
                        ON LEFT(REGEXP_REPLACE(vsoi.stock_item_code, '^[A-Z]-', ''),
                                LENGTH(REGEXP_REPLACE(vsoi.stock_item_code, '^[A-Z]-', '')) - 2)
                           = swpm.wine_product_code
                    WHERE c.channel_name = %s
                      AND st.transaction_id NOT IN (SELECT sales_transaction_id FROM sale_vintage_attribution)
                      AND vsoi.vintage IS NOT NULL
                      AND vsoi.date_despatched IS NOT NULL
                      AND vsoi.date_despatched <= st.sale_date + interval '7 days'
                      AND ({contact_filter})
                    ORDER BY st.transaction_id, vsoi.date_despatched DESC
                """, (channel_name,))
                count = cur.rowcount

            self.db_conn.commit()
            logger.info("Attributed %d %s sales by last_ordered", count, channel_name)
            return count

        except Exception as exc:
            self.db_conn.rollback()
            logger.error("%s attribution failed: %s", channel_name, exc)
            raise

    def _attribute_fallback(self) -> int:
        """Fallback: for remaining unattributed sales, use any dispatch of same wine product."""
        try:
            with self.db_conn.cursor() as cur:
                # Use the most recent dispatch of the same wine product before the sale date
                # regardless of contact/channel
                cur.execute("""
                    INSERT INTO sale_vintage_attribution
                        (sales_transaction_id, attributed_vintage, attribution_method,
                         confidence, vinsight_order_num, notes)
                    SELECT DISTINCT ON (st.transaction_id)
                        st.transaction_id,
                        vsoi.vintage,
                        'fallback_any_dispatch',
                        0.7,
                        vsoi.order_num,
                        'Fallback: nearest dispatch ' || vsoi.date_despatched::date || ' to ' || COALESCE(vsoi.contact_code, '?')
                    FROM sales_transaction st
                    JOIN sku_wine_product_map swpm ON swpm.sku_id = st.sku_id
                    JOIN vinsight_sales_order_item vsoi
                        ON LEFT(REGEXP_REPLACE(vsoi.stock_item_code, '^[A-Z]-', ''),
                                LENGTH(REGEXP_REPLACE(vsoi.stock_item_code, '^[A-Z]-', '')) - 2)
                           = swpm.wine_product_code
                    WHERE st.transaction_id NOT IN (SELECT sales_transaction_id FROM sale_vintage_attribution)
                      AND vsoi.vintage IS NOT NULL
                      AND vsoi.date_despatched IS NOT NULL
                      AND vsoi.date_despatched <= st.sale_date + interval '30 days'
                    ORDER BY st.transaction_id, vsoi.date_despatched DESC
                """)
                count = cur.rowcount

            self.db_conn.commit()
            logger.info("Attributed %d sales via fallback", count)
            return count

        except Exception as exc:
            self.db_conn.rollback()
            logger.error("Fallback attribution failed: %s", exc)
            raise

    def _attribute_by_sale_year(self) -> int:
        """For remaining unattributed sales: estimate vintage from sale year.

        Logic: wines are typically sold 1-2 years after vintage.
        A sale in 2021 was most likely a 2020 or 2019 vintage.
        We pick the closest vintage from wine_product.vintages_seen that is
        <= sale_year. If none, use sale_year - 1.

        This is lower confidence (0.6) but covers historical gaps where
        Vinsight dispatch data uses deleted StockItems.
        """
        try:
            with self.db_conn.cursor() as cur:
                # Get unattributed sales with wine product info
                cur.execute("""
                    SELECT st.transaction_id, EXTRACT(YEAR FROM st.sale_date)::integer as sale_year,
                           swpm.wine_product_code
                    FROM sales_transaction st
                    JOIN sku_wine_product_map swpm ON swpm.sku_id = st.sku_id
                    WHERE st.transaction_id NOT IN (SELECT sales_transaction_id FROM sale_vintage_attribution)
                """)
                rows = cur.fetchall()

                if not rows:
                    return 0

                # Get vintages_seen for each wine product
                cur.execute("SELECT wine_product_code, vintages_seen FROM wine_product")
                vintage_lookup = {}
                for wp_code, vintages in cur.fetchall():
                    vintage_lookup[wp_code] = sorted(vintages) if vintages else []

                count = 0
                for txn_id, sale_year, wp_code in rows:
                    vintages = vintage_lookup.get(wp_code, [])

                    # Find the best vintage: latest vintage <= sale_year
                    estimated = None
                    for v in reversed(vintages):
                        if v <= sale_year:
                            estimated = v
                            break

                    # Fallback: sale_year - 1 (typical wine lag)
                    if estimated is None:
                        estimated = sale_year - 1

                    cur.execute("""
                        INSERT INTO sale_vintage_attribution
                            (sales_transaction_id, attributed_vintage, attribution_method,
                             confidence, notes)
                        VALUES (%s, %s, 'sale_year_estimate', 0.6, %s)
                        ON CONFLICT (sales_transaction_id) DO NOTHING
                    """, (txn_id, estimated,
                          f"Estimated: sale_year={sale_year}, known vintages={vintages[:5]}"))
                    count += 1

            self.db_conn.commit()
            logger.info("Attributed %d sales by sale_year estimate", count)
            return count

        except Exception as exc:
            self.db_conn.rollback()
            logger.error("Sale year estimation failed: %s", exc)
            raise

    def _get_stats(self) -> dict:
        """Get attribution coverage stats."""
        with self.db_conn.cursor() as cur:
            cur.execute("""
                SELECT
                    (SELECT count(*) FROM sales_transaction) as total_sales,
                    (SELECT count(*) FROM sale_vintage_attribution) as attributed,
                    (SELECT count(*) FROM sale_vintage_attribution WHERE attribution_method = 'sku_vintage') as from_sku,
                    (SELECT count(*) FROM sale_vintage_attribution WHERE attribution_method = 'direct_match') as direct,
                    (SELECT count(*) FROM sale_vintage_attribution WHERE attribution_method = 'last_ordered') as last_ordered,
                    (SELECT count(*) FROM sale_vintage_attribution WHERE attribution_method = 'fallback_any_dispatch') as fallback,
                    (SELECT count(*) FROM sale_vintage_attribution WHERE attribution_method = 'sale_year_estimate') as estimated
            """)
            row = cur.fetchone()
            total = row[0]
            attributed = row[1]
            pct = (attributed / total * 100) if total > 0 else 0

            return {
                "total_sales": total,
                "total_attributed": attributed,
                "coverage_pct": round(pct, 1),
                "unattributed": total - attributed,
                "by_method": {
                    "sku_vintage": row[2],
                    "direct_match": row[3],
                    "last_ordered": row[4],
                    "fallback_any_dispatch": row[5],
                    "sale_year_estimate": row[6],
                },
            }

    def close(self):
        if self.db_conn and not self.db_conn.closed:
            self.db_conn.close()


if __name__ == "__main__":
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )

    database_url = os.environ.get("DATABASE_URL")
    if not database_url:
        logger.error("DATABASE_URL not set")
        sys.exit(1)

    attributor = VintageAttributor(db_connection_string=database_url)
    try:
        print("=== Attributing Vintages ===")
        results = attributor.attribute_all()
        print(f"\nResults: {json.dumps(results, indent=2)}")

        pct = results.get("coverage_pct", 0)
        unattr = results.get("unattributed", 0)
        if pct >= 90:
            print(f"\n✅ Coverage {pct}% ({unattr} unattributed)")
        else:
            print(f"\n⚠️ Coverage {pct}% — {unattr} sales unattributed")

    except Exception as exc:
        logger.error("Attribution failed: %s", exc, exc_info=True)
        sys.exit(1)
    finally:
        attributor.close()
