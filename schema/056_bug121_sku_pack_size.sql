-- ════════════════════════════════════════════════════════════════════════════
-- schema/056_bug121_sku_pack_size.sql
-- BUG-121 — sku.pack_size column for bottle pack size distinction (375ml, 750ml, Magnum)
-- ════════════════════════════════════════════════════════════════════════════
-- Date:     2026-04-24
--           BUG-137 AC3 (Phase I v2 umbrella)
--
-- FORWARD-ONLY & ADDITIVE: ALTER TABLE ADD COLUMN only. Nullable column; no
-- existing column altered or dropped. Rollback = DROP COLUMN (safe because
-- no reads depend on it yet).
--
-- BLAST RADIUS: adds one nullable VARCHAR(32) column to `sku` (466 rows).
-- PostgreSQL ALTER TABLE ADD COLUMN with no default is O(1) metadata-only —
-- does not rewrite the table. No writes. No reads change. No existing query
-- references pack_size.
--
-- WHY: the owner 2026-04-22 09:38 Q10: "SKU is Moppity Estate Shiraz 375ml -
-- Range is Moppity Estate." Half-bottle (375ml), Magnum, 6-pack, etc. are
-- pack-size variants of a single logical wine product. Per ADR-012 (to be
-- written this session): one canonical_sku per wine, pack-size distinction
-- at the sku level. This column enables that distinction without forking
-- canonicals per size (which would fragment analytics).
--
-- EXPECTED POST-STATE (after this migration, before BUG-121 UPDATE):
--   sku row count = 466 (unchanged)
--   sku column count = current + 1 (pack_size added)
--   pack_size IS NOT NULL count = 0 (populate via BUG-121 UPDATE in session)
--   Legal values: '375ml', '750ml', 'Magnum', '6-pack', 'piccolo-200ml', ...
--     (free-form VARCHAR; no CHECK constraint — keeps migration zero-ceremony)
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
          AND column_name='pack_size'
    ) THEN
        RAISE EXCEPTION
          'sku.pack_size already exists; aborting to surface re-run state';
    END IF;
END $$;

-- ────────────────────────────────────────────────────────────────────────────
-- 2. ALTER TABLE ADD COLUMN
-- ────────────────────────────────────────────────────────────────────────────
ALTER TABLE sku
  ADD COLUMN pack_size VARCHAR(32);

COMMENT ON COLUMN sku.pack_size IS
  'BUG-121 (2026-04-24): pack-size variant identifier for wine sku rows. '
  'Free-form VARCHAR(32) — typical values 375ml, 750ml, Magnum, 6-pack, '
  'piccolo-200ml. NULL = unspecified (default; the canonical_sku.units_per_case '
  'remains the primary pack-density signal for reports). Populated only when '
  'a sku row needs to be distinguished from its canonical parent by pack size '
  '(e.g. MVESSHZH14 = 375ml half-bottle under MOPPITY ESTATE SHIRAZ canonical '
  'id=68). See ADR-012 for semantics. Intentionally nullable to avoid forcing '
  'pack_size on every historical sku row; readers treat NULL as "no pack_size '
  'override, use canonical defaults".';

-- ────────────────────────────────────────────────────────────────────────────
-- 3. Post-create assertions
-- ────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    col_type TEXT;
    col_nullable TEXT;
    non_null_count INTEGER;
BEGIN
    SELECT data_type, is_nullable INTO col_type, col_nullable
    FROM information_schema.columns
    WHERE table_schema='public' AND table_name='sku' AND column_name='pack_size';

    IF col_type IS NULL THEN
        RAISE EXCEPTION 'sku.pack_size column was not created';
    END IF;
    IF col_type <> 'character varying' THEN
        RAISE EXCEPTION 'sku.pack_size wrong type: %', col_type;
    END IF;
    IF col_nullable <> 'YES' THEN
        RAISE EXCEPTION 'sku.pack_size wrong nullability: %', col_nullable;
    END IF;

    SELECT count(*) INTO non_null_count FROM sku WHERE pack_size IS NOT NULL;
    IF non_null_count <> 0 THEN
        RAISE EXCEPTION
          'sku.pack_size has % non-NULL rows pre-populate (expected 0)',
          non_null_count;
    END IF;

    IF (SELECT count(*) FROM sku) <> 466 THEN
        RAISE EXCEPTION
          'sku row count changed during ADD COLUMN (expected 466, got %)',
          (SELECT count(*) FROM sku);
    END IF;

    RAISE NOTICE
      'schema/056 OK: sku.pack_size added (nullable VARCHAR(32)), '
      '0 non-NULL values — ready for BUG-121 UPDATE';
END $$;

COMMIT;

-- ════════════════════════════════════════════════════════════════════════════
-- Rollback recipe (safe before BUG-121 UPDATE lands values):
--   BEGIN;
--     ALTER TABLE sku DROP COLUMN IF EXISTS pack_size;
--   COMMIT;
-- After BUG-121 UPDATE populates rows:
--   ssh root@your-server-ip "sudo -u postgres pg_restore -d moppity_db --clean \
--     --if-exists /var/backups/moppity/full_pre_phase_i_v2_2026-04-24.pgdump"
-- ════════════════════════════════════════════════════════════════════════════
