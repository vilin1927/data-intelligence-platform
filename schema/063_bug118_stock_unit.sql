-- ════════════════════════════════════════════════════════════════════════════
-- schema/063_bug118_stock_unit.sql
-- BUG-118 — sales_transaction.stock_unit column + source_system backfill
-- ════════════════════════════════════════════════════════════════════════════
-- Date:     2026-04-23
--
-- FORWARD-ONLY & ADDITIVE: ALTER TABLE ADD COLUMN + UPDATE. No existing
-- column altered, dropped, or widened. Rollback recipe at bottom.
--
-- BLAST RADIUS:
--   - ADD COLUMN `stock_unit TEXT` — O(1) metadata-only (no DEFAULT, no rewrite)
--   - ADD CHECK constraint `stock_unit IN ('bottle','case')` — scan + lock,
--     but column is fresh NULL so scan is trivial
--   - UPDATE 4 source-system buckets to backfill `stock_unit='case'`:
--       access_db: 119,124 rows
--       DWS:          271 rows
--       ALM:          293 rows
--       vinsight:     105 rows
--     All get `'case'` per ADR-014 rationale (per-source rule).
--
-- Content hash is NOT touched. `stock_unit` is a derived attribute of the row,
-- not an identity component (BUG-113 Option D rule). Re-ingest under ON
-- CONFLICT (content_hash) stays byte-idempotent.
--
-- WHY: the owner 2026-04-22 09:30 Q2: "DWS reports are in bottles not cases.
-- Vinsight is in Cases not bottles." Codifies channel-level unit rule that
-- was ambient behaviour. Without an explicit unit, cross-source margin +
-- reconciliation reads silently mix bottles and cases. See ADR-014 for the
-- full design + ingest-path mapping.
--
-- EXPECTED POST-STATE:
--   sales_transaction row count = 119,793 (unchanged)
--   sales_transaction column count = current + 1 (stock_unit added)
--   stock_unit IS NOT NULL count = 119,793 (backfill)
--   stock_unit DISTINCT values = {'case'} (all four sources)
--   Future bottle-source DWS rows (re-ingest from legacy Y&R reports without
--   CARTONS column) would flip individual rows to 'bottle' via the
--   importer-patched ingest path; schema is ready for that.
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ────────────────────────────────────────────────────────────────────────────
-- 1. Pre-apply assertions
-- ────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    row_count INTEGER;
    expected_sources TEXT[] := ARRAY['access_db','DWS','ALM','vinsight'];
BEGIN
    IF to_regclass('public.sales_transaction') IS NULL THEN
        RAISE EXCEPTION 'sales_transaction table missing; abort';
    END IF;

    SELECT count(*) INTO row_count FROM sales_transaction;
    IF row_count NOT BETWEEN 119700 AND 120000 THEN
        RAISE EXCEPTION
          'sales_transaction row count % outside expected band [119700, 120000]; '
          'state drift — verify before migrating', row_count;
    END IF;

    -- Idempotency guard: column must not already exist
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='public'
          AND table_name='sales_transaction'
          AND column_name='stock_unit'
    ) THEN
        RAISE EXCEPTION
          'sales_transaction.stock_unit already exists; aborting to surface re-run state';
    END IF;

    -- Sanity: every current source_system is in the ADR-014 mapping
    IF EXISTS (
        SELECT 1 FROM sales_transaction
        WHERE source_system <> ALL(expected_sources)
    ) THEN
        RAISE EXCEPTION
          'sales_transaction has source_system values outside ADR-014 mapping %; '
          'audit before backfill', expected_sources;
    END IF;
END $$;

-- ────────────────────────────────────────────────────────────────────────────
-- 2. ALTER TABLE ADD COLUMN (nullable, no DEFAULT → O(1) metadata-only)
-- ────────────────────────────────────────────────────────────────────────────
ALTER TABLE sales_transaction
  ADD COLUMN stock_unit TEXT;

COMMENT ON COLUMN sales_transaction.stock_unit IS
  'BUG-118 / ADR-014 (2026-04-23): unit of measure for the quantity column. '
  'One of {''bottle'',''case''}. Set at ingest per source_system: access_db, '
  'ALM, vinsight always ''case''; DWS is ''case'' when the source report used '
  'CARTONS column, ''bottle'' when it fell back to QUANTITY (bottles) column. '
  'NOT part of content_hash (derived attribute, not identity). Readers MUST '
  'normalise via etl/unit_normalize.py before cross-source comparison. '
  'Nullable for migration-then-backfill; a future migration may SET NOT NULL '
  'once all ingest paths are confirmed to populate it.';

-- ────────────────────────────────────────────────────────────────────────────
-- 3. CHECK constraint
-- ────────────────────────────────────────────────────────────────────────────
ALTER TABLE sales_transaction
  ADD CONSTRAINT sales_transaction_stock_unit_check
  CHECK (stock_unit IS NULL OR stock_unit IN ('bottle','case'));

-- ────────────────────────────────────────────────────────────────────────────
-- 4. Backfill per source_system (ADR-014 mapping)
-- ────────────────────────────────────────────────────────────────────────────
-- access_db: field name QuantitySupplied(Dozens) confirms cases
UPDATE sales_transaction SET stock_unit = 'case' WHERE source_system = 'access_db';

-- DWS: all 271 rows stored under CARTONS-column default. If any were bottle-
-- sourced, a targeted UPDATE against specific source_refs can flip them
-- post-apply (no current audit evidence of bottle-source rows).
UPDATE sales_transaction SET stock_unit = 'case' WHERE source_system = 'DWS';

-- ALM: importer divides bottles by pack_size at ingest → cases
UPDATE sales_transaction SET stock_unit = 'case' WHERE source_system = 'ALM';

-- vinsight: the owner authoritative
UPDATE sales_transaction SET stock_unit = 'case' WHERE source_system = 'vinsight';

-- ────────────────────────────────────────────────────────────────────────────
-- 5. Post-apply assertions
-- ────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    col_type TEXT;
    col_nullable TEXT;
    total_rows INTEGER;
    null_rows INTEGER;
    distinct_values INTEGER;
BEGIN
    SELECT data_type, is_nullable INTO col_type, col_nullable
    FROM information_schema.columns
    WHERE table_schema='public'
      AND table_name='sales_transaction'
      AND column_name='stock_unit';

    IF col_type IS NULL THEN
        RAISE EXCEPTION 'sales_transaction.stock_unit column was not created';
    END IF;
    IF col_type <> 'text' THEN
        RAISE EXCEPTION 'sales_transaction.stock_unit wrong type: %', col_type;
    END IF;
    IF col_nullable <> 'YES' THEN
        RAISE EXCEPTION
          'sales_transaction.stock_unit nullability: expected YES (migration-then-backfill), got %',
          col_nullable;
    END IF;

    SELECT count(*) INTO total_rows FROM sales_transaction;
    SELECT count(*) INTO null_rows FROM sales_transaction WHERE stock_unit IS NULL;
    SELECT count(DISTINCT stock_unit) INTO distinct_values FROM sales_transaction;

    IF null_rows <> 0 THEN
        RAISE EXCEPTION
          'stock_unit backfill incomplete: % NULL rows remain (expected 0)',
          null_rows;
    END IF;

    IF distinct_values <> 1 THEN
        RAISE EXCEPTION
          'stock_unit has % distinct values post-backfill (expected 1: case)',
          distinct_values;
    END IF;

    -- Confirm the CHECK constraint is present + valid
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'public.sales_transaction'::regclass
          AND conname = 'sales_transaction_stock_unit_check'
    ) THEN
        RAISE EXCEPTION 'sales_transaction_stock_unit_check constraint missing';
    END IF;

    RAISE NOTICE
      'schema/063 OK: sales_transaction.stock_unit added + backfilled. '
      'total=%, NULL=0, distinct=1 (case). Ready for ingest-path patches.',
      total_rows;
END $$;

COMMIT;

-- ════════════════════════════════════════════════════════════════════════════
-- Rollback recipe:
--   BEGIN;
--     ALTER TABLE sales_transaction DROP CONSTRAINT IF EXISTS sales_transaction_stock_unit_check;
--     ALTER TABLE sales_transaction DROP COLUMN IF EXISTS stock_unit;
--   COMMIT;
-- Safe both pre- and post-backfill (stock_unit has no dependents at schema apply time).
-- ════════════════════════════════════════════════════════════════════════════
