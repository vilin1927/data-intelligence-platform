-- =============================================================================
-- 012_canonical_foundation.sql — Foundation Tables: Canonical SKU, Customer, Territory
-- =============================================================================
-- Tasks: F-01 (99 Canonical SKUs), F-02 (4,030 Customers), F-03 (30 Territories)
-- Run as: psql -U moppity -d moppity_db -f schema/012_canonical_foundation.sql
--
-- This script is forward-only and idempotent (IF NOT EXISTS throughout).
-- =============================================================================

BEGIN;

-- ════════════════════════════════════════════════════════════════════════════
-- F-01: canonical_sku — the owner's authoritative 99 SKU master list
-- ════════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS canonical_sku (
    id              SERIAL PRIMARY KEY,
    sku_name        VARCHAR(300) NOT NULL UNIQUE,
    range_name      VARCHAR(200),
    range_group     VARCHAR(200),
    units_per_case  INTEGER,
    cogs            DECIMAL(10,2),
    base_wholesale  DECIMAL(10,2),
    transfer_cost   DECIMAL(10,2),
    created_at      TIMESTAMP NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMP NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE canonical_sku IS 'the owner''s authoritative 99 SKU master list from the reconciliation spreadsheet. Vintage-agnostic product definitions.';
COMMENT ON COLUMN canonical_sku.sku_name IS 'Product name as given by the owner, e.g. "LOCK & KEY SHIRAZ". UNIQUE and canonical.';
COMMENT ON COLUMN canonical_sku.cogs IS 'COGS per case from the owner''s spreadsheet.';
COMMENT ON COLUMN canonical_sku.base_wholesale IS 'Base wholesale price per case.';
COMMENT ON COLUMN canonical_sku.transfer_cost IS 'Internal transfer cost per case.';


-- Link existing sku rows to canonical_sku
ALTER TABLE sku ADD COLUMN IF NOT EXISTS canonical_sku_id INTEGER REFERENCES canonical_sku(id);

CREATE INDEX IF NOT EXISTS idx_sku_canonical_sku_id ON sku (canonical_sku_id);


-- ════════════════════════════════════════════════════════════════════════════
-- F-01 (cont): canonical_sku_code_map — external code → canonical SKU mapping
-- ════════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS canonical_sku_code_map (
    id                SERIAL PRIMARY KEY,
    canonical_sku_id  INTEGER NOT NULL REFERENCES canonical_sku(id),
    source_system     VARCHAR(50) NOT NULL,    -- 'dws', 'alm', 'vinsight', 'xero'
    external_code     VARCHAR(200) NOT NULL,   -- the code used in that external system
    confidence        DECIMAL(3,2) DEFAULT 1.0, -- 0.00–1.00, how confident the mapping is
    notes             TEXT,
    created_at        TIMESTAMP NOT NULL DEFAULT NOW(),
    UNIQUE (source_system, external_code)
);

COMMENT ON TABLE canonical_sku_code_map IS 'Maps external system codes to canonical_sku. Used for reconciliation across DWS, ALM, Vinsight, etc.';
COMMENT ON COLUMN canonical_sku_code_map.confidence IS '1.0 = confirmed mapping, <1.0 = fuzzy/auto-matched.';

CREATE INDEX IF NOT EXISTS idx_canonical_sku_code_map_lookup
    ON canonical_sku_code_map (source_system, external_code);


-- ════════════════════════════════════════════════════════════════════════════
-- F-02: canonical_customer — the owner's 4,030 customer master
-- ════════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS canonical_customer (
    id                  SERIAL PRIMARY KEY,
    customer_name       VARCHAR(500) NOT NULL UNIQUE,
    alm_customer_code   VARCHAR(100),
    dir_customer_code   VARCHAR(100),
    ynr_customer_code   VARCHAR(100),
    territory_name      VARCHAR(200),
    rep_name            VARCHAR(200),
    channel             VARCHAR(100),
    customer_group      VARCHAR(200),
    created_at          TIMESTAMP NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE canonical_customer IS 'the owner''s authoritative customer master (~4,030 rows) from reconciliation spreadsheet.';
COMMENT ON COLUMN canonical_customer.alm_customer_code IS 'ALM system customer code.';
COMMENT ON COLUMN canonical_customer.dir_customer_code IS 'Direct channel customer code.';
COMMENT ON COLUMN canonical_customer.ynr_customer_code IS 'Y&R (DWS legacy) customer code.';

CREATE INDEX IF NOT EXISTS idx_canonical_customer_territory ON canonical_customer (territory_name);
CREATE INDEX IF NOT EXISTS idx_canonical_customer_channel ON canonical_customer (channel);

-- Link existing customer rows to canonical_customer
ALTER TABLE customer ADD COLUMN IF NOT EXISTS canonical_customer_id INTEGER REFERENCES canonical_customer(id);

CREATE INDEX IF NOT EXISTS idx_customer_canonical_customer_id ON customer (canonical_customer_id);


-- ════════════════════════════════════════════════════════════════════════════
-- F-03: canonical_territory — the owner's 30 territory list
-- ════════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS canonical_territory (
    id              SERIAL PRIMARY KEY,
    territory_name  VARCHAR(200) NOT NULL UNIQUE
);

COMMENT ON TABLE canonical_territory IS 'the owner''s authoritative 30 territories from reconciliation spreadsheet. Reference table for territory normalization.';

CREATE INDEX IF NOT EXISTS idx_canonical_territory_name ON canonical_territory (territory_name);


COMMIT;
