-- Manual refresh of staging_vinsight_region_lookup wrapper.
-- Run if sync_vinsight_cogs.py logged "Wrapper refresh FAILED" or if
-- combined_data_enriched.region cells look stale.
BEGIN;
TRUNCATE TABLE staging_vinsight_region_lookup;
INSERT INTO staging_vinsight_region_lookup
  (stock_item_code, product_categories, parsed_region, is_active)
SELECT DISTINCT ON (raw_data->>'StockItemCode')
  raw_data->>'StockItemCode',
  raw_data->>'ProductCategories',
  SUBSTRING(raw_data->>'ProductCategories' FROM '(?i)region:([^;]+)'),
  raw_data->>'IsActive'
FROM staging_vinsight_stock_items
WHERE raw_data->>'StockItemCode' IS NOT NULL
  AND raw_data->>'ProductCategories' IS NOT NULL
ORDER BY raw_data->>'StockItemCode',
         raw_data->>'IsActive' DESC NULLS LAST;
COMMIT;
SELECT COUNT(*) AS wrapper_rows FROM staging_vinsight_region_lookup;
