-- Migration 050: sync_vinsight_direct_sales() — add content_hash to every
-- INSERT so the function is idempotent under the UNIQUE(content_hash) index
-- created in schema/049 part2.
--
-- BUG-113 Option D (2026-04-22 session early-12).
--
-- ============================================================================
-- Why this migration exists
-- ----------------------------------------------------------------------------
-- schema/049 added a NOT NULL UNIQUE content_hash column on sales_transaction
-- and backfilled existing rows. Any INSERT that does not populate content_hash
-- will now fail with NOT NULL violation. sync_vinsight_direct_sales() is
-- called from cron (scripts/sync-all.sh:68) and writes every NEW Vinsight
-- Direct sales_order_item into sales_transaction via a single INSERT ... SELECT.
-- This file CREATE OR REPLACEs the function to:
--   (a) add content_hash to the INSERT column list, computed by the same
--       SHA256 expression used in schema/049 part1 backfill
--       (source_system, source_ref, sku_id, customer_id, sale_date, quantity),
--   (b) add `ON CONFLICT (content_hash) DO NOTHING` as belt-and-braces after
--       the existing `WHERE NOT EXISTS (source_ref)` pre-filter.
--
-- Version lineage:
--   schema/018 — original sync_vinsight_direct_sales (base_wholesale pricing).
--   schema/038 — BUG-33 UoM fix: use actual invoice line net price.
--   schema/041 — JR-089: populate territory_id + rep_id from customer.
--   schema/050 — THIS FILE — Option D content_hash for Phase K idempotency.
-- Applies on top of 041's body with the minimal Option D delta.
--
-- Hash expression byte-equivalence check: see schema/049 part1 +
-- confirmed on transaction_id=603145, hash 8a58b9f5fb45...).
-- ============================================================================

CREATE OR REPLACE FUNCTION sync_vinsight_direct_sales()
RETURNS TABLE (inserted bigint, skipped bigint, no_sku_match bigint) AS $$
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
    'vinsight-' || vi.order_num || '-' || vi.entry_num AS source_ref,
    COALESCE(
      scm.sku_id,
      (SELECT s.sku_id FROM sku s
       JOIN canonical_sku cs ON cs.id = s.canonical_sku_id
       WHERE UPPER(cs.sku_name) = UPPER(REGEXP_REPLACE(vi.description, '\s*\d{4}$', ''))
       LIMIT 1)
    ) AS sku_id,
    ccm.customer_id,
    -- BUG-33: unit_price = actual invoice-line net price (after discount)
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
    AND vi.stock_item_code NOT IN ('Freight', 'Claims NO WET', 'Claims WET', 'Rounding adjustment',
      'Rounding', 'Staff Issue', 'Bulk Wine Sales', 'BAD DEBT WET', 'Sponsorship', 'Tokens',
      'Ice', 'Pallet', 'BAD DEBT')
    AND vi.stock_item_code NOT LIKE 'A-%'
    AND vi.stock_item_code NOT LIKE 'B-%'
    AND vi.stock_item_code NOT LIKE 'L-%'
    AND vi.stock_item_code NOT LIKE 'S-%'
    AND vi.stock_item_code NOT LIKE 'X-%'
    AND COALESCE(vi.invoice_date, vi.date_despatched)::date > v_cutoff_date
    AND COALESCE(vi.invoice_date, vi.date_despatched) IS NOT NULL;

  -- Count items with no SKU match
  SELECT COUNT(*) INTO v_no_match FROM _vinsight_candidates WHERE sku_id IS NULL;

  -- Count items that already exist in sales_transaction
  SELECT COUNT(*) INTO v_skipped
  FROM _vinsight_candidates vc
  WHERE EXISTS (
    SELECT 1 FROM sales_transaction st WHERE st.source_ref = vc.source_ref
  );

  -- BUG-113 Option D: insert with content_hash (computed SQL-side via the
  -- same SHA256 expression as schema/049 part1). ON CONFLICT (content_hash)
  -- DO NOTHING is belt-and-braces after the source_ref NOT EXISTS pre-filter
  -- — catches any case where two source_refs would collapse to the same
  -- content_hash (by design impossible given source_ref uniqueness, but
  -- defensive).
  INSERT INTO sales_transaction (
    sku_id, customer_id, channel_id, sale_date, period,
    quantity, unit_price, net_revenue, gross_revenue,
    warehouse, source_system, source_ref,
    territory_id, rep_id,
    content_hash
  )
  SELECT
    vc.sku_id,
    vc.customer_id,
    v_direct_channel_id,
    vc.sale_date,
    vc.period,
    vc.quantity,
    vc.unit_price,
    vc.quantity * vc.unit_price,
    vc.quantity * vc.unit_price,
    'Direct',
    'vinsight',
    vc.source_ref,
    c.territory_id,
    c.rep_id,
    encode(
      sha256(
        (
          'vinsight'                              || '|' ||
          coalesce(vc.source_ref, '')             || '|' ||
          coalesce(vc.sku_id::text, '')           || '|' ||
          coalesce(vc.customer_id::text, '')      || '|' ||
          vc.sale_date::text                      || '|' ||
          (vc.quantity::decimal(12,2))::text
        )::bytea
      ),
      'hex'
    )
  FROM _vinsight_candidates vc
  LEFT JOIN customer c ON c.customer_id = vc.customer_id
  WHERE vc.sku_id IS NOT NULL
    AND vc.unit_price > 0
    AND NOT EXISTS (
      SELECT 1 FROM sales_transaction st WHERE st.source_ref = vc.source_ref
    )
  ON CONFLICT (content_hash) DO NOTHING;

  GET DIAGNOSTICS v_inserted = ROW_COUNT;

  IF v_inserted > 0 THEN
    PERFORM assign_vintage_cogs();
  END IF;

  RETURN QUERY SELECT v_inserted, v_skipped, v_no_match;

END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION sync_vinsight_direct_sales() IS
'BUG-113 Option D (2026-04-22): INSERT now sets content_hash (SHA256 over '
'source_system|source_ref|sku_id|customer_id|sale_date|quantity) matching '
'schema/049 part1 backfill. ON CONFLICT (content_hash) DO NOTHING makes the '
'function idempotent under the schema/049 UNIQUE(content_hash) constraint. '
'Retains schema/041 (JR-089) territory_id + rep_id from customer, and BUG-33 '
'pricing logic (UnitPrice * (1 - Discount), fallback to base_wholesale).';
