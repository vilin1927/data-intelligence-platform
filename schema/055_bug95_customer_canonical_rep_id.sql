-- ════════════════════════════════════════════════════════════════════════════
-- schema/055_bug95_customer_canonical_rep_id.sql
-- BUG-95 — customer.canonical_rep_id FK to canonical_representative
-- ════════════════════════════════════════════════════════════════════════════
-- Date: 2026-04-23
--
-- FORWARD-ONLY & ADDITIVE: ALTER TABLE ADD COLUMN only; no existing column
-- altered or dropped. Column is nullable on add (required for backfill UPDATE
-- in step 17 via etl/backfill_customer_canonical_rep.py). Rollback = DROP
-- COLUMN (safe because no reads depend on it yet; dashboard code unaware).
--
-- BLAST RADIUS: adds one nullable FK column to `customer` (10,973 rows). No
-- writes. No reads change. No existing query references canonical_rep_id.
-- PostgreSQL ALTER TABLE ADD COLUMN with no default is O(1) metadata-only.
--
-- WHY NEW COLUMN vs REUSE customer.rep_id: customer.rep_id → representative
-- (132 rows, includes Vinsight synth + historical deprecated). canonical_rep_id
-- → canonical_representative (74 Owner-master rows only). Keeping both
-- preserves historical FK integrity while exposing the owner's canonical view.
--
-- EXPECTED POST-STATE (after this migration, before step 17 backfill):
--   customer row count = 10,973 (unchanged)
--   customer column count = current + 1 (canonical_rep_id added)
--   canonical_rep_id IS NOT NULL count = 0 (populate in step 17)
--   FK target: canonical_representative(id) — 74 rows confirmed pre-apply.
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ────────────────────────────────────────────────────────────────────────────
-- 1. Pre-apply assertions
-- ────────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
    -- customer table must exist with expected row count
    IF to_regclass('public.customer') IS NULL THEN
        RAISE EXCEPTION 'customer table missing; abort';
    END IF;
    IF (SELECT count(*) FROM customer) <> 10973 THEN
        RAISE EXCEPTION
          'customer row count % (expected 10973); state drift — verify before migrating',
          (SELECT count(*) FROM customer);
    END IF;

    -- canonical_representative must exist with expected row count (FK target)
    IF to_regclass('public.canonical_representative') IS NULL THEN
        RAISE EXCEPTION
          'canonical_representative missing; Phase G step 12 (schema/053) must land first';
    END IF;
    IF (SELECT count(*) FROM canonical_representative) <> 74 THEN
        RAISE EXCEPTION
          'canonical_representative row count % (expected 74); FK target drift',
          (SELECT count(*) FROM canonical_representative);
    END IF;

    -- Guard: column must not already exist (idempotency would hide drift)
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='public'
          AND table_name='customer'
          AND column_name='canonical_rep_id'
    ) THEN
        RAISE EXCEPTION
          'customer.canonical_rep_id already exists; aborting to surface re-run state';
    END IF;
END $$;

-- ────────────────────────────────────────────────────────────────────────────
-- 2. ALTER TABLE ADD COLUMN
-- ────────────────────────────────────────────────────────────────────────────
ALTER TABLE customer
  ADD COLUMN canonical_rep_id INTEGER
  REFERENCES canonical_representative(id);

CREATE INDEX idx_customer_canonical_rep_id
  ON customer (canonical_rep_id)
  WHERE canonical_rep_id IS NOT NULL;

COMMENT ON COLUMN customer.canonical_rep_id IS
  'BUG-95 (2026-04-23): FK to canonical_representative(id), Owner-master view of the sales rep assigned to this customer. Distinct from customer.rep_id which references representative (includes Vinsight synth + historical deprecated reps). NULL when (a) customer.rep_id is NULL (2,191 rows pre-backfill), (b) customer.rep_id references a representative row whose rep_name has no canonical_representative match (635 rows pre-backfill: 608 Vinsight synth + 27 historical deprecated/sentinel — see internal notes). Populated by etl/backfill_customer_canonical_rep.py (UPPER/TRIM name-match via customer.rep_id → representative.rep_name → canonical_representative.rep_name).';

-- ────────────────────────────────────────────────────────────────────────────
-- 3. Post-create assertions
-- ────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    fk_count INTEGER;
    idx_count INTEGER;
    non_null_count INTEGER;
BEGIN
    -- Column presence + nullability
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='public'
          AND table_name='customer'
          AND column_name='canonical_rep_id'
          AND data_type='integer'
          AND is_nullable='YES'
    ) THEN
        RAISE EXCEPTION 'customer.canonical_rep_id not present or wrong type/nullability';
    END IF;

    -- FK constraint presence
    SELECT count(*) INTO fk_count
    FROM information_schema.table_constraints tc
    JOIN information_schema.constraint_column_usage ccu
      ON tc.constraint_name = ccu.constraint_name
    WHERE tc.table_name = 'customer'
      AND tc.constraint_type = 'FOREIGN KEY'
      AND ccu.table_name = 'canonical_representative'
      AND ccu.column_name = 'id';
    IF fk_count < 1 THEN
        RAISE EXCEPTION 'FK customer.canonical_rep_id → canonical_representative(id) missing';
    END IF;

    -- Index presence
    SELECT count(*) INTO idx_count
    FROM pg_indexes
    WHERE schemaname = 'public'
      AND tablename = 'customer'
      AND indexname = 'idx_customer_canonical_rep_id';
    IF idx_count <> 1 THEN
        RAISE EXCEPTION 'idx_customer_canonical_rep_id missing (found % indexes with that name)', idx_count;
    END IF;

    -- Pre-backfill: 0 non-NULL values
    SELECT count(*) INTO non_null_count FROM customer WHERE canonical_rep_id IS NOT NULL;
    IF non_null_count <> 0 THEN
        RAISE EXCEPTION
          'customer.canonical_rep_id has % non-NULL rows pre-backfill (expected 0)',
          non_null_count;
    END IF;

    RAISE NOTICE 'schema/055 OK: customer.canonical_rep_id added (nullable INT FK → canonical_representative(id)), partial index created, 0 non-NULL values — ready for step 17 backfill';
END $$;

COMMIT;

-- ════════════════════════════════════════════════════════════════════════════
-- Rollback recipe (if needed BEFORE step 17 populates rows):
--   BEGIN;
--     DROP INDEX IF EXISTS idx_customer_canonical_rep_id;
--     ALTER TABLE customer DROP COLUMN IF EXISTS canonical_rep_id;
--   COMMIT;
-- After step 17 population, rollback via:
--   ssh root@your-server-ip "sudo -u postgres pg_restore -d moppity_db --clean \
--     --if-exists /var/backups/moppity/full_pre_phase_h_2026-04-23.pgdump"
--   (or targeted: UPDATE customer SET canonical_rep_id = NULL;
--                 DROP INDEX + DROP COLUMN as above.)
-- ════════════════════════════════════════════════════════════════════════════
