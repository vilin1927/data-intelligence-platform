-- schema/096_b9_inventory_location_drill.sql
-- Bundle B9 — JC-262 + JC-265 + JC-270 + JC-281: per-location vintage
-- drill-down with months-of-cover.
--
-- Source: inventory_stocks_on_hand (Moppity-owned + DWS consignment, ALM
-- explicitly EXCLUDED per JC-262), joined to canonical_sku for vintage,
-- and to sales_transaction for 12-month velocity → months-of-cover.
--
-- Forward-only: CREATE OR REPLACE VIEW. No DROP / no schema change to
-- underlying tables.

BEGIN;

-- ------------------------------------------------------------------------
-- Pre-state assertion
-- ------------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name = 'inventory_stocks_on_hand'
    ) THEN
        RAISE EXCEPTION
            'B9 prerequisite missing: inventory_stocks_on_hand. '
            'schema/095 must be applied before schema/096.';
    END IF;
END $$;

-- ------------------------------------------------------------------------
-- inventory_by_location_drill
-- ------------------------------------------------------------------------
-- One row per (canonical_sku × vintage × stock_location_code).
--
-- Warehouse classifier (mirrors /api/inventory/route.ts line 104-108):
--   warehouse_owner =
--     'DWS'     when stock_item_code matches a sku_code_map row with
--               source_system='dws'  (the DWS consignment hub holds the stock)
--     'Moppity' otherwise (Moppity-owned stock at any Vinsight warehouse)
--
-- ALM is NEVER joined here (JC-262: ALM takes ownership on purchase, so
-- ALM warehouses are NOT part of Moppity inventory).
--
-- Months-of-cover formula (JC-270):
--   velocity_12m = SUM(quantity over last 12mo) / DISTINCT months with sales
--   months_of_cover = units_in_stock / velocity_12m  (NULL when velocity=0)
CREATE OR REPLACE VIEW inventory_by_location_drill AS
WITH classified_stock AS (
    SELECT
        soh.id                          AS soh_id,
        soh.stock_item_code,
        soh.description,
        soh.stock_location_code,
        soh.units_in_stock,
        soh.units_in_stock_uom,
        soh.cost_per_unit,
        soh.total_value_of_stock,
        soh.status,
        CASE
            WHEN EXISTS (
                SELECT 1 FROM sku_code_map scm
                WHERE scm.source_system = 'dws'
                  AND scm.external_code = soh.stock_item_code
            ) THEN 'DWS'
            ELSE 'Moppity'
        END                             AS warehouse_owner,
        soh.source_system
    FROM inventory_stocks_on_hand soh
    WHERE soh.status = 'active'
      AND soh.units_in_stock > 0
),
sku_link AS (
    -- Promote canonical_sku metadata for vintage roll-up. LEFT JOIN so
    -- unlinked codes still appear (with NULL canonical_sku_id).
    SELECT
        cs.stock_item_code,
        s.sku_id,
        s.vintage,
        s.canonical_sku_id,
        csk.sku_name        AS canonical_sku_name,
        csk.range_name,
        csk.units_per_case
    FROM classified_stock cs
    LEFT JOIN LATERAL (
        SELECT s2.sku_id, s2.vintage, s2.canonical_sku_id
        FROM sku_code_map scm
        JOIN sku s2 ON s2.sku_id = scm.sku_id
        WHERE scm.source_system = 'vinsight'
          AND scm.external_code = cs.stock_item_code
        ORDER BY s2.sku_id
        LIMIT 1
    ) s ON TRUE
    LEFT JOIN canonical_sku csk
        ON csk.id = s.canonical_sku_id
),
velocity AS (
    -- 12-month velocity per sku_id (cases/month). DWS sales appear via
    -- channel='DWS' on sales_transaction, so DWS consignment SKUs DO get
    -- a velocity number (sell-through revenue). ALM channel sales are
    -- ignored here because ALM stock is excluded from inventory upstream.
    SELECT
        st.sku_id,
        CASE WHEN COUNT(DISTINCT date_trunc('month', st.sale_date)) > 0
            THEN SUM(st.quantity)::numeric
                 / COUNT(DISTINCT date_trunc('month', st.sale_date))
            ELSE 0
        END                             AS velocity_12m
    FROM sales_transaction st
    WHERE st.sale_date >= CURRENT_DATE - INTERVAL '12 months'
      AND st.quantity > 0
    GROUP BY st.sku_id
)
SELECT
    cs.soh_id,
    cs.stock_item_code,
    cs.description,
    cs.stock_location_code,
    cs.warehouse_owner,
    cs.units_in_stock,
    cs.units_in_stock_uom,
    cs.cost_per_unit,
    cs.total_value_of_stock,
    cs.status,
    sl.sku_id,
    sl.vintage,
    sl.canonical_sku_id,
    sl.canonical_sku_name,
    sl.range_name,
    sl.units_per_case,
    COALESCE(v.velocity_12m, 0)::numeric(12,2)  AS velocity_12m,
    CASE
        WHEN COALESCE(v.velocity_12m, 0) > 0
        THEN ROUND((cs.units_in_stock / v.velocity_12m)::numeric, 1)
        ELSE NULL
    END                                          AS months_of_cover
FROM classified_stock cs
LEFT JOIN sku_link sl
    ON sl.stock_item_code = cs.stock_item_code
LEFT JOIN velocity v
    ON v.sku_id = sl.sku_id;

COMMENT ON VIEW inventory_by_location_drill IS
    'B9 JC-262/265/270/281: per-SKU per-location stock with months-of-cover. '
    'ALM excluded by design (no ALM rows in inventory_stocks_on_hand). '
    'DWS classifier matches /api/inventory/route.ts:104-108 (sku_code_map '
    'source_system=dws). Months-of-cover NULL when 12m velocity = 0.';

COMMIT;
