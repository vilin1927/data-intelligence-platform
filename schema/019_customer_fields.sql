-- =============================================================================
-- Moppity Vineyards — Add Customer Fields (019_customer_fields.sql)
-- =============================================================================
-- Task: RECON-FIX-18
-- Adds suburb, postcode, rep_id to customer table per the owner's request.
-- =============================================================================

BEGIN;

ALTER TABLE customer ADD COLUMN IF NOT EXISTS suburb VARCHAR(200);
ALTER TABLE customer ADD COLUMN IF NOT EXISTS postcode VARCHAR(10);
ALTER TABLE customer ADD COLUMN IF NOT EXISTS rep_id INTEGER REFERENCES representative(rep_id);

COMMENT ON COLUMN customer.suburb IS 'Customer suburb/location (from Access DB or manual entry)';
COMMENT ON COLUMN customer.postcode IS 'Australian postcode';
COMMENT ON COLUMN customer.rep_id IS 'Sales representative assigned to this customer';

COMMIT;
