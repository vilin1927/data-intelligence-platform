-- 011_data_quality.sql — M3-02: Fix regions, varietals, typos, territories
-- Also adds canonical reference tables to prevent future data drift.
--
-- Run as: sudo -u postgres psql -d moppity_db -f schema/011_data_quality.sql

BEGIN;

-- ════════════════════════════════════════════════════════════════════════════
-- 1. CANONICAL REFERENCE TABLES
-- ════════════════════════════════════════════════════════════════════════════

-- 1a. Region reference — the only allowed wine regions
CREATE TABLE IF NOT EXISTS region_ref (
    region_name VARCHAR(100) PRIMARY KEY
);

INSERT INTO region_ref (region_name) VALUES
    ('Hilltops'),
    ('Tumbarumba'),
    ('Canberra'),
    ('Young'),
    ('Barossa Valley'),
    ('Hunter Valley'),
    ('Tasmania')
ON CONFLICT DO NOTHING;

-- 1b. Variety reference — canonical varietal names
CREATE TABLE IF NOT EXISTS variety_ref (
    variety_name VARCHAR(100) PRIMARY KEY
);

INSERT INTO variety_ref (variety_name) VALUES
    ('Albarino'),
    ('Cabernet'),
    ('Cabernet Merlot'),
    ('Cabernet Sauvignon'),
    ('Chardonnay'),
    ('Gamay'),
    ('Gewurztraminer'),
    ('Grenache'),
    ('Grüner Veltliner'),
    ('Merlot'),
    ('Moscato'),
    ('Nebbiolo'),
    ('Pétillant Naturel'),
    ('Pinot Grigio'),
    ('Pinot Noir'),
    ('Prosecco'),
    ('Riesling'),
    ('Rosé'),
    ('Sangiovese'),
    ('Sauvignon Blanc'),
    ('Semillon'),
    ('Semillon Sauvignon Blanc'),
    ('Shiraz'),
    ('Shiraz Grenache Mourvèdre'),
    ('Sparkling'),
    ('Syrah'),
    ('Tempranillo'),
    ('Vermentino'),
    ('White Blend')
ON CONFLICT DO NOTHING;

-- ════════════════════════════════════════════════════════════════════════════
-- 2. FIX WINE RANGE TYPOS/DUPLICATES
-- ════════════════════════════════════════════════════════════════════════════

-- 2a. "OPPABELLA PROCELLA" → merge into "COPPABELLA PROCELLA"
DO $$
DECLARE
    bad_id  INT;
    good_id INT;
BEGIN
    SELECT range_id INTO bad_id  FROM wine_range WHERE range_name = 'OPPABELLA PROCELLA';
    SELECT range_id INTO good_id FROM wine_range WHERE range_name = 'COPPABELLA PROCELLA';
    IF bad_id IS NOT NULL AND good_id IS NOT NULL THEN
        UPDATE sku SET range_id = good_id WHERE range_id = bad_id;
        DELETE FROM wine_range WHERE range_id = bad_id;
        RAISE NOTICE 'Merged OPPABELLA PROCELLA → COPPABELLA PROCELLA';
    END IF;
END $$;

-- 2b. "Lock & Key" (mixed case) → merge into "LOCK & KEY"
DO $$
DECLARE
    bad_id  INT;
    good_id INT;
BEGIN
    SELECT range_id INTO bad_id  FROM wine_range WHERE range_name = 'Lock & Key';
    SELECT range_id INTO good_id FROM wine_range WHERE range_name = 'LOCK & KEY';
    IF bad_id IS NOT NULL AND good_id IS NOT NULL THEN
        UPDATE sku SET range_id = good_id WHERE range_id = bad_id;
        DELETE FROM wine_range WHERE range_id = bad_id;
        RAISE NOTICE 'Merged Lock & Key → LOCK & KEY';
    END IF;
END $$;

-- ════════════════════════════════════════════════════════════════════════════
-- 3. FIX SKU REGIONS
-- ════════════════════════════════════════════════════════════════════════════

-- 3a. "Canberra" in description → region = Canberra (currently wrongly Hilltops or NULL)
UPDATE sku SET region = 'Canberra'
WHERE item_description ILIKE '%canberra%'
  AND (region IS NULL OR region != 'Canberra');

-- 3b. Coppabella/Copabella → always Tumbarumba
UPDATE sku SET region = 'Tumbarumba'
WHERE (item_description ILIKE '%coppabella%' OR item_description ILIKE '%copabella%')
  AND (region IS NULL OR region != 'Tumbarumba');

-- 3c. Backfill NULL region from wine_batch via packaging chain
--     sku → packaging_operation → packaging_vessel → vessel → wine_batch.region
UPDATE sku s SET region = batch_region.region
FROM (
    SELECT DISTINCT ON (po.sku_id) po.sku_id, wb.region
    FROM packaging_operation po
    JOIN packaging_vessel pv ON pv.packaging_operation_id = po.id
    JOIN vessel v ON v.id = pv.vessel_id
    JOIN wine_batch wb ON wb.id = v.wine_batch_id
    WHERE po.sku_id IS NOT NULL AND wb.region IS NOT NULL
    ORDER BY po.sku_id, pv.volume_litres DESC  -- largest component determines region
) batch_region
WHERE s.sku_id = batch_region.sku_id
  AND s.region IS NULL;

-- 3d. Remaining NULL regions: default by brand
UPDATE sku SET region = 'Tumbarumba'
WHERE region IS NULL
  AND (item_description ILIKE '%sirius%' OR item_description ILIKE '%crest %');

UPDATE sku SET region = 'Hilltops'
WHERE region IS NULL
  AND (item_description ILIKE '%moppity%' OR item_description ILIKE '%lock%key%'
       OR item_description ILIKE '%twelve signs%' OR item_description ILIKE '%cato %'
       OR item_description ILIKE '%estate %' OR item_description ILIKE '%reserve %'
       OR item_description ILIKE '%block %' OR item_description ILIKE '%atrius%');

-- ════════════════════════════════════════════════════════════════════════════
-- 4. FIX VARIETIES
-- ════════════════════════════════════════════════════════════════════════════

-- 4a. Prosecco mislabeled as Rosé
UPDATE sku SET variety = 'Prosecco'
WHERE item_description ILIKE '%prosecco%'
  AND variety != 'Prosecco';

-- 4b. "Tumbarumba Sparkling" → "Sparkling" (region is separate from variety)
UPDATE sku SET variety = 'Sparkling'
WHERE variety = 'Tumbarumba Sparkling';

-- 4c. "Rose" (no accent) → "Rosé"
UPDATE sku SET variety = 'Rosé'
WHERE variety = 'Rose';

-- 4d. Fill remaining NULL varieties for actual wines
UPDATE sku SET variety = 'Cabernet Merlot'
WHERE variety IS NULL AND (item_description ILIKE '%cab%mer%');

UPDATE sku SET variety = 'Gamay'
WHERE variety IS NULL AND item_description ILIKE '%gamay%';

UPDATE sku SET variety = 'Sparkling'
WHERE variety IS NULL AND (item_description ILIKE '%sparkling%' OR item_description ILIKE '%brut%'
                           OR item_description ILIKE '%cuvee%' OR item_description ILIKE '%spk %');

UPDATE sku SET variety = 'Shiraz'
WHERE variety IS NULL AND item_description ILIKE '%shiraz%';

UPDATE sku SET variety = 'Sangiovese'
WHERE variety IS NULL AND item_description ILIKE '%sangiovese%';

UPDATE sku SET variety = 'Sauvignon Blanc'
WHERE variety IS NULL AND (item_description ILIKE '%sauv%blanc%' OR item_description ILIKE '% ssb %'
                           OR item_description ILIKE '% ssb%');

UPDATE sku SET variety = 'Chardonnay'
WHERE variety IS NULL AND item_description ILIKE '%chard%';

UPDATE sku SET variety = 'Pinot Noir'
WHERE variety IS NULL AND item_description ILIKE '%pinot%noir%';

UPDATE sku SET variety = 'Rosé'
WHERE variety IS NULL AND item_description ILIKE '%rose%';

-- ════════════════════════════════════════════════════════════════════════════
-- 5. NORMALIZE TERRITORIES — deduplicate case variants
-- ════════════════════════════════════════════════════════════════════════════

-- Strategy: for each set of case duplicates, keep the one with sales data,
-- remap all references, then delete the empties.

-- Build a mapping: canonical name → all duplicate IDs
-- Canonical = the title-case variant (the one with actual sales data)

CREATE TEMP TABLE territory_canonical AS
WITH ranked AS (
    SELECT
        t.territory_id,
        LOWER(TRIM(t.territory_name)) as lower_name,
        COUNT(st.transaction_id) as sale_count,
        ROW_NUMBER() OVER (
            PARTITION BY LOWER(TRIM(t.territory_name))
            ORDER BY COUNT(st.transaction_id) DESC, t.territory_id
        ) as rn
    FROM territory t
    LEFT JOIN sales_transaction st ON st.territory_id = t.territory_id
    GROUP BY t.territory_id, LOWER(TRIM(t.territory_name))
)
SELECT lower_name, territory_id as canonical_id
FROM ranked WHERE rn = 1;

-- Remap sales_transaction references
UPDATE sales_transaction st
SET territory_id = tc.canonical_id
FROM territory t
JOIN territory_canonical tc ON LOWER(TRIM(t.territory_name)) = tc.lower_name
WHERE st.territory_id = t.territory_id
  AND t.territory_id != tc.canonical_id;

-- Remap rep_territory references (delete dupes first to avoid PK conflict)
DELETE FROM rep_territory rt
WHERE EXISTS (
    SELECT 1 FROM territory t
    JOIN territory_canonical tc ON LOWER(TRIM(t.territory_name)) = tc.lower_name
    WHERE rt.territory_id = t.territory_id
      AND t.territory_id != tc.canonical_id
      AND EXISTS (
          SELECT 1 FROM rep_territory rt2
          WHERE rt2.rep_id = rt.rep_id AND rt2.territory_id = tc.canonical_id
      )
);

UPDATE rep_territory rt
SET territory_id = tc.canonical_id
FROM territory t
JOIN territory_canonical tc ON LOWER(TRIM(t.territory_name)) = tc.lower_name
WHERE rt.territory_id = t.territory_id
  AND t.territory_id != tc.canonical_id;

-- Remap customer references
UPDATE customer cu
SET territory_id = tc.canonical_id
FROM territory t
JOIN territory_canonical tc ON LOWER(TRIM(t.territory_name)) = tc.lower_name
WHERE cu.territory_id = t.territory_id
  AND t.territory_id != tc.canonical_id;

-- Remap representative references
UPDATE representative r
SET territory_id = tc.canonical_id
FROM territory t
JOIN territory_canonical tc ON LOWER(TRIM(t.territory_name)) = tc.lower_name
WHERE r.territory_id = t.territory_id
  AND t.territory_id != tc.canonical_id;

-- Delete duplicate territories (the non-canonical ones)
DELETE FROM territory t
WHERE t.territory_id NOT IN (SELECT canonical_id FROM territory_canonical);

DROP TABLE territory_canonical;

-- Add unique constraint to prevent future duplicates
-- (uses a case-insensitive index)
CREATE UNIQUE INDEX IF NOT EXISTS idx_territory_name_lower
ON territory (LOWER(TRIM(territory_name)));

-- ════════════════════════════════════════════════════════════════════════════
-- 6. REPORT — verify results
-- ════════════════════════════════════════════════════════════════════════════

\echo '=== Regions ==='
SELECT region, COUNT(*) FROM sku WHERE region IS NOT NULL GROUP BY region ORDER BY COUNT(*) DESC;
SELECT COUNT(*) as still_null_region FROM sku WHERE region IS NULL;

\echo '=== Varieties ==='
SELECT variety, COUNT(*) FROM sku WHERE variety IS NOT NULL GROUP BY variety ORDER BY COUNT(*) DESC;
SELECT COUNT(*) as still_null_variety FROM sku WHERE variety IS NULL;

\echo '=== Wine Ranges ==='
SELECT range_name, COUNT(*) as sku_count
FROM wine_range wr JOIN sku s ON s.range_id = wr.range_id
GROUP BY range_name ORDER BY range_name;

\echo '=== Territories (should be ~28 unique, no case dupes) ==='
SELECT territory_name, COUNT(st.transaction_id) as sales
FROM territory t
LEFT JOIN sales_transaction st ON st.territory_id = t.territory_id
GROUP BY territory_name ORDER BY territory_name;

COMMIT;
