-- ════════════════════════════════════════════════════════════════════════════
-- schema/092_b11_channel_canonical.sql
-- B11 / JC-076, JC-077, JC-078, JC-089
-- Channel canonicalisation: 12 raw → 7 canonical (canonical_customer.channel)
--                           12 raw → 6 canonical (combined_data_enriched.channel
--                                                 view projection — drops ALM
--                                                 because ALM is the warehouse
--                                                 axis, not the venue axis).
-- ════════════════════════════════════════════════════════════════════════════
-- Date: 2026-04-27
-- Bundle: B11 (Channels + Vinsight import correctness)
--
--   - 7 canonical for canonical_customer.channel: JC-077 extract-xlsx-0008
--     (the owner recon mar26 xlsx) + Access Customers.Channel raw distribution
--     (1718+1013+605+335+123+76+72+55+42+32+19+9+1 → 7 distinct after
--      case-fold).
--   - 6 canonical for combined_data: JC-078 (drop ALM — ALM is warehouse).
--   - Mapping table validated against
--     WHOLESALE, ON PREMISE, OFF PREMISE, DIRECT) + 7-row Customers.Channel
--     post-canonicalisation (5 + HOFFICE + ALM).
--
-- ORTHOGONAL AXES (per ADR-017 + schema/078):
--   D1 sales/warehouse channel: DWS / ALM / Direct → channel table (3 rows)
--                               + customer.warehouse_channel VARCHAR(20).
--                               B11 does NOT touch D1.
--   D2 venue type:              ON PREMISE / OFF PREMISE / WHOLESALE / HYBRID
--                               / DIRECT / HOFFICE / ALM (customer-level only)
--                               → canonical_customer.channel (varchar 100).
--                               B11 enforces CHECK + canonicalises this.
--
--   - UPDATE within transaction is reversible via the rollback recipe at the
--     bottom of this file (snapshot table channel_canonical_pre_b11_snapshot
--     captures pre-state for one-shot restore).
--   - CHECK constraint added via DO block ADD CONSTRAINT IF NOT EXISTS guard.
--   - View uses CREATE OR REPLACE; prior definition recoverable from
--     schema/068_bug147_combined_data_enriched_refactor.sql.
--
-- BLAST RADIUS: any read of canonical_customer.channel or
-- combined_data_enriched.channel — /sales filter, /margin, /reports.
-- New CHECK rejects writes outside the 7-value enum (NULL allowed).
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ────────────────────────────────────────────────────────────────────────────
-- 1. PRE-state assertion
-- ────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
  v_total          INT;
  v_column_exists  BOOL;
  v_check_exists   BOOL;
  v_pre_distinct   INT;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM information_schema.columns
     WHERE table_schema = 'public'
       AND table_name   = 'canonical_customer'
       AND column_name  = 'channel'
  ) INTO v_column_exists;

  IF NOT v_column_exists THEN
    RAISE EXCEPTION 'B11 PRE: canonical_customer.channel column missing — schema/060 must apply first';
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conname = 'canonical_customer_channel_check'
  ) INTO v_check_exists;

  SELECT count(*) INTO v_total FROM canonical_customer;

  SELECT count(DISTINCT channel)
    INTO v_pre_distinct
    FROM canonical_customer
   WHERE channel IS NOT NULL AND channel <> '';

  RAISE NOTICE 'B11 PRE: canonical_customer rows=% pre_distinct_channels=% check_already_exists=%',
    v_total, v_pre_distinct, v_check_exists;

  -- Sanity: B4 left canonical_customer near 4014 rows.
  IF v_total < 4000 OR v_total > 4100 THEN
    RAISE EXCEPTION 'B11 PRE: unexpected canonical_customer count % (expected ~4014 post-B4)', v_total;
  END IF;
END;
$$;

-- ────────────────────────────────────────────────────────────────────────────
-- 2. Snapshot pre-state (one-shot for rollback; safe to re-run = TRUNCATE+INSERT)
-- ────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS channel_canonical_pre_b11_snapshot (
    canonical_customer_id  INT     PRIMARY KEY,
    channel_pre_b11        VARCHAR(100),
    snapshot_at            TIMESTAMP NOT NULL DEFAULT NOW()
);

TRUNCATE channel_canonical_pre_b11_snapshot;

INSERT INTO channel_canonical_pre_b11_snapshot (canonical_customer_id, channel_pre_b11)
SELECT id, channel
  FROM canonical_customer;

-- ────────────────────────────────────────────────────────────────────────────
-- 3. Canonicalise canonical_customer.channel (12 raw → 7 canonical)
--    Mapping derived from B11-pre-state.txt §"Access Customers.Channel".
-- ────────────────────────────────────────────────────────────────────────────
UPDATE canonical_customer
   SET channel = CASE
         WHEN channel IS NULL OR TRIM(channel) = '' THEN NULL
         WHEN UPPER(TRIM(channel)) IN ('OFF PREMISE', 'OFF-PREMISE', 'OFF_PREMISE') THEN 'OFF PREMISE'
         WHEN UPPER(TRIM(channel)) IN ('ON PREMISE', 'ON-PREMISE', 'ON_PREMISE')   THEN 'ON PREMISE'
         WHEN UPPER(TRIM(channel)) = 'HYBRID'                                       THEN 'HYBRID'
         WHEN UPPER(TRIM(channel)) IN ('WHOLESALE', 'WHOLE SALE')                  THEN 'WHOLESALE'
         WHEN UPPER(TRIM(channel)) = 'DIRECT'                                       THEN 'DIRECT'
         WHEN UPPER(TRIM(channel)) IN ('HOFFICE', 'HEAD OFFICE', 'HEADOFFICE', 'HEAD-OFFICE') THEN 'HOFFICE'
         WHEN UPPER(TRIM(channel)) = 'ALM'                                          THEN 'ALM'
         WHEN UPPER(TRIM(channel)) IN ('YOUNG & RASHLEIGH', 'YOUNG&RASHLEIGH', 'Y&R', 'YNR')
              THEN 'WHOLESALE'  -- YnR is wholesale distributor (warehouse, not venue) per JC-077
         ELSE NULL              -- unknown raw value → NULL rather than fabricate; logged below
       END;

-- Log any rows whose pre-value couldn't be mapped (now NULL but pre-snapshot non-null)
DO $$
DECLARE
  v_unmapped INT;
BEGIN
  SELECT count(*) INTO v_unmapped
    FROM channel_canonical_pre_b11_snapshot s
    JOIN canonical_customer cc ON cc.id = s.canonical_customer_id
   WHERE s.channel_pre_b11 IS NOT NULL
     AND TRIM(s.channel_pre_b11) <> ''
     AND cc.channel IS NULL;

  IF v_unmapped > 0 THEN
    RAISE NOTICE 'B11 CANONICALISE: % rows had unmapped channel values nulled — see channel_canonical_pre_b11_snapshot for the originals', v_unmapped;
  END IF;
END;
$$;

-- ────────────────────────────────────────────────────────────────────────────
-- 4. Add CHECK constraint (NULL allowed; 7 canonical values per JC-077)
--    DO-block guard makes this idempotent (no IF NOT EXISTS for ADD CONSTRAINT
--    pre-PG16).
-- ────────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conname = 'canonical_customer_channel_check'
  ) THEN
    ALTER TABLE canonical_customer
      ADD CONSTRAINT canonical_customer_channel_check
      CHECK (
        channel IS NULL
        OR channel IN (
            'ALM',
            'DIRECT',
            'HOFFICE',
            'HYBRID',
            'OFF PREMISE',
            'ON PREMISE',
            'WHOLESALE'
        )
      );
  END IF;
END;
$$;

COMMENT ON CONSTRAINT canonical_customer_channel_check ON canonical_customer IS
  'B11 JC-077 (2026-04-27): canonical_customer.channel restricted to 7 D2 venue '
  'values + NULL. Source: Access Customers.Channel post-case-fold (the '
  'xtblChannel lookup covers 5 of 7; HOFFICE + ALM '
  'come from the actual Customers data per JC-077 extract-xlsx-0008).';

-- ────────────────────────────────────────────────────────────────────────────
-- 5. Refactor combined_data_enriched view to project 6 canonical channels
--    (drops ALM and Young & Rashleigh — those are D1 warehouse identities,
--     not D2 venues — per JC-078).
-- ────────────────────────────────────────────────────────────────────────────
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
  -- B11 JC-078: project channel through a normalising CASE so combined_data
  -- has exactly 6 distinct non-empty values (DIRECT, HOFFICE, HYBRID,
  -- OFF PREMISE, ON PREMISE, WHOLESALE). ALM + warehouse identities map to
  -- empty string here — their identity is preserved in the `warehouse` column.
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
      WHEN 'ALM'                THEN ''   -- D1 warehouse, not a D2 venue
      WHEN 'YOUNG & RASHLEIGH'  THEN ''   -- D1 warehouse
      WHEN 'YOUNG&RASHLEIGH'    THEN ''
      WHEN 'Y&R'                THEN ''
      WHEN 'YNR'                THEN ''
      ELSE ''
    END,
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
  'B11 JC-076 + JC-078 (2026-04-27): refactored from schema/068 to project '
  '`channel` through a normalising CASE — 12 raw values collapse to exactly '
  '6 D2 venue values (DIRECT, HOFFICE, HYBRID, OFF PREMISE, ON PREMISE, '
  'WHOLESALE). ALM + Young & Rashleigh raw values are D1 warehouse identities '
  'and project to empty string here; their identity is preserved in `warehouse`. '
  'See ADR-017 for the two-axis taxonomy.';

-- ────────────────────────────────────────────────────────────────────────────
-- 6. POST-state assertion
-- ────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
  v_cc_distinct          INT;
  v_view_distinct        INT;
  v_cc_invalid           INT;
BEGIN
  SELECT count(DISTINCT channel) INTO v_cc_distinct
    FROM canonical_customer
   WHERE channel IS NOT NULL;

  SELECT count(DISTINCT channel) INTO v_view_distinct
    FROM combined_data_enriched
   WHERE channel <> '';

  SELECT count(*) INTO v_cc_invalid
    FROM canonical_customer
   WHERE channel IS NOT NULL
     AND channel NOT IN ('ALM','DIRECT','HOFFICE','HYBRID','OFF PREMISE','ON PREMISE','WHOLESALE');

  RAISE NOTICE 'B11 POST: canonical_customer.channel distinct=% (target ≤7), combined_data.channel distinct=% (target =6), invalid=%',
    v_cc_distinct, v_view_distinct, v_cc_invalid;

  IF v_cc_distinct > 7 THEN
    RAISE EXCEPTION 'B11 POST AC2: canonical_customer.channel distinct=% > 7 — canonicalisation incomplete', v_cc_distinct;
  END IF;

  IF v_cc_invalid > 0 THEN
    RAISE EXCEPTION 'B11 POST: % canonical_customer rows have channel outside enum — CHECK should have rejected them', v_cc_invalid;
  END IF;

  IF v_view_distinct > 6 THEN
    RAISE EXCEPTION 'B11 POST AC1: combined_data_enriched.channel distinct=% > 6 — view CASE leaks raw values', v_view_distinct;
  END IF;
END;
$$;

-- ────────────────────────────────────────────────────────────────────────────
-- 7. Record migration
-- ────────────────────────────────────────────────────────────────────────────
INSERT INTO schema_migrations (version, source)
VALUES ('092_b11_channel_canonical', 'live-apply')
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ════════════════════════════════════════════════════════════════════════════
-- ROLLBACK / DOWN-MIGRATION RECIPE (manual; not auto-run)
-- ════════════════════════════════════════════════════════════════════════════
-- Restore canonical_customer.channel to pre-B11 state (mapping CASE undone):
--   BEGIN;
--   UPDATE canonical_customer cc
--      SET channel = s.channel_pre_b11
--     FROM channel_canonical_pre_b11_snapshot s
--    WHERE s.canonical_customer_id = cc.id;
--   ALTER TABLE canonical_customer DROP CONSTRAINT IF EXISTS canonical_customer_channel_check;
--   -- Restore prior view from schema/068:
--   \i schema/068_bug147_combined_data_enriched_refactor.sql
--   DELETE FROM schema_migrations WHERE version = '092_b11_channel_canonical';
--   COMMIT;
-- (channel_canonical_pre_b11_snapshot is left in place after rollback for forensics.)
