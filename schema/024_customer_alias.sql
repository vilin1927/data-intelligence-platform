-- 022_customer_alias.sql
-- BUG-06: Customer dedup fast path — manual alias table
--
-- Context: the owner 2026-04-11 screenshot showed Pegasus Supply Solutions as TWO rows on
-- the Sales Analytics → Top Customers section ("@ REVESBY" variant vs base name).
--
-- Investigation (2026-04-11 margin-bugs-agent) found 3 customer rows for Pegasus
-- (customer_id 2889, 6498, 9117) and all 3 ALREADY point to the same
-- canonical_customer_id = 2715. The real root cause of BUG-06 is that the
-- /api/sales Top Customers query groups by raw customer.customer_id instead of
-- canonical_customer.id. That fix is applied in dashboard/src/app/api/sales/route.ts
-- on the same commit.
--
-- This table is created per task brief as an infrastructure primitive for future
-- manual dedupe overrides that the canonical_customer layer doesn't cover. Seed
-- rows document the Pegasus variants for audit history.
--
-- Long-term: Stage 2 admin grids (JF-27) will provide a dedupe review UI that
-- writes to this table.

CREATE TABLE IF NOT EXISTS customer_alias (
  alias_id              SERIAL PRIMARY KEY,
  alias_name            VARCHAR(500) NOT NULL,
  canonical_customer_id INTEGER NOT NULL REFERENCES canonical_customer(id),
  source                VARCHAR(50) DEFAULT 'manual',
  note                  TEXT,
  created_at            TIMESTAMPTZ DEFAULT NOW()
);

-- Case-insensitive uniqueness so 'FOO' and 'foo' don't both match and cause
-- row multiplication in JOINs against customer.customer_name.
CREATE UNIQUE INDEX IF NOT EXISTS uq_customer_alias_name_lower
  ON customer_alias (LOWER(alias_name));

CREATE INDEX IF NOT EXISTS idx_customer_alias_canonical
  ON customer_alias (canonical_customer_id);

-- Seed: Pegasus dedup audit row (documents that canonical already handles this)
-- All 3 raw customer rows for Pegasus already map to canonical_customer.id=2715.
-- Only one row per case-insensitive name to preserve the JOIN invariant.
INSERT INTO customer_alias (alias_name, canonical_customer_id, source, note)
VALUES
  ('CUSTOMER 07 @ REVESBY', 2715, 'bug06-seed',
   'the owner 2026-04-11 dedup seed; already handled by canonical layer'),
  ('CUSTOMER 07', 2715, 'bug06-seed',
   'the owner 2026-04-11 dedup seed; covers both ALL-CAPS and Title-case variants')
ON CONFLICT DO NOTHING;

-- Grant read access so the dashboard readonly role can JOIN on this table.
GRANT SELECT ON customer_alias TO moppity_readonly;
