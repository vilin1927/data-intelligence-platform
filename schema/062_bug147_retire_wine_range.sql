-- =============================================================================
-- 062_bug147_retire_wine_range.sql — retire wine_range VIEW + sku.range_id column
-- =============================================================================
-- Ticket : BUG-147 (Phase T reader refactor, follow-up to BUG-101 Phase O)
-- Phase  : T (Access-first migration plan 2026-04-22, final step of range SoT)
-- Run as : psql -U moppity -d moppity_db -f schema/062_bug147_retire_wine_range.sql
--
-- Purpose:
--   All dashboard + AI readers have been refactored off wine_range onto direct
--   JOIN with canonical_sku (BUG-147 AC1). The compatibility VIEW created in
--   schema/051, the deprecated table preserved in schema/051, the single-column
--   undo table from schema/058, and the now-unreferenced sku.range_id column
--   can all be retired in a single forward-only migration.
--
-- Pre-apply checks (run manually BEFORE executing this file):
--
--   -- 1. Confirm no application code still references wine_range:
--   -- (Run from repo root.)
--   -- $ grep -rn 'wine_range' dashboard/src etl scripts
--   -- Expected: only META mentions that say "VIEW over canonical_sku" /
--   --           "retired" / similar wording, no LEFT JOIN / INSERT / SELECT
--   --           FROM wine_range. The ai-sql-fallback WHITELISTED_TABLES must
--   --           no longer contain 'wine_range'.
--
--   -- 2. Confirm no residual sku.range_id references in code:
--   -- $ grep -rn '\.range_id\b\|s\.range_id\|sku\.range_id' dashboard/src etl scripts
--   -- Expected: inventory route + what-if route may still SELECT s.range_id
--   --           but should not JOIN on it. Any JOIN on s.range_id = wr.range_id
--   --           is a blocker.
--
--   -- 3. Snapshot + git tag BEFORE apply:
--   -- $ ssh root@your-server-ip 'pg_dump -U moppity moppity_db -F c -f /var/backups/moppity/full_pre_phase_t_2026-04-23.pgdump'
--   -- $ git tag pre-phase-t-2026-04-23 <HEAD sha>
--
-- Forward-only. Idempotent via IF EXISTS / IF EXISTS clauses.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- Step 1: drop the wine_range VIEW (was created by schema/051).
-- -----------------------------------------------------------------------------
-- Readers no longer reference wine_range; the VIEW has no dependents.
-- (If any DEPENDENT slipped through pre-apply grep, `DROP VIEW` will fail
-- with "cannot drop view wine_range because other objects depend on it"
-- and point at the dependent. Do NOT use CASCADE — stop and investigate.)

DROP VIEW IF EXISTS wine_range;

-- -----------------------------------------------------------------------------
-- Step 2: drop wine_range_deprecated (row-data preserved for rollback in
-- schema/051 — no longer needed now that Phase T closes the migration).
-- -----------------------------------------------------------------------------

DROP TABLE IF EXISTS wine_range_deprecated;

-- -----------------------------------------------------------------------------
-- Step 3: drop sku_range_id_backup_2026_04_23 (undo table for schema/058
-- backfill — only useful if readers still used sku.range_id).
-- -----------------------------------------------------------------------------

DROP TABLE IF EXISTS sku_range_id_backup_2026_04_23;

-- -----------------------------------------------------------------------------
-- Step 4: drop the sku.range_id column now that no reader joins on it.
-- -----------------------------------------------------------------------------
-- The FK was dropped in schema/051 (pre-VIEW-demotion). The column itself
-- became a soft reference. Phase T retires it so canonical_sku_id is the
-- single sku → range resolution path.

ALTER TABLE sku DROP COLUMN IF EXISTS range_id;

-- -----------------------------------------------------------------------------
-- Verification (run manually after apply — NOT executed by this script).
-- -----------------------------------------------------------------------------
--
--   -- Expected: 0 rows (VIEW, both tables, and column all gone).
--   SELECT relname, relkind
--   FROM pg_class
--   WHERE relname IN ('wine_range',
--                     'wine_range_deprecated',
--                     'sku_range_id_backup_2026_04_23');
--
--   -- Expected: range_id column absent from sku.
--   SELECT column_name
--   FROM information_schema.columns
--   WHERE table_name = 'sku' AND column_name = 'range_id';
--
--   -- Expected: 466 rows, all with non-NULL range_name (via canonical JOIN).
--   SELECT count(*) AS total,
--          count(*) FILTER (WHERE cs.range_name IS NOT NULL) AS with_range
--   FROM sku s LEFT JOIN canonical_sku cs ON cs.id = s.canonical_sku_id;
--
-- -----------------------------------------------------------------------------

COMMIT;

-- =============================================================================
-- Rollback (manual, forward-only migration kept alongside for the DBA):
--
-- Rollback is NON-TRIVIAL because schema/051 renamed wine_range → wine_range_
-- deprecated and schema/058 backfilled sku.range_id. To restore the pre-Phase-T
-- state you need BOTH:
--
--   1. Re-create the VIEW from canonical_sku (same DDL as schema/051 Step 3).
--   2. Re-add sku.range_id as an INTEGER nullable column and backfill from
--      canonical_sku via the VIEW's MIN(cs.id) mapping (same logic as
--      schema/058 Step 2).
--
-- This cannot be done by a single-line revert — it is a re-application of the
-- two predecessor migrations. If rollback is needed, replay schema/051 + schema/
-- 058 in order, then re-apply any reader-level code changes that want the old
-- VIEW-based JOIN back. In practice, the forward path (keep canonical_sku as
-- SoT) is the intended direction and rollback is not expected to be exercised.
-- =============================================================================
