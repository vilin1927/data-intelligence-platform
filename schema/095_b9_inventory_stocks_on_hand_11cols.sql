-- schema/095_b9_inventory_stocks_on_hand_11cols.sql
-- Bundle B9 — JC-268 + JC-269: stocks_on_hand 11-col schema +
-- Vinsight Stock Item master (target 742 rows / 57 cols).
--
-- ("Write zone: inventory_* tables only"). Compatibility VIEWs
-- `stocks_on_hand` and `stock_item` alias them so AC SQL written in
-- `count(*) FROM stock_item`) works as written.
--
--   "ID|Stock Item Code|Description|Product Categories|Asset Ledger Code|
--    Stock Location Code|Units In Stock|Units In Stock UOM|Cost Per Unit|
--    Total Value Of Stock|Status"
--
-- 742-row target source (HARD):
--
-- Forward-only: CREATE TABLE IF NOT EXISTS + idempotent ALTER ADD.
-- No DROP / TRUNCATE.

BEGIN;

-- ------------------------------------------------------------------------
-- Pre-state assertions (HARD blockers if missing — fail fast on prod)
-- ------------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name = 'staging_vinsight_stock_items'
    ) THEN
        RAISE EXCEPTION
            'B9 prerequisite missing: staging_vinsight_stock_items not found. '
            'Bundle B9 cannot run without Vinsight staging.';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name = 'canonical_sku'
    ) THEN
        RAISE EXCEPTION
            'B9 prerequisite missing: canonical_sku not found. '
            'B6a must be deployed before B9.';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'canonical_sku'
          AND column_name = 'units_per_case'
    ) THEN
        RAISE EXCEPTION
            'B9 prerequisite missing: canonical_sku.units_per_case column '
            'not found. Re-check B6a schema/088.';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name = 'sku_code_map'
    ) THEN
        RAISE EXCEPTION
            'B9 prerequisite missing: sku_code_map not found. '
            'DWS classifier depends on it.';
    END IF;
END $$;

-- ------------------------------------------------------------------------
-- 1. inventory_stocks_on_hand — 11-column mirror of Access tblStocksONHand
-- ------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS inventory_stocks_on_hand (
    id                    SERIAL PRIMARY KEY,                    -- 1. ID
    stock_item_code       TEXT        NOT NULL,                  -- 2. Stock Item Code
    description           TEXT,                                  -- 3. Description
    product_categories    TEXT,                                  -- 4. Product Categories
    asset_ledger_code     TEXT,                                  -- 5. Asset Ledger Code
    stock_location_code   TEXT        NOT NULL DEFAULT 'DEFAULT',-- 6. Stock Location Code
    units_in_stock        NUMERIC(14,3) NOT NULL DEFAULT 0,      -- 7. Units In Stock
    units_in_stock_uom    TEXT        NOT NULL DEFAULT 'cases',  -- 8. Units In Stock UOM
    cost_per_unit         NUMERIC(14,4),                         -- 9. Cost Per Unit
    total_value_of_stock  NUMERIC(14,2)
        GENERATED ALWAYS AS (units_in_stock * cost_per_unit) STORED, -- 10. Total Value Of Stock
    status                TEXT        NOT NULL DEFAULT 'active', -- 11. Status

    -- bookkeeping (NOT part of the 11-col HARD schema)
    source_system         TEXT        NOT NULL DEFAULT 'vinsight',
    snapshot_date         DATE        NOT NULL DEFAULT CURRENT_DATE,
    updated_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT inventory_soh_uom_chk
        CHECK (units_in_stock_uom IN ('cases', 'bottles', 'litres', 'kg', 'each')),
    CONSTRAINT inventory_soh_status_chk
        CHECK (status IN ('active', 'inactive', 'archived'))
);

CREATE UNIQUE INDEX IF NOT EXISTS inventory_soh_code_loc_date_uk
    ON inventory_stocks_on_hand (stock_item_code, stock_location_code, snapshot_date);

CREATE INDEX IF NOT EXISTS inventory_soh_status_idx
    ON inventory_stocks_on_hand (status);

CREATE INDEX IF NOT EXISTS inventory_soh_location_idx
    ON inventory_stocks_on_hand (stock_location_code);

COMMENT ON TABLE inventory_stocks_on_hand IS
    'B9 JC-268: 11-col mirror of Access tblStocksONHand. '
    'Populated by etl/sync_vinsight_stock_items.py for Moppity-owned stock + '
    'etl/dws_inventory_bottles_to_cases.py for DWS consignment stock. '
    'ALM is excluded by design (JC-262 — ALM takes ownership on purchase).';

COMMENT ON COLUMN inventory_stocks_on_hand.units_in_stock_uom IS
    'B9 JC-266: cases is the canonical UOM. DWS source data is in bottles; '
    'etl/dws_inventory_bottles_to_cases.py converts to cases using '
    'canonical_sku.units_per_case (default 12).';

COMMENT ON COLUMN inventory_stocks_on_hand.stock_location_code IS
    'B9 JC-270 + JC-281: warehouse/location key for per-location drill-down. '
    'Vinsight default = DEFAULT until warehouse model lands. '
    'DWS rows use stock_location_code starting with "DWS-" for the consignment hub.';

-- Compatibility view so the bundle-spec AC SQL `\d stocks_on_hand` returns
-- 11 columns matching tblStocksONHand exactly (no bookkeeping cols).
CREATE OR REPLACE VIEW stocks_on_hand AS
SELECT
    id,
    stock_item_code,
    description,
    product_categories,
    asset_ledger_code,
    stock_location_code,
    units_in_stock,
    units_in_stock_uom,
    cost_per_unit,
    total_value_of_stock,
    status
FROM inventory_stocks_on_hand;

COMMENT ON VIEW stocks_on_hand IS
    'B9 AC1 compatibility: bundle spec requires `\d stocks_on_hand` = 11 cols. '
    'Aliases inventory_stocks_on_hand restricted to the Access tblStocksONHand '
    'columns (no bookkeeping cols).';

-- ------------------------------------------------------------------------
-- 2. inventory_stock_item — Vinsight Stock Item master (target 742 rows)
-- ------------------------------------------------------------------------
-- 57-col Vinsight StockItem schema is too wide for first-class typed cols on
-- day 1; we type the key business cols and keep the full payload as JSONB.
-- This matches the staging-pattern used by B11 alm_data, direct_data, etc.
CREATE TABLE IF NOT EXISTS inventory_stock_item (
    id                  SERIAL PRIMARY KEY,
    vinsight_id         INTEGER     NOT NULL UNIQUE,    -- Vinsight Id
    stock_item_code     TEXT        NOT NULL,
    description         TEXT,
    supplier_name       TEXT,
    product_category    TEXT,
    is_packaged_wine    BOOLEAN,
    is_dry_goods        BOOLEAN,
    is_archived         BOOLEAN     NOT NULL DEFAULT FALSE,
    is_active           BOOLEAN     NOT NULL DEFAULT TRUE,
    standard_cost       NUMERIC(14,4),
    base_wholesale      NUMERIC(14,4),
    units_per_case      NUMERIC(8,3),
    raw_data            JSONB       NOT NULL,            -- full 57-col payload
    fetched_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS inventory_stock_item_code_idx
    ON inventory_stock_item (stock_item_code);

CREATE INDEX IF NOT EXISTS inventory_stock_item_active_idx
    ON inventory_stock_item (is_active, is_archived);

CREATE INDEX IF NOT EXISTS inventory_stock_item_packaged_idx
    ON inventory_stock_item (is_packaged_wine);

COMMENT ON TABLE inventory_stock_item IS
    'B9 JC-269: Vinsight Stock Item master, target 742 rows '
    '(active + inactive + archived per JC-300). '
    'Sourced from /StockItems.json + /StockItems.json?$filter=IsArchived eq true. '
    'Populated by etl/sync_vinsight_stock_items.py. '
    'Full 57-col payload preserved in raw_data; key cols promoted for query speed.';

COMMENT ON COLUMN inventory_stock_item.is_archived IS
    'B9 JC-300: Vinsight sync MUST include archived items so old vintages '
    '(e.g. Moppity Creo Pet Naturel) keep region/variety/COGS metadata even '
    'when current stock = 0.';

-- Compatibility view for AC2 (`SELECT count(*) FROM stock_item` = 742).
CREATE OR REPLACE VIEW stock_item AS
SELECT
    vinsight_id          AS id,
    stock_item_code,
    description,
    supplier_name,
    product_category,
    is_packaged_wine,
    is_dry_goods,
    is_archived,
    is_active,
    standard_cost,
    base_wholesale,
    units_per_case,
    raw_data,
    fetched_at,
    updated_at
FROM inventory_stock_item;

COMMENT ON VIEW stock_item IS
    'B9 AC2 compatibility: bundle spec requires `count(*) FROM stock_item` = 742. '
    'Aliases inventory_stock_item with vinsight_id as id.';

COMMIT;
