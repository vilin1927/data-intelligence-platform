-- ════════════════════════════════════════════════════════════════════════════
-- schema/169_b3_4_redo_access_db_itemcode.sql
-- B3-4 REDO — backfill access_combined_data.raw_data->>'ItemCode' from MODAL
--             sibling short-code (per `raw_data->>'SKU'`) for the 392 rows
--             where ItemCode is empty. Replaces schema/152 (reverted by 155).
-- ════════════════════════════════════════════════════════════════════════════
-- Date:    2026-05-12
-- Ticket:  PHASE1-CLOSE-B3-4 REDO (matrix line 44)
-- Supersedes:
--   * schema/152_b3_4_access_db_itemcode_backfill.sql (LIVE 2026-05-10,
--     reverted same day by schema/155 — used description text, cascaded into
--     5 downstream consumers).
-- Was-going-to-be:
--   * schema/164 originally intended as B3-4 redo; repurposed for C17a, then
--     HOLD-canonical-blocker. C17a redo lives at schema/166. 169 is a fresh
--
-- ════════════════════════════════════════════════════════════════════════════
-- WHY THIS MIGRATION (root cause + delta vs schema/152)
-- ════════════════════════════════════════════════════════════════════════════
-- 392 access_combined_data rows have empty raw_data->>'ItemCode'. The
-- combined_data_enriched view (schema/147 LIVE) item_code COALESCE chain falls
-- through slot 1 NULLIF and lands on slot 4 s.sku_code (canonical name),
-- producing the `item_code = sku` collapse the owner flagged.
--
-- schema/152 backfilled from raw_data->>'ItemDescription' (long human-readable
-- text). That broke 5 downstream consumers (description text > 30 chars, hit
-- transform_to_core sku INSERT, vintage regex misfires, etc).
--
-- schema/169 backfills from the MODAL sibling short-code per `raw_data->>'SKU'`.
-- All 8 broken SKU groups have a clear dominant 8-digit code used by 12,472
-- sibling rows in the same Access export. Codes are 8 chars (≪ 30-char ETL
-- guard), do not match `(19|20)\d{2}` vintage regex, and already resolve in
-- sku_code_map. No cascade risk.
--
-- ════════════════════════════════════════════════════════════════════════════
-- ════════════════════════════════════════════════════════════════════════════
--   Tier 1a — accessdb.accdb 120,343 rows via mdb-export — HARD for sales tx.
--             access_combined_data.raw_data is the JSONB landing of that
--             export. The 8 modal codes are sourced from 12,472 sibling rows
--             in the same export (within-source HARD majority vote).
--   Tier 1b — xlsx 'Database reconciliation (1).xlsx' sheet
--             "Combined data Feb 25-Feb 26" 13,086 rows — independent HARD
--             cross-validation that Lock & Key SKUs use the 00xxxxxx 8-digit
--             code in the Access ItemCode column.
--   Tier 1c — sku_code_map (source_system='access') — all 8 modal codes
--             present, joining to the matching canonical SKU. Map sourced
--             from a separate Access SKU master export.
--
-- ANSWER-pass: xlsx Combined data sheet confirms 8-digit short-code shape for
-- Lock & Key. xlsx is source-of-truth, our pick matches.
-- VETO-pass:   no HARD verbal / DOCX / Slack contradiction. No the owner override.
--
-- ════════════════════════════════════════════════════════════════════════════
-- ════════════════════════════════════════════════════════════════════════════
--   LOCK & KEY CABERNET SAUVIGNON  -> 00513846  (1,200 siblings)
--   LOCK & KEY CHARDONNAY          -> 00513854  (2,161 siblings)
--   LOCK & KEY MERLOT              -> 00527308    (695 siblings)
--   LOCK & KEY PINOT NOIR          -> 00574583  (2,618 siblings)
--   LOCK & KEY RIESLING            -> 00513862  (1,177 siblings)
--   LOCK & KEY ROSE                -> 00513870  (1,134 siblings)
--   LOCK & KEY SAUVIGNON BLANC     -> 00513888  (1,404 siblings)
--   LOCK & KEY SHIRAZ              -> 00513896  (2,083 siblings)
--
-- ════════════════════════════════════════════════════════════════════════════
-- ════════════════════════════════════════════════════════════════════════════
-- Prior schema migrations writing access_combined_data:
--   schema/152 (LIVE then REVERTED) — description-text backfill.
--   schema/155 (REVERT)             — restored empty ItemCode per
--                                     mio_152_b3_4 audit table.
--   ZERO others. schema/169 is the second writer ever (first redo).
-- Prior migrations on JSONB key 'ItemCode': only 152 + 155 (same lineage).
--
-- ════════════════════════════════════════════════════════════════════════════
-- Consumer cascade analysis (delta vs schema/152 reason-for-revert)
-- ════════════════════════════════════════════════════════════════════════════
-- 1. etl/transform_to_core.py:521-523 — WHERE LENGTH <= 30. 8 chars OK.
-- 2. etl/sync_composition_from_staging.py — propagates ItemCode to
--    sales_transaction.resolved_item_code. 8 chars fits column. OK.
-- 3. etl/ingest_access_vintages.py — vintage regex (19|20)\d{2}. None of the
--    8 codes match (all start "005..."). No bogus vintage attribution. OK.
-- 4. etl/get_wholesale_price.py — SKU join. All 8 codes resolve in
--    sku_code_map → sku.sku_code. OK.
-- 5. scripts/phase_b_precheck_2026-04-22.sql — 43+ regex extractions. None
--    targeting 00xxxxxx shape; all benign string ops. OK.
--
-- No new ETL changes needed. Forward-only.
--
-- ════════════════════════════════════════════════════════════════════════════
-- ADR-015 / L6 customer_must_have_canonical check
-- ════════════════════════════════════════════════════════════════════════════
-- This migration writes only `access_combined_data.raw_data` (JSONB) via
-- jsonb_set. No `canonical_*_id` column UPDATE. No `customer` row UPDATE.
-- ADR-015 and customer_must_have_canonical NOT VALID CHECK — N/A.
-- The only CHECK on access_combined_data is the PK; no L6 constraint trips.
--
-- ════════════════════════════════════════════════════════════════════════════
-- Strategy
-- ════════════════════════════════════════════════════════════════════════════
--   PRE-asserts:
--     (a) access_combined_data exists; raw_data is jsonb.
--     (b) Broken-row count in band [300, 500] (target 392).
--     (c) Long-text contamination at baseline 0 (post-schema/155 clean).
--     (d) 8 modal codes all present in sku_code_map (defensive — confirms map
--         is still authoritative). Skipped if sku_code_map shape changed.
--
--   UPDATE: jsonb_set per-row with CASE-mapped modal code by raw_data->>'SKU'.
--     Idempotent: WHERE re-checks empty-ItemCode predicate.
--     LENGTH guard: only apply where modal code <= 30 chars (always 8 in
--                   practice but the guard documents the invariant).
--
--   AUDIT trail: b3_4_redo_audit_169 captures access_id + item_code_before +
--                item_code_after + reason for per-row rollback. Separate from
--                mio_152_b3_4 (different fix lineage).
--
--   POST-asserts:
--     (a) Broken-row count drops to 0 (band 0-10 defensive).
--     (b) Long-text contamination stays 0 (we wrote 8-char codes).
--     (c) View-side collapse drops to <50 (target 0).
--     (d) Audit-row count ~392.
--     (e) access_combined_data row count unchanged.
--
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ────────────────────────────────────────────────────────────────────────────
-- §1 PRE-asserts
-- ────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    v_table_acd       BOOLEAN;
    v_col_raw_data    TEXT;
    v_acd_total       BIGINT;
    v_broken_pre      BIGINT;
    v_long_pre        BIGINT;
    v_modal_map_count BIGINT;
    v_view_collapse_pre BIGINT;
BEGIN
    SELECT EXISTS (
        SELECT 1 FROM information_schema.tables
         WHERE table_schema='public' AND table_name='access_combined_data'
    ) INTO v_table_acd;
    IF NOT v_table_acd THEN
        RAISE EXCEPTION 'B3-4 169 PRE FAIL: access_combined_data table missing';
    END IF;

    SELECT data_type INTO v_col_raw_data
      FROM information_schema.columns
     WHERE table_schema='public' AND table_name='access_combined_data'
       AND column_name='raw_data';
    IF v_col_raw_data IS NULL OR v_col_raw_data <> 'jsonb' THEN
        RAISE EXCEPTION 'B3-4 169 PRE FAIL: raw_data missing or not jsonb (got %)',
                        COALESCE(v_col_raw_data,'(null)');
    END IF;

    SELECT count(*) INTO v_acd_total FROM access_combined_data;
    IF v_acd_total < 100000 THEN
        RAISE EXCEPTION 'B3-4 169 PRE FAIL: access_combined_data rowcount % below floor 100000', v_acd_total;
    END IF;

    SELECT count(*) INTO v_broken_pre
      FROM access_combined_data
     WHERE (raw_data->>'ItemCode' IS NULL OR raw_data->>'ItemCode' = '');
    IF v_broken_pre NOT BETWEEN 300 AND 500 THEN
        RAISE EXCEPTION 'B3-4 169 PRE FAIL: empty-ItemCode rows % outside band 300-500 (scout HARD = 392)', v_broken_pre;
    END IF;

    SELECT count(*) INTO v_long_pre
      FROM access_combined_data
     WHERE LENGTH(raw_data->>'ItemCode') > 30;
    IF v_long_pre > 50 THEN
        RAISE EXCEPTION 'B3-4 169 PRE FAIL: long-text ItemCode % already high (>50) — schema/155 revert may have regressed; investigate before re-applying B3-4', v_long_pre;
    END IF;

    -- Defensive: the 8 modal codes should all be present in sku_code_map.
    -- If the map shape changed, raise NOTICE (not EXCEPTION) — UPDATE still
    -- runs; downstream sku_code_map join is separate from JSONB write.
    SELECT count(*) INTO v_modal_map_count FROM sku_code_map
     WHERE source_system='access'
       AND external_code IN ('00513846','00513854','00527308','00574583',
                             '00513862','00513870','00513888','00513896');
    IF v_modal_map_count < 8 THEN
        RAISE NOTICE 'B3-4 169 PRE NOTICE: only %/8 modal codes in sku_code_map — UPDATE still runs but downstream join coverage may differ', v_modal_map_count;
    END IF;

    SELECT count(*) INTO v_view_collapse_pre
      FROM combined_data_enriched
     WHERE source_system='access_db' AND item_code = sku AND item_code <> '';

    RAISE NOTICE 'B3-4 169 PRE: acd=% / broken=% / long=% / map_hits=%/8 / view_collapse=%',
                 v_acd_total, v_broken_pre, v_long_pre, v_modal_map_count, v_view_collapse_pre;
END $$;

-- ────────────────────────────────────────────────────────────────────────────
-- §2 Audit-trail table
-- ────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS b3_4_redo_audit_169 (
    access_id          BIGINT       PRIMARY KEY,
    access_jsonb_id    TEXT,
    access_sku_label   TEXT,
    item_code_before   TEXT,
    item_code_after    TEXT         NOT NULL,
    reason             TEXT         NOT NULL,
    set_by             TEXT         NOT NULL DEFAULT 'schema/169_b3_4_redo',
    set_at             TIMESTAMP    NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE b3_4_redo_audit_169 IS
  'B3-4 REDO schema/169 audit trail. One row per access_combined_data row '
  'whose raw_data ItemCode was backfilled from the per-SKU modal short-code '
  '(8-digit Access cross-reference, e.g. 00513888 for LOCK & KEY SAUVIGNON '
  'BLANC). HARD source: within-table majority vote across 12,472 sibling '
  'rows in the same Access export, cross-validated by xlsx Combined data '
  'sheet + sku_code_map. Supersedes schema/152 (description-text approach '
  'reverted by schema/155 — see mio_152_b3_4).';

-- ────────────────────────────────────────────────────────────────────────────
-- §3 Per-SKU modal-code map (CTE → INSERT audit BEFORE update)
-- ────────────────────────────────────────────────────────────────────────────
INSERT INTO b3_4_redo_audit_169
    (access_id, access_jsonb_id, access_sku_label,
     item_code_before, item_code_after, reason)
SELECT
    acd.id,
    acd.raw_data->>'ID',
    acd.raw_data->>'SKU',
    acd.raw_data->>'ItemCode',
    CASE acd.raw_data->>'SKU'
        WHEN 'LOCK & KEY CABERNET SAUVIGNON' THEN '00513846'
        WHEN 'LOCK & KEY CHARDONNAY'         THEN '00513854'
        WHEN 'LOCK & KEY MERLOT'             THEN '00527308'
        WHEN 'LOCK & KEY PINOT NOIR'         THEN '00574583'
        WHEN 'LOCK & KEY RIESLING'           THEN '00513862'
        WHEN 'LOCK & KEY ROSE'               THEN '00513870'
        WHEN 'LOCK & KEY SAUVIGNON BLANC'    THEN '00513888'
        WHEN 'LOCK & KEY SHIRAZ'             THEN '00513896'
    END AS item_code_after,
    'B3-4-169 — empty raw_data ItemCode backfilled from per-SKU MODAL '
       || 'sibling short-code (8-digit Access cross-reference). HARD: '
       || 'within-table majority vote 12,472 sibling rows + xlsx Combined '
       || 'data Feb 25-Feb 26 + sku_code_map cross-validation. Scout: '
       || 'internal notes §3f. Supersedes '
       || 'schema/152 reverted by 155 (description-text cascade).' AS reason
FROM access_combined_data acd
WHERE (acd.raw_data->>'ItemCode' IS NULL OR acd.raw_data->>'ItemCode' = '')
  AND acd.raw_data->>'SKU' IN (
        'LOCK & KEY CABERNET SAUVIGNON',
        'LOCK & KEY CHARDONNAY',
        'LOCK & KEY MERLOT',
        'LOCK & KEY PINOT NOIR',
        'LOCK & KEY RIESLING',
        'LOCK & KEY ROSE',
        'LOCK & KEY SAUVIGNON BLANC',
        'LOCK & KEY SHIRAZ'
      )
ON CONFLICT (access_id) DO NOTHING;

DO $$
DECLARE v_audit_inserted BIGINT;
BEGIN
    SELECT count(*) INTO v_audit_inserted
      FROM b3_4_redo_audit_169
     WHERE set_by = 'schema/169_b3_4_redo';
    RAISE NOTICE 'B3-4 169 §3: b3_4_redo_audit_169 rows = %', v_audit_inserted;
    IF v_audit_inserted < 100 THEN
        RAISE EXCEPTION 'B3-4 169 §3 FAIL: only % audit rows captured (expected ~392)', v_audit_inserted;
    END IF;
END $$;

-- ────────────────────────────────────────────────────────────────────────────
-- §4 UPDATE access_combined_data — apply MODAL code to raw_data ItemCode
--    LENGTH guard built in: only writes codes <= 30 chars (always 8 here).
--    WHERE re-checks empty-ItemCode predicate for idempotency.
-- ────────────────────────────────────────────────────────────────────────────
UPDATE access_combined_data acd
   SET raw_data = jsonb_set(
                    acd.raw_data,
                    '{ItemCode}',
                    to_jsonb(m.item_code_after),
                    true
                  )
  FROM b3_4_redo_audit_169 m
 WHERE m.access_id = acd.id
   AND m.set_by = 'schema/169_b3_4_redo'
   AND (acd.raw_data->>'ItemCode' IS NULL OR acd.raw_data->>'ItemCode' = '')
   AND LENGTH(m.item_code_after) <= 30
   AND LENGTH(m.item_code_after) > 0;

-- ────────────────────────────────────────────────────────────────────────────
-- §5 POST-asserts
-- ────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    v_acd_post           BIGINT;
    v_broken_post        BIGINT;
    v_long_post          BIGINT;
    v_audit_count        BIGINT;
    v_view_collapse_post BIGINT;
BEGIN
    SELECT count(*) INTO v_acd_post FROM access_combined_data;
    IF v_acd_post < 100000 THEN
        RAISE EXCEPTION 'B3-4 169 §5 FAIL: access_combined_data rowcount % below floor — UPDATE leaked rows', v_acd_post;
    END IF;

    SELECT count(*) INTO v_broken_post
      FROM access_combined_data
     WHERE (raw_data->>'ItemCode' IS NULL OR raw_data->>'ItemCode' = '');
    IF v_broken_post > 10 THEN
        RAISE EXCEPTION 'B3-4 169 §5 FAIL: empty-ItemCode rows still % (expected <=10; target 0)', v_broken_post;
    END IF;

    SELECT count(*) INTO v_long_post
      FROM access_combined_data
     WHERE LENGTH(raw_data->>'ItemCode') > 30;
    IF v_long_post > 0 THEN
        RAISE EXCEPTION 'B3-4 169 §5 FAIL: long-text ItemCode rows % > 0 — modal-code write produced long text (impossible — 8 codes are 8 chars each)', v_long_post;
    END IF;

    SELECT count(*) INTO v_audit_count
      FROM b3_4_redo_audit_169 WHERE set_by = 'schema/169_b3_4_redo';
    IF v_audit_count < 100 THEN
        RAISE EXCEPTION 'B3-4 169 §5 FAIL: audit count % below floor 100', v_audit_count;
    END IF;

    -- View-side collapse — should drop from 392 → 0 (new codes ≠ canonical name).
    SELECT count(*) INTO v_view_collapse_post
      FROM combined_data_enriched
     WHERE source_system='access_db' AND item_code = sku AND item_code <> '';
    IF v_view_collapse_post >= 50 THEN
        RAISE EXCEPTION 'B3-4 169 §5 FAIL: view-side access_db collapse still % rows (expected <50; target 0)', v_view_collapse_post;
    END IF;

    RAISE NOTICE 'B3-4 169 §5 POST: acd=% / broken=% / long=% / audit=% / view_collapse=%',
                 v_acd_post, v_broken_post, v_long_post, v_audit_count, v_view_collapse_post;
END $$;

-- ────────────────────────────────────────────────────────────────────────────
-- §6 Migration registry
-- ────────────────────────────────────────────────────────────────────────────
INSERT INTO schema_migrations (version, applied_at, source)
VALUES ('169_b3_4_redo_access_db_itemcode', NOW(), 'live-apply')
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ════════════════════════════════════════════════════════════════════════════
-- ════════════════════════════════════════════════════════════════════════════
--
-- PRE-apply (should show ~392):
--   SELECT count(*) FROM access_combined_data
--    WHERE (raw_data->>'ItemCode' IS NULL OR raw_data->>'ItemCode' = '');
--   SELECT count(*) FROM combined_data_enriched
--    WHERE source_system='access_db' AND item_code = sku AND item_code <> '';
--
-- POST-apply (should show 0 / 0):
--   Same queries → 0 + 0.
--
-- POST-apply spot-check:
--   SELECT raw_data->>'ID', raw_data->>'SKU', raw_data->>'ItemCode'
--     FROM access_combined_data WHERE raw_data->>'ID' IN ('199400','199402','204611','234365');
--   EXPECTED: ItemCode = '00513846' / '00513854' / '00527308' / '00513870'
--
-- POST-apply L2:
--   EXPECTED: PASS (xfail marker can be removed in follow-up commit).
--
-- POST-apply L2 shape:
--   EXPECTED: PASS (no row has LENGTH > 30 — we wrote 8-char codes).
--
-- ════════════════════════════════════════════════════════════════════════════
-- ROLLBACK recipe (forward-only via audit table)
-- ════════════════════════════════════════════════════════════════════════════
-- Per-row rollback:
--   BEGIN;
--   UPDATE access_combined_data acd
--      SET raw_data = jsonb_set(
--                       acd.raw_data,
--                       '{ItemCode}',
--                       to_jsonb(COALESCE(m.item_code_before, '')::text),
--                       true)
--     FROM b3_4_redo_audit_169 m
--    WHERE m.access_id = acd.id
--      AND m.set_by = 'schema/169_b3_4_redo';
--   DELETE FROM b3_4_redo_audit_169 WHERE set_by = 'schema/169_b3_4_redo';
--   DELETE FROM schema_migrations WHERE version = '169_b3_4_redo_access_db_itemcode';
--   COMMIT;
--
-- Full-table rollback (last resort): restore access_combined_data from the
-- ════════════════════════════════════════════════════════════════════════════
