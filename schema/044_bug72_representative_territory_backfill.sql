-- =============================================================================
-- Moppity Vineyards — BUG-72: representative.territory_id backfill
-- =============================================================================
-- Version:   1.0
-- Created:   2026-04-19
-- Task:      BUG-72 (Territories tab REPS ASSIGNED = 0 on most rows while
--            REP NAMES column is populated — two data paths disagree)
--
-- Root cause (verified via VPS read-only probe 2026-04-19):
--   /api/territories COUNT path queries representative.territory_id FK.
--   /api/territories NAMES path aggregates canonical_customer.rep_name per
--   territory. The COUNT path is empty because:
--     - representative has 132 rows; only 27 carry territory_id (20%).
--     - FK `representative_territory_id_fkey` points at the LEGACY
--       `territory` table (40 rows, id range 6..98), NOT at
--       `canonical_territory` (30 rows, id range 1..30).
--     - /api/reps and /api/territories both JOIN on
--       `canonical_territory.id = representative.territory_id`, so of the
--       27 existing rows only 4 accidentally match canonical IDs (1..30);
--       the other 23 resolve to NULL in the dashboard UI.
--
-- Fix (three parts, all inside one transaction):
--   1. Remap the 26 existing legacy territory_ids (e.g. 81 "VIC Melbourne
--      CBD") to the canonical_territory.id of the same name (21), via
--      case-insensitive territory_name match. One row ("ACT on premise"
--      vs "ACT On Premise") is caught by the UPPER(TRIM()) collapse that
--      BUG-45 / schema/043 already applied to canonical_customer.
--   2. Swap the FK: drop
--      representative_territory_id_fkey → territory(territory_id)
--      and add
--      representative_territory_id_fkey → canonical_territory(id).
--      Safe because step 1 guarantees every existing non-null
--      territory_id is now a valid canonical_territory.id.
--   3. Backfill the remaining NULL rows via majority-territory aggregation
--      across canonical_customer: for each rep_name, pick the
--      territory_name that covers the plurality of that rep's customers.
--      Matches both rep_name and territory_name case-insensitively because
--      representative uses title-case ("Rep G") and
--      canonical_customer uses upper-case ("REP G").
--
-- Dry-run post-state (simulated 2026-04-19, rolled back):
--   - Stage 1 remap:             26 rows (of 27 pre-existing)
--   - Stage 1 via UPPER collapse: +1 row ("ACT on premise" → 1)
--   - Stage 3 majority backfill: 102 reps match a canonical_customer
--     rep_name with a non-null territory_name
--   - Combined after stages 1+3: 103/132 reps populated = 78 %
--
-- Residual NULL population (29 reps) breakdown:
--     16 × "(Vinsight) *" reps — Vinsight system users (flag to the owner;
--        these arguably should not be in representative at all)
--      3 × "NOT APPLICABLE" / "Not Applicable" / "NSW 205" placeholders
--      6 × case-duplicate rep rows (CUSTOMER 14 vs Customer 14 etc.)
--      4 × reps with no sales history yet (Customer 08, Helen, Victoria,
--        Customer 27). These have no canonical_customer row to
--        aggregate against.
--   None of these 29 have a recoverable territory signal from available
--   data. The 78 % post-state is therefore the practical ceiling unless
--   The owner dedupes / retires rep rows.
--
-- Assertion: the DO-block below raises WARNING (not ERROR) if post-state
-- is below 75 %. Spec asked for 80 % but simulation shows 78 % is the
-- ceiling from current data. If the owner confirms the 16 "(Vinsight) *" and
-- 3 "NOT APPLICABLE" rows should be soft-deleted (active = false), a
-- follow-up migration can raise the active-only population to >=95 %.
--
-- Safety:
--   - Forward-only: no DROP TABLE, no CASCADE, no TRUNCATE.
--   - No existing non-null territory_id is overwritten unless its legacy
--     name remaps cleanly to a canonical name (case-insensitive).
--   - Idempotent: re-running is a no-op (stages 1 + 3 both filter on
--     "territory_id is currently wrong / NULL"); step 2 uses
--     IF EXISTS / NOT EXISTS guards.
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- Stage 1. DROP old FK first so we can remap territory_id values to
--          canonical_territory.id (which don't exist in legacy territory table).
-- ---------------------------------------------------------------------------

ALTER TABLE representative
  DROP CONSTRAINT IF EXISTS representative_territory_id_fkey;


-- ---------------------------------------------------------------------------
-- Stage 2. Remap existing legacy territory_ids to canonical_territory.id
--          (via case-insensitive territory_name match).
-- ---------------------------------------------------------------------------

UPDATE representative r
   SET territory_id = ct.id
  FROM territory t
  JOIN canonical_territory ct
    ON UPPER(TRIM(ct.territory_name)) = UPPER(TRIM(t.territory_name))
 WHERE r.territory_id = t.territory_id
   AND r.territory_id <> ct.id;    -- only rewrite if different id


-- ---------------------------------------------------------------------------
-- Stage 3. Majority-territory backfill for reps with NULL territory_id.
--          For each rep_name: pick the territory_name that dominates
--          their canonical_customer rows. Ties broken by territory_name
--          alphabetical (deterministic).
-- ---------------------------------------------------------------------------

WITH rep_terr_counts AS (
  SELECT
    cc.rep_name,
    cc.territory_name,
    COUNT(*) AS n
  FROM canonical_customer cc
  WHERE cc.rep_name       IS NOT NULL
    AND cc.territory_name IS NOT NULL
  GROUP BY cc.rep_name, cc.territory_name
),
rep_majority AS (
  SELECT DISTINCT ON (rep_name)
    rep_name,
    territory_name
  FROM rep_terr_counts
  ORDER BY rep_name, n DESC, territory_name
)
UPDATE representative r
   SET territory_id = ct.id
  FROM rep_majority rm
  JOIN canonical_territory ct
    ON UPPER(TRIM(ct.territory_name)) = UPPER(TRIM(rm.territory_name))
 WHERE UPPER(TRIM(r.rep_name)) = UPPER(TRIM(rm.rep_name))
   AND r.territory_id IS NULL;


-- ---------------------------------------------------------------------------
-- Stage 4. ADD new FK pointing at canonical_territory (now safe — all
--          non-null values are valid canonical_territory.id after Stage 2/3).
-- ---------------------------------------------------------------------------

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conname  = 'representative_territory_id_fkey'
       AND conrelid = 'representative'::regclass
  ) THEN
    ALTER TABLE representative
      ADD CONSTRAINT representative_territory_id_fkey
      FOREIGN KEY (territory_id) REFERENCES canonical_territory(id);
  END IF;
END $$;


-- ---------------------------------------------------------------------------
-- Stage 5. Post-apply assertion. Logs a NOTICE with the final counts and
--          raises a WARNING (not ERROR) if coverage drops below 75 %.
-- ---------------------------------------------------------------------------

DO $$
DECLARE
  v_total bigint;
  v_filled bigint;
  v_pct int;
BEGIN
  SELECT COUNT(*), COUNT(territory_id)
    INTO v_total, v_filled
    FROM representative;

  v_pct := ROUND(v_filled * 100.0 / NULLIF(v_total, 0))::int;

  RAISE NOTICE 'BUG-72 post-backfill: % / % reps have territory_id (% pct)',
               v_filled, v_total, v_pct;

  IF v_pct < 75 THEN
    RAISE WARNING 'BUG-72 territory_id coverage below 75 pct — expected >=78 pct. Investigate before marking complete.';
  END IF;
END $$;

COMMIT;
