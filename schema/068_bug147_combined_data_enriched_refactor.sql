-- =============================================================================
-- 068_bug147_combined_data_enriched_refactor.sql — prereq for schema/062
-- =============================================================================
-- Ticket : BUG-147 (Phase T reader refactor, dependent VIEW swept here)
-- Phase  : T (Access-first migration plan 2026-04-22, final range SoT step)
-- Run as : psql -U moppity -d moppity_db -f schema/068_bug147_combined_data_enriched_refactor.sql
--
-- Purpose:
--   Schema/027 defined combined_data_enriched (powers /legacy-data) with
--   LEFT JOIN wine_range wr ON wr.range_id = s.range_id. Schema/051 renamed
--   wine_range → wine_range_deprecated + created a VIEW of the same name over
--   canonical_sku; Postgres auto-rewrote the dependent VIEW to reference the
--   renamed table. Schema/062 drops both wine_range_deprecated and sku.range_id
--   and fails because combined_data_enriched still depends on them.
--
--   Fix (this migration): CREATE OR REPLACE the VIEW with identical column
--   signature but source range_name from canonical_sku (already joined via
--   s.canonical_sku_id). This mirrors the BUG-147 AC1 reader refactor on the
--   dashboard API side.
--
--   Must run BEFORE schema/062.
--
-- Safe, forward-only, idempotent (CREATE OR REPLACE VIEW).
-- =============================================================================

BEGIN;

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
  COALESCE(st.warehouse, '')                                    AS warehouse,
  COALESCE(
    cc.channel,
    NULLIF(ac.raw_data->>'Channel', ''),
    ''
  )                                                             AS channel,
  COALESCE(
    NULLIF(cc.territory_name, ''),
    t_st.territory_name,
    t_cust.territory_name,
    NULLIF(ac.raw_data->>'Territory', ''),
    ''
  )                                                             AS territory,
  COALESCE(c.customer_name, '')                                 AS customer_name,
  COALESCE(cs.sku_name, s.item_description, '')                 AS sku,
  CASE
    WHEN s.vintage IS NOT NULL
      THEN TRIM(COALESCE(cs.sku_name, s.item_description, '')) || ' ' || s.vintage
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
  cs.range_name                                                 AS range_name,
  COALESCE(NULLIF(cc.rep_name, ''), '')                         AS rep_name
FROM sales_transaction st
LEFT JOIN sku s                   ON s.sku_id       = st.sku_id
LEFT JOIN canonical_sku cs        ON cs.id          = s.canonical_sku_id
LEFT JOIN customer c              ON c.customer_id  = st.customer_id
LEFT JOIN canonical_customer cc   ON cc.id          = c.canonical_customer_id
LEFT JOIN territory t_st          ON t_st.territory_id   = st.territory_id
LEFT JOIN territory t_cust        ON t_cust.territory_id = c.territory_id
LEFT JOIN access_combined_data ac
       ON ac.id = st.transaction_id
      AND st.source_system = 'access_db'
LEFT JOIN vinsight_sales_order_item vsoi
       ON vsoi.order_num = (CASE WHEN st.source_ref ~ '^vinsight-[0-9]+-[0-9]+$'
                                 THEN split_part(st.source_ref, '-', 2)::int END)
      AND vsoi.entry_num = (CASE WHEN st.source_ref ~ '^vinsight-[0-9]+-[0-9]+$'
                                 THEN split_part(st.source_ref, '-', 3)::int END)
      AND st.source_system = 'vinsight';

COMMENT ON VIEW combined_data_enriched IS
  'BUG-20: unified display+filter projection over sales_transaction for '
  '/api/legacy-data. Refactored 2026-04-24 (BUG-147): range_name now sourced '
  'from canonical_sku (via canonical_sku_id FK) instead of wine_range_deprecated '
  '(retired by schema/062). Column signature unchanged. See ADR-010.';

COMMIT;

-- =============================================================================
-- Verification (run manually after apply):
-- =============================================================================
--   -- Expected: no dependency on wine_range_deprecated.
--   SELECT 1 FROM pg_depend d
--   JOIN pg_class t ON t.oid = d.refobjid
--   JOIN pg_rewrite r ON r.oid = d.objid
--   JOIN pg_class src ON src.oid = r.ev_class
--   WHERE t.relname = 'wine_range_deprecated' AND src.relname = 'combined_data_enriched';
--
--   -- Expected: row count unchanged.
--   SELECT count(*) FROM combined_data_enriched;
-- =============================================================================
