-- =============================================================================
-- Moppity Vineyards — Salesperson Code Map (038_salesperson_code_map.sql)
-- =============================================================================
-- Task: BUG-34 (Vinsight Contacts ETL drops 99% enrichment fields)
--
-- Problem:
--   Vinsight Contacts carry DefaultSalesPersonNum (numeric FK back to another
--   Vinsight contact where IsSalesOperator=true). That salesperson contact's
--   ContactCode is the canonical code (e.g. ADRIANMA, ADAMCOX, TMAULE) that
--   The owner refers to in reports. We need a stable lookup from sp_code to
--   representative.rep_id so the Contacts ETL can populate customer.rep_id.
--
-- Scope:
--   Forward-only (CREATE TABLE IF NOT EXISTS). Does not mutate existing tables.
-- =============================================================================

BEGIN;

CREATE TABLE IF NOT EXISTS salesperson_code_map (
    sp_code     VARCHAR(50)  PRIMARY KEY,            -- e.g. ADRIANMA, TMAULE
    sp_num      INTEGER      UNIQUE,                 -- Vinsight ContactNum
    rep_id      INTEGER      REFERENCES representative(rep_id),
    sp_name     VARCHAR(200),                        -- display name from contact
    source      VARCHAR(50)  NOT NULL DEFAULT 'vinsight',
    created_at  TIMESTAMP    NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMP    NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE  salesperson_code_map IS
    'Maps Vinsight sales-person codes (ContactCode where IsSalesOperator=true) '
    'and numeric ids (ContactNum) to representative.rep_id. Populated by '
    'etl/backfill_vinsight_contact_enrichment.py from staging_vinsight_contacts.';

COMMENT ON COLUMN salesperson_code_map.sp_code IS
    'Vinsight ContactCode for the salesperson contact (e.g. ADRIANMA, ADAMCOX).';
COMMENT ON COLUMN salesperson_code_map.sp_num  IS
    'Vinsight ContactNum for the salesperson contact. DefaultSalesPersonNum on '
    'a customer contact matches this column.';
COMMENT ON COLUMN salesperson_code_map.rep_id  IS
    'FK to representative. Nullable while we build the mapping; fuzzy-matched '
    'against rep_name (case-insensitive, trimmed).';

CREATE INDEX IF NOT EXISTS idx_sp_code_map_num ON salesperson_code_map (sp_num);
CREATE INDEX IF NOT EXISTS idx_sp_code_map_rep ON salesperson_code_map (rep_id);

COMMIT;
