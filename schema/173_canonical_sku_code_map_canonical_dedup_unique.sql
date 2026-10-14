-- ════════════════════════════════════════════════════════════════════════════
-- schema/173_canonical_sku_code_map_canonical_dedup_unique.sql
-- PHASE1-CLOSE-B1-CSCM-DEDUP — canonical_sku_code_map structural dedup
-- ════════════════════════════════════════════════════════════════════════════
-- Date: 2026-05-13
-- Trust contract v1.1 / forward-only / destructive=true (DELETE 561 rows).
--
-- THE OWNER CONTEXT
-- -------------
-- Cross-source attestation rows for the same canonical product inflate code
-- counts on /skus/export, /margins, and (when DISTINCT is missed) any
-- consumer aggregating canonical_sku_code_map. Example: Coppabella Sirius
-- Chardonnay code COCSCHAB22 sits twice — once as source='vinsight', once as
-- source='access'. Both attribute the SAME canonical_sku_id. UI shows fan-out
-- = 2 when truth = 1 distinct code.
--
-- ------------------------------------------------------------------
--   total rows                              = 2177
--   dupe keys on (canonical_sku_id, code)   = 560
--   rows-to-drop                            = 561
--      (560 keys × 1 dupe-each, +1 three-way dupe)
--   100% of dupe keys agree on canonical_sku_id (no semantic conflict)
--   sources priority: vinsight > moppity > dws > access > alm > ilg
--   drops by source: access 459, alm 82, ilg 18, dws 2 = 561
--
-- TARGET STATE
-- ------------
--   total rows                              = 1616
--   dupe keys on (canonical_sku_id, code)   = 0
--   UNIQUE (canonical_sku_id, external_code) enforced at DB level
--   old UNIQUE (source_system, external_code) DROPPED — was too narrow and
--     mathematically implied by the new UNIQUE for the rows that survive
--     dedup (a (canonical, code) pair has at most one surviving source row,
--     so (source, code) cannot dupe within a canonical; the only way the old
--     constraint could differ is across canonicals — which is the legitimate
--     131-row cross-canonical attestation pattern we DO NOT want to block,
--     see DANGER §).
--
-- DANGER (from sanity probe §4)
-- -----------------------------
-- 131 external_codes legitimately map to MULTIPLE canonical_sku_ids (e.g.
-- ALM EAN 00126864 attributes both canonical 96 + canonical 115). This is
-- semantic ambiguity in ALM EDI upstream, NOT dedup-introduced. The new
-- UNIQUE(canonical_sku_id, external_code) PRESERVES these legitimate rows.
-- An alternative UNIQUE(external_code) would DROP them and corrupt data.
-- DO NOT change the UNIQUE target on a future migration without re-checking
-- this caveat.
--
-- -------------------------------------------------------------------
-- schema/ grep for canonical_sku_code_map UNIQUE/CONSTRAINT/DROP:
--   schema/012      — original CREATE TABLE + UNIQUE(source_system,
--                     external_code) (the constraint this migration DROPs).
--   schema/088      — JOIN reader, no constraint touch.
--   schema/089      — adds CREATE INDEX on canonical_sku_id (kept, helps
--                     new UNIQUE). Adds DROP TRIGGER (already disabled).
--                     Comment on line 108 references the old UNIQUE; not
--                     load-bearing.
--   schema/113      — canonical_sku dedup; no canonical_sku_code_map
--                     constraint touch (only counts refs).
--   schema/125,137,170 — UPDATE/DELETE specific rows; do not touch
--                     constraints. schema/170 row id=3167 already applied
--                     and may not survive dedup (acceptable: that migration
--                     is idempotent on the canonical_sku_id value, not the id).
-- CONCLUSION: no prior migration owns the old UNIQUE other than schema/012.
--             No conflict.
--
-- dashboard/ + etl/ + tests/ + scripts/ grep for code relying on
-- UNIQUE(source_system, external_code):
--   etl/populate_canonical_sku_code_map.py:59       — ON CONFLICT target,
--     patched in this ticket's companion change to (canonical_sku_id,
--     external_code).
--   etl/dws_new_vintage_detect.py:91                — ON CONFLICT target,
--     patched in this ticket's companion change.
--   dashboard/src/app/api/skus/route.ts:130-133     — INSERTs into
--     sku_code_map (different table), unaffected.
--   dashboard/src/app/api/upload/save-match/route.ts:54-56 — sku_code_map
--     (different table), unaffected.
--   dashboard/src/app/api/skus/export/route.ts:96-128 — pure SELECT, no
--     UNIQUE dependency.
--   dashboard/src/app/api/margins/route.ts:131-147   — pure SELECT.
--   dashboard/src/app/api/overview/route.ts:111      — pure SELECT.
--   dashboard/src/app/api/reference-tables/route.ts:299-318 — pure SELECT
--     display-time DISTINCT ON priority CASE (different table sku_code_map
--     anyway). Unaffected.
--   dashboard/src/lib/ai-system-prompt.ts:57-70     — doc string only.
--   dashboard/src/lib/ai-tools.ts:297-316           — JOIN reader, no
--     UNIQUE dependency.
--   etl/sku_hierarchical_match.py:53-86             — read-only.
--     test_e4 + test_e5 currently xfail; will flip XPASS post-deploy.
--   schema/089 trigger trg_enforce_dws_canonical_cap_27 — already disabled
--     line 102. New UNIQUE has no interaction.
--
-- CONCLUSION: no code path requires global cross-source external_code
--             uniqueness. Safe to DROP old UNIQUE.
--
-- SCHEMA/174 SKIP DECISION
-- ------------------------
-- L6-style CHECK NOT VALID belt-and-braces (schema/162 pattern) was
-- considered for canonical_sku_code_map. NOT WRITTEN because:
--   (a) UNIQUE(canonical_sku_id, external_code) is STRICTER than any CHECK
--       could express for this dedup semantic — CHECK is per-row, UNIQUE
--       is multi-row.
--   (b) Adding a non-multi-row CHECK (e.g. confidence IS NOT NULL) would
--       mix concerns into a structural-dedup ticket.
--   (c) L6 universal-harness ratchet (schema/162→163) is the right place
--       for new CHECKs, not a B1-specific schema/174.
-- Future L6 expansion may add canonical_sku_code_map CHECKs (e.g.
-- source_system IN allowed list); that ships as a separate ticket.
--
-- ROLLBACK NOTE
-- -------------
-- recoverable post-hoc by:
--   1. Re-running etl/populate_canonical_sku_code_map.py — it derives
--      canonical_sku_code_map from sku_code_map JOIN sku.canonical_sku_id.
--      With patched ON CONFLICT target (canonical_sku_id, external_code),
--      re-running would NOT re-introduce dupes; only first-encountered
--      source for each (canonical, code) survives. NOT a true rollback —
--      original source attribution order is lost. Acceptable per probe-review
--      §5 ("provenance loss is the intended structural dedup, not a bug").
--   2. /var/backups/moppity prod backup — restore canonical_sku_code_map
--      table snapshot if a critical reversal is needed.
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ════════════════════════════════════════════════════════════════════════════
-- PRE — assert prod state matches sanity probe baseline (2026-05-13)
-- until verified at migration time. Fail loudly if prod has drifted.
-- ════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  pre_total             INT;
  pre_dupe_keys         INT;
  pre_rows_to_drop      INT;
  pre_old_uniq_exists   INT;
  pre_new_uniq_exists   INT;
BEGIN
  SELECT COUNT(*) INTO pre_total FROM canonical_sku_code_map;

  SELECT COUNT(*) INTO pre_dupe_keys FROM (
    SELECT canonical_sku_id, external_code
      FROM canonical_sku_code_map
     GROUP BY canonical_sku_id, external_code
    HAVING COUNT(*) > 1
  ) k;

  -- Rows-to-drop = total - distinct (canonical_sku_id, external_code).
  SELECT pre_total - COUNT(DISTINCT (canonical_sku_id, external_code))
    INTO pre_rows_to_drop
    FROM canonical_sku_code_map;

  SELECT COUNT(*) INTO pre_old_uniq_exists
    FROM pg_constraint
   WHERE conname = 'canonical_sku_code_map_source_system_external_code_key';

  SELECT COUNT(*) INTO pre_new_uniq_exists
    FROM pg_constraint
   WHERE conname = 'canonical_sku_code_map_canonical_code_uniq';

  RAISE NOTICE 'PHASE1-CLOSE-B1-CSCM-DEDUP PRE: total=% (expect 2177) dupe_keys=% (expect 560) rows_to_drop=% (expect 561)',
    pre_total, pre_dupe_keys, pre_rows_to_drop;
  RAISE NOTICE 'PHASE1-CLOSE-B1-CSCM-DEDUP PRE: old_uniq=% (expect 1) new_uniq=% (expect 0)',
    pre_old_uniq_exists, pre_new_uniq_exists;

  IF pre_total <> 2177 THEN
    RAISE EXCEPTION 'PRE FAIL: canonical_sku_code_map total = %, expected 2177. Prod drifted since 2026-05-13 sanity probe — RE-SCOUT before deploy.', pre_total;
  END IF;
  IF pre_dupe_keys <> 560 THEN
    RAISE EXCEPTION 'PRE FAIL: dupe_keys on (canonical_sku_id, external_code) = %, expected 560.', pre_dupe_keys;
  END IF;
  IF pre_rows_to_drop <> 561 THEN
    RAISE EXCEPTION 'PRE FAIL: rows_to_drop = %, expected 561.', pre_rows_to_drop;
  END IF;
  IF pre_old_uniq_exists <> 1 THEN
    RAISE EXCEPTION 'PRE FAIL: old UNIQUE canonical_sku_code_map_source_system_external_code_key not found. Migration assumes it exists from schema/012.';
  END IF;
  IF pre_new_uniq_exists <> 0 THEN
    RAISE EXCEPTION 'PRE FAIL: new UNIQUE canonical_sku_code_map_canonical_code_uniq already exists. Migration already partially applied.';
  END IF;

  RAISE NOTICE 'PHASE1-CLOSE-B1-CSCM-DEDUP PRE: all asserts pass';
END $$;


-- ════════════════════════════════════════════════════════════════════════════
-- STEP 1 — DELETE 561 lower-priority dupe rows
-- ════════════════════════════════════════════════════════════════════════════
-- Priority CASE per probe-review §3:
--   vinsight=1 (highest, keep)
--   moppity =2
--   dws     =3
--   access  =4
--   alm     =5
--   ilg     =6
--   other   =7 (lowest, drop first)
-- ROW_NUMBER() partitions by the dedup key, orders by priority then id
-- (deterministic tie-breaker). rn=1 survives, rn>1 dropped.
-- ════════════════════════════════════════════════════════════════════════════
WITH ranked AS (
  SELECT id,
         ROW_NUMBER() OVER (
           PARTITION BY canonical_sku_id, external_code
           ORDER BY
             CASE LOWER(source_system)
               WHEN 'vinsight' THEN 1
               WHEN 'moppity'  THEN 2
               WHEN 'dws'      THEN 3
               WHEN 'access'   THEN 4
               WHEN 'alm'      THEN 5
               WHEN 'ilg'      THEN 6
               ELSE                 7
             END,
             id
         ) AS rn
    FROM canonical_sku_code_map
)
DELETE FROM canonical_sku_code_map
 WHERE id IN (SELECT id FROM ranked WHERE rn > 1);


-- ════════════════════════════════════════════════════════════════════════════
-- STEP 2 — DROP old UNIQUE (source_system, external_code)
-- ════════════════════════════════════════════════════════════════════════════
-- Old constraint name = default-generated from UNIQUE clause in schema/012:
--   canonical_sku_code_map_source_system_external_code_key
-- Index idx_canonical_sku_code_map_lookup (schema/012 line 61) is a SEPARATE
-- object and is NOT dropped — still useful for source-filtered lookups.
-- ════════════════════════════════════════════════════════════════════════════
ALTER TABLE canonical_sku_code_map
  DROP CONSTRAINT canonical_sku_code_map_source_system_external_code_key;


-- ════════════════════════════════════════════════════════════════════════════
-- STEP 3 — ADD new UNIQUE (canonical_sku_id, external_code)
-- ════════════════════════════════════════════════════════════════════════════
-- Constraint name = canonical_sku_code_map_canonical_code_uniq
-- Implicit btree index created with same name. Replaces old UNIQUE for
-- structural-dedup semantics. Cross-canonical (131-row) attestation
-- preserved — see DANGER §.
-- ════════════════════════════════════════════════════════════════════════════
ALTER TABLE canonical_sku_code_map
  ADD CONSTRAINT canonical_sku_code_map_canonical_code_uniq
  UNIQUE (canonical_sku_id, external_code);


-- ════════════════════════════════════════════════════════════════════════════
-- POST — assert clean state
-- ════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  post_total            INT;
  post_dupe_keys        INT;
  post_old_uniq_exists  INT;
  post_new_uniq_exists  INT;
  post_new_uniq_valid   BOOLEAN;
BEGIN
  SELECT COUNT(*) INTO post_total FROM canonical_sku_code_map;

  SELECT COUNT(*) INTO post_dupe_keys FROM (
    SELECT canonical_sku_id, external_code
      FROM canonical_sku_code_map
     GROUP BY canonical_sku_id, external_code
    HAVING COUNT(*) > 1
  ) k;

  SELECT COUNT(*) INTO post_old_uniq_exists
    FROM pg_constraint
   WHERE conname = 'canonical_sku_code_map_source_system_external_code_key';

  SELECT COUNT(*) INTO post_new_uniq_exists
    FROM pg_constraint
   WHERE conname = 'canonical_sku_code_map_canonical_code_uniq';

  SELECT convalidated INTO post_new_uniq_valid
    FROM pg_constraint
   WHERE conname = 'canonical_sku_code_map_canonical_code_uniq';

  RAISE NOTICE 'PHASE1-CLOSE-B1-CSCM-DEDUP POST: total=% (expect 1616) dupe_keys=% (expect 0)',
    post_total, post_dupe_keys;
  RAISE NOTICE 'PHASE1-CLOSE-B1-CSCM-DEDUP POST: old_uniq=% (expect 0) new_uniq=% (expect 1) new_uniq_validated=% (expect t)',
    post_old_uniq_exists, post_new_uniq_exists, post_new_uniq_valid;

  IF post_total <> 1616 THEN
    RAISE EXCEPTION 'POST FAIL: canonical_sku_code_map total = %, expected 1616 (2177 - 561 dropped).', post_total;
  END IF;
  IF post_dupe_keys <> 0 THEN
    RAISE EXCEPTION 'POST FAIL: % dupe keys remain on (canonical_sku_id, external_code); expected 0.', post_dupe_keys;
  END IF;
  IF post_old_uniq_exists <> 0 THEN
    RAISE EXCEPTION 'POST FAIL: old UNIQUE still registered. DROP CONSTRAINT silently no-op?';
  END IF;
  IF post_new_uniq_exists <> 1 THEN
    RAISE EXCEPTION 'POST FAIL: new UNIQUE canonical_sku_code_map_canonical_code_uniq not registered.';
  END IF;
  IF NOT post_new_uniq_valid THEN
    RAISE EXCEPTION 'POST FAIL: new UNIQUE registered but not validated. Expected immediate validation (not NOT VALID).';
  END IF;

  RAISE NOTICE 'PHASE1-CLOSE-B1-CSCM-DEDUP POST: all asserts pass';
END $$;


-- ════════════════════════════════════════════════════════════════════════════
-- Record migration in schema_migrations (project convention per schema/071).
-- ════════════════════════════════════════════════════════════════════════════
INSERT INTO schema_migrations (version, applied_at, source)
VALUES ('173_canonical_sku_code_map_canonical_dedup_unique', NOW(), 'live-apply')
ON CONFLICT (version) DO NOTHING;

COMMIT;
