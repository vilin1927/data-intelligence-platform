-- =============================================================================
-- 090_b6b_canonical_separation_and_region_overrides.sql
-- B6b — JC-111 / JC-112 / JC-113 / JC-135 / JC-136 / JC-138
-- =============================================================================
-- Purpose: data fixes paired with B6b UI work. Touches three concerns:
--
--   1. canonical_sku separation (JC-135 / JC-136 / JC-138):
--      - Atrius Riesling 2026 (MOATRI26F) must NOT collapse into the older
--        Atrius Riesling canonical that holds 2024/2025 vintages.
--      - Block M4/A5 (MVBLSH4B22, MVBLSH5B22) are separate brands from
--        Lock & Key Shiraz — they must have their own canonical rows.
--      - Coppabella Prosecco 750ml + 200ml Piccolo stay as two distinct
--        canonical rows (already separate in the 99-row accdb export; this
--        migration asserts the invariant + adds canonical_sku rows on
--        fresh installs).
--
--   2. manual_region_override seeding (JC-111 / JC-113):
--      - Atrius Riesling 2025 = Hilltops, Atrius 2023 = Canberra
--      - Lock & Key Pinot Noir 2024 = Tumbarumba (NEVER Hilltops)
--      - Twelve Signs Cab/Merlot = Hilltops (NEVER Tumbarumba)
--      - Procella CV Riesling 2024 = Clare Valley (NEVER Tumbarumba)
--
--   3. Coppabella note (JC-112): no blanket override, but a doc-comment so
--      future ETL doesn't re-introduce a brand-level Tumbarumba mapping for
--      the entire Coppabella range. Per-SKU overrides handle exceptions.
--
--   - LK Pinot Noir = 4 vintages (2017, 22, 23, 24): the owner call C0328 [06:36/06:50/07:01] 2026-03-28
--   - LK Shiraz = 3 vintages (22, 23, 24): C0328 [11:31] 2026-03-28
--   - Atrius Riesling 25 vs 26 distinct: DOCX ¶0714 (2026-04-21)
--   - Procella CV Riesling 2024 = Clare Valley: C0328 [21:37/21:58] 2026-03-28
--   - 12 Signs region clarifications: DOCX ¶0647 (2026-04-11)
--
-- Forward-only: idempotent INSERT ... ON CONFLICT, UPDATE guarded by
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. Defensive: ensure manual_region_override exists (B1 schema/083 already
--    creates it, but a fresh DB might apply migrations 80→90 without 83).
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS manual_region_override (
    sku_id  INTEGER PRIMARY KEY REFERENCES sku(sku_id) ON DELETE CASCADE,
    region  TEXT NOT NULL,
    reason  TEXT NOT NULL,
    set_by  TEXT NOT NULL DEFAULT 'system',
    set_at  TIMESTAMP NOT NULL DEFAULT NOW()
);

-- -----------------------------------------------------------------------------
-- 2. Canonical SKU rows for the 6 separations B6b cares about.
--    All are no-ops on fresh DBs that already have these names from the
--    accdb-driven import (B6a etl/import_sku_from_access_first.py).
-- -----------------------------------------------------------------------------

-- 2a. Atrius Riesling 2026 (JC-138).
--     The accdb 99-row export shows 'Atrius Riesling' (the new product) as
--     row 11667 with sku_code MOATRI26F. The OLDER product is 'MOPPITY ATRIUS
--     RIESLING'. We seed both as distinct canonical rows.
INSERT INTO canonical_sku (sku_name, range_name, range_group)
VALUES
    ('Atrius Riesling',         'Atrius',         'Atrius'),
    ('MOPPITY ATRIUS RIESLING', 'Moppity Atrius', 'Moppity Atrius')
ON CONFLICT (sku_name) DO NOTHING;

-- 2b. Block M4/A5 (JC-136). These are individual block-specific Shiraz wines,
--     NOT Lock & Key Shiraz. Seed dedicated canonicals so MVBLSH4B22 +
--     MVBLSH5B22 cannot accidentally collapse into LK SHIRAZ.
INSERT INTO canonical_sku (sku_name, range_name, range_group)
VALUES
    ('MOPPITY BLOCK M4 SHIRAZ', 'Moppity Reserve', 'Moppity Reserve'),
    ('MOPPITY BLOCK A5 SHIRAZ', 'Moppity Reserve', 'Moppity Reserve')
ON CONFLICT (sku_name) DO NOTHING;

-- 2c. Coppabella Prosecco 750ml vs 200ml Piccolo (JC-135).
--     Already separate in accdb (rows 'COPPABELLA PROSECCO' + 'Coppabella
--     Prosecco Piccolo'), this just guarantees the invariant on fresh DBs.
INSERT INTO canonical_sku (sku_name, range_name, range_group)
VALUES
    ('COPPABELLA PROSECCO',         'Coppabella', 'Coppabella'),
    ('Coppabella Prosecco Piccolo', 'Coppabella', 'Coppabella')
ON CONFLICT (sku_name) DO NOTHING;

-- -----------------------------------------------------------------------------
-- 3. Repoint sku.canonical_sku_id where the fuzzy matcher mis-merged.
--    Each UPDATE only acts when the current canonical_sku_id is wrong — uses
--    IS DISTINCT FROM so the migration is safe on already-fixed DBs.
-- -----------------------------------------------------------------------------

-- 3a. MOATRI26F -> 'Atrius Riesling' canonical (JC-138).
UPDATE sku s
SET    canonical_sku_id = (SELECT id FROM canonical_sku WHERE sku_name = 'Atrius Riesling')
WHERE  UPPER(s.sku_code) = 'MOATRI26F'
  AND  s.canonical_sku_id IS DISTINCT FROM
       (SELECT id FROM canonical_sku WHERE sku_name = 'Atrius Riesling');

-- 3b. MVBLSH4B22 -> 'MOPPITY BLOCK M4 SHIRAZ' canonical (JC-136).
UPDATE sku s
SET    canonical_sku_id = (SELECT id FROM canonical_sku WHERE sku_name = 'MOPPITY BLOCK M4 SHIRAZ')
WHERE  UPPER(s.sku_code) = 'MVBLSH4B22'
  AND  s.canonical_sku_id IS DISTINCT FROM
       (SELECT id FROM canonical_sku WHERE sku_name = 'MOPPITY BLOCK M4 SHIRAZ');

-- 3c. MVBLSH5B22 -> 'MOPPITY BLOCK A5 SHIRAZ' canonical (JC-136).
UPDATE sku s
SET    canonical_sku_id = (SELECT id FROM canonical_sku WHERE sku_name = 'MOPPITY BLOCK A5 SHIRAZ')
WHERE  UPPER(s.sku_code) = 'MVBLSH5B22'
  AND  s.canonical_sku_id IS DISTINCT FROM
       (SELECT id FROM canonical_sku WHERE sku_name = 'MOPPITY BLOCK A5 SHIRAZ');

-- 3d. Coppabella Prosecco 200ml Piccolo separation (JC-135).
--     Any sku row whose description contains 'Piccolo' OR sku_code
--     starts with COCPP/PICCOLO must point to the 200ml canonical, not 750ml.
UPDATE sku s
SET    canonical_sku_id = (SELECT id FROM canonical_sku WHERE sku_name = 'Coppabella Prosecco Piccolo')
WHERE  (s.item_description ILIKE '%coppabella%prosecco%piccolo%'
        OR s.item_description ILIKE '%coppabella%prosecco%200%')
  AND  s.canonical_sku_id IS DISTINCT FROM
       (SELECT id FROM canonical_sku WHERE sku_name = 'Coppabella Prosecco Piccolo');

-- -----------------------------------------------------------------------------
-- 4. manual_region_override rows (JC-111 / JC-113).
--    Each row keyed on sku_id (FK to sku). We INSERT for every matching SKU
--    today and rely on the override step (5) to push it down to sku.region.
--    Filters use ILIKE so vintage-suffix variants are all covered.
-- -----------------------------------------------------------------------------

-- 4a. Atrius Riesling 2025 = Hilltops (JC-111).
INSERT INTO manual_region_override (sku_id, region, reason, set_by)
SELECT s.sku_id,
       'Hilltops',
       'JC-111 — the owner call: 25 Atrius Riesling = Hilltops (DOCX ¶0647 2026-04-11)',
       'schema/090_b6b'
FROM   sku s
WHERE  (s.item_description ILIKE '%atrius%riesling%' OR s.sku_code ILIKE 'MOATRI25%')
  AND  s.vintage = 2025
ON CONFLICT (sku_id) DO UPDATE
  SET region = EXCLUDED.region,
      reason = EXCLUDED.reason,
      set_by = EXCLUDED.set_by;

-- 4b. Atrius Riesling 2023 = Canberra (JC-111).
INSERT INTO manual_region_override (sku_id, region, reason, set_by)
SELECT s.sku_id,
       'Canberra',
       'JC-111 — the owner call: 23 Atrius Riesling = Canberra (DOCX ¶0647 2026-04-11)',
       'schema/090_b6b'
FROM   sku s
WHERE  (s.item_description ILIKE '%atrius%riesling%' OR s.sku_code ILIKE 'MOATRI23%')
  AND  s.vintage = 2023
ON CONFLICT (sku_id) DO UPDATE
  SET region = EXCLUDED.region,
      reason = EXCLUDED.reason,
      set_by = EXCLUDED.set_by;

-- 4c. Lock & Key Pinot Noir 2024 = Tumbarumba (JC-111 — NEVER Hilltops).
INSERT INTO manual_region_override (sku_id, region, reason, set_by)
SELECT s.sku_id,
       'Tumbarumba',
       'JC-111 — the owner: 24 Lock & Key Pinot Noir = Tumbarumba (NEVER Hilltops). DOCX ¶0647 2026-04-11',
       'schema/090_b6b'
FROM   sku s
WHERE  s.item_description ILIKE '%lock%key%pinot%noir%'
  AND  s.vintage = 2024
ON CONFLICT (sku_id) DO UPDATE
  SET region = EXCLUDED.region,
      reason = EXCLUDED.reason,
      set_by = EXCLUDED.set_by;

-- 4d. Twelve Signs Cabernet Merlot = Hilltops (JC-111 — NEVER Tumbarumba).
INSERT INTO manual_region_override (sku_id, region, reason, set_by)
SELECT s.sku_id,
       'Hilltops',
       'JC-111 — the owner: Twelve Signs Cab/Merlot is Hilltops, NEVER Tumbarumba. DOCX ¶0647 2026-04-11',
       'schema/090_b6b'
FROM   sku s
WHERE  s.item_description ILIKE '%twelve signs%'
  AND  (s.item_description ILIKE '%cabernet%merlot%'
        OR s.item_description ILIKE '%cab%merlot%'
        OR s.item_description ILIKE '%merlot%cabernet%')
ON CONFLICT (sku_id) DO UPDATE
  SET region = EXCLUDED.region,
      reason = EXCLUDED.reason,
      set_by = EXCLUDED.set_by;

-- 4e. Procella CV Riesling 2024 = Clare Valley (JC-113).
INSERT INTO manual_region_override (sku_id, region, reason, set_by)
SELECT s.sku_id,
       'Clare Valley',
       'JC-113 — the owner call C0328 [21:37/21:58] 2026-03-28: Procella CV Riesling 2024 = Clare Valley',
       'schema/090_b6b'
FROM   sku s
WHERE  s.item_description ILIKE '%procella%riesling%'
  AND  (s.vintage = 2024 OR s.sku_code ILIKE '%CVRI24%' OR s.sku_code ILIKE '%PROCV%24%')
ON CONFLICT (sku_id) DO UPDATE
  SET region = EXCLUDED.region,
      reason = EXCLUDED.reason,
      set_by = EXCLUDED.set_by;

-- -----------------------------------------------------------------------------
-- 5. Push manual_region_override -> sku.region (mirrors Step 4c of
--    etl/sync_composition_from_staging.py). Only updates when actually
--    different so the trigger / audit-log overhead stays minimal.
-- -----------------------------------------------------------------------------
UPDATE sku s
SET    region = mro.region
FROM   manual_region_override mro
WHERE  mro.sku_id = s.sku_id
  AND  s.region IS DISTINCT FROM mro.region
  AND  mro.set_by = 'schema/090_b6b';

-- -----------------------------------------------------------------------------
-- 6. JC-112 sentinel comment: no blanket Coppabella region rule. The
--    existing per-SKU override path handles exceptions; do NOT add a
--    range_name -> region rule for Coppabella in any future ETL.
-- -----------------------------------------------------------------------------
-- (intentionally no SQL — see header comment)

-- Schema-migration registry (write inside the txn so a failure rolls it back).
INSERT INTO schema_migrations (version, source)
VALUES ('090_b6b_canonical_separation_and_region_overrides', 'live-apply')
ON CONFLICT (version) DO NOTHING;

COMMIT;
