"""
B9 JC-269 + JC-300 — Sync Vinsight Stock Item master to inventory_stock_item.

Refreshes the canonical inventory_stock_item table from staging_vinsight_stock_items.
Targets 742 rows (active + inactive + archived) per JC-269 master sheet count.

JC-300 motivation: Vinsight syncs MUST include archived items so old vintages
(e.g. Moppity Creo Pet Naturel) keep region/variety/COGS metadata even when
their current stock = 0.

first to refresh staging_vinsight_stock_items. This script is the
staging → typed-table promotion step.

Usage:
    DATABASE_URL=postgresql://... python -m etl.sync_vinsight_stock_items
"""

import logging
import os
import sys

import psycopg2
import psycopg2.extras

from etl.logger import log_etl_run

logger = logging.getLogger("moppity.etl.sync_vinsight_stock_items")


# row extract-xlsx-0041 (HARD source: Apr 14 2026 Vinsight CSV).
EXPECTED_STOCK_ITEM_COUNT = 742


def _coerce_bool(val):
    if val is None:
        return None
    if isinstance(val, bool):
        return val
    s = str(val).strip().lower()
    if s in ("true", "1", "yes", "y", "t"):
        return True
    if s in ("false", "0", "no", "n", "f", ""):
        return False
    return None


def _coerce_numeric(val):
    if val is None:
        return None
    s = str(val).strip()
    if not s:
        return None
    try:
        return float(s)
    except (TypeError, ValueError):
        return None


def _coerce_int(val):
    if val is None:
        return None
    s = str(val).strip()
    if not s:
        return None
    try:
        return int(float(s))
    except (TypeError, ValueError):
        return None


def main():
    database_url = os.environ.get("DATABASE_URL")
    if not database_url:
        print("ERROR: DATABASE_URL not set", file=sys.stderr)
        sys.exit(1)

    conn = psycopg2.connect(database_url)
    conn.autocommit = False  # explicit BEGIN/COMMIT per HARD-RULES

    rows_upserted = 0
    rows_skipped = 0

    try:
        with conn.cursor() as cur:
            # Pre-flight: ensure target table exists.
            cur.execute("""
                SELECT 1 FROM information_schema.tables
                WHERE table_schema = 'public'
                  AND table_name = 'inventory_stock_item'
            """)
            if cur.fetchone() is None:
                raise RuntimeError(
                    "inventory_stock_item missing — apply schema/095 first."
                )

            # B9.2 fix: Vinsight /StockItems.json payload uses `StockItemNum`,
            # not `Id` (probed on prod 2026-04-28). Coalesce both for forward
            # compat with any legacy-named rows that may still exist.
            cur.execute("""
                SELECT
                    si.raw_data,
                    si.fetched_at
                FROM staging_vinsight_stock_items si
                JOIN (
                    SELECT
                        COALESCE(raw_data->>'StockItemNum', raw_data->>'Id')::int AS vid,
                        MAX(fetched_at)                                            AS latest
                    FROM staging_vinsight_stock_items
                    WHERE raw_data ? 'StockItemNum' OR raw_data ? 'Id'
                    GROUP BY COALESCE(raw_data->>'StockItemNum', raw_data->>'Id')::int
                ) latest
                  ON COALESCE(si.raw_data->>'StockItemNum', si.raw_data->>'Id')::int = latest.vid
                 AND si.fetched_at = latest.latest
            """)
            rows = cur.fetchall()
            logger.info(
                "Loaded %d distinct stock items from staging_vinsight_stock_items",
                len(rows),
            )

            for raw, fetched_at in rows:
                # B9.2 fix: Vinsight /StockItems.json payload uses `StockItemNum`,
                # not `Id`/`ID`/`id`. Probed on prod 2026-04-28 — `Id` returned None
                # for every row, causing 947/947 to skip on the vid-None guard below.
                vid = _coerce_int(
                    raw.get("StockItemNum")
                    or raw.get("Id") or raw.get("ID") or raw.get("id")
                )
                code = raw.get("StockItemCode")
                if vid is None or not code:
                    rows_skipped += 1
                    continue

                description       = raw.get("Description")
                supplier_name     = raw.get("SupplierName")
                product_category  = raw.get("ProductCategories")
                is_packaged_wine  = _coerce_bool(raw.get("IsPackagedWine"))
                is_dry_goods      = _coerce_bool(raw.get("IsDryGoods"))
                is_archived       = _coerce_bool(raw.get("IsArchived")) or False
                # Vinsight stock-items payload uses boolean `IsActive`. Older
                # endpoints used `Status='Active'/'Inactive'` or `Active`. Try
                # IsActive first; fall through to legacy keys; default True.
                if "IsActive" in raw:
                    is_active = bool(_coerce_bool(raw.get("IsActive"))) if raw.get("IsActive") is not None else True
                else:
                    status_raw = raw.get("Status") or raw.get("Active")
                    if isinstance(status_raw, str):
                        is_active = status_raw.strip().lower() in ("active", "true", "1")
                    else:
                        is_active = bool(_coerce_bool(status_raw)) if status_raw is not None else True
                # Archived items are inactive even if IsActive missing.
                if is_archived:
                    is_active = False

                standard_cost  = _coerce_numeric(raw.get("StandardCost"))
                base_wholesale = _coerce_numeric(raw.get("BaseWholesale"))
                units_per_case = _coerce_numeric(raw.get("UnitsPerCase"))

                cur.execute(
                    """
                    INSERT INTO inventory_stock_item (
                        vinsight_id, stock_item_code, description, supplier_name,
                        product_category, is_packaged_wine, is_dry_goods,
                        is_archived, is_active,
                        standard_cost, base_wholesale, units_per_case,
                        raw_data, fetched_at, updated_at
                    )
                    VALUES (
                        %s, %s, %s, %s,
                        %s, %s, %s,
                        %s, %s,
                        %s, %s, %s,
                        %s::jsonb, %s, NOW()
                    )
                    ON CONFLICT (vinsight_id) DO UPDATE SET
                        stock_item_code  = EXCLUDED.stock_item_code,
                        description      = EXCLUDED.description,
                        supplier_name    = EXCLUDED.supplier_name,
                        product_category = EXCLUDED.product_category,
                        is_packaged_wine = EXCLUDED.is_packaged_wine,
                        is_dry_goods     = EXCLUDED.is_dry_goods,
                        is_archived      = EXCLUDED.is_archived,
                        is_active        = EXCLUDED.is_active,
                        standard_cost    = EXCLUDED.standard_cost,
                        base_wholesale   = EXCLUDED.base_wholesale,
                        units_per_case   = EXCLUDED.units_per_case,
                        raw_data         = EXCLUDED.raw_data,
                        fetched_at       = EXCLUDED.fetched_at,
                        updated_at       = NOW()
                    """,
                    (
                        vid, code, description, supplier_name,
                        product_category, is_packaged_wine, is_dry_goods,
                        is_archived, is_active,
                        standard_cost, base_wholesale, units_per_case,
                        psycopg2.extras.Json(raw),
                        fetched_at,
                    ),
                )
                rows_upserted += 1

            cur.execute("SELECT COUNT(*) FROM inventory_stock_item")
            final_count = cur.fetchone()[0]

            log_etl_run(
                db_conn=conn,
                source="vinsight",
                endpoint="sync_vinsight_stock_items",
                status="success" if rows_upserted > 0 else "partial",
                rows_processed=rows_upserted,
                rows_skipped=rows_skipped,
                error_count=0,
                error_detail=None,
            )

        conn.commit()

        logger.info(
            "sync_vinsight_stock_items done: upserted=%d skipped=%d final_count=%d (target=%d)",
            rows_upserted, rows_skipped, final_count, EXPECTED_STOCK_ITEM_COUNT,
        )
        if final_count < EXPECTED_STOCK_ITEM_COUNT * 0.9:
            logger.warning(
                "Final count %d is well below target %d — Vinsight pull may not include archived items. "
                "Check connectors/vinsight.py:_sync_endpoint $top + IsArchived filter.",
                final_count, EXPECTED_STOCK_ITEM_COUNT,
            )

        return final_count

    except Exception:
        conn.rollback()
        logger.exception("sync_vinsight_stock_items failed; rolled back")
        raise
    finally:
        conn.close()


if __name__ == "__main__":
    logging.basicConfig(
        level=os.environ.get("LOG_LEVEL", "INFO"),
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    main()
