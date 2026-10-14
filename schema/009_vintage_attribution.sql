-- Migration 009: Vintage Attribution + Economic COGS
-- Part of M2-COGS-ENGINE: enables correct economic COGS on all dashboard pages
--
-- Creates:
--   1. vinsight_sales_order_item — flat table of Vinsight dispatch line items
--   2. sale_vintage_attribution — maps each sales_transaction to a vintage
--   3. economic_cogs_per_unit column on sales_transaction

-- ============================================================================
-- 1. Vinsight Sales Order Items (flat, from /SalesOrderItems.json)
-- ============================================================================
CREATE TABLE IF NOT EXISTS vinsight_sales_order_item (
    id              SERIAL PRIMARY KEY,
    entry_num       INTEGER NOT NULL,          -- Vinsight EntryNum (line item ID)
    order_num       INTEGER NOT NULL,          -- Vinsight SalesOrderNum (FK to staging_vinsight_sales_orders)
    stock_item_num  INTEGER NOT NULL,          -- Vinsight StockItemNum (FK to StockItems)
    quantity        NUMERIC(12,2) NOT NULL,    -- Cases/units sold
    uom_code        VARCHAR(50),               -- Unit of measure (e.g. '12x750mL')
    -- Denormalized from joins (populated by ETL transform step):
    stock_item_code VARCHAR(100),              -- e.g. 'COPRSANB24' (from StockItems)
    description     VARCHAR(500),              -- e.g. 'Procella Sangiovese 2024'
    date_despatched TIMESTAMP,                 -- From SalesOrder
    invoice_date    TIMESTAMP,                 -- From SalesOrder
    contact_code    VARCHAR(200),              -- Customer name from SalesOrder.Contact
    contact_num     INTEGER,                   -- Vinsight ContactNum
    vintage         INTEGER,                   -- Extracted from StockItemCode or Description
    synced_at       TIMESTAMP DEFAULT NOW(),
    UNIQUE(entry_num)
);

CREATE INDEX IF NOT EXISTS idx_vsoi_order_num ON vinsight_sales_order_item(order_num);
CREATE INDEX IF NOT EXISTS idx_vsoi_stock_item_num ON vinsight_sales_order_item(stock_item_num);
CREATE INDEX IF NOT EXISTS idx_vsoi_stock_item_code ON vinsight_sales_order_item(stock_item_code);
CREATE INDEX IF NOT EXISTS idx_vsoi_date_despatched ON vinsight_sales_order_item(date_despatched);
CREATE INDEX IF NOT EXISTS idx_vsoi_contact_num ON vinsight_sales_order_item(contact_num);

-- ============================================================================
-- 2. Sale Vintage Attribution (links sales_transaction → vintage)
-- ============================================================================
CREATE TABLE IF NOT EXISTS sale_vintage_attribution (
    id                  SERIAL PRIMARY KEY,
    sales_transaction_id INTEGER NOT NULL REFERENCES sales_transaction(transaction_id),
    attributed_vintage  INTEGER NOT NULL,       -- The vintage year assigned to this sale
    attribution_method  VARCHAR(50) NOT NULL,    -- 'direct_match', 'last_ordered', 'proportional', 'sku_code', 'manual'
    confidence          NUMERIC(3,2) DEFAULT 1.0, -- 0.0 to 1.0 (1.0 = exact match)
    vinsight_order_num  INTEGER,                -- Source Vinsight order used for attribution
    notes               TEXT,                   -- Explanation of how vintage was determined
    created_at          TIMESTAMP DEFAULT NOW(),
    updated_at          TIMESTAMP DEFAULT NOW(),
    UNIQUE(sales_transaction_id)
);

CREATE INDEX IF NOT EXISTS idx_sva_vintage ON sale_vintage_attribution(attributed_vintage);
CREATE INDEX IF NOT EXISTS idx_sva_method ON sale_vintage_attribution(attribution_method);

-- ============================================================================
-- 3. Economic COGS column on sales_transaction
-- ============================================================================
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'sales_transaction' AND column_name = 'economic_cogs_per_unit'
    ) THEN
        ALTER TABLE sales_transaction ADD COLUMN economic_cogs_per_unit NUMERIC(12,4);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'sales_transaction' AND column_name = 'economic_cogs_total'
    ) THEN
        ALTER TABLE sales_transaction ADD COLUMN economic_cogs_total NUMERIC(14,2);
    END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_st_economic_cogs ON sales_transaction(economic_cogs_per_unit) WHERE economic_cogs_per_unit IS NOT NULL;
