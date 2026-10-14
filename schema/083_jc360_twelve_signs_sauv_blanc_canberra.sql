-- =============================================================================
-- 083_jc360_twelve_signs_sauv_blanc_canberra.sql
-- JC-360: Fix region for Twelve Signs Sauvignon Blanc — Canberra, not Hilltops
-- =============================================================================
-- Source: the owner on call C0328 [18:54], 2026-03-28: "12 Signs Sauv Blanc region
-- Data Source Trust rule.
--
-- Why a manual override (not a brand rule change): Twelve Signs reds *are*
-- Hilltops; only the Sauv Blanc is Canberra-grown. Brand-level rule in
-- etl/sync_composition_from_staging.py (Step 4b) maps the entire Twelve Signs
-- range to Hilltops. The cleanest precedence-aware fix is per-SKU in
-- manual_region_override — Step 4c re-applies it on every composition sync.
--
-- Forward-only: idempotent INSERT ... ON CONFLICT, plus an immediate UPDATE
-- on sku so the override is visible without waiting for the next ETL run.
-- =============================================================================

BEGIN;

-- Defensive: ensure the override table exists on fresh installs.
-- (Columns match the existing prod schema seeded by an earlier migration:
--  sku_id PK, region NOT NULL, reason NOT NULL, set_by DEFAULT 'system',
--  set_at DEFAULT now().)
CREATE TABLE IF NOT EXISTS manual_region_override (
    sku_id  INTEGER PRIMARY KEY REFERENCES sku(sku_id) ON DELETE CASCADE,
    region  TEXT NOT NULL,
    reason  TEXT NOT NULL,
    set_by  TEXT NOT NULL DEFAULT 'system',
    set_at  TIMESTAMP NOT NULL DEFAULT NOW()
);

-- Insert override rows for every Twelve Signs Sauvignon Blanc SKU
-- (covers all vintages: 22F, 23F, 24F, 25F + any future drop).
INSERT INTO manual_region_override (sku_id, region, reason, set_by)
SELECT s.sku_id,
       'Canberra',
       'JC-360 — the owner call C0328 [18:54] 2026-03-28: 12 Signs Sauv Blanc is Canberra-grown',
       'schema/083_jc360'
FROM sku s
WHERE s.item_description ILIKE '%twelve signs%'
  AND s.item_description ILIKE '%sauv%blanc%'
ON CONFLICT (sku_id) DO UPDATE
  SET region = EXCLUDED.region,
      reason = EXCLUDED.reason,
      set_by = EXCLUDED.set_by;

-- Apply the override to sku.region immediately (mirrors Step 4c of
-- etl/sync_composition_from_staging.py so the dashboard reflects the fix
-- without waiting for the next nightly sync).
UPDATE sku s
SET    region = mro.region
FROM   manual_region_override mro
WHERE  mro.sku_id = s.sku_id
  AND  s.region IS DISTINCT FROM mro.region;

-- Verification — should show 1+ rows, region = 'Canberra'.
SELECT s.sku_code, s.item_description, s.region
FROM sku s
WHERE s.item_description ILIKE '%twelve signs%'
  AND s.item_description ILIKE '%sauv%blanc%'
ORDER BY s.sku_code;

COMMIT;

-- Schema migration log (cols: version, applied_at, source — verified prod schema)
INSERT INTO schema_migrations (version, applied_at, source)
VALUES ('083_jc360_twelve_signs_sauv_blanc_canberra',
        NOW(),
        'live-apply')
ON CONFLICT (version) DO NOTHING;
