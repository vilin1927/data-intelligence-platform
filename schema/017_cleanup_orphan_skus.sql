-- =============================================================================
-- Moppity Vineyards — Clean Orphaned SKU Rows (017_cleanup_orphan_skus.sql)
-- =============================================================================
-- Version:   1.0
-- Created:   2026-04-01
-- Author:    Vladimir (Autoflux)
-- Task:      RECON-04d
--
-- Problem: 1,711 SKUs but only 97 have sales. The rest are duplicates from
-- broken ETL runs, discontinued brands, label/sticker entries, etc.
-- The owner sees 1,168 "unmapped" codes on Admin page — alarming.
--
-- Strategy: Re-point dependent tables to active SKUs via canonical_sku_id
-- bridge, then delete orphans. Full transaction — ROLLBACK if anything fails.
-- =============================================================================

BEGIN;

-- Step 1: Backup
CREATE TABLE sku_backup_20260401 AS SELECT * FROM sku;

-- Temp: active SKU IDs (97 SKUs that have sales)
CREATE TEMP TABLE _active_skus AS
SELECT DISTINCT sku_id FROM sales_transaction WHERE sku_id IS NOT NULL;
CREATE INDEX ON _active_skus (sku_id);

-- Step 2: Re-point sku_code_map to active SKUs via canonical_sku_id
-- For orphan entries that share a canonical_sku with an active SKU, re-point
UPDATE sku_code_map m
SET sku_id = (
  SELECT s2.sku_id FROM sku s2
  JOIN _active_skus a ON a.sku_id = s2.sku_id
  WHERE s2.canonical_sku_id = (SELECT canonical_sku_id FROM sku WHERE sku_id = m.sku_id)
  LIMIT 1
)
WHERE m.sku_id NOT IN (SELECT sku_id FROM _active_skus)
  AND (SELECT canonical_sku_id FROM sku WHERE sku_id = m.sku_id) IS NOT NULL
  AND EXISTS (
    SELECT 1 FROM sku s2
    JOIN _active_skus a ON a.sku_id = s2.sku_id
    WHERE s2.canonical_sku_id = (SELECT canonical_sku_id FROM sku WHERE sku_id = m.sku_id)
  );

-- Delete sku_code_map entries that couldn't be re-pointed (no canonical match)
DELETE FROM sku_code_map
WHERE sku_id NOT IN (SELECT sku_id FROM _active_skus);

-- Step 3: Re-point packaging_operation to active SKUs
UPDATE packaging_operation po
SET sku_id = (
  SELECT s2.sku_id FROM sku s2
  JOIN _active_skus a ON a.sku_id = s2.sku_id
  WHERE s2.canonical_sku_id = (SELECT canonical_sku_id FROM sku WHERE sku_id = po.sku_id)
  LIMIT 1
)
WHERE po.sku_id NOT IN (SELECT sku_id FROM _active_skus)
  AND po.sku_id IS NOT NULL
  AND (SELECT canonical_sku_id FROM sku WHERE sku_id = po.sku_id) IS NOT NULL
  AND EXISTS (
    SELECT 1 FROM sku s2
    JOIN _active_skus a ON a.sku_id = s2.sku_id
    WHERE s2.canonical_sku_id = (SELECT canonical_sku_id FROM sku WHERE sku_id = po.sku_id)
  );

-- Nullify packaging_operation entries that couldn't be re-pointed
UPDATE packaging_operation SET sku_id = NULL
WHERE sku_id IS NOT NULL
  AND sku_id NOT IN (SELECT sku_id FROM _active_skus);

-- Step 4: Clean sku_wine_product_map
-- Has UNIQUE on sku_id — can't re-point without conflicts.
-- Just delete all orphan entries (mapping table, can be rebuilt).
DELETE FROM sku_wine_product_map
WHERE sku_id NOT IN (SELECT sku_id FROM _active_skus);

-- Step 5: Delete orphan SKUs (no sales)
DELETE FROM sku
WHERE sku_id NOT IN (SELECT sku_id FROM _active_skus);

COMMIT;
