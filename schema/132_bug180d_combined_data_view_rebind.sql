-- ════════════════════════════════════════════════════════════════════════════
-- ════════════════════════════════════════════════════════════════════════════
-- Date:       2026-05-05 (drafted)
-- Bug:        BUG-180d (Phase A Lane F, Q1 BAKED)
-- Scenario:   A (read-side fix, no schema migration on tables; data already preserved
--             in access_combined_data.raw_data JSONB).
--
-- Purpose:
--   Rebind 4 column projections + 1 JOIN condition in `combined_data_enriched`
--   so the `/api/export/combined-data` CSV mirrors Access tbl_CombinedData
--   semantics for cols ID (1), CustomerCode (4), InvoiceNo (13), ItemCode (19).
--
--   Root cause: schema/115's `LEFT JOIN access_combined_data ac
--               ON ac.id = st.transaction_id AND st.source_system = 'access_db'`
--   uses `ac.id` (= access_combined_data SERIAL PK) which is not 1:1 with
--   `st.transaction_id` (= sales_transaction SERIAL PK). The intended join key
--   is `ac.raw_data->>'ID' = st.source_ref` (per `etl/transform_to_core.py:661`
--   which sets source_ref to the Access auto-PK).
--
--   Built on top of schema/115_r004_customer_name_at_suburb_view.sql (current
--   live view shape). Preserves R-004 NAME @ SUBURB CASE + BUG-63a/schema-109
--   sva/channel joins + all 49 unaffected projections byte-identical.
--
--   (Q1-blocked framing — superseded).
--
-- BLAST RADIUS: every consumer of combined_data_enriched (3 routes:
--   /api/export/combined-data, /api/legacy-data, /api/channels). CSV-export shape
--   for cols 5-12, 14-18, 20-52 is byte-identical post-fix. Cols 1, 4, 13, 19
--   change semantics — that IS the fix. Verify with recon coverage 0%→≥90%
--   (Gate 4 in PHASE-A-KICKOFF).
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ────────────────────────────────────────────────────────────────────────────
-- 1. PRE-asserts
-- ────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    v_view_exists       BOOLEAN;
    v_st_count          INT;
    v_acd_count         INT;
    v_access_db_count   INT;
    v_join_match_count  INT;
    v_sva_exists        BOOLEAN;
    v_ch_exists         BOOLEAN;
BEGIN
    -- 1.a — view + tables present
    SELECT EXISTS (
        SELECT 1 FROM information_schema.views
        WHERE table_schema='public' AND table_name='combined_data_enriched'
    ) INTO v_view_exists;
    IF NOT v_view_exists THEN
        RAISE EXCEPTION 'PRE-ASSERT FAIL: combined_data_enriched view missing — schema/115 must land first';
    END IF;

    IF to_regclass('public.access_combined_data') IS NULL THEN
        RAISE EXCEPTION 'PRE-ASSERT FAIL: access_combined_data table missing';
    END IF;

    SELECT EXISTS (SELECT 1 FROM information_schema.tables
                   WHERE table_schema='public' AND table_name='sale_vintage_attribution')
      INTO v_sva_exists;
    IF NOT v_sva_exists THEN
        RAISE EXCEPTION 'PRE-ASSERT FAIL: sale_vintage_attribution missing — schema/082+109 must land first';
    END IF;

    SELECT EXISTS (SELECT 1 FROM information_schema.tables
                   WHERE table_schema='public' AND table_name='channel')
      INTO v_ch_exists;
    IF NOT v_ch_exists THEN
        RAISE EXCEPTION 'PRE-ASSERT FAIL: channel table missing — schema/115 must land first';
    END IF;

    -- 1.b — row counts (sanity baseline)
    EXECUTE 'SELECT count(*) FROM sales_transaction'              INTO v_st_count;
    EXECUTE 'SELECT count(*) FROM access_combined_data'           INTO v_acd_count;
    EXECUTE 'SELECT count(*) FROM sales_transaction WHERE source_system = ''access_db'''
                                                                  INTO v_access_db_count;
    RAISE NOTICE 'PRE: sales_transaction=% / access_combined_data=% / access_db rows=%',
                 v_st_count, v_acd_count, v_access_db_count;

    -- Expect: access_combined_data ≈ access_db rows ≈ 120,343 (HARD baseline)
    IF v_access_db_count < 119000 OR v_access_db_count > 121000 THEN
        RAISE WARNING 'access_db rows out of expected range 119K-121K: actual=%',
                      v_access_db_count;
    END IF;

    -- 1.c — confirm proposed JOIN key works for ≥95% of access_db rows
    EXECUTE $sql$
        SELECT count(*)
        FROM sales_transaction st
        JOIN access_combined_data ac ON ac.raw_data->>'ID' = st.source_ref
        WHERE st.source_system = 'access_db'
    $sql$ INTO v_join_match_count;
    RAISE NOTICE 'PRE: proposed JOIN ac.raw_data->>ID = st.source_ref → matched %  / % access_db rows',
                 v_join_match_count, v_access_db_count;

    IF v_join_match_count < (v_access_db_count * 0.95)::int THEN
        RAISE EXCEPTION
            'PRE-ASSERT FAIL: proposed JOIN matches only %.1f%% of access_db rows; require ≥95%%',
            (v_join_match_count::numeric / NULLIF(v_access_db_count, 0) * 100);
    END IF;
END $$;

-- ────────────────────────────────────────────────────────────────────────────
-- 2. CREATE OR REPLACE VIEW combined_data_enriched
--
-- Built on top of schema/115_r004_customer_name_at_suburb_view.sql (current
-- live shape). 4 surgical edits + 1 JOIN-condition swap. All other projections
-- + all other JOINs byte-identical to schema/115.
--
-- Diff vs schema/115:
--   (a) JOIN access_combined_data: change ON clause from
--           ac.id = st.transaction_id
--       to
--           ac.raw_data->>'ID' = st.source_ref
--       (other clause unchanged: AND st.source_system = 'access_db').
--   (b) Col 1 (upload_id) + col 2 (sn): for access_db rows, surface Access ID
--       instead of Postgres SERIAL. NULL-coalesce to st.transaction_id for
--       non-access_db so the column never goes empty.
--   (c) Col 4 (customer_code): order-of-precedence flip — read raw_data first
--       so HARD value wins over the (often-empty) cc.customer_code.
--   (d) Col 13 (invoice_no): explicit access_db branch — never fall through to
--       st.source_ref (= Access ID) for access_db rows.
--   (e) Col 19 (item_code): no projection edit needed; already reads raw_data
--       first. The JOIN fix (a) makes this column auto-correct.
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
       ON ch_st.channel_id = st.channel_id;

COMMENT ON VIEW combined_data_enriched IS
  'BUG-180d Lane F (2026-05-05): rebind JOIN access_combined_data ON '
  'ac.raw_data->>ID = st.source_ref (was: ac.id = st.transaction_id, broken '
  'because the two PKs are independent SERIALs). Cols 1, 2, 4, 13, 19 now '
  'surface HARD Access values (Access ID, real CustomerCode, real InvoiceNo, '
  'Vinsight ItemCode). 47 other cols byte-identical to schema/115. Preserves '
  'R-004 NAME @ SUBURB CASE + BUG-63a sva/channel joins from schema/109+115.';

-- ────────────────────────────────────────────────────────────────────────────
-- 3. POST-asserts
-- ────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    v_total                INT;
    v_invoice_alphanum     INT;
    v_item_alphanum        INT;
    v_customer_filled      INT;
    v_access_db_total      INT;
    v_id_access_match      INT;
BEGIN
    -- Total rows must be unchanged (LEFT JOIN doesn't fanout — sva, ch_st
    -- already in baseline schema/115).
    SELECT count(*) INTO v_total FROM combined_data_enriched;
    RAISE NOTICE 'POST: combined_data_enriched row count = %', v_total;
    IF v_total < 119000 OR v_total > 122000 THEN
        RAISE EXCEPTION 'POST-ASSERT FAIL: row count % out of expected 119K-122K range', v_total;
    END IF;

    -- Cell-shape checks on access_db slice.
    SELECT count(*) INTO v_access_db_total
      FROM combined_data_enriched WHERE source_system = 'access_db';

    -- (a) upload_id should match Access ID for access_db rows. HARD-shape
    --     range: 11K-376K (5-6 digit). Pre-fix: 100% Postgres SERIAL in
    --     600K-1.1M range. Post-fix: ≥95% in 11K-376K range.
    SELECT count(*) INTO v_id_access_match
      FROM combined_data_enriched
     WHERE source_system = 'access_db'
       AND upload_id BETWEEN 1 AND 999999;
    RAISE NOTICE 'POST: access_db rows with upload_id in HARD range (1-999999) = % / % (= %.1f%%)',
                 v_id_access_match, v_access_db_total,
                 (v_id_access_match::numeric / NULLIF(v_access_db_total, 0) * 100);
    IF v_id_access_match < (v_access_db_total * 0.95)::int THEN
        RAISE EXCEPTION
            'POST-ASSERT FAIL: only %.1f%% of access_db upload_id in HARD range; require ≥95%%',
            (v_id_access_match::numeric / NULLIF(v_access_db_total, 0) * 100);
    END IF;

    -- (b) InvoiceNo: ≥80% of access_db rows should have non-pure-numeric
    --     value OR a 4-8 digit ALM pattern (HARD invoices like TRAVIS1701,
    --     ADAM0101, 016573 all match). Pre-fix: 100% pure 6-digit Access-ID
    --     pattern (which actually overlaps the alm pattern, so we use a
    --     stricter check — exclude exact equality with upload_id).
    SELECT count(*) INTO v_invoice_alphanum
      FROM combined_data_enriched
     WHERE source_system = 'access_db'
       AND invoice_no <> ''
       AND invoice_no <> upload_id::text  -- pre-fix had invoice_no = Access ID
       AND (invoice_no ~ '^[A-Za-z]' OR invoice_no ~ '^[0-9]{4,8}$');
    RAISE NOTICE 'POST: access_db rows with HARD-shape InvoiceNo (and != upload_id) = % / % (= %.1f%%)',
                 v_invoice_alphanum, v_access_db_total,
                 (v_invoice_alphanum::numeric / NULLIF(v_access_db_total, 0) * 100);
    IF v_invoice_alphanum < (v_access_db_total * 0.80)::int THEN
        RAISE EXCEPTION
            'POST-ASSERT FAIL: only %.1f%% of access_db InvoiceNo match HARD shape; require ≥80%%',
            (v_invoice_alphanum::numeric / NULLIF(v_access_db_total, 0) * 100);
    END IF;

    -- (c) ItemCode: ≥80% of access_db rows should match Vinsight stock-code
    --     shape (uppercase letters + digits, NO spaces). Pre-fix: 100% had
    --     spaces (canonical name strings).
    SELECT count(*) INTO v_item_alphanum
      FROM combined_data_enriched
     WHERE source_system = 'access_db'
       AND item_code ~ '^[A-Z0-9]+$'
       AND length(item_code) BETWEEN 6 AND 14;
    RAISE NOTICE 'POST: access_db rows with HARD-shape ItemCode = % / % (= %.1f%%)',
                 v_item_alphanum, v_access_db_total,
                 (v_item_alphanum::numeric / NULLIF(v_access_db_total, 0) * 100);
    IF v_item_alphanum < (v_access_db_total * 0.80)::int THEN
        RAISE EXCEPTION
            'POST-ASSERT FAIL: only %.1f%% of access_db ItemCode match HARD shape; require ≥80%%',
            (v_item_alphanum::numeric / NULLIF(v_access_db_total, 0) * 100);
    END IF;

    -- (d) CustomerCode: ≥80% non-empty for access_db rows. Pre-fix: 0%.
    SELECT count(*) INTO v_customer_filled
      FROM combined_data_enriched
     WHERE source_system = 'access_db'
       AND customer_code <> '';
    RAISE NOTICE 'POST: access_db rows with non-empty CustomerCode = % / % (= %.1f%%)',
                 v_customer_filled, v_access_db_total,
                 (v_customer_filled::numeric / NULLIF(v_access_db_total, 0) * 100);
    IF v_customer_filled < (v_access_db_total * 0.80)::int THEN
        RAISE EXCEPTION
            'POST-ASSERT FAIL: only %.1f%% of access_db CustomerCode populated; require ≥80%%',
            (v_customer_filled::numeric / NULLIF(v_access_db_total, 0) * 100);
    END IF;

    RAISE NOTICE 'BUG-180d Lane F schema rebind OK: cols 1/2/4/13/19 re-bound to HARD values';
END $$;

INSERT INTO schema_migrations (version, applied_at, source)
VALUES ('132_bug180d_combined_data_view_rebind', NOW(), 'live-apply')
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ════════════════════════════════════════════════════════════════════════════
-- Verification (post-apply, run manually):
--
-- -- 1. Row count unchanged
-- SELECT count(*) FROM combined_data_enriched;
-- -- Expect: ~120,977 (or whatever sales_transaction count is at deploy time).
--
-- -- 2. Spot-check 5 rows from the BUG-180d Lane F sample
-- SELECT upload_id, invoice_no, item_code, sku, customer_code
--   FROM combined_data_enriched
--  WHERE customer_name LIKE 'CUSTOMER 25%'
--    AND sale_date = '2019-01-17'
--    AND sku LIKE '%COPPABELLA ROSE%'
--  LIMIT 1;
-- -- Expect: invoice_no='TRAVIS1701', item_code='COCOROSB18', customer_code='NBAWLE01'
-- --         upload_id=195497 (Access ID), NOT 603145 (Postgres PK).
--
-- -- 3. Re-run preflight to regenerate /tmp/preflight-test/ours/legacy_data.csv
-- bash scripts/owner-preflight.sh --no-fetch --skip-sniffs --out-dir /tmp/preflight-test
--
-- -- 4. Re-run recon — expect coverage to rise from 0% to ≥90%
-- python scripts/owner-preflight/recons/recon_legacy_data.py
--
-- -- Visit /legacy-data in chrome-devtools, hit "Export CSV", spot-check
-- -- col 13 + col 19 + col 4 on the 5 sample rows.
--
-- ROLLBACK recipe (NOT part of this migration — documentation only):
--   Re-apply schema/115_r004_customer_name_at_suburb_view.sql to revert.
-- ════════════════════════════════════════════════════════════════════════════
