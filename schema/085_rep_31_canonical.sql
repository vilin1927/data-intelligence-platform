-- ════════════════════════════════════════════════════════════════════════════
-- schema/085_rep_31_canonical.sql
-- B5 / JC-054, JC-055, JC-056, JC-057, JC-066, JC-048, JC-049
-- Extend canonical_representative to 26 Access verbatim cols, swap UNIQUE
-- key from rep_name → (short_rep, full_rep_display), enforce 31-row cap.
-- ════════════════════════════════════════════════════════════════════════════
-- Date: 2026-04-27
-- Bundle: B5 (Reps + Territories)
--   (31 unique ShortReps; B2 imported 30 because of FullRep dedup that
--    dropped SNEWB / Rep C / Queensland Metro vs SNEWBE / QLD CBD).
--
--   - ALL ALTER TABLE statements use ADD COLUMN IF NOT EXISTS.
--   - The UNIQUE constraint swap (DROP + ADD) is reversible inside one
--     transaction; rollback recipe at bottom of file.
--   - Existing rows are NOT touched (population happens in
--     etl/refresh_reps_from_access.py with --commit).
--
-- BLAST RADIUS: canonical_representative reads in dashboard/api/reps + a
-- handful of ETL backfills. New cols are nullable so existing reads keep
-- working unchanged.
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ────────────────────────────────────────────────────────────────────────────
-- 1. Pre-apply assertions
-- ────────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
    IF to_regclass('public.canonical_representative') IS NULL THEN
        RAISE EXCEPTION
          'canonical_representative does not exist; run schema/053 first';
    END IF;
    IF to_regclass('public.canonical_territory') IS NULL THEN
        RAISE EXCEPTION
          'canonical_territory does not exist; run schema/043 first';
    END IF;
    IF (SELECT count(*) FROM canonical_territory) <> 30 THEN
        RAISE EXCEPTION
          'canonical_territory row count % unexpected (expected 30)',
          (SELECT count(*) FROM canonical_territory);
    END IF;
END $$;

-- ────────────────────────────────────────────────────────────────────────────
-- 2. Add 23 Access verbatim columns (idempotent ADD COLUMN IF NOT EXISTS)
-- ────────────────────────────────────────────────────────────────────────────
-- TerritoryGroup (JC-066: 10 canonical values; CHECK constraint added in §3)
ALTER TABLE canonical_representative ADD COLUMN IF NOT EXISTS territory_group VARCHAR(64);

-- Free-text representative bio
ALTER TABLE canonical_representative ADD COLUMN IF NOT EXISTS representative_details TEXT;

-- Per-rep performance metrics (JC-057 MAT pattern; all numeric, nullable)
ALTER TABLE canonical_representative ADD COLUMN IF NOT EXISTS members_growth         NUMERIC(14,4);
ALTER TABLE canonical_representative ADD COLUMN IF NOT EXISTS ty_distrn              NUMERIC(14,4);
ALTER TABLE canonical_representative ADD COLUMN IF NOT EXISTS range_mtd              NUMERIC(14,4);
ALTER TABLE canonical_representative ADD COLUMN IF NOT EXISTS ly_dollar              NUMERIC(14,4);
ALTER TABLE canonical_representative ADD COLUMN IF NOT EXISTS ty_dollar              NUMERIC(14,4);
ALTER TABLE canonical_representative ADD COLUMN IF NOT EXISTS y_dollar_per           NUMERIC(14,4);
ALTER TABLE canonical_representative ADD COLUMN IF NOT EXISTS ly_mtd_dollar          NUMERIC(14,4);
ALTER TABLE canonical_representative ADD COLUMN IF NOT EXISTS ty_mtd_dollar          NUMERIC(14,4);
ALTER TABLE canonical_representative ADD COLUMN IF NOT EXISTS mtd_per                NUMERIC(14,4);
ALTER TABLE canonical_representative ADD COLUMN IF NOT EXISTS ly_mqt_dollar          NUMERIC(14,4);
ALTER TABLE canonical_representative ADD COLUMN IF NOT EXISTS ty_mqt_dollar          NUMERIC(14,4);
ALTER TABLE canonical_representative ADD COLUMN IF NOT EXISTS mqt_dollar_per         NUMERIC(14,4);
ALTER TABLE canonical_representative ADD COLUMN IF NOT EXISTS ranges_per_member      NUMERIC(14,4);
ALTER TABLE canonical_representative ADD COLUMN IF NOT EXISTS distrn_per_member      NUMERIC(14,4);
ALTER TABLE canonical_representative ADD COLUMN IF NOT EXISTS sales_per_member_mat   NUMERIC(14,4);
ALTER TABLE canonical_representative ADD COLUMN IF NOT EXISTS sales_growth_per_member_mat NUMERIC(14,4);

-- 5 generic Field# cols verbatim from Access schema (free-text; future-proof)
ALTER TABLE canonical_representative ADD COLUMN IF NOT EXISTS field1 TEXT;
ALTER TABLE canonical_representative ADD COLUMN IF NOT EXISTS field2 TEXT;
ALTER TABLE canonical_representative ADD COLUMN IF NOT EXISTS field3 TEXT;
ALTER TABLE canonical_representative ADD COLUMN IF NOT EXISTS field4 TEXT;
ALTER TABLE canonical_representative ADD COLUMN IF NOT EXISTS field5 TEXT;

-- ────────────────────────────────────────────────────────────────────────────
-- 3. JC-066 / JC-048 / JC-049: TerritoryGroup CHECK constraint (10 values)
--   Adding this BEFORE the SNEWB row is inserted (ETL).
--   Includes 'Export' (JC-048) and 'Young & Rashleigh' (JC-049).
--   NULL allowed — back-compat with rows that pre-date this column.
-- ────────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'canonical_representative_territory_group_chk'
    ) THEN
        ALTER TABLE canonical_representative
            ADD CONSTRAINT canonical_representative_territory_group_chk
            CHECK (
                territory_group IS NULL
                OR territory_group IN (
                    'ACT',
                    'DWS',
                    'Export',
                    'Head Office',
                    'Icon',
                    'Majors & Wine Clubs',
                    'NSW',
                    'QLD',
                    'SA',
                    'Samples',
                    'VIC',
                    'WA',
                    'Young & Rashleigh'
                )
            );
    END IF;
END $$;

-- Same enumeration on canonical_territory.territory_group (mirror).
ALTER TABLE canonical_territory ADD COLUMN IF NOT EXISTS territory_group VARCHAR(64);

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'canonical_territory_territory_group_chk'
    ) THEN
        ALTER TABLE canonical_territory
            ADD CONSTRAINT canonical_territory_territory_group_chk
            CHECK (
                territory_group IS NULL
                OR territory_group IN (
                    'ACT',
                    'DWS',
                    'Export',
                    'Head Office',
                    'Icon',
                    'Majors & Wine Clubs',
                    'NSW',
                    'QLD',
                    'SA',
                    'Samples',
                    'VIC',
                    'WA',
                    'Young & Rashleigh'
                )
            );
    END IF;
END $$;

-- ────────────────────────────────────────────────────────────────────────────
-- 4. JC-056: Swap UNIQUE constraint from rep_name → (short_rep, full_rep_display)
--   The existing UNIQUE(rep_name) blocks adding the 31st DWS rep
--   (SNEWB / "Rep C" / Queensland Metro) because rep_name="REP C"
--   is already taken by SNEWBE / QLD CBD. The Access master keys reps on
--   ShortRep + FullRep (two-level identity, JC-056) so that's the right key.
--
--   Idempotent: skip if the new constraint already exists.
-- ────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    rep_name_unique_constraint TEXT;
BEGIN
    -- Find the auto-generated rep_name UNIQUE constraint (name varies by PG version)
    SELECT conname INTO rep_name_unique_constraint
    FROM pg_constraint
    WHERE conrelid = 'canonical_representative'::regclass
      AND contype = 'u'
      AND pg_get_constraintdef(oid) ILIKE '%rep_name%'
      AND pg_get_constraintdef(oid) NOT ILIKE '%short_rep%';

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'canonical_representative_short_rep_full_rep_key'
    ) THEN
        IF rep_name_unique_constraint IS NOT NULL THEN
            EXECUTE format(
                'ALTER TABLE canonical_representative DROP CONSTRAINT %I',
                rep_name_unique_constraint
            );
            RAISE NOTICE 'Dropped legacy rep_name UNIQUE constraint: %', rep_name_unique_constraint;
        END IF;

        -- short_rep can be NULL for non-DWS reps (Customers.Rep-only rows).
        -- Pair (NULL, full_rep_display) is treated as distinct in PG UNIQUE,
        -- but full_rep_display itself is not unique either. To avoid broken
        -- semantics, we coalesce short_rep into a synthetic disambiguator
        -- only when a short_rep is present; for NULL short_rep we fall back
        -- to UNIQUE(rep_name) behavior via a partial unique index instead.
        ALTER TABLE canonical_representative
            ADD CONSTRAINT canonical_representative_short_rep_full_rep_key
            UNIQUE (short_rep, full_rep_display);

        -- Partial unique index for non-DWS reps (short_rep IS NULL):
        -- enforce one row per rep_name in that population.
        CREATE UNIQUE INDEX IF NOT EXISTS
            canonical_representative_rep_name_no_short_rep_key
        ON canonical_representative (rep_name)
        WHERE short_rep IS NULL;

        RAISE NOTICE 'Added (short_rep, full_rep_display) UNIQUE + rep_name partial unique';
    ELSE
        RAISE NOTICE 'short_rep+full_rep UNIQUE already present — skipped';
    END IF;
END $$;

-- ────────────────────────────────────────────────────────────────────────────
-- 5. JC-054 row-cap: enforce <= 31 DWS-canonical reps via deferred trigger.
--   A CHECK constraint can't span rows; using a row-level trigger that fires
--   on INSERT/UPDATE and aborts if count(*) WHERE is_active_dws=true exceeds 31.
-- ────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION assert_canonical_representative_dws_cap()
    RETURNS TRIGGER AS $$
DECLARE
    n INTEGER;
BEGIN
    SELECT count(*) INTO n
    FROM canonical_representative
    WHERE is_active_dws = TRUE;
    IF n > 31 THEN
        RAISE EXCEPTION
          'canonical_representative is_active_dws=true count is % (cap is 31; HARD source = internal notes 31 unique ShortReps)',
          n;
    END IF;
    RETURN NULL; -- AFTER trigger
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS canonical_representative_dws_cap_trg
    ON canonical_representative;

CREATE CONSTRAINT TRIGGER canonical_representative_dws_cap_trg
    AFTER INSERT OR UPDATE OF is_active_dws
    ON canonical_representative
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW
    EXECUTE FUNCTION assert_canonical_representative_dws_cap();

-- ────────────────────────────────────────────────────────────────────────────
-- 6. Post-apply assertions
-- ────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    col_count INTEGER;
BEGIN
    SELECT count(*) INTO col_count
    FROM information_schema.columns
    WHERE table_name = 'canonical_representative' AND table_schema = 'public';
    -- Original 9 + 23 new = 32 cols
    IF col_count < 32 THEN
        RAISE EXCEPTION
          'canonical_representative has % columns (expected at least 32 after schema/085)',
          col_count;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'canonical_representative_short_rep_full_rep_key'
    ) THEN
        RAISE EXCEPTION 'short_rep+full_rep UNIQUE constraint missing';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'canonical_representative_territory_group_chk'
    ) THEN
        RAISE EXCEPTION 'territory_group CHECK constraint missing';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_trigger
        WHERE tgname = 'canonical_representative_dws_cap_trg'
    ) THEN
        RAISE EXCEPTION 'canonical_representative_dws_cap_trg missing';
    END IF;

    RAISE NOTICE 'schema/085 OK: 23 cols added, UNIQUE swapped, DWS cap trigger live';
END $$;

INSERT INTO schema_migrations (version, source)
VALUES ('085_rep_31_canonical', 'live-apply')
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ════════════════════════════════════════════════════════════════════════════
-- Rollback recipe (BEFORE any data inserts on the new cols):
--   BEGIN;
--     DROP TRIGGER IF EXISTS canonical_representative_dws_cap_trg ON canonical_representative;
--     DROP FUNCTION IF EXISTS assert_canonical_representative_dws_cap();
--     ALTER TABLE canonical_representative
--       DROP CONSTRAINT IF EXISTS canonical_representative_short_rep_full_rep_key;
--     DROP INDEX IF EXISTS canonical_representative_rep_name_no_short_rep_key;
--     ALTER TABLE canonical_representative
--       ADD CONSTRAINT canonical_representative_rep_name_key UNIQUE (rep_name);
--     ALTER TABLE canonical_representative
--       DROP CONSTRAINT IF EXISTS canonical_representative_territory_group_chk;
--     ALTER TABLE canonical_territory
--       DROP CONSTRAINT IF EXISTS canonical_territory_territory_group_chk;
--     ALTER TABLE canonical_territory DROP COLUMN IF EXISTS territory_group;
--     -- 23 col drops:
--     ALTER TABLE canonical_representative
--       DROP COLUMN IF EXISTS field5,
--       DROP COLUMN IF EXISTS field4,
--       DROP COLUMN IF EXISTS field3,
--       DROP COLUMN IF EXISTS field2,
--       DROP COLUMN IF EXISTS field1,
--       DROP COLUMN IF EXISTS sales_growth_per_member_mat,
--       DROP COLUMN IF EXISTS sales_per_member_mat,
--       DROP COLUMN IF EXISTS distrn_per_member,
--       DROP COLUMN IF EXISTS ranges_per_member,
--       DROP COLUMN IF EXISTS mqt_dollar_per,
--       DROP COLUMN IF EXISTS ty_mqt_dollar,
--       DROP COLUMN IF EXISTS ly_mqt_dollar,
--       DROP COLUMN IF EXISTS mtd_per,
--       DROP COLUMN IF EXISTS ty_mtd_dollar,
--       DROP COLUMN IF EXISTS ly_mtd_dollar,
--       DROP COLUMN IF EXISTS y_dollar_per,
--       DROP COLUMN IF EXISTS ty_dollar,
--       DROP COLUMN IF EXISTS ly_dollar,
--       DROP COLUMN IF EXISTS range_mtd,
--       DROP COLUMN IF EXISTS ty_distrn,
--       DROP COLUMN IF EXISTS members_growth,
--       DROP COLUMN IF EXISTS representative_details,
--       DROP COLUMN IF EXISTS territory_group;
--     DELETE FROM schema_migrations WHERE version = '085_rep_31_canonical';
--   COMMIT;
-- ════════════════════════════════════════════════════════════════════════════
