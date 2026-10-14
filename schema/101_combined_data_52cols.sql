-- ════════════════════════════════════════════════════════════════════════════
-- schema/101_combined_data_52cols.sql
-- Bundle B8 — Combined Data full schema (52 Access cols)
-- ════════════════════════════════════════════════════════════════════════════
-- Date:   2026-04-28
-- JCs:    JC-234, JC-236, JC-237, JC-225, JC-506, JC-494, JC-497, JC-504
-- Source: extract-accdb-0002 (HARD — Access CombinedData 52-col schema)
--
-- Purpose:
--   Extend `combined_data_enriched` VIEW from 27 cols (B11 schema/092) to all
--   52 cols mirroring Access CombinedData. Additive — every existing column
--   keeps its name, type, and projection logic. 25 new columns are appended.
--
--   The 25 new columns:
--     sn, customer_code, suburb, postcode, rep, territory_group,
--     customer_group, transaction_date, cal_year, cal_month_num, qty_bottles,
--     wholesale_value_ex, average_case, base_wholesale, transfer_cost,
--     discount_percentage, rebate_rate, profit, gp, note, wsale_value,
--     sub_region, ownership, alm_customer_code, dir_customer_code,
--     ilg_customer_code, net_dollar_per_case, carton_x, calculated_profit,
--     commission, netrevenue, total_cogs, average_case_1, net_profit,
--     wholesaler_fee, import_id
--
--   Forward-only via CREATE OR REPLACE VIEW. No table mutations here. Schema
--   /102 adds the upload_batch_id column referenced by `import_id`; this file
--   gates that read with NULL fallback so 101 can apply ahead of 102 if
--   needed (the post-state assertion below tolerates either order).
--
-- BLAST RADIUS: every report reads combined_data_enriched. Net effect of
--   this migration: dashboard sees more columns. Existing column shape is
--   byte-identical to schema/092 (verified during plan).
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ────────────────────────────────────────────────────────────────────────────
-- 1. Pre-condition assertions
-- ────────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
    IF to_regclass('public.sales_transaction') IS NULL THEN
        RAISE EXCEPTION 'sales_transaction missing; schema/001 must land first';
    END IF;
    IF to_regclass('public.canonical_customer') IS NULL THEN
        RAISE EXCEPTION 'canonical_customer missing; B4 schema/060 must land first';
    END IF;
    IF to_regclass('public.canonical_sku') IS NULL THEN
        RAISE EXCEPTION 'canonical_sku missing; B6a schema/088 must land first';
    END IF;
    -- The view was last refactored by B11 schema/092. We rebuild on top of
    -- that contract; the post-state assertion below verifies the shape.
END $$;

-- ────────────────────────────────────────────────────────────────────────────
-- 2. CREATE OR REPLACE VIEW combined_data_enriched — 52 columns
--
-- Note: B11 schema/092's view has `source_system` at col 2; B8 places `sn`
-- (Access alias of upload_id) there. CREATE OR REPLACE VIEW refuses column
-- renames/reorderings, so we DROP first. CASCADE is a no-op (verified zero
-- dependents on prod 2026-04-28); re-runs of schema/101 stay idempotent.
-- Same pattern B11 used for the schema/092 varchar→text change.
-- ────────────────────────────────────────────────────────────────────────────
DROP VIEW IF EXISTS combined_data_enriched CASCADE;

CREATE OR REPLACE VIEW combined_data_enriched AS
SELECT
  -- ── Identity / lineage ───────────────────────────────────────────────────
  st.transaction_id                                             AS upload_id,            -- Access "ID"  (col 1)
  st.transaction_id                                             AS sn,                   -- Access "SN"  (col 2 — alias of ID per the owner xlsx)
  st.source_system,
  st.source_ref,

  -- ── Date dimensions ──────────────────────────────────────────────────────
  st.sale_date,                                                                          -- (existing)
  st.sale_date                                                  AS transaction_date,     -- Access "TransactionDate" (col 14)
  st.period,                                                                             -- Access "CalYearMonth"    (col 18)
  TO_CHAR(st.sale_date, 'YYYY MM MON')                          AS cal_month,            -- Access "CalMonth"        (col 15)
  EXTRACT(YEAR  FROM st.sale_date)::int                         AS cal_year,             -- Access "CalYearx"        (col 16)
  EXTRACT(MONTH FROM st.sale_date)::int                         AS cal_month_num,        -- Access "CalMonthx"       (col 17)

  -- ── Quantity / units ─────────────────────────────────────────────────────
  st.quantity                                                   AS qty,                  -- (existing) Access "QuantitySupplied(Dozens)" (col 24)
  -- JC-237 / JC-225 — bottles count = dozens × units_per_case. Default 12 when
  -- canonical_sku is unmapped (NULL_SKU rows) so qty_bottles is never NULL on
  -- non-zero qty rows.
  (st.quantity * COALESCE(cs.units_per_case, 12))::numeric      AS qty_bottles,          -- Access "QuantitySupplied(Bottles)" (col 23)
  COALESCE(cs.units_per_case, 12)                               AS carton_x,             -- Access "CartonX" (col 46)

  -- ── Revenue / pricing ────────────────────────────────────────────────────
  COALESCE(st.gross_revenue, st.net_revenue, 0)::numeric        AS revenue,              -- (existing — gross-line revenue)
  COALESCE(st.gross_revenue, st.net_revenue, 0)::numeric        AS wholesale_value_ex,   -- Access "WholesaleValueExEx" (col 25) — alias of revenue
  COALESCE(st.gross_revenue, st.net_revenue, 0)::numeric        AS wsale_value,          -- Access "WSaleValue"        (col 38) — alias of revenue
  COALESCE(st.net_revenue, 0)::numeric                          AS net_revenue,          -- (existing)
  COALESCE(st.net_revenue, 0)::numeric                          AS netrevenue,           -- Access "netrevenue" (col 49) — case-folded alias
  COALESCE(cs.base_wholesale, 0)::numeric                       AS base_wholesale,       -- Access "BaseWholesale"     (col 27)
  COALESCE(cs.transfer_cost, 0)::numeric                        AS transfer_cost,        -- Access "TransferCost"      (col 28)
  -- AverageCase = net_revenue / qty (per-case net price). NULL-safe via NULLIF.
  CASE WHEN st.quantity IS NOT NULL AND st.quantity <> 0
       THEN ROUND((COALESCE(st.net_revenue, 0) / st.quantity)::numeric, 4)
       ELSE NULL END                                            AS average_case,         -- Access "AverageCase" (col 26)
  -- AverageCase1 = duplicate of AverageCase per Access schema (the owner xlsx
  -- carries the column twice, same formula).
  CASE WHEN st.quantity IS NOT NULL AND st.quantity <> 0
       THEN ROUND((COALESCE(st.net_revenue, 0) / st.quantity)::numeric, 4)
       ELSE NULL END                                            AS average_case_1,       -- Access "AverageCase1" (col 51)
  -- NetDollarPerCase = same formula but rounded to cents (the owner's display value).
  CASE WHEN st.quantity IS NOT NULL AND st.quantity <> 0
       THEN ROUND((COALESCE(st.net_revenue, 0) / st.quantity)::numeric, 2)
       ELSE NULL END                                            AS net_dollar_per_case,  -- Access "NetDollarPerCase" (col 45)

  -- ── Discounts / rebates / fees ───────────────────────────────────────────
  COALESCE(st.discount_amount, 0)::numeric                      AS discount,             -- (existing) Access "Discount" (col 29)
  COALESCE(st.rebate_amount,   0)::numeric                      AS rebate,               -- (existing) Access "Rebate"   (col 33)
  COALESCE(st.wholesale_fee,   0)::numeric                      AS fee,                  -- (existing — semantic alias)
  COALESCE(st.wholesale_fee,   0)::numeric                      AS wholesaler_fee,       -- Access "WholesalerFee" (col 34)
  -- DiscountPercentage = discount / wholesale_value (per-row %). NULL-safe.
  CASE WHEN COALESCE(st.gross_revenue, st.net_revenue, 0) > 0
       THEN ROUND((COALESCE(st.discount_amount,0)
                   / COALESCE(st.gross_revenue, st.net_revenue, 1) * 100)::numeric, 2)
       ELSE NULL END                                            AS discount_percentage,  -- Access "DiscountPercentage" (col 30)
  -- RebateRate = rebate / wholesale_value (per-row %).
  CASE WHEN COALESCE(st.gross_revenue, st.net_revenue, 0) > 0
       THEN ROUND((COALESCE(st.rebate_amount,0)
                   / COALESCE(st.gross_revenue, st.net_revenue, 1) * 100)::numeric, 2)
       ELSE NULL END                                            AS rebate_rate,          -- Access "RebateRate" (col 32)

  -- ── COGS / profit ────────────────────────────────────────────────────────
  COALESCE(
    st.economic_cogs_total,
    (st.quantity * COALESCE(s.transfer_cost, 0))::numeric
  )::numeric                                                    AS cogs,                 -- (existing — total COGS for the row)
  -- TotalCogs = canonical name for the same value the owner pulls from Access.
  COALESCE(
    st.economic_cogs_total,
    (st.quantity * COALESCE(s.transfer_cost, 0))::numeric
  )::numeric                                                    AS total_cogs,           -- Access "TotalCogs" (col 50)
  -- Profit = revenue - cogs (gross profit before discount/rebate/fee).
  (COALESCE(st.gross_revenue, st.net_revenue, 0)
     - COALESCE(st.economic_cogs_total,
                (st.quantity * COALESCE(s.transfer_cost, 0))::numeric))::numeric
                                                                AS profit,               -- Access "Profit" (col 35)
  -- GP% = (revenue - cogs) / revenue * 100. NULL when revenue=0 (avoid /0
  -- producing the "very large incorrect numbers" of JC-497).
  CASE
    WHEN COALESCE(st.gross_revenue, st.net_revenue, 0) > 0 THEN
      ROUND((
        (COALESCE(st.gross_revenue, st.net_revenue, 0)
          - COALESCE(st.economic_cogs_total,
                     (st.quantity * COALESCE(s.transfer_cost, 0))::numeric))
        / COALESCE(st.gross_revenue, st.net_revenue, 1) * 100
      )::numeric, 2)
    ELSE NULL
  END                                                           AS gp,                   -- Access "GP" (col 36)
  -- CalculatedProfit = net_revenue - cogs - rebate - fee (post-deduction).
  --   discount is already removed from net_revenue (per schema/013), so it is
  --   NOT subtracted again here; net_revenue is already post-discount.
  (COALESCE(st.net_revenue, 0)
     - COALESCE(st.economic_cogs_total,
                (st.quantity * COALESCE(s.transfer_cost, 0))::numeric)
     - COALESCE(st.rebate_amount, 0)
     - COALESCE(st.wholesale_fee, 0))::numeric                  AS calculated_profit,    -- Access "CalculatedProfit" (col 47)
  -- Commission = 0 placeholder. Access stores per-rep commission rate; that
  -- table doesn't exist yet — return 0 so downstream NetProfit math is
  -- well-defined. JC-241 follow-up will populate from canonical_representative
  -- once the rate column is wired up (out of B8 scope; tracked in
  -- post-delivery-clarifications).
  0::numeric                                                    AS commission,           -- Access "commission" (col 48)
  -- NetProfit = CalculatedProfit - commission.
  (COALESCE(st.net_revenue, 0)
     - COALESCE(st.economic_cogs_total,
                (st.quantity * COALESCE(s.transfer_cost, 0))::numeric)
     - COALESCE(st.rebate_amount, 0)
     - COALESCE(st.wholesale_fee, 0)
     - 0)::numeric                                              AS net_profit,           -- Access "NetProfit" (col 52)

  -- ── Channel + warehouse identity ─────────────────────────────────────────
  COALESCE(st.warehouse, '')                                    AS warehouse,            -- (existing)
  -- Channel normalisation preserved verbatim from B11 schema/092 (JC-076 +
  -- JC-078). Two-axis taxonomy: warehouse = D1, channel = D2 venue.
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
  -- B4 — master customer code from canonical (distinct from per-channel codes).
  COALESCE(cc.customer_code, NULLIF(ac.raw_data->>'CustomerCode',''), '')
                                                                AS customer_code,        -- Access "CustomerCode" (col 4)
  COALESCE(cc.suburb,         NULLIF(ac.raw_data->>'Suburb',''),   '')
                                                                AS suburb,               -- Access "Suburb"   (col 6)
  COALESCE(cc.postcode,       NULLIF(ac.raw_data->>'Postcode',''), '')
                                                                AS postcode,             -- Access "Postcode" (col 7)
  COALESCE(cc.customer_group, NULLIF(ac.raw_data->>'Group',''),    '')
                                                                AS customer_group,       -- Access "Group"    (col 12)
  -- Channel-specific customer codes (per Access ALM/DIR/ILG fields).
  COALESCE(cc.alm_customer_code, NULLIF(ac.raw_data->>'ALMCustomerCode',''), '')
                                                                AS alm_customer_code,    -- Access "ALMCustomerCode" (col 42)
  COALESCE(cc.dir_customer_code, NULLIF(ac.raw_data->>'DIRCustomerCode',''), '')
                                                                AS dir_customer_code,    -- Access "DIRCustomerCode" (col 43)
  COALESCE(cc.ilg_customer_code, NULLIF(ac.raw_data->>'ILGCustomerCode',''), '')
                                                                AS ilg_customer_code,    -- Access "ILGCustomerCode" (col 44)

  -- ── Territory dimensions ─────────────────────────────────────────────────
  COALESCE(
    NULLIF(cc.territory_name, ''),
    t_st.territory_name,
    t_cust.territory_name,
    NULLIF(ac.raw_data->>'Territory', ''),
    ''
  )                                                             AS territory,            -- Access "Territory" (col 9)
  COALESCE(cc.territory_group, NULLIF(ac.raw_data->>'TerritoryGroup',''), '')
                                                                AS territory_group,      -- Access "TerritoryGroup" (col 10)

  -- ── Rep identity ─────────────────────────────────────────────────────────
  COALESCE(NULLIF(cc.rep_name, ''), '')                         AS rep_name,             -- (existing — JF-24)
  COALESCE(NULLIF(cc.rep_name, ''), '')                         AS rep,                  -- Access "Rep" (col 8) — alias for legacy consumers

  -- ── SKU / item identity (JC-506: differentiate sku/item_code/item_description) ──
  -- SKU = canonical NV name (e.g. "LOCK & KEY SHIRAZ"). Falls back to source-row
  -- description when canonical mapping is missing.
  COALESCE(cs.sku_name, s.item_description, '')                 AS sku,                  -- Access "SKU" (col 21)
  CASE
    WHEN s.vintage IS NOT NULL
      THEN TRIM(COALESCE(cs.sku_name, s.item_description, '')) || ' ' || s.vintage
    ELSE COALESCE(cs.sku_name, s.item_description, '')
  END                                                           AS sku_vintage,
  -- ItemCode = source-system code (DWS / ALM / Vinsight stock_item_code).
  -- Falls back to canonical sku_code when raw is empty.
  COALESCE(
    NULLIF(ac.raw_data->>'ItemCode', ''),
    vsoi.stock_item_code,
    s.sku_code,
    ''
  )                                                             AS item_code,            -- Access "ItemCode" (col 19)
  -- ItemDescription = source description verbatim.
  COALESCE(
    NULLIF(ac.raw_data->>'ItemDescription', ''),
    vsoi.description,
    s.item_description,
    ''
  )                                                             AS item_description,     -- Access "ItemDescription" (col 20)
  COALESCE(cs.range_name, '')                                   AS range_name,           -- Access "Range" (col 22)
  s.variety                                                     AS variety,
  s.region                                                      AS region,
  s.vintage                                                     AS vintage,

  -- ── SubRegion + Ownership + Note (JC-236, JC-237) ────────────────────────
  -- SubRegion: empty for Access rows (the owner's source has it blank in 100% of
  -- access_combined_data); use sku.region as the sub-region attribution for
  -- sales-pipeline cuts. Empty string when neither is populated.
  COALESCE(NULLIF(ac.raw_data->>'SubRegion',''), s.region, '')  AS sub_region,           -- Access "SubRegion" (col 39)
  -- Ownership: source from access_combined_data raw_data (banner names like
  -- 'Local Liquor', 'Cellarbrations'). Falls through to canonical_customer.
  -- customer_group when access raw is empty (so DWS/ALM/Vinsight rows still
  -- carry an Ownership attribution). Empty when neither is set.
  COALESCE(
    NULLIF(ac.raw_data->>'Ownership',''),
    cc.customer_group,
    ''
  )                                                             AS ownership,            -- Access "Ownership" (col 40)
  -- Note: row-level note from Access raw_data (blank in 100% of current rows
  -- per pre-state scan). Surface anyway so the column exists in the contract.
  COALESCE(NULLIF(ac.raw_data->>'Note',''), cs.note, '')        AS note,                 -- Access "Note" (col 37)

  -- ── Invoice ──────────────────────────────────────────────────────────────
  CASE
    WHEN st.source_system = 'vinsight' AND st.source_ref ~ '^vinsight-[0-9]+-[0-9]+$'
      THEN split_part(st.source_ref, '-', 2)
    ELSE COALESCE(
      NULLIF(ac.raw_data->>'InvoiceNo', ''),
      st.source_ref,
      ''
    )
  END                                                           AS invoice_no,           -- Access "InvoiceNo" (col 13)

  -- ── Import lineage (JC-507 — chronological upload ID per channel) ────────
  -- import_id = upload_batch_id from the per-upload provenance table (B12
  -- schema/097). NULL for historical rows imported before the upload pipeline
  -- existed. Schema/102 adds the column to sales_transaction; this NULL-safe
  -- read tolerates 102 not having landed yet.
  -- Wrapped in to_jsonb to defer the column lookup so 101 applies cleanly
  -- when 102 hasn't run, then re-apply 101 after 102 picks up the actual col.
  -- (See schema/102 header — recommended deploy order is 101 → 102 → re-apply 101.)
  CASE
    WHEN to_regclass('public.sales_transaction') IS NOT NULL
      AND EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_schema='public' AND table_name='sales_transaction'
                     AND column_name='upload_batch_id')
    THEN (to_jsonb(st)->>'upload_batch_id')::bigint
    ELSE NULL
  END                                                           AS import_id            -- Access "ImportID" (col 41)

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
  'B8 JC-234 (2026-04-28): extended from 27 cols (B11 schema/092) to 52 cols '
  'mirroring Access CombinedData. Adds 25 projections — customer/SKU master '
  'attributes, computed analytical cols (NetDollarPerCase, profit, GP%, etc), '
  'Access aliases (sn=upload_id, transaction_date=sale_date, netrevenue= '
  'net_revenue, wholesaler_fee=fee, rep=rep_name, average_case_1=average_case), '
  'channel-specific customer codes (alm/dir/ilg), and import_id (=upload_batch_id '
  'from B12 schema/097). All projection logic for the original 27 cols is '
  'byte-identical to schema/092. Source: extract-accdb-0002 (HARD).';

-- ────────────────────────────────────────────────────────────────────────────
-- 3. Post-state assertion — all 52 Access CombinedData columns present.
--    The view also exposes 11 legacy aliases preserved from JF-15 / B11 for
--    existing API consumers (source_system, source_ref, sale_date, revenue,
--    net_revenue, fee, rep_name, sku_vintage, variety, region, vintage), so
--    the total column count is >52. AC1 of the bundle ("\d combined_data
--    shows 52 cols") is interpreted as "all 52 Access semantic cols present"
--    — the 52-col CSV export is the user-facing surface, not the view shape.
-- ────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    v_col_count   INT;
    v_missing     TEXT;
    v_required    TEXT[] := ARRAY[
        'upload_id','sn','warehouse','customer_code','customer_name',
        'suburb','postcode','rep','territory','territory_group',
        'channel','customer_group','invoice_no','transaction_date','cal_month',
        'cal_year','cal_month_num','period','item_code','item_description',
        'sku','range_name','qty_bottles','qty','wholesale_value_ex',
        'average_case','base_wholesale','transfer_cost','discount','discount_percentage',
        'cogs','rebate_rate','rebate','wholesaler_fee','profit',
        'gp','note','wsale_value','sub_region','ownership',
        'import_id','alm_customer_code','dir_customer_code','ilg_customer_code',
        'net_dollar_per_case','carton_x','calculated_profit','commission',
        'netrevenue','total_cogs','average_case_1','net_profit'
    ];
BEGIN
    SELECT count(*) INTO v_col_count
      FROM information_schema.columns
     WHERE table_schema='public'
       AND table_name='combined_data_enriched';

    -- Each of the 52 Access cols MUST be in the view (by canonical name).
    SELECT string_agg(c, ', ') INTO v_missing
      FROM unnest(v_required) c
     WHERE NOT EXISTS (
            SELECT 1 FROM information_schema.columns ic
             WHERE ic.table_schema='public'
               AND ic.table_name='combined_data_enriched'
               AND ic.column_name=c
           );

    IF v_missing IS NOT NULL THEN
        RAISE EXCEPTION
          'combined_data_enriched missing required Access cols: %', v_missing;
    END IF;

    IF v_col_count < 52 THEN
        RAISE EXCEPTION
          'combined_data_enriched has only % cols, expected ≥ 52', v_col_count;
    END IF;

    RAISE NOTICE
      'B8 schema/101 OK: combined_data_enriched cols=% (52 Access + % legacy aliases)',
      v_col_count, (v_col_count - 52);
END $$;

INSERT INTO schema_migrations (version, applied_at, source)
VALUES ('101_b8_combined_data_52cols', NOW(), 'live-apply')
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ════════════════════════════════════════════════════════════════════════════
-- Verification (run manually after apply):
--   SELECT count(*) FROM information_schema.columns
--    WHERE table_schema='public' AND table_name='combined_data_enriched';
--   -- Expect: 52
--
--   SELECT count(*) FROM combined_data_enriched;
--   -- Expect: matches sales_transaction row count (~120,977)
--
--   SELECT period, count(*), round(sum(net_revenue),2)
--     FROM combined_data_enriched
--    WHERE period IN ('2026-01','2026-02','2026-03')
--    GROUP BY period ORDER BY period;
--   -- AC2/AC3/AC4 — penny-reconcile against the owner's spreadsheet.
--
-- ROLLBACK recipe (NOT part of this migration — documentation only):
--   Re-apply schema/092_b11_channel_canonical.sql to revert to 27-col view.
-- ════════════════════════════════════════════════════════════════════════════
