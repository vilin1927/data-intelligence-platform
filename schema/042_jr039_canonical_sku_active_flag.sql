-- =============================================================================
-- 042_jr039_canonical_sku_active_flag.sql
-- JR-039: Add is_active_canonical flag so canonical_sku can separate the owner's
-- 99 active canonicals from the 37 discontinued/legacy bridge rows added by
-- migration 034 for dead-letter recovery.
-- =============================================================================
--   sheet "SKU table" — 99 rows = the owner's authoritative canonical list.
--
-- VPS state at write-time (2026-04-19):
--   canonical_sku.id 1..99  — matched 1:1 to the owner's "SKU table" (created 2026-03-26 / 29).
--   canonical_sku.id 100..136 — 37 legacy bridges (created 2026-04-14 by schema/034).
--
-- All 37 legacy rows have 0 sales_transaction refs, 0 sku_code_map refs;
-- they exist only so 1,254 historical Access dead-letter rows resolve.
--
-- This migration does NOT delete or merge anything. It adds a flag so
-- user-facing "total SKUs" counts can report 99 while ETL lookups still work.
-- Forward-only; idempotent on re-run.
-- =============================================================================

BEGIN;

-- 1. Add column (idempotent)
ALTER TABLE canonical_sku
  ADD COLUMN IF NOT EXISTS is_active_canonical BOOLEAN NOT NULL DEFAULT TRUE;

COMMENT ON COLUMN canonical_sku.is_active_canonical IS
  'TRUE for the owner''s 99 canonical wines (from his reconciliation xlsx "SKU table"). FALSE for legacy/discontinued bridge rows that exist only for Access dead-letter ETL resolution. User-facing SKU counts should filter on this flag; ETL lookups should ignore it.';

-- 2. Flag the 37 legacy rows (IDs 100..136) as inactive
--    Criterion: id >= 100 (the first post-Owner id). Verified by name-diff
--    against HARD source (the owner's xlsx SKU table) on 2026-04-19 — see
UPDATE canonical_sku
   SET is_active_canonical = FALSE
 WHERE id >= 100
   AND is_active_canonical = TRUE;

-- 3. Guard: expect exactly 99 active / 37 legacy. Abort if not.
DO $$
DECLARE
  active_ct INTEGER;
  legacy_ct INTEGER;
BEGIN
  SELECT COUNT(*) INTO active_ct FROM canonical_sku WHERE is_active_canonical = TRUE;
  SELECT COUNT(*) INTO legacy_ct FROM canonical_sku WHERE is_active_canonical = FALSE;
  RAISE NOTICE 'JR-039 post-migration: active=% legacy=% total=%', active_ct, legacy_ct, active_ct + legacy_ct;
  IF active_ct <> 99 OR legacy_ct <> 37 THEN
    RAISE EXCEPTION 'JR-039 guard failed: expected 99 active / 37 legacy, got active=% / legacy=%. Aborting.',
      active_ct, legacy_ct;
  END IF;
END $$;

COMMIT;
