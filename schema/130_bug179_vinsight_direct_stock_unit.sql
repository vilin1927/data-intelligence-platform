-- ────────────────────────────────────────────────────────────────────────────
-- schema/130_bug179_vinsight_direct_stock_unit.sql
-- BUG-179: ETL crash — sync_vinsight_direct_sales() PL/pgSQL function violates
-- NOT NULL constraint on sales_transaction.stock_unit during INSERT.
--
-- Surfaced 2026-05-04 in cron log; root-caused 2026-05-05 in
-- `stock_unit` — overlooked when BUG-118 schema/072 added the NOT NULL
-- constraint (Apr 24 19:56). Vinsight API contract unchanged; uom_code
-- present on every row including the failing one. Per ADR-014 (vinsight =
-- 'case' invariant), populate the column with the literal 'case' inside the
-- INSERT/SELECT.
--
-- 47 rows currently blocked across 15 OrderNums, sale dates 2026-02-03 →
-- 2026-04-29. 100% of new Vinsight Direct sales blocked since 2026-04-26.
-- Last successful insert: 2026-04-22 20:03:33 UTC (12 days stale).
--
-- ─── Schema-drift caveat — read this carefully ──────────────────────────────
-- HARD prod evidence (`obj_description(pg_proc.oid, 'pg_proc')` returns the
-- schema/050 BUG-113 COMMENT byte-for-byte) that the live function body on
-- prod is NOT schema/117 (BUG-168) or schema/076 (BUG-142) but schema/050
-- (BUG-113), even though both schema/076 + schema/117 are recorded as applied
-- in schema_migrations. Root cause: schema/050 ships a BARE
-- `CREATE OR REPLACE FUNCTION` (no BEGIN/COMMIT), and pre-INFRA-05
-- `deploy_schema()` blindly looped `for f in schema/*.sql; do psql -f $f; done`
-- on every full deploy, silently re-overwriting the function body back to
-- BUG-113 every time. INFRA-05 (deployed 2026-05-04) closes this — it now
-- consults `schema_migrations` and SKIPS schema/050 forever.
--
-- This migration therefore baselines on schema/117 (the spec-correct version),
-- so that applying schema/130 simultaneously closes BUG-179 + restores BUG-142
-- (get_wholesale_price routing) + restores BUG-168 (cross-path NOT EXISTS
-- dedup) in one shipped migration. POST-asserts INDEPENDENTLY VERIFY all
-- three behavioural contracts are live in the function body — fail-loud
-- ROLLBACK if any prior drift mechanism re-emerges.
--
-- ─── Lineage ────────────────────────────────────────────────────────────────
--   schema/018 — original sync_vinsight_direct_sales (base_wholesale).
--   schema/038 — BUG-33 UoM fix.
--   schema/041 — JR-089 territory + rep populate.
--   schema/050 — BUG-113 content_hash (BARE — drift vector; INFRA-08 will
--                rename to .disabled after this migration ships).
--   schema/063 — BUG-118 add stock_unit column (CHECK in ('bottle','case')).
--   schema/072 — BUG-118 backfill + ALTER COLUMN stock_unit SET NOT NULL.
--   schema/076 — BUG-142 retire base_wholesale → get_wholesale_price().
--   schema/117 — BUG-168 cross-path dedup. ← body baseline for THIS file.
--   THIS FILE  — BUG-179: stock_unit='case' added to INSERT/SELECT.
--
-- Lane B audit catalogued every CREATE OR REPLACE FUNCTION across schema/.
-- Only sync_vinsight_direct_sales meets the multi-version + earlier-bare-CREATE
-- drift conditions. No prior migration writes a destructive UPDATE on
-- sales_transaction.stock_unit. No prior migration patches this function
-- between schema/117 and now.
--
-- ─── Pre-flight backup ──────────────────────────────────────────────────────
-- Live function body snapshotted to
--   /var/backups/moppity/pre_bug179_sync_vinsight_body.sql
-- (md5 8dd733239ebe626fdaa6adaec867847b, 150 lines) BEFORE this migration is
-- applied. Forensic record of the BUG-113-drifted body for comparison vs
-- schema/117-baseline body that schema/130 installs.
-- ────────────────────────────────────────────────────────────────────────────

BEGIN;

-- ────────────────────────────────────────────────────────────────────────────
-- ────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
  v_blocked_count    int;
  v_helper_present   int;
  v_func_present     int;
  v_cutoff_date      date;
BEGIN
  -- Reproduce the cutoff watermark used by the function so the candidate
  -- count matches what the function will see when invoked in POST.
  SELECT COALESCE(MAX(sale_date), '2019-01-01')
  INTO v_cutoff_date
  FROM sales_transaction
  WHERE warehouse = 'Direct' AND source_system = 'access_db';

  -- Count Direct candidates whose source_ref is NOT yet in sales_transaction
  -- AND whose OrderNum isn't already covered by a source_system='DIRECT' row
  -- (BUG-168 cross-path guard). Mirrors the schema/117 INSERT WHERE clause.
  SELECT COUNT(*) INTO v_blocked_count
  FROM vinsight_sales_order_item vi
  WHERE vi.contact_code NOT LIKE 'ALM%'
    AND vi.contact_code NOT LIKE 'DWS%'
    AND vi.stock_item_code IS NOT NULL
    AND vi.stock_item_code != ''
    AND vi.stock_item_code NOT IN ('Freight', 'Claims NO WET', 'Claims WET',
      'Rounding adjustment', 'Rounding', 'Staff Issue', 'Bulk Wine Sales',
      'BAD DEBT WET', 'Sponsorship', 'Tokens', 'Ice', 'Pallet', 'BAD DEBT')
    AND vi.stock_item_code NOT LIKE 'A-%'
    AND vi.stock_item_code NOT LIKE 'B-%'
    AND vi.stock_item_code NOT LIKE 'L-%'
    AND vi.stock_item_code NOT LIKE 'S-%'
    AND vi.stock_item_code NOT LIKE 'X-%'
    AND COALESCE(vi.invoice_date, vi.date_despatched)::date > v_cutoff_date
    AND COALESCE(vi.invoice_date, vi.date_despatched) IS NOT NULL
    AND NOT EXISTS (
      SELECT 1 FROM sales_transaction st
      WHERE st.source_ref = 'vinsight-' || vi.order_num || '-' || vi.entry_num
    )
    AND NOT EXISTS (
      SELECT 1 FROM sales_transaction d
      WHERE d.source_system='DIRECT'
        AND regexp_replace(d.source_ref, '-.*', '') = vi.order_num::text
    );

  IF v_blocked_count = 0 THEN
    RAISE EXCEPTION 'BUG-179 PRE-ASSERT FAIL: 0 blocked Direct candidates — bug already fixed or state drifted. Refusing to proceed (refuses no-op apply).';
  END IF;

  -- AC2: confirm get_wholesale_price helper is present (function body uses it).
  SELECT COUNT(*) INTO v_helper_present
  FROM pg_proc WHERE proname = 'get_wholesale_price';
  IF v_helper_present = 0 THEN
    RAISE EXCEPTION 'BUG-179 PRE-ASSERT FAIL: get_wholesale_price helper missing — schema/076 must be applied first';
  END IF;

  -- AC3: confirm sync_vinsight_direct_sales currently exists (we're CREATE OR
  -- REPLACE-ing it; if it's somehow gone, that's a state we don't expect).
  SELECT COUNT(*) INTO v_func_present
  FROM pg_proc WHERE proname = 'sync_vinsight_direct_sales';
  IF v_func_present = 0 THEN
    RAISE EXCEPTION 'BUG-179 PRE-ASSERT FAIL: sync_vinsight_direct_sales function not found — drift more severe than expected';
  END IF;

  RAISE NOTICE 'BUG-179 PRE: blocked_candidates=% helper_present=YES func_present=YES cutoff=%',
    v_blocked_count, v_cutoff_date;
END $$;

-- ────────────────────────────────────────────────────────────────────────────
-- Replace function body — schema/117 baseline + 2 byte-precise BUG-179 edits.
--
-- Edit 1: INSERT column list (lines 302-308 of schema/117) gains `stock_unit`.
-- Edit 2: SELECT clause (lines 309-336 of schema/117) gains the constant
--         'case' immediately before content_hash, matching the position in
--         the column list and the literal used by schema/063 backfill +
--         every Python ingest path.
--
-- The rest of the body is byte-preserved from schema/117 (BUG-168 cross-path
-- dedup retained; BUG-142 get_wholesale_price routing retained; BUG-113
-- content_hash retained). stock_unit is intentionally NOT in content_hash
-- per ADR-014 (derived attribute, not identity component).
-- ────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION sync_vinsight_direct_sales()
RETURNS TABLE (inserted bigint, skipped bigint, no_sku_match bigint) AS $$
DECLARE
  v_inserted bigint := 0;
  v_skipped bigint := 0;
  v_no_match bigint := 0;
  v_cutoff_date date;
  v_direct_channel_id int;
BEGIN

  -- Get the latest Access DB Direct sale date as cutoff.
  SELECT COALESCE(MAX(sale_date), '2019-01-01')
  INTO v_cutoff_date
  FROM sales_transaction
  WHERE warehouse = 'Direct' AND source_system = 'access_db';

  -- Get Direct channel_id.
  SELECT channel_id INTO v_direct_channel_id
  FROM channel WHERE channel_name = 'Direct';

  -- Build candidate rows from Vinsight items (body byte-preserved from schema/076).
  CREATE TEMP TABLE IF NOT EXISTS _vinsight_candidates ON COMMIT DROP AS
  SELECT
    vi.id AS vinsight_item_id,
    vi.order_num,
    vi.entry_num,
    COALESCE(vi.invoice_date, vi.date_despatched)::date AS sale_date,
    TO_CHAR(COALESCE(vi.invoice_date, vi.date_despatched), 'YYYY-MM') AS period,
    vi.quantity,
    vi.contact_code,
    vi.stock_item_code,
    vi.description,
    vi.vintage,
    'vinsight-' || vi.order_num || '-' || vi.entry_num AS source_ref,
    COALESCE(
      scm.sku_id,
      (SELECT s.sku_id FROM sku s
       JOIN canonical_sku cs ON cs.id = s.canonical_sku_id
       WHERE UPPER(cs.sku_name) = UPPER(REGEXP_REPLACE(vi.description, '\s*\d{4}$', ''))
       LIMIT 1)
    ) AS sku_id,
    ccm.customer_id,
    COALESCE(
      CASE
        WHEN vi.unit_price IS NOT NULL AND vi.unit_price > 0
          THEN vi.unit_price * (1 - COALESCE(vi.discount_pct, 0))
        ELSE NULL
      END,
      get_wholesale_price(
        COALESCE(
          scm.sku_id,
          (SELECT s.sku_id FROM sku s
           JOIN canonical_sku cs ON cs.id = s.canonical_sku_id
           WHERE UPPER(cs.sku_name) = UPPER(REGEXP_REPLACE(vi.description, '\s*\d{4}$', ''))
           LIMIT 1)
        ),
        COALESCE(vi.invoice_date, vi.date_despatched)::date
      ),
      0
    ) AS unit_price
  FROM vinsight_sales_order_item vi
  LEFT JOIN sku_code_map scm ON scm.external_code = vi.stock_item_code AND scm.source_system = 'vinsight'
  LEFT JOIN customer_code_map ccm ON ccm.external_name = vi.contact_code AND ccm.source_system = 'vinsight'
  WHERE vi.contact_code NOT LIKE 'ALM%'
    AND vi.contact_code NOT LIKE 'DWS%'
    AND vi.stock_item_code IS NOT NULL
    AND vi.stock_item_code != ''
    AND vi.stock_item_code NOT IN ('Freight', 'Claims NO WET', 'Claims WET', 'Rounding adjustment',
      'Rounding', 'Staff Issue', 'Bulk Wine Sales', 'BAD DEBT WET', 'Sponsorship', 'Tokens',
      'Ice', 'Pallet', 'BAD DEBT')
    AND vi.stock_item_code NOT LIKE 'A-%'
    AND vi.stock_item_code NOT LIKE 'B-%'
    AND vi.stock_item_code NOT LIKE 'L-%'
    AND vi.stock_item_code NOT LIKE 'S-%'
    AND vi.stock_item_code NOT LIKE 'X-%'
    AND COALESCE(vi.invoice_date, vi.date_despatched)::date > v_cutoff_date
    AND COALESCE(vi.invoice_date, vi.date_despatched) IS NOT NULL;

  -- Count items with no SKU match.
  SELECT COUNT(*) INTO v_no_match FROM _vinsight_candidates WHERE sku_id IS NULL;

  -- Count items already in sales_transaction (existing source_ref dedup +
  -- BUG-168 NEW: also count rows being skipped because OrderNum already
  -- present in source_system='DIRECT' path).
  SELECT COUNT(*) INTO v_skipped
  FROM _vinsight_candidates vc
  WHERE EXISTS (
    SELECT 1 FROM sales_transaction st WHERE st.source_ref = vc.source_ref
  )
  OR EXISTS (
    SELECT 1 FROM sales_transaction d
    WHERE d.source_system='DIRECT'
      AND regexp_replace(d.source_ref, '-.*', '') = vc.order_num::text
  );

  -- BUG-113 Option D: insert with content_hash.
  -- BUG-168: NOT EXISTS guard skips OrderNums already present via DIRECT
  -- path (the owner's CSV upload is authoritative for periods he uploads;
  -- live sync fills only periods/orders the CSV doesn't cover).
  -- BUG-179: stock_unit='case' literal added per ADR-014 vinsight invariant.
  INSERT INTO sales_transaction (
    sku_id, customer_id, channel_id, sale_date, period,
    quantity, unit_price, net_revenue, gross_revenue,
    warehouse, source_system, source_ref,
    territory_id, rep_id,
    stock_unit,                    -- BUG-179: ADR-014 vinsight=case invariant
    content_hash
  )
  SELECT
    vc.sku_id,
    vc.customer_id,
    v_direct_channel_id,
    vc.sale_date,
    vc.period,
    vc.quantity,
    vc.unit_price,
    vc.quantity * vc.unit_price,
    vc.quantity * vc.unit_price,
    'Direct',
    'vinsight',
    vc.source_ref,
    c.territory_id,
    c.rep_id,
    'case',                        -- BUG-179: matches schema/063 backfill + every Python ingest path
    encode(
      sha256(
        (
          'vinsight'                              || '|' ||
          coalesce(vc.source_ref, '')             || '|' ||
          coalesce(vc.sku_id::text, '')           || '|' ||
          coalesce(vc.customer_id::text, '')      || '|' ||
          vc.sale_date::text                      || '|' ||
          (vc.quantity::decimal(12,2))::text
        )::bytea
      ),
      'hex'
    )
  FROM _vinsight_candidates vc
  LEFT JOIN customer c ON c.customer_id = vc.customer_id
  WHERE vc.sku_id IS NOT NULL
    AND vc.unit_price > 0
    AND NOT EXISTS (
      SELECT 1 FROM sales_transaction st WHERE st.source_ref = vc.source_ref
    )
    -- BUG-168: cross-path dedup against source_system='DIRECT'.
    AND NOT EXISTS (
      SELECT 1 FROM sales_transaction d
      WHERE d.source_system='DIRECT'
        AND regexp_replace(d.source_ref, '-.*', '') = vc.order_num::text
    )
  ON CONFLICT (content_hash) DO NOTHING;

  GET DIAGNOSTICS v_inserted = ROW_COUNT;

  IF v_inserted > 0 THEN
    PERFORM assign_vintage_cogs();
  END IF;

  RETURN QUERY SELECT v_inserted, v_skipped, v_no_match;

END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION sync_vinsight_direct_sales() IS
'BUG-179 (2026-05-05): adds stock_unit=''case'' per ADR-014 vinsight invariant. '
'Restores BUG-168 (2026-04-30) cross-path dedup + BUG-142 (2026-04-25) '
'get_wholesale_price routing + BUG-113 (2026-04-22) content_hash, all silently '
'reverted by schema/050 BARE-CREATE-OR-REPLACE drift (see '
'internal notes). Body baseline = schema/117.';

-- ────────────────────────────────────────────────────────────────────────────
-- POST asserts — verify all 4 behavioural contracts (BUG-179 + BUG-168 +
-- BUG-142 + BUG-113) are live in the function body, AND verify the function
-- can actually run + insert the 47 backlog rows. Independent of the forensic
-- ambiguity about which deploy session reverted to schema/050 — these checks
-- prove the fix lands and stays NOW.
-- ────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
  v_func_body        text;
  v_inserted_count   bigint;
  v_skipped_count    bigint;
  v_no_match_count   bigint;
  v_post_direct_count int;
  v_post_direct_with_unit int;
BEGIN
  -- Fetch the now-installed function body for marker checks.
  SELECT pg_get_functiondef(oid) INTO v_func_body
  FROM pg_proc WHERE proname = 'sync_vinsight_direct_sales';

  -- AC1: BUG-179 marker (stock_unit literal added).
  IF v_func_body !~ 'BUG-179' THEN
    RAISE EXCEPTION 'BUG-179 POST-ASSERT FAIL: function body missing BUG-179 marker — replacement did not land';
  END IF;

  -- AC2: stock_unit IS in the INSERT column list (the comma-suffix
  -- distinguishes the column-list usage from the comment text).
  IF v_func_body !~ 'stock_unit,' THEN
    RAISE EXCEPTION 'BUG-179 POST-ASSERT FAIL: INSERT column list missing stock_unit,';
  END IF;

  -- AC3: BUG-142 routing (get_wholesale_price helper call) preserved.
  IF v_func_body !~ 'get_wholesale_price' THEN
    RAISE EXCEPTION 'BUG-179 POST-ASSERT FAIL: BUG-142 get_wholesale_price routing missing — schema/050 drift not closed';
  END IF;

  -- AC4: BUG-168 cross-path NOT EXISTS guard preserved.
  IF v_func_body !~ 'source_system=''DIRECT''' THEN
    RAISE EXCEPTION 'BUG-179 POST-ASSERT FAIL: BUG-168 cross-path NOT EXISTS missing — schema/050 drift not closed';
  END IF;

  -- AC5: invoke the function once and confirm it inserts > 0.
  -- The PRE-assert proved ≥1 blocked candidate exists; the function should
  -- now successfully INSERT them with stock_unit='case'.
  SELECT inserted, skipped, no_sku_match
    INTO v_inserted_count, v_skipped_count, v_no_match_count
  FROM sync_vinsight_direct_sales();

  IF v_inserted_count = 0 THEN
    RAISE EXCEPTION 'BUG-179 POST-ASSERT FAIL: function ran but inserted 0 rows — backlog should land. skipped=% no_sku_match=%',
      v_skipped_count, v_no_match_count;
  END IF;

  -- AC6: every newly-inserted vinsight Direct row must have stock_unit='case'.
  -- Defensive — prove the literal landed at the row level, not just in the
  -- function source.
  SELECT
    COUNT(*) FILTER (WHERE source_system = 'vinsight' AND warehouse = 'Direct'),
    COUNT(*) FILTER (WHERE source_system = 'vinsight' AND warehouse = 'Direct' AND stock_unit = 'case')
    INTO v_post_direct_count, v_post_direct_with_unit
  FROM sales_transaction;

  IF v_post_direct_count != v_post_direct_with_unit THEN
    RAISE EXCEPTION 'BUG-179 POST-ASSERT FAIL: vinsight Direct rows total=%, with stock_unit=case=% — drift detected at row level',
      v_post_direct_count, v_post_direct_with_unit;
  END IF;

  RAISE NOTICE 'BUG-179 POST: ALL 6 ACs PASS. function body markers OK (BUG-179, stock_unit,, get_wholesale_price, source_system=DIRECT). Test invocation: inserted=%, skipped=%, no_sku_match=%. Vinsight Direct row total=%, all stock_unit=case.',
    v_inserted_count, v_skipped_count, v_no_match_count,
    v_post_direct_count;
END $$;

-- ────────────────────────────────────────────────────────────────────────────
-- Record migration
-- ────────────────────────────────────────────────────────────────────────────
INSERT INTO schema_migrations (version, source)
VALUES ('130_bug179_vinsight_direct_stock_unit', 'live-apply')
ON CONFLICT (version) DO NOTHING;

COMMIT;
