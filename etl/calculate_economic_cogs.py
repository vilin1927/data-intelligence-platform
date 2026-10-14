"""
Economic COGS Calculator — M2-COGS-ENGINE Step 4a.

Calculates economic_cogs_per_unit for every sale in sales_transaction
using: vintage attribution + grape composition + grape price rules.

For SKUs WITH grape composition (52 SKUs):
  → Weighted average of grape prices by proportion × tons_per_case

For SKUs WITHOUT composition (majority):
  → Derive variety/region from SKU metadata → single grape price lookup

Grape price cascade (most specific wins):
  1. region + color + grade + variety + vintage
  2. region + color + grade + vintage
  3. region + color + vintage
  4. region + vintage
  5. Nearest vintage if exact vintage not found

Usage:
    DATABASE_URL=postgresql://... python -m etl.calculate_economic_cogs
"""

import json
import logging
import os
import sys
from decimal import Decimal

import psycopg2
import psycopg2.extras

logger = logging.getLogger("moppity.etl.calculate_economic_cogs")

# Typical tons of grape per case of wine (12 bottles × 750mL)
# 1 ton of grapes ≈ 720 liters of juice ≈ 960 bottles ≈ 80 cases
TONS_PER_CASE = Decimal("0.0125")  # 1/80


class EconomicCOGSCalculator:
    """Calculates and persists economic COGS for all sales."""

    def __init__(self, db_connection_string: str) -> None:
        self.db_conn = psycopg2.connect(db_connection_string)
        self.db_conn.autocommit = False
        self._price_cache = {}
        self._composition_cache = {}
        self._sku_meta_cache = {}
        logger.info("EconomicCOGSCalculator initialised")

    def calculate_all(self) -> dict[str, int]:
        """Calculate economic COGS for all attributed sales."""
        results = {}

        # Load caches
        self._load_grape_prices()
        self._load_compositions()
        self._load_sku_metadata()

        # Calculate for sales with composition (high accuracy)
        results["with_composition"] = self._calc_with_composition()

        # Calculate for sales without composition (use SKU metadata)
        results["without_composition"] = self._calc_without_composition()

        # Calculate totals
        results["totals_updated"] = self._update_totals()

        results.update(self._get_stats())
        return results

    def _load_grape_prices(self):
        """Load all grape price rules into cache."""
        with self.db_conn.cursor() as cur:
            cur.execute("""
                SELECT region, color, grade, variety, vintage, price_per_ton
                FROM grape_price_rule
                ORDER BY vintage DESC
            """)
            for row in cur.fetchall():
                region, color, grade, variety, vintage, price = row
                key = (region, color, grade, variety, vintage)
                self._price_cache[key] = price

        logger.info("Loaded %d grape price rules", len(self._price_cache))

    def _load_compositions(self):
        """Load grape composition per SKU."""
        with self.db_conn.cursor() as cur:
            cur.execute("""
                SELECT
                    po.sku_id,
                    wb.variety,
                    wb.region,
                    wb.color,
                    pv.volume_litres,
                    SUM(ABS(pv.volume_litres)) OVER (PARTITION BY po.sku_id) as total_volume  -- BUG-26: ABS prevents negative vessel transfers from cancelling positives downstream. Mirrors 2026-04-14 fix in dashboard/src/app/api/{what-if,margins}/route.ts.
                FROM packaging_vessel pv
                JOIN packaging_operation po ON po.id = pv.packaging_operation_id
                JOIN vessel v ON v.id = pv.vessel_id
                JOIN wine_batch wb ON wb.id = v.wine_batch_id
                WHERE po.sku_id IS NOT NULL AND wb.variety IS NOT NULL
            """)
            for row in cur.fetchall():
                sku_id, variety, region, color, volume, total = row
                if sku_id not in self._composition_cache:
                    self._composition_cache[sku_id] = []
                proportion = abs(float(volume or 0)) / float(total or 1)
                self._composition_cache[sku_id].append({
                    "variety": variety,
                    "region": region or "Unknown",
                    "color": color or self._derive_color(variety),
                    "proportion": proportion,
                })

        logger.info("Loaded composition for %d SKUs", len(self._composition_cache))

    def _load_sku_metadata(self):
        """Load variety/region from SKU table for fallback."""
        with self.db_conn.cursor() as cur:
            cur.execute("""
                SELECT sku_id, variety, region, transfer_cost
                FROM sku
            """)
            for row in cur.fetchall():
                self._sku_meta_cache[row[0]] = {
                    "variety": row[1],
                    "region": row[2],
                    "transfer_cost": float(row[3]) if row[3] else None,
                }

        logger.info("Loaded metadata for %d SKUs", len(self._sku_meta_cache))

    def _get_grape_price(self, region: str, color: str, grade: int | None,
                         variety: str, vintage: int) -> Decimal | None:
        """Get grape price using cascade logic (most specific wins)."""
        # Try exact match first, then progressively less specific
        lookups = [
            (region, color, grade, variety, vintage),
            (region, color, grade, None, vintage),
            (region, color, None, None, vintage),
            (region, None, None, None, vintage),
        ]

        for key in lookups:
            if key in self._price_cache:
                return self._price_cache[key]

        # Try nearest vintage (any distance — grape prices are sparse, use closest available)
        for delta in range(1, 40):
            for v in [vintage - delta, vintage + delta]:
                for key_template in lookups:
                    adjusted_key = key_template[:4] + (v,)
                    if adjusted_key in self._price_cache:
                        return self._price_cache[adjusted_key]

        return None

    def _derive_color(self, variety: str | None) -> str:
        if not variety:
            return "red"
        v = variety.lower()
        whites = ['chardonnay', 'riesling', 'sauvignon', 'pinot gris', 'pinot grigio',
                  'moscato', 'prosecco', 'semillon', 'gewurztraminer']
        return "white" if any(w in v for w in whites) else "red"

    def _calc_with_composition(self) -> int:
        """Calculate COGS for SKUs with grape composition data."""
        try:
            with self.db_conn.cursor() as cur:
                cur.execute("""
                    SELECT st.transaction_id, st.sku_id, sva.attributed_vintage
                    FROM sales_transaction st
                    JOIN sale_vintage_attribution sva ON sva.sales_transaction_id = st.transaction_id
                    WHERE st.sku_id IN %s
                      AND st.economic_cogs_per_unit IS NULL
                """, (tuple(self._composition_cache.keys()),))
                rows = cur.fetchall()

                count = 0
                for txn_id, sku_id, vintage in rows:
                    components = self._composition_cache.get(sku_id, [])
                    if not components:
                        continue

                    total_cost = Decimal("0")
                    has_price = False
                    for comp in components:
                        price = self._get_grape_price(
                            comp["region"], comp["color"], None,
                            comp["variety"], vintage
                        )
                        if price:
                            total_cost += Decimal(str(comp["proportion"])) * price * TONS_PER_CASE
                            has_price = True

                    if has_price:
                        cur.execute(
                            "UPDATE sales_transaction SET economic_cogs_per_unit = %s WHERE transaction_id = %s",
                            (float(total_cost), txn_id)
                        )
                        count += 1

            self.db_conn.commit()
            logger.info("Calculated COGS for %d sales with composition", count)
            return count

        except Exception as exc:
            self.db_conn.rollback()
            logger.error("Composition COGS calc failed: %s", exc)
            raise

    def _calc_without_composition(self) -> int:
        """Calculate COGS for SKUs without composition — use SKU variety/region."""
        try:
            with self.db_conn.cursor() as cur:
                cur.execute("""
                    SELECT st.transaction_id, st.sku_id, sva.attributed_vintage
                    FROM sales_transaction st
                    JOIN sale_vintage_attribution sva ON sva.sales_transaction_id = st.transaction_id
                    WHERE st.economic_cogs_per_unit IS NULL
                """)
                rows = cur.fetchall()

                count = 0
                for txn_id, sku_id, vintage in rows:
                    meta = self._sku_meta_cache.get(sku_id, {})
                    variety = meta.get("variety")
                    region = meta.get("region")
                    color = self._derive_color(variety)

                    price = self._get_grape_price(
                        region or "Tumbarumba", color, None,
                        variety, vintage
                    )

                    if price:
                        cogs = float(price * TONS_PER_CASE)
                        cur.execute(
                            "UPDATE sales_transaction SET economic_cogs_per_unit = %s WHERE transaction_id = %s",
                            (cogs, txn_id)
                        )
                        count += 1

            self.db_conn.commit()
            logger.info("Calculated COGS for %d sales without composition", count)
            return count

        except Exception as exc:
            self.db_conn.rollback()
            logger.error("No-composition COGS calc failed: %s", exc)
            raise

    def _update_totals(self) -> int:
        """Set economic_cogs_total = economic_cogs_per_unit × quantity."""
        try:
            with self.db_conn.cursor() as cur:
                cur.execute("""
                    UPDATE sales_transaction
                    SET economic_cogs_total = economic_cogs_per_unit * quantity
                    WHERE economic_cogs_per_unit IS NOT NULL
                      AND (economic_cogs_total IS NULL
                           OR economic_cogs_total != economic_cogs_per_unit * quantity)
                """)
                count = cur.rowcount

            self.db_conn.commit()
            logger.info("Updated %d COGS totals", count)
            return count

        except Exception as exc:
            self.db_conn.rollback()
            logger.error("Totals update failed: %s", exc)
            raise

    def _get_stats(self) -> dict:
        with self.db_conn.cursor() as cur:
            cur.execute("""
                SELECT
                    count(*) as total_sales,
                    count(economic_cogs_per_unit) as with_cogs,
                    ROUND(AVG(economic_cogs_per_unit)::numeric, 2) as avg_cogs,
                    ROUND(SUM(economic_cogs_total)::numeric, 2) as total_economic_cogs,
                    ROUND(SUM(net_revenue)::numeric, 2) as total_revenue
                FROM sales_transaction
            """)
            row = cur.fetchone()
            total = row[0]
            with_cogs = row[1]

            return {
                "total_sales": total,
                "with_economic_cogs": with_cogs,
                "cogs_coverage_pct": round(with_cogs / total * 100, 1) if total > 0 else 0,
                "avg_cogs_per_unit": float(row[2]) if row[2] else 0,
                "total_economic_cogs": float(row[3]) if row[3] else 0,
                "total_revenue": float(row[4]) if row[4] else 0,
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

    calc = EconomicCOGSCalculator(db_connection_string=database_url)
    try:
        print("=== Calculating Economic COGS ===")
        results = calc.calculate_all()
        print(f"\nResults: {json.dumps(results, indent=2)}")

        pct = results.get("cogs_coverage_pct", 0)
        if pct >= 90:
            print(f"\n✅ COGS coverage {pct}%")
        else:
            print(f"\n⚠️ COGS coverage {pct}%")

        if results.get("total_revenue") and results.get("total_economic_cogs"):
            gp_pct = (1 - results["total_economic_cogs"] / results["total_revenue"]) * 100
            print(f"Overall GP%: {gp_pct:.1f}%")

    except Exception as exc:
        logger.error("Calculation failed: %s", exc, exc_info=True)
        sys.exit(1)
    finally:
        calc.close()
