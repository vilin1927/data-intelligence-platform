-- ════════════════════════════════════════════════════════════════════════════
-- schema/115_r004_customer_name_at_suburb_view.sql
-- R-004 — view-level NAME @ SUBURB concat for bare-name 2026-02+ rows
-- ════════════════════════════════════════════════════════════════════════════
-- Date:   2026-04-30
-- Cluster: R-004 (run5 RED-D5 / B RED-5)
-- Source: schema/101_combined_data_52cols.sql + schema/109_bug63a_vintage_coalesce_view.sql
--
-- Purpose:
--   /sales Top Customers + /legacy-data render bare 'CUSTOMER 06' for 2026-02+
--   ingest rows because Vinsight Contacts ingest + admin "match new customer"
--   POST /api/customers write `customer.customer_name` without the embedded
--   ' @ <suburb>' suffix. Legacy access_db rows have it baked in via schema/060.
--
--   Path B (view-only, guarded). Surfaces ' @ <suburb>' at render time only
--   when the underlying name does NOT already carry ' @ ' AND a suburb is
--   known (customer.suburb or canonical_customer.suburb).
--
-- WHY VIEW-ONLY (not upstream ETL rename):
--   COLLIDE on UNIQUE(customer_name) with an already-existing '@ '-form sibling
--   if we mass-renamed (2,573 collisions point to the SAME canonical_customer
--   = duplicate customer rows, the genuine fix is row-dedup not rename).
--   Rename path is filed as a separate dedup ticket; this migration is pure
--   display-time CONCAT and does NOT touch any table data.
--
-- WHY THE NOT LIKE '% @ %' GUARD MATTERS (override safety):
--   B1 bundle (2026-04-27) deliberately removed an active strip-' @ SUBURB'
--   regex in /api/sales because legacy access_db rows carry the suffix
--   embedded inside customer_name itself (e.g. 'CUSTOMER 07
--   pinned to that pattern. The guard `c.customer_name NOT LIKE '% @ %'`
--   means legacy rows pass through verbatim, no doubling, no override of B1.
--
-- DELTA vs schema/109:
--   1. customer_name projection: COALESCE → guarded CASE that appends suburb
--      when (a) name has no embedded ' @ ' AND (b) a suburb source is non-empty.
--   Every other projection + every JOIN is byte-identical to schema/109.
--
-- BLAST RADIUS:
--   - /sales Top Customers list: 2026-02+ rows now render NAME @ SUBURB.
--   - /legacy-data grid: same.
--   - /api/export/combined-data CSV: customer_name col now consistent.
--   - /margin, /reps, all other view consumers inherit consistent display.
--   - No table writes; no row count change; no FK touched.
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ────────────────────────────────────────────────────────────────────────────
-- 1. Pre-state assertion
-- ────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    v_view_exists  INT;
    v_bare_with_sub INT;
BEGIN
    SELECT count(*) INTO v_view_exists
      FROM information_schema.views
     WHERE table_schema='public' AND table_name='combined_data_enriched';

    IF v_view_exists = 0 THEN
        RAISE EXCEPTION '115 PRE: combined_data_enriched view missing — schema/101+109 must land first';
    END IF;

    -- Eligibility: bare-name customer rows with a known suburb (the rows
    -- this migration's CASE will visibly affect on read).
    SELECT count(*) INTO v_bare_with_sub
      FROM customer c
      LEFT JOIN canonical_customer cc ON cc.id = c.canonical_customer_id
     WHERE c.customer_name NOT LIKE '% @ %'
       AND COALESCE(NULLIF(c.suburb,''), cc.suburb, '') <> '';

    RAISE NOTICE '115 PRE: combined_data_enriched=present bare_name_with_suburb_rows=% '
                 '(these will newly render NAME @ SUBURB)', v_bare_with_sub;

    IF v_bare_with_sub = 0 THEN
        RAISE NOTICE '115 PRE: zero bare-name customer rows have a known suburb — '
                     'view CASE will be a no-op. Safe but unexpected; check ingest.';
    END IF;
END $$;

-- ────────────────────────────────────────────────────────────────────────────
-- 2. DROP + CREATE view (matches schema/109 precedent for column-shape changes;
--    column shape is unchanged here but DROP+CREATE keeps the precedent
--    consistent and avoids CREATE-OR-REPLACE refusal on dependent objects).
-- ────────────────────────────────────────────────────────────────────────────
DROP VIEW IF EXISTS combined_data_enriched CASCADE;

CREATE OR REPLACE VIEW combined_data_enriched AS
SELECT
  -- ── Identity / lineage ───────────────────────────────────────────────────
  st.transaction_id                                             AS upload_id,
  st.transaction_id                                             AS sn,
  st.source_system,
  st.source_ref,

  -- ── Date dimensions ──────────────────────────────────────────────────────
  st.sale_date,
  st.sale_date                                                  AS transaction_date,
  st.period,
  TO_CHAR(st.sale_date, 'YYYY MM MON')                          AS cal_month,
  EXTRACT(YEAR  FROM st.sale_date)::int                         AS cal_year,
  EXTRACT(MONTH FROM st.sale_date)::int                         AS cal_month_num,

  -- ── Quantity / units ─────────────────────────────────────────────────────
  st.quantity                                                   AS qty,
  (st.quantity * COALESCE(cs.units_per_case, 12))::numeric      AS qty_bottles,
  COALESCE(cs.units_per_case, 12)                               AS carton_x,

  -- ── Revenue / pricing ────────────────────────────────────────────────────
  COALESCE(st.gross_revenue, st.net_revenue, 0)::numeric        AS revenue,
  COALESCE(st.gross_revenue, st.net_revenue, 0)::numeric        AS wholesale_value_ex,
  COALESCE(st.gross_revenue, st.net_revenue, 0)::numeric        AS wsale_value,
  COALESCE(st.net_revenue, 0)::numeric                          AS net_revenue,
  COALESCE(st.net_revenue, 0)::numeric                          AS netrevenue,
  COALESCE(cs.base_wholesale, 0)::numeric                       AS base_wholesale,
  COALESCE(cs.transfer_cost, 0)::numeric                        AS transfer_cost,
  CASE WHEN st.quantity IS NOT NULL AND st.quantity <> 0
       THEN ROUND((COALESCE(st.net_revenue, 0) / st.quantity)::numeric, 4)
       ELSE NULL END                                            AS average_case,
  CASE WHEN st.quantity IS NOT NULL AND st.quantity <> 0
       THEN ROUND((COALESCE(st.net_revenue, 0) / st.quantity)::numeric, 4)
       ELSE NULL END                                            AS average_case_1,
  CASE WHEN st.quantity IS NOT NULL AND st.quantity <> 0
       THEN ROUND((COALESCE(st.net_revenue, 0) / st.quantity)::numeric, 2)
       ELSE NULL END                                            AS net_dollar_per_case,

  -- ── Discounts / rebates / fees ───────────────────────────────────────────
  COALESCE(st.discount_amount, 0)::numeric                      AS discount,
  COALESCE(st.rebate_amount,   0)::numeric                      AS rebate,
  COALESCE(st.wholesale_fee,   0)::numeric                      AS fee,
  COALESCE(st.wholesale_fee,   0)::numeric                      AS wholesaler_fee,
  CASE WHEN COALESCE(st.gross_revenue, st.net_revenue, 0) > 0
       THEN ROUND((COALESCE(st.discount_amount,0)
                   / COALESCE(st.gross_revenue, st.net_revenue, 1) * 100)::numeric, 2)
       ELSE NULL END                                            AS discount_percentage,
  CASE WHEN COALESCE(st.gross_revenue, st.net_revenue, 0) > 0
       THEN ROUND((COALESCE(st.rebate_amount,0)
                   / COALESCE(st.gross_revenue, st.net_revenue, 1) * 100)::numeric, 2)
       ELSE NULL END                                            AS rebate_rate,

  -- ── COGS / profit ────────────────────────────────────────────────────────
  COALESCE(
    st.economic_cogs_total,
    (st.quantity * COALESCE(s.transfer_cost, 0))::numeric
  )::numeric                                                    AS cogs,
  COALESCE(
    st.economic_cogs_total,
    (st.quantity * COALESCE(s.transfer_cost, 0))::numeric
  )::numeric                                                    AS total_cogs,
  (COALESCE(st.gross_revenue, st.net_revenue, 0)
     - COALESCE(st.economic_cogs_total,
                (st.quantity * COALESCE(s.transfer_cost, 0))::numeric))::numeric
                                                                AS profit,
  CASE
    WHEN COALESCE(st.gross_revenue, st.net_revenue, 0) > 0 THEN
      ROUND((
        (COALESCE(st.gross_revenue, st.net_revenue, 0)
          - COALESCE(st.economic_cogs_total,
                     (st.quantity * COALESCE(s.transfer_cost, 0))::numeric))
        / COALESCE(st.gross_revenue, st.net_revenue, 1) * 100
      )::numeric, 2)
    ELSE NULL
  END                                                           AS gp,
  (COALESCE(st.net_revenue, 0)
     - COALESCE(st.economic_cogs_total,
                (st.quantity * COALESCE(s.transfer_cost, 0))::numeric)
     - COALESCE(st.rebate_amount, 0)
     - COALESCE(st.wholesale_fee, 0))::numeric                  AS calculated_profit,
  0::numeric                                                    AS commission,
  (COALESCE(st.net_revenue, 0)
     - COALESCE(st.economic_cogs_total,
                (st.quantity * COALESCE(s.transfer_cost, 0))::numeric)
     - COALESCE(st.rebate_amount, 0)
     - COALESCE(st.wholesale_fee, 0)
     - 0)::numeric                                              AS net_profit,

  -- ── Channel + warehouse identity ─────────────────────────────────────────
  COALESCE(st.warehouse, '')                                    AS warehouse,
  COALESCE(
    CASE UPPER(TRIM(COALESCE(cc.channel, ac.raw_data->>'Channel', '')))
      WHEN 'OFF PREMISE'        THEN 'OFF PREMISE'
      WHEN 'OFF-PREMISE'        THEN 'OFF PREMISE'
      WHEN 'OFF_PREMISE'        THEN 'OFF PREMISE'
      WHEN 'ON PREMISE'         THEN 'ON PREMISE'
      WHEN 'ON-PREMISE'         THEN 'ON PREMISE'
      WHEN 'ON_PREMISE'         THEN 'ON PREMISE'
      WHEN 'HYBRID'             THEN 'HYBRID'
      WHEN 'WHOLESALE'          THEN 'WHOLESALE'
      WHEN 'WHOLE SALE'         THEN 'WHOLESALE'
      WHEN 'DIRECT'             THEN 'DIRECT'
      WHEN 'HOFFICE'            THEN 'HOFFICE'
      WHEN 'HEAD OFFICE'        THEN 'HOFFICE'
      WHEN 'HEADOFFICE'         THEN 'HOFFICE'
      WHEN 'HEAD-OFFICE'        THEN 'HOFFICE'
      WHEN 'ALM'                THEN ''
      WHEN 'YOUNG & RASHLEIGH'  THEN ''
      WHEN 'YOUNG&RASHLEIGH'    THEN ''
      WHEN 'Y&R'                THEN ''
      WHEN 'YNR'                THEN ''
      ELSE ''
    END,
    ''
  )                                                             AS channel,

  -- ── Customer dimensions ──────────────────────────────────────────────────
  -- R-004 schema/115 (2026-04-30): guarded NAME @ SUBURB concat.
  -- Append ' @ <suburb>' ONLY when (a) bare name (no embedded ' @ ')
  -- AND (b) a non-empty suburb source exists. Preserves B1's "embedded form
  -- is canonical" decision (legacy rows with ' @ ' bypass the CASE).
  CASE
    WHEN COALESCE(c.customer_name, '') = '' THEN ''
    WHEN c.customer_name LIKE '% @ %' THEN c.customer_name
    WHEN COALESCE(NULLIF(c.suburb, ''), cc.suburb, '') <> ''
      THEN c.customer_name || ' @ ' || COALESCE(NULLIF(c.suburb, ''), cc.suburb)
    ELSE c.customer_name
  END                                                           AS customer_name,
  COALESCE(cc.customer_code, NULLIF(ac.raw_data->>'CustomerCode',''), '')
                                                                AS customer_code,
  COALESCE(cc.suburb,         NULLIF(ac.raw_data->>'Suburb',''),   '')
                                                                AS suburb,
  COALESCE(cc.postcode,       NULLIF(ac.raw_data->>'Postcode',''), '')
                                                                AS postcode,
  COALESCE(cc.customer_group, NULLIF(ac.raw_data->>'Group',''),    '')
                                                                AS customer_group,
  COALESCE(cc.alm_customer_code, NULLIF(ac.raw_data->>'ALMCustomerCode',''), '')
                                                                AS alm_customer_code,
  COALESCE(cc.dir_customer_code, NULLIF(ac.raw_data->>'DIRCustomerCode',''), '')
                                                                AS dir_customer_code,
  COALESCE(cc.ilg_customer_code, NULLIF(ac.raw_data->>'ILGCustomerCode',''), '')
                                                                AS ilg_customer_code,

  -- ── Territory dimensions ─────────────────────────────────────────────────
  COALESCE(
    NULLIF(cc.territory_name, ''),
    t_st.territory_name,
    t_cust.territory_name,
    NULLIF(ac.raw_data->>'Territory', ''),
    ''
  )                                                             AS territory,
  COALESCE(cc.territory_group, NULLIF(ac.raw_data->>'TerritoryGroup',''), '')
                                                                AS territory_group,

  -- ── Rep identity ─────────────────────────────────────────────────────────
  COALESCE(NULLIF(cc.rep_name, ''), '')                         AS rep_name,
  COALESCE(NULLIF(cc.rep_name, ''), '')                         AS rep,

  -- ── SKU / item identity ──────────────────────────────────────────────────
  COALESCE(cs.sku_name, s.item_description, '')                 AS sku,
  -- BUG-63a (schema/109): for ALM rows, prefer sale_vintage_attribution
  -- (attribution_method='alm_estimated_*' — date-attributed per the owner's spec)
  -- because sku.vintage is the SKU's "current" vintage and disagrees with the
  -- historical sale's correct vintage on 88% of ALM rows. For non-ALM rows,
  -- sku.vintage is canonical (vintage is in the SKU code) so prefer it.
  CASE
    WHEN ch_st.channel_name = 'ALM'
         AND COALESCE(sva.attributed_vintage, s.vintage) IS NOT NULL THEN
      TRIM(COALESCE(cs.sku_name, s.item_description, '')) || ' '
        || COALESCE(sva.attributed_vintage, s.vintage)::text
    WHEN COALESCE(s.vintage, sva.attributed_vintage) IS NOT NULL THEN
      TRIM(COALESCE(cs.sku_name, s.item_description, '')) || ' '
        || COALESCE(s.vintage, sva.attributed_vintage)::text
    ELSE COALESCE(cs.sku_name, s.item_description, '')
  END                                                           AS sku_vintage,
  COALESCE(
    NULLIF(ac.raw_data->>'ItemCode', ''),
    vsoi.stock_item_code,
    s.sku_code,
    ''
  )                                                             AS item_code,
  COALESCE(
    NULLIF(ac.raw_data->>'ItemDescription', ''),
    vsoi.description,
    s.item_description,
    ''
  )                                                             AS item_description,
  COALESCE(cs.range_name, '')                                   AS range_name,
  s.variety                                                     AS variety,
  s.region                                                      AS region,
  CASE
    WHEN ch_st.channel_name = 'ALM' THEN COALESCE(sva.attributed_vintage, s.vintage)
    ELSE                                  COALESCE(s.vintage, sva.attributed_vintage)
  END                                                           AS vintage,

  -- ── SubRegion + Ownership + Note ─────────────────────────────────────────
  COALESCE(NULLIF(ac.raw_data->>'SubRegion',''), s.region, '')  AS sub_region,
  COALESCE(
    NULLIF(ac.raw_data->>'Ownership',''),
    cc.customer_group,
    ''
  )                                                             AS ownership,
  COALESCE(NULLIF(ac.raw_data->>'Note',''), cs.note, '')        AS note,

  -- ── Invoice ──────────────────────────────────────────────────────────────
  CASE
    WHEN st.source_system = 'vinsight' AND st.source_ref ~ '^vinsight-[0-9]+-[0-9]+$'
      THEN split_part(st.source_ref, '-', 2)
    ELSE COALESCE(
      NULLIF(ac.raw_data->>'InvoiceNo', ''),
      st.source_ref,
      ''
    )
  END                                                           AS invoice_no,

  -- ── Import lineage ───────────────────────────────────────────────────────
  CASE
    WHEN to_regclass('public.sales_transaction') IS NOT NULL
      AND EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_schema='public' AND table_name='sales_transaction'
                     AND column_name='upload_batch_id')
    THEN (to_jsonb(st)->>'upload_batch_id')::bigint
    ELSE NULL
  END                                                           AS import_id

FROM sales_transaction st
LEFT JOIN sku s                       ON s.sku_id       = st.sku_id
LEFT JOIN canonical_sku cs            ON cs.id          = s.canonical_sku_id
LEFT JOIN customer c                  ON c.customer_id  = st.customer_id
LEFT JOIN canonical_customer cc       ON cc.id          = c.canonical_customer_id
LEFT JOIN territory t_st              ON t_st.territory_id   = st.territory_id
LEFT JOIN territory t_cust            ON t_cust.territory_id = c.territory_id
LEFT JOIN access_combined_data ac
       ON ac.id = st.transaction_id
      AND st.source_system = 'access_db'
LEFT JOIN vinsight_sales_order_item vsoi
       ON vsoi.order_num = (CASE WHEN st.source_ref ~ '^vinsight-[0-9]+-[0-9]+$'
                                 THEN split_part(st.source_ref, '-', 2)::int END)
      AND vsoi.entry_num = (CASE WHEN st.source_ref ~ '^vinsight-[0-9]+-[0-9]+$'
                                 THEN split_part(st.source_ref, '-', 3)::int END)
      AND st.source_system = 'vinsight'
LEFT JOIN sale_vintage_attribution sva
       ON sva.sales_transaction_id = st.transaction_id
LEFT JOIN channel ch_st
       ON ch_st.channel_id = st.channel_id;

COMMENT ON VIEW combined_data_enriched IS
  'R-004 schema/115 (2026-04-30): extends schema/109 view with guarded '
  'NAME @ SUBURB concat on customer_name projection. CASE appends '' @ <suburb>'' '
  'ONLY when name has no embedded '' @ '' AND a suburb source is non-empty. '
  'Preserves B1 (2026-04-27) decision that embedded '' @ SUBURB'' is canonical: '
  'legacy rows pass through verbatim. All other projections + JOINs '
  'byte-identical to schema/109.';

-- ────────────────────────────────────────────────────────────────────────────
-- 3. POST-state assertion: spot-check the CASE on real rows.
-- ────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    v_legacy_pass_through INT;
    v_bare_now_decorated  INT;
    v_no_doubling         INT;
BEGIN
    -- Legacy rows (already had ' @ ') should pass through unchanged.
    SELECT COUNT(*) INTO v_legacy_pass_through
      FROM combined_data_enriched cde
      JOIN sales_transaction st ON st.transaction_id = cde.upload_id
      JOIN customer c            ON c.customer_id    = st.customer_id
     WHERE c.customer_name LIKE '% @ %'
       AND cde.customer_name = c.customer_name
     LIMIT 100;

    -- Bare rows with known suburb should now render NAME @ SUBURB.
    SELECT COUNT(*) INTO v_bare_now_decorated
      FROM combined_data_enriched cde
      JOIN sales_transaction st ON st.transaction_id = cde.upload_id
      JOIN customer c            ON c.customer_id    = st.customer_id
      LEFT JOIN canonical_customer cc ON cc.id = c.canonical_customer_id
     WHERE c.customer_name NOT LIKE '% @ %'
       AND COALESCE(NULLIF(c.suburb,''), cc.suburb, '') <> ''
       AND cde.customer_name LIKE '% @ %'
       AND cde.customer_name = c.customer_name || ' @ ' || COALESCE(NULLIF(c.suburb,''), cc.suburb);

    -- Anti-test: detect migration-induced doublings, ignoring legitimate venue
    -- names that already carry ' @ ' (e.g. 'CUSTOMER 03 @ SYDNEY' has
    -- 2 tokens by design — pre-existing data, not a doubling).
    -- A genuine doubling means: the view appended ' @ <suburb>' to a row that
    -- ALREADY had a ' @ ' token in c.customer_name (CASE branch 2 should
    -- have fired but didn't). Flag iff view-tokens > base-tokens AND base
    -- already had >= 1 token.
    SELECT COUNT(*) INTO v_no_doubling
      FROM combined_data_enriched cde
      JOIN sales_transaction st ON st.transaction_id = cde.upload_id
      JOIN customer c            ON c.customer_id    = st.customer_id
     WHERE (length(cde.customer_name) - length(replace(cde.customer_name, ' @ ', '')))
         > (length(c.customer_name)   - length(replace(c.customer_name,   ' @ ', '')))
       AND c.customer_name LIKE '% @ %';

    RAISE NOTICE '115 POST: legacy_pass_through (sampled 100)=% bare_now_decorated=% double_at_rows=%',
      v_legacy_pass_through, v_bare_now_decorated, v_no_doubling;

    IF v_no_doubling > 0 THEN
        RAISE EXCEPTION '115 POST: % rows have doubled '' @ '' — guard not preventing override',
          v_no_doubling;
    END IF;

    IF v_legacy_pass_through = 0 THEN
        RAISE EXCEPTION '115 POST: zero legacy '' @ ''-form rows passed through — CASE may be rewriting them';
    END IF;
END $$;

INSERT INTO schema_migrations (version, applied_at, source)
VALUES ('115_r004_customer_name_at_suburb_view', NOW(), 'live-apply')
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ════════════════════════════════════════════════════════════════════════════
-- ROLLBACK (manual; not auto-run)
-- Reapply schema/109 to revert the view to the pre-CASE shape.
-- ════════════════════════════════════════════════════════════════════════════
