-- =============================================================================
-- 025_sales_transaction_fk_indexes.sql — BUG-16 (DB-01): FK indexes on fact table
-- =============================================================================
-- Context: 2026-04-11 CTO audit CRITICAL #3. sales_transaction is the central
-- fact table (~119K rows today) and currently has only 4 indexes:
--   * PK transaction_id
--   * idx_sales_transaction_sale_date (sale_date)
--   * idx_sales_transaction_period    (period)
--   * idx_st_economic_cogs            (economic_cogs_per_unit) WHERE NOT NULL
--
-- Postgres does NOT auto-create indexes on foreign-key columns. Every query that
-- joins or filters by sku_id / customer_id / channel_id / territory_id /
-- source_system / warehouse therefore falls back to a Seq Scan + Filter,
-- which EXPLAIN ANALYZE on /api/margins showed as 948K rows-removed-by-filter,
-- ~71ms and 41,176 buffer hits per SKU. At 2x data volume that becomes ~150ms
-- per SKU and ~700ms at 10x — the /margin page already the owner's #1 surface would
-- start to feel broken.
--
-- Fix: add plain B-tree indexes on all six FK / discriminator columns.
-- Safe, forward-only, idempotent. No data rewrite; Postgres builds the indexes
-- in place. Run during a low-traffic window on live DB.
--
-- Run as: psql -U moppity -d moppity_db -f schema/025_sales_transaction_fk_indexes.sql
--
-- Related: BUG-21 (DASH-02) rewrites the /api/margins LATERAL joins to a single
-- aggregated subquery on the same commit series. These indexes are a prerequisite
-- for the rewrite to hit Index Scans instead of Seq Scans.
-- =============================================================================

-- 1. customer_id — used by /api/sales, /api/margins, /api/customers
CREATE INDEX IF NOT EXISTS idx_st_customer_id
  ON sales_transaction (customer_id);

-- 2. sku_id — used by every margin / velocity / composition query
CREATE INDEX IF NOT EXISTS idx_st_sku_id
  ON sales_transaction (sku_id);

-- 3. warehouse — used by vintage COGS attribution (schema/016) and channel split
CREATE INDEX IF NOT EXISTS idx_st_warehouse
  ON sales_transaction (warehouse);

-- 4. source_system — used by ETL idempotency / reconciliation queries
CREATE INDEX IF NOT EXISTS idx_st_source_system
  ON sales_transaction (source_system);

-- 5. territory_id — used by territory roll-ups and filter dropdowns
CREATE INDEX IF NOT EXISTS idx_st_territory_id
  ON sales_transaction (territory_id);

-- 6. channel_id — used by /api/margins channel revenue breakdown (GROUP BY)
CREATE INDEX IF NOT EXISTS idx_st_channel_id
  ON sales_transaction (channel_id);

-- =============================================================================
-- Verification (run manually after apply):
-- =============================================================================
-- \d sales_transaction
--   expect 10 indexes total: pk + 3 existing + 6 new
--
-- EXPLAIN (ANALYZE, BUFFERS)
-- SELECT SUM(net_revenue) FROM sales_transaction
-- WHERE sku_id = 42 AND sale_date >= CURRENT_DATE - interval '12 months';
--   expect: Index Scan using idx_st_sku_id (not Seq Scan)
--   expect: buffers shared hit drops by >90% vs pre-index baseline
-- =============================================================================
