-- ════════════════════════════════════════════════════════════════════════════
-- schema/178_feb2026_st_territory_id_backfill.sql
-- Backfill sales_transaction.territory_id for Feb 2026 ALM + DWS rows where
-- territory_id is currently NULL (293 ALM + 270 DWS = 563 rows total).
-- ════════════════════════════════════════════════════════════════════════════
-- Date: 2026-05-20
-- Trust contract: v1 (HARD-SOURCE, DESTRUCTIVE-CONTROLLED, AUDIT-TABLE,
--                     CITATION-PER-ROW-CLASS, FORWARD-ONLY, ATOMIC-TXN)
-- CITATION: per-row resolution path (sales_transaction.customer_id → canonical_customer.territory_name → territory) recorded in schema_178_st_territory_backfill_audit
-- AUDIT-TABLE: schema_178_st_territory_backfill_audit (one row per UPDATE; manual rollback recipe in this header below)
--
-- WHY THIS EXISTS
-- ---------------
-- 2026-04-14 ingestion of Feb 2026 ALM + DWS monthly files landed 293 ALM
-- (100%) + 270 DWS (100%) rows in sales_transaction with territory_id NULL.
-- ALM/DWS upstream files carry customer codes but not territory; the ingest
-- path failed to resolve territory_id from the customer's joined record.
-- This caused L9 Q[A7] (MQT by territory/channel AI smoke) to non-
-- deterministically exhaust step budget on territory-COALESCE probe queries
-- — root cause documented in audit doc 13. The fix is to backfill territory_id
-- on those Feb rows from the authoritative source: the customer's
-- canonical_customer.territory_name resolved to territory.territory_id by
-- name (case-trim insensitive — territory.uq_territory_name + idx
-- territory_name_lower already enforce uniqueness).
--
-- HARD SOURCE PER ROW
-- -------------------
-- For every Feb-2026 ALM/DWS sales_transaction row st with territory_id NULL,
-- the recovered territory_id derives from:
--   sales_transaction.customer_id
--     → customer.canonical_customer_id
--       → canonical_customer.territory_name
--         → territory.territory_name (case-trim normalised) → territory_id
--
-- This is the same path the dashboard /api/sales territory grouping uses, and
-- the same path the AI tool's get_sales_by_territory follows internally. It
-- aligns reads (which join through canonical_customer.territory_name) with
-- the writer-side cached FK column sales_transaction.territory_id.
--
-- here as the ANSWER source — its territory_name (populated by schema/177
-- This migration COPIES that canonical territory back onto the cached FK on
-- sales_transaction.
--
-- DEPENDENCY: schema/177 MUST APPLY FIRST
-- ---------------------------------------
-- schema/177 backfills the canonical territory NULL backlog (78 ids, incl.
-- the DWS-UNATTRIBUTED sentinel cc_id=4124 which alone accounts for 71 of
-- the 563 Feb 2026 ALM/DWS NULL sales_transactions). Without 177 having
-- landed first, this migration recovers only 462/563 sales_transaction
-- rows. With 177 applied, recovery is 538/563.
--
-- Residual 25 rows that stay NULL after this migration = sales_transactions
-- referencing the 5 schema/176 dedup-deleted canonical_customer rows
-- (cc_id IN (4038, 4039, 4041, 4042, 4043)) which schema/177 deliberately
-- skips per "do not resurrect" rule. Breakdown:
--     cc 4038 CUSTOMER 100 & LCL LI      10 rows
--     cc 4039 CUSTOMER 101 MORUYA               4 rows
--     cc 4041 CUSTOMER 26 NEW     1 row
--     cc 4042 STRANGE ALCHEMY BOTTLE SH       4 rows
--     cc 4043 CUSTOMER 102 MELBA          6 rows
--                                             ----
--                                            25 rows
-- These 25 sales_transactions point to dedup-deleted canonical rows whose
-- live equivalents already absorbed any reattributions in schema/176. They
-- remain territory-NULL until a future ingest re-maps customer_id to the
-- surviving canonical row. NOT a the owner ask; documented residual.
--
-- AUDIT TABLE
-- -----------
-- NEW table: schema_178_st_territory_backfill_audit
-- One row per UPDATEd sales_transaction. Shape kept minimal — sales_tx FK,
-- prev (NULL by precondition), new territory_id, applied_at. No reason text
-- per row (all rows share one reason — this migration's header). Bulk audit
-- pattern reused from schema_175_customer_ingest_audit (single-purpose,
-- single-pass audit table).
--
-- FORWARD-ONLY & ADDITIVE
-- -----------------------
-- Only UPDATEs sales_transaction.territory_id on the 538 matched rows; only
-- INSERTs into the new audit table. No DROPs, no DELETEs, no ALTERs on
-- sales_transaction core columns. Atomic transaction. If any row fails the
-- migration aborts and prior rows roll back.
--
-- BLAST RADIUS
-- ------------
-- Affected rows: 538 of ~725,000 sales_transaction rows (<0.1%). No
-- downstream view rebuilds required — combined_data_enriched matview
-- already derives territory via the same canonical join, so refresh will
-- pick up the new FK on next nightly refresh (idempotent).
--
-- EXPECTED POST-STATE
-- -------------------
--   sales_transaction Feb 2026 ALM+DWS WHERE territory_id IS NULL
--     = 25 rows (the dedup-deleted residual documented above)
--   schema_178_st_territory_backfill_audit row count
--     = 538
--
-- PRE/POST ASSERTIONS
-- -------------------
-- PRE  — total Feb 2026 ALM+DWS NULL count must be in [550, 580]
-- PRE  — schema/177 must have applied (canonical NULL count <= 30)
-- POST — exactly 25 rows remain unbackfilled (dedup-deleted residual)
-- POST — exactly 538 rows in audit table
-- POST — every audit row corresponds to a previously-NULL sales_transaction
--        whose territory_id is now non-NULL
--
-- ROLLBACK RECIPE (manual; not auto-run)
-- --------------------------------------
-- BEGIN;
--   UPDATE sales_transaction st SET territory_id = NULL
--     FROM schema_178_st_territory_backfill_audit a
--    WHERE st.transaction_id = a.sales_transaction_id;
--   DROP TABLE schema_178_st_territory_backfill_audit;
--   DELETE FROM schema_migrations
--    WHERE version = '178_feb2026_st_territory_id_backfill';
-- COMMIT;
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ────────────────────────────────────────────────────────────────────────────
-- 1. Pre-apply assertions
-- ────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    v_null_count           INT;
    v_cc_null_count        INT;
    v_audit_table_exists   BOOL;
    v_schema_177_applied   BOOL;
BEGIN
    -- Hard-fail if this migration has already been applied (idempotency).
    SELECT to_regclass('public.schema_178_st_territory_backfill_audit') IS NOT NULL
      INTO v_audit_table_exists;
    IF v_audit_table_exists THEN
        RAISE EXCEPTION
          'schema/178 PRE: audit table already exists — migration already applied; refuse to re-run';
    END IF;

    -- Confirm Feb 2026 ALM+DWS NULL count is in expected envelope.
    SELECT COUNT(*) INTO v_null_count
      FROM sales_transaction
     WHERE territory_id IS NULL
       AND sale_date >= '2026-02-01' AND sale_date < '2026-03-01'
       AND source_system IN ('ALM','DWS');
    IF v_null_count NOT BETWEEN 550 AND 580 THEN
        RAISE EXCEPTION
          'schema/178 PRE: expected 550-580 Feb-2026 ALM+DWS NULL territory_id rows, got %; prod drift — re-scout',
          v_null_count;
    END IF;

    -- Confirm schema/177 has landed (canonical_customer NULL count should be
    -- <= 30: 7 dedup-deleted intentional + small slack for new ingests).
    -- If schema/177 not yet applied the count is ~78 and this migration's
    -- recovery rate drops materially; refuse to apply.
    SELECT COUNT(*) INTO v_cc_null_count
      FROM canonical_customer
     WHERE territory_name IS NULL
       AND is_deleted = FALSE;
    IF v_cc_null_count > 30 THEN
        RAISE EXCEPTION
          'schema/178 PRE: canonical_customer.territory_name has % NULL active rows (>30); schema/177 must apply first',
          v_cc_null_count;
    END IF;

    -- Sanity: territory table has the expected name targets the join relies on.
    PERFORM 1 FROM territory
      WHERE lower(trim(territory_name)) = 'head office';
    IF NOT FOUND THEN
        RAISE EXCEPTION
          'schema/178 PRE: territory ''Head Office'' missing from territory table';
    END IF;

    RAISE NOTICE 'schema/178 PRE: % Feb-2026 ALM+DWS NULL territory_id rows, % NULL canonical rows (post-177); proceeding',
                 v_null_count, v_cc_null_count;
END $$;


-- ────────────────────────────────────────────────────────────────────────────
-- 2. Audit table: one row per UPDATEd sales_transaction
-- ────────────────────────────────────────────────────────────────────────────
CREATE TABLE schema_178_st_territory_backfill_audit (
    sales_transaction_id INTEGER       NOT NULL,
    prev_territory_id    INTEGER,      -- expected NULL by precondition
    new_territory_id     INTEGER       NOT NULL,
    applied_at           TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    CONSTRAINT schema_178_audit_pk PRIMARY KEY (sales_transaction_id),
    CONSTRAINT schema_178_audit_st_fk FOREIGN KEY (sales_transaction_id)
        REFERENCES sales_transaction(transaction_id),
    CONSTRAINT schema_178_audit_new_terr_fk FOREIGN KEY (new_territory_id)
        REFERENCES territory(territory_id),
    CONSTRAINT schema_178_audit_prev_null CHECK (prev_territory_id IS NULL)
);

COMMENT ON TABLE schema_178_st_territory_backfill_audit IS
  'Audit trail for schema/178. One row per Feb-2026 ALM/DWS sales_transaction whose territory_id was backfilled from canonical_customer.territory_name -> territory.territory_id. Apply date 2026-05-20.';


-- ────────────────────────────────────────────────────────────────────────────
-- 3. Stage the recoverable set into a temp table (deterministic snapshot)
-- ────────────────────────────────────────────────────────────────────────────
CREATE TEMP TABLE tmp_178_backfill ON COMMIT DROP AS
SELECT
    st.transaction_id        AS sales_transaction_id,
    t.territory_id           AS new_territory_id
FROM sales_transaction st
JOIN customer c
  ON st.customer_id = c.customer_id
JOIN canonical_customer cc
  ON c.canonical_customer_id = cc.id
JOIN territory t
  ON lower(trim(t.territory_name)) = lower(trim(cc.territory_name))
WHERE st.territory_id IS NULL
  AND st.sale_date >= '2026-02-01' AND st.sale_date < '2026-03-01'
  AND st.source_system IN ('ALM','DWS')
  AND cc.territory_name IS NOT NULL;

-- Sanity: cardinality 1:1 (no transaction matches multiple territories).
DO $$
DECLARE
    v_total_rows    INT;
    v_distinct_st   INT;
BEGIN
    SELECT COUNT(*), COUNT(DISTINCT sales_transaction_id)
      INTO v_total_rows, v_distinct_st
      FROM tmp_178_backfill;
    IF v_total_rows <> v_distinct_st THEN
        RAISE EXCEPTION
          'schema/178: join cardinality broken — % rows for % distinct sales_transactions; abort',
          v_total_rows, v_distinct_st;
    END IF;
    RAISE NOTICE 'schema/178: staged % rows for backfill', v_total_rows;
END $$;


-- ────────────────────────────────────────────────────────────────────────────
-- 4. Insert audit rows BEFORE UPDATE (records the prev=NULL state)
-- ────────────────────────────────────────────────────────────────────────────
INSERT INTO schema_178_st_territory_backfill_audit
    (sales_transaction_id, prev_territory_id, new_territory_id, applied_at)
SELECT
    b.sales_transaction_id,
    NULL,
    b.new_territory_id,
    NOW()
FROM tmp_178_backfill b;


-- ────────────────────────────────────────────────────────────────────────────
-- 5. Single SET-based UPDATE on sales_transaction
-- ────────────────────────────────────────────────────────────────────────────
UPDATE sales_transaction st
   SET territory_id = b.new_territory_id
  FROM tmp_178_backfill b
 WHERE st.transaction_id = b.sales_transaction_id
   AND st.territory_id IS NULL;  -- defensive: only flip if still NULL


-- ────────────────────────────────────────────────────────────────────────────
-- 6. Post-apply assertions
-- ────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    v_remaining_null   INT;
    v_audit_rows       INT;
    v_audit_orphans    INT;
BEGIN
    SELECT COUNT(*) INTO v_remaining_null
      FROM sales_transaction
     WHERE territory_id IS NULL
       AND sale_date >= '2026-02-01' AND sale_date < '2026-03-01'
       AND source_system IN ('ALM','DWS');

    -- Expected: 25 rows tied to dedup-deleted canonical_customer ids
    -- (4038, 4039, 4041, 4042, 4043). Allow [20, 30] for small slack.
    IF v_remaining_null NOT BETWEEN 20 AND 30 THEN
        RAISE EXCEPTION
          'schema/178 POST: expected ~25 residual NULL rows (dedup-deleted), got %',
          v_remaining_null;
    END IF;

    SELECT COUNT(*) INTO v_audit_rows
      FROM schema_178_st_territory_backfill_audit;

    -- Expected audit count = original NULL count - residual = ~538. Allow
    -- [530, 545] for envelope.
    IF v_audit_rows NOT BETWEEN 530 AND 545 THEN
        RAISE EXCEPTION
          'schema/178 POST: audit rows = % (expected ~538)',
          v_audit_rows;
    END IF;

    -- Every audit row must point to a sales_transaction that now has the
    -- recorded territory_id (sanity that the UPDATE took effect).
    SELECT COUNT(*) INTO v_audit_orphans
      FROM schema_178_st_territory_backfill_audit a
      JOIN sales_transaction st
        ON st.transaction_id = a.sales_transaction_id
     WHERE st.territory_id IS DISTINCT FROM a.new_territory_id;
    IF v_audit_orphans <> 0 THEN
        RAISE EXCEPTION
          'schema/178 POST: % audit rows do not match sales_transaction.territory_id',
          v_audit_orphans;
    END IF;

    RAISE NOTICE 'schema/178 POST: OK — % rows backfilled, % residual NULL (dedup-deleted)',
                 v_audit_rows, v_remaining_null;
END $$;


-- ────────────────────────────────────────────────────────────────────────────
-- 7. Record migration in schema_migrations ledger (idempotent)
-- ────────────────────────────────────────────────────────────────────────────
INSERT INTO schema_migrations (version, applied_at, source)
VALUES ('178_feb2026_st_territory_id_backfill', NOW(), 'live-apply')
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ════════════════════════════════════════════════════════════════════════════
-- TALLY (informational, expected post-apply state):
--   backfilled    : 538   (territory_id NULL -> resolved via cc.territory_name)
--   residual NULL :  25   (cc_id IN (4038,4039,4041,4042,4043) dedup-deleted)
--   total Feb-26  : 563   ALM (293) + DWS (270) source_system rows
-- ════════════════════════════════════════════════════════════════════════════
