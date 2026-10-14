"""
F-05: Pull COGS and Regions from Vinsight Staging Data

Populates sku.vinsight_cogs from staging_vinsight_stock_items.StandardCost
(historical cost per packaging operation, locked at bottling time).

Also populates sku.region by parsing the Region tag from Vinsight's
ProductCategories field, with brand-based fallback and manual overrides.

The detailed composition breakdown (Fruit/Additives/Packaging) requires
an API endpoint not yet discovered. For now, StandardCost gives us the
correct total COGS per vintage-SKU (matches the owner's screenshot: $63.21
for MVLKSHZB23).

Usage:
    DATABASE_URL=postgresql://... python -m etl.sync_composition_from_staging
"""

import logging
import os
import sys

import psycopg2

from etl.logger import log_etl_run

logger = logging.getLogger("moppity.etl.sync_composition_from_staging")


def main():
    database_url = os.environ.get("DATABASE_URL")
    if not database_url:
        print("ERROR: DATABASE_URL not set", file=sys.stderr)
        sys.exit(1)

    conn = psycopg2.connect(database_url)
    conn.autocommit = False

    try:
        with conn.cursor() as cur:
            # Step 1: Update sku.transfer_cost from Vinsight StandardCost
            # StandardCost = total cost per unit (12x750mL case), locked at bottling
            # This is the CORRECT historical COGS per the owner's Mar 26 feedback
            cur.execute("""
                UPDATE sku s
                SET transfer_cost = (si.raw_data->>'StandardCost')::numeric
                FROM staging_vinsight_stock_items si
                WHERE si.raw_data->>'StockItemCode' = s.sku_code
                  AND (si.raw_data->>'IsPackagedWine')::boolean = true
                  AND (si.raw_data->>'StandardCost')::numeric > 0
                  AND (s.transfer_cost IS NULL OR s.transfer_cost = 0
                       OR s.transfer_cost != (si.raw_data->>'StandardCost')::numeric)
            """)
            cogs_updated = cur.rowcount
            logger.info("Updated %d SKU transfer_cost from Vinsight StandardCost", cogs_updated)

            # Step 2: Also update via sku_code_map for DWS/ALM codes that
            # have a linked Vinsight stock item
            cur.execute("""
                UPDATE sku s
                SET transfer_cost = COALESCE(
                    (SELECT (si.raw_data->>'StandardCost')::numeric
                     FROM staging_vinsight_stock_items si
                     JOIN sku_code_map scm ON scm.external_code = si.raw_data->>'StockItemNum'
                     WHERE scm.sku_id = s.sku_id AND scm.source_system = 'vinsight'
                       AND (si.raw_data->>'StandardCost')::numeric > 0
                     LIMIT 1),
                    s.transfer_cost
                )
                WHERE s.transfer_cost IS NULL OR s.transfer_cost = 0
            """)
            cogs_via_map = cur.rowcount
            logger.info("Updated %d additional SKUs via sku_code_map bridge", cogs_via_map)

            # Step 3: For SKUs still missing transfer_cost, use canonical_sku.cogs
            # (the owner's NV-level average from his spreadsheet)
            cur.execute("""
                UPDATE sku s
                SET transfer_cost = cs.cogs
                FROM canonical_sku cs
                WHERE s.canonical_sku_id = cs.id
                  AND (s.transfer_cost IS NULL OR s.transfer_cost = 0)
                  AND cs.cogs IS NOT NULL AND cs.cogs > 0
            """)
            cogs_from_canonical = cur.rowcount
            logger.info("Updated %d SKUs from canonical_sku.cogs fallback", cogs_from_canonical)

            # Step 4a: Parse Region from Vinsight ProductCategories tags
            # Joins staging_vinsight_stock_items → sku_code_map → sku.
            # Normalises known abbreviations: sesa/sea → South East Australia,
            # tumba → Tumbarumba; INITCAP for everything else.
            cur.execute("""
                WITH vinsight_regions AS (
                    SELECT DISTINCT ON (scm.sku_id)
                        scm.sku_id,
                        CASE
                            WHEN LOWER(x.parsed) IN ('sesa', 'sea')
                                THEN 'South East Australia'
                            WHEN LOWER(TRIM(x.parsed)) = 'tumba'
                                THEN 'Tumbarumba'
                            ELSE INITCAP(TRIM(x.parsed))
                        END AS region
                    FROM staging_vinsight_stock_items s
                    JOIN sku_code_map scm
                        ON  scm.source_system = 'vinsight'
                        AND scm.external_code = s.raw_data->>'StockItemCode'
                    CROSS JOIN LATERAL (
                        SELECT SUBSTRING(
                            s.raw_data->>'ProductCategories'
                            FROM '(?i)region:([^;]+)'
                        ) AS parsed
                    ) x
                    WHERE x.parsed IS NOT NULL
                      AND TRIM(x.parsed) != ''
                    ORDER BY scm.sku_id,
                             s.raw_data->>'IsActive' DESC
                )
                UPDATE sku
                SET region = vr.region
                FROM vinsight_regions vr
                WHERE sku.sku_id = vr.sku_id
                  AND sku.region IS DISTINCT FROM vr.region
            """)
            regions_from_tags = cur.rowcount
            logger.info("Step 4a: Updated %d SKU regions from ProductCategories tags", regions_from_tags)

            # Step 4b: Brand-based fallback for SKUs still without region
            # Coppabella / Procella (non-Clare) → Tumbarumba
            cur.execute("""
                UPDATE sku
                SET region = 'Tumbarumba'
                WHERE region IS NULL
                  AND (
                      item_description ILIKE '%%coppabella%%'
                      OR (item_description ILIKE '%%procella%%'
                          AND item_description NOT ILIKE '%%clare%%'
                          AND item_description NOT ILIKE '%%cv %%')
                  )
            """)
            fallback_tumbarumba = cur.rowcount

            # Moppity / Lock & Key / Twelve Signs / Cato → Hilltops
            cur.execute("""
                UPDATE sku
                SET region = 'Hilltops'
                WHERE region IS NULL
                  AND (
                      item_description ILIKE '%%moppity%%'
                      OR item_description ILIKE '%%lock & key%%'
                      OR item_description ILIKE '%%lock&key%%'
                      OR item_description ILIKE '%%twelve signs%%'
                      OR item_description ILIKE '%%cato%%'
                  )
            """)
            fallback_hilltops = cur.rowcount

            regions_fallback = fallback_tumbarumba + fallback_hilltops
            logger.info(
                "Step 4b: Brand fallback assigned %d regions (%d Tumbarumba, %d Hilltops)",
                regions_fallback, fallback_tumbarumba, fallback_hilltops,
            )

            # Step 4c REMOVED 2026-05-09 (B4B-141): override now applied at view-read via COALESCE in combined_data_enriched. sku.region stays as Vinsight mirror.

            regions_updated = regions_from_tags + regions_fallback

            # ───────────────────────────────────────────────────────────
            # Step 5: B4A vintage backfill — extend sale_vintage_attribution
            # for Access/Direct/Vinsight rows where source code carries vintage.
            #
            # Mirror schema/140 (one-shot migration applied 2026-05-08).
            # This step is idempotent (ON CONFLICT DO NOTHING) and safe to
            # re-run on every nightly sync, so newly-imported rows whose
            # ItemCode/ItemDescription carries a vintage year auto-populate
            # without a manual migration.
            #
            # We DO NOT read combined_data_enriched here because schema/132
            # redefined cde.upload_id to surface Access raw_data->>'ID' for
            # access_db rows (NOT sales_transaction.transaction_id) — would
            # FK-fail. Re-derive item_code/item_description COALESCE chain
            # from sales_transaction joins directly.
            #
            # Strict regex `[A-Z]+[0-9]{2}[A-Z]?$` on item_code, then a
            # 4-digit-year fallback on item_description (mirrors schema/075
            # and ingest_access_vintages.py).
            # ───────────────────────────────────────────────────────────
            cur.execute(r"""
                WITH cand AS (
                    SELECT
                        st.transaction_id,
                        COALESCE(
                            -- B3-4 shape guard (2026-05-11): only short codes
                            -- (<= 30 chars). schema/155 revert — description
                            -- text contamination cascaded into resolved_item_code.
                            NULLIF(CASE WHEN LENGTH(ac.raw_data->>'ItemCode') <= 30
                                        THEN ac.raw_data->>'ItemCode' END, ''),
                            vsoi.stock_item_code,
                            s.sku_code,
                            ''
                        ) AS resolved_item_code
                    FROM sales_transaction st
                    LEFT JOIN sku s ON s.sku_id = st.sku_id
                    LEFT JOIN access_combined_data ac
                           ON ac.raw_data->>'ID' = st.source_ref
                          AND st.source_system = 'access_db'
                    LEFT JOIN vinsight_sales_order_item vsoi
                           ON vsoi.order_num = (CASE WHEN st.source_ref ~ '^vinsight-[0-9]+-[0-9]+$'
                                                     THEN split_part(st.source_ref, '-', 2)::int END)
                          AND vsoi.entry_num = (CASE WHEN st.source_ref ~ '^vinsight-[0-9]+-[0-9]+$'
                                                     THEN split_part(st.source_ref, '-', 3)::int END)
                          AND st.source_system = 'vinsight'
                    LEFT JOIN sale_vintage_attribution sva
                           ON sva.sales_transaction_id = st.transaction_id
                    WHERE COALESCE(s.vintage, sva.attributed_vintage) IS NULL
                      AND NOT EXISTS (
                          SELECT 1 FROM sale_vintage_attribution s2
                           WHERE s2.sales_transaction_id = st.transaction_id
                      )
                )
                INSERT INTO sale_vintage_attribution
                    (sales_transaction_id, attributed_vintage, attribution_method,
                     confidence, notes, created_at, updated_at)
                SELECT
                    cand.transaction_id,
                    2000 + SUBSTRING(cand.resolved_item_code FROM '([0-9]{2})[A-Z]?$')::INT,
                    'access_code_regex',
                    0.85,
                    'sync_composition step5: code regex item_code=' || cand.resolved_item_code,
                    now(), now()
                FROM cand
                WHERE cand.resolved_item_code ~ '[A-Z]+[0-9]{2}[A-Z]?$'
                  AND SUBSTRING(cand.resolved_item_code FROM '([0-9]{2})[A-Z]?$')::INT BETWEEN 0 AND 30
                ON CONFLICT (sales_transaction_id) DO NOTHING
            """)
            sva_from_code = cur.rowcount

            cur.execute(r"""
                WITH cand AS (
                    SELECT
                        st.transaction_id,
                        COALESCE(
                            NULLIF(ac.raw_data->>'ItemDescription', ''),
                            vsoi.description,
                            s.item_description,
                            ''
                        ) AS resolved_desc
                    FROM sales_transaction st
                    LEFT JOIN sku s ON s.sku_id = st.sku_id
                    LEFT JOIN access_combined_data ac
                           ON ac.raw_data->>'ID' = st.source_ref
                          AND st.source_system = 'access_db'
                    LEFT JOIN vinsight_sales_order_item vsoi
                           ON vsoi.order_num = (CASE WHEN st.source_ref ~ '^vinsight-[0-9]+-[0-9]+$'
                                                     THEN split_part(st.source_ref, '-', 2)::int END)
                          AND vsoi.entry_num = (CASE WHEN st.source_ref ~ '^vinsight-[0-9]+-[0-9]+$'
                                                     THEN split_part(st.source_ref, '-', 3)::int END)
                          AND st.source_system = 'vinsight'
                    LEFT JOIN sale_vintage_attribution sva
                           ON sva.sales_transaction_id = st.transaction_id
                    WHERE COALESCE(s.vintage, sva.attributed_vintage) IS NULL
                      AND NOT EXISTS (
                          SELECT 1 FROM sale_vintage_attribution s2
                           WHERE s2.sales_transaction_id = st.transaction_id
                      )
                )
                INSERT INTO sale_vintage_attribution
                    (sales_transaction_id, attributed_vintage, attribution_method,
                     confidence, notes, created_at, updated_at)
                SELECT
                    cand.transaction_id,
                    NULLIF(SUBSTRING(cand.resolved_desc FROM '(?<![0-9])(20[0-2][0-9]|19[0-9]{2})(?![0-9])'), '')::INT,
                    'description_year_regex',
                    0.80,
                    'sync_composition step5: desc regex item_description=' || LEFT(cand.resolved_desc, 80),
                    now(), now()
                FROM cand
                WHERE NULLIF(SUBSTRING(cand.resolved_desc FROM '(?<![0-9])(20[0-2][0-9]|19[0-9]{2})(?![0-9])'), '') IS NOT NULL
                ON CONFLICT (sales_transaction_id) DO NOTHING
            """)
            sva_from_desc = cur.rowcount
            sva_total = sva_from_code + sva_from_desc
            logger.info(
                "Step 5: SVA backfill — %d via code regex, %d via desc regex (total %d)",
                sva_from_code, sva_from_desc, sva_total,
            )

            conn.commit()

            # Report
            cur.execute("""
                SELECT
                    COUNT(*) as total,
                    COUNT(*) FILTER (WHERE transfer_cost > 0) as has_cogs,
                    COUNT(*) FILTER (WHERE transfer_cost IS NULL OR transfer_cost = 0) as no_cogs,
                    COUNT(*) FILTER (WHERE region IS NOT NULL AND region != 'Unknown') as has_region,
                    COUNT(*) FILTER (WHERE variety IS NOT NULL
                        AND EXISTS (SELECT 1 FROM sales_transaction st WHERE st.sku_id = sku.sku_id)
                        AND (transfer_cost IS NULL OR transfer_cost = 0)) as no_cogs_with_sales
                FROM sku
            """)
            total, has_cogs, no_cogs, has_region, no_cogs_sales = cur.fetchone()

            print("=" * 60)
            print("F-05: Sync COGS + Regions + Vintage Attribution from Vinsight Staging")
            print("=" * 60)
            print(f"\nCOGS updated:")
            print(f"  From Vinsight StandardCost:  {cogs_updated}")
            print(f"  From sku_code_map bridge:    {cogs_via_map}")
            print(f"  From canonical_sku fallback: {cogs_from_canonical}")
            print(f"\nRegions updated:")
            print(f"  From ProductCategories tags: {regions_from_tags}")
            print(f"  From brand fallback:         {regions_fallback}")
            print(f"  Total:                       {regions_updated}")
            print(f"  (Note: manual_region_override applied at view-read via COALESCE — see schema/141_b4b)")
            print(f"\nVintage attribution (B4A) inserted:")
            print(f"  From item_code regex:        {sva_from_code}")
            print(f"  From item_description regex: {sva_from_desc}")
            print(f"  Total:                       {sva_total}")
            print(f"\nOverall coverage:")
            print(f"  Total SKUs:          {total}")
            print(f"  Has COGS:            {has_cogs} ({has_cogs*100//total}%)")
            print(f"  No COGS:             {no_cogs}")
            print(f"  No COGS with sales:  {no_cogs_sales}")
            print(f"  Has region:          {has_region}")
            print("=" * 60)

            log_etl_run(
                db_conn=conn,
                source="vinsight_composition",
                endpoint="staging_sync",
                status="success",
                rows_processed=cogs_updated + cogs_via_map + cogs_from_canonical + regions_updated + sva_total,
                rows_skipped=0,
                error_count=no_cogs_sales,
                error_detail=f"{no_cogs_sales} SKUs with sales still missing COGS" if no_cogs_sales else None,
            )

    except Exception as exc:
        conn.rollback()
        logger.error("Failed: %s", exc)
        raise
    finally:
        conn.close()


if __name__ == "__main__":
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    )
    main()
