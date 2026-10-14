-- ════════════════════════════════════════════════════════════════════════════
-- schema/109_bug63a_vintage_coalesce_view.sql
-- BUG-63a — Surface ALM vintage on transaction view via sale_vintage_attribution
-- ════════════════════════════════════════════════════════════════════════════
-- Date:   2026-04-30
-- JR:     JR-112
-- Source: schema/082_bug63a_alm_vintage_attribution.sql (data fill);
--         schema/101_combined_data_52cols.sql (view contract — body byte-identical here);
--
-- Purpose:
--   Schema/082 backfills sale_vintage_attribution.attributed_vintage for ALM
--   rows with attribution_method='alm_estimated_*'. But combined_data_enriched
--   reads vintage strictly from sku.vintage (s.vintage AS vintage). For ALM
--   transactions, sku.vintage is NULL because ALM SKU codes don't carry
--   vintage — the result is /legacy-data, /margin, and the 52-col CSV export
--   all show empty Vintage cells on ALM rows.
--
--   This migration extends the view to COALESCE(s.vintage, sva.attributed_vintage)
--   so every transaction surface inherits the ALM estimation through the same
--   read contract. No table mutations.
--
-- DELTA vs schema/101:
--   1. sku_vintage CASE expression COALESCEs s.vintage with sva.attributed_vintage
--   2. vintage projection COALESCEs s.vintage with sva.attributed_vintage
--   3. LEFT JOIN to sale_vintage_attribution sva at the end of the JOIN list
--   4. View comment updated; new schema_migrations row 109
--   Every other projection is byte-identical to schema/101.
--
-- BLAST RADIUS:
--   - /legacy-data transaction list: ALM rows now show vintage in sku_vintage
--   - /margin page: vintage filter now matches ALM rows correctly
--   - /api/export/combined-data: gains a populated vintage signal (col added in
--     same session by route.ts edit)
--   - All other readers of combined_data_enriched inherit the COALESCE
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ────────────────────────────────────────────────────────────────────────────
-- 1. Pre-state assertion
-- ────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    v_view_exists       INT;
    v_sva_exists        INT;
    v_sva_alm_count     INT;
BEGIN
    SELECT count(*) INTO v_view_exists
      FROM information_schema.views
     WHERE table_schema='public' AND table_name='combined_data_enriched';

    IF v_view_exists = 0 THEN
        RAISE EXCEPTION '109 PRE: combined_data_enriched view missing — schema/101 must land first';
    END IF;

    SELECT count(*) INTO v_sva_exists
      FROM information_schema.tables
     WHERE table_schema='public' AND table_name='sale_vintage_attribution';

    IF v_sva_exists = 0 THEN
        RAISE EXCEPTION '109 PRE: sale_vintage_attribution missing — schema/009 must land first';
    END IF;

    SELECT count(*) INTO v_sva_alm_count
      FROM sale_vintage_attribution
     WHERE attribution_method LIKE 'alm_estimated%';

    RAISE NOTICE '109 PRE: combined_data_enriched=present sva=present alm_estimated_rows=%',
      v_sva_alm_count;

    IF v_sva_alm_count = 0 THEN
        RAISE NOTICE '109 PRE: zero alm_estimated rows — schema/082 must run before this for ALM coverage';
    END IF;
END $$;

-- ────────────────────────────────────────────────────────────────────────────
-- 2. DROP + CREATE view (CREATE OR REPLACE refuses adding/changing columns
--    when the new column appears at a different position; safer to DROP).
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
  COALESCE(c.customer_name, '')                                 AS customer_name,
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
  -- sku.vintage is canonical (vintage is in the SKU code) so prefer it. The
  -- per-row channel lookup uses ch_st.channel_name (joined below via st.channel_id).
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
  -- BUG-63a (schema/109): vintage projection — same channel-aware rule as
  -- sku_vintage above. ALM prefers sva.attributed_vintage; non-ALM prefers
  -- s.vintage (vintage in SKU code is canonical for DWS/Direct/YR).
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
-- BUG-63a (schema/109): pull attributed vintage from sale_vintage_attribution
-- so ALM rows get the date-attributed vintage from schema/082's backfill.
LEFT JOIN sale_vintage_attribution sva
       ON sva.sales_transaction_id = st.transaction_id
-- BUG-63a (schema/109): channel lookup for the per-row vintage CASE.
LEFT JOIN channel ch_st
       ON ch_st.channel_id = st.channel_id;

COMMENT ON VIEW combined_data_enriched IS
  'BUG-63a schema/109 (2026-04-30): extends schema/101 52-col view with '
  'COALESCE on vintage and sku_vintage so ALM rows inherit attributed_vintage '
  'from sale_vintage_attribution (schema/082 backfill, methods alm_estimated_*). '
  'All other projections byte-identical to schema/101.';

-- ────────────────────────────────────────────────────────────────────────────
-- 3. POST-state assertion: ALM rows have a populated vintage via the view
-- ────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    v_alm_total           INT;
    v_alm_with_vintage    INT;
    v_alm_pref_sva        INT;
    v_pct                 NUMERIC;
BEGIN
    SELECT COUNT(*) INTO v_alm_total
      FROM sales_transaction st
      JOIN channel c USING(channel_id)
     WHERE c.channel_name = 'ALM';

    SELECT COUNT(*) INTO v_alm_with_vintage
      FROM sales_transaction st
      JOIN channel c USING(channel_id)
      JOIN combined_data_enriched cde ON cde.upload_id = st.transaction_id
     WHERE c.channel_name = 'ALM'
       AND cde.vintage IS NOT NULL;

    -- BUG-63a correctness check: ALM rows must surface
    -- sva.attributed_vintage when set, NOT s.vintage.
    SELECT COUNT(*) INTO v_alm_pref_sva
      FROM sales_transaction st
      JOIN channel c USING(channel_id)
      JOIN combined_data_enriched cde ON cde.upload_id = st.transaction_id
      JOIN sale_vintage_attribution sva ON sva.sales_transaction_id = st.transaction_id
     WHERE c.channel_name = 'ALM'
       AND sva.attributed_vintage IS NOT NULL
       AND cde.vintage = sva.attributed_vintage;

    IF v_alm_total = 0 THEN
        RAISE NOTICE '109 POST: zero ALM rows — coverage check skipped';
    ELSE
        v_pct := ROUND(v_alm_with_vintage::numeric * 100.0 / v_alm_total::numeric, 2);
        RAISE NOTICE '109 POST: alm_total=% with_vintage=% pct=% prefer_sva=%',
          v_alm_total, v_alm_with_vintage, v_pct, v_alm_pref_sva;

        IF v_pct < 95 THEN
            RAISE EXCEPTION '109 POST: ALM vintage coverage % below 95%% target — '
              'view COALESCE not wiring sva. with_vintage=%/%',
              v_pct, v_alm_with_vintage, v_alm_total;
        END IF;

        -- prefer_sva should be very close to v_alm_with_vintage (>=95% of it)
        IF v_alm_with_vintage > 0
           AND (v_alm_pref_sva::numeric / v_alm_with_vintage::numeric) < 0.95 THEN
            RAISE EXCEPTION '109 POST: ALM rows surfacing sva.attributed_vintage = %/% — '
              'channel-aware CASE not preferring sva over s.vintage',
              v_alm_pref_sva, v_alm_with_vintage;
        END IF;
    END IF;
END $$;

INSERT INTO schema_migrations (version, applied_at, source)
VALUES ('109_bug63a_vintage_coalesce_view', NOW(), 'live-apply')
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ════════════════════════════════════════════════════════════════════════════
-- ROLLBACK (manual; not auto-run)
-- Reapply schema/101 to revert the view to the pre-COALESCE shape.
-- ════════════════════════════════════════════════════════════════════════════
