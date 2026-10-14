-- schema/175 — M12 customer codes ingest from "Customers Postgres Updated" tab
--
-- DESTRUCTIVE: false  (this .sql = DDL stub: CREATE audit table/index + schema_migrations row; data UPDATE ran via scripts/apply-schema-175-customer-ingest.py — atomic txn + full per-row audit)
-- AUDIT-TABLE: schema_175_customer_ingest_audit
-- (trust-contract v1 header retrofit 2026-05-17 — migration already applied + verified; tokens document shipped truth, prose context retained below)
--
-- Forward-only. Audit JSON-blob per row. xlsx WINS where xlsx non-empty, else prod kept.
-- DDL stub only — actual UPDATE work runs via scripts/apply-schema-175-customer-ingest.py
-- to keep 3-pass matching (primary / encoding-normalize / max_id-fallback) in one Python
-- transaction with full audit and atomic rollback.
--
--              sheet "Customers Postgres Updated" (4070 rows × 22 cols)
--
-- Dry-run summary (apply-script dry-run vs prod 2026-05-14, xlsx_id_pk PK-direct match):
--   2243 UPDATE (codes only) + 1827 unchanged + 0 unmatched + 0 ambiguous
--   xlsx_id_pk pass matches ALL 4070 xlsx rows; passes 2/3/4 unused
--   0 rep_name / territory / suburb / postcode / channel updates
--   per-col tally: ynr_customer_code=1520, customer_code=851, ynr_alm_customer_code=60,
--                  dir_customer_code=1, ilg_customer_code=1, customer_group=1
--    strategy only — predates xlsx_id_pk pass; superseded by apply-script dry-run.)
--
-- Rollback: scripts/revert-schema-175-customer-ingest.py reads schema_175_customer_ingest_audit.prev_row_json
-- and reverses each row. ~5min for 2243 rows.

BEGIN;

-- 1. Audit table (forward-only, immutable per row)
CREATE TABLE IF NOT EXISTS schema_175_customer_ingest_audit (
  id SERIAL PRIMARY KEY,
  canonical_customer_id INT NOT NULL REFERENCES canonical_customer(id),
  xlsx_row_n INT NOT NULL,
  match_strategy TEXT NOT NULL CHECK (match_strategy IN (
    'xlsx_id_pk',
    'primary_xname_suburb',
    'encoding_normalize_ascii',
    'fallback_max_id'
  )),
  prev_row_json JSONB NOT NULL,
  new_row_json JSONB NOT NULL,
  cols_changed TEXT[] NOT NULL,
  applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  applied_by TEXT NOT NULL DEFAULT current_user
);

CREATE INDEX IF NOT EXISTS idx_schema_175_audit_canonical
  ON schema_175_customer_ingest_audit (canonical_customer_id);
CREATE INDEX IF NOT EXISTS idx_schema_175_audit_applied_at
  ON schema_175_customer_ingest_audit (applied_at);

COMMENT ON TABLE schema_175_customer_ingest_audit IS
  'M12 customer codes ingest from xlsx (4).xlsx "Customers Postgres Updated" tab. Per-row prev/new JSON for rollback.';

-- 2. schema_migrations ledger
-- schema_migrations.source CHECK allows only {live-apply, backfilled-2026-04-24, backfilled-file-present}.
-- Mark as 'live-apply' since this ran via apply-script live against prod.
INSERT INTO schema_migrations (version, applied_at, source)
VALUES ('175', NOW(), 'live-apply')
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- Next step: run `python3 scripts/apply-schema-175-customer-ingest.py --commit`
-- with DATABASE_URL pointing to writable prod role (NOT moppity_readonly).
