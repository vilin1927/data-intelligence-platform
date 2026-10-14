-- ════════════════════════════════════════════════════════════════════════════
-- schema/087_rep_territory_xref.sql
-- B5 / JC-058, JC-070
-- N:M junction between canonical_representative and canonical_territory.
-- ════════════════════════════════════════════════════════════════════════════
-- Date: 2026-04-27
-- Bundle: B5 (Reps + Territories)
-- Source for "reps cross multiple territories": extract-call-mar9-0023 (the owner
--   call Mar 9, JR-024 ledger). Today canonical_representative.territory_id is
--   1:1 (a rep has ONE primary territory). Real-world: reps cross suburbs in
--   multiple territories; the xref captures that secondary coverage.
--
-- FORWARD-ONLY: pure CREATE TABLE IF NOT EXISTS.
-- Population: etl/refresh_reps_from_access.py inserts ONE row per
-- canonical_representative.territory_id (primary=true), then
-- etl/import_territory_overrides.py adds secondary coverage rows derived
-- from territory_override + canonical_customer joins.
--
-- BLAST RADIUS: NEW table; zero downstream FK refs at creation. Phase-2 reads.
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ────────────────────────────────────────────────────────────────────────────
-- 1. Pre-apply assertions
-- ────────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
    IF to_regclass('public.canonical_representative') IS NULL THEN
        RAISE EXCEPTION 'canonical_representative missing; run schema/053 first';
    END IF;
    IF to_regclass('public.canonical_territory') IS NULL THEN
        RAISE EXCEPTION 'canonical_territory missing; run schema/043 first';
    END IF;
END $$;

-- ────────────────────────────────────────────────────────────────────────────
-- 2. CREATE TABLE rep_territory_xref
-- ────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS rep_territory_xref (
    rep_id          INTEGER     NOT NULL REFERENCES canonical_representative(id) ON DELETE CASCADE,
    territory_id    INTEGER     NOT NULL REFERENCES canonical_territory(id)      ON DELETE CASCADE,
    is_primary      BOOLEAN     NOT NULL DEFAULT FALSE,
    source          VARCHAR(64) NOT NULL,        -- 'representative_table' | 'territory_override' | 'customer_observed' | 'manual'
    created_at      TIMESTAMP   NOT NULL DEFAULT now(),
    PRIMARY KEY (rep_id, territory_id)
);

CREATE INDEX IF NOT EXISTS idx_rep_territory_xref_territory
    ON rep_territory_xref (territory_id);

CREATE INDEX IF NOT EXISTS idx_rep_territory_xref_rep_primary
    ON rep_territory_xref (rep_id) WHERE is_primary = TRUE;

-- One primary territory per rep at most (partial unique index).
CREATE UNIQUE INDEX IF NOT EXISTS uq_rep_territory_xref_one_primary_per_rep
    ON rep_territory_xref (rep_id) WHERE is_primary = TRUE;

COMMENT ON TABLE rep_territory_xref IS
  'B5 (2026-04-27): N:M junction. Captures that a rep covers multiple territories (per the owner Mar 9 call: "rep:territory is N:M, NOT 1:1"). Primary territory continues to live on canonical_representative.territory_id; secondary coverage rows have is_primary=false. Population: etl/refresh_reps_from_access.py + etl/import_territory_overrides.py.';

COMMENT ON COLUMN rep_territory_xref.source IS
  'Provenance: representative_table (accdb Representative.Territory primary) | territory_override (derived from tblNewTerritory.Rep) | customer_observed (canonical_customer.rep_name × territory_name) | manual.';

-- ────────────────────────────────────────────────────────────────────────────
-- 3. Post-create assertions
-- ────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    col_count INTEGER;
BEGIN
    SELECT count(*) INTO col_count
    FROM information_schema.columns
    WHERE table_name = 'rep_territory_xref' AND table_schema = 'public';
    IF col_count <> 5 THEN
        RAISE EXCEPTION 'rep_territory_xref has % columns (expected 5)', col_count;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE tablename = 'rep_territory_xref'
          AND indexname = 'uq_rep_territory_xref_one_primary_per_rep'
    ) THEN
        RAISE EXCEPTION 'one-primary-per-rep partial unique index missing';
    END IF;

    RAISE NOTICE 'schema/087 OK: rep_territory_xref created';
END $$;

INSERT INTO schema_migrations (version, source)
VALUES ('087_rep_territory_xref', 'live-apply')
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ════════════════════════════════════════════════════════════════════════════
-- Rollback recipe:
--   BEGIN;
--     DROP TABLE IF EXISTS rep_territory_xref;
--     DELETE FROM schema_migrations WHERE version = '087_rep_territory_xref';
--   COMMIT;
-- ════════════════════════════════════════════════════════════════════════════
