-- ════════════════════════════════════════════════════════════════════════════
-- schema/061_customer_alias_codes.sql
-- Bundle B4 — 5 channel cross-reference customer codes
-- ════════════════════════════════════════════════════════════════════════════
-- Date:   2026-04-27
-- JCs:    JC-004, JC-238
-- Source: extract-accdb-0009 + extract-xlsx-0013 (HARD — Access + the owner xlsx)
--
-- Adds the two missing channel cross-ref columns (ilg_, ynr_alm_) on
-- canonical_customer to round out the 5-channel set per Access 22-col schema,
-- plus a normalised customer_channel_code lookup table for future-flexible
-- per-channel code lookups (e.g. when ALM rotates a customer's code mid-year
-- and we need to retain history vs. just the current code).
--
-- Existing channel cross-ref cols on canonical_customer (schema/012):
--   alm_customer_code, dir_customer_code, ynr_customer_code
-- Adding here:
--   ilg_customer_code, ynr_alm_customer_code
-- Total after this migration: 5 channel cross-ref cols matching Access spec.
--
-- BLAST RADIUS: canonical_customer (4,014 rows) + new lookup table.
-- All ADDs nullable; new table additive. No FK rewrites, no row deletes.
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ────────────────────────────────────────────────────────────────────────────
-- 1. Pre-condition assertions
-- ────────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
    IF to_regclass('public.canonical_customer') IS NULL THEN
        RAISE EXCEPTION 'canonical_customer missing; schema/012 must land first';
    END IF;

    -- Confirm 060 ran (we expect customer_code etc.)
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='public'
          AND table_name='canonical_customer'
          AND column_name='customer_code'
    ) THEN
        RAISE EXCEPTION 'canonical_customer.customer_code missing; schema/060 must land first';
    END IF;
END $$;

-- ────────────────────────────────────────────────────────────────────────────
-- 2. Add the 2 missing channel cross-ref columns
-- ────────────────────────────────────────────────────────────────────────────
ALTER TABLE canonical_customer
    ADD COLUMN IF NOT EXISTS ilg_customer_code      VARCHAR(100),
    ADD COLUMN IF NOT EXISTS ynr_alm_customer_code  VARCHAR(100);

COMMENT ON COLUMN canonical_customer.ilg_customer_code IS
  'B4 JC-004 (2026-04-27): ILG channel customer code (5th channel — Independent Liquor Group / Independent Liquor Group). Distinct from alm_/dir_/ynr_ codes.';
COMMENT ON COLUMN canonical_customer.ynr_alm_customer_code IS
  'B4 JC-004 (2026-04-27): Young & Rashleigh-via-ALM channel customer code (cross-channel transfer code where YNR sells through ALM).';

CREATE INDEX IF NOT EXISTS idx_canonical_customer_ilg_code
    ON canonical_customer (ilg_customer_code)
    WHERE ilg_customer_code IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_canonical_customer_ynr_alm_code
    ON canonical_customer (ynr_alm_customer_code)
    WHERE ynr_alm_customer_code IS NOT NULL;

-- ────────────────────────────────────────────────────────────────────────────
-- 3. customer_channel_code — normalised lookup
--    One row per (canonical_customer, channel) cross-ref code. Coexists with
--    the 5 wide columns above; the wide columns are the read fast-path, this
--    table is the audit-trail/history form. Backfilled from existing wide
--    columns at end of this migration.
-- ────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS customer_channel_code (
    id                     SERIAL PRIMARY KEY,
    canonical_customer_id  INTEGER NOT NULL
                              REFERENCES canonical_customer(id) ON DELETE CASCADE,
    channel_code           VARCHAR(20) NOT NULL
                              CHECK (channel_code IN
                                ('ALM','DIR','ILG','YNR','YNRALM')),
    external_code          VARCHAR(100) NOT NULL,
    is_current             BOOLEAN NOT NULL DEFAULT TRUE,
    valid_from             DATE,
    valid_to               DATE,
    source                 VARCHAR(50) NOT NULL DEFAULT 'access-import',
    created_at             TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (canonical_customer_id, channel_code, external_code)
);

COMMENT ON TABLE customer_channel_code IS
  'B4 JC-004 + JC-238 (2026-04-27): per-channel customer cross-reference codes for canonical_customer. One row per active code; historical codes retained with is_current=FALSE + valid_to set. Wide columns on canonical_customer (alm_/dir_/ilg_/ynr_/ynr_alm_customer_code) hold the current/active value as a read fast-path.';

CREATE INDEX IF NOT EXISTS idx_customer_channel_code_canonical
    ON customer_channel_code (canonical_customer_id);

CREATE INDEX IF NOT EXISTS idx_customer_channel_code_channel_external
    ON customer_channel_code (channel_code, external_code);

CREATE INDEX IF NOT EXISTS idx_customer_channel_code_current
    ON customer_channel_code (canonical_customer_id, channel_code)
    WHERE is_current = TRUE;

-- ────────────────────────────────────────────────────────────────────────────
-- 4. Backfill — populate customer_channel_code from existing wide columns
-- ────────────────────────────────────────────────────────────────────────────
INSERT INTO customer_channel_code (canonical_customer_id, channel_code, external_code, source)
SELECT id, 'ALM', alm_customer_code, 'backfill-060'
  FROM canonical_customer
 WHERE alm_customer_code IS NOT NULL
   AND alm_customer_code <> ''
ON CONFLICT (canonical_customer_id, channel_code, external_code) DO NOTHING;

INSERT INTO customer_channel_code (canonical_customer_id, channel_code, external_code, source)
SELECT id, 'DIR', dir_customer_code, 'backfill-060'
  FROM canonical_customer
 WHERE dir_customer_code IS NOT NULL
   AND dir_customer_code <> ''
ON CONFLICT (canonical_customer_id, channel_code, external_code) DO NOTHING;

INSERT INTO customer_channel_code (canonical_customer_id, channel_code, external_code, source)
SELECT id, 'YNR', ynr_customer_code, 'backfill-060'
  FROM canonical_customer
 WHERE ynr_customer_code IS NOT NULL
   AND ynr_customer_code <> ''
ON CONFLICT (canonical_customer_id, channel_code, external_code) DO NOTHING;

-- ilg + ynr_alm columns just added — backfill from them too (will be empty
-- on first apply but covers re-apply cases after ETL populates the columns)
INSERT INTO customer_channel_code (canonical_customer_id, channel_code, external_code, source)
SELECT id, 'ILG', ilg_customer_code, 'backfill-061'
  FROM canonical_customer
 WHERE ilg_customer_code IS NOT NULL
   AND ilg_customer_code <> ''
ON CONFLICT (canonical_customer_id, channel_code, external_code) DO NOTHING;

INSERT INTO customer_channel_code (canonical_customer_id, channel_code, external_code, source)
SELECT id, 'YNRALM', ynr_alm_customer_code, 'backfill-061'
  FROM canonical_customer
 WHERE ynr_alm_customer_code IS NOT NULL
   AND ynr_alm_customer_code <> ''
ON CONFLICT (canonical_customer_id, channel_code, external_code) DO NOTHING;

-- ────────────────────────────────────────────────────────────────────────────
-- 5. Post-state assertions
-- ────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    ilg_col_present INT;
    ynr_alm_col_present INT;
    ccc_row_count INT;
    expected_ccc_min INT;
BEGIN
    SELECT count(*) INTO ilg_col_present
      FROM information_schema.columns
     WHERE table_schema='public'
       AND table_name='canonical_customer'
       AND column_name='ilg_customer_code';
    IF ilg_col_present <> 1 THEN
        RAISE EXCEPTION 'canonical_customer.ilg_customer_code missing post-ALTER';
    END IF;

    SELECT count(*) INTO ynr_alm_col_present
      FROM information_schema.columns
     WHERE table_schema='public'
       AND table_name='canonical_customer'
       AND column_name='ynr_alm_customer_code';
    IF ynr_alm_col_present <> 1 THEN
        RAISE EXCEPTION 'canonical_customer.ynr_alm_customer_code missing post-ALTER';
    END IF;

    SELECT count(*) INTO ccc_row_count FROM customer_channel_code;
    -- Backfill should have produced rows for every non-null wide column
    SELECT
        (SELECT count(*) FROM canonical_customer WHERE alm_customer_code IS NOT NULL AND alm_customer_code <> '')
      + (SELECT count(*) FROM canonical_customer WHERE dir_customer_code IS NOT NULL AND dir_customer_code <> '')
      + (SELECT count(*) FROM canonical_customer WHERE ynr_customer_code IS NOT NULL AND ynr_customer_code <> '')
      + (SELECT count(*) FROM canonical_customer WHERE ilg_customer_code IS NOT NULL AND ilg_customer_code <> '')
      + (SELECT count(*) FROM canonical_customer WHERE ynr_alm_customer_code IS NOT NULL AND ynr_alm_customer_code <> '')
    INTO expected_ccc_min;

    IF ccc_row_count < expected_ccc_min THEN
        RAISE WARNING
          'customer_channel_code rowcount % below expected backfill count % — possible ON CONFLICT collisions or empty-string filter mismatch',
          ccc_row_count, expected_ccc_min;
    END IF;

    RAISE NOTICE
      'B4 schema/061 OK: ilg + ynr_alm cols added, customer_channel_code backfilled to % rows',
      ccc_row_count;
END $$;

-- Record migration (schema_migrations.version is text; columns: version, applied_at, source)
INSERT INTO schema_migrations (version, applied_at, source)
VALUES ('061_b4_customer_alias_codes', NOW(), 'live-apply')
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ════════════════════════════════════════════════════════════════════════════
-- ROLLBACK recipe (NOT part of this migration — documentation only):
--   BEGIN;
--   DROP TABLE IF EXISTS customer_channel_code;
--   DROP INDEX IF EXISTS idx_canonical_customer_ynr_alm_code;
--   DROP INDEX IF EXISTS idx_canonical_customer_ilg_code;
--   ALTER TABLE canonical_customer
--       DROP COLUMN IF EXISTS ynr_alm_customer_code,
--       DROP COLUMN IF EXISTS ilg_customer_code;
--   DELETE FROM schema_migrations WHERE version = '061';
--   COMMIT;
-- ════════════════════════════════════════════════════════════════════════════
