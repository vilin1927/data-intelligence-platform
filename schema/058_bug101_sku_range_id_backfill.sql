-- =============================================================================
-- 058_bug101_sku_range_id_backfill.sql — re-point sku.range_id at VIEW range_id
-- =============================================================================
-- Ticket : BUG-101 (CTO canonicity audit 2026-04-21, dimension #29)
-- Phase  : O (Access-first migration plan 2026-04-22, step 58)
-- Run as : psql -U moppity -d moppity_db -f schema/058_bug101_sku_range_id_backfill.sql
--
-- Purpose:
--   After schema/051 demoted wine_range to a VIEW over canonical_sku, the
--   VIEW's range_id column is defined as MIN(canonical_sku.id) per range_name.
--   The old wine_range table used a separate SERIAL (values 1..17) that has no
--   relationship to canonical_sku.id values. Readers that JOIN on
--   sku.range_id = wr.range_id therefore lose resolution for the 133 legacy
--   sku rows whose range_id was populated from the old table.
--
--   This migration re-points sku.range_id to the VIEW's range_id for each
--   affected row, using the sku's canonical_sku_id → canonical_sku.range_name
--   → VIEW range_id path. Forward-only, additive, idempotent.
--
-- Safety:
--   - Destructive-shaped (UPDATE of historical rows) but target is HARD per
--     from the owner's xlsx. No the owner pre-auth required.
--   - Covered by BUG-109 (destructive-op authorisation log).
--   - Undo table sku_range_id_backup_2026_04_23 captures the pre-state for
--     single-column revert.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- Step 1: snapshot pre-backfill state into a single-purpose undo table.
-- -----------------------------------------------------------------------------
-- If re-running, this silently no-ops thanks to IF NOT EXISTS. Only the first
-- run's pre-state is preserved; subsequent runs see the post-backfill state
-- and update nothing (IS DISTINCT FROM guard in Step 2).

CREATE TABLE IF NOT EXISTS sku_range_id_backup_2026_04_23 AS
SELECT sku_id, range_id
FROM sku
WHERE range_id IS NOT NULL;

COMMENT ON TABLE sku_range_id_backup_2026_04_23 IS
  'BUG-101 undo path: sku.range_id values captured 2026-04-23 immediately '
  'before schema/058 backfill. Retire alongside wine_range_deprecated in '
  'Phase T once readers are migrated off sku.range_id entirely.';

-- -----------------------------------------------------------------------------
-- Step 2: backfill sku.range_id = VIEW.range_id per canonical_sku.range_name.
-- -----------------------------------------------------------------------------
-- IS DISTINCT FROM makes this idempotent: re-running touches zero rows once
-- the backfill has already landed.

UPDATE sku s
SET range_id = wr.range_id
FROM canonical_sku cs
JOIN wine_range wr ON wr.range_name = cs.range_name
WHERE s.canonical_sku_id = cs.id
  AND s.range_id IS NOT NULL
  AND (s.range_id IS DISTINCT FROM wr.range_id);

-- -----------------------------------------------------------------------------
-- Verification (run manually after apply — NOT executed by this script).
-- -----------------------------------------------------------------------------
--
--   -- Should return (133, 0, 0, 97):
--   SELECT
--     count(*) FILTER (WHERE wr.range_name = cs.range_name) AS post_correct,
--     count(*) FILTER (WHERE wr.range_name <> cs.range_name) AS post_wrong,
--     count(*) FILTER (WHERE wr.range_id IS NULL) AS post_null,
--     count(*) FILTER (WHERE wr.range_name = cs.range_name
--                        AND cs.is_active_canonical = TRUE) AS post_active_correct
--   FROM sku s
--   LEFT JOIN wine_range wr ON wr.range_id = s.range_id
--   LEFT JOIN canonical_sku cs ON cs.id = s.canonical_sku_id
--   WHERE s.range_id IS NOT NULL;
--
-- -----------------------------------------------------------------------------

COMMIT;

-- =============================================================================
-- Rollback (manual, forward-only migration kept alongside for the DBA):
--
--   BEGIN;
--   UPDATE sku s
--   SET range_id = b.range_id
--   FROM sku_range_id_backup_2026_04_23 b
--   WHERE s.sku_id = b.sku_id;
--   COMMIT;
--
-- Note: rollback only restores sku.range_id integer values. The underlying
-- wine_range VIEW (from schema/051) still returns MIN(canonical_sku.id) per
-- range_name, so rolling back this backfill without also rolling back
-- schema/051 puts readers back into the silent-wrong / null state.
-- =============================================================================
