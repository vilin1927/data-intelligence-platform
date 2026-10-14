"""
Wine Product Mapping — M2-COGS-ENGINE Step 2.

Builds two tables:
1. wine_product — auto-derived from Vinsight StockItemCode base codes
2. sku_wine_product_map — bridges every SKU to a wine product via 4 methods:
   - Method 1 (direct_code): sku.sku_code starts with a known wine_product_code
   - Method 2 (sku_code_map): sku_id → sku_code_map(vinsight) → StockItemNum → StockItemCode → base
   - Method 3 (group_sibling): DWS SKU in same sku_group as a Vinsight-mapped SKU
   - Method 4 (description_similarity): pg_trgm similarity() fallback

Usage:
    DATABASE_URL=postgresql://... python -m etl.build_wine_product_map
"""

import json
import logging
import os
import re
import sys

import psycopg2
import psycopg2.extras

logger = logging.getLogger("moppity.etl.build_wine_product_map")


def strip_vintage_from_code(stock_item_code: str) -> str | None:
    """Strip vintage suffix (last 2 digits) from Vinsight StockItemCode.

    Examples:
        MVATSHZB22 → MVATSHZB
        MVLKCABB21 → MVLKCABB
        R-MVLKCABB15 → MVLKCABB  (strip R- prefix too)
        B-COCOVIRC12 → COCOVIRC  (strip B- prefix too)
    """
    if not stock_item_code:
        return None
    # Strip R- or B- prefixes
    code = re.sub(r'^[A-Z]-', '', stock_item_code)
    # Must end in 2 digits (vintage)
    if len(code) >= 4 and re.match(r'\d{2}$', code[-2:]):
        return code[:-2]
    return None


class WineProductMapper:
    """Builds wine_product and sku_wine_product_map tables."""

    def __init__(self, db_connection_string: str) -> None:
        self.db_conn = psycopg2.connect(db_connection_string)
        self.db_conn.autocommit = False
        logger.info("WineProductMapper initialised")

    def build_all(self) -> dict[str, int]:
        """Full build: wine_product table + 4-method SKU mapping."""
        results = {}

        results["wine_products"] = self._build_wine_products()
        results["method_1_direct"] = self._method_1_direct_code()
        results["method_2_bridge"] = self._method_2_sku_code_map()
        results["method_3_sibling"] = self._method_3_group_sibling()
        results["method_4_similarity"] = self._method_4_description_similarity()
        results.update(self._get_coverage_stats())

        return results

    def _build_wine_products(self) -> int:
        """Step 2a: Create wine_product entries from Vinsight StockItemCodes."""
        try:
            with self.db_conn.cursor() as cur:
                # Clear and rebuild
                cur.execute("DELETE FROM sku_wine_product_map")
                cur.execute("DELETE FROM wine_product")

                # Extract unique base codes from vinsight_sales_order_item
                cur.execute("""
                    SELECT stock_item_code, description, vintage
                    FROM vinsight_sales_order_item
                    WHERE stock_item_code IS NOT NULL AND vintage IS NOT NULL
                """)
                rows = cur.fetchall()

                # Build wine products from base codes
                products = {}  # base_code → {desc, vintages}
                for code, desc, vintage in rows:
                    base = strip_vintage_from_code(code)
                    if not base:
                        continue
                    if base not in products:
                        # Strip vintage year from description to get generic name
                        generic_desc = re.sub(r'\s*\d{4}\s*$', '', desc or '').strip()
                        # Also strip pack size suffixes
                        generic_desc = re.sub(r'\s*\(?\d+[xX]\d+m[lL]\)?$', '', generic_desc).strip()
                        generic_desc = re.sub(r'\s+\d+pks?$', '', generic_desc).strip()
                        products[base] = {"desc": generic_desc, "vintages": set()}
                    products[base]["vintages"].add(vintage)

                # Insert wine products
                for base_code, data in products.items():
                    vintages_sorted = sorted(data["vintages"])
                    cur.execute("""
                        INSERT INTO wine_product (wine_product_code, description, vintages_seen)
                        VALUES (%s, %s, %s)
                        ON CONFLICT (wine_product_code) DO UPDATE SET
                            description = EXCLUDED.description,
                            vintages_seen = EXCLUDED.vintages_seen
                    """, (base_code, data["desc"], vintages_sorted))

            self.db_conn.commit()
            count = len(products)
            logger.info("Created %d wine products", count)
            return count

        except Exception as exc:
            self.db_conn.rollback()
            logger.error("Failed to build wine products: %s", exc)
            raise

    def _method_1_direct_code(self) -> int:
        """Method 1: sku.sku_code starts with a known wine_product_code."""
        try:
            with self.db_conn.cursor() as cur:
                # Get all wine product codes
                cur.execute("SELECT wine_product_code FROM wine_product")
                wp_codes = [r[0] for r in cur.fetchall()]

                # Get all SKUs with sales that aren't mapped yet
                cur.execute("""
                    SELECT DISTINCT s.sku_id, s.sku_code
                    FROM sku s
                    JOIN sales_transaction st ON st.sku_id = s.sku_id
                    WHERE s.sku_id NOT IN (SELECT sku_id FROM sku_wine_product_map)
                      AND s.sku_code IS NOT NULL
                """)
                skus = cur.fetchall()

                matched = 0
                for sku_id, sku_code in skus:
                    # Strip R- or B- prefix from SKU code too
                    clean_code = re.sub(r'^[A-Z]-', '', sku_code)
                    for wp_code in wp_codes:
                        if clean_code.startswith(wp_code) and len(clean_code) - len(wp_code) <= 3:
                            cur.execute("""
                                INSERT INTO sku_wine_product_map
                                    (sku_id, wine_product_code, mapping_method, confidence, notes)
                                VALUES (%s, %s, 'direct_code', 1.0, %s)
                                ON CONFLICT (sku_id) DO NOTHING
                            """, (sku_id, wp_code, f"sku_code={sku_code} starts with {wp_code}"))
                            matched += 1
                            break

            self.db_conn.commit()
            logger.info("Method 1 (direct_code): matched %d SKUs", matched)
            return matched

        except Exception as exc:
            self.db_conn.rollback()
            logger.error("Method 1 failed: %s", exc)
            raise

    def _method_2_sku_code_map(self) -> int:
        """Method 2: sku_id → sku_code_map(vinsight) → StockItemNum → StockItemCode → base."""
        try:
            with self.db_conn.cursor() as cur:
                # Join sku_code_map → vinsight_sales_order_item to get StockItemCode
                cur.execute("""
                    SELECT DISTINCT scm.sku_id, vsoi.stock_item_code
                    FROM sku_code_map scm
                    JOIN vinsight_sales_order_item vsoi
                        ON vsoi.stock_item_num = scm.external_code::integer
                    WHERE scm.source_system = 'vinsight'
                      AND scm.external_code ~ '^\d+$'
                      AND vsoi.stock_item_code IS NOT NULL
                      AND scm.sku_id NOT IN (SELECT sku_id FROM sku_wine_product_map)
                      AND scm.sku_id IN (SELECT DISTINCT sku_id FROM sales_transaction)
                """)
                rows = cur.fetchall()

                matched = 0
                for sku_id, stock_item_code in rows:
                    base = strip_vintage_from_code(stock_item_code)
                    if not base:
                        continue
                    # Verify this wine_product exists
                    cur.execute(
                        "SELECT 1 FROM wine_product WHERE wine_product_code = %s", (base,)
                    )
                    if cur.fetchone():
                        cur.execute("""
                            INSERT INTO sku_wine_product_map
                                (sku_id, wine_product_code, mapping_method, confidence, notes)
                            VALUES (%s, %s, 'sku_code_map', 1.0, %s)
                            ON CONFLICT (sku_id) DO NOTHING
                        """, (sku_id, base, f"vinsight StockItemCode={stock_item_code}"))
                        matched += 1

            self.db_conn.commit()
            logger.info("Method 2 (sku_code_map): matched %d SKUs", matched)
            return matched

        except Exception as exc:
            self.db_conn.rollback()
            logger.error("Method 2 failed: %s", exc)
            raise

    def _method_3_group_sibling(self) -> int:
        """Method 3: DWS/ALM SKU in same sku_group as an already-mapped SKU."""
        try:
            with self.db_conn.cursor() as cur:
                cur.execute("""
                    SELECT DISTINCT
                        unmapped.sku_id,
                        mapped.wine_product_code,
                        unmapped.sku_code as unmapped_code,
                        mapped_sku.sku_code as mapped_code,
                        unmapped.sku_group
                    FROM sku unmapped
                    JOIN sku mapped_sku
                        ON LOWER(TRIM(unmapped.sku_group)) = LOWER(TRIM(mapped_sku.sku_group))
                    JOIN sku_wine_product_map mapped
                        ON mapped.sku_id = mapped_sku.sku_id
                    WHERE unmapped.sku_id NOT IN (SELECT sku_id FROM sku_wine_product_map)
                      AND unmapped.sku_id IN (SELECT DISTINCT sku_id FROM sales_transaction)
                      AND unmapped.sku_group IS NOT NULL
                      AND mapped_sku.sku_group IS NOT NULL
                """)
                rows = cur.fetchall()

                matched = 0
                for sku_id, wp_code, unmapped_code, mapped_code, group in rows:
                    cur.execute("""
                        INSERT INTO sku_wine_product_map
                            (sku_id, wine_product_code, mapping_method, confidence, notes)
                        VALUES (%s, %s, 'group_sibling', 0.95, %s)
                        ON CONFLICT (sku_id) DO NOTHING
                    """, (sku_id, wp_code,
                          f"sku_group='{group}' sibling={mapped_code}"))
                    matched += 1

            self.db_conn.commit()
            logger.info("Method 3 (group_sibling): matched %d SKUs", matched)
            return matched

        except Exception as exc:
            self.db_conn.rollback()
            logger.error("Method 3 failed: %s", exc)
            raise

    def _method_4_description_similarity(self) -> int:
        """Method 4: pg_trgm similarity() between sku.item_description and wine_product.description."""
        try:
            with self.db_conn.cursor() as cur:
                # Get unmapped SKUs with sales
                cur.execute("""
                    SELECT DISTINCT s.sku_id, s.sku_code, s.item_description
                    FROM sku s
                    JOIN sales_transaction st ON st.sku_id = s.sku_id
                    WHERE s.sku_id NOT IN (SELECT sku_id FROM sku_wine_product_map)
                      AND s.item_description IS NOT NULL
                """)
                unmapped = cur.fetchall()

                matched = 0
                for sku_id, sku_code, desc in unmapped:
                    # Clean description for matching
                    clean_desc = re.sub(r'\b\d{4}\b', '', desc).strip()
                    clean_desc = re.sub(r'\s+', ' ', clean_desc)

                    # Find best matching wine_product by similarity
                    cur.execute("""
                        SELECT wine_product_code, description,
                               similarity(LOWER(description), LOWER(%s)) as sim
                        FROM wine_product
                        WHERE similarity(LOWER(description), LOWER(%s)) > 0.3
                        ORDER BY sim DESC
                        LIMIT 1
                    """, (clean_desc, clean_desc))
                    result = cur.fetchone()

                    if result:
                        wp_code, wp_desc, sim_score = result
                        confidence = min(0.9, round(float(sim_score), 2))
                        cur.execute("""
                            INSERT INTO sku_wine_product_map
                                (sku_id, wine_product_code, mapping_method, confidence,
                                 similarity_score, notes)
                            VALUES (%s, %s, 'description_similarity', %s, %s, %s)
                            ON CONFLICT (sku_id) DO NOTHING
                        """, (sku_id, wp_code, confidence, round(float(sim_score), 4),
                              f"'{desc}' ~ '{wp_desc}' (sim={sim_score:.3f})"))
                        matched += 1

            self.db_conn.commit()
            logger.info("Method 4 (description_similarity): matched %d SKUs", matched)
            return matched

        except Exception as exc:
            self.db_conn.rollback()
            logger.error("Method 4 failed: %s", exc)
            raise

    def _get_coverage_stats(self) -> dict:
        """Get coverage statistics."""
        with self.db_conn.cursor() as cur:
            cur.execute("""
                SELECT
                    (SELECT COUNT(DISTINCT sku_id) FROM sales_transaction) as total_skus_with_sales,
                    (SELECT COUNT(*) FROM sku_wine_product_map) as mapped_skus,
                    (SELECT COUNT(*) FROM sku_wine_product_map WHERE mapping_method = 'direct_code') as method_1,
                    (SELECT COUNT(*) FROM sku_wine_product_map WHERE mapping_method = 'sku_code_map') as method_2,
                    (SELECT COUNT(*) FROM sku_wine_product_map WHERE mapping_method = 'group_sibling') as method_3,
                    (SELECT COUNT(*) FROM sku_wine_product_map WHERE mapping_method = 'description_similarity') as method_4
            """)
            row = cur.fetchone()
            total = row[0]
            mapped = row[1]
            pct = (mapped / total * 100) if total > 0 else 0

            return {
                "total_skus_with_sales": total,
                "mapped_skus": mapped,
                "coverage_pct": round(pct, 1),
                "by_method": {
                    "direct_code": row[2],
                    "sku_code_map": row[3],
                    "group_sibling": row[4],
                    "description_similarity": row[5],
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

    mapper = WineProductMapper(db_connection_string=database_url)
    try:
        print("=== Building Wine Product Map ===")
        results = mapper.build_all()
        print(f"\nResults: {json.dumps(results, indent=2)}")

        pct = results.get("coverage_pct", 0)
        target = 90
        if pct >= target:
            print(f"\n✅ Coverage {pct}% >= {target}% target")
        else:
            print(f"\n⚠️ Coverage {pct}% < {target}% target — {results['total_skus_with_sales'] - results['mapped_skus']} SKUs unmapped")

    except Exception as exc:
        logger.error("Build failed: %s", exc, exc_info=True)
        sys.exit(1)
    finally:
        mapper.close()
