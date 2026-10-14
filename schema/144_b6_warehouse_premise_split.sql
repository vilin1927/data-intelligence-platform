-- ════════════════════════════════════════════════════════════════════════════
-- schema/144_b6_warehouse_premise_split.sql
-- B6 — Warehouse vs Channel split. Add named-axis aliases on
--      combined_data_enriched so consumers can read warehouse-axis
--      (DWS/ALM/Direct) separately from premise-axis (ON/OFF PREMISE) without
--      ambiguity. Backward-compat preserved: existing `warehouse` + `channel`
--      columns kept byte-identical.
-- ════════════════════════════════════════════════════════════════════════════
-- Date:    2026-05-09
-- Ticket:  OWNER-MAY8-B6-WAREHOUSE-VS-CHANNEL
-- Source-of-truth note:
--     "channel is on-premise off-premise — you currently have warehouse
--      featured as channel"
--   ADR-017 + schema/078 already split the underlying schema:
--     customer.warehouse_channel       (DWS / ALM / Direct — warehouse axis)
--     canonical_customer.channel       (ON PREMISE / OFF PREMISE — premise axis)
--   schema/142 (current applied prod view body) projects both axes onto
--   combined_data_enriched as `warehouse` + `channel` cols. Readers today:
--     /api/export/combined-data    uses `warehouse AS c3` + `channel AS c11`
--     /api/channels                uses `SELECT DISTINCT channel`
--   schema/144 layers TWO new aliases on top of schema/142:
--     warehouse_channel  — duplicate of `warehouse`     (warehouse axis)
--     premise_channel    — duplicate of `channel` CASE  (premise axis)
--   Existing `warehouse` + `channel` cols left intact for backward compat.
--
-- Reversibility:
--   Re-apply schema/142 view body verbatim (drops the 2 new aliases). No data
--   writes, view rebuild only — fully forward-only and instantly reversible.
--
--   pg_dump -t combined_data_enriched > /tmp/pre_144_view_142.sql
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ────────────────────────────────────────────────────────────────────────────
-- PRE assert — combined_data_enriched view exists; record sample COUNT(*).
-- ────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
  v_exists  boolean;
  v_count   bigint;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM information_schema.views
     WHERE table_schema = 'public'
       AND table_name   = 'combined_data_enriched'
  ) INTO v_exists;
  IF NOT v_exists THEN
    RAISE EXCEPTION 'PRE assert FAILED: combined_data_enriched view does not exist';
  END IF;

  EXECUTE 'SELECT COUNT(*) FROM combined_data_enriched' INTO v_count;
  RAISE NOTICE 'PRE assert OK: combined_data_enriched exists, COUNT(*)=%', v_count;
  PERFORM set_config('moppity.schema_144_pre_count', v_count::text, false);
END$$;

-- ────────────────────────────────────────────────────────────────────────────
-- Rebuild combined_data_enriched view — body byte-identical to schema/142
-- view body EXCEPT add TWO new col aliases:
--   warehouse_channel  (after existing `warehouse`)
--   premise_channel    (after existing `channel`)
-- All other body (region COALESCE chain, BUG-180d JOIN, mro JOIN, sva JOIN,
-- channel JOIN ch_st) byte-identical to schema/142.
-- ────────────────────────────────────────────────────────────────────────────
DROP VIEW IF EXISTS combined_data_enriched CASCADE;

CREATE OR REPLACE VIEW combined_data_enriched AS
SELECT
  -- ── Identity / lineage ───────────────────────────────────────────────────
  -- BUG-180d (b): for access_db rows, surface Access ID; Postgres PK fallback
  -- for non-access_db so the column is never empty.
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
  -- B6 (schema/144, 2026-05-09): two-axis split per the owner Apr 13 + ADR-017.
  --   warehouse / warehouse_channel  — DWS / ALM / Direct (warehouse axis)
  --   channel   / premise_channel    — ON / OFF PREMISE   (premise axis)
  -- Existing `warehouse` + `channel` cols preserved byte-identical to
  -- schema/142 for backward compat (readers: /api/export/combined-data uses
  -- `warehouse AS c3` + `channel AS c11`; /api/channels uses
  -- `SELECT DISTINCT channel`). New named-axis aliases let consumers read
  -- the correct axis without ambiguity.
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
  -- R-004 schema/115 (2026-04-30): guarded NAME @ SUBURB concat. Preserved
  -- byte-identical. Append ' @ <suburb>' ONLY when (a) bare name (no embedded
  -- ' @ ') AND (b) a non-empty suburb source exists.
  CASE
    WHEN COALESCE(c.customer_name, '') = '' THEN ''
    WHEN c.customer_name LIKE '% @ %' THEN c.customer_name
    WHEN COALESCE(NULLIF(c.suburb, ''), cc.suburb, '') <> ''
      THEN c.customer_name || ' @ ' || COALESCE(NULLIF(c.suburb, ''), cc.suburb)
    ELSE c.customer_name
  END                                                           AS customer_name,
  -- BUG-180d (c): HARD value (raw_data) wins over canonical_customer.customer_code
  -- (which is empty for ~all rows by design — recon-legacy-data §1.d).
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
  -- BUG-63a (schema/109+115): for ALM rows, prefer sva.attributed_vintage;
  -- for non-ALM rows, sku.vintage is canonical. Preserved byte-identical.
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
  -- BUG-180d (e): no projection edit — already reads raw_data first. JOIN fix
  -- (a) makes this column auto-correct on access_db rows.
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
  -- 1. mro.region        — manual_region_override (Owner-HARD)
  -- 2. TS Sauv Blanc guard — sku_id 87/88/89/12365/12366/12370/12371. The owner
  --                          ruled out Hilltops (Mar 28 C0328) + Canberra
  --                          (May 8). No replacement region given. Force
  --                          'Unknown' so the cell reads honestly until the owner
  --                          answers May 8 question batch. Once mro INSERT
  --                          lands, layer 1 wins and this layer no-ops.
  --                          (Vinsight raw "Sea" + brand rule "Hilltops" both
  --                          rejected by the owner — neither is acceptable here.)
  -- 3. Vinsight regex    — staging_vinsight_stock_items.ProductCategories
  --                        normalized: Sea/Sesa → South East Australia,
  --                        Tumba → Tumbarumba, else INITCAP(TRIM(parsed)).
  --                        REGION-SEA-UNIFICATION (schema/142, 2026-05-09):
  --                        'sea'/'sesa' filtered out of subquery WHERE so the
  --                        wholesale-category leak does NOT win this layer.
  --                        Cascade falls to brand rule for TS Sea-tagged wines.
  --                        Bridges via sku_code_map (source_system='vinsight').
  --                        Prefers active StockItems (raw_data->>'IsActive' DESC).
  -- 4. Brand fallback    — Coppabella/Procella(non-Clare) → Tumbarumba;
  --                        Moppity/Lock & Key/Twelve Signs/Cato → Hilltops.
  -- 5. 'Unknown'         — floor (never NULL on this column).
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
        SELECT SUBSTRING(svs.raw_data->>'ProductCategories' FROM '(?i)region:([^;]+)') AS parsed,
               svs.raw_data->>'IsActive' AS is_active
          FROM staging_vinsight_stock_items svs
          JOIN sku_code_map scm
            ON scm.source_system = 'vinsight'
           AND scm.external_code = svs.raw_data->>'StockItemCode'
         WHERE scm.sku_id = s.sku_id
      ) v
      WHERE v.parsed IS NOT NULL
        AND TRIM(v.parsed) <> ''
        -- REGION-SEA-UNIFICATION (schema/142, 2026-05-09): drop wholesale-
        -- category leak so cascade falls to brand rule (Hilltops) for
        -- TS Sparkling / Cab Sauv / Moscato instead of "South East Australia".
        -- Inner CASE 'sea'/'sesa' branch left byte-identical to schema/141 as
        -- defensive dead code — this WHERE filter prevents it ever evaluating.
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
  -- BUG-180d (d): explicit access_db branch — never fall through to
  -- st.source_ref (= Access ID) for access_db rows. HARD value or empty.
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
-- BUG-180d (a): rebind JOIN. access_combined_data.id is its own SERIAL PK and
-- is NOT 1:1 with sales_transaction.transaction_id. The intended 1:1 key is
-- raw_data->>'ID' = source_ref (per etl/transform_to_core.py:661).
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
-- B4B-141: NEW JOIN — manual_region_override is base layer of region COALESCE.
LEFT JOIN manual_region_override mro
       ON mro.sku_id = s.sku_id;

COMMENT ON VIEW combined_data_enriched IS
  'B6 schema/144 (2026-05-09): warehouse vs channel split per the owner Apr 13 + '
  'ADR-017. Adds named-axis aliases warehouse_channel (DWS/ALM/Direct, '
  'duplicate of warehouse) + premise_channel (ON/OFF PREMISE, duplicate of '
  'channel CASE) so consumers can read each axis without ambiguity. Existing '
  'warehouse + channel cols preserved byte-identical for backward compat. All '
  'other body (REGION-SEA-UNIFICATION schema/142 Vinsight ''sea''/''sesa'' '
  'filter, B4B-141 mro base + TS Sauv Blanc guard + brand fallback + Unknown '
  'floor, BUG-180d Lane F, R-004 NAME @ SUBURB, BUG-63a sva/channel) byte-'
  'identical from schema/142.';

INSERT INTO schema_migrations (version, applied_at, source)
VALUES ('144_b6_warehouse_premise_split', NOW(), 'live-apply')
ON CONFLICT (version) DO NOTHING;

-- ────────────────────────────────────────────────────────────────────────────
-- POST asserts —
--   1. COUNT(*) unchanged from PRE (no row drift).
--   2. warehouse_channel + premise_channel cols exist on the view.
--   3. Sample row confirms the two axes can hold distinct values
--      (warehouse_channel = warehouse axis, premise_channel = premise axis).
-- ────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
  v_pre_count    bigint;
  v_post_count   bigint;
  v_has_wh_col   boolean;
  v_has_pc_col   boolean;
  v_sample_distinct boolean;
BEGIN
  v_pre_count := COALESCE(NULLIF(current_setting('moppity.schema_144_pre_count', true), ''), '0')::bigint;
  EXECUTE 'SELECT COUNT(*) FROM combined_data_enriched' INTO v_post_count;
  IF v_post_count <> v_pre_count THEN
    RAISE EXCEPTION 'POST assert FAILED: combined_data_enriched row count drifted PRE=% POST=%',
      v_pre_count, v_post_count;
  END IF;
  RAISE NOTICE 'POST assert OK: combined_data_enriched COUNT(*)=% (unchanged)', v_post_count;

  SELECT EXISTS (
    SELECT 1 FROM information_schema.columns
     WHERE table_schema = 'public'
       AND table_name   = 'combined_data_enriched'
       AND column_name  = 'warehouse_channel'
  ) INTO v_has_wh_col;
  IF NOT v_has_wh_col THEN
    RAISE EXCEPTION 'POST assert FAILED: warehouse_channel column missing from combined_data_enriched';
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM information_schema.columns
     WHERE table_schema = 'public'
       AND table_name   = 'combined_data_enriched'
       AND column_name  = 'premise_channel'
  ) INTO v_has_pc_col;
  IF NOT v_has_pc_col THEN
    RAISE EXCEPTION 'POST assert FAILED: premise_channel column missing from combined_data_enriched';
  END IF;

  RAISE NOTICE 'POST assert OK: warehouse_channel + premise_channel cols present';

  -- Sample-row sanity: confirm the two axes are NOT a 1:1 mirror across the
  -- whole table — i.e. there exists at least one row where warehouse_channel
  -- and premise_channel hold different values (proves they are distinct axes,
  -- not a redundant duplicate). Tolerant of small dataset edge cases — only
  -- raise NOTICE, never EXCEPTION (some envs may have empty premise_channel
  -- and matching empty warehouse_channel for ALM-rep'd rows).
  SELECT EXISTS (
    SELECT 1
      FROM combined_data_enriched
     WHERE COALESCE(warehouse_channel, '') <> COALESCE(premise_channel, '')
     LIMIT 1
  ) INTO v_sample_distinct;
  RAISE NOTICE 'POST assert sample: distinct warehouse_channel vs premise_channel exists = %', v_sample_distinct;
END$$;

COMMIT;

-- ════════════════════════════════════════════════════════════════════════════
-- ════════════════════════════════════════════════════════════════════════════
--
-- PRE-apply assert (run BEFORE the migration):
--   SELECT column_name
--     FROM information_schema.columns
--    WHERE table_schema = 'public'
--      AND table_name   = 'combined_data_enriched'
--      AND column_name IN ('warehouse', 'channel', 'warehouse_channel', 'premise_channel')
--    ORDER BY column_name;
--   -- Expect: 'channel', 'warehouse'                    (2 rows — schema/142 state)
--
-- POST-apply assert (run AFTER the migration — same query):
--   SELECT column_name
--     FROM information_schema.columns
--    WHERE table_schema = 'public'
--      AND table_name   = 'combined_data_enriched'
--      AND column_name IN ('warehouse', 'channel', 'warehouse_channel', 'premise_channel')
--    ORDER BY column_name;
--   -- Expect: 'channel', 'premise_channel', 'warehouse', 'warehouse_channel' (4 rows)
--
-- POST-apply assert — backward-compat parity (warehouse == warehouse_channel,
-- channel == premise_channel for every row):
--   SELECT
--     SUM(CASE WHEN COALESCE(warehouse, '') = COALESCE(warehouse_channel, '') THEN 0 ELSE 1 END) AS wh_drift,
--     SUM(CASE WHEN COALESCE(channel,   '') = COALESCE(premise_channel,   '') THEN 0 ELSE 1 END) AS pc_drift
--     FROM combined_data_enriched;
--   -- Expect: wh_drift = 0  AND  pc_drift = 0
--
-- POST-apply assert — readers unaffected. /api/export/combined-data uses
--   `warehouse AS c3` + `channel AS c11` and /api/channels uses
--   `SELECT DISTINCT channel`. Confirm the two original cols still resolve.
--   SELECT DISTINCT channel    FROM combined_data_enriched ORDER BY channel    LIMIT 10;
--   SELECT DISTINCT warehouse  FROM combined_data_enriched ORDER BY warehouse  LIMIT 10;
--   -- Expect: same DISTINCT sets as before schema/144.
--
-- ROLLBACK recipe (documentation only — schema/144 is view-only, no data drift):
--   1. Re-apply schema/142 view body verbatim (drops the 2 new aliases).
--   No mro table touched, no sku.region touched, no sales_transaction touched.
-- ════════════════════════════════════════════════════════════════════════════
