-- =============================================================================
-- 022_vineyard_region.sql
-- Vineyard / Region lookup tables seeded from Vinsight API
-- =============================================================================
-- Context: JF-07 replaces regex-on-batch-code region derivation with a real
-- read from the Vinsight Composition API. These tables hold the authoritative
-- code→description mappings used by etl/sync_composition_from_staging.py.
--
-- Additive / forward-only. Safe to run against production.
--
-- Sources:
--   region_lookup   → GET /Regions.json
--   vineyard_region → GET /Blocks.json?$expand=Vineyard  (Vineyards endpoint is sparse)
-- =============================================================================

-- Region lookup: 2-char region code → human-readable description.
-- Keyed on the same 2-char code that appears as the SUFFIX of every
-- Moppity batch code (e.g. '24PINCOP13LKTU' → 'TU' → 'Tumbarumba').
CREATE TABLE IF NOT EXISTS region_lookup (
    region_code VARCHAR(20) PRIMARY KEY,
    region_description VARCHAR(200) NOT NULL,
    last_synced TIMESTAMPTZ DEFAULT NOW()
);

COMMENT ON TABLE region_lookup IS
  'Canonical region code→description from Vinsight /Regions.json. Seeded by etl/seed_vineyard_region.py.';

-- Vineyard → region map. Required by JF-07 acceptance criterion even though
-- the primary lookup for composition sync is region_lookup.
-- Populated from /Blocks.json?$expand=Vineyard (which surfaces more vineyards
-- than /Vineyards.json does).
CREATE TABLE IF NOT EXISTS vineyard_region (
    vineyard_code VARCHAR(50) PRIMARY KEY,
    vineyard_description VARCHAR(200),
    region_code VARCHAR(20),
    region_description VARCHAR(200),
    last_synced TIMESTAMPTZ DEFAULT NOW(),
    FOREIGN KEY (region_code) REFERENCES region_lookup(region_code) ON UPDATE CASCADE
);

COMMENT ON TABLE vineyard_region IS
  'Vineyard code → region mapping from Vinsight /Blocks.json?$expand=Vineyard. Seeded by etl/seed_vineyard_region.py.';

CREATE INDEX IF NOT EXISTS idx_vineyard_region_region_code ON vineyard_region(region_code);

-- -----------------------------------------------------------------------------
-- Extend packaging_vessel with batch_code for composition join.
-- -----------------------------------------------------------------------------
-- JF-07: the ETL writes PackagingOperations.Vessels[].BatchCode onto each
-- packaging_vessel row so the composition sync can join:
--     packaging_vessel.batch_code[-2:] → region_lookup.region_code
-- Additive / idempotent. No data loss.
ALTER TABLE packaging_vessel
    ADD COLUMN IF NOT EXISTS batch_code VARCHAR(100);

CREATE INDEX IF NOT EXISTS idx_packaging_vessel_batch_code
    ON packaging_vessel(batch_code);
