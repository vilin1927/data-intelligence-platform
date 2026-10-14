-- =============================================================================
-- Moppity Vineyards — BUG-63a ALM vintage estimation default (082)
-- =============================================================================
-- Date:      2026-04-26
-- Author:    Vladimir (Autoflux)
-- Branch:    feature/bug-63a-alm
--            schema/009_vintage_attribution.sql (table definition);
--            etl/attribute_vintages.py (existing generic 'last_ordered' rule)
--
-- WHY THIS EXISTS
-- ---------------
-- The owner 2026-04-26 (DOCX line 1196):
--   "SKU-Vintage should be included in every transaction. For Direct, DWS and YR
--   the vintage is in the code. For ALM the vintage will have to be estimated as
--   we previously discussed."
--
-- ALM EDI files do NOT carry vintage in the product code. Vintage must be inferred.
-- The owner's stated method (Mar 19 + Mar 31 + Apr 3 transcripts): use the most recent
-- Vinsight dispatch vintage of the same wine product to ALM, prior to the ALM
-- invoice date.
--
-- The existing etl/attribute_vintages.py method `_attribute_channel_sales('ALM')`
-- already implements the join + ordering, but tags every match as the generic
-- 'last_ordered' (shared with DWS) and falls back through generic methods
-- ('fallback_any_dispatch', 'sale_year_estimate'). BUG-63a needs the explicit
-- ALM-only label + a defined "newest released vintage" fallback so that the
-- attribution method column is honest about what rule was applied.
--
-- WHAT THIS DOES
-- --------------
-- Re-attributes ALL ALM rows in sales_transaction (channel='ALM') in two tiers
-- and overwrites any existing generic-method attribution for those rows:
--
--   Tier 1  attribution_method = 'alm_estimated_by_dispatch_date'  (conf 0.95)
--           Most recent Vinsight dispatch vintage of the same wine_product
--           to any ALM contact ('ALM Fyshwick', 'ALM Charge Thru',
--           'ALM Truganina (Vic)') with date_despatched <= sale_date + 7d.
--
--   Tier 2  attribution_method = 'alm_estimated_newest_released'   (conf 0.70)
--           Fallback for ALM rows tier 1 missed: newest vintage <= sale_year
--           from wine_product.vintages_seen. If no vintages_seen <= sale_year,
--           uses (sale_year - 1) as a final estimate (typical wine release lag).
--
-- IDEMPOTENT
-- ----------
-- INSERT ... ON CONFLICT (sales_transaction_id) DO UPDATE — re-running yields
-- the same attribution. Non-ALM rows are NEVER touched (WHERE channel='ALM' guard).
--
-- SCHEMA CHANGE
-- -------------
-- One additive partial index on sale_vintage_attribution(sales_transaction_id)
-- WHERE attribution_method LIKE 'alm_estimated%' for ALM analytics queries.
-- No column / constraint changes (attribution_method stays VARCHAR(50)).
-- =============================================================================

BEGIN;

-- =============================================================================
-- 1. PRE-state assertions.
-- =============================================================================

DO $$
DECLARE
  v_alm_channel_id INT;
  v_alm_txn_count INT;
  v_alm_contact_count INT;
  v_vsoi_count INT;
BEGIN
  SELECT channel_id INTO v_alm_channel_id
  FROM channel WHERE channel_name = 'ALM';

  IF v_alm_channel_id IS NULL THEN
    RAISE EXCEPTION '082 PRE: channel.channel_name=ALM not found';
  END IF;

  SELECT COUNT(*) INTO v_alm_txn_count
  FROM sales_transaction WHERE channel_id = v_alm_channel_id;

  SELECT COUNT(*) INTO v_alm_contact_count
  FROM vinsight_sales_order_item
  WHERE contact_code IN ('ALM Fyshwick', 'ALM Charge Thru', 'ALM Truganina (Vic)');

  SELECT COUNT(*) INTO v_vsoi_count
  FROM vinsight_sales_order_item WHERE vintage IS NOT NULL;

  RAISE NOTICE '082 PRE: alm_channel=% alm_txns=% alm_dispatch_lines=% vsoi_with_vintage=%',
    v_alm_channel_id, v_alm_txn_count, v_alm_contact_count, v_vsoi_count;

  IF v_alm_txn_count = 0 THEN
    RAISE NOTICE '082 PRE: zero ALM transactions — nothing to attribute (no-op)';
  END IF;

  IF v_vsoi_count = 0 THEN
    RAISE EXCEPTION '082 PRE: vinsight_sales_order_item has no rows with vintage — '
      'cannot run tier 1. Sync Vinsight dispatches before applying.';
  END IF;
END;
$$;

-- =============================================================================
-- 2. Tier 1 — explicit ALM dispatch-date rule.
--    For each ALM sales_transaction, pick the most recent Vinsight dispatch
--    line item where:
--      - same wine_product (via sku_wine_product_map)
--      - dispatched to any ALM contact
--      - date_despatched <= sale_date + 7 days  (matches existing rule's grace)
--    UPSERT with method='alm_estimated_by_dispatch_date'.
-- =============================================================================

INSERT INTO sale_vintage_attribution
    (sales_transaction_id, attributed_vintage, attribution_method,
     confidence, vinsight_order_num, notes)
SELECT DISTINCT ON (st.transaction_id)
    st.transaction_id,
    vsoi.vintage,
    'alm_estimated_by_dispatch_date',
    0.95,
    vsoi.order_num,
    'BUG-63a tier 1: ALM dispatch ' || vsoi.date_despatched::date
        || ' to ' || vsoi.contact_code || ' (sale ' || st.sale_date::date || ')'
FROM sales_transaction st
JOIN channel c ON c.channel_id = st.channel_id
JOIN sku_wine_product_map swpm ON swpm.sku_id = st.sku_id
JOIN vinsight_sales_order_item vsoi
    ON LEFT(REGEXP_REPLACE(vsoi.stock_item_code, '^[A-Z]-', ''),
            LENGTH(REGEXP_REPLACE(vsoi.stock_item_code, '^[A-Z]-', '')) - 2)
       = swpm.wine_product_code
WHERE c.channel_name = 'ALM'
  AND vsoi.vintage IS NOT NULL
  AND vsoi.date_despatched IS NOT NULL
  AND vsoi.date_despatched <= st.sale_date + interval '7 days'
  AND vsoi.contact_code IN ('ALM Fyshwick', 'ALM Charge Thru', 'ALM Truganina (Vic)')
ORDER BY st.transaction_id, vsoi.date_despatched DESC
ON CONFLICT (sales_transaction_id) DO UPDATE
    SET attributed_vintage = EXCLUDED.attributed_vintage,
        attribution_method = EXCLUDED.attribution_method,
        confidence         = EXCLUDED.confidence,
        vinsight_order_num = EXCLUDED.vinsight_order_num,
        notes              = EXCLUDED.notes,
        updated_at         = NOW();

-- =============================================================================
-- 3. Tier 2 — newest released vintage fallback.
--    For ALM rows still without an alm_estimated_* method (tier 1 missed):
--    use newest wine_product.vintages_seen <= EXTRACT(YEAR FROM sale_date),
--    else EXTRACT(YEAR FROM sale_date) - 1.
-- =============================================================================

WITH alm_unmatched AS (
    SELECT
        st.transaction_id,
        EXTRACT(YEAR FROM st.sale_date)::int AS sale_year,
        swpm.wine_product_code,
        wp.vintages_seen
    FROM sales_transaction st
    JOIN channel c ON c.channel_id = st.channel_id
    JOIN sku_wine_product_map swpm ON swpm.sku_id = st.sku_id
    LEFT JOIN wine_product wp ON wp.wine_product_code = swpm.wine_product_code
    LEFT JOIN sale_vintage_attribution sva
        ON sva.sales_transaction_id = st.transaction_id
       AND sva.attribution_method = 'alm_estimated_by_dispatch_date'
    WHERE c.channel_name = 'ALM'
      AND sva.id IS NULL
)
INSERT INTO sale_vintage_attribution
    (sales_transaction_id, attributed_vintage, attribution_method,
     confidence, notes)
SELECT
    transaction_id,
    COALESCE(
        (
            SELECT MAX(v)
            FROM unnest(vintages_seen) AS v
            WHERE v <= sale_year
        ),
        sale_year - 1
    ) AS attributed_vintage,
    'alm_estimated_newest_released',
    0.70,
    'BUG-63a tier 2: newest released <= sale_year=' || sale_year
        || ' from wine_product.vintages_seen='
        || COALESCE(array_to_string(vintages_seen, ','), 'NULL')
FROM alm_unmatched
ON CONFLICT (sales_transaction_id) DO UPDATE
    SET attributed_vintage = EXCLUDED.attributed_vintage,
        attribution_method = EXCLUDED.attribution_method,
        confidence         = EXCLUDED.confidence,
        vinsight_order_num = NULL,
        notes              = EXCLUDED.notes,
        updated_at         = NOW();

-- =============================================================================
-- 4. Partial index for ALM analytics queries.
-- =============================================================================

CREATE INDEX IF NOT EXISTS idx_sva_alm_estimated
    ON sale_vintage_attribution (sales_transaction_id)
    WHERE attribution_method LIKE 'alm_estimated%';

-- =============================================================================
-- 5. POST-state assertions.
-- =============================================================================

DO $$
DECLARE
  v_alm_channel_id INT;
  v_alm_txns INT;
  v_alm_attributed INT;
  v_alm_tier1 INT;
  v_alm_tier2 INT;
  v_alm_other_method INT;
  v_coverage_pct NUMERIC;
BEGIN
  SELECT channel_id INTO v_alm_channel_id FROM channel WHERE channel_name = 'ALM';

  SELECT COUNT(*) INTO v_alm_txns
  FROM sales_transaction WHERE channel_id = v_alm_channel_id;

  IF v_alm_txns = 0 THEN
    RAISE NOTICE '082 POST: zero ALM transactions, skipping coverage check (no-op migration)';
    RETURN;
  END IF;

  SELECT COUNT(*) INTO v_alm_attributed
  FROM sales_transaction st
  JOIN sale_vintage_attribution sva ON sva.sales_transaction_id = st.transaction_id
  WHERE st.channel_id = v_alm_channel_id;

  SELECT COUNT(*) INTO v_alm_tier1
  FROM sales_transaction st
  JOIN sale_vintage_attribution sva ON sva.sales_transaction_id = st.transaction_id
  WHERE st.channel_id = v_alm_channel_id
    AND sva.attribution_method = 'alm_estimated_by_dispatch_date';

  SELECT COUNT(*) INTO v_alm_tier2
  FROM sales_transaction st
  JOIN sale_vintage_attribution sva ON sva.sales_transaction_id = st.transaction_id
  WHERE st.channel_id = v_alm_channel_id
    AND sva.attribution_method = 'alm_estimated_newest_released';

  SELECT COUNT(*) INTO v_alm_other_method
  FROM sales_transaction st
  JOIN sale_vintage_attribution sva ON sva.sales_transaction_id = st.transaction_id
  WHERE st.channel_id = v_alm_channel_id
    AND sva.attribution_method NOT LIKE 'alm_estimated%';

  v_coverage_pct := ROUND((v_alm_attributed::numeric / v_alm_txns::numeric) * 100, 2);

  RAISE NOTICE '082 POST: alm_txns=% attributed=% coverage_pct=% tier1=% tier2=% non_alm_method=%',
    v_alm_txns, v_alm_attributed, v_coverage_pct, v_alm_tier1, v_alm_tier2, v_alm_other_method;

  IF v_alm_other_method > 0 THEN
    RAISE EXCEPTION '082 POST: % ALM rows still have non-ALM attribution_method '
      '(expected all ALM rows to be alm_estimated_*). Check tier 1/2 logic.',
      v_alm_other_method;
  END IF;

  IF v_coverage_pct < 95 THEN
    RAISE EXCEPTION '082 POST: ALM attribution coverage % below 95%% target '
      '(BUG-63a AC). attributed=%/%', v_coverage_pct, v_alm_attributed, v_alm_txns;
  END IF;

  IF v_alm_tier1 + v_alm_tier2 <> v_alm_attributed THEN
    RAISE EXCEPTION '082 POST: tier1+tier2 (%+%=%) does not equal attributed=% — '
      'method labels inconsistent', v_alm_tier1, v_alm_tier2,
      v_alm_tier1 + v_alm_tier2, v_alm_attributed;
  END IF;
END;
$$;

-- =============================================================================
-- 6. Record migration.
-- =============================================================================

INSERT INTO schema_migrations (version, source)
VALUES ('082_bug63a_alm_vintage_attribution', 'live-apply')
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- =============================================================================
-- ROLLBACK (manual; not auto-run)
-- =============================================================================
--   BEGIN;
--   DELETE FROM sale_vintage_attribution
--     WHERE attribution_method IN
--       ('alm_estimated_by_dispatch_date', 'alm_estimated_newest_released');
--   DROP INDEX IF EXISTS idx_sva_alm_estimated;
--   DELETE FROM schema_migrations WHERE version = '082_bug63a_alm_vintage_attribution';
--   COMMIT;
-- =============================================================================
