-- Migration 010: Wine Product Mapping
-- Part of M2-COGS-ENGINE Step 2: bulletproof SKU bridging across code systems
--
-- Key insight: Vinsight StockItemCode = base_code + 2-digit vintage
-- e.g. MVATSHZB22 → base MVATSHZB = "Atrius Shiraz"
-- Strip vintage → deterministic wine product identifier

-- ============================================================================
-- 1. Wine Product reference table (auto-derived from Vinsight StockItemCodes)
-- ============================================================================
CREATE TABLE IF NOT EXISTS wine_product (
    id                  SERIAL PRIMARY KEY,
    wine_product_code   VARCHAR(50) NOT NULL UNIQUE,  -- e.g. 'MVATSHZB' (base code)
    description         VARCHAR(500),                  -- e.g. 'Moppity ATRIUS Shiraz'
    vintages_seen       INTEGER[],                     -- e.g. {2021, 2022, 2023}
    created_at          TIMESTAMP DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_wp_code ON wine_product(wine_product_code);

-- ============================================================================
-- 2. SKU → Wine Product mapping (bridges all code systems)
-- ============================================================================
CREATE TABLE IF NOT EXISTS sku_wine_product_map (
    id                  SERIAL PRIMARY KEY,
    sku_id              INTEGER NOT NULL REFERENCES sku(sku_id),
    wine_product_code   VARCHAR(50) NOT NULL REFERENCES wine_product(wine_product_code),
    mapping_method      VARCHAR(30) NOT NULL,   -- 'direct_code', 'sku_code_map', 'group_sibling', 'description_similarity'
    confidence          NUMERIC(3,2) NOT NULL,  -- 1.0, 1.0, 0.95, 0.80-0.90
    similarity_score    NUMERIC(5,4),           -- Only for description_similarity method
    notes               TEXT,                   -- How the match was made
    created_at          TIMESTAMP DEFAULT NOW(),
    UNIQUE(sku_id)
);

CREATE INDEX IF NOT EXISTS idx_swpm_wine_product ON sku_wine_product_map(wine_product_code);
CREATE INDEX IF NOT EXISTS idx_swpm_method ON sku_wine_product_map(mapping_method);

-- Enable pg_trgm for description similarity matching (Method 4)
CREATE EXTENSION IF NOT EXISTS pg_trgm;
