-- =============================================================================
-- 027_combined_data_enriched_view.sql — BUG-20 (DASH-01): extract /legacy-data CTE
-- =============================================================================
-- Context: 2026-04-11 CTO audit CRITICAL #7. /api/legacy-data (the route that
-- powers the owner's Combined Data browser and CSV export) defined a 10-way CTE
-- inline and pasted it into SIX parallel queries per request. At pool max=5,
-- every click saturated the pool; each query also re-parsed / re-planned the
-- same join tree.
--
-- Fix: extract the CTE body verbatim into a regular VIEW. All six queries in
-- dashboard/src/app/api/legacy-data/route.ts now SELECT FROM combined_data_enriched
-- with the same WHERE clauses as before. Query semantics are unchanged — this
-- is a pure structural refactor on the SQL side.
--
-- VIEW vs MATERIALIZED VIEW: regular VIEW.
--   * sales_transaction is written to on every ETL run, every upload, and
--     every manual correction. A materialized view would need refresh
--     The owner the moment a new upload lands.
--   * The /legacy-data page is the owner's live drill-down surface — correctness
--     beats the marginal extra speed of a snapshot.
--   * The win from this migration is (a) not re-parsing/re-planning the same
--     10-way join six times per request, and (b) giving the planner one
--     stable relation to reason about. A regular VIEW delivers both.
--   * If /legacy-data p95 still doesn't meet the audit target after this,
--     the next step is indexes on joined columns (already covered by
--     schema/025_sales_transaction_fk_indexes.sql), NOT materialization.
--
-- Safe, forward-only, idempotent (CREATE OR REPLACE). No data rewrite.
--
-- Run as: psql -U moppity -d moppity_db -f schema/027_combined_data_enriched_view.sql
--
-- Related: BUG-20 route.ts refactor (same commit). Depends on tables:
--   sales_transaction, sku, canonical_sku, wine_range, customer,
--   canonical_customer, territory, access_combined_data, vinsight_sales_order_item.
-- All of these exist on main as of 2026-04-11.
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
  -- Territory: canonical → sales_transaction.territory_id → customer.territory_id.
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
  --   Vinsight → Vinsight OrderNumber (5-digit) which is already the middle
  --              segment of source_ref, e.g. 'vinsight-21105-43651' → '21105'.
  --              The owner confirmed 2026-04-11 this is THE invoice number he wants
  --              to see. (staging_vinsight_sales_orders.raw_data->>'InvoiceNumber'
  --              is empty in prod so the old LATERAL lookup was useless and we
  --              were falling through to the raw source_ref like 'vinsight-...'.)
  --   DWS/ALM   → access_db raw InvoiceNo if present, else source_ref as-is
  --              (which is already a clean invoice-like string per the owner's
  --              ALM/DWS parser contract, e.g. '364942').
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
  wr.range_name                                                 AS range_name
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
  'BUG-20: unified display+filter projection over sales_transaction for '
  '/api/legacy-data. Extracted from the 10-way CTE that used to be inlined '
  'six times per request. Regular VIEW (not materialized) because '
  'sales_transaction is written on every ETL run and the owner needs live '
  'correctness on /legacy-data. See schema/027 header for rationale.';

-- =============================================================================
-- Verification (run manually after apply):
-- =============================================================================
-- \d+ combined_data_enriched
--   expect: view with 25 columns (upload_id, source_system, source_ref, ...,
--           range_name)
--
-- SELECT count(*) FROM combined_data_enriched;
--   expect: matches (SELECT count(*) FROM sales_transaction) — ~119K today.
--
-- EXPLAIN (ANALYZE, BUFFERS)
-- SELECT count(*), sum(revenue)
-- FROM combined_data_enriched
-- WHERE period >= '2025-02' AND period <= '2026-02';
--   expect: single plan, no nested CTE Scan — view is inlined by the planner.
-- =============================================================================
