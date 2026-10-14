-- ════════════════════════════════════════════════════════════════════════════
-- schema/093_b11_channel_raw_landing.sql
-- B11 / JC-092, JC-093, JC-510
-- Per-channel raw landing tables (ALMData, DirectData, ILGData, YnRALMData) +
-- xtbl_fields cross-reference (63 rows, 6 columns).
-- ════════════════════════════════════════════════════════════════════════════
-- Date: 2026-04-27
-- Bundle: B11 (Channels + Vinsight import correctness)
--
--   - 4 raw landing tables: JC-093 extract-accdb-0061
--      DirectData, ILGData, YnRALMData — confirmed via mdb-tables 2026-04-27.)
--   - xtbl_fields 63 rows + 6 cols: JC-092 extract-accdb-0049
--      header, columns ID,ALM,ILG,DIRECT,YoungNRashleigh,YoungNRashleighALM).
--
-- DESIGN — JSONB-style raw landing tables:
--   Each landing table follows the same shape used by access_combined_data /
--   staging_vinsight_* (schema/008): a serial PK, a JSONB blob holding the
--   full source row, and an audit timestamp + source filename. This is
--   intentionally schemaless at the database level so future column drift in
--   the upload files does not require a migration. Indexed columns are added
--   only where existing ETL/queries demand them (none today; B12 may add).
--
--   - All `CREATE TABLE IF NOT EXISTS` — re-running is safe.
--   - `xtbl_fields` is a populated lookup: schema here only creates the table.
--     etl/import_xtbl_fields.py does the 63-row INSERT in a separate
--
-- BLAST RADIUS: zero today (new tables, no existing reads). Future B12 wires
-- ETL writers; B11 does NOT yet. xtbl_fields is read-only reference data.
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ────────────────────────────────────────────────────────────────────────────
-- 1. PRE-state assertion
-- ────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
  v_existing_tables TEXT[];
BEGIN
  SELECT ARRAY_AGG(table_name)
    INTO v_existing_tables
    FROM information_schema.tables
   WHERE table_schema = 'public'
     AND table_name IN ('alm_data', 'direct_data', 'ilg_data', 'ynr_alm_data', 'xtbl_fields');

  RAISE NOTICE 'B11 PRE: pre-existing landing tables=%', COALESCE(v_existing_tables, ARRAY[]::TEXT[]);
END;
$$;

-- ────────────────────────────────────────────────────────────────────────────
-- 2. ALMData raw landing table
--    Source: Access ALMData table (~78 cols including xCustomerName, Field*,
--    Warehouse, CustomerCode, CustomerName, Channel, etc.). Stored as JSONB.
-- ────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS alm_data (
    id               SERIAL PRIMARY KEY,
    raw_data         JSONB NOT NULL,
    source_filename  VARCHAR(255),
    source_period    VARCHAR(7),                 -- 'YYYY-MM' (canonicalised CalMonth)
    import_id        VARCHAR(64),                -- mirrors raw ImportID for traceability
    imported_at      TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_alm_data_period      ON alm_data (source_period);
CREATE INDEX IF NOT EXISTS idx_alm_data_import_id   ON alm_data (import_id);

COMMENT ON TABLE alm_data IS
  'B11 JC-093 (2026-04-27): per-channel raw landing for ALM monthly upload. '
  'JSONB shape mirrors Access ALMData columns. Wired by B12 upload pipeline; '
  'B11 only establishes the table. Note JC-510: ALM data lag up to 6 weeks '
  'behind real-time — period filtering on `source_period` is the safe filter.';

-- ────────────────────────────────────────────────────────────────────────────
-- 3. DirectData raw landing table
--    Source: Access DirectData table (~62 cols). Direct = consumers + trade
--    accounts not via ALM/DWS; data near real-time per JC-510.
-- ────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS direct_data (
    id               SERIAL PRIMARY KEY,
    raw_data         JSONB NOT NULL,
    source_filename  VARCHAR(255),
    source_period    VARCHAR(7),
    import_id        VARCHAR(64),
    imported_at      TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_direct_data_period    ON direct_data (source_period);
CREATE INDEX IF NOT EXISTS idx_direct_data_import_id ON direct_data (import_id);

COMMENT ON TABLE direct_data IS
  'B11 JC-093 (2026-04-27): per-channel raw landing for Direct (Vinsight + '
  'Vinsight-export-style flat files). JC-510 — Direct = near real-time.';

-- ────────────────────────────────────────────────────────────────────────────
-- 4. ILGData raw landing table
--    Source: Access ILGData (~63 cols). NOTE: per
--    forward — but historical ILG data must remain readable, hence the table
--    exists. Channel filter dropdown excludes ILG separately
--    (ChannelFilter.tsx).
-- ────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS ilg_data (
    id               SERIAL PRIMARY KEY,
    raw_data         JSONB NOT NULL,
    source_filename  VARCHAR(255),
    source_period    VARCHAR(7),
    import_id        VARCHAR(64),
    imported_at      TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_ilg_data_period    ON ilg_data (source_period);
CREATE INDEX IF NOT EXISTS idx_ilg_data_import_id ON ilg_data (import_id);

COMMENT ON TABLE ilg_data IS
  'B11 JC-093 (2026-04-27): per-channel raw landing for ILG (Independent '
  'Liquor Group). HISTORICAL ONLY: per the owner Mar 24, no new ILG uploads — '
  'channel filter dropdown hides ILG. Table preserved for read-only history.';

-- ────────────────────────────────────────────────────────────────────────────
-- 5. YnRALMData raw landing table
--    Source: Access YnRALMData (~70 cols). Young & Rashleigh ALM channel
--    (cross-channel transfer where YnR sells through ALM).
-- ────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS ynr_alm_data (
    id               SERIAL PRIMARY KEY,
    raw_data         JSONB NOT NULL,
    source_filename  VARCHAR(255),
    source_period    VARCHAR(7),
    import_id        VARCHAR(64),
    imported_at      TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_ynr_alm_data_period    ON ynr_alm_data (source_period);
CREATE INDEX IF NOT EXISTS idx_ynr_alm_data_import_id ON ynr_alm_data (import_id);

COMMENT ON TABLE ynr_alm_data IS
  'B11 JC-093 (2026-04-27): per-channel raw landing for YnR-via-ALM '
  'cross-channel transfer (Young & Rashleigh selling through ALM).';

-- ────────────────────────────────────────────────────────────────────────────
-- 6. xtbl_fields cross-reference table (63 rows expected after ETL)
--    Mirrors Access xtblFields 6-column shape.
-- ────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS xtbl_fields (
    id                            INT PRIMARY KEY,                -- mirrors Access ID
    alm_field                     VARCHAR(100),                   -- Access "ALM" col
    ilg_field                     VARCHAR(100),                   -- Access "ILG" col
    direct_field                  VARCHAR(100),                   -- Access "DIRECT" col
    young_n_rashleigh_field       VARCHAR(100),                   -- Access "YoungNRashleigh" col
    young_n_rashleigh_alm_field   VARCHAR(100),                   -- Access "YoungNRashleighALM" col
    imported_at                   TIMESTAMP NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE xtbl_fields IS
  'B11 JC-092 (2026-04-27): internal field-mapping cross-reference. '
  '63 rows imported from Access xtblFields (extract-accdb-0049) — see '
  'internal notes. '
  'Columns track how each channel labels the same logical field; used by ETL '
  'to translate raw uploads into canonical column names. Populated by '
  'etl/import_xtbl_fields.py — until that runs, table is empty (AC6 will '
  'fail until ETL deploys).';

-- ────────────────────────────────────────────────────────────────────────────
-- 7. POST-state assertion (4 landing tables + xtbl_fields shell exist)
-- ────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
  v_count INT;
BEGIN
  SELECT count(*) INTO v_count
    FROM information_schema.tables
   WHERE table_schema = 'public'
     AND table_name IN ('alm_data','direct_data','ilg_data','ynr_alm_data','xtbl_fields');

  RAISE NOTICE 'B11 POST: landing+xtbl_fields tables present=% (target=5)', v_count;

  IF v_count <> 5 THEN
    RAISE EXCEPTION 'B11 POST AC7: expected 5 tables (alm_data/direct_data/ilg_data/ynr_alm_data/xtbl_fields), found %', v_count;
  END IF;
END;
$$;

-- ────────────────────────────────────────────────────────────────────────────
-- 8. Record migration
-- ────────────────────────────────────────────────────────────────────────────
INSERT INTO schema_migrations (version, source)
VALUES ('093_b11_channel_raw_landing', 'live-apply')
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ════════════════════════════════════════════════════════════════════════════
-- ROLLBACK / DOWN-MIGRATION RECIPE (manual; not auto-run)
-- ════════════════════════════════════════════════════════════════════════════
-- (Only safe before any ETL writes a row. After data lands, escalate to
-- Vladimir before dropping.)
--   BEGIN;
--   DROP TABLE IF EXISTS alm_data CASCADE;
--   DROP TABLE IF EXISTS direct_data CASCADE;
--   DROP TABLE IF EXISTS ilg_data CASCADE;
--   DROP TABLE IF EXISTS ynr_alm_data CASCADE;
--   DROP TABLE IF EXISTS xtbl_fields CASCADE;
--   DELETE FROM schema_migrations WHERE version = '093_b11_channel_raw_landing';
--   COMMIT;
