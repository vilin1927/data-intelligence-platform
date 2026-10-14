-- ════════════════════════════════════════════════════════════════════════════
-- schema/072_bug118_stock_unit_backfill_and_not_null.sql
-- BUG-118 AC2 follow-up — backfill 1,184 NULL stock_unit rows + ALTER NOT NULL
-- ════════════════════════════════════════════════════════════════════════════
-- Date:     2026-04-24
--
-- WHY: BUG-105 BUG fix re-ran etl/recon_etl_access_to_sales.py on 2026-04-24
-- and inserted 1,184 access_db rows. The recon_etl _INSERT_SQL column list
-- did NOT include stock_unit (BUG-118 AC2 patch only covered the 4 main
-- importers — recon_etl was overlooked). Result: 1,184 rows landed with
-- stock_unit=NULL, violating BUG-118 AC2 spec ("DWS importer sets bottle,
-- Vinsight sets case, importers set on ingest").
--
-- WHAT THIS MIGRATION DOES:
--   1. Backfill: UPDATE the 1,184 NULL access_db rows to stock_unit='case'.
--      Source justification: access_combined_data CARTONS column is
--      case-quantity by definition; ALL 119,124 access_db rows that landed
--      via the ORIGINAL recon_etl run (pre-BUG-105) carry stock_unit='case'
--      (set by schema/063 backfill). The 1,184 BUG-105 rerun rows came
--      through the SAME recon_etl path reading the SAME CARTONS column;
--      they are case-quantity by construction.
--   2. ALTER COLUMN ... SET NOT NULL — make future "forgot to set
--      stock_unit" loud at insert time. Prevents silent regression of the
--      kind we just discovered.
--
-- ORDER OF OPERATIONS (CRITICAL):
--   etl/recon_etl_access_to_sales.py was patched in same session to add
--   stock_unit='case' to the _INSERT_SQL column list + _INSERT_TEMPLATE +
--   batch tuple. That patch was deployed to VPS (md5 verified) BEFORE this
--   schema migration runs. Otherwise the next recon_etl run would crash on
--   the new NOT NULL constraint.
--
-- FORWARD-ONLY: UPDATE of NULL → 'case' (reversible by re-NULLing if
-- needed, but 'case' is the truth). SET NOT NULL is an ALTER constraint;
-- can be reversed via ALTER COLUMN ... DROP NOT NULL.
--
-- BLAST RADIUS:
--   - UPDATE 1,184 rows in sales_transaction (access_db source only).
--   - ALTER constraint adds NOT NULL to existing column.
--   - Existing CHECK constraint stock_unit IN ('bottle','case') stays.
--   - No FK rewrites, no row deletes, no other column touched.
--   - Re-running is no-op (UPDATE WHERE IS NULL filters to 0 after first run;
--     ALTER NOT NULL is idempotent on already-NOT-NULL column).
--
-- EXPECTED POST-STATE:
--   sales_transaction.stock_unit IS NULL count = 0 (was 1,184)
--   sales_transaction column constraint: stock_unit NOT NULL
--   sales_transaction[access_db,'case'] = 120,308 (was 119,124 + 1,184 NULL)
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ────────────────────────────────────────────────────────────────────────────
-- 1. Pre-apply assertions
-- ────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
  null_count INT;
  total_access INT;
BEGIN
  SELECT count(*) INTO null_count
    FROM sales_transaction WHERE stock_unit IS NULL;
  SELECT count(*) INTO total_access
    FROM sales_transaction WHERE source_system='access_db';

  RAISE NOTICE 'schema/072 PRE: NULL stock_unit=%, total access_db=%',
    null_count, total_access;

  -- Defensive: if NULL count is unexpectedly huge, abort. The 1,184 number
  -- is from the BUG-105 rerun delta. If we see 100k NULLs, something else
  -- went wrong and we should investigate before backfilling blind.
  IF null_count > 5000 THEN
    RAISE EXCEPTION 'schema/072 PRE-FAIL: % NULL stock_unit rows is way more than expected (~1,184). Investigate before backfilling.',
      null_count;
  END IF;
END $$;

-- ────────────────────────────────────────────────────────────────────────────
-- 2. Backfill
-- ────────────────────────────────────────────────────────────────────────────
UPDATE sales_transaction
SET stock_unit = 'case'
WHERE source_system = 'access_db'
  AND stock_unit IS NULL;

-- ────────────────────────────────────────────────────────────────────────────
-- 3. Post-backfill assertion (before SET NOT NULL — order matters)
-- ────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
  null_count INT;
BEGIN
  SELECT count(*) INTO null_count
    FROM sales_transaction WHERE stock_unit IS NULL;

  IF null_count > 0 THEN
    RAISE EXCEPTION 'schema/072 POST-BACKFILL FAIL: still % NULL stock_unit rows. SET NOT NULL would crash. Investigate.',
      null_count;
  END IF;

  RAISE NOTICE 'schema/072 BACKFILL OK: 0 NULL stock_unit rows';
END $$;

-- ────────────────────────────────────────────────────────────────────────────
-- 4. ALTER COLUMN SET NOT NULL
-- ────────────────────────────────────────────────────────────────────────────
ALTER TABLE sales_transaction
  ALTER COLUMN stock_unit SET NOT NULL;

-- ────────────────────────────────────────────────────────────────────────────
-- 5. Self-record in schema_migrations
-- ────────────────────────────────────────────────────────────────────────────
INSERT INTO schema_migrations (version, source)
VALUES ('072_bug118_stock_unit_backfill_and_not_null', 'live-apply')
ON CONFLICT (version) DO NOTHING;

-- ────────────────────────────────────────────────────────────────────────────
-- 6. Final assertion
-- ────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
  not_null_set BOOLEAN;
  case_count INT;
BEGIN
  SELECT (is_nullable = 'NO') INTO not_null_set
    FROM information_schema.columns
    WHERE table_name='sales_transaction' AND column_name='stock_unit';

  IF NOT not_null_set THEN
    RAISE EXCEPTION 'schema/072 FINAL FAIL: stock_unit is_nullable did not flip to NO';
  END IF;

  SELECT count(*) INTO case_count
    FROM sales_transaction
    WHERE source_system='access_db' AND stock_unit='case';

  RAISE NOTICE 'schema/072 OK: stock_unit NOT NULL set; access_db,case = % rows',
    case_count;
END $$;

COMMIT;

-- ════════════════════════════════════════════════════════════════════════════
-- ROLLBACK RECIPE:
--   BEGIN;
--   ALTER TABLE sales_transaction ALTER COLUMN stock_unit DROP NOT NULL;
--   UPDATE sales_transaction SET stock_unit=NULL
--     WHERE source_system='access_db' AND created_at::date='2026-04-24'
--       AND stock_unit='case';  -- only the 1,184 rerun rows
--   DELETE FROM schema_migrations WHERE version='072_bug118_stock_unit_backfill_and_not_null';
--   COMMIT;
-- ════════════════════════════════════════════════════════════════════════════
