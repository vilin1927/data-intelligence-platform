-- Migration: 080_clarify12_customer_match_audit.sql
-- Ticket:    CLARIFY-12 — customer fuzzy-match one-click-approve admin UI
-- Date:      2026-04-26
--
-- Purpose
-- -------
-- Create the customer_match_review audit table that backs the admin UI
-- /admin/unmatched-customers. Records who matched what, when, with what
-- confidence score, and whether the action was a match, skip, or
-- create-new-canonical decision.
--
-- Forward-only. No DROP or TRUNCATE.
-- DO NOT APPLY ON PROD until Vladimir approves.
--
-- Rollback recipe (see footer)
-- -------
BEGIN;

-- Pre-condition assertions
DO $$
BEGIN
  -- customer table exists
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema='public' AND table_name='customer'
  ) THEN
    RAISE EXCEPTION 'Pre-assert failed: customer table not found';
  END IF;

  -- canonical_customer table exists
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema='public' AND table_name='canonical_customer'
  ) THEN
    RAISE EXCEPTION 'Pre-assert failed: canonical_customer table not found';
  END IF;

  -- table does not already exist (idempotency guard)
  IF EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema='public' AND table_name='customer_match_review'
  ) THEN
    RAISE NOTICE 'customer_match_review already exists — skipping creation (idempotent)';
  END IF;
END $$;

-- Create audit table (only if it does not already exist)
CREATE TABLE IF NOT EXISTS customer_match_review (
  id                     SERIAL PRIMARY KEY,

  -- The unmatched customer being reviewed
  customer_id            INTEGER NOT NULL
                           REFERENCES customer(customer_id) ON DELETE CASCADE,

  -- Action taken
  action                 VARCHAR(20) NOT NULL
                           CHECK (action IN ('matched', 'skipped', 'created_new')),

  -- The canonical suggested by the fuzzy-match algorithm (may be NULL for skipped)
  suggested_canonical_id INTEGER
                           REFERENCES canonical_customer(id) ON DELETE SET NULL,

  -- The canonical actually applied (differs from suggested when reviewer overrides)
  -- NULL for 'skipped' or 'created_new' actions
  applied_canonical_id   INTEGER
                           REFERENCES canonical_customer(id) ON DELETE SET NULL,

  -- Fuzzy match score at the time of review (0.0 – 100.0)
  score                  NUMERIC(5,1),

  -- Who did the review — admin email or 'system' for bulk HIGH_CONFIDENCE_AUTO apply
  reviewer               VARCHAR(200) NOT NULL DEFAULT 'admin',

  -- When the review happened
  reviewed_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  -- Optional free-text notes (e.g. "same business, different city in Vinsight")
  notes                  TEXT,

  -- Fuzzy bucket at time of decision
  bucket                 VARCHAR(30)
                           CHECK (bucket IN ('HIGH_CONFIDENCE_AUTO', 'REVIEW_NEEDED', 'NO_MATCH', NULL))
);

-- Indexes for common query patterns
CREATE INDEX IF NOT EXISTS idx_cmr_customer_id
  ON customer_match_review(customer_id);

CREATE INDEX IF NOT EXISTS idx_cmr_applied_canonical_id
  ON customer_match_review(applied_canonical_id)
  WHERE applied_canonical_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_cmr_reviewed_at
  ON customer_match_review(reviewed_at DESC);

CREATE INDEX IF NOT EXISTS idx_cmr_action
  ON customer_match_review(action);

-- Post-condition assertions
DO $$
DECLARE
  col_count INTEGER;
BEGIN
  SELECT count(*) INTO col_count
  FROM information_schema.columns
  WHERE table_schema='public' AND table_name='customer_match_review';

  IF col_count < 9 THEN
    RAISE EXCEPTION 'Post-assert failed: customer_match_review has only % columns (expected >= 9)', col_count;
  END IF;

  RAISE NOTICE 'customer_match_review created/verified: % columns', col_count;
END $$;

-- Record migration
-- (schema_migrations has 3 cols: version, applied_at, source; source CHECK
-- enum allows only 'live-apply'/'backfilled-2026-04-24'/'backfilled-file-present'.
-- Original file had `description` column + free-text source — both wrong.)
INSERT INTO schema_migrations (version, source)
VALUES (
  '080_clarify12_customer_match_audit',
  'live-apply'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- Rollback recipe (DO NOT run on prod without authorisation)
-- ============================================================
-- BEGIN;
-- DROP TABLE IF EXISTS customer_match_review;
-- DELETE FROM schema_migrations WHERE version = '080';
-- COMMIT;
-- ============================================================
-- Note: rolling back this migration is safe (no data migration,
-- no FK changes to existing tables, no column drops on existing tables).
-- The customer_match_review table is additive only.
-- ============================================================
