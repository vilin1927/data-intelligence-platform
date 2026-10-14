-- =============================================================================
-- 051_bug101_wine_range_view.sql — wine_range → VIEW over canonical_sku
-- =============================================================================
-- Ticket : BUG-101 (CTO canonicity audit 2026-04-21, dimension #29)
-- Phase  : O (Access-first migration plan 2026-04-22, step 58)
-- Run as : psql -U moppity -d moppity_db -f schema/051_bug101_wine_range_view.sql
--
-- Purpose:
--   Demote wine_range from an independent table (dual-source drift risk with
--   canonical_sku.range_name) to a VIEW that derives range data exclusively
--   from canonical_sku. Old table is preserved as wine_range_deprecated so the
--   row-data (including any stable range_id values referenced by sku.range_id)
--   can be restored by a simple RENAME on rollback.
--
-- Forward-only. Idempotent where possible (uses IF EXISTS / IF NOT EXISTS).
-- Do NOT apply outside the Phase O deploy window — Phase T will retire the
-- populate_wine_range() ETL step and any readers that can move to
-- canonical_sku directly.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- Step 1: drop the FK from sku.range_id → wine_range(range_id)
-- -----------------------------------------------------------------------------
-- Postgres does not allow a VIEW to be the target of a FOREIGN KEY. We keep
-- the sku.range_id *column* (readers still JOIN on it), but drop the
-- constraint so it becomes a soft reference resolved through the VIEW.
-- Phase T will either re-point these JOINs to canonical_sku or drop
-- sku.range_id entirely.

ALTER TABLE sku DROP CONSTRAINT IF EXISTS sku_range_id_fkey;

-- -----------------------------------------------------------------------------
-- Step 2: preserve the existing wine_range rows under a new name
-- -----------------------------------------------------------------------------
-- Row-data retained for rollback (see file header). After the rename, the
-- name "wine_range" is free for the VIEW defined below.

ALTER TABLE IF EXISTS wine_range RENAME TO wine_range_deprecated;

COMMENT ON TABLE wine_range_deprecated IS
  'DEPRECATED 2026-04-22 by BUG-101 / ADR-010. Replaced by VIEW wine_range '
  'over canonical_sku. Kept for rollback only — DO NOT write to this table. '
  'Retire in Phase T once all readers reconfirmed on the VIEW.';

-- -----------------------------------------------------------------------------
-- Step 3: CREATE VIEW wine_range over canonical_sku
-- -----------------------------------------------------------------------------
-- Column parity with the old wine_range table so every existing reader
-- (dashboard/src/app/api/**, dashboard/src/lib/ai-tools.ts, AI SQL fallback)
-- is drop-in:
--   range_id    INTEGER  — stable identity derived from canonical_sku.id of
--                          the first canonical row per range_name (MIN(id)).
--                          Readers JOIN on sku.range_id = wr.range_id; Phase T
--                          will backfill sku.range_id to this derived value.
--   range_name  VARCHAR  — from canonical_sku.range_name (the source of truth).
--   range_group VARCHAR  — from canonical_sku.range_group, deterministic via
--                          MIN() so repeated evaluation is stable.
--   created_at  TIMESTAMP — MIN(canonical_sku.created_at) per range so the
--                          column still exists with a plausible value for the
--                          one reader (reference-tables/TableCounts) that
--                          expects a timestamp column to exist.

CREATE OR REPLACE VIEW wine_range AS
SELECT
    MIN(cs.id)                       AS range_id,
    cs.range_name                    AS range_name,
    MIN(cs.range_group)              AS range_group,
    MIN(cs.created_at)               AS created_at
FROM canonical_sku cs
WHERE cs.range_name IS NOT NULL
  AND cs.range_name <> ''
GROUP BY cs.range_name;

COMMENT ON VIEW wine_range IS
  'VIEW (BUG-101 / ADR-010): derived from canonical_sku.range_name. '
  'canonical_sku.range_name is the single source of truth. Writes go to '
  'canonical_sku, never here. Old table preserved as wine_range_deprecated.';

-- -----------------------------------------------------------------------------
-- Verification (run manually after apply — NOT executed by this script).
-- -----------------------------------------------------------------------------
-- Expected: identical counts from all three expressions.
--
--   SELECT count(*) FROM wine_range;
--   SELECT count(DISTINCT range_name) FROM canonical_sku
--     WHERE range_name IS NOT NULL AND range_name <> '';
--   SELECT count(DISTINCT range_name) FROM wine_range_deprecated
--     WHERE range_name IS NOT NULL;    -- may differ if Access had ranges
--                                      -- the owner's xlsx does not. Investigate
--                                      -- any delta before continuing Phase O.
--
-- Smoke query to confirm dashboard JOIN shape still resolves:
--   SELECT s.sku_code, wr.range_name
--   FROM sku s
--   LEFT JOIN wine_range wr ON wr.range_id = s.range_id
--   LIMIT 5;
-- -----------------------------------------------------------------------------

COMMIT;

-- =============================================================================
-- Rollback (manual, forward-only migration kept alongside for the DBA):
--
--   BEGIN;
--   DROP VIEW IF EXISTS wine_range;
--   ALTER TABLE wine_range_deprecated RENAME TO wine_range;
--   ALTER TABLE sku
--     ADD CONSTRAINT sku_range_id_fkey
--     FOREIGN KEY (range_id) REFERENCES wine_range(range_id);
--   COMMIT;
-- =============================================================================
