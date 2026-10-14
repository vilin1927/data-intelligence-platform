-- ════════════════════════════════════════════════════════════════════════════
-- schema/086_territory_overrides.sql
-- B5 / JC-067, JC-073, JC-075
-- territory_override (tblNewTerritory replicate, 2295 rows) +
-- samples_territory (tblSamplesTerritory replicate, 35 rows).
-- ════════════════════════════════════════════════════════════════════════════
-- Date: 2026-04-27
-- Bundle: B5 (Reps + Territories)
--   (2296 lines = 1 header + 2295 data rows).
--
-- FORWARD-ONLY: pure CREATE TABLE IF NOT EXISTS — no destructive ALTER.
-- Population happens via etl/import_territory_overrides.py (2295+35 INSERTs).
--
-- BLAST RADIUS: NEW tables; zero downstream FK refs at creation. ETL backfill
-- of combined_data.territory_id (AC8) is wrapped in BEGIN/COMMIT in the
-- ETL script — see import_territory_overrides.py.
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ────────────────────────────────────────────────────────────────────────────
-- 1. territory_override — replicates Access tblNewTerritory (2,295 rows)
--    Cols match Access verbatim (per extract-accdb-0037):
--    ID, CustomerName, Old Territory, Suburb, Rep, New territory, Territory Group
-- ────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS territory_override (
    id              SERIAL       PRIMARY KEY,
    access_id       INTEGER      UNIQUE,          -- original accdb ID; UNIQUE so ETL can ON CONFLICT
    customer_name   VARCHAR(255) NOT NULL,
    old_territory   VARCHAR(255),
    suburb          VARCHAR(255),
    rep             VARCHAR(255),
    new_territory   VARCHAR(255) NOT NULL,
    territory_group VARCHAR(64),
    created_at      TIMESTAMP    NOT NULL DEFAULT now(),
    updated_at      TIMESTAMP    NOT NULL DEFAULT now()
);

-- territory_group enumeration mirrors canonical_representative + canonical_territory.
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'territory_override_territory_group_chk'
    ) THEN
        ALTER TABLE territory_override
            ADD CONSTRAINT territory_override_territory_group_chk
            CHECK (
                territory_group IS NULL
                OR territory_group = ''
                OR territory_group IN (
                    'ACT',
                    'DWS',
                    'Export',
                    'Head Office',
                    'Majors & Wine Clubs',
                    'NSW',
                    'QLD',
                    'SA',
                    'VIC',
                    'WA',
                    'Young & Rashleigh'
                )
            );
    END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_territory_override_customer_name
    ON territory_override (customer_name);

CREATE INDEX IF NOT EXISTS idx_territory_override_new_territory
    ON territory_override (new_territory);

-- AC8 backfill efficiency: composite index for the join used by
-- import_territory_overrides --backfill-combined-data.
CREATE INDEX IF NOT EXISTS idx_territory_override_customer_suburb_rep
    ON territory_override (customer_name, suburb, rep);

COMMENT ON TABLE territory_override IS
  'B5 (2026-04-27): customer-level territory remap engine. Replicates Access tblNewTerritory (2,295 rows). When a customer''s raw Territory differs from their canonical assignment, this table holds the override. Used by ETL backfill to set combined_data.territory_id for Vinsight rows missing territory (JC-074/509 AC8).';

COMMENT ON COLUMN territory_override.access_id IS
  'Original accdb tblNewTerritory.ID for back-trace audits.';
COMMENT ON COLUMN territory_override.customer_name IS
  'Verbatim Access tblNewTerritory.CustomerName (NAME @ SUBURB form preserved).';
COMMENT ON COLUMN territory_override.new_territory IS
  'Target territory name. Should match canonical_territory.territory_name (30 values).';

-- ────────────────────────────────────────────────────────────────────────────
-- 2. samples_territory — replicates Access tblSamplesTerritory (35 rows)
--    Cols (per extract-accdb-0057): RepCustomerName, SampleTerritory, TerritoryGroup
-- ────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS samples_territory (
    id                  SERIAL       PRIMARY KEY,
    rep_customer_name   VARCHAR(255) NOT NULL,
    sample_territory    VARCHAR(255) NOT NULL,
    territory_group     VARCHAR(64),
    created_at          TIMESTAMP    NOT NULL DEFAULT now(),
    CONSTRAINT samples_territory_rep_customer_unique UNIQUE (rep_customer_name)
);

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'samples_territory_territory_group_chk'
    ) THEN
        ALTER TABLE samples_territory
            ADD CONSTRAINT samples_territory_territory_group_chk
            CHECK (
                territory_group IS NULL
                OR territory_group IN (
                    'ACT',
                    'DWS',
                    'Export',
                    'Head Office',
                    'Majors & Wine Clubs',
                    'NSW',
                    'QLD',
                    'SA',
                    'VIC',
                    'Victoria Off',  -- present in source (extract-accdb tblSamplesTerritory)
                    'WA',
                    'Young & Rashleigh'
                )
            );
    END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_samples_territory_rep_customer
    ON samples_territory (rep_customer_name);

COMMENT ON TABLE samples_territory IS
  'B5 (2026-04-27): replicates Access tblSamplesTerritory (35 rows). Maps "rep @ customer" pairs to a sample-tracking territory. Used for sample distribution reports (JC-075).';

-- ────────────────────────────────────────────────────────────────────────────
-- 3. Post-create assertions
-- ────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    col_count INTEGER;
BEGIN
    SELECT count(*) INTO col_count
    FROM information_schema.columns
    WHERE table_name = 'territory_override' AND table_schema = 'public';
    -- 10 cols: id, access_id, customer_name, old_territory, suburb, rep,
    --         new_territory, territory_group, created_at, updated_at
    IF col_count <> 10 THEN
        RAISE EXCEPTION 'territory_override has % columns (expected 10)', col_count;
    END IF;

    SELECT count(*) INTO col_count
    FROM information_schema.columns
    WHERE table_name = 'samples_territory' AND table_schema = 'public';
    IF col_count <> 5 THEN
        RAISE EXCEPTION 'samples_territory has % columns (expected 5)', col_count;
    END IF;

    RAISE NOTICE 'schema/086 OK: territory_override + samples_territory created';
END $$;

INSERT INTO schema_migrations (version, source)
VALUES ('086_territory_overrides', 'live-apply')
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ════════════════════════════════════════════════════════════════════════════
-- Rollback recipe:
--   BEGIN;
--     DROP TABLE IF EXISTS samples_territory;
--     DROP TABLE IF EXISTS territory_override;
--     DELETE FROM schema_migrations WHERE version = '086_territory_overrides';
--   COMMIT;
-- ════════════════════════════════════════════════════════════════════════════
