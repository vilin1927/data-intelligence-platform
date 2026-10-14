-- =============================================================================
-- 091_b6b_sku_match_review.sql
-- B6b — JC-107 / JC-108 / JC-120 audit table for /admin/unmatched-skus
-- =============================================================================
-- Purpose
-- -------
-- Mirrors customer_match_review (schema/080) for SKU. Backs the new
-- /admin/unmatched-skus admin UI (B6b). Records who matched what unmatched
-- SKU to which canonical_sku, with what fuzzy-confidence score, and whether
-- the action was a match or a skip. JC-108 forbids "create new canonical from
-- the modal" so the action enum has 'matched' and 'skipped' only — new
-- canonicals come exclusively from etl/import_sku_from_access_first.py.
--
-- Forward-only. Rollback recipe at footer.
-- =============================================================================

BEGIN;

-- Pre-condition assertions
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema='public' AND table_name='sku'
  ) THEN
    RAISE EXCEPTION 'Pre-assert failed: sku table not found';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema='public' AND table_name='canonical_sku'
  ) THEN
    RAISE EXCEPTION 'Pre-assert failed: canonical_sku table not found (schema/012 missing)';
  END IF;

  IF EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema='public' AND table_name='sku_match_review'
  ) THEN
    RAISE NOTICE 'sku_match_review already exists — skipping creation (idempotent)';
  END IF;
END $$;

-- Audit table — same shape as customer_match_review for code parity.
CREATE TABLE IF NOT EXISTS sku_match_review (
  id                          SERIAL PRIMARY KEY,

  -- The unmatched sku row being reviewed
  sku_id                      INTEGER NOT NULL
                                REFERENCES sku(sku_id) ON DELETE CASCADE,

  -- Action: matched (linked to existing canonical_sku) or skipped (defer).
  -- 'created_new' is INTENTIONALLY ABSENT — JC-108 says no free-form create
  -- from the admin UI. New canonicals come only from accdb-driven ETL.
  action                      VARCHAR(20) NOT NULL
                                CHECK (action IN ('matched', 'skipped')),

  -- Canonical the fuzzy matcher suggested (NULL when no auto-suggestion existed)
  suggested_canonical_sku_id  INTEGER
                                REFERENCES canonical_sku(id) ON DELETE SET NULL,

  -- Canonical actually applied (differs from suggested when reviewer overrides
  -- via manual typeahead). NULL for 'skipped'.
  applied_canonical_sku_id    INTEGER
                                REFERENCES canonical_sku(id) ON DELETE SET NULL,

  -- Fuzzy match score at the time of decision (0.0 – 100.0)
  score                       NUMERIC(5,1),

  -- Who did the review (admin email or 'system' for high-confidence auto-apply)
  reviewer                    VARCHAR(200) NOT NULL DEFAULT 'admin',

  reviewed_at                 TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  notes                       TEXT,

  -- Fuzzy bucket label at time of decision
  bucket                      VARCHAR(30)
                                CHECK (bucket IN ('HIGH_CONFIDENCE_AUTO', 'REVIEW_NEEDED', 'NO_MATCH', 'MANUAL', NULL))
);

CREATE INDEX IF NOT EXISTS idx_smr_sku_id
  ON sku_match_review(sku_id);

CREATE INDEX IF NOT EXISTS idx_smr_applied_canonical_sku_id
  ON sku_match_review(applied_canonical_sku_id)
  WHERE applied_canonical_sku_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_smr_reviewed_at
  ON sku_match_review(reviewed_at DESC);

CREATE INDEX IF NOT EXISTS idx_smr_action
  ON sku_match_review(action);

-- Post-condition assertion
DO $$
DECLARE
  col_count INTEGER;
BEGIN
  SELECT count(*) INTO col_count
  FROM information_schema.columns
  WHERE table_schema='public' AND table_name='sku_match_review';

  IF col_count < 9 THEN
    RAISE EXCEPTION 'Post-assert failed: sku_match_review has only % columns (expected >= 9)', col_count;
  END IF;

  RAISE NOTICE 'sku_match_review created/verified: % columns', col_count;
END $$;

INSERT INTO schema_migrations (version, source)
VALUES ('091_b6b_sku_match_review', 'live-apply')
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- Rollback recipe (DO NOT run on prod without authorisation)
-- ============================================================
-- BEGIN;
-- DROP TABLE IF EXISTS sku_match_review;
-- DELETE FROM schema_migrations WHERE version = '091_b6b_sku_match_review';
-- COMMIT;
-- ============================================================
