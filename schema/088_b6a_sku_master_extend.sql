-- =============================================================================
-- 088_b6a_sku_master_extend.sql — B6a: SKU master 10-col coverage + dws_sku_view
-- =============================================================================
-- Bundle: B6a (SKU schema + ETL split a of B6)
-- JCs: JC-097 (DWS = 27 SKUs view), JC-139 (SKU master 10 cols), JC-140
--      (Wine Range canonical), JC-141 (RangeGroup canonical = 6 values)
--         = 99 rows × 10 cols: ID, SKU, Range, RangeGroup, UnitsperCase, Cogs,
--         BaseWholesale, TransferCost, Note, Units)
-- Run as: psql -U moppity -d moppity_db -f schema/088_b6a_sku_master_extend.sql
--
-- =============================================================================

BEGIN;

-- ════════════════════════════════════════════════════════════════════════════
-- Part 1 — Confirm canonical_sku 10-col coverage (idempotent ALTER ADD)
-- ════════════════════════════════════════════════════════════════════════════
-- canonical_sku already created in schema/012 with 8 business cols
--   (sku_name, range_name, range_group, units_per_case, cogs, base_wholesale,
--    transfer_cost) plus id + timestamps. Access SKU table has 10 cols including
--   Note (free-text) and Units (a derived stock-on-hand snapshot, not a master
--   attribute). We add `note` to canonical_sku for parity with Access; `units`
--   is intentionally OMITTED (it's a stock snapshot, not master data — that
--   lives in stocks_on_hand).

ALTER TABLE canonical_sku
    ADD COLUMN IF NOT EXISTS note TEXT;

COMMENT ON COLUMN canonical_sku.note IS
    'Free-text note from Access SKU.Note column (10th business field).';


-- ════════════════════════════════════════════════════════════════════════════
-- Part 2 — dws_sku_view (JC-097: DWS = 26-27 SKUs)
-- ════════════════════════════════════════════════════════════════════════════
-- Surfaces the canonical SKU rows that have ANY DWS external code mapped.
-- Used by /reconciliation page and AC2 verification:
--   SELECT count(*) FROM dws_sku_view  →  expected 26-27 (the owner's Mar 24 number)
-- Distinct on canonical_sku_id so multi-vintage DWS codes for the same canonical
-- product collapse to one row (matches the owner's "27 unique products" model).

CREATE OR REPLACE VIEW dws_sku_view AS
SELECT DISTINCT
    cs.id              AS canonical_sku_id,
    cs.sku_name,
    cs.range_name,
    cs.range_group,
    cs.units_per_case,
    cs.cogs,
    cs.base_wholesale,
    cs.transfer_cost
FROM canonical_sku cs
JOIN canonical_sku_code_map cscm
    ON cscm.canonical_sku_id = cs.id
   AND cscm.source_system = 'dws';

COMMENT ON VIEW dws_sku_view IS
    'Canonical SKUs with at least one DWS external code mapped. AC2 (B6): row count must be 26 or 27 (was 66 pre-B6a). Distinct on canonical_sku_id collapses vintage-specific DWS codes to their canonical product.';


COMMIT;
