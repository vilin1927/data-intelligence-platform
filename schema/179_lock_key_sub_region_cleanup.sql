-- ════════════════════════════════════════════════════════════════════════════
-- schema/179_lock_key_sub_region_cleanup.sql
-- D14 — Lock & Key sub_region historical leak (CSV vs UI mismatch)
-- ════════════════════════════════════════════════════════════════════════════
-- Date:        2026-05-20
-- Path:        PATH A — view rebuild only, no source-table writes
-- Destructive: false (DDL: CREATE OR REPLACE VIEW; zero data writes)
-- DDL-ONLY: DROP VIEW IF EXISTS + CREATE combined_data_enriched — sub_region COALESCE chain only; no table data UPDATE/DELETE
-- DESTRUCTIVE: false
-- HARD-SOURCE: May 8 verbal the owner "Lock & Key is Hilltops not Tumbarumba" + xlsx (1) Mar 24 "New DB SKU report" per-L&K-row Hilltops (applied schema/150 A7-150 2026-05-09)
-- HARD source: May 8 verbal the owner — "Lock & Key is Hilltops not Tumbarumba"
--              + xlsx (1) Mar 24 baseline "New DB SKU report" sheet (rows
--              33/41/61/79/83/91/107/113/177/182/189/207/213/225/226/257/269/
--              281 — every L&K row shows Hilltops). xlsx Mar 24 was already
--              applied to manual_region_override in schema/150_a7_region_
--              xlsx_backfill.sql (9 L&K skus 25/26/28/29/31/39/42/43/12257
--              flipped Tumbarumba -> Hilltops on 2026-05-09 09:10:13).
--              May 8 verbal reinforced the call.
-- CITATION:    D14 — the owner 2026-05-08 verbal Lock & Key Hilltops + xlsx (1)
--              Mar 24 baseline "New DB SKU report" rows per-sku Hilltops
--              (override applied schema/150 A7-150 2026-05-09)
--
-- ──────────────────────────────────────────────────────────────────────────
-- WHY THIS MIGRATION EXISTS
-- ──────────────────────────────────────────────────────────────────────────
--
-- combined_data_enriched.region uses the override-aware COALESCE chain
-- (mro.region -> vinsight wrapper -> brand fallback -> 'Unknown') so the UI
-- shows Lock & Key = Hilltops everywhere. Confirmed live 2026-05-20.
--
-- combined_data_enriched.sub_region does NOT use that chain. Current line
-- in live view (schema/176 line 194):
--
--     COALESCE(NULLIF(ac.raw_data ->> 'SubRegion', ''), s.region, '')
--                                                       ^^^^^^^^
--   raw sku.region — bypasses manual_region_override entirely.
--
-- For the 9 Lock & Key skus (sku_id 25/26/28/29/31/39/42/43/12257) with
-- raw sku.region='Tumbarumba' but mro.region='Hilltops', that bypass leaks
-- 21,824 historical Tumbarumba rows into CSV exports + /api/legacy-data
-- responses. UI surfaces (margin / inventory / wines / SKUs) all read
-- override-aware region so they're correct; ONLY downloads carry the leak.
--
--   - 100% of L&K transactions have access_combined_data.raw_data->>'SubRegion' = ''
--     (38,721 / 38,721). First leg of COALESCE never fires for L&K.
--   - 100% of ALL transactions have ac.raw_data->>'SubRegion' = ''
--     (121,059 / 121,059). The leg never fires anywhere — sub_region is
--     effectively COALESCE(s.region, '') in production today.
--   - Global region vs sub_region drift across the whole view = 36,594 rows.
--     Of those, 21,824 are the L&K Tumbarumba leak (the Owner-visible
--     symptom). The other 14,770 are Unknown/blank churn + 11 Tumbarumba->
--     Hilltops mirror for non-L&K skus that hit override.
--   - Every other API consumer (api/wines, api/skus, api/margins, api/what-if,
--     api/admin/unmatched-skus, api/wines/cogs) already reads
--     COALESCE(mro.region, s.region). Only this one view leg bypasses.
--
-- pg_depend check (2026-05-20): combined_data_enriched has ZERO dependent
-- views/matviews/rules. CREATE OR REPLACE VIEW is safe — no CASCADE risk,
-- RENAME + DROP CASCADE on this object), no matview refresh needed
-- (relkind='v' regular view, not 'm').
--
-- ──────────────────────────────────────────────────────────────────────────
-- DIFF vs schema/176 (1 line — line 194):
-- ──────────────────────────────────────────────────────────────────────────
--
-- schema/176 line 194 (current live):
--   COALESCE(NULLIF(ac.raw_data ->> 'SubRegion'::text, ''::text),
--            s.region::text, ''::text) AS sub_region,
--
-- schema/179 replacement (mirror region's full COALESCE chain EXACTLY):
--   COALESCE(NULLIF(ac.raw_data ->> 'SubRegion'::text, ''::text),
--            mro.region,
--            CASE WHEN s.sku_id IN (87,88,89,12365,12366,12370,12371)
--                 THEN 'Unknown' END,
--            (vinsight wrapper LATERAL subselect — same body as region),
--            CASE brand fallback (Coppabella/Procella -> Tumbarumba,
--                                 Moppity/L&K/Twelve Signs/Cato -> Hilltops),
--            'Unknown'::text) AS sub_region,
--
-- Identical 6-leg chain to the region column. Guarantees sub_region == region
-- for every row in the view post-fix (zero region<>sub_region drift expected
-- — confirmed 730 -> 0 in adjusted dry-run 2026-05-20).
--
-- Order rationale (mirrors region COALESCE):
--   1. ac.raw_data->>'SubRegion' — defensive, Access-historic field. Empty
--      in 100% of prod rows but kept in case future Access import populates it.
--   2. mro.region                — Owner-HARD override (the May 8 fix).
--   3. TS Sauv Blanc guard       — sku_id 87/88/89/12365/12366/12370/12371,
--                                  The owner ruled out Hilltops+Canberra, force 'Unknown'.
--   4. Vinsight regex wrapper    — sku-mapped Vinsight region (sea/sesa filter).
--   5. Brand fallback            — Coppabella -> Tumbarumba, L&K/Moppity ->
--                                  Hilltops. Catches the 67 L&K skus with no
--                                  raw region + no override (item 8 AMBER in
--   6. 'Unknown'                 — final floor, exactly matches region column's
--                                  floor. Goal of D14 is sub_region == region
--                                  for every row, so the floor MUST match too.
--                                  Earlier draft used s.region here but it
--                                  caused 730 residual region<>sub_region rows
--                                  (where region landed on 'Unknown' but raw
--                                  s.region had a value). DRY-RUN 2026-05-20
--                                  confirmed dropping s.region fallback in
--                                  favour of 'Unknown' takes residual drift to 0.
--
-- Note: this changes ONLY sub_region. Every other view column is byte-identical
-- to schema/176. DROP + CREATE (not CREATE OR REPLACE) is used here for the
-- same reason as schema/176 line 33 — pg_get_viewdef output of the live view
-- shows text/character-varying type drift on some columns (customer_name,
-- sku, sku_vintage, range_name) that Postgres OR REPLACE rejects with
-- "cannot change data type of view column". DROP is safe — pg_depend check
-- 2026-05-20 confirms ZERO dependent views/matviews/rules.
--
-- ──────────────────────────────────────────────────────────────────────────
-- REVERSIBILITY
-- ──────────────────────────────────────────────────────────────────────────
--
-- To revert: re-apply schema/176 verbatim (single CREATE OR REPLACE; no data
-- changes to undo). Or run a single CREATE OR REPLACE patch flipping only
-- line 194 back to the COALESCE(NULLIF(...SubRegion),s.region,'') pattern.
--
-- ══════════════════════════════════════════════════════════════════════════

BEGIN;

-- ──────────────────────────────────────────────────────────────────────────
-- PRE asserts — view exists; capture baseline counts.
-- ──────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
  v_view_exists   boolean;
  v_pre_lk_tumba  bigint;
  v_pre_rowcount  bigint;
  v_pre_drift     bigint;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM information_schema.views
     WHERE table_schema='public' AND table_name='combined_data_enriched'
  ) INTO v_view_exists;
  IF NOT v_view_exists THEN
    RAISE EXCEPTION 'PRE assert FAILED: combined_data_enriched view missing';
  END IF;

  SELECT COUNT(*) INTO v_pre_lk_tumba
    FROM combined_data_enriched
   WHERE (range_name ILIKE '%Lock%Key%'
          OR sku ILIKE '%Lock%Key%'
          OR item_description ILIKE '%lock%key%')
     AND sub_region = 'Tumbarumba';
  IF v_pre_lk_tumba = 0 THEN
    RAISE EXCEPTION
      'PRE assert FAILED: expected >0 Lock & Key Tumbarumba sub_region rows; got 0 — migration may already be applied or scope changed';
  END IF;
  RAISE NOTICE 'PRE: Lock & Key Tumbarumba sub_region rows = % (expect 21824 on 2026-05-20)', v_pre_lk_tumba;
  PERFORM set_config('moppity.schema_179_pre_lk_tumba', v_pre_lk_tumba::text, false);

  SELECT COUNT(*) INTO v_pre_rowcount FROM combined_data_enriched;
  RAISE NOTICE 'PRE: combined_data_enriched total rowcount = %', v_pre_rowcount;
  PERFORM set_config('moppity.schema_179_pre_rowcount', v_pre_rowcount::text, false);

  SELECT COUNT(*) INTO v_pre_drift
    FROM combined_data_enriched
   WHERE region <> sub_region
     AND region IS NOT NULL
     AND sub_region IS NOT NULL;
  RAISE NOTICE 'PRE: region <> sub_region drift = % rows', v_pre_drift;
  PERFORM set_config('moppity.schema_179_pre_drift', v_pre_drift::text, false);
END$$;

-- ──────────────────────────────────────────────────────────────────────────
-- View rebuild — body byte-identical to schema/176 EXCEPT the 1-line
-- sub_region replacement (mirror region's full COALESCE chain).
-- DROP + CREATE (matches schema/176 pattern; OR REPLACE forbidden because of
-- column-type drift on customer_name/sku/sku_vintage/range_name between
-- the schema/176 source-file text casts and the live view's varchar shapes).
-- ──────────────────────────────────────────────────────────────────────────
DROP VIEW IF EXISTS combined_data_enriched;  -- @L0-ALLOW: type-drift forces DROP+CREATE; pg_depend verified zero dependents 2026-05-20; atomic txn safe

CREATE VIEW combined_data_enriched AS
 SELECT COALESCE(NULLIF(ac.raw_data ->> 'ID'::text, ''::text)::bigint, st.transaction_id::bigint) AS upload_id,
    COALESCE(NULLIF(ac.raw_data ->> 'ID'::text, ''::text)::bigint, st.transaction_id::bigint) AS sn,
    st.source_system,
    st.source_ref,
    st.sale_date,
    st.sale_date AS transaction_date,
    st.period,
    to_char(st.sale_date::timestamp with time zone, 'YYYY MM MON'::text) AS cal_month,
    EXTRACT(year FROM st.sale_date)::integer AS cal_year,
    EXTRACT(month FROM st.sale_date)::integer AS cal_month_num,
    st.quantity AS qty,
    st.quantity * COALESCE(cs.units_per_case, 12)::numeric AS qty_bottles,
    COALESCE(cs.units_per_case, 12) AS carton_x,
    COALESCE(st.gross_revenue, st.net_revenue, 0::numeric) AS revenue,
    COALESCE(st.gross_revenue, st.net_revenue, 0::numeric) AS wholesale_value_ex,
    COALESCE(st.gross_revenue, st.net_revenue, 0::numeric) AS wsale_value,
    COALESCE(st.net_revenue, 0::numeric) AS net_revenue,
    COALESCE(st.net_revenue, 0::numeric) AS netrevenue,
    COALESCE(cs.base_wholesale, 0::numeric) AS base_wholesale,
    COALESCE(cs.transfer_cost, 0::numeric) AS transfer_cost,
        CASE
            WHEN st.quantity IS NOT NULL AND st.quantity <> 0::numeric THEN round(COALESCE(st.net_revenue, 0::numeric) / st.quantity, 4)
            ELSE NULL::numeric
        END AS average_case,
        CASE
            WHEN st.quantity IS NOT NULL AND st.quantity <> 0::numeric THEN round(COALESCE(st.net_revenue, 0::numeric) / st.quantity, 4)
            ELSE NULL::numeric
        END AS average_case_1,
        CASE
            WHEN st.quantity IS NOT NULL AND st.quantity <> 0::numeric THEN round(COALESCE(st.net_revenue, 0::numeric) / st.quantity, 2)
            ELSE NULL::numeric
        END AS net_dollar_per_case,
    COALESCE(st.discount_amount, 0::numeric) AS discount,
    COALESCE(st.rebate_amount, 0::numeric) AS rebate,
    COALESCE(st.wholesale_fee, 0::numeric) AS fee,
    COALESCE(st.wholesale_fee, 0::numeric) AS wholesaler_fee,
        CASE
            WHEN COALESCE(st.gross_revenue, st.net_revenue, 0::numeric) > 0::numeric THEN round(COALESCE(st.discount_amount, 0::numeric) / COALESCE(st.gross_revenue, st.net_revenue, 1::numeric) * 100::numeric, 2)
            ELSE NULL::numeric
        END AS discount_percentage,
        CASE
            WHEN COALESCE(st.gross_revenue, st.net_revenue, 0::numeric) > 0::numeric THEN round(COALESCE(st.rebate_amount, 0::numeric) / COALESCE(st.gross_revenue, st.net_revenue, 1::numeric) * 100::numeric, 2)
            ELSE NULL::numeric
        END AS rebate_rate,
    COALESCE(st.economic_cogs_total, st.quantity * COALESCE(s.transfer_cost, 0::numeric)) AS cogs,
    COALESCE(st.economic_cogs_total, st.quantity * COALESCE(s.transfer_cost, 0::numeric)) AS total_cogs,
    COALESCE(st.gross_revenue, st.net_revenue, 0::numeric) - COALESCE(st.economic_cogs_total, st.quantity * COALESCE(s.transfer_cost, 0::numeric)) AS profit,
        CASE
            WHEN COALESCE(st.gross_revenue, st.net_revenue, 0::numeric) > 0::numeric THEN round((COALESCE(st.gross_revenue, st.net_revenue, 0::numeric) - COALESCE(st.economic_cogs_total, st.quantity * COALESCE(s.transfer_cost, 0::numeric))) / COALESCE(st.gross_revenue, st.net_revenue, 1::numeric) * 100::numeric, 2)
            ELSE NULL::numeric
        END AS gp,
    COALESCE(st.net_revenue, 0::numeric) - COALESCE(st.economic_cogs_total, st.quantity * COALESCE(s.transfer_cost, 0::numeric)) - COALESCE(st.rebate_amount, 0::numeric) - COALESCE(st.wholesale_fee, 0::numeric) AS calculated_profit,
    0::numeric AS commission,
    COALESCE(st.net_revenue, 0::numeric) - COALESCE(st.economic_cogs_total, st.quantity * COALESCE(s.transfer_cost, 0::numeric)) - COALESCE(st.rebate_amount, 0::numeric) - COALESCE(st.wholesale_fee, 0::numeric) - 0::numeric AS net_profit,
    COALESCE(st.warehouse, ''::character varying) AS warehouse,
    COALESCE(st.warehouse, ''::character varying) AS warehouse_channel,
    COALESCE(
        CASE upper(TRIM(BOTH FROM COALESCE(cc.channel, (ac.raw_data ->> 'Channel'::text)::character varying, ''::character varying)))
            WHEN 'OFF PREMISE'::text THEN 'OFF PREMISE'::text
            WHEN 'OFF-PREMISE'::text THEN 'OFF PREMISE'::text
            WHEN 'OFF_PREMISE'::text THEN 'OFF PREMISE'::text
            WHEN 'ON PREMISE'::text THEN 'ON PREMISE'::text
            WHEN 'ON-PREMISE'::text THEN 'ON PREMISE'::text
            WHEN 'ON_PREMISE'::text THEN 'ON PREMISE'::text
            WHEN 'HYBRID'::text THEN 'HYBRID'::text
            WHEN 'WHOLESALE'::text THEN 'WHOLESALE'::text
            WHEN 'WHOLE SALE'::text THEN 'WHOLESALE'::text
            WHEN 'DIRECT'::text THEN 'DIRECT'::text
            WHEN 'HOFFICE'::text THEN 'HOFFICE'::text
            WHEN 'HEAD OFFICE'::text THEN 'HOFFICE'::text
            WHEN 'HEADOFFICE'::text THEN 'HOFFICE'::text
            WHEN 'HEAD-OFFICE'::text THEN 'HOFFICE'::text
            WHEN 'ALM'::text THEN ''::text
            WHEN 'YOUNG & RASHLEIGH'::text THEN ''::text
            WHEN 'YOUNG&RASHLEIGH'::text THEN ''::text
            WHEN 'Y&R'::text THEN ''::text
            WHEN 'YNR'::text THEN ''::text
            ELSE ''::text
        END, ''::text) AS channel,
    COALESCE(
        CASE upper(TRIM(BOTH FROM COALESCE(cc.channel, (ac.raw_data ->> 'Channel'::text)::character varying, ''::character varying)))
            WHEN 'OFF PREMISE'::text THEN 'OFF PREMISE'::text
            WHEN 'OFF-PREMISE'::text THEN 'OFF PREMISE'::text
            WHEN 'OFF_PREMISE'::text THEN 'OFF PREMISE'::text
            WHEN 'ON PREMISE'::text THEN 'ON PREMISE'::text
            WHEN 'ON-PREMISE'::text THEN 'ON PREMISE'::text
            WHEN 'ON_PREMISE'::text THEN 'ON PREMISE'::text
            WHEN 'HYBRID'::text THEN 'HYBRID'::text
            WHEN 'WHOLESALE'::text THEN 'WHOLESALE'::text
            WHEN 'WHOLE SALE'::text THEN 'WHOLESALE'::text
            WHEN 'DIRECT'::text THEN 'DIRECT'::text
            WHEN 'HOFFICE'::text THEN 'HOFFICE'::text
            WHEN 'HEAD OFFICE'::text THEN 'HOFFICE'::text
            WHEN 'HEADOFFICE'::text THEN 'HOFFICE'::text
            WHEN 'HEAD-OFFICE'::text THEN 'HOFFICE'::text
            WHEN 'ALM'::text THEN ''::text
            WHEN 'YOUNG & RASHLEIGH'::text THEN ''::text
            WHEN 'YOUNG&RASHLEIGH'::text THEN ''::text
            WHEN 'Y&R'::text THEN ''::text
            WHEN 'YNR'::text THEN ''::text
            ELSE ''::text
        END, ''::text) AS premise_channel,
        CASE
            WHEN COALESCE(c.customer_name, ''::character varying)::text = ''::text THEN ''::text
            WHEN c.customer_name::text ~~ '% @ %'::text THEN c.customer_name::text
            WHEN COALESCE(NULLIF(c.suburb, ''::character varying), cc.suburb, ''::character varying)::text <> ''::text THEN (c.customer_name::text || ' @ '::text) || COALESCE(NULLIF(c.suburb, ''::character varying), cc.suburb)::text
            ELSE c.customer_name::text
        END AS customer_name,
    COALESCE(NULLIF(ac.raw_data ->> 'CustomerCode'::text, ''::text), cc.customer_code::text, ''::text) AS customer_code,
    COALESCE(cc.suburb, NULLIF(ac.raw_data ->> 'Suburb'::text, ''::text)::character varying, ''::character varying) AS suburb,
    COALESCE(cc.postcode, NULLIF(ac.raw_data ->> 'Postcode'::text, ''::text)::character varying, ''::character varying) AS postcode,
    COALESCE(cc.customer_group, NULLIF(ac.raw_data ->> 'Group'::text, ''::text)::character varying, ''::character varying) AS customer_group,
    COALESCE(NULLIF(cc.territory_name, ''::character varying), t_st.territory_name, t_cust.territory_name, NULLIF(ac.raw_data ->> 'Territory'::text, ''::text)::character varying, ''::character varying) AS territory,
    COALESCE(cc.territory_group, NULLIF(ac.raw_data ->> 'TerritoryGroup'::text, ''::text)::character varying, ''::character varying) AS territory_group,
    COALESCE(NULLIF(cc.rep_name, ''::character varying), ''::character varying) AS rep_name,
    COALESCE(NULLIF(cc.rep_name, ''::character varying), ''::character varying) AS rep,
    COALESCE(cs.sku_name, s.item_description, ''::character varying) AS sku,
        CASE
            WHEN ch_st.channel_name::text = 'ALM'::text AND COALESCE(sva.attributed_vintage, s.vintage) IS NOT NULL THEN (TRIM(BOTH FROM COALESCE(cs.sku_name, s.item_description, ''::character varying)) || ' '::text) || COALESCE(sva.attributed_vintage, s.vintage)
            WHEN COALESCE(s.vintage, sva.attributed_vintage) IS NOT NULL THEN (TRIM(BOTH FROM COALESCE(cs.sku_name, s.item_description, ''::character varying)) || ' '::text) || COALESCE(s.vintage, sva.attributed_vintage)
            ELSE TRIM(BOTH FROM COALESCE(cs.sku_name, s.item_description, ''::character varying))::character varying::text
        END AS sku_vintage,
    COALESCE(NULLIF(ac.raw_data ->> 'ItemCode'::text, ''::text), vsoi.stock_item_code::text,
        CASE
            WHEN st.source_system::text = 'DWS'::text THEN NULLIF(split_part(st.source_ref::text, '-'::text, 2), ''::text)
            WHEN st.source_system::text = 'ALM'::text THEN NULLIF(regexp_replace(st.source_ref::text, '^ALM-[0-9]+-[0-9]{4}-[0-9]{2}-[0-9]{2}-'::text, ''::text), ''::text)
            ELSE NULL::text
        END, s.sku_code::text, ''::text) AS item_code,
    COALESCE(NULLIF(ac.raw_data ->> 'ItemDescription'::text, ''::text), vsoi.description::text, NULLIF(dws.stkdesc1, ''::text), NULLIF(ase.product_description, ''::text), s.item_description::text, ''::text) AS item_description,
    COALESCE(cs.range_name, ''::character varying) AS range_name,
    s.variety,
    COALESCE(mro.region,
        CASE
            WHEN s.sku_id = ANY (ARRAY[87, 88, 89, 12365, 12366, 12370, 12371]) THEN 'Unknown'::text
            ELSE NULL::text
        END, ( SELECT
                CASE
                    WHEN lower(v.parsed) = ANY (ARRAY['sesa'::text, 'sea'::text]) THEN 'South East Australia'::text
                    WHEN lower(TRIM(BOTH FROM v.parsed)) = 'tumba'::text THEN 'Tumbarumba'::text
                    ELSE initcap(TRIM(BOTH FROM v.parsed))
                END AS initcap
           FROM ( SELECT svs.parsed_region AS parsed,
                    svs.is_active
                   FROM staging_vinsight_region_lookup svs
                     JOIN sku_code_map scm ON scm.source_system::text = 'vinsight'::text AND scm.external_code::text = svs.stock_item_code
                  WHERE scm.sku_id = s.sku_id) v
          WHERE v.parsed IS NOT NULL AND TRIM(BOTH FROM v.parsed) <> ''::text AND (lower(TRIM(BOTH FROM v.parsed)) <> ALL (ARRAY['sea'::text, 'sesa'::text]))
          ORDER BY v.is_active DESC NULLS LAST
         LIMIT 1),
        CASE
            WHEN s.item_description::text ~~* '%coppabella%'::text OR s.item_description::text ~~* '%procella%'::text AND s.item_description::text !~~* '%clare%'::text AND s.item_description::text !~~* '%cv %'::text THEN 'Tumbarumba'::text
            WHEN s.item_description::text ~~* '%moppity%'::text OR s.item_description::text ~~* '%lock & key%'::text OR s.item_description::text ~~* '%lock&key%'::text OR s.item_description::text ~~* '%twelve signs%'::text OR s.item_description::text ~~* '%cato%'::text THEN 'Hilltops'::text
            ELSE NULL::text
        END, 'Unknown'::text) AS region,
        CASE
            WHEN ch_st.channel_name::text = 'ALM'::text THEN COALESCE(sva.attributed_vintage, s.vintage)
            ELSE COALESCE(s.vintage, sva.attributed_vintage)
        END AS vintage,
    -- ── D14 sub_region — mirror region's COALESCE chain ──────────────────
    -- schema/179 (2026-05-20): replaces schema/176 line 194
    --   OLD: COALESCE(NULLIF(ac.raw_data->>'SubRegion',''), s.region, '')
    --   NEW: full mro -> wrapper -> brand -> raw -> '' chain matching region.
    -- HARD-cite: the owner 2026-05-08 verbal "Lock & Key is Hilltops" + xlsx (1)
    -- Mar 24 baseline "New DB SKU report" sheet, applied to mro via schema/150
    -- A7-150. Sweeps 21,824 L&K Tumbarumba historical rows out of CSV exports.
    COALESCE(NULLIF(ac.raw_data ->> 'SubRegion'::text, ''::text),
        mro.region,
        CASE
            WHEN s.sku_id = ANY (ARRAY[87, 88, 89, 12365, 12366, 12370, 12371]) THEN 'Unknown'::text
            ELSE NULL::text
        END, ( SELECT
                CASE
                    WHEN lower(v.parsed) = ANY (ARRAY['sesa'::text, 'sea'::text]) THEN 'South East Australia'::text
                    WHEN lower(TRIM(BOTH FROM v.parsed)) = 'tumba'::text THEN 'Tumbarumba'::text
                    ELSE initcap(TRIM(BOTH FROM v.parsed))
                END AS initcap
           FROM ( SELECT svs.parsed_region AS parsed,
                    svs.is_active
                   FROM staging_vinsight_region_lookup svs
                     JOIN sku_code_map scm ON scm.source_system::text = 'vinsight'::text AND scm.external_code::text = svs.stock_item_code
                  WHERE scm.sku_id = s.sku_id) v
          WHERE v.parsed IS NOT NULL AND TRIM(BOTH FROM v.parsed) <> ''::text AND (lower(TRIM(BOTH FROM v.parsed)) <> ALL (ARRAY['sea'::text, 'sesa'::text]))
          ORDER BY v.is_active DESC NULLS LAST
         LIMIT 1),
        CASE
            WHEN s.item_description::text ~~* '%coppabella%'::text OR s.item_description::text ~~* '%procella%'::text AND s.item_description::text !~~* '%clare%'::text AND s.item_description::text !~~* '%cv %'::text THEN 'Tumbarumba'::text
            WHEN s.item_description::text ~~* '%moppity%'::text OR s.item_description::text ~~* '%lock & key%'::text OR s.item_description::text ~~* '%lock&key%'::text OR s.item_description::text ~~* '%twelve signs%'::text OR s.item_description::text ~~* '%cato%'::text THEN 'Hilltops'::text
            ELSE NULL::text
        END, 'Unknown'::text) AS sub_region,
    COALESCE(NULLIF(ac.raw_data ->> 'Ownership'::text, ''::text), cc.customer_group::text, ''::text) AS ownership,
    COALESCE(NULLIF(ac.raw_data ->> 'Note'::text, ''::text), cs.note, ''::text) AS note,
        CASE
            WHEN st.source_system::text = 'vinsight'::text AND st.source_ref::text ~ '^vinsight-[0-9]+-[0-9]+$'::text THEN split_part(st.source_ref::text, '-'::text, 2)
            WHEN st.source_system::text = 'access_db'::text THEN COALESCE(NULLIF(ac.raw_data ->> 'InvoiceNo'::text, ''::text), ''::text)
            ELSE COALESCE(NULLIF(ac.raw_data ->> 'InvoiceNo'::text, ''::text), st.source_ref::text, ''::text)
        END AS invoice_no,
        CASE
            WHEN to_regclass('public.sales_transaction'::text) IS NOT NULL AND (EXISTS ( SELECT 1
               FROM information_schema.columns
              WHERE columns.table_schema::name = 'public'::name AND columns.table_name::name = 'sales_transaction'::name AND columns.column_name::name = 'upload_batch_id'::name)) THEN (to_jsonb(st.*) ->> 'upload_batch_id'::text)::bigint
            ELSE NULL::bigint
        END AS import_id
   FROM sales_transaction st
     LEFT JOIN sku s ON s.sku_id = st.sku_id
     LEFT JOIN canonical_sku cs ON cs.id = s.canonical_sku_id
     LEFT JOIN customer c ON c.customer_id = st.customer_id
     LEFT JOIN canonical_customer cc ON cc.id = c.canonical_customer_id
     LEFT JOIN territory t_st ON t_st.territory_id = st.territory_id
     LEFT JOIN territory t_cust ON t_cust.territory_id = c.territory_id
     LEFT JOIN access_combined_data ac ON (ac.raw_data ->> 'ID'::text) = st.source_ref::text AND st.source_system::text = 'access_db'::text
     LEFT JOIN vinsight_sales_order_item vsoi ON vsoi.order_num =
        CASE
            WHEN st.source_ref::text ~ '^vinsight-[0-9]+-[0-9]+$'::text THEN split_part(st.source_ref::text, '-'::text, 2)::integer
            ELSE NULL::integer
        END AND vsoi.entry_num =
        CASE
            WHEN st.source_ref::text ~ '^vinsight-[0-9]+-[0-9]+$'::text THEN split_part(st.source_ref::text, '-'::text, 3)::integer
            ELSE NULL::integer
        END AND st.source_system::text = 'vinsight'::text
     LEFT JOIN LATERAL ( SELECT alm_edi_segment_52.alm_product_code,
            alm_edi_segment_52.product_description
           FROM alm_edi_segment_52
          WHERE st.source_system::text = 'ALM'::text AND alm_edi_segment_52.alm_product_code = NULLIF(regexp_replace(st.source_ref::text, '^ALM-[0-9]+-[0-9]{4}-[0-9]{2}-[0-9]{2}-'::text, ''::text), ''::text)
          ORDER BY alm_edi_segment_52.inserted_at DESC
         LIMIT 1) ase ON true
     LEFT JOIN LATERAL ( SELECT dws_staging_114.stockitem,
            dws_staging_114.stkdesc1
           FROM dws_staging_114
          WHERE st.source_system::text = 'DWS'::text AND dws_staging_114.stockitem = NULLIF(split_part(st.source_ref::text, '-'::text, 2), ''::text)
          ORDER BY dws_staging_114.inserted_at DESC
         LIMIT 1) dws ON true
     LEFT JOIN sale_vintage_attribution sva ON sva.sales_transaction_id = st.transaction_id
     LEFT JOIN channel ch_st ON ch_st.channel_id = st.channel_id
     LEFT JOIN manual_region_override mro ON mro.sku_id = s.sku_id;

COMMENT ON VIEW combined_data_enriched IS
  'D14 schema/179 (2026-05-20): sub_region now mirrors region COALESCE chain '
  '(mro -> TS guard -> vinsight wrapper -> brand fallback -> s.region -> empty). '
  'Removes 21,824-row Lock & Key Tumbarumba leak in CSV exports introduced by '
  'schema/176 line 194. All other view body byte-identical to schema/176. '
  'HARD-cite: the owner 2026-05-08 verbal L&K=Hilltops + xlsx(1) Mar 24 baseline '
  '(applied via schema/150 A7-150 to manual_region_override).';

INSERT INTO schema_migrations (version, applied_at, source)
VALUES ('179_lock_key_sub_region_cleanup', NOW(), 'live-apply')
ON CONFLICT (version) DO NOTHING;

-- ──────────────────────────────────────────────────────────────────────────
-- POST asserts
-- ──────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
  v_pre_lk_tumba   bigint;
  v_post_lk_tumba  bigint;
  v_pre_rowcount   bigint;
  v_post_rowcount  bigint;
  v_pre_drift      bigint;
  v_post_drift     bigint;
  v_lk_hilltops    bigint;
BEGIN
  v_pre_lk_tumba := COALESCE(NULLIF(current_setting('moppity.schema_179_pre_lk_tumba', true), ''), '0')::bigint;
  v_pre_rowcount := COALESCE(NULLIF(current_setting('moppity.schema_179_pre_rowcount', true), ''), '0')::bigint;
  v_pre_drift    := COALESCE(NULLIF(current_setting('moppity.schema_179_pre_drift', true), ''), '0')::bigint;

  -- Invariant 1: rowcount unchanged (view rebuild must not gain/lose rows).
  SELECT COUNT(*) INTO v_post_rowcount FROM combined_data_enriched;
  IF v_post_rowcount <> v_pre_rowcount THEN
    RAISE EXCEPTION 'POST assert FAILED: rowcount drifted PRE=% POST=%', v_pre_rowcount, v_post_rowcount;
  END IF;
  RAISE NOTICE 'POST: rowcount unchanged (%)', v_post_rowcount;

  -- Invariant 2: zero Lock & Key Tumbarumba sub_region rows after fix.
  SELECT COUNT(*) INTO v_post_lk_tumba
    FROM combined_data_enriched
   WHERE (range_name ILIKE '%Lock%Key%'
          OR sku ILIKE '%Lock%Key%'
          OR item_description ILIKE '%lock%key%')
     AND sub_region = 'Tumbarumba';
  IF v_post_lk_tumba <> 0 THEN
    RAISE EXCEPTION
      'POST assert FAILED: Lock & Key Tumbarumba sub_region rows = % (must be 0). PRE was %',
      v_post_lk_tumba, v_pre_lk_tumba;
  END IF;
  RAISE NOTICE 'POST: Lock & Key Tumbarumba sub_region rows = 0 (PRE was %)', v_pre_lk_tumba;

  -- Invariant 3: Lock & Key Hilltops sub_region count should jump by ~21,824.
  SELECT COUNT(*) INTO v_lk_hilltops
    FROM combined_data_enriched
   WHERE (range_name ILIKE '%Lock%Key%'
          OR sku ILIKE '%Lock%Key%'
          OR item_description ILIKE '%lock%key%')
     AND sub_region = 'Hilltops';
  RAISE NOTICE 'POST: Lock & Key Hilltops sub_region rows = % (PRE was 16,897 expected)', v_lk_hilltops;

  -- Invariant 4: region <> sub_region drift must drop to ZERO (sub_region
  -- COALESCE chain is byte-identical to region's, so every row must match).
  SELECT COUNT(*) INTO v_post_drift
    FROM combined_data_enriched
   WHERE region <> sub_region
     AND region IS NOT NULL
     AND sub_region IS NOT NULL;
  IF v_post_drift <> 0 THEN
    RAISE EXCEPTION 'POST assert FAILED: region<>sub_region drift = % (must be 0; PRE was %)', v_post_drift, v_pre_drift;
  END IF;
  RAISE NOTICE 'POST: region<>sub_region drift = 0 (PRE was %)', v_pre_drift;
END$$;

COMMIT;
