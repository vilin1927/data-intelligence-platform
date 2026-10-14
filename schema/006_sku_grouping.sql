-- FIX-06: SKU grouping for non-vintage rollups
-- The owner: "An SKU really IS the vintage." Multiple vintage SKUs belong to one SKU group.
-- e.g., "Lock & Key Chardonnay 2017", "2018", "2019" → group "Lock & Key Chardonnay"

-- Add sku_group column (self-referencing label for grouping)
ALTER TABLE sku ADD COLUMN IF NOT EXISTS sku_group VARCHAR(255);

-- Populate sku_group by stripping vintage year from item_description
-- Pattern: remove trailing 4-digit year (2014-2029) and optional quotes/spaces
UPDATE sku
SET sku_group = TRIM(
  REGEXP_REPLACE(
    REGEXP_REPLACE(item_description, '\s*''?\d{2,4}$', ''),  -- strip trailing year like '17 or 2017
    '\s+\d{4}ML$', 'ML', 'i'  -- preserve 750ML but remove year before it
  )
)
WHERE sku_group IS NULL;

-- Also strip common size suffixes for cleaner grouping
UPDATE sku
SET sku_group = TRIM(REGEXP_REPLACE(sku_group, '\s*\d+ML$', '', 'i'))
WHERE sku_group ~ '\d+ML$';

-- Report: show groups with multiple vintages
SELECT sku_group, count(*) AS vintage_count,
       string_agg(DISTINCT vintage::text, ', ' ORDER BY vintage::text) AS vintages
FROM sku
WHERE vintage IS NOT NULL AND sku_group IS NOT NULL
GROUP BY sku_group
HAVING count(*) > 1
ORDER BY count(*) DESC
LIMIT 20;
