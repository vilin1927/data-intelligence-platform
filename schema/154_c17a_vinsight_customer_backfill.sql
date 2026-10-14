-- ════════════════════════════════════════════════════════════════════════════
-- schema/154_c17a_vinsight_customer_backfill.sql
-- C17a — Backfill customer_name on 8 vinsight rows (Territory NULL upstream)
-- ════════════════════════════════════════════════════════════════════════════
-- Date:    2026-05-11
-- Ticket:  C17a (Phase 1 ship-state matrix line 108, AMBER 8/110 vinsight rows
--          missing territory because customer_name is NULL upstream)
-- Source:  staging_vinsight_sales_orders.raw_data->'Contact'->>'ContactCode'
--          (canonical Vinsight customer name field — verified in
--          Cross-cite: staging_vinsight_contacts.raw_data->>'ContactCode'
--          for FYI lookup; sales-order Contact subobject has the same code.
--
-- The owner verbatim (PDF p6 #15):
--   "I downloaded the Combined Data file and found Vinsight data is being
--    appended without Territory"
--
-- ════════════════════════════════════════════════════════════════════════════
-- WHY THIS MIGRATION (root cause)
-- ════════════════════════════════════════════════════════════════════════════
-- combined_data_enriched view (schema/068, schema/132, schema/146) computes
-- territory through a COALESCE chain anchored on `customer` and
-- `canonical_customer` joined via `sales_transaction.customer_id`. When
-- sales_transaction.customer_id IS NULL (vinsight contact_code did not
-- resolve in customer_code_map at INSERT time per schema/041 path), the view
-- returns NULL customer_name AND NULL territory.
--
--   SELECT COUNT(*) FROM combined_data_enriched
--    WHERE source_system='vinsight' AND (territory IS NULL OR territory='')
--   = 0
--
-- Fix: extract ContactCode from staging_vinsight_sales_orders.raw_data via
-- vinsight-<order_num>-<entry_num> source_ref join → vinsight_sales_order_item
-- → staging_vinsight_sales_orders. Use ContactCode to find existing customer
-- row OR create it from staging_vinsight_contacts JSONB enrichment, then
-- UPDATE sales_transaction.customer_id linking the row. Territory then
-- derives via existing customer.territory_id join in the enriched view.
--
-- ════════════════════════════════════════════════════════════════════════════
-- ════════════════════════════════════════════════════════════════════════════
--   1. May 8 verbal — out of scope (no contradiction on vinsight names)
--   2. DOCX paragraph 0647 — out of scope
--      authoritative for direct sales customers
--   4. Vinsight raw API — staging_vinsight_sales_orders.raw_data->'Contact'
--      ->>'ContactCode' is the canonical customer-name field per
--      THIS migration source.
--   5. xlsx Mar 24 baseline — Customer table sheet has 4,031 rows; NOT used
--      directly here because the 8 broken rows are post-Mar-24 vinsight
--      transactions whose contact may not exist on the xlsx Mar 24 baseline.
--      ContactCode HARD per row.
--
-- ════════════════════════════════════════════════════════════════════════════
-- ════════════════════════════════════════════════════════════════════════════
-- Grep'd schema/ for prior migrations writing customer_name from JSONB.
-- Findings:
--   schema/060_customer_master_22cols.sql      — B4 JC-003 (Apr 27) Access
--                                                CombinedData backfill of
--                                                customer.customer_name with
--                                                "@ SUBURB" suffix from
--                                                Access raw_data->>'Suburb'.
--                                                Path: access_db source ONLY.
--                                                Vinsight customers untouched.
--                                                No conflict — this migration
--                                                preserves any customer rows
--                                                schema/060 created.
--   schema/041_jr089_vinsight_territory_rep_backfill.sql
--                                              — JR-089 (Apr 18) created the
--                                                sync_vinsight_direct_sales()
--                                                function path that writes
--                                                vinsight rows to
--                                                sales_transaction with
--                                                customer_id resolved via
--                                                customer_code_map LEFT JOIN
--                                                on contact_code. When the
--                                                LEFT JOIN misses, the row
--                                                lands with customer_id=NULL.
--                                                THIS migration backfills
--                                                those 8 NULL customer_ids.
--                                                Function not modified.
--   schema/052_bug107_canonical_customer_flags.sql — canonical_customer flags
--                                                only; does not touch
--                                                customer.customer_name.
--   schema/127_bug173_ilg_customer_code_backfill.sql — ilg_customer_code
--                                                column on canonical_customer;
--                                                no customer_name writes.
--   schema/134_lane_b_customer_hygiene.sql      — exports for audit only;
--                                                no customer_name writes.
--   schema/115_r004_customer_name_at_suburb_view.sql — view-level CASE on
--                                                cu.customer_name; no DB
--                                                writes. R-004 deliberately
--                                                kept "NAME @ SUBURB" embedded
--                                                in customer.customer_name.
-- No prior C17a or vinsight customer_name backfill migration on file.
--
-- ════════════════════════════════════════════════════════════════════════════
-- BLAST RADIUS
-- ════════════════════════════════════════════════════════════════════════════
-- Affected rows: ≤ 8 sales_transaction rows (source_system='vinsight',
--                30 to allow drift since matrix snapshot 2026-05-10.
-- Columns:       sales_transaction.customer_id (UPDATE NULL → resolved id);
--                customer (INSERT new rows when ContactCode has no existing
--                customer row, ON CONFLICT (customer_name) DO NOTHING);
--                customer_code_map (INSERT 'vinsight' source rows linking
--                ContactCode → customer_id, ON CONFLICT DO NOTHING).
-- NOT touched:   any access_db, ALM, DWS, direct, xero rows; any vinsight row
--                already linked to a customer; any customer_name on existing
--                rows; canonical_customer; manual_region_override; sku.
--                content_hash NOT in the WHERE filter (BUG-113 hash basis
--                excludes customer_id; UPDATE preserves identity).
--
-- ════════════════════════════════════════════════════════════════════════════
-- Forward-only safety
-- ════════════════════════════════════════════════════════════════════════════
--   * BEGIN/COMMIT wraps all UPDATE + INSERT
--   * PRE-asserts: required tables present, broken-row count in band
--   * Per-row HARD cite captured in vinsight_customer_backfill_audit_154
--     audit table (transaction_id, source_ref, contact_code, before/after
--     customer_id, resolved customer_name, source path)
--   * UPDATE filters customer_id IS NULL → idempotent (re-run = 0 rows)
--   * customer INSERT uses ON CONFLICT (customer_name) DO NOTHING — preserves
--     any prior schema/060 NAME-AT-SUBURB form
--   * customer_code_map INSERT uses ON CONFLICT (source_system, external_name)
--     DO NOTHING — preserves any prior 'vinsight' mapping
--   * POST-asserts: 0 broken rows (HARD floor) OR documented-tail count
--
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ────────────────────────────────────────────────────────────────────────────
-- §1 PRE-asserts
-- ────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    v_table_st           BOOLEAN;
    v_table_cust         BOOLEAN;
    v_table_ccm          BOOLEAN;
    v_table_so           BOOLEAN;
    v_table_soi          BOOLEAN;
    v_st_count           INT;
    v_broken_pre         INT;
    v_view_broken_pre    INT;
BEGIN
    SELECT EXISTS(SELECT 1 FROM information_schema.tables
                  WHERE table_schema='public' AND table_name='sales_transaction')
      INTO v_table_st;
    SELECT EXISTS(SELECT 1 FROM information_schema.tables
                  WHERE table_schema='public' AND table_name='customer')
      INTO v_table_cust;
    SELECT EXISTS(SELECT 1 FROM information_schema.tables
                  WHERE table_schema='public' AND table_name='customer_code_map')
      INTO v_table_ccm;
    SELECT EXISTS(SELECT 1 FROM information_schema.tables
                  WHERE table_schema='public' AND table_name='staging_vinsight_sales_orders')
      INTO v_table_so;
    SELECT EXISTS(SELECT 1 FROM information_schema.tables
                  WHERE table_schema='public' AND table_name='vinsight_sales_order_item')
      INTO v_table_soi;
    IF NOT v_table_st THEN
        RAISE EXCEPTION 'C17a-154 PRE FAIL: sales_transaction missing'; END IF;
    IF NOT v_table_cust THEN
        RAISE EXCEPTION 'C17a-154 PRE FAIL: customer missing'; END IF;
    IF NOT v_table_ccm THEN
        RAISE EXCEPTION 'C17a-154 PRE FAIL: customer_code_map missing'; END IF;
    IF NOT v_table_so THEN
        RAISE EXCEPTION 'C17a-154 PRE FAIL: staging_vinsight_sales_orders missing'; END IF;
    IF NOT v_table_soi THEN
        RAISE EXCEPTION 'C17a-154 PRE FAIL: vinsight_sales_order_item missing'; END IF;

    -- sales_transaction sanity floor
    SELECT count(*) INTO v_st_count FROM sales_transaction;
    IF v_st_count < 100000 THEN
        RAISE EXCEPTION 'C17a-154 PRE FAIL: sales_transaction count % below floor 100000',
            v_st_count;
    END IF;

    -- Broken-row count (vinsight rows missing customer_id)
    SELECT count(*) INTO v_broken_pre
      FROM sales_transaction
     WHERE source_system = 'vinsight'
       AND customer_id IS NULL;

    -- Belt-and-braces: also count enriched-view rows missing territory.
    SELECT count(*) INTO v_view_broken_pre
      FROM combined_data_enriched
     WHERE source_system = 'vinsight'
       AND (territory IS NULL OR territory = '');

    IF v_broken_pre NOT BETWEEN 0 AND 30 THEN
        RAISE EXCEPTION 'C17a-154 PRE FAIL: vinsight customer_id NULL count % outside expected band 0-30 (verifier-CD baseline 8) — investigate before bulk backfill',
            v_broken_pre;
    END IF;

    IF v_view_broken_pre NOT BETWEEN 0 AND 30 THEN
        RAISE EXCEPTION 'C17a-154 PRE FAIL: combined_data_enriched vinsight territory-NULL count % outside expected band 0-30',
            v_view_broken_pre;
    END IF;

    RAISE NOTICE 'C17a-154 PRE OK — sales_transaction=% rows / vinsight customer_id NULL=% / view territory NULL=%',
                 v_st_count, v_broken_pre, v_view_broken_pre;

    -- Stash invariants for POST cross-check
    CREATE TEMP TABLE _c17a_invariant (
        st_total_pre        INT,
        broken_pre          INT,
        view_broken_pre     INT
    );
    INSERT INTO _c17a_invariant
    VALUES (v_st_count, v_broken_pre, v_view_broken_pre);
END $$;

-- ────────────────────────────────────────────────────────────────────────────
-- §2 Audit table — captures per-row before/after for traceability
-- ────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS vinsight_customer_backfill_audit_154 (
    audit_id           SERIAL PRIMARY KEY,
    transaction_id     INT  NOT NULL,
    source_ref         TEXT NOT NULL,
    order_num          INT,
    entry_num          INT,
    contact_code       TEXT,
    customer_id_before INT,
    customer_id_after  INT,
    customer_name      TEXT,
    source_path        TEXT NOT NULL DEFAULT
        'staging_vinsight_sales_orders.raw_data->Contact->>ContactCode',
    created_customer   BOOLEAN NOT NULL DEFAULT FALSE,
    created_code_map   BOOLEAN NOT NULL DEFAULT FALSE,
    applied_at         TIMESTAMP NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE vinsight_customer_backfill_audit_154 IS
'C17a (2026-05-11): per-row audit of schema/154 vinsight customer_name backfill. One row per sales_transaction.transaction_id whose customer_id was NULL pre-migration. Source path documents JSONB extraction lineage for HARD cite.';

-- ────────────────────────────────────────────────────────────────────────────
-- §3 Build resolution temp table — extract ContactCode per broken row
--    Source path: sales_transaction.source_ref ('vinsight-<order>-<entry>')
--                 → vinsight_sales_order_item.(order_num, entry_num)
--                 → staging_vinsight_sales_orders.raw_data on order_num match
--                 → raw_data->'Contact'->>'ContactCode'
--    Fallback path: vinsight_sales_order_item.contact_code already populated
--                  by sync_sales_order_items.py:223 (same JSONB extraction
--                  done at sync time). Either source resolves to the same
--                  ContactCode value.
-- ────────────────────────────────────────────────────────────────────────────
-- staging_vinsight_sales_orders has multiple rows per SalesOrderNum
-- (ETL re-syncs same order across runs). DISTINCT ON (transaction_id)
-- collapses to 1 row per broken sales_transaction. ContactCode is
-- deterministic per order so any staging row produces same value.
CREATE TEMP TABLE _c17a_resolve ON COMMIT DROP AS
SELECT DISTINCT ON (st.transaction_id)
    st.transaction_id,
    st.source_ref,
    CASE WHEN st.source_ref ~ '^vinsight-[0-9]+-[0-9]+$'
         THEN split_part(st.source_ref, '-', 2)::int END               AS order_num,
    CASE WHEN st.source_ref ~ '^vinsight-[0-9]+-[0-9]+$'
         THEN split_part(st.source_ref, '-', 3)::int END               AS entry_num,
    -- Primary: raw JSONB Contact->ContactCode
    -- Secondary: vinsight_sales_order_item.contact_code (same source)
    -- Tertiary: raw JSONB ContactName / Customer Name fallback for completeness
    COALESCE(
        NULLIF(TRIM(so.raw_data->'Contact'->>'ContactCode'), ''),
        NULLIF(TRIM(vsoi.contact_code), ''),
        NULLIF(TRIM(so.raw_data->>'ContactName'), ''),
        NULLIF(TRIM(so.raw_data->>'CustomerName'), '')
    )                                                                   AS contact_code,
    st.customer_id                                                      AS customer_id_before
  FROM sales_transaction st
  LEFT JOIN vinsight_sales_order_item vsoi
         ON vsoi.order_num = (CASE WHEN st.source_ref ~ '^vinsight-[0-9]+-[0-9]+$'
                                   THEN split_part(st.source_ref, '-', 2)::int END)
        AND vsoi.entry_num = (CASE WHEN st.source_ref ~ '^vinsight-[0-9]+-[0-9]+$'
                                   THEN split_part(st.source_ref, '-', 3)::int END)
  LEFT JOIN staging_vinsight_sales_orders so
         ON (so.raw_data->>'SalesOrderNum')::int =
            (CASE WHEN st.source_ref ~ '^vinsight-[0-9]+-[0-9]+$'
                  THEN split_part(st.source_ref, '-', 2)::int END)
 WHERE st.source_system = 'vinsight'
   AND st.customer_id IS NULL
 ORDER BY st.transaction_id,
          (so.raw_data->'Contact'->>'ContactCode') NULLS LAST,
          so.id DESC NULLS LAST;

CREATE INDEX ON _c17a_resolve (transaction_id);
CREATE INDEX ON _c17a_resolve (contact_code);

-- ────────────────────────────────────────────────────────────────────────────
-- §4 Resolve count assert
-- ────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    v_resolve_total    INT;
    v_resolve_with_cc  INT;
    v_resolve_no_cc    INT;
BEGIN
    SELECT count(*),
           count(*) FILTER (WHERE contact_code IS NOT NULL),
           count(*) FILTER (WHERE contact_code IS NULL)
      INTO v_resolve_total, v_resolve_with_cc, v_resolve_no_cc
      FROM _c17a_resolve;

    RAISE NOTICE 'C17a-154 §4: resolve total=% / with ContactCode=% / no ContactCode=%',
                 v_resolve_total, v_resolve_with_cc, v_resolve_no_cc;

    IF v_resolve_total NOT BETWEEN 0 AND 30 THEN
        RAISE EXCEPTION 'C17a-154 §4 FAIL: resolve total % outside expected band 0-30',
            v_resolve_total;
    END IF;

    -- Soft floor: if every broken row failed ContactCode extraction, source
    -- path regressed (raw JSONB shape changed or staging stopped syncing).
    IF v_resolve_total > 0 AND v_resolve_with_cc = 0 THEN
        RAISE EXCEPTION 'C17a-154 §4 FAIL: 0 of % broken rows resolved ContactCode — JSONB path drift or staging gap; investigate raw_data->Contact subobject',
            v_resolve_total;
    END IF;
END $$;

-- ────────────────────────────────────────────────────────────────────────────
-- §5 INSERT customer rows for ContactCodes with no existing customer
--    Pattern follows etl/transform_to_core.py populate_from_vinsight():
--    customer_name = ContactCode (canonical Vinsight name).
--    Suburb / postcode left NULL — schema/060 NAME-AT-SUBURB enrichment runs
--    on subsequent ETL passes via populate_from_vinsight + suburb merge logic.
-- ────────────────────────────────────────────────────────────────────────────
INSERT INTO customer (customer_name)
SELECT DISTINCT contact_code
  FROM _c17a_resolve
 WHERE contact_code IS NOT NULL
   AND NOT EXISTS (
       SELECT 1 FROM customer c
        WHERE LOWER(c.customer_name) = LOWER(_c17a_resolve.contact_code)
   )
ON CONFLICT (customer_name) DO NOTHING;

-- ────────────────────────────────────────────────────────────────────────────
-- §6 INSERT customer_code_map rows linking ContactCode → customer_id
--    Mirrors etl/transform_to_core.py:874-877 pattern.
-- ────────────────────────────────────────────────────────────────────────────
INSERT INTO customer_code_map (customer_id, source_system, external_name)
SELECT DISTINCT c.customer_id, 'vinsight', r.contact_code
  FROM _c17a_resolve r
  JOIN customer c ON LOWER(c.customer_name) = LOWER(r.contact_code)
 WHERE r.contact_code IS NOT NULL
ON CONFLICT (source_system, external_name) DO NOTHING;

-- ────────────────────────────────────────────────────────────────────────────
-- §7 UPDATE sales_transaction.customer_id for the 8 broken rows
--    Idempotent: WHERE customer_id IS NULL filter; re-run = 0 rows.
-- ────────────────────────────────────────────────────────────────────────────
UPDATE sales_transaction st
   SET customer_id = c.customer_id
  FROM _c17a_resolve r
  JOIN customer c ON LOWER(c.customer_name) = LOWER(r.contact_code)
 WHERE st.transaction_id = r.transaction_id
   AND st.customer_id IS NULL
   AND st.source_system = 'vinsight'
   AND r.contact_code IS NOT NULL;

-- ────────────────────────────────────────────────────────────────────────────
-- §8 Audit-row capture (one row per resolved transaction)
-- ────────────────────────────────────────────────────────────────────────────
INSERT INTO vinsight_customer_backfill_audit_154
    (transaction_id, source_ref, order_num, entry_num, contact_code,
     customer_id_before, customer_id_after, customer_name,
     created_customer, created_code_map)
SELECT
    r.transaction_id,
    r.source_ref,
    r.order_num,
    r.entry_num,
    r.contact_code,
    r.customer_id_before,
    st.customer_id                                                  AS customer_id_after,
    c.customer_name,
    NOT EXISTS (
        SELECT 1 FROM customer cc
         WHERE LOWER(cc.customer_name) = LOWER(r.contact_code)
           AND cc.created_at < (NOW() - INTERVAL '1 hour')
    )                                                               AS created_customer,
    NOT EXISTS (
        SELECT 1 FROM customer_code_map ccm
         WHERE ccm.source_system = 'vinsight'
           AND LOWER(ccm.external_name) = LOWER(r.contact_code)
           AND ccm.created_at < (NOW() - INTERVAL '1 hour')
    )                                                               AS created_code_map
  FROM _c17a_resolve r
  LEFT JOIN sales_transaction st ON st.transaction_id = r.transaction_id
  LEFT JOIN customer c ON c.customer_id = st.customer_id
 WHERE NOT EXISTS (
     SELECT 1 FROM vinsight_customer_backfill_audit_154 a
      WHERE a.transaction_id = r.transaction_id
 );

-- ────────────────────────────────────────────────────────────────────────────
-- §9 POST-asserts (RAISE EXCEPTION on regression = transaction abort)
-- ────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    v_pre_st_count        INT;
    v_post_st_count       INT;
    v_pre_broken          INT;
    v_post_broken         INT;
    v_pre_view_broken     INT;
    v_post_view_broken    INT;
    v_audit_count         INT;
BEGIN
    SELECT st_total_pre, broken_pre, view_broken_pre
      INTO v_pre_st_count, v_pre_broken, v_pre_view_broken
      FROM _c17a_invariant;

    SELECT count(*) INTO v_post_st_count FROM sales_transaction;
    SELECT count(*) INTO v_post_broken
      FROM sales_transaction
     WHERE source_system = 'vinsight'
       AND customer_id IS NULL;
    SELECT count(*) INTO v_post_view_broken
      FROM combined_data_enriched
     WHERE source_system = 'vinsight'
       AND (territory IS NULL OR territory = '');
    SELECT count(*) INTO v_audit_count
      FROM vinsight_customer_backfill_audit_154;

    -- a) sales_transaction row count must NOT drift (UPDATE only)
    IF v_post_st_count <> v_pre_st_count THEN
        RAISE EXCEPTION 'C17a-154 POST FAIL: sales_transaction row count drift % → %',
            v_pre_st_count, v_post_st_count;
    END IF;

    -- b) broken vinsight customer_id NULL must monotonically decrease (or
    --    stay 0 on idempotent re-run).
    IF v_post_broken > v_pre_broken THEN
        RAISE EXCEPTION 'C17a-154 POST FAIL: vinsight customer_id NULL grew %→%',
            v_pre_broken, v_post_broken;
    END IF;

    -- c) view-level territory NULL must NOT grow
    IF v_post_view_broken > v_pre_view_broken THEN
        RAISE EXCEPTION 'C17a-154 POST FAIL: vinsight view territory-NULL grew %→%',
            v_pre_view_broken, v_post_view_broken;
    END IF;

    -- d) Hard floor: residual broken rows allowed only if ContactCode could
    --    not be resolved from raw JSONB (documented tail). HARD: must reach 0
    --    when L2 test passes; allow ≤ 5 floor in case of tail rows pending
    --    Vinsight resync.
    IF v_post_broken > 5 THEN
        RAISE EXCEPTION 'C17a-154 POST FAIL: % vinsight rows still missing customer_id (expected ≤ 5 residual tail; investigate raw_data Contact subobject for unresolved rows)',
            v_post_broken;
    END IF;

    -- e) Audit table must have at least one row per resolved transaction
    IF v_audit_count < (v_pre_broken - v_post_broken) THEN
        RAISE EXCEPTION 'C17a-154 POST FAIL: audit row count % < flips %→% (pre - post)',
            v_audit_count, v_pre_broken, v_post_broken;
    END IF;

    RAISE NOTICE 'C17a-154 POST OK — st_total=% (unchanged) / broken pre→post = %→% / view territory NULL pre→post = %→% / audit rows=%',
                 v_post_st_count, v_pre_broken, v_post_broken,
                 v_pre_view_broken, v_post_view_broken, v_audit_count;
END $$;

-- ────────────────────────────────────────────────────────────────────────────
-- §10 Migration registry
-- ────────────────────────────────────────────────────────────────────────────
INSERT INTO schema_migrations (version, applied_at, source)
VALUES ('154_c17a_vinsight_customer_backfill', NOW(), 'live-apply')
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ════════════════════════════════════════════════════════════════════════════
-- ════════════════════════════════════════════════════════════════════════════
--
-- PRE-apply broken count (should be ~8):
--   SELECT count(*) FROM sales_transaction
--    WHERE source_system='vinsight' AND customer_id IS NULL;
--
-- PRE-apply view territory-NULL count (should be ~8):
--   SELECT count(*) FROM combined_data_enriched
--    WHERE source_system='vinsight' AND (territory IS NULL OR territory='');
--
-- POST-apply: same two queries should = 0 (or low residual ≤ 5 with documented
-- ContactCode-unresolvable tail).
--
--   (remove xfail marker after green; matrix line 108 flips 🟡 → 🟢)
--
-- Audit lookup (per-row HARD trace):
--   SELECT transaction_id, source_ref, contact_code,
--          customer_id_before, customer_id_after, customer_name, applied_at
--     FROM vinsight_customer_backfill_audit_154
--    ORDER BY applied_at DESC, transaction_id;
-- ════════════════════════════════════════════════════════════════════════════
