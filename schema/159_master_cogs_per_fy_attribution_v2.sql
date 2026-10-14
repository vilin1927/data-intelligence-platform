-- ════════════════════════════════════════════════════════════════════════════
-- schema/159_master_cogs_per_fy_attribution_v2.sql
-- A8 v2 — FORWARD-FIX of schema/151 — backfill economic_cogs_per_unit via
--         master_cogs_canonical_map + FY_2024 fallback for FY_2025/FY_2026
-- ════════════════════════════════════════════════════════════════════════════
-- AUDIT-TABLE: master_cogs_a8_v2_audit  (per-row pre-UPDATE snapshot for forward-revert; see schema/160 or out-of-band rollback queries at bottom of this file)
-- FORWARD-FIX-OF: schema/151_master_cogs_per_fy_attribution.sql.DEFERRED (PRE assert §3 failed 2026-05-11; backfill row count 35 < floor 100)
--
-- Date:    2026-05-11
-- Ticket:  A8 v2 — recon_master_cogs.py 0 PASS / 636 FAIL forward-fix
-- Mode:    WRITE LOCAL ONLY
-- Predecessor:  schema/151 (DEFERRED — naming-gap + lock-guard mis-application root-caused 2026-05-11)
--
-- ════════════════════════════════════════════════════════════════════════════
-- WHY THIS V2 (root cause that v1 missed)
-- ════════════════════════════════════════════════════════════════════════════
-- schema/151 (v1) had TWO compounding failure modes:
--
-- 1. NAMING GAP — direct UPPER(sku_name) JOIN matched 72 of 105 master_cogs
--    SKUs. v2 uses master_cogs_canonical_map (schema/158) which seeds 97 of
--    105 via fuzzy normalization (high=74, medium=16, low=7). 8 master SKUs
--    intentionally unseeded — no canonical match. See schema/158 §METHODOLOGY.
--
-- 2. LOCK-DATE GUARD MIS-APPLIED — v1 filtered `economic_cogs_lock_date IS NULL`
--    to honor schema/026's What-If Apply 409 Conflict guard. But 120,872 of
--    121,052 sales_transaction rows (99.85%) have lock_date populated via
--    schema/074 BUG-112 closed-period backfill — so v1 only backfilled 35
--    rows in OPEN periods (2026-03 + 2026-04). The lock semantics scope per
--    schema/026 line 7-12 is "What-If Apply refuses to mutate" (user-driven
--    grape-price recalculation), NOT "HARD-source first-time backfill must
--    skip". A8 is HARD-source from Access tbl_Master_COGS — the authoritative
--    market-COGS register. Lock-guard scope expansion to A8 = mis-application.
--
-- v2 fix: DROP the lock-guard filter for the master_cogs backfill path. Keep
-- What-If Apply guard untouched (no lock_date toggle in this migration; trigger
-- fn_reject_closed_period unchanged). schema/026 + schema/074 lock semantics
-- preserved for user-driven What-If path.
--
-- ════════════════════════════════════════════════════════════════════════════
-- ════════════════════════════════════════════════════════════════════════════
--   1. May 8 Vladimir + the owner verbal — out of scope (no per-FY COGS change)
--   2. DOCX paragraph 0647 (Apr 11) — out of scope
--   3. Apr 13 feedback — Vinsight nominated price ≠ market COGS; this migration
--      aligns
--   4. master_cogs (schema/099 / Access tbl_Master_COGS Apr 28) — THIS source
--   5. xlsx 'New DB SKU report' Mar 24 baseline — corroborates master_cogs
--   6. Vinsight transfer_cost — fallback only (current 51.66 source)
--
-- ════════════════════════════════════════════════════════════════════════════
-- BLAST RADIUS
-- ════════════════════════════════════════════════════════════════════════════
-- Reads:    master_cogs (636 rows), master_cogs_canonical_map (~97 rows),
--           canonical_sku (136 rows), sku, sales_transaction (121,052 rows)
-- Writes:   sales_transaction.economic_cogs_per_unit, .economic_cogs_total
--           (target: ≥500 rows; estimate 30K-80K based on FY coverage × seed
--           coverage × active SKU sales volume)
--           master_cogs_a8_v2_audit (per-row audit log of pre/post values)
-- Unwritten: lock_date / vintage cols / sku_id / customer_id / channel_id /
--           sale_date / quantity / unit_price / net_revenue / content_hash
-- content_hash invariance: per BUG-113, hash basis excludes
--           economic_cogs_per_unit + economic_cogs_total. Hash byte-identical
--           post-update → ON CONFLICT idempotency preserved across all writers.
-- What-If preserved: schema/026 trigger fn_reject_closed_period unchanged.
--           A8-v2 does NOT toggle economic_cogs_lock_date.
--
-- Estimate basis (Vladimir-reviewable):
--   - High-confidence seed (74 rows) × avg 3 active FYs of sales × ~500
--     transactions/(SKU×FY) = ~111K row writes in best case
--   - Conservative real-world: ~30K-50K rows after dedup + locked-row carry
--   - Floor: 500 rows (PRE-assert §3)
--
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ────────────────────────────────────────────────────────────────────────────
-- §1 PRE-asserts
-- ────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    v_master_count       INT;
    v_st_count           INT;
    v_baseline_5166      INT;
    v_canonical_count    INT;
    v_map_count          INT;
    v_map_high_count     INT;
    v_table_audit_exists BOOLEAN;
BEGIN
    -- Required tables present
    IF NOT EXISTS (SELECT 1 FROM information_schema.tables
                   WHERE table_schema='public' AND table_name='master_cogs') THEN
        RAISE EXCEPTION 'A8-159 PRE FAIL: master_cogs table missing — schema/099 must land first';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.tables
                   WHERE table_schema='public' AND table_name='sales_transaction') THEN
        RAISE EXCEPTION 'A8-159 PRE FAIL: sales_transaction table missing';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.tables
                   WHERE table_schema='public' AND table_name='canonical_sku') THEN
        RAISE EXCEPTION 'A8-159 PRE FAIL: canonical_sku table missing';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.tables
                   WHERE table_schema='public' AND table_name='sku') THEN
        RAISE EXCEPTION 'A8-159 PRE FAIL: sku table missing';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.tables
                   WHERE table_schema='public' AND table_name='master_cogs_canonical_map') THEN
        RAISE EXCEPTION 'A8-159 PRE FAIL: master_cogs_canonical_map missing — schema/157 + schema/158 must apply first';
    END IF;

    -- Row count sanity bands
    SELECT count(*) INTO v_master_count FROM master_cogs;
    IF v_master_count NOT BETWEEN 600 AND 700 THEN
        RAISE EXCEPTION 'A8-159 PRE FAIL: master_cogs count % outside band 600-700 (HARD baseline 636)', v_master_count;
    END IF;

    SELECT count(*) INTO v_st_count FROM sales_transaction;
    IF v_st_count < 100000 THEN
        RAISE EXCEPTION 'A8-159 PRE FAIL: sales_transaction count % below floor 100000', v_st_count;
    END IF;

    SELECT count(*) INTO v_baseline_5166 FROM sales_transaction WHERE economic_cogs_per_unit = 51.66;
    IF v_baseline_5166 < 1000 THEN
        RAISE EXCEPTION 'A8-159 PRE FAIL: 51.66 baseline rows % below floor 1000 — symptom may have already flipped or schema/016 not applied', v_baseline_5166;
    END IF;

    SELECT count(*) INTO v_canonical_count FROM canonical_sku;
    IF v_canonical_count < 50 THEN
        RAISE EXCEPTION 'A8-159 PRE FAIL: canonical_sku count % below floor 50', v_canonical_count;
    END IF;

    SELECT count(*), count(*) FILTER (WHERE confidence='high')
      INTO v_map_count, v_map_high_count
      FROM master_cogs_canonical_map;
    IF v_map_count < 90 THEN
        RAISE EXCEPTION 'A8-159 PRE FAIL: map seed count % below floor 90 — schema/158 may not have applied fully', v_map_count;
    END IF;
    IF v_map_high_count < 50 THEN
        RAISE EXCEPTION 'A8-159 PRE FAIL: map high-confidence count % below floor 50', v_map_high_count;
    END IF;

    RAISE NOTICE 'A8-159 PRE OK — master_cogs=%, sales_transaction=%, 51.66 rows=%, canonical_sku=%, map total=% (high=%)',
        v_master_count, v_st_count, v_baseline_5166, v_canonical_count, v_map_count, v_map_high_count;

    -- Stash invariants for POST cross-check
    CREATE TEMP TABLE _a8v2_invariant (
        master_count_pre     INT,
        st_count_pre         INT,
        baseline_5166_pre    INT,
        map_count_pre        INT,
        canonical_count_pre  INT
    );
    INSERT INTO _a8v2_invariant
    VALUES (v_master_count, v_st_count, v_baseline_5166, v_map_count, v_canonical_count);
END $$;

-- ────────────────────────────────────────────────────────────────────────────
-- §2 Audit table (forward-revert preservation)
-- ────────────────────────────────────────────────────────────────────────────
-- Stores pre-UPDATE economic_cogs_per_unit + economic_cogs_total per transaction
-- this migration touches. Idempotent CREATE IF NOT EXISTS; INSERTs only.
CREATE TABLE IF NOT EXISTS master_cogs_a8_v2_audit (
    transaction_id          BIGINT PRIMARY KEY,
    pre_cogs_per_unit       NUMERIC(12,4),
    pre_cogs_total          NUMERIC(12,4),
    post_cogs_per_unit      NUMERIC(12,4) NOT NULL,
    post_cogs_total         NUMERIC(12,4) NOT NULL,
    canonical_sku_id        INT,
    canonical_sku_name      TEXT,
    fy                      TEXT,
    master_sku              TEXT,
    confidence              TEXT,
    fy_fallback             BOOLEAN NOT NULL DEFAULT FALSE,
    applied_at              TIMESTAMP NOT NULL DEFAULT now()
);

COMMENT ON TABLE master_cogs_a8_v2_audit IS
    'A8 v2 — per-transaction pre/post snapshot for forward-revert. Used if Vladimir DELETEs a mapping row and wants to undo backfill on affected transactions.';

CREATE INDEX IF NOT EXISTS idx_a8v2_audit_canonical
    ON master_cogs_a8_v2_audit(canonical_sku_id);
CREATE INDEX IF NOT EXISTS idx_a8v2_audit_master
    ON master_cogs_a8_v2_audit(master_sku);

-- ────────────────────────────────────────────────────────────────────────────
-- §3 Build temp _cogs_backfill — one row per sales_transaction with COGS to apply
-- ────────────────────────────────────────────────────────────────────────────
--   FY_YYYY where YYYY = year+1 if month>=7 else year
--
-- Two-stage CTE:
--   1. _fy_target — every sales_transaction with canonical_sku + computed FY.
--   2. _master_lookup — JOIN master_cogs via map, prefer exact-FY match, fall
--      back to FY_2024 for FY_2025+FY_2026 rows where master_cogs has no row.
--
-- Lock-guard NOT applied here (v2 fix): A8 is HARD-source first-time backfill,
-- not What-If user mutation. schema/026 + trigger fn unchanged; What-If Apply
-- still 409-Conflicts on user POSTs.
--
-- Idempotency: re-run skips rows where pre_value already = target value via
-- `IS DISTINCT FROM` in §4 UPDATE.
--
-- DISTINCT ON (transaction_id): handles duplicate master_cogs rows (Atrius
-- Shiraz × 6 FYs × 2 dup rows per FY); IDENTICAL cogs_value 58.13 so tie-break
-- safe; ORDER BY canonical_sku_id, mc_id is deterministic.

CREATE TEMP TABLE _cogs_backfill ON COMMIT DROP AS
WITH _fy_target AS (
    SELECT
        st.transaction_id,
        st.quantity,
        st.economic_cogs_per_unit                 AS pre_cogs,
        st.economic_cogs_total                    AS pre_total,
        cs.id                                     AS canonical_sku_id,
        cs.sku_name                               AS canonical_sku_name,
        'FY_' || (CASE WHEN EXTRACT(MONTH FROM st.sale_date) >= 7
                       THEN (EXTRACT(YEAR FROM st.sale_date) + 1)::int
                       ELSE  EXTRACT(YEAR FROM st.sale_date)::int
                  END)::text                     AS fy
      FROM sales_transaction st
      JOIN sku           s  ON s.sku_id = st.sku_id
      JOIN canonical_sku cs ON cs.id    = s.canonical_sku_id
),
_master_lookup AS (
    -- Stage A: exact-FY match via map
    SELECT
        f.transaction_id,
        f.quantity,
        f.pre_cogs,
        f.pre_total,
        f.canonical_sku_id,
        f.canonical_sku_name,
        f.fy,
        m.master_sku,
        m.confidence,
        mc.id                  AS mc_id,
        mc.cogs_value          AS cogs_value,
        FALSE                  AS fy_fallback
      FROM _fy_target f
      JOIN master_cogs_canonical_map m  ON m.canonical_sku_id = f.canonical_sku_id
      JOIN master_cogs mc                ON mc.sku = m.master_sku
                                         AND mc.financial_year = f.fy
                                         AND mc.cogs_value IS NOT NULL
                                         AND mc.cogs_value > 0
    UNION ALL
    -- Stage B: FY_2024 fallback for FY_2025/FY_2026 rows (master_cogs ends FY_2024)
    SELECT
        f.transaction_id,
        f.quantity,
        f.pre_cogs,
        f.pre_total,
        f.canonical_sku_id,
        f.canonical_sku_name,
        f.fy,
        m.master_sku,
        m.confidence,
        mc.id                  AS mc_id,
        mc.cogs_value          AS cogs_value,
        TRUE                   AS fy_fallback
      FROM _fy_target f
      JOIN master_cogs_canonical_map m  ON m.canonical_sku_id = f.canonical_sku_id
      JOIN master_cogs mc                ON mc.sku = m.master_sku
                                         AND mc.financial_year = 'FY_2024'
                                         AND mc.cogs_value IS NOT NULL
                                         AND mc.cogs_value > 0
     WHERE f.fy IN ('FY_2025','FY_2026')
       AND NOT EXISTS (
           -- Skip rows already covered by Stage A
           SELECT 1 FROM master_cogs mc2
            WHERE mc2.sku = m.master_sku
              AND mc2.financial_year = f.fy
              AND mc2.cogs_value IS NOT NULL
              AND mc2.cogs_value > 0
       )
)
SELECT DISTINCT ON (transaction_id)
       transaction_id, quantity, pre_cogs, pre_total,
       canonical_sku_id, canonical_sku_name, fy,
       master_sku, confidence, cogs_value, fy_fallback
  FROM _master_lookup
 ORDER BY transaction_id, fy_fallback, mc_id;  -- exact-FY (fy_fallback=FALSE) wins over fallback

CREATE INDEX ON _cogs_backfill (transaction_id);

-- ────────────────────────────────────────────────────────────────────────────
-- §4 Pre-UPDATE assert: backfill row count in target band
-- ────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    v_backfill_count       INT;
    v_backfill_high_only   INT;
    v_backfill_fy_fallback INT;
    v_distinct_canonical   INT;
    v_distinct_fys         INT;
BEGIN
    SELECT count(*),
           count(*) FILTER (WHERE confidence='high'),
           count(*) FILTER (WHERE fy_fallback),
           count(DISTINCT canonical_sku_id),
           count(DISTINCT fy)
      INTO v_backfill_count, v_backfill_high_only, v_backfill_fy_fallback, v_distinct_canonical, v_distinct_fys
      FROM _cogs_backfill;

    -- Expected band: 500 floor (loose) ... 150000 ceiling
    -- v1 used 100 floor (tight) — v2 retargets per task spec (≥500)
    IF v_backfill_count < 500 THEN
        RAISE EXCEPTION 'A8-159 §4 FAIL: backfill row count % below floor 500 — investigate (likely seed coverage gap, FY formula drift, or upstream sku.canonical_sku_id NULLs). Pre-deploy expected ≥ 30000.',
            v_backfill_count;
    END IF;
    IF v_backfill_count > 150000 THEN
        RAISE EXCEPTION 'A8-159 §4 FAIL: backfill row count % above ceiling 150000 — temp build likely fanned out via JOIN bug',
            v_backfill_count;
    END IF;
    IF v_distinct_canonical < 10 THEN
        RAISE EXCEPTION 'A8-159 §4 FAIL: only % distinct canonical_sku matched (expected ≥10) — map seed likely empty for active SKUs',
            v_distinct_canonical;
    END IF;

    RAISE NOTICE 'A8-159 §4 OK — backfill rows=%  (high-confidence=%, FY-fallback=%)  distinct_canonical=%  distinct_fys=%',
        v_backfill_count, v_backfill_high_only, v_backfill_fy_fallback, v_distinct_canonical, v_distinct_fys;
END $$;

-- ────────────────────────────────────────────────────────────────────────────
-- §5 Audit log INSERT (snapshot pre-UPDATE values)
-- ────────────────────────────────────────────────────────────────────────────
-- ON CONFLICT preserves first-write audit row (forward-revert source of truth).
INSERT INTO master_cogs_a8_v2_audit
    (transaction_id, pre_cogs_per_unit, pre_cogs_total,
     post_cogs_per_unit, post_cogs_total,
     canonical_sku_id, canonical_sku_name, fy,
     master_sku, confidence, fy_fallback)
SELECT b.transaction_id,
       b.pre_cogs,
       b.pre_total,
       b.cogs_value,
       b.cogs_value * b.quantity,
       b.canonical_sku_id,
       b.canonical_sku_name,
       b.fy,
       b.master_sku,
       b.confidence,
       b.fy_fallback
  FROM _cogs_backfill b
 WHERE b.pre_cogs IS DISTINCT FROM b.cogs_value
ON CONFLICT (transaction_id) DO NOTHING;

-- ────────────────────────────────────────────────────────────────────────────
-- §6 UPDATE economic_cogs_per_unit + economic_cogs_total in sync
-- ────────────────────────────────────────────────────────────────────────────
-- Idempotency: `IS DISTINCT FROM b.cogs_value` ensures re-run after success
--              matches 0 rows.
-- Lock-guard NOT applied: v2 fix (see §WHY THIS V2). What-If guard preserved
--              via schema/026 + schema/074 unchanged.
-- economic_cogs_total derived from cogs_value × b.quantity (snapshot at temp-
--              table build time; sales_transaction.quantity unchanged in this
--              migration — single-row consistency preserved).
UPDATE sales_transaction SET economic_cogs_per_unit = b.cogs_value,
                              economic_cogs_total    = b.cogs_value * b.quantity
  FROM _cogs_backfill b
 WHERE sales_transaction.transaction_id = b.transaction_id
   AND sales_transaction.economic_cogs_per_unit IS DISTINCT FROM b.cogs_value;

-- ────────────────────────────────────────────────────────────────────────────
-- §7 POST-asserts
-- ────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    v_post_st_count        INT;
    v_pre_st_count         INT;
    v_post_5166_count      INT;
    v_pre_5166_count       INT;
    v_distinct_cogs_post   INT;
    v_pending_flips        INT;
    v_audit_row_count      INT;
    v_changed_count        INT;
BEGIN
    SELECT st_count_pre, baseline_5166_pre
      INTO v_pre_st_count, v_pre_5166_count
      FROM _a8v2_invariant;

    -- a) Row count preserve invariant (UPDATE only; no INSERT/DELETE)
    SELECT count(*) INTO v_post_st_count FROM sales_transaction;
    IF v_post_st_count <> v_pre_st_count THEN
        RAISE EXCEPTION 'A8-159 POST FAIL: sales_transaction row count drift % → %', v_pre_st_count, v_post_st_count;
    END IF;

    -- b) 51.66 baseline rows must NOT grow (UPDATE goes 51.66 → master_cogs value)
    SELECT count(*) INTO v_post_5166_count
      FROM sales_transaction WHERE economic_cogs_per_unit = 51.66;
    IF v_post_5166_count > v_pre_5166_count THEN
        RAISE EXCEPTION 'A8-159 POST FAIL: 51.66 row count grew (% → %) — UPDATE introduced new 51.66s',
            v_pre_5166_count, v_post_5166_count;
    END IF;

    -- c) Pending flips check (UPDATE applied correctly)
    SELECT count(*) INTO v_pending_flips
      FROM sales_transaction st
      JOIN _cogs_backfill b ON b.transaction_id = st.transaction_id
     WHERE st.economic_cogs_per_unit IS DISTINCT FROM b.cogs_value;
    IF v_pending_flips > 0 THEN
        RAISE EXCEPTION 'A8-159 POST FAIL: % rows in _cogs_backfill still mismatch after UPDATE',
            v_pending_flips;
    END IF;

    -- d) Distinct cogs values increased (per-FY variance introduced)
    SELECT count(DISTINCT economic_cogs_per_unit) INTO v_distinct_cogs_post
      FROM sales_transaction WHERE economic_cogs_per_unit IS NOT NULL;
    IF v_distinct_cogs_post < 5 THEN
        RAISE EXCEPTION 'A8-159 POST FAIL: distinct cogs values=% (expected ≥5)', v_distinct_cogs_post;
    END IF;

    -- e) Audit row count = rows where pre != post
    SELECT count(*) INTO v_audit_row_count FROM master_cogs_a8_v2_audit;
    SELECT count(*) INTO v_changed_count
      FROM _cogs_backfill b
     WHERE b.pre_cogs IS DISTINCT FROM b.cogs_value;
    IF v_audit_row_count < v_changed_count THEN
        RAISE EXCEPTION 'A8-159 POST FAIL: audit rows=% < expected changed_count=%',
            v_audit_row_count, v_changed_count;
    END IF;

    RAISE NOTICE 'A8-159 POST OK — st_count=% (unchanged), 51.66 rows %→%, distinct cogs=%, audit rows=%, no pending flips',
        v_post_st_count, v_pre_5166_count, v_post_5166_count,
        v_distinct_cogs_post, v_audit_row_count;
END $$;

-- ────────────────────────────────────────────────────────────────────────────
-- §8 schema_migrations ledger insert
-- ────────────────────────────────────────────────────────────────────────────
INSERT INTO schema_migrations (version, applied_at, source)
VALUES ('159_master_cogs_per_fy_attribution_v2', now(), 'live-apply')
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ════════════════════════════════════════════════════════════════════════════
-- ROLLBACK PLAN (out-of-band, post-COMMIT)
-- ════════════════════════════════════════════════════════════════════════════
-- In-transaction failure auto-rolls back via RAISE EXCEPTION.
--
-- Post-COMMIT forward-revert via audit table:
--
--   BEGIN;
--   UPDATE sales_transaction st
--      SET economic_cogs_per_unit = a.pre_cogs_per_unit,
--          economic_cogs_total    = a.pre_cogs_total
--     FROM master_cogs_a8_v2_audit a
--    WHERE st.transaction_id = a.transaction_id
--      AND a.pre_cogs_per_unit IS NOT NULL;
--   DELETE FROM schema_migrations WHERE version = '159_master_cogs_per_fy_attribution_v2';
--   -- Optionally: DROP TABLE master_cogs_a8_v2_audit; (lose forward-revert source)
--   COMMIT;
--
-- Per-mapping rollback (e.g. Vladimir rejects a low-confidence map row):
--
--   BEGIN;
--   UPDATE sales_transaction st
--      SET economic_cogs_per_unit = a.pre_cogs_per_unit,
--          economic_cogs_total    = a.pre_cogs_total
--     FROM master_cogs_a8_v2_audit a
--    WHERE st.transaction_id = a.transaction_id
--      AND a.master_sku = '<sku to revert>';
--   DELETE FROM master_cogs_canonical_map WHERE master_sku = '<sku to revert>';
--   DELETE FROM master_cogs_a8_v2_audit WHERE master_sku = '<sku to revert>';
--   COMMIT;
--
-- Full restore: psql ${DATABASE_URL} -f /var/backups/moppity/pre_a8v2_<date>.pgdump
-- ════════════════════════════════════════════════════════════════════════════
