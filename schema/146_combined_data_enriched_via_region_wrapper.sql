-- ════════════════════════════════════════════════════════════════════════════
-- schema/146_combined_data_enriched_via_region_wrapper.sql
-- BUG-VIEW-CASCADE-DROP — Rebind combined_data_enriched view to JOIN
-- staging_vinsight_region_lookup wrapper (created in schema/145) instead of
-- staging_vinsight_stock_items directly. View body byte-identical to
-- schema/144 except 4 lines in the LATERAL subquery (per A3 §7f).
-- ════════════════════════════════════════════════════════════════════════════
-- Date:    2026-05-10
-- Ticket:  BUG-VIEW-CASCADE-DROP
-- Companion: schema/145_view_cascade_decouple_region_lookup.sql
--            etl/sync_vinsight_cogs.py (wrapper refresh patch line ~670)
--            etl/refresh_region_wrapper.sql (manual refresh fallback)
--
-- Why this migration exists:
--   schema/144 view JOINs staging_vinsight_stock_items directly (lines
--   333-339). The nightly Vinsight ETL shadow-swaps that staging table
--   with `RENAME live -> _old` + `DROP TABLE _old CASCADE`. The CASCADE
--   walks pg_depend and drops the view. schema/145 introduces a flat
--   refresh-table wrapper (zero pg_depend edges to staging). schema/146
--   rebinds the view's LATERAL subquery to read from the wrapper,
--   breaking the catalog dependency chain.
--
-- Diff vs schema/144 (4 lines only — per A3 §7f):
--
--   schema/144 line 334:
--     SELECT SUBSTRING(svs.raw_data->>'ProductCategories' FROM '(?i)region:([^;]+)') AS parsed,
--   schema/146 replacement:
--     SELECT svs.parsed_region AS parsed,
--
--   schema/144 line 335:
--     svs.raw_data->>'IsActive' AS is_active
--   schema/146 replacement:
--     svs.is_active AS is_active
--
--   schema/144 line 336:
--     FROM staging_vinsight_stock_items svs
--   schema/146 replacement:
--     FROM staging_vinsight_region_lookup svs
--
--   schema/144 line 339:
--     AND scm.external_code = svs.raw_data->>'StockItemCode'
--   schema/146 replacement:
--     AND scm.external_code = svs.stock_item_code
--
--   ALL other ~440 lines: byte-identical to schema/144 view body.
--
-- Reversibility:
--   Re-apply schema/144 verbatim (rebinds view to staging directly).
--   Wrapper table from schema/145 may stay in place (orphan but harmless).
--
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ────────────────────────────────────────────────────────────────────────────
-- PRE asserts — wrapper exists; view exists. Capture baseline rowcount only.
-- (Region distribution baseline pre-captured externally in pre_b1_view_def.txt
-- step. Full json_build_object aggregation across the view costs ~70s per run,
-- so PRE/POST byte-equivalence is verified via the materialized
-- _schema_146_region_dist temp snapshot below — single full scan amortized
-- across both PRE and POST checks instead of 4+ scans.)
-- ────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
  v_wrapper_exists boolean;
  v_view_exists    boolean;
  v_pre_count      bigint;
BEGIN
  v_wrapper_exists := to_regclass('public.staging_vinsight_region_lookup') IS NOT NULL;
  IF NOT v_wrapper_exists THEN
    RAISE EXCEPTION
      'PRE assert FAILED: staging_vinsight_region_lookup missing — apply schema/145 first';
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM information_schema.views
     WHERE table_schema = 'public'
       AND table_name   = 'combined_data_enriched'
  ) INTO v_view_exists;
  IF NOT v_view_exists THEN
    RAISE EXCEPTION 'PRE assert FAILED: combined_data_enriched view does not exist';
  END IF;

  EXECUTE 'SELECT COUNT(*) FROM combined_data_enriched' INTO v_pre_count;
  RAISE NOTICE 'PRE assert OK: combined_data_enriched exists, COUNT(*)=%', v_pre_count;
  PERFORM set_config('moppity.schema_146_pre_count', v_pre_count::text, false);
END$$;

-- Materialize PRE region distribution into a temp table (single full scan).
CREATE TEMP TABLE _schema_146_pre_dist ON COMMIT DROP AS
SELECT region, COUNT(*) AS cnt FROM combined_data_enriched GROUP BY region;

-- ────────────────────────────────────────────────────────────────────────────
-- Rebuild combined_data_enriched view — body byte-identical to schema/144
-- view body EXCEPT the 4-line LATERAL diff (lines 334, 335, 336, 339):
--   • SELECT svs.parsed_region AS parsed              (was SUBSTRING regex)
--   • svs.is_active AS is_active                      (was raw_data->>'IsActive')
--   • FROM staging_vinsight_region_lookup svs         (was staging_vinsight_stock_items)
--   • AND scm.external_code = svs.stock_item_code     (was raw_data->>'StockItemCode')
-- All other body byte-identical to schema/144.
-- ────────────────────────────────────────────────────────────────────────────
DROP VIEW IF EXISTS combined_data_enriched CASCADE;

CREATE OR REPLACE VIEW combined_data_enriched AS
SELECT
  -- ── Identity / lineage ───────────────────────────────────────────────────
  COALESCE(NULLIF(ac.raw_data->>'ID', '')::bigint, st.transaction_id::bigint)
                                                                AS upload_id,            -- Access "ID"  (col 1)
  COALESCE(NULLIF(ac.raw_data->>'ID', '')::bigint, st.transaction_id::bigint)
                                                                AS sn,                   -- Access "SN"  (col 2 — alias of ID)
  st.source_system,
  st.source_ref,

  -- ── Date dimensions ──────────────────────────────────────────────────────
  st.sale_date,
  st.sale_date                                                  AS transaction_date,     -- Access "TransactionDate" (col 14)
  st.period,                                                                             -- Access "CalYearMonth"    (col 18)
  TO_CHAR(st.sale_date, 'YYYY MM MON')                          AS cal_month,            -- Access "CalMonth"        (col 15)
  EXTRACT(YEAR  FROM st.sale_date)::int                         AS cal_year,             -- Access "CalYearx"        (col 16)
  EXTRACT(MONTH FROM st.sale_date)::int                         AS cal_month_num,        -- Access "CalMonthx"       (col 17)

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
  COALESCE(st.warehouse, '')                                    AS warehouse_channel,
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
  )                                                             AS premise_channel,

  -- ── Customer dimensions ──────────────────────────────────────────────────
  CASE
    WHEN COALESCE(c.customer_name, '') = '' THEN ''
    WHEN c.customer_name LIKE '% @ %' THEN c.customer_name
    WHEN COALESCE(NULLIF(c.suburb, ''), cc.suburb, '') <> ''
      THEN c.customer_name || ' @ ' || COALESCE(NULLIF(c.suburb, ''), cc.suburb)
    ELSE c.customer_name
  END                                                           AS customer_name,
  COALESCE(NULLIF(ac.raw_data->>'CustomerCode',''), cc.customer_code, '')
                                                                AS customer_code,        -- Access "CustomerCode" (col 4)
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
  COALESCE(cs.sku_name, s.item_description, '')                 AS sku,                  -- Access "SKU" (col 21)
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
  )                                                             AS item_code,            -- Access "ItemCode" (col 19)
  COALESCE(
    NULLIF(ac.raw_data->>'ItemDescription', ''),
    vsoi.description,
    s.item_description,
    ''
  )                                                             AS item_description,
  COALESCE(cs.range_name, '')                                   AS range_name,
  s.variety                                                     AS variety,
  -- ── Region — B4B-141 COALESCE chain (override-as-source-of-truth) ────────
  -- BUG-VIEW-CASCADE-DROP (schema/146, 2026-05-10): LATERAL subquery now
  -- reads from staging_vinsight_region_lookup wrapper (schema/145) instead
  -- of staging_vinsight_stock_items directly. Wrapper is a flat heap table
  -- refreshed by ETL after each shadow-swap. Decouples view from the
  -- staging CASCADE drop. View body otherwise byte-identical to schema/144.
  -- 1. mro.region        — manual_region_override (Owner-HARD)
  -- 2. TS Sauv Blanc guard — sku_id 87/88/89/12365/12366/12370/12371. The owner
  --                          ruled out Hilltops + Canberra. Force 'Unknown'.
  -- 3. Vinsight regex    — staging_vinsight_region_lookup (wrapper).
  --                        Same 'sea'/'sesa' filter as schema/142+.
  --                        Bridges via sku_code_map (source_system='vinsight').
  --                        Prefers active StockItems (svs.is_active DESC).
  -- 4. Brand fallback    — Coppabella/Procella(non-Clare) -> Tumbarumba;
  --                        Moppity/Lock & Key/Twelve Signs/Cato -> Hilltops.
  -- 5. 'Unknown'         — floor.
  COALESCE(
    mro.region,
    CASE WHEN s.sku_id IN (87, 88, 89, 12365, 12366, 12370, 12371)
         THEN 'Unknown'
    END,
    (
      SELECT
        CASE
          WHEN LOWER(parsed) IN ('sesa', 'sea')
            THEN 'South East Australia'
          WHEN LOWER(TRIM(parsed)) = 'tumba'
            THEN 'Tumbarumba'
          ELSE INITCAP(TRIM(parsed))
        END
      FROM (
        SELECT svs.parsed_region AS parsed,
               svs.is_active AS is_active
          FROM staging_vinsight_region_lookup svs
          JOIN sku_code_map scm
            ON scm.source_system = 'vinsight'
           AND scm.external_code = svs.stock_item_code
         WHERE scm.sku_id = s.sku_id
      ) v
      WHERE v.parsed IS NOT NULL
        AND TRIM(v.parsed) <> ''
        AND LOWER(TRIM(v.parsed)) NOT IN ('sea', 'sesa')
      ORDER BY v.is_active DESC NULLS LAST
      LIMIT 1
    ),
    CASE
      WHEN s.item_description ILIKE '%coppabella%'
        OR (s.item_description ILIKE '%procella%'
            AND s.item_description NOT ILIKE '%clare%'
            AND s.item_description NOT ILIKE '%cv %')
          THEN 'Tumbarumba'
      WHEN s.item_description ILIKE '%moppity%'
        OR s.item_description ILIKE '%lock & key%'
        OR s.item_description ILIKE '%lock&key%'
        OR s.item_description ILIKE '%twelve signs%'
        OR s.item_description ILIKE '%cato%'
          THEN 'Hilltops'
      ELSE NULL
    END,
    'Unknown'
  )                                                             AS region,
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
    WHEN st.source_system = 'access_db'
      THEN COALESCE(NULLIF(ac.raw_data->>'InvoiceNo', ''), '')
    ELSE COALESCE(
      NULLIF(ac.raw_data->>'InvoiceNo', ''),
      st.source_ref,
      ''
    )
  END                                                           AS invoice_no,           -- Access "InvoiceNo" (col 13)

  -- ── Import lineage ────────────────────────────────────────────────────────
  CASE
    WHEN to_regclass('public.sales_transaction') IS NOT NULL
      AND EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_schema='public' AND table_name='sales_transaction'
                     AND column_name='upload_batch_id')
    THEN (to_jsonb(st)->>'upload_batch_id')::bigint
    ELSE NULL
  END                                                           AS import_id            -- Access "ImportID" (col 41)

FROM sales_transaction st
LEFT JOIN sku s                       ON s.sku_id       = st.sku_id
LEFT JOIN canonical_sku cs            ON cs.id          = s.canonical_sku_id
LEFT JOIN customer c                  ON c.customer_id  = st.customer_id
LEFT JOIN canonical_customer cc       ON cc.id          = c.canonical_customer_id
LEFT JOIN territory t_st              ON t_st.territory_id   = st.territory_id
LEFT JOIN territory t_cust            ON t_cust.territory_id = c.territory_id
LEFT JOIN access_combined_data ac
       ON ac.raw_data->>'ID' = st.source_ref
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
       ON ch_st.channel_id = st.channel_id
LEFT JOIN manual_region_override mro
       ON mro.sku_id = s.sku_id;

COMMENT ON VIEW combined_data_enriched IS
  'BUG-VIEW-CASCADE-DROP schema/146 (2026-05-10): LATERAL subquery rebound '
  'to staging_vinsight_region_lookup wrapper (schema/145) instead of '
  'staging_vinsight_stock_items directly. Decouples view from nightly ETL '
  'CASCADE drop. View body otherwise byte-identical to schema/144 (B6 '
  'warehouse vs channel split, REGION-SEA-UNIFICATION sea/sesa filter, '
  'B4B-141 mro base + TS Sauv Blanc guard + brand fallback + Unknown floor, '
  'BUG-180d Lane F, R-004 NAME @ SUBURB, BUG-63a sva/channel).';

INSERT INTO schema_migrations (version, applied_at, source)
VALUES ('146_combined_data_enriched_via_region_wrapper', NOW(), 'live-apply')
ON CONFLICT (version) DO NOTHING;

-- ────────────────────────────────────────────────────────────────────────────
-- POST asserts (single combined scan strategy).
-- Materialize POST region distribution into temp table, then compare to PRE
-- via FULL OUTER JOIN. Avoids 4+ separate full-table scans of the slow view.
-- ────────────────────────────────────────────────────────────────────────────
CREATE TEMP TABLE _schema_146_post_dist ON COMMIT DROP AS
SELECT region,
       COUNT(*) AS cnt,
       SUM(CASE WHEN COALESCE(warehouse, '') = COALESCE(warehouse_channel, '') THEN 0 ELSE 1 END) AS wh_drift,
       SUM(CASE WHEN COALESCE(channel,   '') = COALESCE(premise_channel,   '') THEN 0 ELSE 1 END) AS pc_drift
  FROM combined_data_enriched
 GROUP BY region;

DO $$
DECLARE
  v_pre_count        bigint;
  v_post_count       bigint;
  v_drift_rows       bigint;
  v_drift_sample     text;
  v_wh_drift_total   bigint;
  v_pc_drift_total   bigint;
  v_sea_cells        bigint;
  v_canberra_cells   bigint;
  v_view_dep_staging bigint;
  v_view_dep_wrapper bigint;
BEGIN
  -- Rowcount invariant.
  v_pre_count := COALESCE(NULLIF(current_setting('moppity.schema_146_pre_count', true), ''), '0')::bigint;
  SELECT COALESCE(SUM(cnt), 0) INTO v_post_count FROM _schema_146_post_dist;
  IF v_post_count <> v_pre_count THEN
    RAISE EXCEPTION 'POST assert FAILED: rowcount drifted PRE=% POST=%',
      v_pre_count, v_post_count;
  END IF;
  RAISE NOTICE 'POST assert OK: rowcount unchanged (%)', v_post_count;

  -- Region distribution byte-equivalence. Postgres FULL OUTER JOIN requires
  -- merge/hash-joinable conditions, so equality on COALESCE-d region (NULL
  -- buckets become empty string for join purposes — we have no NULL regions
  -- in production view; this is defensive).
  SELECT COUNT(*),
         string_agg(COALESCE(p.region, q.region) || '=' ||
                    COALESCE(p.cnt::text, 'NULL') || '/' ||
                    COALESCE(q.cnt::text, 'NULL'), ', ')
    INTO v_drift_rows, v_drift_sample
    FROM (SELECT COALESCE(region, '') AS region, cnt FROM _schema_146_pre_dist) p
    FULL OUTER JOIN
         (SELECT COALESCE(region, '') AS region, cnt FROM _schema_146_post_dist) q
      ON p.region = q.region
   WHERE COALESCE(p.cnt, -1) <> COALESCE(q.cnt, -1);
  IF v_drift_rows IS NOT NULL AND v_drift_rows <> 0 THEN
    RAISE EXCEPTION 'POST assert FAILED: region distribution drift % rows: %',
      v_drift_rows, v_drift_sample;
  END IF;
  RAISE NOTICE 'POST assert OK: region distribution byte-identical to PRE (zero drift rows)';

  -- Surface PRE+POST region totals for human eyeball.
  RAISE NOTICE 'POST region distribution snapshot:';
  FOR v_drift_sample IN
    SELECT region || '=' || cnt::text
      FROM _schema_146_post_dist
     ORDER BY cnt DESC
  LOOP
    RAISE NOTICE '  %', v_drift_sample;
  END LOOP;

  -- B6 backward-compat parity (warehouse <-> warehouse_channel,
  -- channel <-> premise_channel).
  SELECT COALESCE(SUM(wh_drift), 0), COALESCE(SUM(pc_drift), 0)
    INTO v_wh_drift_total, v_pc_drift_total
    FROM _schema_146_post_dist;
  IF v_wh_drift_total <> 0 THEN
    RAISE EXCEPTION 'POST assert FAILED: wh_drift=% (warehouse vs warehouse_channel)', v_wh_drift_total;
  END IF;
  IF v_pc_drift_total <> 0 THEN
    RAISE EXCEPTION 'POST assert FAILED: pc_drift=% (channel vs premise_channel)', v_pc_drift_total;
  END IF;
  RAISE NOTICE 'POST assert OK: wh_drift=%, pc_drift=%', v_wh_drift_total, v_pc_drift_total;

  -- Zero Sea/Canberra cells (read from materialized temp, not full view).
  SELECT COALESCE(SUM(cnt), 0) INTO v_sea_cells
    FROM _schema_146_post_dist WHERE region = 'South East Australia';
  SELECT COALESCE(SUM(cnt), 0) INTO v_canberra_cells
    FROM _schema_146_post_dist WHERE region = 'Canberra';
  IF v_sea_cells <> 0 THEN
    RAISE EXCEPTION 'POST assert FAILED: South East Australia cells=% (must be 0)', v_sea_cells;
  END IF;
  IF v_canberra_cells <> 0 THEN
    RAISE EXCEPTION 'POST assert FAILED: Canberra cells=% (must be 0)', v_canberra_cells;
  END IF;
  RAISE NOTICE 'POST assert OK: zero Sea / zero Canberra cells';

  -- pg_depend graph: view depends on wrapper, NOT staging directly.
  SELECT COUNT(*) INTO v_view_dep_staging
    FROM pg_depend d
    JOIN pg_rewrite r ON d.objid = r.oid
    JOIN pg_class cls ON r.ev_class = cls.oid
    JOIN pg_class ref_cls ON d.refobjid = ref_cls.oid
   WHERE cls.relname = 'combined_data_enriched'
     AND ref_cls.relname = 'staging_vinsight_stock_items';

  SELECT COUNT(*) INTO v_view_dep_wrapper
    FROM pg_depend d
    JOIN pg_rewrite r ON d.objid = r.oid
    JOIN pg_class cls ON r.ev_class = cls.oid
    JOIN pg_class ref_cls ON d.refobjid = ref_cls.oid
   WHERE cls.relname = 'combined_data_enriched'
     AND ref_cls.relname = 'staging_vinsight_region_lookup';

  IF v_view_dep_staging > 0 THEN
    RAISE EXCEPTION 'POST assert FAILED: view STILL depends on staging_vinsight_stock_items (% edges) — fix did not decouple', v_view_dep_staging;
  END IF;
  IF v_view_dep_wrapper = 0 THEN
    RAISE EXCEPTION 'POST assert FAILED: view does NOT depend on staging_vinsight_region_lookup wrapper — rebind missed';
  END IF;
  RAISE NOTICE 'POST assert OK: view pg_depend -> wrapper edges=%, staging edges=%', v_view_dep_wrapper, v_view_dep_staging;
END$$;

COMMIT;
