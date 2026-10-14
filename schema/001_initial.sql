-- =============================================================================
-- Moppity Vineyards — Initial Schema (001_initial.sql)
-- =============================================================================
-- Version:   1.0
-- Created:   2026-03-08
-- Author:    Vladimir (Autoflux)
-- Milestone: M1-02 (Data Foundation)
-- References: PRD Section 5, ADR-005, ADR-006, ADR-008
--
-- This script is idempotent — safe to run multiple times.
-- Uses CREATE TABLE IF NOT EXISTS throughout.
-- Wrapped in a transaction for atomicity.
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- CORE TABLES
-- ---------------------------------------------------------------------------

-- Entity: The 3 Moppity legal structures mapped to Xero organisations.
--   - Vineyard Partnership (owns land, no trading — skipped in Xero sync)
--   - Moppity Vineyards / Trust (grows grapes, grape costs)
--   - Moppity Wines Pty Ltd (makes and sells wine)
CREATE TABLE IF NOT EXISTS entity (
    entity_id   SERIAL PRIMARY KEY,
    entity_name VARCHAR(200) NOT NULL,
    entity_type VARCHAR(50)  NOT NULL,  -- 'partnership', 'trust', 'pty_ltd'
    abn         VARCHAR(20),
    xero_org_id VARCHAR(100),           -- Xero tenant UUID for API calls
    created_at  TIMESTAMP NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMP NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE  entity IS 'The 3 Moppity legal entities. Each maps to a Xero organisation (tenant).';
COMMENT ON COLUMN entity.xero_org_id IS 'Xero tenant UUID. Trust = 29614f53-..., Wines Pty Ltd = d49e7503-...';
COMMENT ON COLUMN entity.entity_type IS 'One of: partnership, trust, pty_ltd';


-- Wine Range: product line groupings (e.g. Lock & Key, Reserve, Coppabella).
CREATE TABLE IF NOT EXISTS wine_range (
    range_id    SERIAL PRIMARY KEY,
    range_name  VARCHAR(200) NOT NULL,
    range_group VARCHAR(100),           -- higher-level grouping if needed
    created_at  TIMESTAMP NOT NULL DEFAULT NOW()
);


-- Channel: DWS (consignment), ALM (wholesale), Direct.
-- Each has different commercial models, revenue timing, and payment terms.
CREATE TABLE IF NOT EXISTS channel (
    channel_id       SERIAL PRIMARY KEY,
    channel_name     VARCHAR(100) NOT NULL UNIQUE,
    commercial_model VARCHAR(50),   -- 'consignment', 'wholesale', 'direct'
    stock_ownership  VARCHAR(100),  -- who holds stock: 'moppity' or 'buyer'
    revenue_timing   VARCHAR(100),  -- when revenue recognised: 'on_sell_through', 'on_invoice'
    payment_terms    VARCHAR(100),  -- e.g. '30 days EOM'
    created_at       TIMESTAMP NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE  channel IS 'Sales channels. DWS = consignment (63% wholesale, 30d EOM), ALM = wholesale, Direct = invoice.';
COMMENT ON COLUMN channel.commercial_model IS 'consignment (DWS), wholesale (ALM), or direct';
COMMENT ON COLUMN channel.stock_ownership IS 'DWS: moppity retains ownership until sell-through. ALM: buyer owns on invoice.';
COMMENT ON COLUMN channel.revenue_timing IS 'DWS: revenue on sell-through. ALM/Direct: revenue on invoice.';


-- Territory: geographic sales regions (from Access DB tblNewTerritory).
CREATE TABLE IF NOT EXISTS territory (
    territory_id   SERIAL PRIMARY KEY,
    territory_name VARCHAR(200) NOT NULL,
    state          VARCHAR(50),   -- NSW, VIC, QLD, etc.
    region         VARCHAR(100),  -- sub-state region
    created_at     TIMESTAMP NOT NULL DEFAULT NOW()
);


-- SKU: individual wine product (variety + vintage + packaging = unique SKU).
-- Vintage is a first-class field — multiple vintages of same wine coexist in inventory.
CREATE TABLE IF NOT EXISTS sku (
    sku_id           SERIAL PRIMARY KEY,
    range_id         INTEGER REFERENCES wine_range(range_id),
    sku_code         VARCHAR(50) NOT NULL,   -- Moppity's canonical code (e.g. MVLKSHZB21)
    item_description VARCHAR(500),
    variety          VARCHAR(100),            -- e.g. Shiraz, Chardonnay, Riesling
    variety_code     VARCHAR(20),             -- short code for variety
    region           VARCHAR(100),            -- wine region (e.g. Hilltops, Tumbarumba)
    vintage          INTEGER,                 -- year (e.g. 2021). Multiple vintages coexist in inventory.
    units_per_case   INTEGER DEFAULT 12,
    base_wholesale   DECIMAL(10,2),           -- base wholesale price per case
    transfer_cost    DECIMAL(10,2),           -- internal transfer cost
    rrp              DECIMAL(10,2),           -- recommended retail price per bottle
    bottle_type      VARCHAR(50),             -- e.g. '750ml', 'magnum'
    vintage_status   VARCHAR(20),             -- 'current', 'previous', 'library'
    created_at       TIMESTAMP NOT NULL DEFAULT NOW(),
    updated_at       TIMESTAMP NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE  sku IS 'Canonical SKU master. One row per variety+vintage+packaging combination.';
COMMENT ON COLUMN sku.sku_code IS 'Moppity canonical code. DWS/ALM use different codes — see sku_code_map.';
COMMENT ON COLUMN sku.vintage IS 'Explicit vintage year. Critical: multiple vintages of same wine coexist in inventory.';
COMMENT ON COLUMN sku.base_wholesale IS 'Base wholesale price per case before channel-specific discounts.';

CREATE INDEX IF NOT EXISTS idx_sku_sku_code ON sku (sku_code);


-- SKU Code Map: reconciles DWS/ALM/Vinsight codes to canonical Moppity SKU.
-- DWS uses codes like MOLKSH21F while Moppity uses MVLKSHZB21.
CREATE TABLE IF NOT EXISTS sku_code_map (
    map_id        SERIAL PRIMARY KEY,
    sku_id        INTEGER NOT NULL REFERENCES sku(sku_id),
    source_system VARCHAR(50) NOT NULL,  -- 'dws', 'alm', 'vinsight', 'xero'
    external_code VARCHAR(100) NOT NULL, -- the code used in that external system
    created_at    TIMESTAMP NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE  sku_code_map IS 'Maps external SKU codes (DWS, ALM, Vinsight) to canonical sku_id. Critical for reconciliation.';
COMMENT ON COLUMN sku_code_map.source_system IS 'Which system uses this code: dws, alm, vinsight, xero';
COMMENT ON COLUMN sku_code_map.external_code IS 'The SKU code as it appears in the external system (e.g. DWS: MOLKSH21F).';

CREATE INDEX IF NOT EXISTS idx_sku_code_map_lookup ON sku_code_map (source_system, external_code);


-- Customer: canonical customer record.
CREATE TABLE IF NOT EXISTS customer (
    customer_id    SERIAL PRIMARY KEY,
    customer_name  VARCHAR(300) NOT NULL,
    channel_id     INTEGER REFERENCES channel(channel_id),
    territory_id   INTEGER REFERENCES territory(territory_id),
    customer_group VARCHAR(100),            -- from Access tblCustomerGroups
    created_at     TIMESTAMP NOT NULL DEFAULT NOW(),
    updated_at     TIMESTAMP NOT NULL DEFAULT NOW()
);


-- Customer Code Map: reconciles ALM/DWS/Direct customer names to canonical customer_id.
-- Each channel uses different naming conventions for the same customer.
CREATE TABLE IF NOT EXISTS customer_code_map (
    map_id        SERIAL PRIMARY KEY,
    customer_id   INTEGER NOT NULL REFERENCES customer(customer_id),
    source_system VARCHAR(50)  NOT NULL,  -- 'dws', 'alm', 'direct', 'vinsight', 'xero'
    external_name VARCHAR(300) NOT NULL,  -- customer name as used in that system
    created_at    TIMESTAMP NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE  customer_code_map IS 'Maps external customer names (ALM/DWS/Direct) to canonical customer_id. Same customer may appear under different names in each channel.';

CREATE INDEX IF NOT EXISTS idx_customer_code_map_lookup ON customer_code_map (source_system, external_name);


-- Representative: sales reps (from Access DB Representative table).
CREATE TABLE IF NOT EXISTS representative (
    rep_id       SERIAL PRIMARY KEY,
    rep_name     VARCHAR(200) NOT NULL,
    territory_id INTEGER REFERENCES territory(territory_id),
    active       BOOLEAN NOT NULL DEFAULT TRUE,
    created_at   TIMESTAMP NOT NULL DEFAULT NOW()
);


-- Award: wine competition medals per SKU.
CREATE TABLE IF NOT EXISTS award (
    award_id         SERIAL PRIMARY KEY,
    sku_id           INTEGER NOT NULL REFERENCES sku(sku_id),
    competition_name VARCHAR(300) NOT NULL,
    year             INTEGER,
    medal_type       VARCHAR(50),  -- 'gold', 'silver', 'bronze', 'trophy', etc.
    created_at       TIMESTAMP NOT NULL DEFAULT NOW()
);


-- ---------------------------------------------------------------------------
-- MONTH-END SNAPSHOT (ADR-008)
-- ---------------------------------------------------------------------------
-- Periods lock on close. Once closed, sales data for that period is immutable.
-- This ensures reporting stability — same report on different days gives same numbers.

CREATE TABLE IF NOT EXISTS month_end_snapshot (
    snapshot_id SERIAL PRIMARY KEY,
    period      VARCHAR(7)  NOT NULL UNIQUE,  -- 'YYYY-MM' (e.g. '2026-01')
    closed_at   TIMESTAMP   NOT NULL DEFAULT NOW(),
    closed_by   VARCHAR(100),                 -- username or system identifier
    notes       TEXT,
    created_at  TIMESTAMP   NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE  month_end_snapshot IS 'Period locking for reporting stability (ADR-008). A row here means the period is closed and no new sales data can be inserted for it.';
COMMENT ON COLUMN month_end_snapshot.period IS 'Format YYYY-MM. Existence of a row means this period is closed.';


-- ---------------------------------------------------------------------------
-- SKU COGS — Economic vs Accounting (ADR-006)
-- ---------------------------------------------------------------------------
-- The owner's core pain: Vinsight records grapes at accounting rate ($300/ton),
-- but market value may be $2,000/ton. This table stores both bases and
-- locks the economic (nominated) price at bottling so history never drifts.

CREATE TABLE IF NOT EXISTS sku_cogs (
    cogs_id                SERIAL PRIMARY KEY,
    sku_id                 INTEGER NOT NULL REFERENCES sku(sku_id),
    financial_year         VARCHAR(7) NOT NULL,         -- e.g. '2025-26'
    accounting_grape_price DECIMAL(10,2),               -- from Vinsight (e.g. $300/ton)
    nominated_grape_price  DECIMAL(10,2),               -- the owner's economic override (e.g. $2,000/ton)
    lock_date              TIMESTAMP,                   -- set at bottling; once set, nominated price is frozen
    bulk_wine_cost         DECIMAL(10,2),               -- cost of bulk wine per unit
    dry_goods_cost         DECIMAL(10,2),               -- labels, cartons, capsules, glass
    bottling_cost          DECIMAL(10,2),               -- bottling line cost per unit

    -- GENERATED columns: sum of cost components for each basis.
    -- Accounting COGS uses Vinsight's grape price; Economic COGS uses the owner's nominated price.
    total_cogs_accounting  DECIMAL(10,2) GENERATED ALWAYS AS (
        COALESCE(accounting_grape_price, 0)
        + COALESCE(bulk_wine_cost, 0)
        + COALESCE(dry_goods_cost, 0)
        + COALESCE(bottling_cost, 0)
    ) STORED,

    total_cogs_economic    DECIMAL(10,2) GENERATED ALWAYS AS (
        COALESCE(nominated_grape_price, 0)
        + COALESCE(bulk_wine_cost, 0)
        + COALESCE(dry_goods_cost, 0)
        + COALESCE(bottling_cost, 0)
    ) STORED,

    created_at             TIMESTAMP NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_sku_cogs_sku_fy UNIQUE (sku_id, financial_year)
);

COMMENT ON TABLE  sku_cogs IS 'Versioned COGS per SKU per financial year (ADR-006). Supports dual cost basis: accounting vs economic.';
COMMENT ON COLUMN sku_cogs.accounting_grape_price IS 'Grape price from Vinsight (accounting rate, e.g. $300/ton). Used for statutory reporting.';
COMMENT ON COLUMN sku_cogs.nominated_grape_price IS 'the owner''s economic grape price override (e.g. $2,000/ton market rate). Locked at bottling.';
COMMENT ON COLUMN sku_cogs.lock_date IS 'Set when wine is bottled. After this date, nominated_grape_price must NOT be changed. Enforced at application layer.';
COMMENT ON COLUMN sku_cogs.total_cogs_accounting IS 'Auto-calculated: accounting_grape_price + bulk_wine + dry_goods + bottling. Read-only.';
COMMENT ON COLUMN sku_cogs.total_cogs_economic IS 'Auto-calculated: nominated_grape_price + bulk_wine + dry_goods + bottling. Read-only.';


-- ---------------------------------------------------------------------------
-- SALES TRANSACTION
-- ---------------------------------------------------------------------------
-- Central fact table linking SKU, customer, rep, territory, channel.
-- Includes rebate_amount and wholesale_fee from Access DB CombinedData.

CREATE TABLE IF NOT EXISTS sales_transaction (
    transaction_id  SERIAL PRIMARY KEY,
    sku_id          INTEGER REFERENCES sku(sku_id),
    customer_id     INTEGER REFERENCES customer(customer_id),
    rep_id          INTEGER REFERENCES representative(rep_id),
    territory_id    INTEGER REFERENCES territory(territory_id),
    channel_id      INTEGER REFERENCES channel(channel_id),
    sale_date       DATE NOT NULL,
    period          VARCHAR(7) NOT NULL,            -- 'YYYY-MM', must match sale_date; used for period locking
    quantity        DECIMAL(12,2) NOT NULL DEFAULT 0,
    unit_price      DECIMAL(10,2),
    discount_amount DECIMAL(10,2) DEFAULT 0,
    rebate_amount   DECIMAL(10,2) DEFAULT 0,        -- from Access CombinedData rebate column
    wholesale_fee   DECIMAL(10,2) DEFAULT 0,        -- DWS/ALM wholesale fees
    net_revenue     DECIMAL(12,2),                  -- calculated: (quantity * unit_price) - discount - rebate - fee
    source_system   VARCHAR(50),                    -- 'access_db', 'vinsight', 'dws_upload', 'alm_upload', 'direct_upload'
    source_ref      VARCHAR(200),                   -- reference ID from source (invoice #, row ID, etc.)
    created_at      TIMESTAMP NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE  sales_transaction IS 'Central sales fact table. Links all dimensions. Includes Access DB fields: rebate_amount, wholesale_fee.';
COMMENT ON COLUMN sales_transaction.period IS 'Format YYYY-MM. Derived from sale_date. Used for month-end locking — INSERT rejected if period is closed.';
COMMENT ON COLUMN sales_transaction.rebate_amount IS 'Channel/customer rebate from Access CombinedData. DWS consignment rebate or group rebate.';
COMMENT ON COLUMN sales_transaction.wholesale_fee IS 'Wholesale fee charged by DWS/ALM. Deducted from gross to get net revenue.';
COMMENT ON COLUMN sales_transaction.source_system IS 'Origin of this record: access_db (migration), vinsight, dws_upload, alm_upload, direct_upload.';
COMMENT ON COLUMN sales_transaction.net_revenue IS 'Net revenue after discounts, rebates, and wholesale fees.';

CREATE INDEX IF NOT EXISTS idx_sales_transaction_sale_date ON sales_transaction (sale_date);
CREATE INDEX IF NOT EXISTS idx_sales_transaction_period    ON sales_transaction (period);


-- ---------------------------------------------------------------------------
-- SYSTEM TABLES — ETL Logging
-- ---------------------------------------------------------------------------

-- ETL Run Log: tracks every sync/import operation.
CREATE TABLE IF NOT EXISTS etl_run_log (
    run_id         SERIAL PRIMARY KEY,
    source         VARCHAR(50) NOT NULL,    -- 'vinsight', 'xero_trust', 'xero_wines', 'access_db', 'sheets', 'dws_upload', 'alm_upload'
    endpoint       VARCHAR(200),            -- API endpoint or table name
    status         VARCHAR(20) NOT NULL DEFAULT 'running',  -- 'running', 'success', 'partial', 'failed'
    rows_processed INTEGER DEFAULT 0,
    rows_skipped   INTEGER DEFAULT 0,
    error_count    INTEGER DEFAULT 0,
    error_detail   TEXT,
    started_at     TIMESTAMP NOT NULL DEFAULT NOW(),
    completed_at   TIMESTAMP
);

COMMENT ON TABLE etl_run_log IS 'Audit trail for every ETL sync. Admin panel queries this for source status and error display.';

CREATE INDEX IF NOT EXISTS idx_etl_run_log_source_started ON etl_run_log (source, started_at);


-- ETL Dead Letter: preserves failed records for debugging (never silently dropped).
CREATE TABLE IF NOT EXISTS etl_dead_letter (
    id            SERIAL PRIMARY KEY,
    run_id        INTEGER REFERENCES etl_run_log(run_id),
    source        VARCHAR(50) NOT NULL,
    raw_data      JSONB,
    error_message TEXT,
    created_at    TIMESTAMP NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE etl_dead_letter IS 'Failed ETL records preserved for debugging. Linked to etl_run_log via run_id.';


-- ---------------------------------------------------------------------------
-- STAGING TABLES (ADR-005: raw API data, untransformed)
-- ---------------------------------------------------------------------------
-- Raw API/sheet responses stored as JSONB. If transforms break, we can
-- re-process from staging without re-fetching from external systems.

-- Vinsight staging
CREATE TABLE IF NOT EXISTS staging_vinsight_stock_items (
    id         SERIAL PRIMARY KEY,
    raw_data   JSONB NOT NULL,
    fetched_at TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS staging_vinsight_sales_orders (
    id         SERIAL PRIMARY KEY,
    raw_data   JSONB NOT NULL,
    fetched_at TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS staging_vinsight_contacts (
    id         SERIAL PRIMARY KEY,
    raw_data   JSONB NOT NULL,
    fetched_at TIMESTAMP NOT NULL DEFAULT NOW()
);

-- Xero staging (includes tenant_id to distinguish Trust vs Wines Pty Ltd)
CREATE TABLE IF NOT EXISTS staging_xero_invoices (
    id         SERIAL PRIMARY KEY,
    tenant_id  VARCHAR(100) NOT NULL,  -- Xero org UUID
    raw_data   JSONB NOT NULL,
    fetched_at TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS staging_xero_contacts (
    id         SERIAL PRIMARY KEY,
    tenant_id  VARCHAR(100) NOT NULL,
    raw_data   JSONB NOT NULL,
    fetched_at TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS staging_xero_accounts (
    id         SERIAL PRIMARY KEY,
    tenant_id  VARCHAR(100) NOT NULL,
    raw_data   JSONB NOT NULL,
    fetched_at TIMESTAMP NOT NULL DEFAULT NOW()
);

-- Google Sheets staging
CREATE TABLE IF NOT EXISTS staging_sheets_scheduling (
    id         SERIAL PRIMARY KEY,
    raw_data   JSONB NOT NULL,
    fetched_at TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS staging_sheets_cashflow (
    id         SERIAL PRIMARY KEY,
    raw_data   JSONB NOT NULL,
    fetched_at TIMESTAMP NOT NULL DEFAULT NOW()
);


-- ---------------------------------------------------------------------------
-- TRIGGER: Reject INSERTs into closed periods (ADR-008)
-- ---------------------------------------------------------------------------
-- If a period exists in month_end_snapshot, it is closed.
-- Any attempt to insert a sales_transaction for that period is rejected.

CREATE OR REPLACE FUNCTION fn_reject_closed_period()
RETURNS TRIGGER AS $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM month_end_snapshot
        WHERE period = NEW.period
    ) THEN
        RAISE EXCEPTION 'Period % is closed. Cannot insert sales data into a closed period.', NEW.period;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Drop and recreate to ensure idempotency (CREATE TRIGGER IF NOT EXISTS is not standard SQL).
DROP TRIGGER IF EXISTS trg_reject_closed_period ON sales_transaction;

CREATE TRIGGER trg_reject_closed_period
    BEFORE INSERT ON sales_transaction
    FOR EACH ROW
    EXECUTE FUNCTION fn_reject_closed_period();

COMMENT ON FUNCTION fn_reject_closed_period IS 'ADR-008: Prevents inserting sales data into a period that has been closed via month_end_snapshot.';


-- ---------------------------------------------------------------------------
-- SEED DATA: Channels (known at schema creation time)
-- ---------------------------------------------------------------------------

INSERT INTO channel (channel_name, commercial_model, stock_ownership, revenue_timing, payment_terms)
VALUES
    ('DWS',    'consignment', 'moppity',  'on_sell_through', '30 days EOM'),
    ('ALM',    'wholesale',   'buyer',    'on_invoice',      'on_invoice'),
    ('Direct', 'direct',      'buyer',    'on_invoice',      'on_invoice')
ON CONFLICT (channel_name) DO NOTHING;


-- ---------------------------------------------------------------------------
-- SEED DATA: Entities (known at schema creation time)
-- ---------------------------------------------------------------------------

INSERT INTO entity (entity_name, entity_type, abn, xero_org_id)
VALUES
    ('Vineyard Partnership',       'partnership', NULL, NULL),
    ('Moppity Vineyards (Trust)',  'trust',       NULL, '00000000-0000-4000-8000-000000000001'),
    ('Moppity Wines Pty Ltd',      'pty_ltd',     NULL, '00000000-0000-4000-8000-000000000002')
ON CONFLICT DO NOTHING;


COMMIT;

-- =============================================================================
-- POST-TRANSACTION VERIFICATION (run manually or in test scripts)
-- =============================================================================
-- SELECT table_name FROM information_schema.tables
--   WHERE table_schema = 'public' ORDER BY table_name;
--
-- Expected: 21 tables (13 core + 2 system + 8 staging - but entity and channel
--           are seeded so verify with SELECT count(*) FROM entity; etc.)
-- =============================================================================
