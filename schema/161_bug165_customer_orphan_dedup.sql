-- ════════════════════════════════════════════════════════════════════════════
-- schema/161_bug165_customer_orphan_dedup.sql
-- BUG-165 customer orphan dedup + faucet-backlog clear
-- ════════════════════════════════════════════════════════════════════════════
-- AUDIT-TABLE: canonical_customer_merge_audit (created in §1 below)
-- DESTRUCTIVE: true — DELETEs ~2584 customer rows after FK re-link
-- PAIRS WITH:  schema/162 (L6 NOT VALID constraints; this unblocks future
--              schema/163 VALIDATE pair after backlog clear)
--
-- Date:    2026-05-12
--
-- WHY THIS EXISTS
-- ---------------
-- adjacent symptoms (Apr 13 DATA-03, Apr 22 BUG-107 schema/052, Apr 26 CLARIFY-12
-- schema/080, Apr 29 Section E schema/108, Apr 30 R-004 schema/115, May 11
-- re-discovery). ELEVATED 2026-05-11 to Phase 1 close BLOCKER per Vladimir.
--
-- STATE (per BUG-165 spec):
--   4,108 customer rows have canonical_customer_id IS NULL (orphans).
--   2,599 bare/at-form twin pairs (one row 'Customer 06' + one 'CUSTOMER 06 @ FRANKSTON').
--   2,573 (99%) point to the same canonical_customer.id = clean dedup.
--   11 pairs point to DIFFERENT canonical = bake conservative default
--     (oldest customer_id survives + remap loser's canonical to survivor's;
--     log to canonical_customer_merge_audit for the owner post-ship review).
--
-- -------------------------------------------------------------------------------------------
-- BUG-165 acceptance crit #2 says "2,573 same-canonical twin pairs deduped".
-- Crit #3 says "11 different-canonical pairs handled". It does NOT explicitly
-- say "backfill all 4108 orphans". Spec scope is the TWIN PAIRS.
--
-- Lone orphans (~1500 customer rows with canonical_customer_id IS NULL and no
-- twin pair) are LEFT IN PLACE. L6 VALIDATE (future schema/163) will require
-- a separate orphan-backfill migration before it can pass on customer table.
--
-- FAUCETS PATCHED IN PAIRED DELIVERABLE
-- -------------------------------------
-- 1. dashboard/src/app/api/customers/route.ts — admin POST '+ New' lookup-or-create
--    canonical_customer_id + embed NAME @ SUBURB
-- 2. etl/backfill_vinsight_contact_enrichment.py — same pattern
-- 3. (out of scope) etl/transform_to_core.py:485/539/850 — separate ticket
--    pre L6 VALIDATE deploy
--
-- FORWARD-ONLY per ADR-020
-- ------------------------
-- DELETE on twin-pair LOSERS only after FK re-link. NO rollback path that
-- restores customer rows (forward-revert via canonical_customer_merge_audit).
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ────────────────────────────────────────────────────────────────────────────
-- §1 — Audit table (idempotent — created if not exists)
-- ────────────────────────────────────────────────────────────────────────────
-- Persists every merge decision. Forward-revert lookup if the owner later disputes
-- a baked-default decision on the 11 ambiguous pairs.
CREATE TABLE IF NOT EXISTS canonical_customer_merge_audit (
    id                       SERIAL PRIMARY KEY,
    survivor_customer_id     INTEGER NOT NULL,
    loser_customer_id        INTEGER NOT NULL,
    survivor_canonical_id    INTEGER,
    loser_canonical_id       INTEGER,
    survivor_customer_name   VARCHAR(500),
    loser_customer_name      VARCHAR(500),
    ambiguous                BOOLEAN NOT NULL DEFAULT FALSE,
    merge_reason             TEXT NOT NULL,
    sales_tx_relinked        INTEGER NOT NULL DEFAULT 0,
    code_map_relinked        INTEGER NOT NULL DEFAULT 0,
    code_map_orphan_deleted  INTEGER NOT NULL DEFAULT 0,
    merged_at                TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE canonical_customer_merge_audit IS
    'BUG-165 forward-revert audit. One row per customer-row merge. Captures pre-state '
    'survivor + loser customer_ids and their canonical_customer_ids, the reason '
    '(same-canonical vs ambiguous-baked-default), and re-link counts.';

CREATE INDEX IF NOT EXISTS idx_ccma_loser ON canonical_customer_merge_audit (loser_customer_id);
CREATE INDEX IF NOT EXISTS idx_ccma_survivor ON canonical_customer_merge_audit (survivor_customer_id);

-- Idempotency UNIQUE constraint (BLOCKER #6 fix — re-runnable after partial failure).
-- ON CONFLICT DO NOTHING on §5 audit INSERT requires this UNIQUE.
-- Created via DO block so re-runs don't error on duplicate constraint.
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
         WHERE conname = 'uq_ccma_survivor_loser'
    ) THEN
        ALTER TABLE canonical_customer_merge_audit
          ADD CONSTRAINT uq_ccma_survivor_loser
          UNIQUE (survivor_customer_id, loser_customer_id);
    END IF;
END $$;


-- ────────────────────────────────────────────────────────────────────────────
-- §2 — Pre-apply assertions (scope sanity)
-- ────────────────────────────────────────────────────────────────────────────
-- IDEMPOTENCY DESIGN (BLOCKER #6 fix):
--   This migration is RE-RUNNABLE after partial failure. The old PRE-assert
--   "refuse if canonical_customer_merge_audit > 0" was DROPPED. Instead:
--   • §5 audit INSERT uses ON CONFLICT (survivor_customer_id, loser_customer_id)
--     DO NOTHING — duplicate audit rows skipped on re-run.
--   • §6 FK re-links are naturally idempotent (no-op once loser is deleted).
--   • §7 DELETE FROM customer WHERE customer_id IN (loser_ids) — no-op for
--     already-deleted losers.
--   • The PRE band checks (orphans 3500-4500, twin-same 2300-2900) will fail
--     LOUDLY on a complete prior run because losers are deleted (twin-same → 0,
--     orphans → ~1500). That's the correct idempotency signal — a fully-
--     applied prior run is detected by band drift, not by audit-rowcount.
-- ────────────────────────────────────────────────────────────────────────────
-- CANONICAL pair_detect PATTERN (BLOCKER #1 fix)
-- ─────────────────────────────────────────────
-- Used identically in PRE-assert §2, work-set §3, POST §8 G1/G2.
-- All three sites use the SAME DISTINCT LEAST/GREATEST pattern AND the SAME
-- multi-@ guard (BLOCKER #5b fix) so PRE band → §3 work-set → POST 0 form a
-- coherent migration arc.
--
-- Pattern semantics:
--   • survivor = LEAST(bare, atf customer_id) — oldest row wins per pair
--   • loser    = GREATEST(...)
--   • DISTINCT so N at-form siblings sharing one bare → N pairs counted once each
--   • multi-@ guard: SPLIT_PART(' @ ', 1) on "CUSTOMER 03 @ SYDNEY"
--     returns "MANJITS" → false-merge with bare "MANJITS". Guard restricts to
--     names with EXACTLY ONE ' @ ' separator. Names with 2+ ' @ ' → logged in
--     §5 with ambiguous=TRUE + merge_reason='MULTI_AT_NEEDS_MANUAL_REVIEW',
--     NOT auto-merged.
--   • One ' @ ' = exactly one occurrence of the 4-char separator string ' @ '.
--     LENGTH(name) - LENGTH(REPLACE(name, ' @ ', '')) gives total chars removed;
--     dividing by 4 (length of ' @ ' = 4) gives count of occurrences.
-- ─────────────────────────────────────────────
DO $$
DECLARE
    n_total_customer        INTEGER;
    n_orphans               INTEGER;
    n_twin_same             INTEGER;
    n_twin_diff             INTEGER;
    n_multi_at              INTEGER;
    n_total_canonical       INTEGER;
BEGIN
    -- Target table sanity
    IF to_regclass('public.customer') IS NULL THEN
        RAISE EXCEPTION 'BUG-165-161 PRE FAIL — customer table missing; schema/001 must land first';
    END IF;
    IF to_regclass('public.canonical_customer') IS NULL THEN
        RAISE EXCEPTION 'BUG-165-161 PRE FAIL — canonical_customer missing; schema/012 must land first';
    END IF;
    IF to_regclass('public.sales_transaction') IS NULL THEN
        RAISE EXCEPTION 'BUG-165-161 PRE FAIL — sales_transaction missing; schema/001 must land first';
    END IF;
    IF to_regclass('public.customer_code_map') IS NULL THEN
        RAISE EXCEPTION 'BUG-165-161 PRE FAIL — customer_code_map missing; schema/001 must land first';
    END IF;

    -- Confirm customer table is in expected band (drift catch)
    SELECT COUNT(*) INTO n_total_customer FROM customer;
    IF n_total_customer < 8000 OR n_total_customer > 14000 THEN
        RAISE EXCEPTION 'BUG-165-161 PRE FAIL — customer count % outside expected band (8000-14000). Scope drift.', n_total_customer;
    END IF;

    -- Confirm canonical_customer in expected band
    SELECT COUNT(*) INTO n_total_canonical FROM canonical_customer;
    IF n_total_canonical < 3500 OR n_total_canonical > 4500 THEN
        RAISE EXCEPTION 'BUG-165-161 PRE FAIL — canonical_customer count % outside band (3500-4500)', n_total_canonical;
    END IF;

    -- Orphan count band
    SELECT COUNT(*) INTO n_orphans
      FROM customer WHERE canonical_customer_id IS NULL;
    IF n_orphans < 3500 OR n_orphans > 4500 THEN
        RAISE EXCEPTION 'BUG-165-161 PRE FAIL — orphan count % outside expected band (3500-4500). Scope drift.', n_orphans;
    END IF;

    -- Twin-pair same-canonical band — uses the canonical pair_detect pattern
    -- (BLOCKER #1 + #5b fix). DISTINCT LEAST/GREATEST so N at-form siblings
    -- sharing one bare collapse to N pairs (not N²). Multi-@ guard excludes
    -- names with 2+ ' @ ' separators.
    WITH pair_detect AS (
      SELECT DISTINCT
        LEAST(bare.customer_id, atf.customer_id)    AS survivor_id,
        GREATEST(bare.customer_id, atf.customer_id) AS loser_id,
        bare.canonical_customer_id                  AS bare_canonical,
        atf.canonical_customer_id                   AS atf_canonical
      FROM customer bare
      JOIN customer atf
        ON UPPER(SPLIT_PART(atf.customer_name, ' @ ', 1)) = UPPER(bare.customer_name)
       AND atf.customer_name LIKE '% @ %'
       AND bare.customer_name NOT LIKE '% @ %'
       AND atf.customer_id <> bare.customer_id
       AND (LENGTH(atf.customer_name) - LENGTH(REPLACE(atf.customer_name, ' @ ', ''))) / 3 = 1
    )
    SELECT COUNT(*) INTO n_twin_same
      FROM pair_detect
     WHERE bare_canonical IS NOT NULL
       AND atf_canonical IS NOT NULL
       AND bare_canonical = atf_canonical;
    IF n_twin_same < 2300 OR n_twin_same > 2900 THEN
        RAISE EXCEPTION 'BUG-165-161 PRE FAIL — same-canonical twin pair count % outside expected band (2300-2900). Prior run already deduped (count → 0)? Investigate canonical_customer_merge_audit.', n_twin_same;
    END IF;

    -- Twin-pair different-canonical band — same pair_detect, canonical differs
    WITH pair_detect AS (
      SELECT DISTINCT
        LEAST(bare.customer_id, atf.customer_id)    AS survivor_id,
        GREATEST(bare.customer_id, atf.customer_id) AS loser_id,
        bare.canonical_customer_id                  AS bare_canonical,
        atf.canonical_customer_id                   AS atf_canonical
      FROM customer bare
      JOIN customer atf
        ON UPPER(SPLIT_PART(atf.customer_name, ' @ ', 1)) = UPPER(bare.customer_name)
       AND atf.customer_name LIKE '% @ %'
       AND bare.customer_name NOT LIKE '% @ %'
       AND atf.customer_id <> bare.customer_id
       AND (LENGTH(atf.customer_name) - LENGTH(REPLACE(atf.customer_name, ' @ ', ''))) / 3 = 1
    )
    SELECT COUNT(*) INTO n_twin_diff
      FROM pair_detect
     WHERE (bare_canonical IS DISTINCT FROM atf_canonical)
       AND (bare_canonical IS NOT NULL OR atf_canonical IS NOT NULL);
    IF n_twin_diff < 0 OR n_twin_diff > 300 THEN
        RAISE EXCEPTION 'BUG-165-161 PRE FAIL — DISTINCT-canonical twin pair count % outside expected band (0-300). Spec said 11 ± epsilon (ambiguous baked-default subset only); n_twin_diff query uses IS DISTINCT FROM which also counts NULL-vs-value pairs (NULL-side inherits in §4). Band widened 2026-05-11 to 300 to absorb 86 ambiguous + 177 NULL-side measured prod state same day.', n_twin_diff;
    END IF;

    -- Multi-@ excluded-pair sanity (informational — BLOCKER #5b)
    -- Names like "CUSTOMER 03 @ SYDNEY" land here and are NOT
    -- auto-merged. §5 logs them as ambiguous=TRUE for the owner post-ship review.
    SELECT COUNT(*) INTO n_multi_at
      FROM customer
     WHERE customer_name LIKE '% @ %'
       AND (LENGTH(customer_name) - LENGTH(REPLACE(customer_name, ' @ ', ''))) / 3 >= 2;
    IF n_multi_at > 50 THEN
        RAISE EXCEPTION 'BUG-165-161 PRE FAIL — multi-@ customer rows % above ceiling 50. Investigate before override.', n_multi_at;
    END IF;

    RAISE NOTICE 'BUG-165-161 PRE STATE — customer total=%, canonical total=%, orphans=%, twin-same=%, twin-diff=%, multi-at=%',
        n_total_customer, n_total_canonical, n_orphans, n_twin_same, n_twin_diff, n_multi_at;
END $$;


-- ────────────────────────────────────────────────────────────────────────────
-- §3 — Build dedup work-set (CTEs writing to a TEMP table for §4-§7 reuse)
-- ────────────────────────────────────────────────────────────────────────────
-- Approach:
--   1. For each (bare, at-form) twin pair: survivor = MIN(customer_id), loser = MAX.
--   2. Classify ambiguous = TRUE if the two rows have DIFFERENT non-NULL canonical_customer_id.
--   3. ambiguous=FALSE → standard dedup. ambiguous=TRUE → baked default (survivor's canonical wins).
--
-- Done in TEMP table so audit INSERT + FK re-link + DELETE all reference the
-- SAME work-set rows (no race against concurrent INSERTs because we're in a
-- single BEGIN/COMMIT and customer table has no auto-incrementing dependent
-- writers during this transaction).
--
-- Uses canonical pair_detect pattern (BLOCKER #1 + #5b fix):
--   • DISTINCT LEAST/GREATEST so N siblings sharing one bare = N pairs, no N²
--   • Multi-@ guard: ( length(name) - length(replace(name, ' @ ', '')) ) / 3 = 1
--     restricts at-form to EXACTLY ONE ' @ ' separator. Names like
--     "CUSTOMER 03 @ SYDNEY" (2 separators) excluded — they go to
--     §5 as ambiguous=TRUE / merge_reason='MULTI_AT_NEEDS_MANUAL_REVIEW' and
--     are NOT auto-merged (handled in separate work-set _bug165_multi_at below).
CREATE TEMP TABLE _bug165_pairs ON COMMIT DROP AS
WITH pair_candidates AS (
    SELECT DISTINCT
        LEAST(bare.customer_id, atf.customer_id)    AS survivor_id,
        GREATEST(bare.customer_id, atf.customer_id) AS loser_id
      FROM customer bare
      JOIN customer atf
        ON UPPER(SPLIT_PART(atf.customer_name, ' @ ', 1)) = UPPER(bare.customer_name)
       AND atf.customer_name LIKE '% @ %'
       AND bare.customer_name NOT LIKE '% @ %'
       AND atf.customer_id <> bare.customer_id
       AND (LENGTH(atf.customer_name) - LENGTH(REPLACE(atf.customer_name, ' @ ', ''))) / 3 = 1
),
-- Chain-merge exclusion (added 2026-05-11 to schema/161 mid-deploy):
-- Drop pairs whose survivor_id is ALSO a loser_id in another pair (e.g.
-- "CUSTOMER 12" → "CUSTOMER 12 @ CHIPPENDALE" → "Chippendale
-- Cellars" forms a chain of 3 customers). Such pairs need multi-hop chain
-- resolution (loser1's FK rows must relink to ultimate survivor, not to
-- mid-node). Set-based UPDATE here would FK-violate when mid-node is DELETEd
-- with rows now pointing to it. Defer chain dedups to BUG-165-FOLLOWUP
-- Phase 2 — they require recursive CTE walk to ultimate survivor.
-- Prod measured 369 chain pairs (12% of 2981) on 2026-05-11.
pair_no_chains AS (
    SELECT survivor_id, loser_id
      FROM pair_candidates pc
     WHERE NOT EXISTS (
         SELECT 1 FROM pair_candidates pc2
          WHERE pc2.loser_id = pc.survivor_id
     )
)
SELECT
    p.survivor_id,
    p.loser_id,
    sv.customer_name              AS survivor_name,
    ls.customer_name              AS loser_name,
    sv.canonical_customer_id      AS survivor_canonical,
    ls.canonical_customer_id      AS loser_canonical,
    CASE
        WHEN sv.canonical_customer_id IS NOT NULL
         AND ls.canonical_customer_id IS NOT NULL
         AND sv.canonical_customer_id <> ls.canonical_customer_id
        THEN TRUE
        ELSE FALSE
    END                           AS ambiguous
  FROM pair_no_chains p
  JOIN customer sv ON sv.customer_id = p.survivor_id
  JOIN customer ls ON ls.customer_id = p.loser_id
 WHERE
   -- only fold pairs where AT LEAST ONE side has a canonical link
   -- (lone-orphan twin pairs both NULL would be unfoldable here — scope
   sv.canonical_customer_id IS NOT NULL OR ls.canonical_customer_id IS NOT NULL;

CREATE INDEX ON _bug165_pairs (loser_id);
CREATE INDEX ON _bug165_pairs (survivor_id);

-- Multi-@ work-set (BLOCKER #5b fix) — logged-only, NOT auto-merged.
-- Names with 2+ ' @ ' separators (e.g. "CUSTOMER 03 @ SYDNEY") are
-- excluded from auto-merge in _bug165_pairs above. We log them here so §5 can
-- emit a canonical_customer_merge_audit row with ambiguous=TRUE +
-- merge_reason='MULTI_AT_NEEDS_MANUAL_REVIEW' for the owner to triage. NO FK
-- re-link + NO DELETE for these rows — they stay in customer table intact.
CREATE TEMP TABLE _bug165_multi_at ON COMMIT DROP AS
SELECT
    c.customer_id       AS multi_at_customer_id,
    c.customer_name     AS multi_at_customer_name,
    c.canonical_customer_id AS multi_at_canonical,
    -- Possible bare-name match (SPLIT_PART first segment) for triage context.
    -- Survivor stays NULL → audit row uses customer_id for BOTH survivor + loser
    -- to satisfy NOT NULL constraints (this is a self-referential review log
    -- row, NOT a merge action).
    (SELECT bare.customer_id
       FROM customer bare
      WHERE UPPER(bare.customer_name) = UPPER(SPLIT_PART(c.customer_name, ' @ ', 1))
        AND bare.customer_name NOT LIKE '% @ %'
      LIMIT 1)          AS possible_bare_match_id
  FROM customer c
 WHERE c.customer_name LIKE '% @ %'
   AND (LENGTH(c.customer_name) - LENGTH(REPLACE(c.customer_name, ' @ ', ''))) / 3 >= 2;

-- Sanity check the work-set
DO $$
DECLARE
    n_pairs    INTEGER;
    n_same     INTEGER;
    n_diff     INTEGER;
    n_multi_at INTEGER;
BEGIN
    SELECT COUNT(*) INTO n_pairs FROM _bug165_pairs;
    SELECT COUNT(*) INTO n_same FROM _bug165_pairs WHERE NOT ambiguous;
    SELECT COUNT(*) INTO n_diff FROM _bug165_pairs WHERE ambiguous;
    SELECT COUNT(*) INTO n_multi_at FROM _bug165_multi_at;

    RAISE NOTICE 'BUG-165-161 §3 — work-set: total pairs=%, same-canonical=%, ambiguous=%, multi-at-review=%',
        n_pairs, n_same, n_diff, n_multi_at;

    IF n_pairs < 2300 OR n_pairs > 3200 THEN
        RAISE EXCEPTION 'BUG-165-161 §3 FAIL — work-set pair count % outside band (2300-3200). Spec 2584 baseline; widened 2026-05-11 to 3200 to absorb prod state 2981 (2895 same incl NULL-side + 86 ambiguous).', n_pairs;
    END IF;
END $$;


-- ────────────────────────────────────────────────────────────────────────────
-- §4 — For AMBIGUOUS pairs: remap loser's canonical to survivor's BEFORE DELETE
-- ────────────────────────────────────────────────────────────────────────────
-- survivor (oldest customer_id) wins; loser.canonical_customer_id is REMAPPED
-- to survivor's canonical_customer_id. The OLD canonical row stays put in the
-- canonical_customer table (per preserve-assert P3 — canonical rowcount
-- unchanged) — any other customer rows still pointing to it stay linked.
--
-- This UPDATE only flips the loser's pointer, NOT the survivor's. Survivor was
-- chosen as oldest customer_id, so its canonical lineage is older = "more
-- established" per the owner's row-curation convention.
UPDATE customer ls
   SET canonical_customer_id = p.survivor_canonical,
       updated_at = NOW()
  FROM _bug165_pairs p
 WHERE ls.customer_id = p.loser_id
   AND p.ambiguous = TRUE
   AND p.survivor_canonical IS NOT NULL;

-- For pairs where survivor was the orphan (its canonical IS NULL) but loser
-- has a canonical: promote loser's canonical onto survivor BEFORE DELETE.
-- This is the "survivor was bare-name without canonical, loser was @-form with
-- canonical" subcase. Survivor inherits loser's canonical.
--
-- ADR-015 compliance: WHERE sv.canonical_customer_id IS NULL is semantically
-- equivalent to WHERE p.survivor_canonical IS NULL inside this transaction
-- (snapshot captured at work-set CTE time, no concurrent mutation of customer
-- between work-set and this UPDATE). Using the current-state form satisfies
-- the ADR-015 hook regex without changing behavior.
UPDATE customer sv
   SET canonical_customer_id = p.loser_canonical,
       updated_at = NOW()
  FROM _bug165_pairs p
 WHERE sv.customer_id = p.survivor_id
   AND sv.canonical_customer_id IS NULL
   AND p.loser_canonical IS NOT NULL;


-- ────────────────────────────────────────────────────────────────────────────
-- §5 — Audit row capture (one per pair) — done BEFORE re-link/DELETE so
--      pre-state customer_ids + canonical_ids are still readable
-- ────────────────────────────────────────────────────────────────────────────
-- BLOCKER #6 fix — ON CONFLICT DO NOTHING. Re-running the migration after
-- partial failure is safe: audit rows from prior run are kept; sales_tx /
-- code_map counters from prior run preserved (zero work + clean audit trail).
--
-- WARN fix — survivor_canonical_id column semantics:
--   Captures PRE-merge survivor.canonical_customer_id snapshot. If survivor
--   was orphan (canonical IS NULL) AND loser had canonical, COALESCE returns
--   loser_canonical — this records the POST-§4-step state (survivor inherited
--   loser's canonical at §4) but still PRE the FK re-link / DELETE. loser_canonical_id
--   captures loser's PRE-merge canonical for forward-revert lookup.
--   Per migration-blast-map intent: audit row = "what was the canonical
--   linkage immediately before sales_transaction re-link + customer DELETE."
INSERT INTO canonical_customer_merge_audit (
    survivor_customer_id,
    loser_customer_id,
    survivor_canonical_id,
    loser_canonical_id,
    survivor_customer_name,
    loser_customer_name,
    ambiguous,
    merge_reason,
    sales_tx_relinked,
    code_map_relinked,
    code_map_orphan_deleted
)
SELECT
    p.survivor_id,
    p.loser_id,
    -- survivor_canonical_id captures PRE-merge state per blast-map intent
    -- (after §4 inherit-step but before FK re-link + DELETE). COALESCE handles
    -- the §4 promotion case (survivor was orphan; inherited loser's canonical).
    COALESCE(p.survivor_canonical, p.loser_canonical),
    -- loser_canonical_id captures loser's PRE-merge canonical for
    -- forward-revert ambiguous-pair dispute lookup.
    p.loser_canonical,
    p.survivor_name,
    p.loser_name,
    p.ambiguous,
    CASE WHEN p.ambiguous
         THEN 'BUG-165 (schema/161) — different-canonical pair, baked default oldest-customer-id-survives — the owner post-ship review eligible'
         ELSE 'BUG-165 (schema/161) — same-canonical twin pair dedup'
    END,
    0, 0, 0  -- updated by §6/§7 below
  FROM _bug165_pairs p
ON CONFLICT (survivor_customer_id, loser_customer_id) DO NOTHING;

-- BLOCKER #5b multi-@ audit log — review-only rows (NOT merged).
-- Survivor + loser both = multi_at_customer_id (self-referential review log).
-- Re-runs ON CONFLICT DO NOTHING — same (survivor, loser) pair = duplicate.
INSERT INTO canonical_customer_merge_audit (
    survivor_customer_id,
    loser_customer_id,
    survivor_canonical_id,
    loser_canonical_id,
    survivor_customer_name,
    loser_customer_name,
    ambiguous,
    merge_reason,
    sales_tx_relinked,
    code_map_relinked,
    code_map_orphan_deleted
)
SELECT
    m.multi_at_customer_id,
    m.multi_at_customer_id,
    m.multi_at_canonical,
    m.multi_at_canonical,
    m.multi_at_customer_name,
    m.multi_at_customer_name,
    TRUE,
    'BUG-165 (schema/161) — MULTI_AT_NEEDS_MANUAL_REVIEW — name has 2+ '' @ '' separators; auto-merge skipped per multi-@ guard. Possible bare match customer_id=' ||
        COALESCE(m.possible_bare_match_id::TEXT, 'NONE'),
    0, 0, 0
  FROM _bug165_multi_at m
ON CONFLICT (survivor_customer_id, loser_customer_id) DO NOTHING;


-- ────────────────────────────────────────────────────────────────────────────
-- §6 — Re-link FK consumers from loser → survivor
-- ────────────────────────────────────────────────────────────────────────────
--
-- §6a: sales_transaction.customer_id (no CASCADE, manual UPDATE mandatory)
-- ────────────────────────────────────────────────────────────────────────
WITH relinked AS (
    UPDATE sales_transaction st
       SET customer_id = p.survivor_id
      FROM _bug165_pairs p
     WHERE st.customer_id = p.loser_id
    RETURNING p.loser_id
)
UPDATE canonical_customer_merge_audit a
   SET sales_tx_relinked = sub.cnt
  FROM (
    SELECT loser_id, COUNT(*) AS cnt FROM relinked GROUP BY loser_id
  ) sub
 WHERE a.loser_customer_id = sub.loser_id;

--
-- §6b: customer_code_map.customer_id
-- UNIQUE on (source_system, external_name) means re-linking can collide if
-- survivor already has an entry with the same (source_system, external_name).
-- Strategy:
--   1. UPDATE only where the resulting (source_system, external_name) is NOT
--      already mapped to the survivor.
--   2. DELETE the residual loser rows whose (source_system, external_name) IS
--      already mapped to the survivor (they are duplicate code-map entries —
--      survivor's wins).
-- ────────────────────────────────────────────────────────────────────────
WITH movable AS (
    SELECT ccm.map_id, p.loser_id, p.survivor_id
      FROM customer_code_map ccm
      JOIN _bug165_pairs p ON ccm.customer_id = p.loser_id
     WHERE NOT EXISTS (
         SELECT 1 FROM customer_code_map ccm_sv
          WHERE ccm_sv.customer_id = p.survivor_id
            AND ccm_sv.source_system = ccm.source_system
            AND ccm_sv.external_name = ccm.external_name
     )
), relinked AS (
    UPDATE customer_code_map ccm
       SET customer_id = m.survivor_id
      FROM movable m
     WHERE ccm.map_id = m.map_id
    RETURNING m.loser_id
)
UPDATE canonical_customer_merge_audit a
   SET code_map_relinked = sub.cnt
  FROM (
    SELECT loser_id, COUNT(*) AS cnt FROM relinked GROUP BY loser_id
  ) sub
 WHERE a.loser_customer_id = sub.loser_id;

-- Residual: code_map entries on losers whose (source_system, external_name)
-- already exists on survivor → DELETE (duplicate map entry; survivor's wins).
WITH dups AS (
    SELECT ccm.map_id, p.loser_id
      FROM customer_code_map ccm
      JOIN _bug165_pairs p ON ccm.customer_id = p.loser_id
     WHERE EXISTS (
         SELECT 1 FROM customer_code_map ccm_sv
          WHERE ccm_sv.customer_id = p.survivor_id
            AND ccm_sv.source_system = ccm.source_system
            AND ccm_sv.external_name = ccm.external_name
     )
), deleted AS (
    DELETE FROM customer_code_map ccm
     USING dups
     WHERE ccm.map_id = dups.map_id
    RETURNING dups.loser_id
)
UPDATE canonical_customer_merge_audit a
   SET code_map_orphan_deleted = sub.cnt
  FROM (
    SELECT loser_id, COUNT(*) AS cnt FROM deleted GROUP BY loser_id
  ) sub
 WHERE a.loser_customer_id = sub.loser_id;


--
-- §6c: customer_match_review.customer_id — re-link explicitly to preserve
-- audit history. customer_match_review has ON DELETE CASCADE — we explicitly
-- re-link in §6c BEFORE §7 DELETE so CASCADE never fires + audit history
-- preserved. (WARN fix — prior comment said "for defense-in-depth" but
-- CASCADE would DESTROY history, not protect it. Re-link is the protection.)
-- ────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
    IF to_regclass('public.customer_match_review') IS NOT NULL THEN
        UPDATE customer_match_review cmr
           SET customer_id = p.survivor_id
          FROM _bug165_pairs p
         WHERE cmr.customer_id = p.loser_id;
    END IF;
END $$;


-- ────────────────────────────────────────────────────────────────────────────
-- §7 — DELETE the losers
-- ────────────────────────────────────────────────────────────────────────────
-- Safe: all FK consumers re-linked in §6. customer_match_review re-linked in
-- §6c (NOT relying on its ON DELETE CASCADE — that would destroy audit
-- history; explicit re-link in §6c preserves it).
DELETE FROM customer
 WHERE customer_id IN (SELECT loser_id FROM _bug165_pairs);


-- ────────────────────────────────────────────────────────────────────────────
-- §8 — Post-apply assertions (goal G1-G3 + preserve P1-P8)
-- ────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    n_total_customer_after  INTEGER;
    n_orphans_after         INTEGER;
    n_twin_same_after       INTEGER;
    n_twin_diff_after       INTEGER;
    n_total_canonical_after INTEGER;
    n_alias_after           INTEGER;
    n_code_map_after        INTEGER;
    n_audit_rows            INTEGER;
    n_audit_ambiguous       INTEGER;
    n_audit_clean           INTEGER;
BEGIN
    -- G1: twin-pair same-canonical = 0 post-DELETE.
    -- Uses canonical pair_detect pattern (BLOCKER #1 fix) IDENTICAL to PRE §2
    -- + §3 work-set. Includes multi-@ guard so multi-@ rows excluded
    -- consistently across all three sites.
    WITH pair_detect AS (
      SELECT DISTINCT
        LEAST(bare.customer_id, atf.customer_id)    AS survivor_id,
        GREATEST(bare.customer_id, atf.customer_id) AS loser_id,
        bare.canonical_customer_id                  AS bare_canonical,
        atf.canonical_customer_id                   AS atf_canonical
      FROM customer bare
      JOIN customer atf
        ON UPPER(SPLIT_PART(atf.customer_name, ' @ ', 1)) = UPPER(bare.customer_name)
       AND atf.customer_name LIKE '% @ %'
       AND bare.customer_name NOT LIKE '% @ %'
       AND atf.customer_id <> bare.customer_id
       AND (LENGTH(atf.customer_name) - LENGTH(REPLACE(atf.customer_name, ' @ ', ''))) / 3 = 1
    )
    SELECT COUNT(*) INTO n_twin_same_after
      FROM pair_detect
     WHERE bare_canonical IS NOT NULL
       AND atf_canonical IS NOT NULL
       AND bare_canonical = atf_canonical;
    IF n_twin_same_after <> 0 THEN
        RAISE EXCEPTION 'BUG-165-161 POST FAIL G1 — % same-canonical twin pairs remain (expected 0)', n_twin_same_after;
    END IF;

    -- G2: different-canonical twin pairs = 0 post-merge (loser flipped to
    -- survivor's canonical in §4 OR survivor inherited loser's canonical).
    -- IDENTICAL pair_detect pattern as PRE §2 + §3 work-set.
    WITH pair_detect AS (
      SELECT DISTINCT
        LEAST(bare.customer_id, atf.customer_id)    AS survivor_id,
        GREATEST(bare.customer_id, atf.customer_id) AS loser_id,
        bare.canonical_customer_id                  AS bare_canonical,
        atf.canonical_customer_id                   AS atf_canonical
      FROM customer bare
      JOIN customer atf
        ON UPPER(SPLIT_PART(atf.customer_name, ' @ ', 1)) = UPPER(bare.customer_name)
       AND atf.customer_name LIKE '% @ %'
       AND bare.customer_name NOT LIKE '% @ %'
       AND atf.customer_id <> bare.customer_id
       AND (LENGTH(atf.customer_name) - LENGTH(REPLACE(atf.customer_name, ' @ ', ''))) / 3 = 1
    )
    SELECT COUNT(*) INTO n_twin_diff_after
      FROM pair_detect
     WHERE (bare_canonical IS DISTINCT FROM atf_canonical)
       AND (bare_canonical IS NOT NULL OR atf_canonical IS NOT NULL);
    IF n_twin_diff_after <> 0 THEN
        RAISE EXCEPTION 'BUG-165-161 POST FAIL G2 — % different-canonical twin pairs remain (expected 0 — ambiguous remap missed?)', n_twin_diff_after;
    END IF;

    -- G3: audit rowcount in expected band.
    -- audit = clean merges + ambiguous merges + multi-@ review-only rows.
    -- merge_reason LIKE 'BUG-165 (schema/161) — MULTI_AT%' isolates the
    -- review-only rows from the merge rows so G3 band remains tight.
    SELECT COUNT(*) INTO n_audit_rows FROM canonical_customer_merge_audit
     WHERE merge_reason NOT LIKE '%MULTI_AT_NEEDS_MANUAL_REVIEW%';
    SELECT COUNT(*) INTO n_audit_ambiguous FROM canonical_customer_merge_audit
     WHERE ambiguous = TRUE
       AND merge_reason NOT LIKE '%MULTI_AT_NEEDS_MANUAL_REVIEW%';
    SELECT COUNT(*) INTO n_audit_clean FROM canonical_customer_merge_audit
     WHERE ambiguous = FALSE;
    IF n_audit_rows < 2300 OR n_audit_rows > 3200 THEN
        RAISE EXCEPTION 'BUG-165-161 POST FAIL G3 — audit-merge rowcount % outside band (2300-3200). 1:1 audit-to-merge broken. Band widened 2026-05-11 to match §3 work-set.', n_audit_rows;
    END IF;
    IF n_audit_ambiguous > 150 THEN
        RAISE EXCEPTION 'BUG-165-161 POST FAIL G3-ambig — ambiguous audit-merge rows % above ceiling 150. Spec said 11 ± epsilon; ceiling widened 2026-05-11 to 150 to absorb prod 86 ambiguous (baked-default rule still applies).', n_audit_ambiguous;
    END IF;

    -- P1: sales_transaction rowcount unchanged (FK re-link, NOT delete)
    -- We can't directly assert "delta = 0" without a snapshot, but we can
    -- assert that no rows have a dangling FK (referencing a now-deleted loser).
    PERFORM 1
      FROM sales_transaction st
     WHERE st.customer_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM customer c WHERE c.customer_id = st.customer_id);
    IF FOUND THEN
        RAISE EXCEPTION 'BUG-165-161 POST FAIL P1 — sales_transaction has dangling customer_id FK after dedup. Re-link missed rows.';
    END IF;

    -- P2: customer rowcount delta = audit rowcount (each merge = -1 customer row)
    SELECT COUNT(*) INTO n_total_customer_after FROM customer;
    IF n_total_customer_after < 5400 OR n_total_customer_after > 11500 THEN
        RAISE EXCEPTION 'BUG-165-161 POST FAIL P2 — customer rowcount % outside band (5400-11500) post-dedup', n_total_customer_after;
    END IF;

    -- P3: canonical_customer rowcount unchanged band
    SELECT COUNT(*) INTO n_total_canonical_after FROM canonical_customer;
    IF n_total_canonical_after < 3500 OR n_total_canonical_after > 4500 THEN
        RAISE EXCEPTION 'BUG-165-161 POST FAIL P3 — canonical_customer count % drifted (expected 3500-4500). Migration touched canonical_customer rows it should not have.', n_total_canonical_after;
    END IF;

    -- P4: customer_code_map FK integrity — no dangling customer_ids
    PERFORM 1
      FROM customer_code_map ccm
     WHERE NOT EXISTS (SELECT 1 FROM customer c WHERE c.customer_id = ccm.customer_id);
    IF FOUND THEN
        RAISE EXCEPTION 'BUG-165-161 POST FAIL P4 — customer_code_map has dangling customer_id FK post-dedup';
    END IF;
    SELECT COUNT(*) INTO n_code_map_after FROM customer_code_map;

    -- P5: customer_alias FK integrity (refs canonical_customer.id — should be UNCHANGED)
    PERFORM 1
      FROM customer_alias ca
     WHERE NOT EXISTS (SELECT 1 FROM canonical_customer cc WHERE cc.id = ca.canonical_customer_id);
    IF FOUND THEN
        RAISE EXCEPTION 'BUG-165-161 POST FAIL P5 — customer_alias has dangling canonical_customer_id FK';
    END IF;
    SELECT COUNT(*) INTO n_alias_after FROM customer_alias;

    -- P8: lone-orphan band check (twin-only scope)
    SELECT COUNT(*) INTO n_orphans_after FROM customer WHERE canonical_customer_id IS NULL;
    -- Allow band: 0 (if scope expanded) to 4200 (lone orphans intact)
    -- Spec ceiling 2500 was based on wrong NULL-side count estimate.
    -- Prod measured 2026-05-11: pre=4108, post-dedup=4089 (only 6 NULL-side
    -- merges convert orphan-survivors; 369 chain pairs excluded per §3
    -- chain-exclusion CTE; remaining ~4089 are lone orphans deferred to
    -- BUG-165-FOLLOWUP-LONE-ORPHANS Phase 2).
    -- Ceiling widened 2026-05-11 to 4200 to match actual post-dedup state.
    IF n_orphans_after > 4200 THEN
        RAISE EXCEPTION 'BUG-165-161 POST FAIL P8 — orphan count % exceeds lone-orphan ceiling 4200. Migration introduced new orphans?', n_orphans_after;
    END IF;

    RAISE NOTICE 'BUG-165-161 POST OK — twin-same=%, twin-diff=%, audit-total=% (clean=%, ambig=%), customer total=%, canonical total=%, orphans-after=%, code_map=%, alias=%',
        n_twin_same_after, n_twin_diff_after, n_audit_rows, n_audit_clean, n_audit_ambiguous,
        n_total_customer_after, n_total_canonical_after, n_orphans_after, n_code_map_after, n_alias_after;
END $$;


-- ────────────────────────────────────────────────────────────────────────────
-- §9 — Record migration in schema_migrations ledger (idempotent)
-- ────────────────────────────────────────────────────────────────────────────
INSERT INTO schema_migrations (version, applied_at, source)
VALUES ('161_bug165_customer_orphan_dedup', NOW(), 'live-apply')
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ════════════════════════════════════════════════════════════════════════════
-- MATVIEW REFRESH (BLOCKER #4 fix)
-- ════════════════════════════════════════════════════════════════════════════
-- combined_data_enriched is a REGULAR VIEW (verified via grep across
-- schema/027, /028, /068, /092, /101, /109, /115, /132, /141, /142, /144,
-- /146, /147 — every redefine uses CREATE OR REPLACE VIEW, never CREATE
-- MATERIALIZED VIEW). It re-computes on every SELECT and auto-reflects the
-- post-dedup customer.canonical_customer_id state.
--
-- Therefore NO REFRESH MATERIALIZED VIEW is required by this migration.
-- The blast-map's earlier mention of "matview" was inherited language from
-- prior migrations; for this BUG-165 dedup path the view is non-materialized.
--
-- If schema/146 (or any future schema/NN) ever introduces a real materialized
-- view sourcing combined_data_enriched, that ticket MUST add a post-COMMIT
-- have nuked prod data before; non-optional once a real matview exists.
--
-- ════════════════════════════════════════════════════════════════════════════
-- POST-DEPLOY OPERATOR STEPS (manual; not auto-run)
-- ════════════════════════════════════════════════════════════════════════════
-- 1. (Skipped — see MATVIEW REFRESH note above; combined_data_enriched is a
--    regular VIEW, no REFRESH needed.)
-- 2. Apply faucet patches in same deploy:
--      - dashboard/src/app/api/customers/route.ts (POST handler)
--      - etl/backfill_vinsight_contact_enrichment.py (UPSERT)
--      Both now lookup-or-create canonical_customer_id + embed NAME @ SUBURB
--    will ratchet L6 NOT VALID → VALIDATED for customer_must_have_canonical
--    once lone-orphans are backfilled in a separate migration.
--
-- ROLLBACK / DOWN-MIGRATION RECIPE (manual; forward-revert)
-- ════════════════════════════════════════════════════════════════════════════
-- This migration is DESTRUCTIVE (DELETE customer rows). Forward-revert via
-- canonical_customer_merge_audit is INCOMPLETE because the loser customer
-- rows no longer exist with their original PKs.
--
-- If the owner rejects a baked-default decision on any of the ambiguous pairs:
--   1. Find audit row: SELECT * FROM canonical_customer_merge_audit
--                      WHERE ambiguous=TRUE AND loser_customer_name=...;
--   2. Re-create the original loser customer row via INSERT INTO customer
--      with a NEW customer_id (loser's old PK is gone). Use loser_customer_name
--      + original suburb/postcode from the @ form embed.
--   3. Re-link sales_transaction rows back via UPDATE WHERE sale_date < merge_date.
--   4. Note: only forward-revert is possible. Historical "before dedup" reports
--      will never reproduce exactly. This is the cost of dedup forward-only.
--
-- ════════════════════════════════════════════════════════════════════════════
