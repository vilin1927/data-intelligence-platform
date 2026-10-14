-- =============================================================================
-- 028_combined_data_enriched_add_rep_name.sql — JF-24: expose rep_name in the
-- combined_data_enriched view so /api/legacy-data can filter by sales rep.
-- =============================================================================
-- Context: JF-24 AC[2] requires a rep dropdown filter on the Combined Data
-- (/legacy-data) page. The view already joins canonical_customer (as cc) but
-- doesn't project cc.rep_name. Adding it here so the API route can filter and
-- the frontend can populate a dropdown.
--
-- This is CREATE OR REPLACE — safe, forward-only, no data change.
-- The only difference from schema/027 is the addition of the rep_name column.
--
-- Run as: psql -U moppity -d moppity_db -f schema/028_combined_data_enriched_add_rep_name.sql
-- =============================================================================

CREATE OR REPLACE VIEW combined_data_enriched AS
SELECT
  st.transaction_id                                             AS upload_id,
  st.source_system,
  st.source_ref,
  st.sale_date,
  st.period,
  TO_CHAR(st.sale_date, 'YYYY MM MON')                          AS cal_month,
  st.quantity                                                   AS qty,
  COALESCE(st.gross_revenue, st.net_revenue, 0)::numeric        AS revenue,
  COALESCE(st.net_revenue, 0)::numeric                          AS net_revenue,
  COALESCE(st.discount_amount, 0)::numeric                      AS discount,
  COALESCE(st.rebate_amount, 0)::numeric                        AS rebate,
  COALESCE(st.wholesale_fee, 0)::numeric                        AS fee,
  COALESCE(
    st.economic_cogs_total,
    (st.quantity * COALESCE(s.transfer_cost, 0))::numeric
  )::numeric                                                    AS cogs,
  -- Warehouse = distribution channel (DWS/ALM/Direct/ILG). Stored on the row.
  COALESCE(st.warehouse, '')                                    AS warehouse,
  -- Channel = customer attribute (ON PREMISE / OFF PREMISE / WHOLESALE / DIRECT / HYBRID).
  -- Prefer canonical_customer.channel, fallback to access_combined_data JSONB for
  -- access_db rows, else blank.
  COALESCE(
    cc.channel,
    NULLIF(ac.raw_data->>'Channel', ''),
    ''
  )                                                             AS channel,
  -- Territory: canonical -> sales_transaction.territory_id -> customer.territory_id.
  COALESCE(
    NULLIF(cc.territory_name, ''),
    t_st.territory_name,
    t_cust.territory_name,
    NULLIF(ac.raw_data->>'Territory', ''),
    ''
  )                                                             AS territory,
  COALESCE(c.customer_name, '')                                 AS customer_name,
  -- SKU = canonical NV name (e.g. "LOCK & KEY SHIRAZ"). Falls back to sku.item_description.
  COALESCE(cs.sku_name, s.item_description, '')                 AS sku,
  -- SKU-vintage = canonical name + vintage year (e.g. "LOCK & KEY SHIRAZ 2021").
  CASE
    WHEN s.vintage IS NOT NULL
      THEN TRIM(COALESCE(cs.sku_name, s.item_description, '')) || ' ' || s.vintage
    ELSE COALESCE(cs.sku_name, s.item_description, '')
  END                                                           AS sku_vintage,
  -- item_code = source-system code (NOT canonical). For access_db rows, the raw
  -- Access ItemCode (DWS MOATRI25F / ALM 513820). For Vinsight Direct rows, the
  -- Vinsight stock_item_code (MVATRIEB25). Fallback to sku.sku_code (canonical).
  COALESCE(
    NULLIF(ac.raw_data->>'ItemCode', ''),
    vsoi.stock_item_code,
    s.sku_code,
    ''
  )                                                             AS item_code,
  -- item_description = source description verbatim.
  COALESCE(
    NULLIF(ac.raw_data->>'ItemDescription', ''),
    vsoi.description,
    s.item_description,
    ''
  )                                                             AS item_description,
  -- Invoice number (JF-15 2026-04-11):
  --   Vinsight -> Vinsight OrderNumber (5-digit) which is already the middle
  --              segment of source_ref, e.g. 'vinsight-21105-43651' -> '21105'.
  --   DWS/ALM   -> access_db raw InvoiceNo if present, else source_ref as-is.
  CASE
    WHEN st.source_system = 'vinsight' AND st.source_ref ~ '^vinsight-[0-9]+-[0-9]+$'
      THEN split_part(st.source_ref, '-', 2)
    ELSE COALESCE(
      NULLIF(ac.raw_data->>'InvoiceNo', ''),
      st.source_ref,
      ''
    )
  END                                                           AS invoice_no,
  s.variety                                                     AS variety,
  s.region                                                      AS region,
  s.vintage                                                     AS vintage,
  wr.range_name                                                 AS range_name,
  -- JF-24: Rep name from canonical_customer (populated post-JF-22).
  -- Appended at end so CREATE OR REPLACE can add it without column reorder.
  COALESCE(NULLIF(cc.rep_name, ''), '')                         AS rep_name
FROM sales_transaction st
LEFT JOIN sku s                   ON s.sku_id       = st.sku_id
LEFT JOIN canonical_sku cs        ON cs.id          = s.canonical_sku_id
LEFT JOIN wine_range wr           ON wr.range_id    = s.range_id
LEFT JOIN customer c              ON c.customer_id  = st.customer_id
LEFT JOIN canonical_customer cc   ON cc.id          = c.canonical_customer_id
LEFT JOIN territory t_st          ON t_st.territory_id   = st.territory_id
LEFT JOIN territory t_cust        ON t_cust.territory_id = c.territory_id
-- For access_db rows: join the raw JSONB staging table 1:1 by transaction_id = id.
LEFT JOIN access_combined_data ac
       ON ac.id = st.transaction_id
      AND st.source_system = 'access_db'
-- For Vinsight Direct rows: source_ref = 'vinsight-<order_num>-<entry_num>'.
-- Safe parsing via CASE so non-numeric source_refs never hit ::int.
LEFT JOIN vinsight_sales_order_item vsoi
       ON vsoi.order_num = (CASE WHEN st.source_ref ~ '^vinsight-[0-9]+-[0-9]+$'
                                 THEN split_part(st.source_ref, '-', 2)::int END)
      AND vsoi.entry_num = (CASE WHEN st.source_ref ~ '^vinsight-[0-9]+-[0-9]+$'
                                 THEN split_part(st.source_ref, '-', 3)::int END)
      AND st.source_system = 'vinsight';

COMMENT ON VIEW combined_data_enriched IS
  'BUG-20 + JF-24: unified display+filter projection over sales_transaction for '
  '/api/legacy-data. Extended from schema/027 to include rep_name (from '
  'canonical_customer) for the Combined Data rep dropdown filter.';
