-- ════════════════════════════════════════════════════════════════════════════
-- schema/073_bug118_sales_transaction_normalized_view.sql
-- BUG-118 AC3 — sales_transaction_normalized VIEW with quantity_cases column
-- ════════════════════════════════════════════════════════════════════════════
-- Date:     2026-04-24
--
-- WHY: BUG-118 AC1+AC2 added stock_unit column + patched importers.
-- AC3 closes the loop on the read side: dashboard API routes that
-- aggregate sales_transaction.quantity must compare in a single unit
-- before summing across source_systems. Today 100% of stock_unit='case'
-- so 0 runtime numerical drift; this is forward-safety for the day a DWS
-- bottle-source row lands.
--
-- DESIGN CHOICE: Postgres VIEW vs per-route inline normalization.
-- VIEW chosen because:
--   1. One source of truth — formula lives in one place; can't drift across
--      9 routes.
--   2. Routes can swap `FROM sales_transaction st` → `FROM
--      sales_transaction_normalized st` and `SUM(st.quantity)` →
--      `SUM(st.quantity_cases)` with no other change.
--   3. Prior art: schema/027 + schema/068's combined_data_enriched VIEW
--      uses the same pattern at moppity.
--   4. No materialization → no maintenance burden + always-fresh.
--
-- COLUMNS:
--   * st.* — every column from sales_transaction (29 columns including
--     stock_unit). Routes that don't care about quantity_cases keep working.
--   * quantity_cases — case-normalized quantity. CASE stock_unit:
--       WHEN 'bottle' THEN qty / units_per_case  (with COALESCE-1 safety)
--       ELSE qty                                  (already in cases)
--   * sku_units_per_case — exposed for debugging/audit. Aliased so it
--     doesn't shadow any future sku.units_per_case column on st.* should
--     someone add one.
--
-- LEFT JOIN sku ON sk.sku_id = st.sku_id:
--   - Some sales_transaction rows have sku_id NULL (orphan/unmatched).
--     LEFT JOIN preserves them; COALESCE on units_per_case handles NULL.
--   - sku.units_per_case is NOT NULL on prod (probed: min=1, max=24,
--     0 nulls, 0 zeros).
--
-- FORWARD-ONLY: CREATE OR REPLACE VIEW. No tables touched. Re-runnable.
-- ROLLBACK: DROP VIEW IF EXISTS sales_transaction_normalized;
--
-- BLAST RADIUS:
--   - 0 row writes. 0 column adds.
--   - Adds 1 view + 0 indexes. View is a query rewrite — no storage.
--   - Existing routes that read sales_transaction directly continue to work
--     unchanged. The dashboard route patches that swap to the view land
--     separately (in this same session, post-VIEW-create).
--
-- EXPECTED POST-STATE:
--   - VIEW sales_transaction_normalized exists.
--   - SELECT count(*) FROM sales_transaction_normalized = SELECT count(*)
--     FROM sales_transaction (no row drift via the LEFT JOIN; sku is
--     reference, not filter).
--   - SELECT sum(quantity_cases) FROM sales_transaction_normalized =
--     SELECT sum(quantity) FROM sales_transaction (today, since all rows
--     are 'case'; in future, bottle rows will divide).
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ────────────────────────────────────────────────────────────────────────────
-- 1. Pre-apply assertions
-- ────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
  stock_unit_not_null BOOLEAN;
  null_upc INT;
BEGIN
  -- Hard dep: schema/072 must have run first (SET NOT NULL on stock_unit).
  -- The VIEW's CASE expression assumes stock_unit is one of {'bottle','case'}.
  SELECT (is_nullable = 'NO') INTO stock_unit_not_null
    FROM information_schema.columns
    WHERE table_name='sales_transaction' AND column_name='stock_unit';

  IF NOT stock_unit_not_null THEN
    RAISE EXCEPTION 'schema/073 PRE-FAIL: sales_transaction.stock_unit is nullable. Apply schema/072 first.';
  END IF;

  -- Defensive: COALESCE(units_per_case, 1) handles NULLs safely, but if
  -- many sku rows had NULL upc, the safety would mask a real problem.
  SELECT count(*) INTO null_upc FROM sku WHERE units_per_case IS NULL;
  IF null_upc > 0 THEN
    RAISE NOTICE 'schema/073 PRE-WARN: % sku rows have NULL units_per_case; COALESCE(.,1) will treat as 1 case. Review post-apply.',
      null_upc;
  END IF;

  RAISE NOTICE 'schema/073 PRE: stock_unit NOT NULL ✓, sku NULL upc count = %', null_upc;
END $$;

-- ────────────────────────────────────────────────────────────────────────────
-- 2. Create the VIEW
-- ────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW sales_transaction_normalized AS
SELECT
  st.*,
  -- BUG-118 AC3: case-normalized quantity. NUMERIC division to avoid
  -- integer-truncation surprises (qty 6, upc 12 → 0.5 case, not 0).
  CASE st.stock_unit
    WHEN 'bottle' THEN
      st.quantity::numeric / COALESCE(sk.units_per_case, 1)::numeric
    ELSE  -- 'case' (CHECK constraint guarantees only these two values)
      st.quantity::numeric
  END AS quantity_cases,
  -- Exposed for audit / debugging. Aliased to avoid future column-name
  -- collision if sku itself ever gets put on a JOIN that adds this column.
  sk.units_per_case AS sku_units_per_case
FROM sales_transaction st
LEFT JOIN sku sk ON sk.sku_id = st.sku_id;

COMMENT ON VIEW sales_transaction_normalized IS
  'BUG-118 AC3 — sales_transaction with quantity_cases (case-normalized). '
  'Routes that aggregate quantity across source_systems should SELECT from '
  'this view instead of sales_transaction directly. quantity stays raw; '
  'quantity_cases is the unit-normalized version. See schema/073 + ADR-014.';

COMMENT ON COLUMN sales_transaction_normalized.quantity_cases IS
  'Case-normalized quantity. CASE stock_unit WHEN ''bottle'' THEN qty/upc '
  'ELSE qty END. NUMERIC to avoid integer truncation. Use this for any '
  'cross-source SUM/aggregate.';

-- ────────────────────────────────────────────────────────────────────────────
-- 3. Self-record in schema_migrations
-- ────────────────────────────────────────────────────────────────────────────
INSERT INTO schema_migrations (version, source)
VALUES ('073_bug118_sales_transaction_normalized_view', 'live-apply')
ON CONFLICT (version) DO NOTHING;

-- ────────────────────────────────────────────────────────────────────────────
-- 4. Post-apply assertion: row-count parity + sum parity (today)
-- ────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
  st_rows INT;
  view_rows INT;
  st_qty_sum NUMERIC;
  view_qty_cases_sum NUMERIC;
BEGIN
  SELECT count(*) INTO st_rows FROM sales_transaction;
  SELECT count(*) INTO view_rows FROM sales_transaction_normalized;

  IF st_rows <> view_rows THEN
    RAISE EXCEPTION 'schema/073 POST FAIL: row count drift. sales_transaction=%, view=%',
      st_rows, view_rows;
  END IF;

  -- Today every row is stock_unit='case' so quantity_cases = quantity.
  -- This invariant breaks the day a 'bottle' row lands — that's the
  -- whole point. The check below will then sum DIFFERENT numbers, which
  -- is correct.
  SELECT sum(quantity::numeric), sum(quantity_cases)
    INTO st_qty_sum, view_qty_cases_sum
    FROM sales_transaction_normalized;  -- can compute both from the view

  RAISE NOTICE 'schema/073 OK: VIEW exists; row count = % (matches base table); sum(quantity)=%, sum(quantity_cases)=% (will diverge once bottle rows land)',
    view_rows, st_qty_sum, view_qty_cases_sum;
END $$;

COMMIT;

-- ════════════════════════════════════════════════════════════════════════════
-- ROLLBACK: BEGIN; DROP VIEW IF EXISTS sales_transaction_normalized;
--           DELETE FROM schema_migrations WHERE version='073_bug118_sales_transaction_normalized_view';
--           COMMIT;
-- ════════════════════════════════════════════════════════════════════════════
