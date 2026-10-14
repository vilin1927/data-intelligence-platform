-- =============================================================================
-- Moppity Vineyards — BUG-114 net_revenue lock-in (077_bug114_net_revenue_lock.sql)
-- =============================================================================
-- Date:      2026-04-25
-- Author:    Vladimir (Autoflux) + Sprint 1 session
-- Ticket:    BUG-114 AC3 + AC4 + AC5
--
-- WHY THIS EXISTS
-- ---------------
-- proved that `access_combined_data.raw_data->>'WholesalerFee'` is a literal
-- constant $N on all 120,343 staging rows — fee is ~130x the sale
-- price at median, exceeds the sale price on 90% of rows, and cannot be a
-- per-row fee. It is garbage (likely a misplaced aggregate during the Access
-- DB export).
--
-- The canonical access_db ingest path `etl/recon_etl_access_to_sales.py:273`
-- already hardcodes `wholesale_fee = 0.0  # NOT the $N monthly bulk
-- total`. Prod state for the 120,308 access_db rows in sales_transaction:
--   - wholesale_fee = 0 (every row)
--   - discount_amount = 0 (every row; raw discount was empty/0)
--   - rebate_amount = 0 (every row; raw rebate was empty/0)
--   - net_revenue = gross_revenue (consistent with `gross - 0 - 0 - 0`)
--   - sum(net_revenue) = sum(gross_revenue) = $17,186,018.16
--
-- This migration LOCKS THAT STATE IN with assertion-only DO blocks (pre + post)
-- and updates the column comment to document BUG-114's resolution. It does
-- NOT touch any row data — prod is already correct. Forward-only (BUG-114
-- AC4 code-side fix in etl/transform_to_core.py is shipped in the same commit
-- to prevent future re-introduction of the bug if that legacy ingest path is
-- ever re-run).
--
-- FORMULA (per Phase E Decision Log default for BUG-114):
--   For source_system='access_db':  net_revenue = gross_revenue - discount - rebate
--   wholesale_fee is locked to 0; the column stays in the schema for
--   DWS / ALM / Direct rows where fees are real (DWS=0 today, ALM=0 today,
--   but the column may carry future values from those channels).
--
-- TRANSACTION + PRE/POST ASSERTIONS
-- ---------------------------------
-- BEGIN; DO $$ pre-asserts current state matches expected; UPDATE
-- pg_description (COMMENT ON); DO $$ post-asserts identical to pre; INSERT
-- schema_migrations row; COMMIT. ROLLBACK if any assertion fails.
--
-- IDEMPOTENT
-- ----------
-- Re-running this migration is a no-op: COMMENT ON is overwrite-safe; the
-- DO blocks raise NOTICE but do not modify state; schema_migrations INSERT
-- uses ON CONFLICT (version) DO NOTHING.
-- =============================================================================

BEGIN;

-- =============================================================================
-- 1. PRE-state assertion: confirm prod matches BUG-114 expected state.
--    If any of these RAISE, ROLLBACK and abort.
-- =============================================================================

DO $$
DECLARE
  v_access_rows           INT;
  v_access_fee_nonzero    INT;
  v_access_net_neq_gross  INT;
  v_access_formula_drift  INT;
  v_sum_net               NUMERIC;
  v_sum_gross             NUMERIC;
BEGIN
  -- Total access_db rows
  SELECT COUNT(*) INTO v_access_rows
    FROM sales_transaction
   WHERE source_system = 'access_db';

  -- Rows with wholesale_fee != 0 (must be 0 per BUG-114)
  SELECT COUNT(*) INTO v_access_fee_nonzero
    FROM sales_transaction
   WHERE source_system = 'access_db'
     AND wholesale_fee IS DISTINCT FROM 0;

  -- Rows where net_revenue != gross_revenue - discount - rebate
  -- (allow 1c rounding tolerance)
  SELECT COUNT(*) INTO v_access_formula_drift
    FROM sales_transaction
   WHERE source_system = 'access_db'
     AND ABS(
           COALESCE(net_revenue, 0)
           - (COALESCE(gross_revenue, 0)
              - COALESCE(discount_amount, 0)
              - COALESCE(rebate_amount, 0))
         ) > 0.01;

  -- Sum totals for the migration log
  SELECT ROUND(SUM(net_revenue)::numeric, 2),
         ROUND(SUM(gross_revenue)::numeric, 2)
    INTO v_sum_net, v_sum_gross
    FROM sales_transaction
   WHERE source_system = 'access_db';

  RAISE NOTICE 'BUG-114 PRE: access_db rows=% fee_nonzero=% formula_drift=% sum_net=% sum_gross=%',
    v_access_rows, v_access_fee_nonzero, v_access_formula_drift, v_sum_net, v_sum_gross;

  IF v_access_rows < 119000 OR v_access_rows > 121000 THEN
    RAISE EXCEPTION 'BUG-114 PRE: unexpected access_db row count % (expected ~120,308)', v_access_rows;
  END IF;

  IF v_access_fee_nonzero <> 0 THEN
    RAISE EXCEPTION 'BUG-114 PRE: % access_db rows have wholesale_fee != 0 (expected 0). recon_etl_access_to_sales.py should have hardcoded fee=0.', v_access_fee_nonzero;
  END IF;

  IF v_access_formula_drift <> 0 THEN
    RAISE EXCEPTION 'BUG-114 PRE: % access_db rows have net_revenue != gross-discount-rebate (expected 0). Formula drift detected.', v_access_formula_drift;
  END IF;
END;
$$;

-- =============================================================================
-- 2. Document the BUG-114 resolution in the column comment.
--    No data changes. Forward-only metadata update.
-- =============================================================================

COMMENT ON COLUMN sales_transaction.wholesale_fee IS
  'Wholesale fee charged by DWS/ALM. Deducted from gross to get net revenue. '
  'BUG-114 (2026-04-25): for source_system=''access_db'', this column is locked '
  'to 0. The raw access_combined_data.WholesalerFee field is a literal constant '
  '$N on every row (internal notes) '
  '— garbage from a misplaced aggregate during the Access DB export. The canonical '
  'ingest path etl/recon_etl_access_to_sales.py:273 hardcodes 0; the legacy '
  'etl/transform_to_core.py path was patched in the same commit. For DWS/ALM/Direct '
  'rows the column carries real per-row fee data from those channels.';

COMMENT ON COLUMN sales_transaction.net_revenue IS
  'Net revenue after discounts, rebates, and wholesale fees. '
  'Formula: net_revenue = gross_revenue - discount_amount - rebate_amount - wholesale_fee. '
  'For source_system=''access_db'' wholesale_fee is locked to 0 (see BUG-114), so net = gross - discount - rebate.';

-- =============================================================================
-- 3. POST-state assertion: confirm no row was accidentally touched.
-- =============================================================================

DO $$
DECLARE
  v_access_fee_nonzero    INT;
  v_access_formula_drift  INT;
  v_sum_net               NUMERIC;
  v_sum_gross             NUMERIC;
BEGIN
  SELECT COUNT(*) INTO v_access_fee_nonzero
    FROM sales_transaction
   WHERE source_system = 'access_db'
     AND wholesale_fee IS DISTINCT FROM 0;

  SELECT COUNT(*) INTO v_access_formula_drift
    FROM sales_transaction
   WHERE source_system = 'access_db'
     AND ABS(
           COALESCE(net_revenue, 0)
           - (COALESCE(gross_revenue, 0)
              - COALESCE(discount_amount, 0)
              - COALESCE(rebate_amount, 0))
         ) > 0.01;

  SELECT ROUND(SUM(net_revenue)::numeric, 2),
         ROUND(SUM(gross_revenue)::numeric, 2)
    INTO v_sum_net, v_sum_gross
    FROM sales_transaction
   WHERE source_system = 'access_db';

  RAISE NOTICE 'BUG-114 POST: access_db fee_nonzero=% formula_drift=% sum_net=% sum_gross=%',
    v_access_fee_nonzero, v_access_formula_drift, v_sum_net, v_sum_gross;

  IF v_access_fee_nonzero <> 0 THEN
    RAISE EXCEPTION 'BUG-114 POST: regression — % access_db rows now have wholesale_fee != 0', v_access_fee_nonzero;
  END IF;

  IF v_access_formula_drift <> 0 THEN
    RAISE EXCEPTION 'BUG-114 POST: regression — % access_db rows have formula drift', v_access_formula_drift;
  END IF;
END;
$$;

-- =============================================================================
-- 4. Record migration in schema_migrations (idempotent).
-- =============================================================================

INSERT INTO schema_migrations (version, source)
VALUES ('077_bug114_net_revenue_lock', 'live-apply')
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- =============================================================================
-- ROLLBACK / DOWN-MIGRATION RECIPE (manual; not auto-run)
-- =============================================================================
-- This migration only updates pg_description (column comments) — there is no
-- row data to roll back. To revert the comment text:
--   COMMENT ON COLUMN sales_transaction.wholesale_fee IS 'Wholesale fee charged by DWS/ALM. Deducted from gross to get net revenue.';
--   COMMENT ON COLUMN sales_transaction.net_revenue   IS 'Net revenue after discounts, rebates, and wholesale fees.';
--   DELETE FROM schema_migrations WHERE version = '077_bug114_net_revenue_lock';
