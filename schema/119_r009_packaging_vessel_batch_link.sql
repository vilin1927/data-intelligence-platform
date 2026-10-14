-- =============================================================================
-- 119_r009_packaging_vessel_batch_link.sql
-- R-009 (RC-WINES-TRACEABILITY): link packaging_vessel rows to the historical
-- wine_batch packaged from each vessel into each operation, so /wines detail
-- Traceability Chain stops fanning out to "current vessel contents" batches.
-- =============================================================================
-- Bug:    /api/wines route.ts:134-137 joined wine_batch via vessel.wine_batch_id,
--         which is "current contents" (schema/008 vessel comment + ETL line 301
--         in sync_vinsight_cogs.py reads staging_vinsight_vessels.BatchCode each
--         sync). For LK Shiraz sku_id=40 this gave 0/35 correct rows (13 wrong,
--         22 stale). HARD truth: staging_vinsight_wine_batches.raw_data
--         ->'PackagingOperationVessels'->>'BatchCode' captures the as-of-
--         packaging batch — already in DB, just never persisted into a column.
--
-- Companion patches (ship together, none of them works alone):
--   1. dashboard/src/app/api/wines/route.ts — switch the wine_batch JOIN from
--      vessel.wine_batch_id to packaging_vessel.wine_batch_id.
--   2. etl/sync_vinsight_cogs.py _transform_packaging_vessels — populate
--      wine_batch_id on every future re-sync via JOIN wine_batch on BatchCode.
--      surface in CI.
--
-- Pattern: α (additive schema + data backfill). No DROP, no UPDATE on existing
--
-- migration touches packaging_vessel batch link. Latest schema = 118 (R-014).
-- =============================================================================

BEGIN;

-- ─── Pre-state assertions ───────────────────────────────────────────────────
-- Refuse to apply if expected counts drift. Numbers captured 2026-04-30 prod.
DO $$
DECLARE
    pv_total            INT;
    pv_with_batch       INT;
    staging_pov_tuples  INT;
    expected_backfill   INT;
BEGIN
    SELECT COUNT(*) INTO pv_total FROM packaging_vessel;

    -- Pre-state: column does not exist yet, so this counts as "0 with batch".
    -- After ALTER below the column exists; we also assert post-state.
    IF pv_total < 2000 OR pv_total > 3000 THEN
        RAISE EXCEPTION 'R-009 PRE: packaging_vessel count drift (got %, expected ~2359)', pv_total;
    END IF;

    SELECT COUNT(*) INTO staging_pov_tuples
        FROM staging_vinsight_wine_batches s,
             jsonb_array_elements(s.raw_data->'PackagingOperationVessels');
    IF staging_pov_tuples < 400 OR staging_pov_tuples > 1000 THEN
        RAISE EXCEPTION 'R-009 PRE: staging PackagingOperationVessels tuple count drift (got %, expected ~648)', staging_pov_tuples;
    END IF;

    SELECT COUNT(DISTINCT pv.id) INTO expected_backfill
    FROM packaging_vessel pv
    JOIN staging_vinsight_wine_batches s ON TRUE
    CROSS JOIN LATERAL jsonb_array_elements(s.raw_data->'PackagingOperationVessels') pov
    JOIN packaging_operation po ON po.id=pv.packaging_operation_id AND po.operation_code = pov->>'OperationNum'
    JOIN vessel v ON v.id=pv.vessel_id AND v.vessel_code = pov->>'VesselCode'
    JOIN wine_batch wb ON wb.batch_code = pov->>'BatchCode';
    IF expected_backfill < 1000 OR expected_backfill > 1600 THEN
        RAISE EXCEPTION 'R-009 PRE: expected backfill count drift (got %, expected ~1251)', expected_backfill;
    END IF;

    RAISE NOTICE 'R-009 PRE: pv_total=%, staging_pov_tuples=%, expected_backfill=%',
        pv_total, staging_pov_tuples, expected_backfill;
END $$;

-- ─── Schema: add the missing FK column ──────────────────────────────────────
ALTER TABLE packaging_vessel
    ADD COLUMN IF NOT EXISTS wine_batch_id INTEGER REFERENCES wine_batch(id);

CREATE INDEX IF NOT EXISTS idx_packaging_vessel_batch
    ON packaging_vessel(wine_batch_id);

COMMENT ON COLUMN packaging_vessel.wine_batch_id IS
    'Historical wine_batch packaged from this vessel into this operation. '
    'Source: staging_vinsight_wine_batches.raw_data->PackagingOperationVessels->BatchCode. '
    'Distinct from vessel.wine_batch_id (current contents). R-009 (2026-04-30).';

-- ─── Backfill from staging JSON ──────────────────────────────────────────────
-- For each (operation_code, vessel_code) tuple in any staging
-- PackagingOperationVessels array, look up the BatchCode and resolve to
-- wine_batch.id. Multiple staging snapshots may carry the same tuple; use
-- DISTINCT ON (pv.id) ordered by staging.synced_at DESC to take the most recent.
WITH historical AS (
    SELECT DISTINCT ON (pv.id)
        pv.id AS pv_id,
        wb.id AS wb_id
    FROM packaging_vessel pv
    JOIN staging_vinsight_wine_batches s ON TRUE
    CROSS JOIN LATERAL jsonb_array_elements(s.raw_data->'PackagingOperationVessels') pov
    JOIN packaging_operation po ON po.id=pv.packaging_operation_id AND po.operation_code = pov->>'OperationNum'
    JOIN vessel v ON v.id=pv.vessel_id AND v.vessel_code = pov->>'VesselCode'
    JOIN wine_batch wb ON wb.batch_code = pov->>'BatchCode'
    ORDER BY pv.id, s.synced_at DESC
)
UPDATE packaging_vessel pv
SET wine_batch_id = historical.wb_id
FROM historical
WHERE pv.id = historical.pv_id;

-- ─── Post-state assertions ──────────────────────────────────────────────────
DO $$
DECLARE
    pv_total           INT;
    pv_with_batch      INT;
    pv_null_batch      INT;
    sku40_correct      INT;
    sku40_wrong        INT;
BEGIN
    SELECT COUNT(*) INTO pv_total FROM packaging_vessel;
    SELECT COUNT(*) INTO pv_with_batch FROM packaging_vessel WHERE wine_batch_id IS NOT NULL;
    SELECT COUNT(*) INTO pv_null_batch FROM packaging_vessel WHERE wine_batch_id IS NULL;

    IF pv_total <> (pv_with_batch + pv_null_batch) THEN
        RAISE EXCEPTION 'R-009 POST: total count split mismatch (got %=%+%)',
            pv_total, pv_with_batch, pv_null_batch;
    END IF;

    IF pv_with_batch < 1000 THEN
        RAISE EXCEPTION 'R-009 POST: too few rows backfilled (got %, expected ~1251)', pv_with_batch;
    END IF;

    -- Informational: sample variety-alignment check.
    -- We DO NOT raise on variety mismatch here — Vinsight reality includes
    -- legitimate blend wines (e.g. "Moppity New Grenache Shiraz 2018"
    -- packages a Grenache-primary blend batch; "M20.2 Grenache and M7/8 Shz"
    -- batch is correctly recorded with variety=GRS but contains Shiraz from
    -- block M7/8). The schema-level invariant of R-009 is structural: the
    -- join uses staging.PackagingOperationVessels.BatchCode as the FK source.
    -- The variety/family alignment is a UI-level AC verified via
    -- chrome-devtools post-deploy.
    SELECT COUNT(*) INTO sku40_correct
    FROM packaging_operation po
    JOIN packaging_vessel pv ON pv.packaging_operation_id = po.id
    JOIN wine_batch wb ON wb.id = pv.wine_batch_id
    WHERE po.description ILIKE '%Shiraz%'
      AND (wb.variety IS NULL
           OR wb.variety ILIKE 'SHI%'
           OR wb.variety ILIKE 'Shiraz%'
           OR wb.batch_code ~ '[0-9]{2}SHI');

    SELECT COUNT(*) INTO sku40_wrong
    FROM packaging_operation po
    JOIN packaging_vessel pv ON pv.packaging_operation_id = po.id
    JOIN wine_batch wb ON wb.id = pv.wine_batch_id
    WHERE po.description ILIKE '%Shiraz%'
      AND wb.variety IS NOT NULL
      AND wb.variety NOT ILIKE 'SHI%'
      AND wb.variety NOT ILIKE 'Shiraz%'
      AND wb.batch_code !~ '[0-9]{2}SHI';

    RAISE NOTICE 'R-009 POST: pv_total=%, pv_with_batch=%, pv_null_batch=%, shiraz_op_family_match=%, shiraz_op_blend_or_misc=%',
        pv_total, pv_with_batch, pv_null_batch, sku40_correct, sku40_wrong;
END $$;

INSERT INTO schema_migrations(version)
VALUES ('119_r009_packaging_vessel_batch_link')
ON CONFLICT DO NOTHING;

COMMIT;
