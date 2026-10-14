-- =============================================================================
-- 015_wholesale_price.sql — Historical wholesale prices by date range
-- =============================================================================
-- Task: RECON-FIX-08 (Wholesale price table)
-- Source: the owner's "Vladimir notes" tab in Scheduling spreadsheet
-- Run as: psql -U moppity -d moppity_db -f schema/015_wholesale_price.sql
--
-- Wholesale prices change over time. This table tracks price history so that
-- sales are matched to the price that was effective at the time of the sale.
-- =============================================================================

BEGIN;

-- ════════════════════════════════════════════════════════════════════════════
-- wholesale_price — Historical wholesale prices by SKU and date range
-- ════════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS wholesale_price (
    id              SERIAL PRIMARY KEY,
    canonical_sku_id INTEGER REFERENCES canonical_sku(id),
    sku_name        VARCHAR(300),                    -- For display/matching if canonical_sku_id not yet linked
    price_per_case  DECIMAL(10,2) NOT NULL,
    effective_from  DATE NOT NULL,
    effective_to    DATE,                            -- NULL = still current
    notes           TEXT,
    created_at      TIMESTAMP NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMP NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE wholesale_price IS 'Historical wholesale prices by SKU. Used to calculate discount = wholesale_price - net_revenue. The owner maintains via Admin UI.';
COMMENT ON COLUMN wholesale_price.effective_from IS 'Price effective from this date (inclusive).';
COMMENT ON COLUMN wholesale_price.effective_to IS 'Price effective until this date (inclusive). NULL means still current.';
COMMENT ON COLUMN wholesale_price.sku_name IS 'Product name for display. May be populated before canonical_sku_id is linked.';

CREATE INDEX IF NOT EXISTS idx_wholesale_price_sku ON wholesale_price (canonical_sku_id);
CREATE INDEX IF NOT EXISTS idx_wholesale_price_dates ON wholesale_price (effective_from, effective_to);
CREATE INDEX IF NOT EXISTS idx_wholesale_price_sku_name ON wholesale_price (sku_name);

-- ════════════════════════════════════════════════════════════════════════════
-- get_wholesale_price_at_date — Function to lookup price for a sale date
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION get_wholesale_price_at_date(
    p_canonical_sku_id INTEGER,
    p_sale_date DATE
) RETURNS DECIMAL(10,2) AS $$
DECLARE
    v_price DECIMAL(10,2);
BEGIN
    -- Find price where sale_date is within effective range
    SELECT price_per_case INTO v_price
    FROM wholesale_price
    WHERE canonical_sku_id = p_canonical_sku_id
      AND effective_from <= p_sale_date
      AND (effective_to IS NULL OR effective_to >= p_sale_date)
    ORDER BY effective_from DESC  -- Most recent matching period
    LIMIT 1;

    RETURN v_price;  -- Returns NULL if no matching price found
END;
$$ LANGUAGE plpgsql STABLE;

COMMENT ON FUNCTION get_wholesale_price_at_date IS 'Returns the wholesale price for a SKU at a given sale date, or NULL if no price defined.';

-- ════════════════════════════════════════════════════════════════════════════
-- staging_sheets_wholesale — Raw data from Google Sheets "Vladimir notes" tab
-- ════════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS staging_sheets_wholesale (
    id          SERIAL PRIMARY KEY,
    raw_data    JSONB NOT NULL,
    fetched_at  TIMESTAMP NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE staging_sheets_wholesale IS 'Staging table for wholesale price data from the owner''s "Vladimir notes" tab in Scheduling spreadsheet.';

COMMIT;
