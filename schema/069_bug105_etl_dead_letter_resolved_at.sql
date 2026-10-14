-- ════════════════════════════════════════════════════════════════════════════
-- schema/069_bug105_etl_dead_letter_resolved_at.sql
-- BUG-105 — add resolution markers to etl_dead_letter
-- ════════════════════════════════════════════════════════════════════════════
-- Date: 2026-04-24
-- Depends on: nothing (additive ALTER only; columns are IF NOT EXISTS)
-- Blocks: UPDATE resolved_at for the 1,219 stale sku_not_found entries runs
--
--   etl_dead_letter already has 1,254 rows for source='access_db', all with
--   error_message starting "sku_not_found:" and created_at = 2026-03-29 (two
--   recon_etl runs that day). Of those 1,254:
--     • 1,219 access_ids are STILL missing from sales_transaction (the D7 gap)
--     • 35 access_ids are NOW in sales_transaction (resolved by some independent
--       path between Mar 29 and today, likely a manual patch or an earlier
--       targeted rerun)
--   Re-running recon_etl_access_to_sales.py today (after the content_hash +
--   ON CONFLICT patch in the same BUG-105 session) is expected to recover 100%
--   of the 1,219 because all 35 distinct dead-letter SKU names now have a
--   canonical_sku match (verified: LEFT JOIN canonical_sku ON UPPER(sku_name)
--   returned 1,219/1,219). Phases B1/C1/F/R added those canonical_sku rows
--   between Apr 21 and Apr 24.
--
--   Vladimir decision 2026-04-24: preserve the stale rows (audit trail) rather
--   than DELETE; mark resolved_at + resolution_note post-rerun so future queries
--   like "show me rows still dead-lettered" filter them out, and historical
--   "was this row dead-lettered on 2026-03-29?" queries still work.
--
-- IDEMPOTENT & ADDITIVE: ADD COLUMN IF NOT EXISTS on both columns. No defaults
-- means existing rows read NULL for both, which is the exact semantics we want
-- — unresolved until explicitly marked.
--
-- BLAST RADIUS: etl_dead_letter only. No FK, no read semantics change, no
-- default backfill. Downstream readers that do SELECT * from etl_dead_letter
-- will see two new columns; the ETL producers (recon_etl_access_to_sales.py,
-- others) do not set these columns at insert time and will continue to work.
--
-- EXPECTED POST-STATE (after this migration, BEFORE the recon_etl rerun):
--   etl_dead_letter total                   = unchanged (~1,254 access_db + other sources)
--   etl_dead_letter resolved_at NOT NULL    = 0
--   columns present: resolved_at, resolution_note
--
-- EXPECTED POST-STATE (after the rerun + post-rerun UPDATE in audit evidence):
--   etl_dead_letter[access_db, created_at::date='2026-03-29'] resolved_at      = 1,254 (all stale)
--   etl_dead_letter[access_db] created_at > '2026-04-24', resolved_at IS NULL  = 0 (if zero residual; any new entries here would be a surprise)
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ────────────────────────────────────────────────────────────────────────────
-- 1. Pre-state assertion — do NOT apply if the table doesn't exist or the
--    sku_not_found stale cohort is different from what we scouted.
-- ────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    v_stale_count bigint;
    v_total_count bigint;
BEGIN
    -- Gate 1: etl_dead_letter table must exist.
    IF NOT EXISTS (SELECT 1 FROM information_schema.tables
                   WHERE table_schema='public' AND table_name='etl_dead_letter') THEN
        RAISE EXCEPTION 'etl_dead_letter table not found — migration aborted';
    END IF;

    -- Gate 2: confirm the stale cohort is ~1,254 sku_not_found rows for access_db
    -- from 2026-03-29. Allow a ±5 drift window for robustness.
    SELECT count(*) INTO v_stale_count
    FROM etl_dead_letter
    WHERE source='access_db'
      AND error_message LIKE 'sku_not_found:%'
      AND created_at::date = '2026-03-29';

    SELECT count(*) INTO v_total_count
    FROM etl_dead_letter WHERE source='access_db';

    RAISE NOTICE 'BUG-105 schema/069 pre-state: stale sku_not_found rows (access_db, 2026-03-29) = %, total access_db dead-letters = %', v_stale_count, v_total_count;

    IF v_stale_count < 1249 OR v_stale_count > 1259 THEN
        RAISE EXCEPTION 'stale sku_not_found count % out of expected band [1249..1259] — scout baseline drifted, abort and re-scout', v_stale_count;
    END IF;
END $$;

-- ────────────────────────────────────────────────────────────────────────────
-- 2. Schema additions (forward-only, reversible via DROP COLUMN)
-- ────────────────────────────────────────────────────────────────────────────
ALTER TABLE etl_dead_letter
    ADD COLUMN IF NOT EXISTS resolved_at      TIMESTAMP,
    ADD COLUMN IF NOT EXISTS resolution_note  TEXT;

COMMENT ON COLUMN etl_dead_letter.resolved_at IS
  'BUG-105 (2026-04-24): NOT NULL means the row''s underlying failure has been remediated (e.g., via ETL rerun after canonical-reference backfill). Set post-rerun. NULL = unresolved/live dead-letter.';

COMMENT ON COLUMN etl_dead_letter.resolution_note IS
  'BUG-105 (2026-04-24): free-text pointer to the BUG / commit / audit evidence that explains HOW the row was resolved. Empty for live unresolved dead-letters.';

-- Partial index: unresolved dead-letters only (expected to stay small).
CREATE INDEX IF NOT EXISTS idx_etl_dead_letter_unresolved
    ON etl_dead_letter (source, created_at)
    WHERE resolved_at IS NULL;

-- ────────────────────────────────────────────────────────────────────────────
-- 3. Post-state assertion — confirm ALTER landed idempotently.
-- ────────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='public' AND table_name='etl_dead_letter'
          AND column_name='resolved_at'
    ) THEN
        RAISE EXCEPTION 'resolved_at column failed to land';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='public' AND table_name='etl_dead_letter'
          AND column_name='resolution_note'
    ) THEN
        RAISE EXCEPTION 'resolution_note column failed to land';
    END IF;

    RAISE NOTICE 'BUG-105 schema/069 OK: resolved_at + resolution_note + idx_etl_dead_letter_unresolved in place.';
END $$;

COMMIT;

-- ════════════════════════════════════════════════════════════════════════════
--   BEGIN;
--   DROP INDEX IF EXISTS idx_etl_dead_letter_unresolved;
--   ALTER TABLE etl_dead_letter DROP COLUMN IF EXISTS resolution_note;
--   ALTER TABLE etl_dead_letter DROP COLUMN IF EXISTS resolved_at;
--   COMMIT;
-- Only use if BUG-105 rerun is rolled back AND we want to restore pre-BUG-105
-- column layout. Keep evidence audit doc regardless of rollback decision.
-- ════════════════════════════════════════════════════════════════════════════
