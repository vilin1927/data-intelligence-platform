-- 014_ai_readonly_role.sql
-- Creates a read-only Postgres role for AI chat queries.
-- SELECT-only on specific tables, 5-second statement timeout.

DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'moppity_readonly') THEN
    CREATE ROLE moppity_readonly LOGIN PASSWORD 'change-me';
  END IF;
END
$$;

-- Revoke everything first, then grant SELECT-only
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM moppity_readonly;

GRANT CONNECT ON DATABASE moppity_db TO moppity_readonly;
GRANT USAGE ON SCHEMA public TO moppity_readonly;

-- Whitelisted tables for AI queries
GRANT SELECT ON TABLE
  sku,
  sales_transaction,
  customer,
  canonical_sku,
  wine_range,
  grape_price_rule,
  staging_vinsight_stock_items,
  territory,
  representative,
  vessel,
  channel,
  wine_batch,
  packaging_operation,
  packaging_vessel,
  sku_code_map,
  canonical_customer,
  canonical_territory,
  etl_run_log
TO moppity_readonly;

-- Grant on tables that may or may not exist yet
DO $$ BEGIN
  EXECUTE 'GRANT SELECT ON TABLE sale_vintage_attribution TO moppity_readonly';
EXCEPTION WHEN undefined_table THEN NULL;
END $$;
DO $$ BEGIN
  EXECUTE 'GRANT SELECT ON TABLE sku_wine_product_map TO moppity_readonly';
EXCEPTION WHEN undefined_table THEN NULL;
END $$;

-- 5-second statement timeout to prevent runaway queries
ALTER ROLE moppity_readonly SET statement_timeout = '5000';
