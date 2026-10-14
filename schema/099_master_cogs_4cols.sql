-- B7b JC-202/JC-203: master_cogs replicates Access tbl_Master_COGS (636 rows × 4 cols)
-- Loader: etl/import_master_cogs_from_access.py
-- Acceptance: SELECT count(*) FROM master_cogs = 636 (extract-accdb-0026)

BEGIN;

CREATE TABLE IF NOT EXISTS master_cogs (
    id              INTEGER PRIMARY KEY,           -- Access tbl_Master_COGS.ID
    sku             TEXT    NOT NULL,              -- product description (e.g. "Coppabella Procella Chardonnay")
                                                   -- NOTE: this is Access' "SKU" column = product name, NOT sku_code.
                                                   -- Lookups join via canonical_sku.sku_name OR sku.item_description.
    financial_year  TEXT    NOT NULL,              -- AU FY string "FY_YYYY" (Jul-Jun) per extract-accdb-0028
    cogs_value      NUMERIC(10,4) NOT NULL,        -- AUD per case
    imported_at     TIMESTAMP DEFAULT NOW()
    -- NOTE: NO UNIQUE (sku, financial_year). Access tbl_Master_COGS has 6 duplicate
    -- (sku, financial_year) pairs (Atrius Shiraz × FY_2019..FY_2024, identical
    -- cogs_value 58.13). HARD-source fidelity (636 rows) wins over normalisation;
    -- importer dedups via id PK only.
);

COMMENT ON TABLE  master_cogs           IS 'Per-product per-FY standard COGS replicated from Access tbl_Master_COGS (636 rows). Uses product description as join key (not sku_code).';
COMMENT ON COLUMN master_cogs.sku       IS 'Product description verbatim from Access (e.g. "Coppabella Procella Chardonnay"). Join via canonical_sku.sku_name or sku.item_description.';
COMMENT ON COLUMN master_cogs.financial_year IS 'AU FY string "FY_YYYY" (Jul-Jun). e.g. "FY_2024" = Jul 2023 to Jun 2024.';
COMMENT ON COLUMN master_cogs.cogs_value IS 'Standard cost of goods per case in AUD.';

CREATE INDEX IF NOT EXISTS idx_master_cogs_sku
    ON master_cogs (sku);
CREATE INDEX IF NOT EXISTS idx_master_cogs_sku_fy
    ON master_cogs (sku, financial_year);

COMMIT;

--   SELECT count(*) FROM master_cogs;                            -- expect 636
--   SELECT count(DISTINCT sku) FROM master_cogs;                 -- expect ~80 distinct products
--   SELECT count(DISTINCT financial_year) FROM master_cogs;      -- expect ~8 FYs
