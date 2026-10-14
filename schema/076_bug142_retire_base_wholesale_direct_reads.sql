-- Migration 076: BUG-142 — retire direct canonical_sku.base_wholesale reads in
-- sync_vinsight_direct_sales() by routing through a new SQL function
-- `get_wholesale_price(sku_id int, as_of date)` that mirrors etl/get_wholesale_price.py
-- (ADR-009 source-selection logic).
--
-- ============================================================================
-- APPLIED 2026-04-25 in the BUG-142 + bundled deploy session. Renamed from
-- the placeholder schema/NNN_... to schema/076_... at apply time. Anchors:
-- git tag pre-bug142-deploy-2026-04-25 + pg_dump snapshot
-- /var/backups/moppity/full_pre_bug142.pgdump.
-- ============================================================================
--
-- Source of the design
-- --------------------
-- ADR-009 + etl/get_wholesale_price.py (Phase J BUG-103):
--   - Open period (no row in month_end_snapshot WHERE is_active=TRUE): read
--     current price from staging_vinsight_stock_items.raw_data->>'BaseWholesale'
--     (joined via sku.sku_code ↔ raw_data->>'ItemCode', ordered by fetched_at DESC).
--   - Closed period: read frozen price from canonical_sku.base_wholesale
--     (joined via sku.canonical_sku_id).
-- BUG-112 schema/074 amendment: closed = is_active=TRUE, not just row-present.
-- As of 2026-04-25 prod, 0 month_end_snapshot rows have is_active=TRUE, so the
-- function treats everything as OPEN period — matching current
-- sync_vinsight_direct_sales behaviour that reads live prices.
--
-- What this migration changes
-- ---------------------------
-- 1. CREATE OR REPLACE FUNCTION get_wholesale_price(p_sku_id int, p_as_of date)
--    RETURNS numeric — SQL clone of etl/get_wholesale_price.py.
-- 2. CREATE OR REPLACE FUNCTION sync_vinsight_direct_sales() — replaces both
--    COALESCE fallback branches (vinsight-map-joined base_wholesale + name-joined
--    base_wholesale) with a single get_wholesale_price(vc.sku_id, vc.sale_date)
--    call. Preserves the primary price source (vi.unit_price * (1 - discount))
--    from BUG-33 and all other BUG-113 / JR-089 logic from schema/050.
--
-- What this migration does NOT change
-- -----------------------------------
-- - schema/018 / 038 / 041 are ancestor versions superseded by schema/050.
--   Their base_wholesale reads are only present in the *old* function bodies
--   that prod already overwrote. The live function body = schema/050. So
--   retiring the direct reads means replacing schema/050's body; the earlier
--   files are historical-only (BUG-142 spec AC3 wording "retire in schema/018
--   038 041 050" should be read as "the in-prod sync_vinsight_direct_sales
--   lineage", not file-level edits).
-- - transform_to_core.py also references canonical_sku.base_wholesale but that
--   is Python code, not SQL function bodies; BUG-141 / separate ticket.
-- - canonical_sku.base_wholesale itself stays as the closed-period snapshot
--   column. ADR-009 requires it for the frozen branch.
--
-- Idempotency + rollback
-- ----------------------
-- Both CREATE OR REPLACE FUNCTION statements are idempotent on replay.
-- Rollback: restore the prior schema/050 sync_vinsight_direct_sales body
-- (available at git tag pre-bug142-deploy-2026-04-25 or pg_dump snapshot
-- /var/backups/moppity/full_pre_bug142.pgdump).
-- ============================================================================

BEGIN;

-- ────────────────────────────────────────────────────────────────────────────
-- Part 1: get_wholesale_price(sku_id, as_of_date)
-- ────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION get_wholesale_price(p_sku_id int, p_as_of date)
RETURNS numeric
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_period text;
  v_closed boolean;
  v_price numeric;
BEGIN
  -- Period resolution: YYYY-MM string matching month_end_snapshot.period.
  v_period := TO_CHAR(p_as_of, 'YYYY-MM');

  -- BUG-112 schema/074: closed = is_active=TRUE on the snapshot row.
  -- Row-exists-but-is_active=FALSE is intentional "structural row only".
  SELECT EXISTS (
    SELECT 1
    FROM month_end_snapshot
    WHERE period = v_period
      AND is_active = TRUE
  ) INTO v_closed;

  IF v_closed THEN
    -- Closed period → canonical frozen price.
    SELECT cs.base_wholesale
    INTO v_price
    FROM sku s
    JOIN canonical_sku cs ON cs.id = s.canonical_sku_id
    WHERE s.sku_id = p_sku_id;
  ELSE
    -- Open period → latest Vinsight BaseWholesale from raw staging data.
    SELECT (sv.raw_data->>'BaseWholesale')::numeric
    INTO v_price
    FROM staging_vinsight_stock_items sv
    JOIN sku s ON s.sku_code = sv.raw_data->>'ItemCode'
    WHERE s.sku_id = p_sku_id
      AND sv.raw_data->>'BaseWholesale' IS NOT NULL
    ORDER BY sv.fetched_at DESC
    LIMIT 1;

    -- If Vinsight has no row for this sku, fall back to canonical frozen so
    -- the consumer gets SOME price rather than NULL. Matches Python helper's
    -- behaviour of returning None → caller decides; SQL consumers would then
    -- get `unit_price=0` via the outer COALESCE, which is worse. Prefer
    -- frozen fallback.
    IF v_price IS NULL THEN
      SELECT cs.base_wholesale
      INTO v_price
      FROM sku s
      JOIN canonical_sku cs ON cs.id = s.canonical_sku_id
      WHERE s.sku_id = p_sku_id;
    END IF;
  END IF;

  RETURN v_price;
END;
$$;

COMMENT ON FUNCTION get_wholesale_price(int, date) IS
'BUG-142 / ADR-009: single-source-of-truth SQL wholesale price resolver. '
'Open period (no is_active=TRUE row in month_end_snapshot for YYYY-MM) → '
'latest staging_vinsight_stock_items.raw_data->>BaseWholesale. Closed period '
'→ canonical_sku.base_wholesale. Mirrors etl/get_wholesale_price.py behaviour. '
'SQL callers MUST route through this function rather than querying '
'canonical_sku.base_wholesale directly.';

-- ────────────────────────────────────────────────────────────────────────────
-- Part 2: sync_vinsight_direct_sales() — route fallbacks through get_wholesale_price
-- ────────────────────────────────────────────────────────────────────────────
--
-- Lineage:
--   schema/018 — original (base_wholesale pricing).
--   schema/038 — BUG-33 UoM fix.
--   schema/041 — JR-089 territory + rep populate.
--   schema/050 — BUG-113 Option D content_hash.
--   THIS FILE — BUG-142 retire direct base_wholesale reads.
--
-- Behaviour delta vs schema/050:
--   * COALESCE fallbacks #2 and #3 (two SELECT base_wholesale branches) are
--     replaced with a single call to get_wholesale_price(vc.sku_id, vc.sale_date).
--   * Primary branch (vi.unit_price * (1 - discount)) is unchanged.
--   * Name-lookup fallback on canonical_sku by sku_name regex is dropped:
--     it was always reachable only when the vinsight-mapped lookup returned
--     NULL, which meant the sku_code_map had no vinsight row for the code,
--     which meant vc.sku_id would also be NULL — so the INSERT's WHERE
--     vc.sku_id IS NOT NULL filter would already drop the row. The branch
--     was therefore unreachable; its removal is a no-op.
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

  -- Get the latest Access DB Direct sale date as cutoff
  SELECT COALESCE(MAX(sale_date), '2019-01-01')
  INTO v_cutoff_date
  FROM sales_transaction
  WHERE warehouse = 'Direct' AND source_system = 'access_db';

  -- Get Direct channel_id
  SELECT channel_id INTO v_direct_channel_id
  FROM channel WHERE channel_name = 'Direct';

  -- Build candidate rows from Vinsight items
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
    -- BUG-33: prefer actual invoice-line net price.
    -- BUG-142: fallback routes through get_wholesale_price() instead of
    --          reading canonical_sku.base_wholesale directly.
    --          The resolver is evaluated per-candidate-row with the
    --          candidate's own sale_date, so open/closed-period flips
    --          produce correct period-specific prices.
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

  -- Count items with no SKU match
  SELECT COUNT(*) INTO v_no_match FROM _vinsight_candidates WHERE sku_id IS NULL;

  -- Count items that already exist in sales_transaction
  SELECT COUNT(*) INTO v_skipped
  FROM _vinsight_candidates vc
  WHERE EXISTS (
    SELECT 1 FROM sales_transaction st WHERE st.source_ref = vc.source_ref
  );

  -- BUG-113 Option D: insert with content_hash.
  INSERT INTO sales_transaction (
    sku_id, customer_id, channel_id, sale_date, period,
    quantity, unit_price, net_revenue, gross_revenue,
    warehouse, source_system, source_ref,
    territory_id, rep_id,
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
  ON CONFLICT (content_hash) DO NOTHING;

  GET DIAGNOSTICS v_inserted = ROW_COUNT;

  IF v_inserted > 0 THEN
    PERFORM assign_vintage_cogs();
  END IF;

  RETURN QUERY SELECT v_inserted, v_skipped, v_no_match;

END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION sync_vinsight_direct_sales() IS
'BUG-142 (2026-04-25): unit_price fallback now routes through '
'get_wholesale_price(sku_id, sale_date) rather than reading canonical_sku.'
'base_wholesale directly. Open-period invoices pull latest Vinsight list; '
'closed-period invoices (future, once the owner flips is_active=TRUE in '
'month_end_snapshot) will pull the frozen canonical price. Retains BUG-113 '
'content_hash + schema/041 territory_id + rep_id + BUG-33 primary net-price.';

-- ────────────────────────────────────────────────────────────────────────────
-- Verification assertions (post-apply, idempotent)
-- ────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
  v_helper_exists int;
  v_func_body text;
BEGIN
  -- Assert the helper is in place.
  SELECT count(*) INTO v_helper_exists
  FROM pg_proc
  WHERE proname = 'get_wholesale_price';
  IF v_helper_exists = 0 THEN
    RAISE EXCEPTION 'BUG-142: get_wholesale_price function missing post-apply';
  END IF;

  -- Assert sync_vinsight_direct_sales references get_wholesale_price.
  SELECT pg_get_functiondef(oid) INTO v_func_body
  FROM pg_proc WHERE proname = 'sync_vinsight_direct_sales';
  IF v_func_body !~ 'get_wholesale_price' THEN
    RAISE EXCEPTION 'BUG-142: sync_vinsight_direct_sales body does not reference get_wholesale_price';
  END IF;
  IF v_func_body ~ 'cs\.base_wholesale FROM canonical_sku cs' THEN
    RAISE EXCEPTION 'BUG-142: sync_vinsight_direct_sales still contains a direct base_wholesale read';
  END IF;

  RAISE NOTICE 'BUG-142 post-apply assertions passed (helper present; no direct base_wholesale reads in sync_vinsight_direct_sales).';
END$$;

-- Record in schema_migrations (per BUG-118 Day-3 protocol). Prod table has
-- columns (version, applied_at, source); applied_at defaults to now(), so we
-- supply only version + source. (The migration's design-time intent of also
-- recording a `notes` blurb is captured in the header comment block above.)
INSERT INTO schema_migrations (version, source)
VALUES ('076_bug142_retire_base_wholesale_direct_reads', 'live-apply')
ON CONFLICT (version) DO NOTHING;

COMMIT;
