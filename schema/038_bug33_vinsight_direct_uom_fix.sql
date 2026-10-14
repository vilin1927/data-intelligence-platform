-- =============================================================================
-- Moppity Vineyards — BUG-33 Fix: Vinsight Direct Revenue UOM Correction
-- =============================================================================
-- Version:   1.0
-- Created:   2026-04-17
-- Task:      BUG-33
--
--   Direct-channel Vinsight rows are 2-3x over-stated because schema/018's
--   sync_vinsight_direct_sales() hard-codes `unit_price = canonical_sku.base_wholesale`
--   (LIST wholesale), ignoring the per-invoice negotiated discount.
--   Customer 10 Feb 2026: CSV $4,960 vs DB $12,400 (2.5x).
--   Root CSV rows show Unit Price $310, Discount 60%, Net Price $124, Revenue $4,960.
--
-- Fix:
--   1. Add unit_price + discount_pct columns to vinsight_sales_order_item
--      (populated by the Python fetcher from /SalesOrderItems.json UnitPrice & Discount).
--   2. Rewrite sync_vinsight_direct_sales() to compute
--        line_net_price = unit_price * (1 - COALESCE(discount_pct, 0))
--      and fall back to canonical_sku.base_wholesale ONLY when unit_price is NULL/0.
--   3. Backfill existing sales_transaction rows from vinsight_sales_order_item
--      after the Python fetcher repopulates unit_price + discount.
--
-- Idempotent. Forward-only. No DROPs of existing data.
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Add pricing columns to vinsight_sales_order_item
-- ---------------------------------------------------------------------------

ALTER TABLE vinsight_sales_order_item
    ADD COLUMN IF NOT EXISTS unit_price    NUMERIC(12,4),
    ADD COLUMN IF NOT EXISTS discount_pct  NUMERIC(8,6);

COMMENT ON COLUMN vinsight_sales_order_item.unit_price IS
    'BUG-33: UnitPrice from /SalesOrderItems.json — list wholesale per-UOM (per case when UOM=12x750mL). Before discount.';
COMMENT ON COLUMN vinsight_sales_order_item.discount_pct IS
    'BUG-33: Discount fraction (0.60 = 60%) from /SalesOrderItems.json — negotiated per-line. NULL if not set.';


-- ---------------------------------------------------------------------------
-- 2. Rewrite sync_vinsight_direct_sales() to use actual line net price
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION sync_vinsight_direct_sales()
RETURNS TABLE(inserted bigint, skipped bigint, no_sku_match bigint) AS $$
DECLARE
  v_inserted bigint := 0;
  v_skipped bigint := 0;
  v_no_match bigint := 0;
  v_cutoff_date date;
  v_direct_channel_id int;
BEGIN

  -- Get the latest Access DB Direct sale date as cutoff
  SELECT COALESCE(MAX(sale_date), '2019-01-01')
  INTO v_cutoff_date
  FROM sales_transaction
  WHERE warehouse = 'Direct' AND source_system = 'access_db';

  -- Get Direct channel_id
  SELECT channel_id INTO v_direct_channel_id
  FROM channel WHERE channel_name = 'Direct';

  -- Build candidate rows from Vinsight items
  CREATE TEMP TABLE IF NOT EXISTS _vinsight_candidates ON COMMIT DROP AS
  SELECT
    vi.id AS vinsight_item_id,
    vi.order_num,
    vi.entry_num,
    COALESCE(vi.invoice_date, vi.date_despatched)::date AS sale_date,
    TO_CHAR(COALESCE(vi.invoice_date, vi.date_despatched), 'YYYY-MM') AS period,
    vi.quantity,
    vi.contact_code,
    vi.stock_item_code,
    vi.description,
    vi.vintage,
    -- Source ref for dedup
    'vinsight-' || vi.order_num || '-' || vi.entry_num AS source_ref,
    -- Try to find sku_id: first via sku_code_map, then via canonical name match
    COALESCE(
      scm.sku_id,
      (SELECT s.sku_id FROM sku s
       JOIN canonical_sku cs ON cs.id = s.canonical_sku_id
       WHERE UPPER(cs.sku_name) = UPPER(REGEXP_REPLACE(vi.description, '\s*\d{4}$', ''))
       LIMIT 1)
    ) AS sku_id,
    -- Customer via customer_code_map
    ccm.customer_id,
    -- BUG-33: unit_price = actual invoice-line net price (after discount),
    -- not the SKU's LIST wholesale. Fall back to canonical_sku.base_wholesale
    -- only when the API did not supply UnitPrice (legacy rows pre-BUG-33 fix).
    COALESCE(
      CASE
        WHEN vi.unit_price IS NOT NULL AND vi.unit_price > 0
          THEN vi.unit_price * (1 - COALESCE(vi.discount_pct, 0))
        ELSE NULL
      END,
      (SELECT cs.base_wholesale FROM canonical_sku cs
       JOIN sku s ON s.canonical_sku_id = cs.id
       JOIN sku_code_map scm2 ON scm2.sku_id = s.sku_id AND scm2.source_system = 'vinsight'
       WHERE scm2.external_code = vi.stock_item_code
       LIMIT 1),
      (SELECT cs.base_wholesale FROM canonical_sku cs
       WHERE UPPER(cs.sku_name) = UPPER(REGEXP_REPLACE(vi.description, '\s*\d{4}$', ''))
       LIMIT 1),
      0
    ) AS unit_price
  FROM vinsight_sales_order_item vi
  LEFT JOIN sku_code_map scm ON scm.external_code = vi.stock_item_code AND scm.source_system = 'vinsight'
  LEFT JOIN customer_code_map ccm ON ccm.external_name = vi.contact_code AND ccm.source_system = 'vinsight'
  WHERE vi.contact_code NOT LIKE 'ALM%'
    AND vi.contact_code NOT LIKE 'DWS%'
    AND vi.stock_item_code IS NOT NULL
    AND vi.stock_item_code != ''
    -- Filter out non-wine items
    AND vi.stock_item_code NOT IN ('Freight', 'Claims NO WET', 'Claims WET', 'Rounding adjustment',
      'Rounding', 'Staff Issue', 'Bulk Wine Sales', 'BAD DEBT WET', 'Sponsorship', 'Tokens',
      'Ice', 'Pallet', 'BAD DEBT')
    AND vi.stock_item_code NOT LIKE 'A-%'  -- Additives/chemicals
    AND vi.stock_item_code NOT LIKE 'B-%'  -- Bulk items
    AND vi.stock_item_code NOT LIKE 'L-%'  -- Labels
    AND vi.stock_item_code NOT LIKE 'S-%'  -- Stickers
    AND vi.stock_item_code NOT LIKE 'X-%'  -- Obsolete
    -- Only after Access DB cutoff
    AND COALESCE(vi.invoice_date, vi.date_despatched)::date > v_cutoff_date
    -- Must have a date
    AND COALESCE(vi.invoice_date, vi.date_despatched) IS NOT NULL;

  -- Count items with no SKU match
  SELECT COUNT(*) INTO v_no_match FROM _vinsight_candidates WHERE sku_id IS NULL;

  -- Count items that already exist in sales_transaction
  SELECT COUNT(*) INTO v_skipped
  FROM _vinsight_candidates vc
  WHERE EXISTS (
    SELECT 1 FROM sales_transaction st WHERE st.source_ref = vc.source_ref
  );

  -- Insert new rows
  INSERT INTO sales_transaction (
    sku_id, customer_id, channel_id, sale_date, period,
    quantity, unit_price, net_revenue, gross_revenue,
    warehouse, source_system, source_ref
  )
  SELECT
    vc.sku_id,
    vc.customer_id,
    v_direct_channel_id,
    vc.sale_date,
    vc.period,
    vc.quantity,
    vc.unit_price,
    vc.quantity * vc.unit_price,  -- net_revenue
    vc.quantity * vc.unit_price,  -- gross_revenue (Direct = no further discount)
    'Direct',
    'vinsight',
    vc.source_ref
  FROM _vinsight_candidates vc
  WHERE vc.sku_id IS NOT NULL
    AND vc.unit_price > 0
    AND NOT EXISTS (
      SELECT 1 FROM sales_transaction st WHERE st.source_ref = vc.source_ref
    );

  GET DIAGNOSTICS v_inserted = ROW_COUNT;

  -- Assign COGS to newly inserted rows
  IF v_inserted > 0 THEN
    PERFORM assign_vintage_cogs();
  END IF;

  RETURN QUERY SELECT v_inserted, v_skipped, v_no_match;

END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION sync_vinsight_direct_sales() IS
'BUG-33 (2026-04-17): Uses actual invoice-line net price (UnitPrice * (1 - Discount)) from vinsight_sales_order_item, falling back to canonical_sku.base_wholesale only when API pricing is absent. Previously hard-coded to base_wholesale which ignored the negotiated discount and inflated revenue 2-3x.';


-- ---------------------------------------------------------------------------
-- 3. Backfill: correct already-imported sales_transaction Vinsight rows
--    Runs only when vinsight_sales_order_item has unit_price populated
--    (i.e. after the Python fetcher runs post-migration).
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION backfill_bug33_vinsight_direct_prices()
RETURNS TABLE(rows_touched bigint, rows_unchanged bigint, rows_without_api_price bigint) AS $$
DECLARE
  v_touched bigint := 0;
  v_unchanged bigint := 0;
  v_no_api_price bigint := 0;
BEGIN

  -- Touched: rows where we now have a better price from the API
  WITH targets AS (
    SELECT
      st.transaction_id,
      st.quantity,
      st.unit_price       AS old_unit_price,
      st.net_revenue      AS old_net_revenue,
      vi.unit_price       AS api_unit_price,
      COALESCE(vi.discount_pct, 0) AS api_discount,
      (vi.unit_price * (1 - COALESCE(vi.discount_pct, 0))) AS new_unit_price
    FROM sales_transaction st
    JOIN vinsight_sales_order_item vi
      ON vi.order_num = split_part(st.source_ref, '-', 2)::int
     AND vi.entry_num = split_part(st.source_ref, '-', 3)::int
    WHERE st.source_system = 'vinsight'
      AND st.source_ref ~ '^vinsight-[0-9]+-[0-9]+$'
      AND vi.unit_price IS NOT NULL
      AND vi.unit_price > 0
  ), updated AS (
    UPDATE sales_transaction st
    SET unit_price    = t.new_unit_price,
        net_revenue   = t.quantity * t.new_unit_price,
        gross_revenue = t.quantity * t.new_unit_price
    FROM targets t
    WHERE st.transaction_id = t.transaction_id
      AND ABS(st.unit_price - t.new_unit_price) > 0.01
    RETURNING st.transaction_id
  )
  SELECT COUNT(*) INTO v_touched FROM updated;

  -- Unchanged: rows where the API net price already matched what we had
  SELECT COUNT(*) INTO v_unchanged
  FROM sales_transaction st
  JOIN vinsight_sales_order_item vi
    ON vi.order_num = split_part(st.source_ref, '-', 2)::int
   AND vi.entry_num = split_part(st.source_ref, '-', 3)::int
  WHERE st.source_system = 'vinsight'
    AND vi.unit_price IS NOT NULL AND vi.unit_price > 0
    AND ABS(st.unit_price - vi.unit_price * (1 - COALESCE(vi.discount_pct, 0))) <= 0.01;

  -- Without API price: legacy rows we couldn't correct (fetcher didn't get pricing yet)
  SELECT COUNT(*) INTO v_no_api_price
  FROM sales_transaction st
  LEFT JOIN vinsight_sales_order_item vi
    ON vi.order_num = split_part(st.source_ref, '-', 2)::int
   AND vi.entry_num = split_part(st.source_ref, '-', 3)::int
  WHERE st.source_system = 'vinsight'
    AND (vi.unit_price IS NULL OR vi.unit_price = 0);

  RETURN QUERY SELECT v_touched, v_unchanged, v_no_api_price;

END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION backfill_bug33_vinsight_direct_prices() IS
'BUG-33 backfill: rewrites sales_transaction.unit_price / net_revenue / gross_revenue for source_system=vinsight rows using the actual API-sourced UnitPrice * (1 - Discount). Safe to re-run.';

COMMIT;
