-- =============================================================================
-- Moppity Vineyards — CLARIFY-11 Victoria territory map (079_clarify11_victoria_territory_map.sql)
-- =============================================================================
-- Date:      2026-04-26
-- Author:    Vladimir (Autoflux) + Sprint 1.5 session
-- Ticket:    CLARIFY-11 AC1 — "Victoria and Victoria Off mapped to canonical territories"
-- Override:  exports/clarify-11-victoria-territory-map-2026-04-26.csv
--            (per-row override CSV — the owner can flip any of 12,218 transaction_ids)
--
-- WHY THIS EXISTS
-- ---------------
-- Database reconciliation (1).xlsx`) has 30 entries. Live `canonical_territory`
-- count = 30, verified 2026-04-26.
--
-- Our `territory` table (40 rows total) contains two entries that don't exist
-- in his 30-canonical list:
--   - 'Victoria'     (territory_id=91, 1,589 sales_transaction rows)
--   - 'Victoria Off' (territory_id=93, 10,629 sales_transaction rows)
--
-- Combined: 12,218 transactions (~10% of all sales) had no canonical home.
-- Phase E default per strategy doc §3 row 6: map each Victoria* territory to
-- the dominant VIC canonical by suburb majority; ship a per-row override CSV.
--
-- Suburb majority analysis (audit doc §2):
--   - 'Victoria': 100% MELBOURNE suburb (1,589/1,589) → VIC Melbourne CBD.
--   - 'Victoria Off': 180 distinct suburbs; plurality cluster = inner-CBD ring
--     + inner-South. Default to VIC Melbourne CBD as "Vic-metro home" canonical;
--     The owner overrides per-row via CSV.
--
-- Both Victoria* rows map to canonical_id 21 'VIC Melbourne CBD' at the
-- territory level. Per-row precision lives in the override CSV.
--
-- SCHEMA CHANGE
-- -------------
-- The `territory` table has NO canonical_id FK today (verified live; columns:
-- territory_id, territory_name, state, region, created_at). This migration
-- adds:
--   ALTER TABLE territory ADD COLUMN IF NOT EXISTS canonical_territory_id INT
--     REFERENCES canonical_territory(id);
--
-- Pattern mirrors customer.canonical_customer_id (existing FK precedent).
-- Forward-only; rest of the territory table left NULL until a future ticket.
-- Phase E pattern: only fix what this ticket cares about.
--
-- TRANSACTION + PRE/POST ASSERTIONS
-- ---------------------------------
-- BEGIN; pre-asserts current state matches expected (12,218 Victoria* txns,
-- column absent or NULL on Victoria* rows); ALTER TABLE ADD COLUMN IF NOT
-- EXISTS; UPDATE SET canonical_territory_id=21 on the two rows; post-asserts
-- both rows mapped, other 38 untouched, FK integrity holds; INSERT
-- schema_migrations; COMMIT. ROLLBACK if any assertion fails.
--
-- IDEMPOTENT
-- ----------
-- ADD COLUMN IF NOT EXISTS makes the schema change idempotent. The UPDATE has
-- WHERE canonical_territory_id IS NULL so re-running won't overwrite prior
-- assignments (e.g. if the owner overrides one of the two rows post-CSV review and
-- a separate UPDATE was applied).
-- =============================================================================

BEGIN;

-- =============================================================================
-- 1. PRE-state assertion: confirm prod matches expected state.
-- =============================================================================

DO $$
DECLARE
  v_canonical_count INT;
  v_territory_total INT;
  v_victoria_count INT;
  v_victoria_off_count INT;
  v_victoria_txns INT;
  v_victoria_off_txns INT;
  v_combined_txns INT;
  v_column_exists BOOL;
  v_cbd_canonical_id INT;
BEGIN
  -- Canonical territory count must equal the owner's 30
  SELECT COUNT(*) INTO v_canonical_count FROM canonical_territory;

  -- Locate VIC Melbourne CBD canonical id (target for both Victoria* rows)
  SELECT id INTO v_cbd_canonical_id
  FROM canonical_territory
  WHERE territory_name = 'VIC Melbourne CBD';

  -- Source territory state
  SELECT COUNT(*) INTO v_territory_total FROM territory;

  SELECT COUNT(*) INTO v_victoria_count
  FROM territory WHERE territory_name = 'Victoria';

  SELECT COUNT(*) INTO v_victoria_off_count
  FROM territory WHERE territory_name = 'Victoria Off';

  -- Transaction counts on the two Victoria* rows
  SELECT COUNT(*) INTO v_victoria_txns
  FROM sales_transaction st
  JOIN territory t ON t.territory_id = st.territory_id
  WHERE t.territory_name = 'Victoria';

  SELECT COUNT(*) INTO v_victoria_off_txns
  FROM sales_transaction st
  JOIN territory t ON t.territory_id = st.territory_id
  WHERE t.territory_name = 'Victoria Off';

  v_combined_txns := v_victoria_txns + v_victoria_off_txns;

  -- Schema check: is canonical_territory_id column present yet?
  SELECT EXISTS (
    SELECT 1 FROM information_schema.columns
     WHERE table_schema = 'public'
       AND table_name = 'territory'
       AND column_name = 'canonical_territory_id'
  ) INTO v_column_exists;

  RAISE NOTICE 'CLARIFY-11 PRE: canonical_count=% (expect 30) territory_total=% victoria_rows=% victoria_off_rows=% victoria_txns=% victoria_off_txns=% combined_txns=% canonical_id_column_exists=% target_cbd_canonical_id=%',
    v_canonical_count, v_territory_total, v_victoria_count, v_victoria_off_count,
    v_victoria_txns, v_victoria_off_txns, v_combined_txns, v_column_exists,
    v_cbd_canonical_id;

  -- Hard guards: bail if any of these drift unexpectedly
  IF v_canonical_count <> 30 THEN
    RAISE EXCEPTION 'CLARIFY-11 PRE: canonical_territory count is % (expected 30 per the owner xlsx)', v_canonical_count;
  END IF;

  IF v_cbd_canonical_id IS NULL THEN
    RAISE EXCEPTION 'CLARIFY-11 PRE: VIC Melbourne CBD canonical not found — cannot proceed';
  END IF;

  IF v_victoria_count <> 1 THEN
    RAISE EXCEPTION 'CLARIFY-11 PRE: expected exactly 1 Victoria row, got %', v_victoria_count;
  END IF;

  IF v_victoria_off_count <> 1 THEN
    RAISE EXCEPTION 'CLARIFY-11 PRE: expected exactly 1 Victoria Off row, got %', v_victoria_off_count;
  END IF;

  IF v_combined_txns < 12000 OR v_combined_txns > 12500 THEN
    RAISE EXCEPTION 'CLARIFY-11 PRE: combined Victoria* txn count % outside expected ~12218 band', v_combined_txns;
  END IF;
END;
$$;

-- =============================================================================
-- 2. ALTER TABLE ADD COLUMN canonical_territory_id (forward-only schema add).
--    Idempotent via IF NOT EXISTS.
-- =============================================================================

ALTER TABLE territory
  ADD COLUMN IF NOT EXISTS canonical_territory_id INT
    REFERENCES canonical_territory(id);

COMMENT ON COLUMN territory.canonical_territory_id IS
  'Phase E (CLARIFY-11) link from territory → canonical_territory. Mirrors '
  'customer.canonical_customer_id pattern. Only Victoria/Victoria Off rows '
  'are backfilled in schema/079; other 38 rows remain NULL until a future '
  'ticket. Per-row override CSV at exports/clarify-11-victoria-territory-'
  'map-2026-04-26.csv lets the owner flip individual transactions.';

-- =============================================================================
-- 3. UPDATE: map both Victoria* territory rows to VIC Melbourne CBD (canonical
--    id 21 by name lookup — defensive against id drift). Idempotent via
--    WHERE canonical_territory_id IS NULL.
-- =============================================================================

UPDATE territory
SET canonical_territory_id = (
  SELECT id FROM canonical_territory WHERE territory_name = 'VIC Melbourne CBD'
)
WHERE territory_name IN ('Victoria', 'Victoria Off')
  AND canonical_territory_id IS NULL;

-- =============================================================================
-- 4. POST-state assertion: both Victoria* rows mapped; other 38 untouched;
--    FK integrity holds.
-- =============================================================================

DO $$
DECLARE
  v_victoria_mapped INT;
  v_victoria_off_mapped INT;
  v_other_mapped INT;
  v_other_null INT;
  v_total INT;
  v_orphans INT;
  v_target_cbd_id INT;
  v_victoria_canon_id INT;
  v_victoria_off_canon_id INT;
BEGIN
  SELECT id INTO v_target_cbd_id
  FROM canonical_territory WHERE territory_name = 'VIC Melbourne CBD';

  SELECT canonical_territory_id INTO v_victoria_canon_id
  FROM territory WHERE territory_name = 'Victoria';

  SELECT canonical_territory_id INTO v_victoria_off_canon_id
  FROM territory WHERE territory_name = 'Victoria Off';

  SELECT COUNT(*) INTO v_victoria_mapped
  FROM territory
  WHERE territory_name = 'Victoria' AND canonical_territory_id IS NOT NULL;

  SELECT COUNT(*) INTO v_victoria_off_mapped
  FROM territory
  WHERE territory_name = 'Victoria Off' AND canonical_territory_id IS NOT NULL;

  SELECT COUNT(*) INTO v_other_mapped
  FROM territory
  WHERE territory_name NOT IN ('Victoria', 'Victoria Off')
    AND canonical_territory_id IS NOT NULL;

  SELECT COUNT(*) INTO v_other_null
  FROM territory
  WHERE territory_name NOT IN ('Victoria', 'Victoria Off')
    AND canonical_territory_id IS NULL;

  SELECT COUNT(*) INTO v_total FROM territory;

  -- Orphan check: any canonical_territory_id pointing to a non-existent canonical row
  SELECT COUNT(*) INTO v_orphans
  FROM territory t
  WHERE t.canonical_territory_id IS NOT NULL
    AND NOT EXISTS (
      SELECT 1 FROM canonical_territory ct WHERE ct.id = t.canonical_territory_id
    );

  RAISE NOTICE 'CLARIFY-11 POST: victoria_mapped=% victoria_off_mapped=% other_mapped=% other_null=% total=% orphans=% target_cbd_id=% victoria_canon_id=% victoria_off_canon_id=%',
    v_victoria_mapped, v_victoria_off_mapped, v_other_mapped, v_other_null,
    v_total, v_orphans, v_target_cbd_id, v_victoria_canon_id, v_victoria_off_canon_id;

  IF v_victoria_mapped <> 1 THEN
    RAISE EXCEPTION 'CLARIFY-11 POST: Victoria row not mapped (mapped count=%)', v_victoria_mapped;
  END IF;

  IF v_victoria_off_mapped <> 1 THEN
    RAISE EXCEPTION 'CLARIFY-11 POST: Victoria Off row not mapped (mapped count=%)', v_victoria_off_mapped;
  END IF;

  IF v_victoria_canon_id IS DISTINCT FROM v_target_cbd_id THEN
    RAISE EXCEPTION 'CLARIFY-11 POST: Victoria mapped to wrong canonical id % (expected % VIC Melbourne CBD)',
      v_victoria_canon_id, v_target_cbd_id;
  END IF;

  IF v_victoria_off_canon_id IS DISTINCT FROM v_target_cbd_id THEN
    RAISE EXCEPTION 'CLARIFY-11 POST: Victoria Off mapped to wrong canonical id % (expected % VIC Melbourne CBD)',
      v_victoria_off_canon_id, v_target_cbd_id;
  END IF;

  -- Other 38 territories should remain untouched (Phase E pattern: only fix what this ticket cares about).
  -- Soft guard: tolerate prior backfill from other migrations, but flag if non-zero so it's visible.
  IF v_other_mapped <> 0 THEN
    RAISE NOTICE 'CLARIFY-11 POST NOTE: % territories outside Victoria* already have canonical_territory_id set (likely a future migration also runs). Not a failure.', v_other_mapped;
  END IF;

  IF v_orphans <> 0 THEN
    RAISE EXCEPTION 'CLARIFY-11 POST: % territory rows point to non-existent canonical (FK violation)', v_orphans;
  END IF;

  IF v_total < 38 OR v_total > 45 THEN
    RAISE EXCEPTION 'CLARIFY-11 POST: territory count drift (got %, expected ~40)', v_total;
  END IF;
END;
$$;

-- =============================================================================
-- 5. Record migration in schema_migrations (idempotent).
-- =============================================================================

INSERT INTO schema_migrations (version, source)
VALUES ('079_clarify11_victoria_territory_map', 'live-apply')
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- =============================================================================
-- ROLLBACK / DOWN-MIGRATION RECIPE (manual; not auto-run)
-- =============================================================================
-- This migration adds a column + maps two rows. To revert:
--   UPDATE territory SET canonical_territory_id = NULL
--    WHERE territory_name IN ('Victoria','Victoria Off');
--   ALTER TABLE territory DROP COLUMN IF EXISTS canonical_territory_id;
--   DELETE FROM schema_migrations WHERE version = '079_clarify11_victoria_territory_map';
-- For instant pre-apply restore: pg_restore -d moppity_db /var/backups/moppity/full_pre_clarify11.pgdump
