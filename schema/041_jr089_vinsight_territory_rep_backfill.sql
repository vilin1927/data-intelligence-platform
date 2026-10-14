-- =============================================================================
-- Moppity Vineyards — JR-089: Vinsight sales_transaction territory/rep backfill
-- =============================================================================
-- Version:   1.0
-- Created:   2026-04-18
-- Task:      JR-089 (Vinsight sales_transaction rows have NULL territory_id +
--            rep_id on 95/95 rows)
--
-- Problem (verified via VPS read-only probe 2026-04-18):
--   sales_transaction WHERE source_system = 'vinsight' → 95 rows, 0 with
--   territory_id, 0 with rep_id. BUG-34 (2026-04-17, schema/040) already
--   enriched customer.rep_id + customer.territory_id from Vinsight Contacts
--   via etl/backfill_vinsight_contact_enrichment.py. The territory/rep
--   attribution never flowed down into sales_transaction because the
--   INSERT column list in sync_vinsight_direct_sales() (schema/018, then
--   schema/038) omits those two columns.
--
-- Fix (two parts, both idempotent and forward-only):
--   1. Rewrite sync_vinsight_direct_sales() so future INSERTs populate
--      territory_id + rep_id from customer (BUG-34 enrichment). No other
--      behaviour change vs schema/038.
--   2. One-shot UPDATE to backfill the 95 existing Vinsight rows from
--      their linked customer. Upper bound (probed 2026-04-18):
--        - 94 / 95 rows will get territory_id (1 row has NULL customer_id)
--        - 93 / 95 rows will get rep_id (1 customer has territory_id
--          but NULL rep_id — acceptable; it means BUG-34 couldn't resolve
--          a rep for that contact, not a bug in this migration).
--
-- Safety:
--   - Forward-only: no DROP, no CASCADE, no TRUNCATE.
--   - Scoped to source_system = 'vinsight' so Access DB / ALM / DWS rows
--     are not touched.
--   - Only sets columns when they are currently NULL (never overwrites a
--     value that a future channel-specific override might have set).
--   - Idempotent: re-running the UPDATE is a no-op (WHERE NULL filter).
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Rewrite sync_vinsight_direct_sales() to populate territory_id + rep_id
--    on every future INSERT, by joining candidates against customer.
--    Behaviour otherwise identical to schema/038 version.
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

  -- Insert new rows — JR-089: now carries territory_id + rep_id via customer join
  INSERT INTO sales_transaction (
    sku_id, customer_id, channel_id, sale_date, period,
    quantity, unit_price, net_revenue, gross_revenue,
    warehouse, source_system, source_ref,
    territory_id, rep_id
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
    c.territory_id,   -- JR-089: inherit from customer (BUG-34 enrichment)
    c.rep_id          -- JR-089: inherit from customer (BUG-34 enrichment)
  FROM _vinsight_candidates vc
  LEFT JOIN customer c ON c.customer_id = vc.customer_id
  WHERE vc.sku_id IS NOT NULL
    AND vc.unit_price > 0
    AND NOT EXISTS (
      SELECT 1 FROM sales_transaction st WHERE st.source_ref = vc.source_ref
    );

  GET DIAGNOSTICS v_inserted = ROW_COUNT;

  IF v_inserted > 0 THEN
    PERFORM assign_vintage_cogs();
  END IF;

  RETURN QUERY SELECT v_inserted, v_skipped, v_no_match;

END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION sync_vinsight_direct_sales() IS
'JR-089 (2026-04-18): Now populates territory_id + rep_id from customer on every INSERT so Vinsight Direct rows carry full attribution. Retains BUG-33 pricing logic (UnitPrice * (1 - Discount), fallback to base_wholesale).';


-- ---------------------------------------------------------------------------
-- 2. One-shot backfill of existing Vinsight sales_transaction rows.
--    Safe: only touches rows where the column is currently NULL.
--    Idempotent: re-running is a no-op.
-- ---------------------------------------------------------------------------

UPDATE sales_transaction st
   SET territory_id = c.territory_id
  FROM customer c
 WHERE st.customer_id   = c.customer_id
   AND st.source_system = 'vinsight'
   AND st.territory_id  IS NULL
   AND c.territory_id   IS NOT NULL;

UPDATE sales_transaction st
   SET rep_id = c.rep_id
  FROM customer c
 WHERE st.customer_id   = c.customer_id
   AND st.source_system = 'vinsight'
   AND st.rep_id        IS NULL
   AND c.rep_id         IS NOT NULL;


-- ---------------------------------------------------------------------------
-- 3. Post-apply assertion — logged via RAISE NOTICE; does NOT fail the
--    migration if counts are slightly off (one row has NULL customer_id
--    and some customers legitimately lack a rep). The operator should
--    verify the NOTICE output matches expected (>=93 populated).
-- ---------------------------------------------------------------------------

DO $$
DECLARE
  v_total    bigint;
  v_terr     bigint;
  v_rep      bigint;
BEGIN
  SELECT COUNT(*),
         COUNT(territory_id),
         COUNT(rep_id)
    INTO v_total, v_terr, v_rep
    FROM sales_transaction
   WHERE source_system = 'vinsight';

  RAISE NOTICE 'JR-089 post-backfill: % Vinsight rows total, % with territory_id, % with rep_id',
    v_total, v_terr, v_rep;

  IF v_terr < 90 THEN
    RAISE WARNING 'JR-089 fewer than 90 rows carry territory_id — verify BUG-34 customer enrichment ran.';
  END IF;
END $$;

COMMIT;
