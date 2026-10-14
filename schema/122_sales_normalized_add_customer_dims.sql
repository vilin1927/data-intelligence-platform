-- schema/122_sales_normalized_add_customer_dims.sql
-- JC-345-RPT: extend sales_transaction_normalized with customer_suburb +
-- customer_territory_group so /sales filters can reuse the existing warehouse
-- pattern (single-column WHERE, no per-query JOIN proliferation).
--
-- Pre-flight verified 2026-04-30:
--   - relkind='v' (regular VIEW, no REFRESH cost on REPLACE)
--   - 0 dependent views/matviews — safe to add columns at end
--   - direct path resolves 121015 / 121016 sales rows (99.999% coverage)
--   - alias-fallback adds zero extra coverage → drop the BUG-06 fuzzy JOIN
--   - idx_customer_canonical_customer_id exists → JOIN cost negligible
--
-- Forward-only. CREATE OR REPLACE VIEW. Non-destructive.

BEGIN;

CREATE OR REPLACE VIEW sales_transaction_normalized AS
SELECT
  st.transaction_id,
  st.sku_id,
  st.customer_id,
  st.rep_id,
  st.territory_id,
  st.channel_id,
  st.sale_date,
  st.period,
  st.quantity,
  st.unit_price,
  st.discount_amount,
  st.rebate_amount,
  st.wholesale_fee,
  st.net_revenue,
  st.source_system,
  st.source_ref,
  st.created_at,
  st.economic_cogs_per_unit,
  st.economic_cogs_total,
  st.gross_revenue,
  st.warehouse,
  st.economic_cogs_lock_date,
  st.content_hash,
  st.stock_unit,
  CASE st.stock_unit
    WHEN 'bottle'::text THEN st.quantity::numeric / COALESCE(sk.units_per_case, 1)::numeric
    ELSE st.quantity::numeric
  END AS quantity_cases,
  sk.units_per_case AS sku_units_per_case,
  cc.suburb         AS customer_suburb,
  cc.territory_group AS customer_territory_group
FROM sales_transaction st
  LEFT JOIN sku sk
    ON sk.sku_id = st.sku_id
  LEFT JOIN customer cu
    ON cu.customer_id = st.customer_id
  LEFT JOIN canonical_customer cc
    ON cc.id = cu.canonical_customer_id;

COMMENT ON VIEW sales_transaction_normalized IS
  'Schema/073 (BUG-118 case-normalized qty) + schema/122 (JC-345 customer dims). '
  'Adds customer_suburb + customer_territory_group from canonical_customer for '
  'filter parity with the warehouse pattern in /api/sales. LEFT JOIN chain so '
  'the 1 orphaned customer_id in sales_transaction does not drop from the view.';

COMMENT ON COLUMN sales_transaction_normalized.customer_suburb IS
  'JC-345-RPT — canonical_customer.suburb resolved via customer.canonical_customer_id. '
  'NULL when sales_transaction.customer_id has no customer match (1 row) or the '
  'customer has no canonical mapping (~0 rows). Use directly in WHERE clauses '
  '(case-sensitive equality match the existing warehouse filter pattern).';

COMMENT ON COLUMN sales_transaction_normalized.customer_territory_group IS
  'JC-345-RPT — canonical_customer.territory_group. ~10 distinct values today: '
  'NSW/VIC/ACT/QLD/WA/SA + Head Office / Young & Rashleigh / Majors & Wine Clubs. '
  'NOT a clean state column — see JC-346 (deferred to P1.5) for state rollup.';

INSERT INTO schema_migrations (version, source)
VALUES ('122_sales_normalized_add_customer_dims', 'live-apply')
ON CONFLICT (version) DO NOTHING;

-- POST 1: row count preserved (LEFT JOINs must not multiply or drop)
DO $$
DECLARE
  view_rows  int;
  table_rows int;
BEGIN
  SELECT COUNT(*) INTO view_rows  FROM sales_transaction_normalized;
  SELECT COUNT(*) INTO table_rows FROM sales_transaction;
  IF view_rows <> table_rows THEN
    RAISE EXCEPTION 'Row count mismatch: view=%, table=%', view_rows, table_rows;
  END IF;
  RAISE NOTICE 'POST 1 OK — view rows preserved: %', view_rows;
END $$;

-- POST 2: new columns are populated above pre-flight floor (>=100k rows each)
DO $$
DECLARE
  with_suburb int;
  with_tg     int;
BEGIN
  SELECT COUNT(*) INTO with_suburb FROM sales_transaction_normalized WHERE customer_suburb IS NOT NULL;
  SELECT COUNT(*) INTO with_tg     FROM sales_transaction_normalized WHERE customer_territory_group IS NOT NULL;
  IF with_suburb < 100000 THEN
    RAISE EXCEPTION 'customer_suburb coverage too low: % (expected >=100000)', with_suburb;
  END IF;
  IF with_tg < 100000 THEN
    RAISE EXCEPTION 'customer_territory_group coverage too low: % (expected >=100000)', with_tg;
  END IF;
  RAISE NOTICE 'POST 2 OK — suburb=% tg=% rows populated', with_suburb, with_tg;
END $$;

-- POST 3: distinct values in expected ranges (sanity vs schema audit)
DO $$
DECLARE
  d_suburb int;
  d_tg     int;
BEGIN
  SELECT COUNT(DISTINCT customer_suburb)         INTO d_suburb FROM sales_transaction_normalized WHERE customer_suburb IS NOT NULL;
  SELECT COUNT(DISTINCT customer_territory_group) INTO d_tg     FROM sales_transaction_normalized WHERE customer_territory_group IS NOT NULL;
  RAISE NOTICE 'POST 3 — distinct suburbs=%, distinct territory_groups=%', d_suburb, d_tg;
  IF d_tg > 20 THEN
    RAISE EXCEPTION 'territory_group cardinality unexpectedly high: % (expected ~10)', d_tg;
  END IF;
END $$;

COMMIT;
