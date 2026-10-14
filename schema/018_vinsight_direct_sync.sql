-- =============================================================================
-- Moppity Vineyards — Vinsight Direct Sales Sync (018_vinsight_direct_sync.sql)
-- =============================================================================
-- Version:   1.0
-- Created:   2026-04-02
-- Task:      RECON-FIX-17
--
-- Transforms vinsight_sales_order_item → sales_transaction for Direct channel.
-- Uses canonical_sku.base_wholesale as unit_price (Direct = wholesale invoicing).
-- Only imports items after Access DB cutoff to avoid double-counting.
-- Skips non-wine items (Freight, Claims, Rounding, etc.)
-- Dedup via source_ref = 'vinsight-{order_num}-{entry_num}'
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- Function: sync_vinsight_direct_sales()
-- Syncs new Direct channel sales from vinsight_sales_order_item to
-- sales_transaction. Idempotent — uses source_ref for dedup.
-- Returns: rows inserted, rows skipped (already exist or no match)
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
    -- Price from canonical_sku
    COALESCE(
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
    vc.quantity * vc.unit_price,  -- gross_revenue (Direct = no discount)
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
'RECON-FIX-17: Syncs Direct channel sales from Vinsight dispatch items to sales_transaction. Uses canonical_sku.base_wholesale as price. Idempotent via source_ref dedup. Auto-assigns COGS after insert.';

COMMIT;
