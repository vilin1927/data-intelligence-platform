-- ════════════════════════════════════════════════════════════════════════════
-- schema/057_bug122_sku_is_dry_goods.sql
-- BUG-122 AC3 — sku.is_dry_goods flag for Phase 2 dry-goods inventory tracking
-- ════════════════════════════════════════════════════════════════════════════
-- Date:     2026-04-24
--           BUG-137 AC4 (Phase I v2 umbrella)
--            7 B-* Vinsight codes, all currently routed through sku_code_map
--            to wine sku rows — no sku row currently needs flip to TRUE this
--            session; this column is Phase 2 infrastructure)
--
-- FORWARD-ONLY & ADDITIVE: ALTER TABLE ADD COLUMN with NOT NULL DEFAULT FALSE.
-- Column is SAME CARDINALITY as sku.is_wine (parallel boolean flag). No
-- existing column altered or dropped. Rollback = DROP COLUMN.
--
-- BLAST RADIUS: adds one NOT NULL BOOLEAN column to `sku` (466 rows). On
-- PostgreSQL 11+ ALTER TABLE ADD COLUMN ... DEFAULT <constant> NOT NULL is
-- O(1) metadata-only (DEFAULT FALSE is constant-expression). No writes. No
-- reads change. No existing query references is_dry_goods.
--
-- WHY: the owner 2026-04-22 09:38 Q11: "B-MVECSHZO06 - not wine. Dry goods
-- inventory (later phase)." B- prefix Vinsight codes (B-MVECSHZO06,
-- B-COCOGSPC12, B-COCSATLC06, B-COCSATLINC6, B-COCOVIRC12, B-MVECSHZX01,
-- B-MVECSHZX03 — 7 codes total) represent packaging-line operations in
-- Vinsight, not standalone finished-wine sku rows. Today they route through
-- sku_code_map to legitimate wine sku rows (sku_id=64 "Moppity Escalier
-- Shiraz 6 pack", sku_id=16 "COPPABELLA SPARKLING ROSE", etc.) — this is
-- correct at the finished-wine level because the packaging line produces
-- that wine. The sku-row level flag prepares infrastructure for Phase 2:
-- a future dry_goods_inventory module that will track packaging inputs
-- (cartons, labels, caps) separately from finished wine. For now, the flag
-- is 0% populated — no sku row is dry goods YET (all current sku rows are
-- finished wine per is_wine audit).
--
-- WHY sku NOT canonical_sku (ADR-012):
--   - `sku.is_wine` already exists as a row-level flag; is_dry_goods is its
--     parallel partner at the same grain
--   - B-MVECSHZO06 does not itself have a canonical_sku row (it's a Vinsight-
--     only code); a canonical_sku flag would have nowhere to land
--   - Future dry-goods ingests (cartons, labels) will create per-code sku
--     rows with is_wine=FALSE + is_dry_goods=TRUE — matches sku-row grain
--
-- EXPECTED POST-STATE (after this migration):
--   sku row count = 466 (unchanged)
--   sku column count = current + 1 (is_dry_goods added)
--   is_dry_goods=TRUE count = 0 (no sku row flipped this session; Phase 2
--     will populate via dry-goods ingest path)
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ────────────────────────────────────────────────────────────────────────────
-- 1. Pre-apply assertions
-- ────────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
    IF to_regclass('public.sku') IS NULL THEN
        RAISE EXCEPTION 'sku table missing; abort';
    END IF;

    IF (SELECT count(*) FROM sku) <> 466 THEN
        RAISE EXCEPTION
          'sku row count % (expected 466); state drift — verify before migrating',
          (SELECT count(*) FROM sku);
    END IF;

    -- Idempotency guard: column must not already exist
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='public'
          AND table_name='sku'
          AND column_name='is_dry_goods'
    ) THEN
        RAISE EXCEPTION
          'sku.is_dry_goods already exists; aborting to surface re-run state';
    END IF;
END $$;

-- ────────────────────────────────────────────────────────────────────────────
-- 2. ALTER TABLE ADD COLUMN
-- ────────────────────────────────────────────────────────────────────────────
ALTER TABLE sku
  ADD COLUMN is_dry_goods BOOLEAN NOT NULL DEFAULT FALSE;

COMMENT ON COLUMN sku.is_dry_goods IS
  'BUG-122 AC3 (2026-04-24): packaging/dry-goods flag parallel to sku.is_wine. '
  'TRUE = this sku row represents packaging inputs (cartons, labels, caps, etc.), '
  'tracked separately from finished wine in Phase 2 dry_goods_inventory module. '
  'DEFAULT FALSE — all current 466 sku rows are finished wine (464 is_wine=TRUE + '
  '2 is_wine=FALSE service/placeholder rows). Phase 2 dry-goods ingests will '
  'create new sku rows with is_wine=FALSE + is_dry_goods=TRUE. The owner 2026-04-22 '
  '09:38 Q11 framing: B- prefix Vinsight codes (e.g. B-MVECSHZO06) represent '
  'packaging-line operations in Vinsight, not standalone finished wine; today '
  'they route through sku_code_map to legitimate wine sku rows (correct at '
  'finished-product level). See ADR-012 for full B-/M- convention.';

-- ────────────────────────────────────────────────────────────────────────────
-- 3. Post-create assertions
-- ────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    col_type TEXT;
    col_nullable TEXT;
    col_default TEXT;
    true_count INTEGER;
    false_count INTEGER;
BEGIN
    SELECT data_type, is_nullable, column_default
      INTO col_type, col_nullable, col_default
    FROM information_schema.columns
    WHERE table_schema='public' AND table_name='sku' AND column_name='is_dry_goods';

    IF col_type IS NULL THEN
        RAISE EXCEPTION 'sku.is_dry_goods column was not created';
    END IF;
    IF col_type <> 'boolean' THEN
        RAISE EXCEPTION 'sku.is_dry_goods wrong type: %', col_type;
    END IF;
    IF col_nullable <> 'NO' THEN
        RAISE EXCEPTION 'sku.is_dry_goods wrong nullability: % (expected NO)', col_nullable;
    END IF;
    IF col_default NOT LIKE 'false%' THEN
        RAISE EXCEPTION 'sku.is_dry_goods wrong default: %', col_default;
    END IF;

    SELECT count(*) INTO true_count  FROM sku WHERE is_dry_goods = TRUE;
    SELECT count(*) INTO false_count FROM sku WHERE is_dry_goods = FALSE;

    IF true_count <> 0 THEN
        RAISE EXCEPTION
          'sku.is_dry_goods has % TRUE rows post-ADD COLUMN (expected 0)', true_count;
    END IF;
    IF false_count <> 466 THEN
        RAISE EXCEPTION
          'sku.is_dry_goods has % FALSE rows post-ADD COLUMN (expected 466)', false_count;
    END IF;

    RAISE NOTICE
      'schema/057 OK: sku.is_dry_goods added (NOT NULL BOOLEAN DEFAULT FALSE), '
      '0 TRUE / 466 FALSE — Phase 2 dry-goods infrastructure ready';
END $$;

COMMIT;

-- ════════════════════════════════════════════════════════════════════════════
-- Rollback recipe:
--   BEGIN;
--     ALTER TABLE sku DROP COLUMN IF EXISTS is_dry_goods;
--   COMMIT;
--   (Safe because no sku row has is_dry_goods=TRUE this session; no Phase 2
--    readers depend on the column yet.)
-- ════════════════════════════════════════════════════════════════════════════
