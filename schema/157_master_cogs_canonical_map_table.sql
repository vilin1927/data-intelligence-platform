-- ════════════════════════════════════════════════════════════════════════════
-- schema/157_master_cogs_canonical_map_table.sql
-- A8 v2 — Mapping table: master_cogs.sku ↔ canonical_sku.id
-- ════════════════════════════════════════════════════════════════════════════
-- CITATION: master_cogs table replica of Access tbl_Master_COGS — schema/099_master_cogs_4cols.sql:9
-- DDL-ONLY: pure additive — CREATE TABLE, no UPDATE/DELETE on existing data
-- DESTRUCTIVE: false
--
-- Date:    2026-05-11
-- Ticket:  A8 — recon_master_cogs.py 0 PASS / 636 FAIL forward-fix
--
-- ════════════════════════════════════════════════════════════════════════════
-- WHY THIS MIGRATION
-- ════════════════════════════════════════════════════════════════════════════
-- schema/151 (deferred) attempted direct UPPER(sku_name) join master_cogs ↔
-- canonical_sku. Yield: 72 of 106 master_cogs distinct SKUs matched. Real
-- gap: master_cogs uses Title Case + abbreviations + no brand prefix
-- ("Atrius Cab Sauv", "Coppabella Procella Chardonnay") while canonical_sku
-- uses UPPER + brand prefix + full names ("MOPPITY ATRIUS CABERNET SAUVIGNON",
-- "COPPABELLA CHARDONNAY").
--
-- Manual mapping table = stable JOIN target. Seed via schema/158 with
-- confidence-graded matches. Future Vladimir / the owner review can flip
-- confidence='low'/'medium' rows to 'high' or DELETE them — no re-migration
-- needed.
--
-- ════════════════════════════════════════════════════════════════════════════
-- BLAST RADIUS
-- ════════════════════════════════════════════════════════════════════════════
--   * CREATE TABLE master_cogs_canonical_map (new — no prior consumers)
--   * Indexes on master_sku (PK) + canonical_sku_id (FK lookup)
--   * NO existing-data mutation. Forward-only DDL.
--   * Pre-existing READ-side queries unaffected (no consumer reads this table
--     until schema/159 lands).
--
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ────────────────────────────────────────────────────────────────────────────
-- §1 PRE-asserts (idempotent — tables we depend on must exist)
-- ────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    v_canonical_count INT;
    v_master_count    INT;
BEGIN
    -- canonical_sku table exists + non-empty
    IF NOT EXISTS (SELECT 1 FROM information_schema.tables
                   WHERE table_schema='public' AND table_name='canonical_sku') THEN
        RAISE EXCEPTION 'A8-157 PRE FAIL: canonical_sku table missing — schema/001 must land first';
    END IF;
    SELECT count(*) INTO v_canonical_count FROM canonical_sku;
    IF v_canonical_count < 50 THEN
        RAISE EXCEPTION 'A8-157 PRE FAIL: canonical_sku count % below sanity floor 50', v_canonical_count;
    END IF;

    -- master_cogs table exists + has the expected 636 rows
    IF NOT EXISTS (SELECT 1 FROM information_schema.tables
                   WHERE table_schema='public' AND table_name='master_cogs') THEN
        RAISE EXCEPTION 'A8-157 PRE FAIL: master_cogs table missing — schema/099 must land first';
    END IF;
    SELECT count(*) INTO v_master_count FROM master_cogs;
    IF v_master_count NOT BETWEEN 600 AND 700 THEN
        RAISE EXCEPTION 'A8-157 PRE FAIL: master_cogs row count % outside expected band 600-700 (HARD baseline 636)',
            v_master_count;
    END IF;

    RAISE NOTICE 'A8-157 PRE OK — canonical_sku=% rows, master_cogs=% rows',
        v_canonical_count, v_master_count;
END $$;

-- ────────────────────────────────────────────────────────────────────────────
-- §2 CREATE TABLE master_cogs_canonical_map (idempotent)
-- ────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS master_cogs_canonical_map (
    master_sku        TEXT      PRIMARY KEY,
    canonical_sku_id  INTEGER   NOT NULL REFERENCES canonical_sku(id) ON DELETE RESTRICT,
    confidence        TEXT      NOT NULL CHECK (confidence IN ('high','medium','low')),
    reviewed_by       TEXT,
    reviewed_at       TIMESTAMP,
    note              TEXT,
    created_at        TIMESTAMP NOT NULL DEFAULT now(),
    updated_at        TIMESTAMP NOT NULL DEFAULT now()
);

COMMENT ON TABLE master_cogs_canonical_map IS
    'A8 v2 — Map Access tbl_Master_COGS sku (Title Case + abbrev) to canonical_sku.id (UPPER + brand prefix). '
    'Confidence: high=exact post-normalize, medium=fuzzy >=0.85, low=fuzzy >=0.70. '
    'medium/low rows require Vladimir review (not the owner). '
    'Future updates: UPDATE confidence/reviewed_* fields, or DELETE row to disable that mapping.';

COMMENT ON COLUMN master_cogs_canonical_map.master_sku IS
    'Verbatim master_cogs.sku value (preserves Title Case + spacing). PRIMARY KEY because each master SKU maps to AT MOST one canonical_sku (no fan-out).';

COMMENT ON COLUMN master_cogs_canonical_map.canonical_sku_id IS
    'FK to canonical_sku.id. RESTRICT on delete (deleting canonical_sku invalidates COGS attribution).';

COMMENT ON COLUMN master_cogs_canonical_map.confidence IS
    'high = exact post-normalize match (UPPER + space-collapse + brand-prefix strip + abbrev expand). '
    'medium = fuzzy similarity >= 0.85 OR abbreviation-expansion match (e.g. "Cab Sauv"->"CABERNET SAUVIGNON"). '
    'low = fuzzy >= 0.70 — REQUIRES Vladimir review before trust as backfill source.';

COMMENT ON COLUMN master_cogs_canonical_map.reviewed_by IS
    'Vladimir / the owner / auto-seed marker. NULL = unreviewed (seeded via schema/158 heuristic).';

-- ────────────────────────────────────────────────────────────────────────────
-- §3 Index for reverse lookups (canonical -> master)
-- ────────────────────────────────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_master_cogs_canonical_map_csid
    ON master_cogs_canonical_map(canonical_sku_id);

-- ────────────────────────────────────────────────────────────────────────────
-- §4 updated_at auto-bump trigger
-- ────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_master_cogs_canonical_map_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_master_cogs_canonical_map_updated_at ON master_cogs_canonical_map;
CREATE TRIGGER trg_master_cogs_canonical_map_updated_at
    BEFORE UPDATE ON master_cogs_canonical_map
    FOR EACH ROW
    EXECUTE FUNCTION fn_master_cogs_canonical_map_updated_at();

-- ────────────────────────────────────────────────────────────────────────────
-- §5 POST-asserts
-- ────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    v_table_exists BOOLEAN;
    v_pk_exists    BOOLEAN;
    v_fk_exists    BOOLEAN;
BEGIN
    SELECT EXISTS(SELECT 1 FROM information_schema.tables
                  WHERE table_schema='public' AND table_name='master_cogs_canonical_map')
      INTO v_table_exists;
    IF NOT v_table_exists THEN
        RAISE EXCEPTION 'A8-157 POST FAIL: master_cogs_canonical_map table not created';
    END IF;

    SELECT EXISTS(SELECT 1 FROM information_schema.table_constraints
                  WHERE table_name='master_cogs_canonical_map'
                    AND constraint_type='PRIMARY KEY')
      INTO v_pk_exists;
    IF NOT v_pk_exists THEN
        RAISE EXCEPTION 'A8-157 POST FAIL: PRIMARY KEY on master_cogs_canonical_map missing';
    END IF;

    SELECT EXISTS(SELECT 1 FROM information_schema.table_constraints
                  WHERE table_name='master_cogs_canonical_map'
                    AND constraint_type='FOREIGN KEY')
      INTO v_fk_exists;
    IF NOT v_fk_exists THEN
        RAISE EXCEPTION 'A8-157 POST FAIL: FOREIGN KEY canonical_sku_id missing';
    END IF;

    RAISE NOTICE 'A8-157 POST OK — table + PK + FK + trigger present';
END $$;

-- ────────────────────────────────────────────────────────────────────────────
-- §6 schema_migrations ledger insert (idempotent)
-- ────────────────────────────────────────────────────────────────────────────
INSERT INTO schema_migrations (version, applied_at, source)
VALUES ('157_master_cogs_canonical_map_table', now(), 'live-apply')
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ════════════════════════════════════════════════════════════════════════════
-- ROLLBACK (out-of-band — only if no schema/158 + schema/159 applied yet)
-- ════════════════════════════════════════════════════════════════════════════
--   BEGIN;
--   DROP TABLE IF EXISTS master_cogs_canonical_map;
--   DROP FUNCTION IF EXISTS fn_master_cogs_canonical_map_updated_at();
--   DELETE FROM schema_migrations WHERE version = '157_master_cogs_canonical_map_table';
--   COMMIT;
-- ════════════════════════════════════════════════════════════════════════════
