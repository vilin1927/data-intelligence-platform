-- ════════════════════════════════════════════════════════════════════════════
-- schema/053_bug100_canonical_representative.sql
-- BUG-100 / BUG-108 AC3 / BUG-124 AC3 — canonical_representative master table
-- ════════════════════════════════════════════════════════════════════════════
-- Date: 2026-04-25
-- Plan self-ruling: Part III — BUG-108 AC3 uses HARD source
-- Option selected: **Option C (union 74 rows with per-source flags)** per
--   directive 2026-04-25 "1".
--
-- FORWARD-ONLY & ADDITIVE: CREATE TABLE for a new table; no existing table
-- altered. Zero downstream FK refs at creation (population in step 13 via
-- etl/import_canonical_representative.py). Rollback recipe = DROP TABLE.
--
-- BLAST RADIUS: new table only. Existing `representative` table (132 rows)
-- untouched. No reads changed. Dashboard code unaware of this table.
--
-- EXPECTED POST-STATE (after this migration applies, before step 13 runs):
--   canonical_representative row count = 0
--   canonical_representative column count = 9 (id, rep_name, full_rep_display,
--     short_rep, territory_id, is_active_dws, is_active_allchannel,
--     created_at, updated_at)
--   FK target: canonical_territory(id) — 30 rows confirmed pre-apply.
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ────────────────────────────────────────────────────────────────────────────
-- 1. Pre-apply assertions
-- ────────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
    IF to_regclass('public.canonical_representative') IS NOT NULL THEN
        RAISE EXCEPTION
          'canonical_representative already exists; aborting to avoid accidental overwrite';
    END IF;
    IF (SELECT count(*) FROM canonical_territory) <> 30 THEN
        RAISE EXCEPTION
          'canonical_territory row count % unexpected (expected 30); FK target drift',
          (SELECT count(*) FROM canonical_territory);
    END IF;
END $$;

-- ────────────────────────────────────────────────────────────────────────────
-- 2. CREATE TABLE canonical_representative
-- ────────────────────────────────────────────────────────────────────────────
CREATE TABLE canonical_representative (
    id                      SERIAL       PRIMARY KEY,
    rep_name                VARCHAR(255) NOT NULL UNIQUE,
    full_rep_display        VARCHAR(255),
    short_rep               VARCHAR(64),
    territory_id            INTEGER REFERENCES canonical_territory(id),
    is_active_dws           BOOLEAN      NOT NULL DEFAULT FALSE,
    is_active_allchannel    BOOLEAN      NOT NULL DEFAULT FALSE,
    created_at              TIMESTAMP    NOT NULL DEFAULT now(),
    updated_at              TIMESTAMP    NOT NULL DEFAULT now(),
    CONSTRAINT canonical_representative_at_least_one_channel_chk
        CHECK (is_active_dws OR is_active_allchannel)
);

CREATE INDEX idx_canonical_representative_territory
    ON canonical_representative (territory_id)
    WHERE territory_id IS NOT NULL;

COMMENT ON TABLE canonical_representative IS
  'BUG-100 (2026-04-25): canonical master for sales reps, union of Jan 2026 accdb Representative (30 DWS) and Customers.Rep UPPER-distinct (72 all-channel). 28 overlap → 74 unique rows. Per-source flags is_active_dws / is_active_allchannel indicate which source(s) confirmed the rep. Populated via etl/import_canonical_representative.py. Owner-facing master — dashboard reads TBD in Phase H.';

COMMENT ON COLUMN canonical_representative.rep_name IS
  'UPPER-normalized unique rep name (e.g. REP E). Matches Customers.Rep case-collapse convention.';

COMMENT ON COLUMN canonical_representative.full_rep_display IS
  'Human-readable display form (e.g. Rep E). Prefer Representative.FullRep when available; title-case fallback otherwise.';

COMMENT ON COLUMN canonical_representative.short_rep IS
  'DWS ShortRep code (e.g. ANEWT) from accdb Representative table. NULL for non-DWS reps.';

COMMENT ON COLUMN canonical_representative.territory_id IS
  'FK to canonical_territory(id). NULL allowed: (a) pseudo-reps like CHARGE THROUGH, (b) data-drift territories like QLD CBD, (c) new hires not yet in the owner territory master. 4 such rows expected at initial population per internal notes.';

COMMENT ON COLUMN canonical_representative.is_active_dws IS
  'TRUE if this rep appears in accdb Representative table (TerritoryGroup=DWS). 30 such rows.';

COMMENT ON COLUMN canonical_representative.is_active_allchannel IS
  'TRUE if this rep appears in accdb Customers.Rep UPPER-distinct. 72 such rows.';

-- ────────────────────────────────────────────────────────────────────────────
-- 3. Post-create assertions
-- ────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    col_count INTEGER;
    row_count INTEGER;
BEGIN
    IF to_regclass('public.canonical_representative') IS NULL THEN
        RAISE EXCEPTION 'canonical_representative not created';
    END IF;

    SELECT count(*) INTO col_count
    FROM information_schema.columns
    WHERE table_name = 'canonical_representative' AND table_schema = 'public';
    IF col_count <> 9 THEN
        RAISE EXCEPTION 'canonical_representative has % columns (expected 9)', col_count;
    END IF;

    SELECT count(*) INTO row_count FROM canonical_representative;
    IF row_count <> 0 THEN
        RAISE EXCEPTION 'canonical_representative has % rows (expected 0; populate in step 13)', row_count;
    END IF;

    RAISE NOTICE 'schema/053 OK: canonical_representative created, 9 columns, 0 rows, FK → canonical_territory(id)';
END $$;

COMMIT;

-- ════════════════════════════════════════════════════════════════════════════
-- Rollback recipe (if needed BEFORE step 13 populates rows):
--   BEGIN;
--     DROP INDEX IF EXISTS idx_canonical_representative_territory;
--     DROP TABLE IF EXISTS canonical_representative;
--   COMMIT;
-- After step 13 population, rollback via:
--   ssh root@your-server-ip "sudo -u postgres pg_restore -d moppity_db --clean --if-exists \
--     /var/backups/moppity/full_pre_phase_g_2026-04-25.pgdump"
--   (or targeted: TRUNCATE canonical_representative; DROP TABLE canonical_representative;)
-- ════════════════════════════════════════════════════════════════════════════
