-- =============================================================================
-- Moppity Vineyards — Vintage COGS Assignment (016_vintage_cogs.sql)
-- =============================================================================
-- Version:   1.0
-- Created:   2026-04-01
-- Author:    Vladimir (Autoflux)
-- Task:      RECON-FIX-07
--
-- The owner's algorithm: For ALM/DWS sales where vintage is unknown,
-- find the most recent Vinsight dispatch of the SAME canonical product
-- to that channel BEFORE the sale date. Use that vintage's transfer_cost.
--
-- Matching chain:
--   sales_transaction.sku_id → sku.sku_code → canonical_sku.sku_name
--   → vinsight_sales_order_item.description (strip year) → vintage
--   → sku.transfer_cost (via vinsight stock_item_code)
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- Function: assign_vintage_cogs()
-- Backfills economic_cogs_per_unit and economic_cogs_total for all
-- sales_transaction rows where they are NULL.
-- Returns: total updated, vintage-matched, fallback-used
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION assign_vintage_cogs()
RETURNS TABLE(total_updated bigint, vintage_matched bigint, fallback_used bigint) AS $$
DECLARE
  v_matched bigint := 0;
  v_fallback bigint := 0;
BEGIN

  -- Step 1: Pre-compute Vinsight dispatches mapped to canonical products
  CREATE TEMP TABLE IF NOT EXISTS _vinsight_canonical ON COMMIT DROP AS
  SELECT
    vi.id AS vinsight_id,
    vi.date_despatched,
    vi.vintage,
    vi.stock_item_code,
    cs.id AS canonical_id,
    CASE
      WHEN vi.contact_code LIKE 'ALM%' THEN 'ALM'
      WHEN vi.contact_code LIKE 'DWS%' THEN 'DWS'
      ELSE 'OTHER'
    END AS channel_group
  FROM vinsight_sales_order_item vi
  JOIN canonical_sku cs
    ON UPPER(cs.sku_name) = UPPER(REGEXP_REPLACE(vi.description, '\s*\d{4}$', ''))
  WHERE vi.vintage > 0
    AND vi.date_despatched IS NOT NULL;

  CREATE INDEX ON _vinsight_canonical (canonical_id, channel_group, date_despatched DESC);

  -- Step 2: Pre-compute transfer_cost lookup by Vinsight stock_item_code
  -- Pick Moppity-canonical codes (MV*) preferentially
  CREATE TEMP TABLE IF NOT EXISTS _sku_cost ON COMMIT DROP AS
  SELECT DISTINCT ON (sku_code)
    sku_code,
    transfer_cost
  FROM sku
  WHERE transfer_cost IS NOT NULL AND transfer_cost > 0
  ORDER BY sku_code, CASE WHEN sku_code LIKE 'MV%' THEN 0 ELSE 1 END;

  CREATE INDEX ON _sku_cost (sku_code);

  -- Step 3: Map each sale to its canonical product
  CREATE TEMP TABLE IF NOT EXISTS _sale_canonical ON COMMIT DROP AS
  SELECT
    st.transaction_id,
    st.sale_date,
    st.quantity,
    st.warehouse,
    cs.id AS canonical_id,
    cs.transfer_cost AS fallback_cost
  FROM sales_transaction st
  JOIN sku s ON s.sku_id = st.sku_id
  JOIN canonical_sku cs ON UPPER(cs.sku_name) = UPPER(s.sku_code)
  WHERE st.economic_cogs_per_unit IS NULL;

  CREATE INDEX ON _sale_canonical (canonical_id, warehouse, sale_date);

  -- Step 4: Find best Vinsight dispatch match for each sale
  -- Uses DISTINCT ON to get the most recent dispatch before sale_date
  CREATE TEMP TABLE IF NOT EXISTS _sale_vintage_match ON COMMIT DROP AS
  SELECT DISTINCT ON (sc.transaction_id)
    sc.transaction_id,
    sc.quantity,
    sc.fallback_cost,
    vc.stock_item_code,
    vc.vintage,
    skc.transfer_cost AS vintage_cost
  FROM _sale_canonical sc
  JOIN _vinsight_canonical vc
    ON vc.canonical_id = sc.canonical_id
    AND vc.date_despatched < sc.sale_date
    AND (
      (sc.warehouse IN ('ALM', 'ILG', 'Y&R-ALM') AND vc.channel_group = 'ALM')
      OR (sc.warehouse = 'DWS' AND vc.channel_group = 'DWS')
      OR (sc.warehouse = 'Direct' AND TRUE)  -- Direct: any channel dispatch
    )
  LEFT JOIN _sku_cost skc ON skc.sku_code = vc.stock_item_code
  ORDER BY sc.transaction_id, vc.date_despatched DESC;

  -- Step 5a: Update rows that have a vintage match with transfer_cost
  UPDATE sales_transaction st SET
    economic_cogs_per_unit = vm.vintage_cost,
    economic_cogs_total = vm.vintage_cost * vm.quantity
  FROM _sale_vintage_match vm
  WHERE st.transaction_id = vm.transaction_id
    AND vm.vintage_cost IS NOT NULL
    AND vm.vintage_cost > 0;

  GET DIAGNOSTICS v_matched = ROW_COUNT;

  -- Step 5b: For vintage matches WITHOUT transfer_cost, and unmatched rows,
  -- use fallback (canonical_sku.transfer_cost)
  UPDATE sales_transaction st SET
    economic_cogs_per_unit = sc.fallback_cost,
    economic_cogs_total = sc.fallback_cost * sc.quantity
  FROM _sale_canonical sc
  WHERE st.transaction_id = sc.transaction_id
    AND st.economic_cogs_per_unit IS NULL
    AND sc.fallback_cost IS NOT NULL
    AND sc.fallback_cost > 0;

  GET DIAGNOSTICS v_fallback = ROW_COUNT;

  RETURN QUERY SELECT (v_matched + v_fallback), v_matched, v_fallback;

END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION assign_vintage_cogs() IS
'RECON-FIX-07: the owner''s vintage COGS approximation. Matches ALM/DWS sales to most recent Vinsight dispatch of same product before sale date. Uses vintage-specific transfer_cost, falls back to canonical average.';

COMMIT;
