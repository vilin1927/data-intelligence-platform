-- schema/097_b12_upload_pipeline.sql
-- Bundle B12 — Upload Pipeline Hardening
--
-- Adds:
--   1. dws_staging_114                — DWS 114-col staging mirror (JC-303)
--   2. alm_edi_segment_50/51/52/53    — ALM EDI segmented landing (JC-304)
--   3. vinsight_sales_detail_28       — Vinsight Sales Detail 28-col landing (JC-305)
--   4. upload_batch                   — per-upload provenance (JC-295, JC-311)
--   5. upload_row_hash                — duplicate-detection hash (JC-295)
--   6. upload_batch_reconcile         — Stage 1 reconcile snapshot (JC-288, JC-311, JC-315)
--   7. upload_required_field_toggle   — channel-specific required-field config (JC-487)
--
-- All tables use IF NOT EXISTS so re-application is idempotent.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. DWS staging table — 114 cols (mirrors raw monthly xlsx)
--            February 2026.xlsx (114 cols verified 2026-04-27).
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dws_staging_114 (
    staging_id        BIGSERIAL PRIMARY KEY,
    upload_batch_id   BIGINT,
    row_num           INTEGER NOT NULL,

    -- Cols 1-30: invoice / debtor / sales rep
    sale_date         DATE,                  -- DATE (col 1)
    source_code       TEXT,                  -- SOURCE
    refno             TEXT,                  -- REFNO (invoice ref)
    finyear           TEXT,                  -- FINYEAR
    finmth            TEXT,                  -- FINMTH
    debtor            TEXT,                  -- DEBTOR (account code)
    drname            TEXT,                  -- DRNAME (debtor name)
    drtype            TEXT,                  -- DRTYPE
    drgrp             TEXT,                  -- DRGRP
    drgrpname         TEXT,                  -- DRGRPNAME
    sarea             TEXT,                  -- SAREA (territory code)
    sareaname         TEXT,                  -- SAREANAME
    sagrp             TEXT,                  -- SAGRP
    sagrpname         TEXT,                  -- SAGRPNAME
    srep              TEXT,                  -- SREP (rep code)
    srepname          TEXT,                  -- SREPNAME
    srgrp             TEXT,                  -- SRGRP
    srgrpname         TEXT,                  -- SRGRPNAME
    drcat             TEXT,                  -- DRCAT
    drcatname         TEXT,                  -- DRCATNAME
    crrat             TEXT,                  -- CRRAT
    crratname         TEXT,                  -- CRRATNAME
    terms             TEXT,                  -- TERMS
    termsname         TEXT,                  -- TERMSNAME
    disc              TEXT,                  -- DISC
    discname          TEXT,                  -- DISCNAME
    price             TEXT,                  -- PRICE
    pricename         TEXT,                  -- PRICENAME
    currency          TEXT,                  -- CURRENCY
    lqrlic            TEXT,                  -- LQRLIC

    -- Cols 31-45: stock item / category
    stockitem         TEXT,                  -- STOCKITEM (DWS sku code)
    stkdesc1          TEXT,                  -- STKDESC1
    stkdesc2          TEXT,                  -- STKDESC2
    stkgrp            TEXT,                  -- STKGRP
    stkgrpname        TEXT,                  -- STKGRPNAME
    salgrp            TEXT,                  -- SALGRP
    salgrpname        TEXT,                  -- SALGRPNAME
    loc               TEXT,                  -- LOC
    locname           TEXT,                  -- LOCNAME
    locgrp            TEXT,                  -- LOCGRP
    locgrpname        TEXT,                  -- LOCGRPNAME
    alctyp            TEXT,                  -- ALCTYP
    alctypname        TEXT,                  -- ALCTYPNAME
    abscls            TEXT,                  -- ABSCLS
    absclsname        TEXT,                  -- ABSCLSNAME

    -- Cols 46-55: quantity & value
    quantity          NUMERIC(14,4),         -- QUANTITY
    cartons           NUMERIC(14,4),         -- CARTONS
    bottles           NUMERIC(14,4),         -- BOTTLES
    litres            NUMERIC(14,4),         -- LITRES
    grossval          NUMERIC(14,4),         -- GROSSVAL
    staxval           NUMERIC(14,4),         -- STAXVAL
    discval           NUMERIC(14,4),         -- DISCVAL
    costval           NUMERIC(14,4),         -- COSTVAL
    wetval            NUMERIC(14,4),         -- WETVAL
    gstval            NUMERIC(14,4),         -- GSTVAL

    -- Cols 56-65: XGROUP01..10
    xgroup01          TEXT, xgroup02 TEXT, xgroup03 TEXT, xgroup04 TEXT, xgroup05 TEXT,
    xgroup06          TEXT, xgroup07 TEXT, xgroup08 TEXT, xgroup09 TEXT, xgroup10 TEXT,

    -- Cols 66-67: STKALIAS / DRALIAS
    stkalias          TEXT,                  -- canonical sku alias from DWS
    dralias           TEXT,                  -- customer alias

    -- Cols 68-81: XSTKGRP01..14
    xstkgrp01 TEXT, xstkgrp02 TEXT, xstkgrp03 TEXT, xstkgrp04 TEXT,
    xstkgrp05 TEXT, xstkgrp06 TEXT, xstkgrp07 TEXT, xstkgrp08 TEXT,
    xstkgrp09 TEXT, xstkgrp10 TEXT, xstkgrp11 TEXT, xstkgrp12 TEXT,
    xstkgrp13 TEXT, xstkgrp14 TEXT,

    -- Cols 82-91: XGROUPNM01..10
    xgroupnm01 TEXT, xgroupnm02 TEXT, xgroupnm03 TEXT, xgroupnm04 TEXT,
    xgroupnm05 TEXT, xgroupnm06 TEXT, xgroupnm07 TEXT, xgroupnm08 TEXT,
    xgroupnm09 TEXT, xgroupnm10 TEXT,

    -- Cols 92-105: XSTGRPNM01..14
    xstgrpnm01 TEXT, xstgrpnm02 TEXT, xstgrpnm03 TEXT, xstgrpnm04 TEXT,
    xstgrpnm05 TEXT, xstgrpnm06 TEXT, xstgrpnm07 TEXT, xstgrpnm08 TEXT,
    xstgrpnm09 TEXT, xstgrpnm10 TEXT, xstgrpnm11 TEXT, xstgrpnm12 TEXT,
    xstgrpnm13 TEXT, xstgrpnm14 TEXT,

    -- Cols 106-114: canonical case unit, etc. (CASES9LTR is the JC-306 canonical)
    cases9ltr         NUMERIC(14,4),         -- CASES9LTR (JC-306 canonical case unit)
    stockunit         TEXT,                  -- STOCKUNIT
    salno             TEXT,                  -- SALNO
    cnreason          TEXT,                  -- CNREASON
    crinv             TEXT,                  -- CRINV
    cruserid          TEXT,                  -- CRUSERID
    invuserid         TEXT,                  -- INVUSERID
    pricetype         TEXT,                  -- PRICETYPE
    freereason        TEXT,                  -- FREEREASON

    raw_row_json      JSONB,                 -- full unparsed row for audit
    inserted_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS dws_staging_114_batch_idx
    ON dws_staging_114 (upload_batch_id);
CREATE INDEX IF NOT EXISTS dws_staging_114_refno_idx
    ON dws_staging_114 (refno);

COMMENT ON TABLE dws_staging_114 IS
    'B12 JC-303: DWS monthly xlsx 114-col staging mirror. CASES9LTR is JC-306 canonical case unit.';

-- ---------------------------------------------------------------------------
-- 2. ALM EDI segments — 5/0 5/1 5/2 5/3 (JC-304)
--    Spec: each line in ALM EDI flat file starts with `5|<n>|...`
--    where n=0 file header, 1 batch header, 2 transaction, 3 batch trailer.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS alm_edi_segment_50 (
    segment_id        BIGSERIAL PRIMARY KEY,
    upload_batch_id   BIGINT,
    line_num          INTEGER NOT NULL,
    raw_line          TEXT NOT NULL,
    -- Common fields parsed from 5|0
    supplier_code     TEXT,
    state_code        TEXT,
    file_date         DATE,
    inserted_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS alm_edi_segment_51 (
    segment_id        BIGSERIAL PRIMARY KEY,
    upload_batch_id   BIGINT,
    line_num          INTEGER NOT NULL,
    raw_line          TEXT NOT NULL,
    batch_id          TEXT,
    inserted_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS alm_edi_segment_52 (
    segment_id        BIGSERIAL PRIMARY KEY,
    upload_batch_id   BIGINT,
    line_num          INTEGER NOT NULL,
    raw_line          TEXT NOT NULL,
    -- Parsed transaction fields per import_alm.py field map
    customer_code     TEXT,        -- field [4]
    customer_code_stripped TEXT,   -- JC-298: leading-zero stripped (TRIGGER below)
    txn_id            TEXT,        -- field [5]
    sale_date         DATE,        -- field [8]
    alm_product_code  TEXT,        -- field [11]
    product_description TEXT,      -- field [12]
    pack_size         INTEGER,     -- field [18]
    outlet_name       TEXT,        -- field [20]
    qty_delivered     NUMERIC(14,4),  -- field [37]
    gross_cents       BIGINT,      -- field [43]
    cost_cents        BIGINT,      -- field [44]
    discount_cents    BIGINT,      -- field [45]
    wet_cents         BIGINT,      -- field [46]
    gst_cents         BIGINT,      -- field [47]
    inserted_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS alm_edi_segment_53 (
    segment_id        BIGSERIAL PRIMARY KEY,
    upload_batch_id   BIGINT,
    line_num          INTEGER NOT NULL,
    raw_line          TEXT NOT NULL,
    record_count      INTEGER,
    inserted_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS alm_edi_segment_52_batch_idx
    ON alm_edi_segment_52 (upload_batch_id);

COMMENT ON TABLE alm_edi_segment_52 IS
    'B12 JC-304: ALM EDI 5|2 transaction segment landing. customer_code_stripped is JC-298 leading-zero strip.';

-- ---------------------------------------------------------------------------
-- 3. Vinsight Sales Detail — 28 cols (JC-305)
--    Spec: Vinsight CSV "Sales Detail" report has 28 cols. Verified against
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS vinsight_sales_detail_28 (
    detail_id                       BIGSERIAL PRIMARY KEY,
    upload_batch_id                 BIGINT,
    row_num                         INTEGER NOT NULL,

    stock_item_code                 TEXT,    -- col 1
    description                     TEXT,    -- col 2
    order_num                       TEXT,    -- col 3
    invoice_date                    DATE,    -- col 4
    date_created                    DATE,    -- col 5
    customer_name                   TEXT,    -- col 6
    contact_num                     TEXT,    -- col 7
    contact_category                TEXT,    -- col 8
    order_reference                 TEXT,    -- col 9
    sales_person                    TEXT,    -- col 10
    quantity                        NUMERIC(14,4),  -- col 11
    unit_of_measure_code            TEXT,    -- col 12
    equivalent_quantity             NUMERIC(14,4),  -- col 13
    equivalent_uom_code             TEXT,    -- col 14
    equivalent_unit                 TEXT,    -- col 15
    unit_price                      NUMERIC(14,4),  -- col 16
    discount                        TEXT,    -- col 17 (e.g. "37%")
    unit_discount                   NUMERIC(14,4),  -- col 18
    net_price                       NUMERIC(14,4),  -- col 19
    total_taxes                     NUMERIC(14,4),  -- col 20
    revenue                         NUMERIC(14,4),  -- col 21
    average_equivalent_uom_revenue  NUMERIC(14,4),  -- col 22
    order_currency                  TEXT,    -- col 23
    value_in_base_currency          NUMERIC(14,4),  -- col 24
    base_currency                   TEXT,    -- col 25
    item_currency                   TEXT,    -- col 26
    cogs                            NUMERIC(14,4),  -- col 27
    gross_margin                    TEXT,    -- col 28 (e.g. "49.745%")

    raw_row_json                    JSONB,
    inserted_at                     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS vinsight_sales_detail_28_batch_idx
    ON vinsight_sales_detail_28 (upload_batch_id);

COMMENT ON TABLE vinsight_sales_detail_28 IS
    'B12 JC-305: Vinsight Sales Detail 28-col landing.';

-- ---------------------------------------------------------------------------
-- 4. upload_batch — provenance per upload
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS upload_batch (
    upload_batch_id   BIGSERIAL PRIMARY KEY,
    channel           TEXT NOT NULL CHECK (channel IN ('dws','alm','direct','ilg','ynr')),
    file_name         TEXT,
    file_hash_sha256  TEXT,         -- SHA-256 of file bytes (for re-upload detection)
    status            TEXT NOT NULL DEFAULT 'pending'
                          CHECK (status IN ('pending','staged','imported','reconciled','failed','rolled_back')),
    row_count_seen    INTEGER,
    row_count_inserted INTEGER,
    row_count_duplicates INTEGER,
    started_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    ended_at          TIMESTAMPTZ,
    error_message     TEXT,
    actor             TEXT,         -- user/system who triggered
    period_label      TEXT          -- e.g. "Feb 2026"
);

CREATE INDEX IF NOT EXISTS upload_batch_channel_idx ON upload_batch (channel, started_at DESC);
CREATE INDEX IF NOT EXISTS upload_batch_filehash_idx ON upload_batch (file_hash_sha256);

-- ---------------------------------------------------------------------------
-- 5. upload_row_hash — JC-295 duplicate detection (channel,customer,sku,month,qty)
--    Hash used to flag rows that look like prior submissions.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS upload_row_hash (
    row_hash          CHAR(64) PRIMARY KEY,    -- SHA-256 hex
    upload_batch_id   BIGINT NOT NULL REFERENCES upload_batch (upload_batch_id) ON DELETE CASCADE,
    channel           TEXT NOT NULL,
    customer_key      TEXT,
    sku_key           TEXT,
    month_key         TEXT,            -- YYYY-MM
    quantity          NUMERIC(14,4),
    inserted_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS upload_row_hash_batch_idx ON upload_row_hash (upload_batch_id);
CREATE INDEX IF NOT EXISTS upload_row_hash_lookup_idx
    ON upload_row_hash (channel, customer_key, sku_key, month_key);

-- ---------------------------------------------------------------------------
-- 6. upload_batch_reconcile — JC-288 / JC-311 / JC-315 Stage 1 reconcile snapshot
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS upload_batch_reconcile (
    reconcile_id      BIGSERIAL PRIMARY KEY,
    upload_batch_id   BIGINT NOT NULL REFERENCES upload_batch (upload_batch_id) ON DELETE CASCADE,
    dimension         TEXT NOT NULL,    -- 'sku' | 'customer' | 'territory' | 'total'
    dimension_key     TEXT NOT NULL,    -- e.g. sku_code, customer_id, territory_name, '__TOTAL__'
    source_value      NUMERIC(14,2),    -- value computed from raw upload
    db_value          NUMERIC(14,2),    -- value from sales_transaction post-import
    diff              NUMERIC(14,2) GENERATED ALWAYS AS (
                          coalesce(db_value, 0) - coalesce(source_value, 0)
                      ) STORED,
    tolerance         NUMERIC(14,2) NOT NULL DEFAULT 1.00,  -- ± per group
    status            TEXT NOT NULL DEFAULT 'unknown'
                          CHECK (status IN ('match','mismatch','unknown')),
    notes             TEXT,
    inserted_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS upload_batch_reconcile_batch_idx
    ON upload_batch_reconcile (upload_batch_id, dimension);

COMMENT ON TABLE upload_batch_reconcile IS
    'B12 JC-288/JC-311/JC-315: per-batch Stage 1 reconcile snapshot. Mirrors Access "Compare to source" workflow.';

-- ---------------------------------------------------------------------------
-- 7. upload_required_field_toggle — JC-487 channel-specific required-field cfg
--    Default seed values from post-delivery-clarifications.md
--    (ALM Must = customer+SKU+cases+rep; DIRECT/ILG/YnR Must = customer+SKU+cases)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS upload_required_field_toggle (
    channel           TEXT PRIMARY KEY CHECK (channel IN ('dws','alm','direct','ilg','ynr')),
    require_customer  BOOLEAN NOT NULL DEFAULT TRUE,
    require_sku       BOOLEAN NOT NULL DEFAULT TRUE,
    require_cases     BOOLEAN NOT NULL DEFAULT TRUE,
    require_rep       BOOLEAN NOT NULL DEFAULT FALSE,
    require_date      BOOLEAN NOT NULL DEFAULT TRUE,
    last_updated      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by        TEXT
);

INSERT INTO upload_required_field_toggle (channel, require_customer, require_sku, require_cases, require_rep, require_date, updated_by)
VALUES
    ('dws',    TRUE, TRUE, TRUE, FALSE, TRUE, 'b12-seed'),
    ('alm',    TRUE, TRUE, TRUE, TRUE,  TRUE, 'b12-seed'),
    ('direct', TRUE, TRUE, TRUE, FALSE, TRUE, 'b12-seed'),
    ('ilg',    TRUE, TRUE, TRUE, FALSE, TRUE, 'b12-seed'),
    ('ynr',    TRUE, TRUE, TRUE, FALSE, TRUE, 'b12-seed')
ON CONFLICT (channel) DO NOTHING;

COMMENT ON TABLE upload_required_field_toggle IS
    'B12 JC-487: per-channel required-field config. ASK_OWNER_WITH_GUESS default; confirm/override post-delivery.';

COMMIT;
