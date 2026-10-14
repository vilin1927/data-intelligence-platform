-- M2 Foundation Schema: COGS Traceability + Economic Grape Pricing
-- Implements EPIC-01 from M2-IMPLEMENTATION-PLAN.md
-- Run as: psql -U moppity -d moppity_db -f 008_m2_foundation.sql

BEGIN;

-- ============================================================================
-- 1. grape_price_rule: Economic grape prices (4-tier hierarchy)
-- ============================================================================
-- The owner enters prices here. "Most specific wins" cascade logic.
-- Blank columns = wildcard (applies to all)

CREATE TABLE IF NOT EXISTS grape_price_rule (
    id SERIAL PRIMARY KEY,
    region VARCHAR(100),           -- e.g., 'Tumbarumba', 'Hilltops', 'Young'
    color VARCHAR(20),             -- 'white', 'red', NULL = all colors
    grade INTEGER CHECK (grade IN (1, 2, 3)),  -- 1=Reserved/Ascalia, 2=Single Block/Crest, 3=Lock&Key
    variety VARCHAR(100),          -- e.g., 'Shiraz', 'Chardonnay', NULL = all varieties
    vintage INTEGER NOT NULL,      -- e.g., 2025
    price_per_ton NUMERIC(10,2) NOT NULL,  -- Economic price in AUD

    -- Audit fields
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW(),
    created_by VARCHAR(100) DEFAULT 'system',

    -- Ensure no duplicate rules
    UNIQUE (region, color, grade, variety, vintage)
);

COMMENT ON TABLE grape_price_rule IS 'Economic grape prices for what-if analysis. More specific rules (more columns filled) win over general rules.';

CREATE INDEX IF NOT EXISTS idx_grape_price_rule_lookup
ON grape_price_rule(region, vintage, color, grade, variety);

-- ============================================================================
-- 2. wine_batch: From Vinsight WineBatches
-- ============================================================================
-- Represents a batch of wine made from grapes (the first step after harvest)

CREATE TABLE IF NOT EXISTS wine_batch (
    id SERIAL PRIMARY KEY,
    vinsight_batch_id VARCHAR(50) UNIQUE NOT NULL,  -- Vinsight WineBatch.Id
    batch_code VARCHAR(100),        -- Vinsight WineBatch.Code
    description VARCHAR(500),       -- Vinsight WineBatch.Description

    -- Grape details (from Vinsight)
    variety VARCHAR(100),           -- e.g., 'Shiraz', 'Chardonnay'
    region VARCHAR(100),            -- e.g., 'Tumbarumba', 'Hilltops'
    vintage INTEGER,                -- e.g., 2021
    color VARCHAR(20),              -- 'white', 'red' (derived from variety)

    -- Cost from Vinsight (accounting cost)
    accounting_grape_cost_per_ton NUMERIC(10,2),  -- What Vinsight records
    total_grape_tonnes NUMERIC(10,4),             -- How many tonnes in this batch

    -- Status
    status VARCHAR(50),             -- Vinsight batch status
    created_date DATE,              -- When batch was created in Vinsight

    -- Sync metadata
    raw_data JSONB,                 -- Full Vinsight API response
    synced_at TIMESTAMP DEFAULT NOW()
);

COMMENT ON TABLE wine_batch IS 'Wine batches from Vinsight. First step: grapes → wine batch.';

CREATE INDEX IF NOT EXISTS idx_wine_batch_vintage ON wine_batch(vintage);
CREATE INDEX IF NOT EXISTS idx_wine_batch_variety ON wine_batch(variety);

-- ============================================================================
-- 3. vessel: From Vinsight Vessels (tanks/barrels)
-- ============================================================================
-- Wine moves from batch into vessels (tanks or barrels) for aging

CREATE TABLE IF NOT EXISTS vessel (
    id SERIAL PRIMARY KEY,
    vinsight_vessel_id VARCHAR(50) UNIQUE NOT NULL,  -- Vinsight Vessel.Id
    vessel_code VARCHAR(100),       -- Vinsight Vessel.Code (e.g., 'T001', 'B042')
    name VARCHAR(200),              -- Vinsight Vessel.Name
    vessel_type VARCHAR(50),        -- 'tank', 'barrel', etc.
    capacity_litres NUMERIC(12,2),  -- Vessel capacity

    -- Current contents (from Vinsight)
    wine_batch_id INTEGER REFERENCES wine_batch(id),  -- Which batch is in this vessel
    current_volume_litres NUMERIC(12,2),

    -- Sync metadata
    raw_data JSONB,
    synced_at TIMESTAMP DEFAULT NOW()
);

COMMENT ON TABLE vessel IS 'Tanks and barrels from Vinsight. Wine ages here before packaging.';

CREATE INDEX IF NOT EXISTS idx_vessel_batch ON vessel(wine_batch_id);

-- ============================================================================
-- 4. packaging_operation: From Vinsight PackagingOperations
-- ============================================================================
-- Wine is bottled: many vessels blend into one packaging operation → SKU

CREATE TABLE IF NOT EXISTS packaging_operation (
    id SERIAL PRIMARY KEY,
    vinsight_packaging_id VARCHAR(50) UNIQUE NOT NULL,  -- Vinsight PackagingOperation.Id
    operation_code VARCHAR(100),    -- Vinsight operation code
    description VARCHAR(500),

    -- Link to our SKU
    sku_id INTEGER REFERENCES sku(sku_id),  -- Which product this became
    vinsight_stock_item_id VARCHAR(50), -- Vinsight StockItem.Id for matching

    -- Bottling details
    bottling_date DATE,
    cases_produced INTEGER,
    bottles_produced INTEGER,

    -- Status
    status VARCHAR(50),

    -- Sync metadata
    raw_data JSONB,
    synced_at TIMESTAMP DEFAULT NOW()
);

COMMENT ON TABLE packaging_operation IS 'Bottling runs from Vinsight. Multiple vessels blend into one SKU.';

CREATE INDEX IF NOT EXISTS idx_packaging_sku ON packaging_operation(sku_id);
CREATE INDEX IF NOT EXISTS idx_packaging_date ON packaging_operation(bottling_date);

-- ============================================================================
-- 5. packaging_vessel: Junction table (many vessels → one packaging op)
-- ============================================================================
-- Tracks which vessels contributed to each packaging operation and in what proportion

CREATE TABLE IF NOT EXISTS packaging_vessel (
    id SERIAL PRIMARY KEY,
    packaging_operation_id INTEGER NOT NULL REFERENCES packaging_operation(id) ON DELETE CASCADE,
    vessel_id INTEGER NOT NULL REFERENCES vessel(id),

    -- How much from this vessel went into the blend
    volume_litres NUMERIC(12,2),
    proportion NUMERIC(5,4),  -- 0.0000 to 1.0000 (percentage of total)

    -- Sync metadata
    synced_at TIMESTAMP DEFAULT NOW(),

    UNIQUE (packaging_operation_id, vessel_id)
);

COMMENT ON TABLE packaging_vessel IS 'Junction: which vessels blended into each packaging operation.';

CREATE INDEX IF NOT EXISTS idx_packaging_vessel_op ON packaging_vessel(packaging_operation_id);
CREATE INDEX IF NOT EXISTS idx_packaging_vessel_vessel ON packaging_vessel(vessel_id);

-- ============================================================================
-- 6. SQL Function: get_effective_grape_price()
-- ============================================================================
-- Returns the economic grape price for a given grape profile using "most specific wins" logic

CREATE OR REPLACE FUNCTION get_effective_grape_price(
    p_region VARCHAR,
    p_color VARCHAR,
    p_grade INTEGER,
    p_variety VARCHAR,
    p_vintage INTEGER
) RETURNS NUMERIC(10,2) AS $$
DECLARE
    v_price NUMERIC(10,2);
BEGIN
    -- Find the most specific matching rule
    -- More non-NULL columns = higher specificity
    SELECT price_per_ton INTO v_price
    FROM grape_price_rule
    WHERE vintage = p_vintage
      AND (region IS NULL OR region = p_region)
      AND (color IS NULL OR color = p_color)
      AND (grade IS NULL OR grade = p_grade)
      AND (variety IS NULL OR variety = p_variety)
    ORDER BY
        -- Count non-NULL columns (more = more specific)
        (CASE WHEN region IS NOT NULL THEN 1 ELSE 0 END +
         CASE WHEN color IS NOT NULL THEN 1 ELSE 0 END +
         CASE WHEN grade IS NOT NULL THEN 1 ELSE 0 END +
         CASE WHEN variety IS NOT NULL THEN 1 ELSE 0 END) DESC
    LIMIT 1;

    RETURN COALESCE(v_price, 0);
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION get_effective_grape_price IS 'Returns economic grape price using "most specific wins" cascade logic.';

-- ============================================================================
-- 7. SQL Function: weighted_grape_cost()
-- ============================================================================
-- Calculates weighted average grape cost for a packaging operation
-- Used for SKU COGS calculation

CREATE OR REPLACE FUNCTION weighted_grape_cost(
    p_packaging_id INTEGER,
    p_use_economic BOOLEAN DEFAULT TRUE
) RETURNS NUMERIC(10,2) AS $$
DECLARE
    v_total_cost NUMERIC(14,4) := 0;
    v_total_volume NUMERIC(14,4) := 0;
    v_rec RECORD;
    v_grape_price NUMERIC(10,2);
BEGIN
    -- Loop through each vessel that contributed to this packaging
    FOR v_rec IN
        SELECT
            pv.volume_litres,
            pv.proportion,
            wb.variety,
            wb.region,
            wb.vintage,
            wb.color,
            wb.accounting_grape_cost_per_ton,
            wb.total_grape_tonnes
        FROM packaging_vessel pv
        JOIN vessel v ON v.id = pv.vessel_id
        JOIN wine_batch wb ON wb.id = v.wine_batch_id
        WHERE pv.packaging_operation_id = p_packaging_id
    LOOP
        IF p_use_economic THEN
            -- Get economic price from grape_price_rule
            -- Note: grade would need to be derived from wine_range or SKU
            v_grape_price := get_effective_grape_price(
                v_rec.region,
                v_rec.color,
                NULL,  -- grade: TODO derive from wine_range
                v_rec.variety,
                v_rec.vintage
            );
        ELSE
            -- Use accounting price from Vinsight
            v_grape_price := COALESCE(v_rec.accounting_grape_cost_per_ton, 0);
        END IF;

        -- Accumulate weighted cost
        v_total_cost := v_total_cost + (COALESCE(v_rec.proportion, 0) * v_grape_price);
        v_total_volume := v_total_volume + COALESCE(v_rec.proportion, 0);
    END LOOP;

    -- Return weighted average (cost per tonne)
    IF v_total_volume > 0 THEN
        RETURN v_total_cost / v_total_volume;
    ELSE
        RETURN 0;
    END IF;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION weighted_grape_cost IS 'Calculates weighted average grape cost for a packaging operation from blended vessels.';

-- ============================================================================
-- 8. Staging tables for Vinsight data
-- ============================================================================

CREATE TABLE IF NOT EXISTS staging_vinsight_wine_batches (
    id SERIAL PRIMARY KEY,
    raw_data JSONB NOT NULL,
    synced_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS staging_vinsight_vessels (
    id SERIAL PRIMARY KEY,
    raw_data JSONB NOT NULL,
    synced_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS staging_vinsight_packaging_operations (
    id SERIAL PRIMARY KEY,
    raw_data JSONB NOT NULL,
    synced_at TIMESTAMP DEFAULT NOW()
);

-- ============================================================================
-- 9. Seed data: Example grape prices for testing
-- ============================================================================

INSERT INTO grape_price_rule (region, color, grade, variety, vintage, price_per_ton)
VALUES
    -- Level 1: Broad regional pricing for 2024
    ('Tumbarumba', NULL, NULL, NULL, 2024, 2000.00),
    ('Hilltops', NULL, NULL, NULL, 2024, 1800.00),
    ('Young', NULL, NULL, NULL, 2024, 1600.00),

    -- Level 2: Color-specific overrides
    ('Tumbarumba', 'white', NULL, NULL, 2024, 2200.00),  -- Premium whites

    -- Level 3: Grade-specific
    ('Tumbarumba', 'white', 1, NULL, 2024, 2500.00),     -- Reserved/Ascalia grade

    -- Level 4: Variety-specific
    ('Tumbarumba', 'white', 1, 'Chardonnay', 2024, 2800.00)  -- Top Chardonnay
ON CONFLICT DO NOTHING;

COMMIT;

-- ============================================================================
-- Verification queries
-- ============================================================================

-- Check tables created
SELECT 'grape_price_rule' as table_name, COUNT(*) as rows FROM grape_price_rule
UNION ALL SELECT 'wine_batch', COUNT(*) FROM wine_batch
UNION ALL SELECT 'vessel', COUNT(*) FROM vessel
UNION ALL SELECT 'packaging_operation', COUNT(*) FROM packaging_operation
UNION ALL SELECT 'packaging_vessel', COUNT(*) FROM packaging_vessel;

-- Test get_effective_grape_price function
SELECT get_effective_grape_price('Tumbarumba', 'white', 1, 'Chardonnay', 2024) as chardonnay_price;
SELECT get_effective_grape_price('Tumbarumba', 'red', NULL, 'Shiraz', 2024) as shiraz_price;
SELECT get_effective_grape_price('Hilltops', NULL, NULL, NULL, 2024) as hilltops_default;
