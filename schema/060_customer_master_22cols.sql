-- ════════════════════════════════════════════════════════════════════════════
-- schema/060_customer_master_22cols.sql
-- Bundle B4 — extend canonical_customer to Access 22-column schema (non-channel)
-- ════════════════════════════════════════════════════════════════════════════
-- Date:   2026-04-27
-- JCs:    JC-003, JC-005, JC-006, JC-007, JC-008, JC-009, JC-016, JC-027,
--         JC-028, JC-032, JC-035, JC-039, JC-051
-- Source: extract-accdb-0009 (HARD — Tier-1 Access DB schema)
--
-- Forward-only & additive: ALTER TABLE ADD COLUMN IF NOT EXISTS only. No DROP,
-- no NOT NULL on existing data. Companion 061 adds the two missing channel
-- cross-ref code columns plus the customer_channel_code lookup table.
--
-- BLAST RADIUS: canonical_customer (4,014 rows). All ADDs are nullable with
-- DEFAULT NULL (or DEFAULT FALSE for is_deleted, seeded from is_active).
-- No FK rewrites, no row deletes, no existing reads broken.
--
-- POST-STATE EXPECTED:
--   canonical_customer total cols  >= 23  (12 existing + 11 new = 23)
--   canonical_customer total rows   = 4014 (unchanged)
--   is_deleted = TRUE rows           = 10 (mirrors is_active = FALSE seed)
--   contact_category JSONB nullable  = TRUE
--   tbl_temp_customers exists        = TRUE (16 cols)
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

    -- Confirm 052_bug107 columns are present (we depend on is_active for seed)
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='public'
          AND table_name='canonical_customer'
          AND column_name='is_active'
    ) THEN
        RAISE EXCEPTION 'canonical_customer.is_active missing; schema/052 must land first';
    END IF;
END $$;

-- ────────────────────────────────────────────────────────────────────────────
-- 2. ALTER TABLE — add the 11 non-channel Access cols
--    (channel cross-ref ilg + ynr_alm land in 061)
-- ────────────────────────────────────────────────────────────────────────────
-- Width notes (verified against prod access_customers 2026-04-27):
--   Remark   max actual = 653 chars → TEXT (was VARCHAR(500), would truncate)
--   Postcode max actual =  14 chars → VARCHAR(20) (was VARCHAR(10), Australian
--            postcodes occasionally include country prefix/space)
ALTER TABLE canonical_customer
    ADD COLUMN IF NOT EXISTS customer_code      VARCHAR(100),
    ADD COLUMN IF NOT EXISTS suburb             VARCHAR(200),
    ADD COLUMN IF NOT EXISTS postcode           VARCHAR(20),
    ADD COLUMN IF NOT EXISTS territory_group    VARCHAR(200),
    ADD COLUMN IF NOT EXISTS remark             TEXT,
    ADD COLUMN IF NOT EXISTS notes              TEXT,
    ADD COLUMN IF NOT EXISTS x_customer_name    VARCHAR(500),
    ADD COLUMN IF NOT EXISTS edited_on          TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS added_on           TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS max_id             INTEGER,
    ADD COLUMN IF NOT EXISTS is_deleted         BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS contact_category   JSONB;

COMMENT ON COLUMN canonical_customer.customer_code IS
  'B4 JC-003 (2026-04-27): Master CustomerCode from Access (distinct from channel-specific cross-ref codes alm_/dir_/ilg_/ynr_/ynr_alm_).';
COMMENT ON COLUMN canonical_customer.suburb IS
  'B4 JC-003: Customer suburb (from Access Customers.Suburb).';
COMMENT ON COLUMN canonical_customer.postcode IS
  'B4 JC-003: Australian postcode (from Access Customers.Postcode).';
COMMENT ON COLUMN canonical_customer.territory_group IS
  'B4 JC-003: Territory rollup grouping (from Access Customers.TerritoryGroup).';
COMMENT ON COLUMN canonical_customer.remark IS
  'B4 JC-008: Short status remark, distinct purpose from notes (from Access Customers.Remark).';
COMMENT ON COLUMN canonical_customer.notes IS
  'B4 JC-008: Long-form free-text notes / history (from Access Customers.Notes).';
COMMENT ON COLUMN canonical_customer.x_customer_name IS
  'B4 JC-007: Source-of-truth raw imported customer name (xCustomerName) — distinct from canonical customer_name. Use for ALM/DWS feed reconciliation when canonical name differs from feed-side spelling.';
COMMENT ON COLUMN canonical_customer.edited_on IS
  'B4 JC-006: Last-edited audit timestamp (Access Customers.EditedOn).';
COMMENT ON COLUMN canonical_customer.added_on IS
  'B4 JC-006: Original-add audit timestamp (Access Customers.AddedOn).';
COMMENT ON COLUMN canonical_customer.max_id IS
  'B4 JC-006: Access surrogate audit ID (Customers.MaxID).';
COMMENT ON COLUMN canonical_customer.is_deleted IS
  'B4 JC-005: Soft-delete flag (Access Customers.IsDelete). Distinct from is_active (BUG-107) — is_deleted reflects Access source-of-truth IsDelete column; is_active reflects local soft-archive of orphan canonicals. Hard-delete forbidden per JC-005.';
COMMENT ON COLUMN canonical_customer.contact_category IS
  'B4 JC-035 + JC-051: Vinsight Sales Detail Contact Category 14 free-form tag bag, stored as JSONB array of strings. Case-folded on ingest. Examples: ["category:wholesale","custcode:ACME","price-category:standard"].';

-- ────────────────────────────────────────────────────────────────────────────
-- 3. Seed is_deleted from existing is_active (BUG-107 marked 10 inactive)
-- ────────────────────────────────────────────────────────────────────────────
UPDATE canonical_customer
   SET is_deleted = TRUE
 WHERE is_active = FALSE
   AND is_deleted = FALSE;

-- ────────────────────────────────────────────────────────────────────────────
-- 3b. Backfill new cols from access_customers.raw_data (JSONB)
--    Match key: canonical_customer.customer_name = UPPER(TRIM(xCustomerName))
--    || ' @ ' || UPPER(TRIM(Suburb)) — verified 4027/4027 access rows match.
--    Source rows where IsDelete='1' set canonical is_deleted=TRUE.
-- ────────────────────────────────────────────────────────────────────────────
WITH src AS (
  SELECT
    UPPER(TRIM(COALESCE(raw_data->>'xCustomerName',''))) ||
      CASE
        WHEN COALESCE(raw_data->>'Suburb','') <> ''
        THEN ' @ ' || UPPER(TRIM(raw_data->>'Suburb'))
        ELSE ''
      END                                              AS join_key,
    NULLIF(raw_data->>'CustomerCode','')               AS customer_code,
    NULLIF(raw_data->>'Suburb','')                     AS suburb,
    NULLIF(raw_data->>'Postcode','')                   AS postcode,
    NULLIF(raw_data->>'TerritoryGroup','')             AS territory_group,
    NULLIF(raw_data->>'Remark','')                     AS remark,
    NULLIF(raw_data->>'Notes','')                      AS notes,
    NULLIF(raw_data->>'xCustomerName','')              AS x_customer_name,
    -- Access date format: 'DD/MM/YY HH24:MI:SS' (e.g. "09/04/25 17:08:18").
    -- Regex requires MM to be 01-12 to filter out a few US-format outliers
    -- ("07/15/25" — month=15) that would crash to_timestamp. Those land NULL.
    CASE
      WHEN COALESCE(raw_data->>'EditedOn','') ~ '^\d{2}/(0[1-9]|1[0-2])/\d{2}'
      THEN to_timestamp(raw_data->>'EditedOn', 'DD/MM/YY HH24:MI:SS') AT TIME ZONE 'UTC'
      ELSE NULL
    END                                                AS edited_on,
    CASE
      WHEN COALESCE(raw_data->>'AddedOn','') ~ '^\d{2}/(0[1-9]|1[0-2])/\d{2}'
      THEN to_timestamp(raw_data->>'AddedOn', 'DD/MM/YY HH24:MI:SS') AT TIME ZONE 'UTC'
      ELSE NULL
    END                                                AS added_on,
    NULLIF(raw_data->>'MaxID','')::int                 AS max_id,
    -- IsDelete is '0' or '1' as text in the JSONB
    CASE WHEN raw_data->>'IsDelete' = '1' THEN TRUE ELSE FALSE END AS is_deleted_src
  FROM access_customers
)
UPDATE canonical_customer cc
   SET customer_code   = COALESCE(cc.customer_code,   src.customer_code),
       suburb          = COALESCE(cc.suburb,          src.suburb),
       postcode        = COALESCE(cc.postcode,        src.postcode),
       territory_group = COALESCE(cc.territory_group, src.territory_group),
       remark          = COALESCE(cc.remark,          src.remark),
       notes           = COALESCE(cc.notes,           src.notes),
       x_customer_name = COALESCE(cc.x_customer_name, src.x_customer_name),
       edited_on       = COALESCE(cc.edited_on,       src.edited_on),
       added_on        = COALESCE(cc.added_on,        src.added_on),
       max_id          = COALESCE(cc.max_id,          src.max_id),
       is_deleted      = cc.is_deleted OR src.is_deleted_src
  FROM src
 WHERE UPPER(TRIM(cc.customer_name)) = src.join_key;

-- Indexes for new lookup paths
CREATE INDEX IF NOT EXISTS idx_canonical_customer_customer_code
    ON canonical_customer (customer_code)
    WHERE customer_code IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_canonical_customer_suburb_postcode
    ON canonical_customer (suburb, postcode);

CREATE INDEX IF NOT EXISTS idx_canonical_customer_is_deleted
    ON canonical_customer (id)
    WHERE is_deleted = TRUE;

-- GIN index for JSONB tag-bag containment queries
CREATE INDEX IF NOT EXISTS idx_canonical_customer_contact_category
    ON canonical_customer USING gin (contact_category)
    WHERE contact_category IS NOT NULL;

-- ────────────────────────────────────────────────────────────────────────────
-- 4. tbl_temp_customers — JC-032 staging (16 cols matching Access schema)
-- ────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS tbl_temp_customers (
    id                 SERIAL PRIMARY KEY,
    rep                VARCHAR(200),
    territory          VARCHAR(200),
    territory_group    VARCHAR(200),
    suburb             VARCHAR(200),
    postcode           VARCHAR(10),
    customer_group     VARCHAR(200),
    channel            VARCHAR(100),
    x_customer_name    VARCHAR(500),
    is_selected        BOOLEAN NOT NULL DEFAULT FALSE,
    new_territory      VARCHAR(200),
    final_territory    VARCHAR(200),
    new_rep            VARCHAR(200),
    final_rep          VARCHAR(200),
    org_customer_name  VARCHAR(500),
    customer_name      VARCHAR(500),
    created_at         TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE tbl_temp_customers IS
  'B4 JC-032 (2026-04-27): Customer staging table mirroring Access tblTempCustomers (16 cols). Holds in-flight import rows pending territory/rep finalisation before promotion to canonical_customer.';

CREATE INDEX IF NOT EXISTS idx_tbl_temp_customers_x_name
    ON tbl_temp_customers (x_customer_name);

-- ────────────────────────────────────────────────────────────────────────────
-- 4b. staging_vinsight_contacts.is_moppity_customer — JC-033 filter flag.
--    Vinsight Contacts export contains 7,967 contacts (growers/suppliers/
--    employees/inactive); only ~4,030 are canonical Moppity customers. This
--    column lets the ETL filter applied via etl/filter_vinsight_moppity_customers.py
--    persist its decision without re-evaluating the predicate per query.
-- ────────────────────────────────────────────────────────────────────────────
ALTER TABLE staging_vinsight_contacts
    ADD COLUMN IF NOT EXISTS is_moppity_customer BOOLEAN;

COMMENT ON COLUMN staging_vinsight_contacts.is_moppity_customer IS
  'B4 JC-033 (2026-04-27): TRUE iff this Vinsight Contact is a Moppity sales customer (excludes growers, suppliers, employees, channel-transfer dummies, mail-order). Populated by etl/filter_vinsight_moppity_customers.py — NULL means not yet evaluated.';

CREATE INDEX IF NOT EXISTS idx_staging_vinsight_contacts_moppity
    ON staging_vinsight_contacts (id)
    WHERE is_moppity_customer = TRUE;

-- ────────────────────────────────────────────────────────────────────────────
-- 5. Post-state assertions
-- ────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    cc_col_count   INT;
    cc_total       INT;
    cc_deleted     INT;
    tt_col_count   INT;
BEGIN
    SELECT count(*) INTO cc_col_count
      FROM information_schema.columns
     WHERE table_schema='public' AND table_name='canonical_customer';

    SELECT count(*) INTO cc_total FROM canonical_customer;
    SELECT count(*) INTO cc_deleted FROM canonical_customer WHERE is_deleted;

    SELECT count(*) INTO tt_col_count
      FROM information_schema.columns
     WHERE table_schema='public' AND table_name='tbl_temp_customers';

    IF cc_col_count < 23 THEN
        RAISE EXCEPTION
          'canonical_customer expected >=23 cols after 11 ADDs, found %',
          cc_col_count;
    END IF;

    IF cc_total <> 4014 THEN
        RAISE WARNING
          'canonical_customer row count % (expected 4014 from BUG-107 post-state). Drift — verify before deploy.',
          cc_total;
    END IF;

    IF tt_col_count < 16 THEN
        RAISE EXCEPTION
          'tbl_temp_customers expected >=16 cols, found %', tt_col_count;
    END IF;

    RAISE NOTICE
      'B4 schema/060 OK: canonical_customer cols=%, total=%, is_deleted=%, tbl_temp_customers cols=%',
      cc_col_count, cc_total, cc_deleted, tt_col_count;
END $$;

-- Record migration (schema_migrations.version is text; columns: version, applied_at, source)
INSERT INTO schema_migrations (version, applied_at, source)
VALUES ('060_b4_customer_master_22cols', NOW(), 'live-apply')
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ════════════════════════════════════════════════════════════════════════════
-- ROLLBACK recipe (NOT part of this migration — documentation only):
--   BEGIN;
--   DROP TABLE IF EXISTS tbl_temp_customers;
--   DROP INDEX IF EXISTS idx_canonical_customer_contact_category;
--   DROP INDEX IF EXISTS idx_canonical_customer_is_deleted;
--   DROP INDEX IF EXISTS idx_canonical_customer_suburb_postcode;
--   DROP INDEX IF EXISTS idx_canonical_customer_customer_code;
--   ALTER TABLE canonical_customer
--       DROP COLUMN IF EXISTS contact_category,
--       DROP COLUMN IF EXISTS is_deleted,
--       DROP COLUMN IF EXISTS max_id,
--       DROP COLUMN IF EXISTS added_on,
--       DROP COLUMN IF EXISTS edited_on,
--       DROP COLUMN IF EXISTS x_customer_name,
--       DROP COLUMN IF EXISTS notes,
--       DROP COLUMN IF EXISTS remark,
--       DROP COLUMN IF EXISTS territory_group,
--       DROP COLUMN IF EXISTS postcode,
--       DROP COLUMN IF EXISTS suburb,
--       DROP COLUMN IF EXISTS customer_code;
--   DELETE FROM schema_migrations WHERE version = '060';
--   COMMIT;
-- Forward-only ALTER ADD is reversible by ALTER DROP without losing existing
-- canonical_customer rows (column data is the only loss; existing rows persist).
-- ════════════════════════════════════════════════════════════════════════════
