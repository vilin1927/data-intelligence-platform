-- =============================================================================
-- Moppity Vineyards — Australian Postcode Lookup Table (032_au_postcode_lookup.sql)
-- =============================================================================
-- Task: JF-24 (suburb→postcode auto-populate in import wizard)
-- Creates reference table for Australian suburb/locality to postcode mapping.
-- Seeded from https://github.com/matthewproctor/australianpostcodes (18,535 entries).
-- Already applied on VPS via direct seed — this migration is for documentation.
-- =============================================================================

BEGIN;

CREATE TABLE IF NOT EXISTS au_postcode (
  id SERIAL PRIMARY KEY,
  postcode VARCHAR(4) NOT NULL,
  locality VARCHAR(100) NOT NULL,
  state VARCHAR(3) NOT NULL,
  type VARCHAR(30)
);

CREATE INDEX IF NOT EXISTS idx_au_postcode_locality ON au_postcode (LOWER(locality));
CREATE INDEX IF NOT EXISTS idx_au_postcode_postcode ON au_postcode (postcode);

COMMENT ON TABLE au_postcode IS 'Australian suburb/locality to postcode reference table — sourced from ABS/AusPost open data';
COMMENT ON COLUMN au_postcode.type IS 'Delivery Area, PO Box, LVR, etc. — prefer Delivery Area for suburb lookups';

COMMIT;
