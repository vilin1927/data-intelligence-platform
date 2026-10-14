-- schema/176 — M18b: drop per-channel customer-code cols from combined_data_enriched view
--
-- DDL-ONLY: DROP VIEW + CREATE VIEW combined_data_enriched (no table data UPDATE/DELETE; removes per-channel customer-code columns from the view projection only)
-- DESTRUCTIVE: false  (view rebuild; underlying table data untouched)
-- (trust-contract v1 header retrofit 2026-05-17 — migration already applied + verified; tokens document shipped truth, prose context retained below)
--
--   "Combined data → The table includes all various customer codes -
--    this doesn't need to be in the table. It's stored in the customer table"
--
--              sheet "Combined data fields" — the owner's explicit col spec lists
--              ALMCustomerCode / DIRCustomerCode / ILGCustomerCode / YNRCustomerCode /
--              YNRALMCustomerCode as customer-table-only, NOT combined-data.
--             per-customer codes live on customer table (one row per customer).
--
-- Of the 5 cols the owner listed, only 3 appear in combined_data_enriched today:
-- alm_customer_code, dir_customer_code, ilg_customer_code. ynr_customer_code +
-- ynr_alm_customer_code never were in the view — they live on canonical_customer only.
--
-- View has zero dependent views/matviews (pg_depend check 2026-05-14 = 0 rows).
-- DROP + CREATE used (not CREATE OR REPLACE) because Postgres REPLACE forbids
-- removing cols; only addition at the end is allowed.
--
-- Forward-only. Old view def captured in schema/147 + git history.

BEGIN;

DROP VIEW IF EXISTS combined_data_enriched;

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
            WHEN COALESCE(c.customer_name, ''::character varying)::text = ''::text THEN ''::character varying
            WHEN c.customer_name::text ~~ '% @ %'::text THEN c.customer_name
            WHEN COALESCE(NULLIF(c.suburb::text, ''::text), cc.suburb::text, ''::text) <> ''::text THEN ((c.customer_name::text || ' @ '::text) || COALESCE(NULLIF(c.suburb::text, ''::text), cc.suburb::text))::character varying
            ELSE c.customer_name
        END AS customer_name,
    COALESCE(NULLIF(ac.raw_data ->> 'CustomerCode'::text, ''::text), cc.customer_code::text, ''::text) AS customer_code,
    COALESCE(cc.suburb, NULLIF(ac.raw_data ->> 'Suburb'::text, ''::text)::character varying, ''::character varying) AS suburb,
    COALESCE(cc.postcode, NULLIF(ac.raw_data ->> 'Postcode'::text, ''::text)::character varying, ''::character varying) AS postcode,
    COALESCE(cc.customer_group, NULLIF(ac.raw_data ->> 'Group'::text, ''::text)::character varying, ''::character varying) AS customer_group,
    COALESCE(NULLIF(cc.territory_name::text, ''::text), t_st.territory_name::text, t_cust.territory_name::text, NULLIF(ac.raw_data ->> 'Territory'::text, ''::text), ''::text) AS territory,
    COALESCE(cc.territory_group, NULLIF(ac.raw_data ->> 'TerritoryGroup'::text, ''::text)::character varying, ''::character varying) AS territory_group,
    COALESCE(NULLIF(cc.rep_name::text, ''::text), ''::text) AS rep_name,
    COALESCE(NULLIF(cc.rep_name::text, ''::text), ''::text) AS rep,
    COALESCE(cs.sku_name, s.item_description, ''::character varying) AS sku,
        CASE
            WHEN ch_st.channel_name::text = 'ALM'::text AND COALESCE(sva.attributed_vintage, s.vintage) IS NOT NULL THEN ((TRIM(BOTH FROM COALESCE(cs.sku_name, s.item_description, ''::character varying)) || ' '::text) || COALESCE(sva.attributed_vintage, s.vintage)::text)::character varying
            WHEN COALESCE(s.vintage, sva.attributed_vintage) IS NOT NULL THEN ((TRIM(BOTH FROM COALESCE(cs.sku_name, s.item_description, ''::character varying)) || ' '::text) || COALESCE(s.vintage, sva.attributed_vintage)::text)::character varying
            ELSE COALESCE(cs.sku_name, s.item_description, ''::character varying)
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
    COALESCE(NULLIF(ac.raw_data ->> 'SubRegion'::text, ''::text), s.region::text, ''::text) AS sub_region,
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

INSERT INTO schema_migrations (version, applied_at, source)
VALUES ('176', NOW(), 'live-apply')
ON CONFLICT (version) DO NOTHING;

COMMIT;
