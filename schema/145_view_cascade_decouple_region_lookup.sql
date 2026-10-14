-- ════════════════════════════════════════════════════════════════════════════
-- schema/145_view_cascade_decouple_region_lookup.sql
-- BUG-VIEW-CASCADE-DROP — Decouple combined_data_enriched view from
-- staging_vinsight_stock_items physical swap. Introduce wrapper refresh-table
-- staging_vinsight_region_lookup so the nightly ETL CASCADE drop on
-- staging_vinsight_stock_items_old does NOT silently destroy the view.
-- ════════════════════════════════════════════════════════════════════════════
-- Date:    2026-05-10
-- Ticket:  BUG-VIEW-CASCADE-DROP
-- Companion: schema/146_combined_data_enriched_via_region_wrapper.sql
-- Root cause:
--   etl/sync_vinsight_cogs.py:_insert_staging (lines 661-669) shadow-swaps
--   the staging table: CREATE shadow, INSERT rows, RENAME live→old,
--   RENAME shadow→live, DROP old CASCADE. The trailing CASCADE walks
--   pg_depend edges and drops every dependent catalog object — including
--   combined_data_enriched which JOINs staging_vinsight_stock_items at
--   schema/144 lines 333-339 for the Vinsight ProductCategories region
--   regex. Result: view silently disappears every night, restored only
--   by manual reapply of schema/144.
--
-- Fix layer in this migration:
--   Build a physical refresh-table named staging_vinsight_region_lookup that
--   mirrors the columns the view needs (stock_item_code, parsed_region,
--   is_active, product_categories). The table holds zero pg_depend edges
--   to staging_vinsight_stock_items; the relationship is purely runtime via
--   INSERT executed by ETL after each shadow-swap. schema/146 then rebinds
--   combined_data_enriched to JOIN this wrapper instead of staging directly.
--
--   Why a refresh-table and NOT a MATERIALIZED VIEW:
--   A MATERIALIZED VIEW preserves its SELECT body in pg_rewrite and
--   registers pg_depend edges to every base table it queries — the cascade
--   drop on staging_vinsight_stock_items would still drop the matview,
--   defeating the purpose. A flat heap table populated by ETL has zero
--   such edges. Refresh cost is trivial (~947 rows, <1s).
--
-- Resolution A (active-prefer semantics):
--   Wrapper INSERT uses DISTINCT ON (stock_item_code) ORDER BY
--   stock_item_code, is_active DESC NULLS LAST to preserve schema/144's
--   LATERAL ORDER BY is_active DESC LIMIT 1 per-StockItemCode behavior.
--   Without this, ON CONFLICT DO NOTHING would pick a non-deterministic
--   winner and could drop the active-IsActive variant when duplicates exist.
--
-- Reversibility:
--   DROP TABLE staging_vinsight_region_lookup CASCADE; DELETE FROM
--   schema_migrations WHERE version='145_view_cascade_decouple_region_lookup';
--
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ────────────────────────────────────────────────────────────────────────────
-- PRE asserts.
-- ────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
  v_staging_exists boolean;
  v_staging_rows   bigint;
  v_wrapper_exists boolean;
BEGIN
  v_staging_exists := to_regclass('public.staging_vinsight_stock_items') IS NOT NULL;
  IF NOT v_staging_exists THEN
    RAISE EXCEPTION
      'PRE assert FAILED: staging_vinsight_stock_items missing — apply Vinsight sync first';
  END IF;

  EXECUTE 'SELECT COUNT(*) FROM staging_vinsight_stock_items' INTO v_staging_rows;
  IF v_staging_rows < 100 THEN
    RAISE EXCEPTION
      'PRE assert FAILED: staging_vinsight_stock_items rows=% < 100 floor', v_staging_rows;
  END IF;
  RAISE NOTICE 'PRE assert OK: staging_vinsight_stock_items rows=%', v_staging_rows;

  v_wrapper_exists := to_regclass('public.staging_vinsight_region_lookup') IS NOT NULL;
  RAISE NOTICE 'PRE state: staging_vinsight_region_lookup exists=% (idempotent rebuild)', v_wrapper_exists;
END$$;

-- ────────────────────────────────────────────────────────────────────────────
-- Idempotent rebuild.
-- ────────────────────────────────────────────────────────────────────────────
DROP TABLE IF EXISTS staging_vinsight_region_lookup CASCADE;

CREATE TABLE staging_vinsight_region_lookup (
  stock_item_code     TEXT PRIMARY KEY,
  product_categories  TEXT,
  parsed_region       TEXT,
  is_active           TEXT,
  refreshed_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE staging_vinsight_region_lookup IS
  'Wrapper refresh-table for combined_data_enriched region COALESCE chain. '
  'Mirrors per-stock-item region parse from staging_vinsight_stock_items. '
  'Refreshed by etl/sync_vinsight_cogs.py after each shadow-swap commit. '
  'Decouples view from staging CASCADE drop (BUG-VIEW-CASCADE-DROP). '
  'DO NOT add pg_depend edges to staging_vinsight_stock_items. '
  'Refresh by TRUNCATE + DISTINCT-ON-INSERT only.';

-- Initial seed via Resolution A (preserves schema/144 active-prefer semantics).
INSERT INTO staging_vinsight_region_lookup
  (stock_item_code, product_categories, parsed_region, is_active)
SELECT DISTINCT ON (raw_data->>'StockItemCode')
  raw_data->>'StockItemCode'                                                 AS stock_item_code,
  raw_data->>'ProductCategories'                                             AS product_categories,
  SUBSTRING(raw_data->>'ProductCategories' FROM '(?i)region:([^;]+)')        AS parsed_region,
  raw_data->>'IsActive'                                                      AS is_active
FROM staging_vinsight_stock_items
WHERE raw_data->>'StockItemCode' IS NOT NULL
  AND raw_data->>'ProductCategories' IS NOT NULL
ORDER BY raw_data->>'StockItemCode',
         raw_data->>'IsActive' DESC NULLS LAST;

CREATE INDEX idx_svrl_is_active
  ON staging_vinsight_region_lookup (is_active DESC NULLS LAST);

INSERT INTO schema_migrations (version, applied_at, source)
VALUES ('145_view_cascade_decouple_region_lookup', NOW(), 'live-apply')
ON CONFLICT (version) DO NOTHING;

-- ────────────────────────────────────────────────────────────────────────────
-- POST asserts.
-- ────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
  v_wrapper_rows bigint;
  v_staging_distinct bigint;
  v_has_hilltops bigint;
  v_has_tumba bigint;
BEGIN
  SELECT COUNT(*) INTO v_wrapper_rows FROM staging_vinsight_region_lookup;
  IF v_wrapper_rows < 50 THEN
    RAISE EXCEPTION 'POST assert FAILED: wrapper rows=% < 50', v_wrapper_rows;
  END IF;

  SELECT COUNT(DISTINCT raw_data->>'StockItemCode') INTO v_staging_distinct
    FROM staging_vinsight_stock_items
    WHERE raw_data->>'StockItemCode' IS NOT NULL
      AND raw_data->>'ProductCategories' IS NOT NULL;
  IF v_wrapper_rows > v_staging_distinct THEN
    RAISE EXCEPTION
      'POST assert FAILED: wrapper rows=% > staging distinct codes=%',
      v_wrapper_rows, v_staging_distinct;
  END IF;
  RAISE NOTICE 'POST assert OK: wrapper=% rows from %distinct staging codes',
    v_wrapper_rows, v_staging_distinct;

  SELECT COUNT(*) INTO v_has_hilltops FROM staging_vinsight_region_lookup
    WHERE LOWER(parsed_region) LIKE '%hilltop%';
  SELECT COUNT(*) INTO v_has_tumba FROM staging_vinsight_region_lookup
    WHERE LOWER(parsed_region) IN ('tumbarumba', 'tumba');
  RAISE NOTICE 'POST sample: parsed_region Hilltops=%, Tumbarumba=%',
    v_has_hilltops, v_has_tumba;

  -- Confirm zero pg_depend edge from wrapper to staging.
  IF EXISTS (
    SELECT 1 FROM pg_depend
    WHERE objid = 'public.staging_vinsight_region_lookup'::regclass
      AND refobjid = 'public.staging_vinsight_stock_items'::regclass
  ) THEN
    RAISE EXCEPTION 'POST assert FAILED: wrapper has pg_depend to staging — fix did not decouple';
  END IF;
  RAISE NOTICE 'POST assert OK: zero pg_depend edge wrapper -> staging';
END$$;

COMMIT;
