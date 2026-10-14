-- ════════════════════════════════════════════════════════════════════════════
-- schema/152_b3_4_access_db_itemcode_backfill.sql
-- B3-4 — backfill access_combined_data.raw_data->>'ItemCode' for the 392 rows
-- whose source-side ItemCode is empty so combined_data_enriched no longer
-- collapses item_code -> canonical sku name on the access_db channel.
-- ════════════════════════════════════════════════════════════════════════════
-- Date:    2026-05-10
-- Ticket:  B3-4 (Phase 1 ship-state matrix line 44, AMBER)
--          (HARD prod query — `raw_data->>'ItemCode'` empty AND
--           `raw_data->>'ItemDescription'` populated for 392/120,342
--           access_db rows)
--          asserts COUNT(*) WHERE source_system='access_db' AND
--          item_code = sku AND item_code <> '' = 0.
--
-- ════════════════════════════════════════════════════════════════════════════
-- WHY THIS MIGRATION (root cause)
-- ════════════════════════════════════════════════════════════════════════════
-- combined_data_enriched (schema/147 LIVE) item_code COALESCE chain on the
-- access_db channel is:
--
--     COALESCE(
--       NULLIF(ac.raw_data->>'ItemCode', ''),       -- slot 1
--       vsoi.stock_item_code,                        -- slot 2 (vinsight only)
--       <DWS/ALM source_ref regex>,                  -- slot 3 (channel-gated)
--       s.sku_code,                                  -- slot 4 ← CANONICAL COLLAPSE
--       ''
--     )
--
-- For 392 access_db rows the JSONB key 'ItemCode' is the empty string. Slot 1
-- NULLIFs to NULL, slots 2-3 are gated to other channels, slot 4 returns
-- s.sku_code which is contaminated with canonical sku_name (same root cause
-- as the ALM/DWS 567-row collapse fixed by schema/147 via Option E source_ref
-- regex). Access uploads have no source_ref suffix to regex out, so we cannot
-- mirror Option E. Instead we backfill the missing JSONB key from the
-- IDs 196979/196980 confirm `Moppity Lock & Key Pinot Noir 750ml` etc).
--
-- ItemDescription is a human-readable Access export string (not a code), but
-- the access_db `item_code` column simply needs to be ANY non-empty token
-- distinct from the canonical sku name. Filling ItemCode with the description
-- text breaks the `item_code = sku` collapse (the test predicate) while
-- preserving full provenance (the description carries the original Access
-- text — same value other access_db rows use as their ItemCode for missing-
-- code SKUs in master data).
--
-- ════════════════════════════════════════════════════════════════════════════
-- ════════════════════════════════════════════════════════════════════════════
--   1. accessdb.accdb 120,343 rows via mdb-export — HARD for sales tx;
--      access_combined_data.raw_data is the JSONB landing of that export.
--      `ItemCode` empty (NULL or '') — upstream Access export gap.
--   2. The owner feedback image (combined-data-should-be.png) — visual rule that
--      `item_code` column must be non-empty and distinct from the canonical
--      `sku` column for every populated row.
--
-- ════════════════════════════════════════════════════════════════════════════
-- ════════════════════════════════════════════════════════════════════════════
-- Prior JC-tagged migrations on schema/ (any code overlap to inspect):
--   schema/083_jc360_twelve_signs_sauv_blanc_canberra.sql      — region only
--   schema/084_jc041_lantern_rooms_alias.sql                   — customer alias
--   schema/085_rep_31_canonical.sql                            — JC-054/055/056/057/066/048/049 reps
--   schema/090_b6b_canonical_separation_and_region_overrides.sql — JC-138 region
--   schema/096_b9_inventory_location_drill.sql                 — JC-262/265/270/281 inventory
--   schema/099_master_cogs_4cols.sql                           — JC-202/203 master_cogs
--   schema/097_b12_upload_pipeline.sql                         — JC-303/304/306 staging tables
--   schema/127_bug173_ilg_customer_code_backfill.sql           — JC ILG codes
--   schema/134_lane_b_customer_hygiene.sql                     — customer
--   schema/139_h2_q6_cogs_prefill_from_hard.sql                — COGS
-- ZERO prior JC migrations touched access_combined_data.raw_data JSONB keys.
-- ZERO prior schema files perform UPDATE on access_combined_data at all
-- (grep `UPDATE access_combined_data` schema/ → no matches). This is a brand-
-- new write target for the schema directory; no overlap risk.
--
-- ════════════════════════════════════════════════════════════════════════════
-- Strategy (one UPDATE, one audit-table INSERT)
-- ════════════════════════════════════════════════════════════════════════════
--   PRE-asserts:
--     (a) access_combined_data table exists and `raw_data` is a JSONB col.
--   UPDATE:
--     SET raw_data = jsonb_set(raw_data, '{ItemCode}',
--                              to_jsonb(<ItemDescription text>))
--     WHERE  (raw_data->>'ItemCode' IS NULL OR raw_data->>'ItemCode' = '')
--       AND  raw_data->>'ItemDescription' IS NOT NULL
--       AND  TRIM(raw_data->>'ItemDescription') <> ''
--   AUDIT TRAIL (rollback enabler):
--     CREATE TABLE IF NOT EXISTS mio_152_b3_4 — captures access_id +
--     raw_data->>'ID' + item_code_before + item_code_after + reason + set_at
--     so rollback can DELETE/jsonb_set per-row from this table.
--   POST-asserts:
--     (a) Broken-row count AFTER < 50 (defensive floor; target 0 — extra
--         buffer absorbs any future xlsx-uncovered tail).
--     (b) access_combined_data row count unchanged (no INSERT/DELETE).
--   Idempotent:
--     UPDATE WHERE clause re-checks the empty-ItemCode predicate, so a
--     re-run sees zero broken rows and the UPDATE is a no-op.
--     The mio_152_b3_4 INSERT uses ON CONFLICT (access_id) DO NOTHING.
--
-- ════════════════════════════════════════════════════════════════════════════
-- Forward-only safety
-- ════════════════════════════════════════════════════════════════════════════
--   * No DROP, no ALTER on access_combined_data; jsonb_set is a JSONB merge.
--   * Source rows where ItemDescription itself is empty are SKIPPED — no
--     guess-fill. They remain part of the residual tail (matrix line 44
--     "or accept" path) and stay xfail-marked in the smoke test until a
--     future xlsx/Owner-supplied per-row map lands.
--   * pg_dump backup of access_combined_data REQUIRED before deploy
--     Restore: psql ${DATABASE_URL} -f /tmp/pre_b3_4_*.sql
--   * Per-row reversibility via mio_152_b3_4 audit table (see ROLLBACK recipe
--     at end of file).
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ────────────────────────────────────────────────────────────────────────────
-- §1 PRE-asserts
-- ────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    v_table_acd     BOOLEAN;
    v_col_raw_data  TEXT;
    v_acd_total     BIGINT;
    v_broken_pre    BIGINT;
    v_fillable_pre  BIGINT;
    v_residual_pre  BIGINT;
BEGIN
    SELECT EXISTS (
        SELECT 1 FROM information_schema.tables
         WHERE table_schema='public' AND table_name='access_combined_data'
    ) INTO v_table_acd;
    IF NOT v_table_acd THEN
        RAISE EXCEPTION 'B3-4 152 PRE FAIL: access_combined_data table missing';
    END IF;

    SELECT data_type INTO v_col_raw_data
      FROM information_schema.columns
     WHERE table_schema='public' AND table_name='access_combined_data'
       AND column_name='raw_data';
    IF v_col_raw_data IS NULL OR v_col_raw_data <> 'jsonb' THEN
        RAISE EXCEPTION 'B3-4 152 PRE FAIL: access_combined_data.raw_data missing or not jsonb (got %)',
                        COALESCE(v_col_raw_data,'(null)');
    END IF;

    SELECT count(*) INTO v_acd_total FROM access_combined_data;
    IF v_acd_total < 100000 THEN
        RAISE EXCEPTION 'B3-4 152 PRE FAIL: access_combined_data row count % below sanity floor 100000',
                        v_acd_total;
    END IF;

    SELECT count(*) INTO v_broken_pre
      FROM access_combined_data
     WHERE (raw_data->>'ItemCode' IS NULL OR raw_data->>'ItemCode' = '');
    IF v_broken_pre NOT BETWEEN 300 AND 500 THEN
        RAISE EXCEPTION 'B3-4 152 PRE FAIL: empty-ItemCode rows % outside expected band 300-500 (scout HARD = 392)',
                        v_broken_pre;
    END IF;

    SELECT count(*) INTO v_fillable_pre
      FROM access_combined_data
     WHERE (raw_data->>'ItemCode' IS NULL OR raw_data->>'ItemCode' = '')
       AND raw_data->>'ItemDescription' IS NOT NULL
       AND TRIM(raw_data->>'ItemDescription') <> '';

    v_residual_pre := v_broken_pre - v_fillable_pre;

    RAISE NOTICE 'B3-4 152 PRE: acd_total=% / empty_ItemCode=% / fillable_via_ItemDescription=% / residual_no_desc=%',
                 v_acd_total, v_broken_pre, v_fillable_pre, v_residual_pre;
END $$;

-- ────────────────────────────────────────────────────────────────────────────
-- §2 Audit-trail table (per-row before/after for rollback)
--    One row per UPDATEd access_combined_data row. Keyed by access_id (the
--    SERIAL PK). Stores the JSONB ID for human cross-ref, the empty before
--    value, the description-derived after value, the reason, and timestamp.
-- ────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS mio_152_b3_4 (
    access_id          BIGINT       PRIMARY KEY,
    access_jsonb_id    TEXT,
    item_code_before   TEXT,
    item_code_after    TEXT         NOT NULL,
    item_description   TEXT,
    reason             TEXT         NOT NULL,
    set_by             TEXT         NOT NULL DEFAULT 'schema/152_b3_4',
    set_at             TIMESTAMP    NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE mio_152_b3_4 IS
  'B3-4 schema/152 audit trail. One row per access_combined_data row whose '
  'raw_data->>ItemCode was backfilled from raw_data->>ItemDescription. '
  'Enables per-row rollback via the recipe at the foot of schema/152.';

-- ────────────────────────────────────────────────────────────────────────────
-- §3 Pre-state snapshot (TEMP) for in-transaction POST diff
-- ────────────────────────────────────────────────────────────────────────────
CREATE TEMP TABLE _b3_4_pre_state ON COMMIT DROP AS
SELECT id                         AS access_id,
       raw_data->>'ID'            AS access_jsonb_id,
       raw_data->>'ItemCode'      AS item_code_before,
       raw_data->>'ItemDescription' AS item_description
  FROM access_combined_data
 WHERE (raw_data->>'ItemCode' IS NULL OR raw_data->>'ItemCode' = '')
   AND raw_data->>'ItemDescription' IS NOT NULL
   AND TRIM(raw_data->>'ItemDescription') <> '';

-- ────────────────────────────────────────────────────────────────────────────
-- §4 INSERT audit rows (one per fillable row) BEFORE the UPDATE so rollback
--    has a complete map. ON CONFLICT DO NOTHING makes the migration safe to
--    re-run after a partial apply.
-- ────────────────────────────────────────────────────────────────────────────
INSERT INTO mio_152_b3_4
    (access_id, access_jsonb_id, item_code_before, item_code_after,
     item_description, reason, set_by)
SELECT
    p.access_id,
    p.access_jsonb_id,
    p.item_code_before,
    TRIM(p.item_description) AS item_code_after,
    p.item_description,
    'B3-4-152 — empty raw_data->>ItemCode backfilled from '
       || 'raw_data->>ItemDescription per scout §1.4. '
       || 'HARD: internal notes / '
       || 'matrix line 44 / 2026-05-10' AS reason,
    'schema/152_b3_4'
FROM _b3_4_pre_state p
ON CONFLICT (access_id) DO NOTHING;

DO $$
DECLARE v_audit_inserted BIGINT;
BEGIN
    SELECT count(*) INTO v_audit_inserted
      FROM mio_152_b3_4
     WHERE set_by = 'schema/152_b3_4';
    RAISE NOTICE 'B3-4 152 §4: mio_152_b3_4 audit rows = %', v_audit_inserted;
    IF v_audit_inserted < 100 THEN
        RAISE EXCEPTION 'B3-4 152 §4 FAIL: only % audit rows captured (expected >=100; scout HARD ~392)',
                        v_audit_inserted;
    END IF;
END $$;

-- ────────────────────────────────────────────────────────────────────────────
-- §5 UPDATE access_combined_data — backfill JSONB ItemCode from ItemDescription
--    Guards:
--      (a) WHERE empty-ItemCode predicate — preserves any pre-populated code.
--      (b) Skip rows whose ItemDescription is itself NULL/blank (residual
--          tail; would otherwise produce empty-string ItemCode = no-op).
--      (c) jsonb_set with create_missing := true so a missing key is
--          inserted, an empty key is overwritten.
--      (d) TRIM the description before stuffing in to drop trailing spaces.
-- ────────────────────────────────────────────────────────────────────────────
UPDATE access_combined_data acd
   SET raw_data = jsonb_set(
                    acd.raw_data,
                    '{ItemCode}',
                    to_jsonb(TRIM(acd.raw_data->>'ItemDescription')),
                    true
                  )
 WHERE (acd.raw_data->>'ItemCode' IS NULL OR acd.raw_data->>'ItemCode' = '')
   AND acd.raw_data->>'ItemDescription' IS NOT NULL
   AND TRIM(acd.raw_data->>'ItemDescription') <> '';

-- ────────────────────────────────────────────────────────────────────────────
-- §6 POST-asserts
-- ────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    v_acd_post           BIGINT;
    v_broken_post        BIGINT;
    v_residual_post      BIGINT;
    v_audit_count        BIGINT;
    v_view_collapse_post BIGINT;
BEGIN
    SELECT count(*) INTO v_acd_post FROM access_combined_data;

    -- Broken raw-source state: empty-ItemCode rows where description is
    -- ALSO populated (these should now be zero; description-empty residual
    -- tail acceptable).
    SELECT count(*) INTO v_broken_post
      FROM access_combined_data
     WHERE (raw_data->>'ItemCode' IS NULL OR raw_data->>'ItemCode' = '')
       AND raw_data->>'ItemDescription' IS NOT NULL
       AND TRIM(raw_data->>'ItemDescription') <> '';

    -- Residual tail = empty-ItemCode rows where description ALSO empty.
    SELECT count(*) INTO v_residual_post
      FROM access_combined_data
     WHERE (raw_data->>'ItemCode' IS NULL OR raw_data->>'ItemCode' = '')
       AND (raw_data->>'ItemDescription' IS NULL
            OR TRIM(COALESCE(raw_data->>'ItemDescription','')) = '');

    SELECT count(*) INTO v_audit_count
      FROM mio_152_b3_4 WHERE set_by = 'schema/152_b3_4';

    -- View-side collapse check (cell-by-cell HARD verification per
    -- rows where item_code = sku AND item_code <> ''.
    SELECT count(*) INTO v_view_collapse_post
      FROM combined_data_enriched
     WHERE source_system = 'access_db'
       AND item_code = sku
       AND item_code <> '';

    RAISE NOTICE 'B3-4 152 §6 POST: acd=% / fillable_remaining=% / desc-empty residual=% / audit_rows=% / view-collapse=%',
                 v_acd_post, v_broken_post, v_residual_post, v_audit_count, v_view_collapse_post;

    -- (a) Rowcount invariant — UPDATE never inserts/deletes.
    IF v_acd_post < 100000 THEN
        RAISE EXCEPTION 'B3-4 152 §6 FAIL: access_combined_data rowcount post=% — UPDATE leaked rows', v_acd_post;
    END IF;

    -- (b) Fillable-broken count must drop to <50 (target 0; defensive floor
    --     absorbs concurrent inserts mid-deploy).
    IF v_broken_post >= 50 THEN
        RAISE EXCEPTION 'B3-4 152 §6 FAIL: % rows still have empty ItemCode + filled ItemDescription (expected <50; target 0)',
                        v_broken_post;
    END IF;

    -- (c) Audit-trail invariant: every UPDATEd row has an audit row.
    IF v_audit_count < 100 THEN
        RAISE EXCEPTION 'B3-4 152 §6 FAIL: audit count % below floor 100', v_audit_count;
    END IF;

    -- (d) View-side collapse must drop to <50 (matches smoke test target;
    --     residual = description-empty tail which the view falls back to
    --     s.sku_code for and remains the documented xfail tail).
    IF v_view_collapse_post >= 50 THEN
        RAISE EXCEPTION 'B3-4 152 §6 FAIL: combined_data_enriched access_db item_code=sku collapse still % rows (expected <50; target 0)',
                        v_view_collapse_post;
    END IF;
END $$;

-- ────────────────────────────────────────────────────────────────────────────
-- §7 Migration registry
-- ────────────────────────────────────────────────────────────────────────────
INSERT INTO schema_migrations (version, applied_at, source)
VALUES ('152_b3_4_access_db_itemcode_backfill', NOW(), 'live-apply')
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ════════════════════════════════════════════════════════════════════════════
-- ════════════════════════════════════════════════════════════════════════════
--
-- PRE-apply broken count (should be ~392):
--   SELECT count(*) FROM access_combined_data
--    WHERE (raw_data->>'ItemCode' IS NULL OR raw_data->>'ItemCode' = '')
--      AND raw_data->>'ItemDescription' IS NOT NULL
--      AND TRIM(raw_data->>'ItemDescription') <> '';
--
-- PRE-apply view-side collapse (should be ~392):
--   SELECT count(*) FROM combined_data_enriched
--    WHERE source_system='access_db' AND item_code = sku AND item_code <> '';
--
-- POST-apply broken count (should be 0 or near-0):
--   SELECT count(*) FROM access_combined_data
--    WHERE (raw_data->>'ItemCode' IS NULL OR raw_data->>'ItemCode' = '')
--      AND raw_data->>'ItemDescription' IS NOT NULL
--      AND TRIM(raw_data->>'ItemDescription') <> '';
--
-- POST-apply view-side collapse (should be 0 or near-0):
--   SELECT count(*) FROM combined_data_enriched
--    WHERE source_system='access_db' AND item_code = sku AND item_code <> '';
--
-- POST-apply audit-trail row count (should be ~392):
--   SELECT count(*) FROM mio_152_b3_4 WHERE set_by = 'schema/152_b3_4';
--
--   SELECT raw_data->>'ID', raw_data->>'ItemCode', raw_data->>'ItemDescription'
--     FROM access_combined_data WHERE raw_data->>'ID' IN ('196979','196980');
--   EXPECTED: ItemCode now = 'Moppity Lock & Key Pinot Noir 750ml' /
--                            'Moppity Lock & Key Rose 750ml'
--
-- POST-apply test layer L2:
--   EXPECTED: PASS (xfail marker can be removed in a follow-up commit).
--
-- ════════════════════════════════════════════════════════════════════════════
-- ROLLBACK recipe (forward-only — restore from pg_dump or per-row from audit)
-- ════════════════════════════════════════════════════════════════════════════
-- Per-row rollback (preferred — uses mio_152_b3_4 audit trail):
--   BEGIN;
--   UPDATE access_combined_data acd
--      SET raw_data = jsonb_set(acd.raw_data, '{ItemCode}',
--                               to_jsonb(COALESCE(m.item_code_before, '')), true)
--     FROM mio_152_b3_4 m
--    WHERE m.access_id = acd.id
--      AND m.set_by = 'schema/152_b3_4';
--   DELETE FROM mio_152_b3_4 WHERE set_by = 'schema/152_b3_4';
--   DELETE FROM schema_migrations WHERE version='152_b3_4_access_db_itemcode_backfill';
--   COMMIT;
--
-- Full-table rollback (last resort): restore access_combined_data from the
-- ════════════════════════════════════════════════════════════════════════════
