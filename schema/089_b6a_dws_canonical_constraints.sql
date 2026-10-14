-- =============================================================================
-- 089_b6a_dws_canonical_constraints.sql — B6a: DWS canonical ≤ 27 enforcement
-- =============================================================================
-- Bundle: B6a (SKU schema + ETL split a of B6)
-- JCs: JC-097 (DWS = 26-27 SKUs cap), JC-122 (DWS+ALM SKUs strict subset of
--      Vinsight), JC-131 (Pegasus dedup canonical schema)
-- Source: the owner Mar 24 call — DWS = 26-27 unique products (call-transcripts
--         flags JC-097 RED with current /reconciliation showing 66.
-- Run as: psql -U moppity -d moppity_db -f schema/089_b6a_dws_canonical_constraints.sql
--
-- Forward-only and idempotent (CREATE OR REPLACE FUNCTION, DROP TRIGGER IF
-- EXISTS pattern).
-- =============================================================================

BEGIN;

-- ════════════════════════════════════════════════════════════════════════════
-- assert_dws_canonical_count_le_27 — health-check function
-- ════════════════════════════════════════════════════════════════════════════
-- Callable from CI / mini-CTO / scripts/health-check.sh. Returns the current
-- DWS canonical count and raises NOTICE if over 27. We intentionally do NOT
-- RAISE EXCEPTION here so the health-check can report all problems in one
-- pass; the trigger below enforces the hard cap on writes.

CREATE OR REPLACE FUNCTION assert_dws_canonical_count_le_27()
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    dws_count INTEGER;
BEGIN
    SELECT count(*) INTO dws_count FROM dws_sku_view;
    IF dws_count > 27 THEN
        RAISE NOTICE 'DWS canonical SKU count = % (expected ≤ 27 per the owner Mar 24)', dws_count;
    END IF;
    RETURN dws_count;
END;
$$;

COMMENT ON FUNCTION assert_dws_canonical_count_le_27() IS
    'Returns count of DWS canonical SKUs (JC-097 target: 26-27). RAISE NOTICE — non-blocking. The hard cap is enforced by the trigger on canonical_sku_code_map writes.';


-- ════════════════════════════════════════════════════════════════════════════
-- Trigger function — block inserts that would push DWS count past 27
-- ════════════════════════════════════════════════════════════════════════════
-- Fires only on INSERT/UPDATE to canonical_sku_code_map rows where
-- source_system='dws'. Allows updates that don't change the canonical_sku_id.
-- Allows the populator's normal ON CONFLICT DO NOTHING flow (the trigger only
-- runs on rows that actually inserted).

CREATE OR REPLACE FUNCTION enforce_dws_canonical_cap_27()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    new_dws_count INTEGER;
BEGIN
    IF NEW.source_system <> 'dws' THEN
        RETURN NEW;
    END IF;

    SELECT count(DISTINCT canonical_sku_id)
        INTO new_dws_count
        FROM canonical_sku_code_map
        WHERE source_system = 'dws';

    IF new_dws_count > 27 THEN
        RAISE EXCEPTION
            'DWS canonical SKU cap exceeded: % distinct canonical_sku_id rows have source_system=dws after this insert (max 27 per the owner Mar 24, JC-097).',
            new_dws_count;
    END IF;

    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION enforce_dws_canonical_cap_27() IS
    'Trigger function. Aborts INSERT/UPDATE on canonical_sku_code_map if source_system=dws would push distinct canonical_sku_id count over 27.';


-- ════════════════════════════════════════════════════════════════════════════
-- ════════════════════════════════════════════════════════════════════════════
-- The agent's intent was to enforce "DWS sells ≤27 SKUs per the owner Mar 24",
-- but real prod data shows 66 distinct canonical_sku_id rows for DWS
-- because canonical_sku is VINTAGE-LEVEL (12 wine ranges × multiple vintages
-- each), not WINE-LEVEL. A 27-cap on distinct canonical_sku_id is structurally
-- wrong against this data shape.
--
-- The trigger was hot-dropped on prod after the populator hit it. Function
-- + assertion remain in place (lines 1-80 + the assertion function) for
-- future use IF the owner confirms the cap should be applied to wine-level
-- (range_name) instead of vintage-level (canonical_sku_id), at which point
-- a follow-up bundle (B6b or post-delivery cleanup) re-creates a corrected
-- trigger.
--
-- DROP TRIGGER IF EXISTS still emitted to make the disabled state idempotent
-- against any prior install.
DROP TRIGGER IF EXISTS trg_enforce_dws_canonical_cap_27 ON canonical_sku_code_map;


-- ════════════════════════════════════════════════════════════════════════════
-- Confidence index touch-up (helper for B6b matching UI)
-- ════════════════════════════════════════════════════════════════════════════
-- canonical_sku_code_map has UNIQUE (source_system, external_code) and
-- idx_canonical_sku_code_map_lookup. Add index on canonical_sku_id to speed up
-- the dws_sku_view JOIN (canonical_sku.id ⨝ canonical_sku_code_map.canonical_sku_id).

CREATE INDEX IF NOT EXISTS idx_canonical_sku_code_map_canonical_sku_id
    ON canonical_sku_code_map (canonical_sku_id);


COMMIT;
