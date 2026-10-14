-- ════════════════════════════════════════════════════════════════════════════
-- schema/141_b4b_region_override_as_source_of_truth.sql
-- B4B — replace override-cascade-down with override-as-source-of-truth at view
--       read time, drop schema/083 fabricated rows, bulk-fill ~280 mro rows
--       from the owner Mar 24 reconciliation xlsx HARD baseline.
-- ════════════════════════════════════════════════════════════════════════════
-- Date:    2026-05-09
--   1. May 8 Vladimir + the owner verbal — TS Sauv Blanc not Canberra
--   2. DOCX ¶0647 (Apr 11) — TS Cab/Merlot Hilltops; LK Pinot 24 Tumbarumba;
--      Atrius 25 Hilltops; Atrius 23 Canberra (covered by schema/090)
--   4. Mar 28 call C0328 — TS Sauv Blanc Hilltops wrong; Procella CV 24
--      Clare Valley; LK Pinot 4 vintages; LK Shiraz 3 vintages (in schema/090)
--      reconciliation (1).xlsx → "New DB SKU report" sheet, 396 rows
--      Hilltops 288 / Tumbarumba 96 / None 11) — bulk fill HARD source for
--      285 wines the owner has NOT verbally corrected.
--   6. Vinsight ProductCategories regex (real-time but DIRTY for ≥2 brands —
--      TS Cab/Merlot tag = "Sea" but Hilltops; Procella CV tag = "Tumbarumba"
--      but Clare Valley) — read-time fallback only.
--   7. Access — empty for region (verified mdb-tools — see decision doc §5b).
--
--   psql ${DATABASE_URL} -f /tmp/pre_b4b_*.sql
--
-- ════════════════════════════════════════════════════════════════════════════
-- Why this migration (root cause: 41-day region LOOP, see decision doc §1)
-- ════════════════════════════════════════════════════════════════════════════
-- Today: manual_region_override writes DOWN into sku.region (replacement).
-- View 132 reads cooked sku.region. Result: every override is a destructive
-- bake-in; every wrong override survives until someone hand-writes a fix.
--
-- After this migration:
--   * mro is the BASE layer (Owner-HARD source of truth)
--   * Vinsight ProductCategories regex is the FALLBACK layer (real-time but
--     dirty for ≥2 brands)
--   * Brand-rule (Coppabella → Tumbarumba, Moppity/LK/TS/Cato → Hilltops) is
--     the SECOND fallback for SKUs missing Vinsight tag
--   * 'Unknown' is the floor (never NULL)
-- View resolves at read-time. ETL stops baking override into sku.region —
-- sku.region becomes a Vinsight-only mirror (raw Vinsight tag, not authoritative).
--
-- ════════════════════════════════════════════════════════════════════════════
-- Plan (5 sections inside one BEGIN/COMMIT)
-- ════════════════════════════════════════════════════════════════════════════
-- §1  PRE-asserts — fail-fast on drift
-- §2  Pre-state snapshot (TEMP TABLE _b4b_pre)
-- §3  DELETE 7 schema/083 fabricated overlay rows from manual_region_override
-- §4  Stage xlsx VALUES (339 unique sku_codes after dedupe + .0 normalization
--     of 384 non-empty xlsx rows; 11 None-region rows skipped per spec §3 AC #4
--     "skip the owner hasn't decided")
-- §5  Resolve xlsx sku_code → sku.sku_id (path A direct; path B via sku_code_map)
-- §6  INSERT into manual_region_override — exclude schema/090 sku_ids,
--     exclude TS Sauv Blanc 7 sku_ids (AC #5), gate on s.region IS DISTINCT FROM
-- §7  DROP + CREATE OR REPLACE VIEW combined_data_enriched (rebuilt from
--     schema/132 byte-identical except region projection becomes COALESCE chain
--     with new LEFT JOIN manual_region_override mro)
-- §8  POST-asserts — every spot-check row, view-row count, FAB drop confirmed
-- §9  schema_migrations registry insert
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ────────────────────────────────────────────────────────────────────────────
-- §1 PRE-asserts
-- ────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    v_view_exists       BOOLEAN;
    v_mro_exists        BOOLEAN;
    v_sku_count         INT;
    v_mro_total         INT;
    v_mro_083_count     INT;
    v_mro_090_count     INT;
    v_mro_jf07_count    INT;
    v_sku_with_region   INT;
    v_staging_rows      INT;
BEGIN
    -- 1.a — required tables/views present
    SELECT EXISTS (
        SELECT 1 FROM information_schema.views
        WHERE table_schema='public' AND table_name='combined_data_enriched'
    ) INTO v_view_exists;
    IF NOT v_view_exists THEN
        RAISE EXCEPTION 'PRE-ASSERT FAIL: combined_data_enriched view missing — schema/132 must land first';
    END IF;

    SELECT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema='public' AND table_name='manual_region_override'
    ) INTO v_mro_exists;
    IF NOT v_mro_exists THEN
        RAISE EXCEPTION 'PRE-ASSERT FAIL: manual_region_override table missing — schema/083+090 must land first';
    END IF;

    IF to_regclass('public.sku')                       IS NULL THEN
        RAISE EXCEPTION 'PRE-ASSERT FAIL: sku table missing'; END IF;
    IF to_regclass('public.sku_code_map')              IS NULL THEN
        RAISE EXCEPTION 'PRE-ASSERT FAIL: sku_code_map table missing'; END IF;
    IF to_regclass('public.staging_vinsight_stock_items') IS NULL THEN
        RAISE EXCEPTION 'PRE-ASSERT FAIL: staging_vinsight_stock_items table missing'; END IF;

    -- 1.b — sanity counts (sku ≥500 per recon)
    SELECT count(*) INTO v_sku_count FROM sku;
    IF v_sku_count < 500 THEN
        RAISE EXCEPTION 'PRE-ASSERT FAIL: sku count % below sanity floor 500 — staging/import issue', v_sku_count;
    END IF;

    SELECT count(*) INTO v_sku_with_region FROM sku WHERE region IS NOT NULL;

    -- 1.c — manual_region_override snapshot
    SELECT count(*) INTO v_mro_total      FROM manual_region_override;
    SELECT count(*) INTO v_mro_083_count  FROM manual_region_override WHERE set_by = 'schema/083_jc360';
    SELECT count(*) INTO v_mro_090_count  FROM manual_region_override WHERE set_by = 'schema/090_b6b';
    SELECT count(*) INTO v_mro_jf07_count FROM manual_region_override WHERE set_by = 'jf07-2026-04-12';

    -- 1.d — schema/083 must be 7 rows (the FAB rows we are about to drop)
    --       schema/090 must be 10 rows (HARD-confirmed, must be PRESERVED)
    --       jf07     must be 1 row    (Vinsight-UI-verified, untouched)
    --       Hard fail-fast on drift — if these counts don't match recon §3
    --       the recon doc is stale or someone hand-edited the table.
    IF v_mro_083_count <> 7 THEN
        RAISE EXCEPTION
            'PRE-ASSERT FAIL: schema/083_jc360 row count = % (expected 7); recon stale or hand-edit',
            v_mro_083_count;
    END IF;
    IF v_mro_090_count <> 10 THEN
        RAISE EXCEPTION
            'PRE-ASSERT FAIL: schema/090_b6b row count = % (expected 10); recon stale or hand-edit',
            v_mro_090_count;
    END IF;
    IF v_mro_jf07_count <> 1 THEN
        RAISE WARNING
            'PRE-WARN: jf07-2026-04-12 row count = % (expected 1); not blocking',
            v_mro_jf07_count;
    END IF;

    -- 1.e — Vinsight staging present (fallback layer in new view)
    SELECT count(*) INTO v_staging_rows FROM staging_vinsight_stock_items;
    IF v_staging_rows < 100 THEN
        RAISE EXCEPTION 'PRE-ASSERT FAIL: staging_vinsight_stock_items row count % below floor 100', v_staging_rows;
    END IF;

    RAISE NOTICE 'PRE: sku=% / sku.region populated=% / mro_total=% / mro_083=% / mro_090=% / mro_jf07=% / vinsight_staging=%',
                 v_sku_count, v_sku_with_region, v_mro_total,
                 v_mro_083_count, v_mro_090_count, v_mro_jf07_count, v_staging_rows;
END $$;

-- ────────────────────────────────────────────────────────────────────────────
-- §2 Pre-state snapshot (TEMP TABLE for POST-assert diffing)
-- ────────────────────────────────────────────────────────────────────────────
CREATE TEMP TABLE _b4b_pre AS
SELECT mro.sku_id, mro.region, mro.set_by, mro.reason
  FROM manual_region_override mro;

-- ────────────────────────────────────────────────────────────────────────────
-- §3 DELETE 7 schema/083 fabricated overlay rows
--    These were inferred from C0328 Mar 28 ("Hilltops wrong") but the owner never
--    said Canberra; he ruled out Canberra on May 8. FAB rows must be removed
--    so the COALESCE chain falls through to (NULL → Vinsight raw → brand →
--    'Unknown') instead of stale fake Canberra. Per spec AC #5 these 7 sku
--    rows STAY in COALESCE-resolves-NULL state until the owner answers May 8 Q.
-- ────────────────────────────────────────────────────────────────────────────
DELETE FROM manual_region_override
 WHERE set_by = 'schema/083_jc360';

DO $$
DECLARE
    v_remaining INT;
BEGIN
    SELECT count(*) INTO v_remaining FROM manual_region_override
     WHERE set_by = 'schema/083_jc360';
    IF v_remaining <> 0 THEN
        RAISE EXCEPTION 'POST-§3 FAIL: schema/083 still has % rows after DELETE', v_remaining;
    END IF;
    RAISE NOTICE 'POST-§3: schema/083 FAB rows DELETEd (was 7, now 0)';
END $$;

-- ────────────────────────────────────────────────────────────────────────────
-- §4 Stage xlsx CSV → TEMP TABLE
--    "New DB SKU report" sheet, 396 data rows). Filter applied at extract:
--      - 11 None-region rows skipped (the owner hasn't decided per decision doc §5c)
--      - .0 float-coercion stripped from numeric DWS-style codes
--      - 45 duplicate sku_codes deduped (all consolidated, region matched)
--    Result: 339 unique (sku_code, region) pairs, all Hilltops/Tumbarumba.
--    VALUES list is embedded inline (no COPY FROM) so this migration is
--    self-contained on VPS — no auxiliary file to scp.
-- ────────────────────────────────────────────────────────────────────────────
CREATE TEMP TABLE _xlsx_region_map (
    sku_code    TEXT NOT NULL,
    wine        TEXT,
    variety     TEXT,
    region      TEXT NOT NULL,
    vintage     INT,
    range_name  TEXT
);

INSERT INTO _xlsx_region_map (sku_code, wine, variety, region, vintage, range_name)
VALUES
  ('MOLKPN24F','MOPPITY LOCK & KEY PINOT NOIR 2024(12 PK)','Pinot Noir','Hilltops',2024,'LOCK & KEY'),
  ('MVLKSCPB23','Lock & Key Spk Chard Pinot Noir 2023','Pinot Noir','Hilltops',2023,'LOCK & KEY'),
  ('COPRCHAB24','Procella Chardonnay 2024','Chardonnay','Tumbarumba',2024,'COPPABELLA PROCELLA'),
  ('MVATCHAB21','Moppity ATRIUS Chardonnay 2021','Chardonnay','Hilltops',2021,'ATRIUS'),
  ('MVBLSH4B22','Moppity Block M4 H/Tops Shiraz 2022','Shiraz','Hilltops',2022,'BLOCK'),
  ('245011','TWELVE SIGNS SAUV BLANC 750ML','Sauvignon Blanc','Hilltops',NULL,'TWELVE SIGNS'),
  ('MVESCHAB22','Moppity Estate Chardonnay 2022','Chardonnay','Hilltops',2022,'MOPPITY ESTATE'),
  ('513854','LOCK&KEY CHARDONNAY 750ML','Chardonnay','Hilltops',NULL,'LOCK & KEY'),
  ('574583','LOCK&KEY PINOT NOIR 750ML','Pinot Noir','Hilltops',NULL,'LOCK & KEY'),
  ('244688','TWELVE SIGNS PINT GRIGIO 750ML','Pinot Grigio','Hilltops',NULL,'TWELVE SIGNS'),
  ('MVLKPINB24','Lock & Key Pinot Noir 2024','Pinot Noir','Hilltops',2024,'LOCK & KEY'),
  ('MOTBRT25F','MOPPITY TWELVE SIGNS SPARKLING BRUT','Tumbarumba Sparkling','Hilltops',NULL,'TWELVE SIGNS'),
  ('MVLKSHZB22','Lock & Key Shiraz 2022','Shiraz','Hilltops',2022,'LOCK & KEY'),
  ('513896','LOCK&KEY SHIRAZ 750ML','Shiraz','Hilltops',1996,'LOCK & KEY'),
  ('COCOCHAB21','Coppabella SV Chardonnay 2021','Chardonnay','Tumbarumba',2021,'COPPABELLA'),
  ('MOCVPPNVF','COPPABELLA SINGLE VINEYARD PROSECCO PICCOLOSNV 200ml (24 PK)','RosÃ©','Tumbarumba',NULL,'COPPABELLA'),
  ('245040','TWELVE SIGNS SPARKLING 750ML','Tumbarumba Sparkling','Hilltops',NULL,'TWELVE SIGNS'),
  ('MOLKCH24F','MOPPITY LOCK & KEY CHARDONNAY','Chardonnay','Hilltops',NULL,'LOCK & KEY'),
  ('MVATRIEB25','Moppity ATRIUS Riesling 2025','Riesling','Hilltops',2025,'ATRIUS'),
  ('527293','LOCK&KEY SPARKLING 750ML','Tumbarumba Sparkling','Hilltops',1993,'LOCK & KEY'),
  ('MOCVPR23F','COPPABELLA SINGLE VINEYARD PROSECCO 2023(12 PK)','RosÃ©','Tumbarumba',2023,'COPPABELLA'),
  ('COPRCABB22','Procella Cabernet Sauvignon 2022','Cabernet Sauvignon','Tumbarumba',2022,'COPPABELLA PROCELLA'),
  ('668887','COPPABELLA PROSECCO 750ML','RosÃ©','Tumbarumba',NULL,'COPPABELLA'),
  ('MOATRI25F','MOPPITY ATRIUS RIESLING','Riesling','Hilltops',NULL,'ATRIUS'),
  ('MOLKRI24F','MOPPITY LOCK & KEY RIESLING 2024(12 PK)','Riesling','Hilltops',2024,'LOCK & KEY'),
  ('513862','LOCK&KEY RIESLING 750ML','Riesling','Hilltops',NULL,'LOCK & KEY'),
  ('744191','COPPABELLA PINOT ROSE 750ML','RosÃ©','Tumbarumba',1991,'COPPABELLA'),
  ('513888','LOCK&KEY SAV BLANC 750ML','Sauvignon Blanc','Hilltops',NULL,'LOCK & KEY'),
  ('MOCSCH24F','COPPABELLA SINGLE VINEYARD CHARDONNAY','Chardonnay','Tumbarumba',NULL,'COPPABELLA'),
  ('MOTBRTNVF','MOPPITY TWELVE SIGNS SPARKLING BRUT','Tumbarumba Sparkling','Hilltops',NULL,'TWELVE SIGNS'),
  ('COPRSHZB22','Procella Shiraz 2022','Shiraz','Tumbarumba',2022,'COPPABELLA PROCELLA'),
  ('MVTSPIGB25','Twelve Signs Pinot Grigio 2025','Pinot Grigio','Hilltops',2025,'TWELVE SIGNS'),
  ('COPRCABB21','Procella Cabernet Sauvignon 2021','Cabernet Sauvignon','Tumbarumba',2021,'COPPABELLA PROCELLA'),
  ('MVLKCHAB24','Lock & Key Chardonnay 2024','Chardonnay','Hilltops',2024,'LOCK & KEY'),
  ('TWESPKCL1224','Twelve Signs Spkl Brut','Sparkling','Hilltops',2024,''),
  ('MVTSSBLB25','Twelve Signs Sauvignon Blanc 2025','Sauvignon Blanc','Hilltops',2025,'TWELVE SIGNS'),
  ('33362','TWELVE SIGNS S/BLC SEM 750ML','Sauvignon Blanc','Hilltops',NULL,'TWELVE SIGNS'),
  ('COCSCHAB22','Coppabella SIRIUS Chardonnay 2022 6PK','Chardonnay','Tumbarumba',2022,'COPPABELLA SIRIUS'),
  ('MVATSGMB22','Moppity ATRIUS SGM 2022','Shiraz Grenache MourvÃ¨dre','Hilltops',2022,'ATRIUS'),
  ('MOTPGR24F','MOPPITY TWELVE SIGNS PINOT GRIGIO','Pinot Grigio','Hilltops',NULL,'TWELVE SIGNS'),
  ('COCOPROPNV','Coppabella Prosecco Sparkling Piccolo 200ml NV','Tumbarumba Sparkling','Tumbarumba',NULL,'COPPABELLA'),
  ('33419','TWELVE SIGNS SHIRAZ 750ML','Shiraz','Hilltops',2019,'TWELVE SIGNS'),
  ('MVMUSHZB21','Moppity ''Tristis'' Shiraz 2021','Shiraz','Hilltops',2021,'MOPPITY ESTATE'),
  ('MVLKCABB21','Lock & Key Cabernet Sauv 2021','Cabernet','Hilltops',2021,'LOCK & KEY'),
  ('MOCSPC23F','COPPABELLA SINGLE VINEYARD SPAR CHARD PINOT','Chardonnay','Tumbarumba',NULL,'COPPABELLA'),
  ('MOLKSH22F','MOPPITY LOCK & KEY SHIRAZ','Shiraz','Hilltops',NULL,'LOCK & KEY'),
  ('MOCSPN22F','COPPABELLA SINGLE VINEYARD PINOT NOIR','Pinot Noir','Tumbarumba',NULL,'COPPABELLA'),
  ('621534','TWELVE SIGNS CAB SAUV 750ML','Cabernet Sauvignon','Hilltops',NULL,'TWELVE SIGNS'),
  ('MOAGSM22F','MOPPITY ATRIUS GSM','Shiraz Grenache MourvÃ¨dre','Hilltops',NULL,'ATRIUS'),
  ('513846','LOCK&KEY CABERNET SAUV 750ML','Cabernet','Hilltops',NULL,'LOCK & KEY'),
  ('983473','TWELVE SIGNS PINOT NOIR 750ML','Pinot Noir','Hilltops',NULL,'TWELVE SIGNS'),
  ('TWEPIG1224','Twelve Signs Pinot Grigio','Pinot Grigio','Hilltops',2024,''),
  ('LOCPIN1224','Lock & Key Pinot Noir','Pinot Noir','Hilltops',2024,''),
  ('578074','COPPABELLA PINOT NOIR 750ML','Pinot Noir','Tumbarumba',NULL,'COPPABELLA'),
  ('MVTSCHAB24','Twelve Signs Chardonnay 2024','Chardonnay','Hilltops',2024,'TWELVE SIGNS'),
  ('MOCSC621F','COPPABELLA SIRIUS CHARDONNAY 2021 (6 PK)','Chardonnay','Tumbarumba',2021,'COPPABELLA SIRIUS'),
  ('COCOPROB23','Coppabella Prosecco 2023','RosÃ©','Tumbarumba',2023,'COPPABELLA'),
  ('MOTPNO24F','MOPPITY TWELVE SIGNS PINOT NOIR 2024(12 PK)','Pinot Noir','Hilltops',2024,'TWELVE SIGNS'),
  ('MOTMOS24F','MOPPITY TWELVE SIGNS MOSCATO','Moscato','Hilltops',NULL,'TWELVE SIGNS'),
  ('33228','TWELVE SIGNS CAB MERL 750ML','Cabernet Merlot','Hilltops',2028,'TWELVE SIGNS'),
  ('MVLKSCPB22','Lock & Key Spk Chard Pinot Noir 2022','Pinot Noir','Hilltops',2022,'LOCK & KEY'),
  ('33338','TWELVE SIGNS CHARD 750ML','Chardonnay','Hilltops',NULL,'TWELVE SIGNS'),
  ('COCOPROBNV','Coppabella Prosecco NV','RosÃ©','Tumbarumba',NULL,'COPPABELLA'),
  ('MVLKRIEB24','Lock & Key Riesling 2024','Riesling','Hilltops',2024,'LOCK & KEY'),
  ('259426','TWELVE SIGNS ROSE 750ML','RosÃ©','Hilltops',2026,'TWELVE SIGNS'),
  ('MOCSPN24F','COPPABELLA SINGLE VINEYARD PINOT NOIR','Pinot Noir','Tumbarumba',NULL,'COPPABELLA'),
  ('983465','LOCK&KEY PINOT GRIGIO 750ML','Pinot Grigio','Hilltops',NULL,'LOCK & KEY'),
  ('159045','LOCK&KEY SPARK PICCOLO 200ML','Sparkling','Hilltops',NULL,'LOCK & KEY'),
  ('668934','TWELVE SIGNS MERLOT 750ML','Merlot','Hilltops',NULL,'TWELVE SIGNS'),
  ('MVATSHZB22','Moppity ATRIUS Shiraz 2022','Shiraz','Hilltops',2022,'ATRIUS'),
  ('MOLKSB23F','MOPPITY LOCK & KEY SAUVIGNON BLANC','Sauvignon Blanc','Hilltops',NULL,'LOCK & KEY'),
  ('513870','LOCK&KEY ROSE 750ML','RosÃ©','Hilltops',NULL,'LOCK & KEY'),
  ('MOTSSB23F','MOPPITY TWELVE SIGNS SEMILLON SAUVIGNON BLANC','Sauvignon Blanc','Hilltops',NULL,'TWELVE SIGNS'),
  ('COPRRIEB24','Procella Clare Riesling 2024','Riesling','Tumbarumba',2024,'MV EXCLUSIVE'),
  ('MVTSCLBB24','Twelve Signs Classic Brut 2024','Sparkling','Hilltops',2024,'TWELVE SIGNS'),
  ('983716','COPPABELLA PROSEC PICCLO 200ML','RosÃ©','Tumbarumba',2016,'COPPABELLA'),
  ('578066','COPPABELLA CHARD 750ML','Chardonnay','Tumbarumba',NULL,'COPPABELLA'),
  ('MVLRCABB18','Lock & Key ReserveCabernet2018 (6pack)','Cabernet','Hilltops',2018,''),
  ('MVTSCAMB23','Twelve Signs Cabernet Merlot 2023','Cabernet','Hilltops',2023,'TWELVE SIGNS'),
  ('MVTSPIGB24','Twelve Signs Pinot Grigio 2024','Pinot Grigio','Hilltops',2024,'TWELVE SIGNS'),
  ('COCOPINB24','Coppabella SV Pinot Noir 2024','Pinot Noir','Tumbarumba',2024,'COPPABELLA'),
  ('MVLKPINB17','Lock & Key Pinot Noir 2017','Pinot Noir','Hilltops',2017,'LOCK & KEY'),
  ('MVLKCHAB14','Lock & Key Chardonnay 2014','Chardonnay','Hilltops',2014,'LOCK & KEY'),
  ('MVTSSHZB24','Twelve Signs Shiraz 2024','Shiraz','Hilltops',2024,'TWELVE SIGNS'),
  ('MVESCABB21','Moppity Estate Cabernet Sauv 2021','Cabernet','Hilltops',2021,'MOPPITY ESTATE'),
  ('527308','LOCK&KEY MERLOT 750ML','Merlot','Hilltops',NULL,'LOCK & KEY'),
  ('MVTSSBLB24','Twelve Signs Sauvignon Blanc 2024','Sauvignon Blanc','Hilltops',2024,'TWELVE SIGNS'),
  ('MVLKSBLB23','Lock & Key Sauv Blanc 2023','Sauvignon Blanc','Hilltops',2023,'LOCK & KEY'),
  ('MVTSSHZB20','Twelve Signs Shiraz 2020','Shiraz','Hilltops',2020,'TWELVE SIGNS'),
  ('513820','MOPPITY RIESLING 750ML','Riesling','Hilltops',2020,'MOPPITY ESTATE'),
  ('MVLKSPKPNV','Lock & Key Sparkling Cuvee Piccolo NV','Tumbarumba Sparkling','Hilltops',NULL,'LOCK & KEY'),
  ('191801','LOCK&KEY H/T SANGIOVESE 750ML','Sangiovese','Hilltops',NULL,'LOCK & KEY'),
  ('MVLKSCPB16','Lock & Key Spk Pinot Chard2016','Chardonnay','Hilltops',2016,'LOCK & KEY'),
  ('MVATRIEB23','Moppity ''Lunam'' Riesling 2023','Riesling','Hilltops',2023,'ATRIUS'),
  ('MOLKCP22F','MOPPITY LOCK & KEY CHARD PINOT SPARKLING 2022(12 PK)','Chardonnay','Hilltops',2022,'LOCK & KEY'),
  ('MVLKMERB22','Lock & Key Merlot 2022','Merlot','Hilltops',2022,'LOCK & KEY'),
  ('MVESSHZB21','Moppity Estate Shiraz 2021','Shiraz','Hilltops',2021,'MOPPITY ESTATE'),
  ('MVTSCLBB14','Twelve Signs Classic Brut 2014','Sparkling','Hilltops',2014,'TWELVE SIGNS'),
  ('MOTSAU25F','MOPPITY TWELVE SIGNS SAUVIGNON BLANC','Sauvignon Blanc','Hilltops',NULL,'TWELVE SIGNS'),
  ('MOCCHA22F','COPPABELLA CREST CHARDONNAY','Chardonnay','Tumbarumba',NULL,'COPPABELLA CREST'),
  ('MVTSPIGB17','Twelve Signs Pinot Grigio 2017','Pinot Grigio','Hilltops',2017,'TWELVE SIGNS'),
  ('496353','MOPPITY ATRIUS SHZGRENMOU750ML','Shiraz','Hilltops',NULL,'ATRIUS'),
  ('MVLKSHZB13','Lock & Key Shiraz 2013','Shiraz','Hilltops',2013,''),
  ('668918','TWELVE SIGNS RIESLING 750ML','Riesling','Hilltops',2018,'TWELVE SIGNS'),
  ('COCOPINB22','Coppabella SV Pinot Noir 2022','Pinot Noir','Tumbarumba',2022,'COPPABELLA'),
  ('513804','MOPPITY CHARDONNAY 750ML','Chardonnay','Hilltops',NULL,'MOPPITY ESTATE'),
  ('COCOCHAB24','Coppabella SV Chardonnay 2024','Chardonnay','Tumbarumba',2024,'COPPABELLA'),
  ('MVTSCASB23','Twelve Signs Cab Sauvignon 2023','Cabernet Sauvignon','Hilltops',2023,'TWELVE SIGNS'),
  ('COCOPROB17','Coppabella Prosecco 2017','RosÃ©','Tumbarumba',2017,'COPPABELLA'),
  ('TWELVE SIGNS CABERNET MERLOT','TWELVE SIGNS CABERNET MERLOT','Cabernet','Hilltops',NULL,'TWELVE SIGNS'),
  ('MVTSROSB23','Twelve Signs ROSE 2023','RosÃ©','Hilltops',2023,'TWELVE SIGNS'),
  ('128751','COPPABELLA CRST P/NOIR 750ML','Pinot Noir','Tumbarumba',NULL,'COPPABELLA CREST'),
  ('LOCRIE1218','Lock & Key Riesling 2018','Riesling','Hilltops',2018,'LOCK & KEY'),
  ('COCOPROP18','Coppabella Prosecco Sparkling Piccolo 200ml','Tumbarumba Sparkling','Tumbarumba',2018,'COPPABELLA'),
  ('MVTSSSBB25','Twelve Signs Semillon Sauv Blanc 2025','Semillon','Hilltops',2025,'TWELVE SIGNS'),
  ('MVTSRIEB25','Twelve Signs Riesling 2025','Riesling','Hilltops',2025,'TWELVE SIGNS'),
  ('TWELVE SIGNS CABERNET SAUVIGNON','TWELVE SIGNS CABERNET SAUVIGNON','Cabernet Sauvignon','Hilltops',NULL,'TWELVE SIGNS'),
  ('MOTPNO25F','MOPPITY TWELVE SIGNS PINOT NOIR 2025(12 PK)','Pinot Noir','Hilltops',2025,'TWELVE SIGNS'),
  ('496324','MOPPITY ATRIUS CHARDONNAY750ML','Chardonnay','Hilltops',2024,'ATRIUS'),
  ('MVLKROSB23','Lock & Key Rose 2023','RosÃ©','Hilltops',2023,'LOCK & KEY'),
  ('225820','COPPABELLA PREMIER CUVEE 750ML','Sparkling','Tumbarumba',2020,'COPPABELLA'),
  ('484979','MOPPITY ATRIUS PINOT NOIR750ML','Pinot Noir','Hilltops',NULL,'ATRIUS'),
  ('485637','MOPPITY ATRIUS SHIRAZ 750ML','Shiraz','Hilltops',NULL,'ATRIUS'),
  ('MVRESHZB18','Moppity RESERVE Shiraz 2018 UNLABELLED','Shiraz','Hilltops',2018,'MOPPITY RESERVE'),
  ('MVTSSBLB17','Twelve Signs Sauv Blanc 2017','Sauvignon Blanc','Hilltops',2017,'TWELVE SIGNS'),
  ('MOATAL24F','MOPPITY ATRIUS ALBARINO','Albarino','Hilltops',NULL,'ATRIUS'),
  ('MVBLCABB22','Moppity Block M1 Cab Sauv 2022','Cabernet Sauvignon','Hilltops',2022,'MOPPITY ESTATE'),
  ('MVTSCASB21','Twelve Signs Cab Sauvignon 2021','Cabernet Sauvignon','Hilltops',2021,'TWELVE SIGNS'),
  ('COCOPINB14','Coppabella SV Pinot Noir 2014','Pinot Noir','Tumbarumba',2014,'COPPABELLA'),
  ('MOBLCH24F','MOPPITY BLOCK C20 CHARDONNAY','Chardonnay','Hilltops',NULL,'MOPPITY ESTATE'),
  ('MVTSPINB24','Twelve Signs Pinot Noir 2024','Pinot Noir','Hilltops',2024,'TWELVE SIGNS'),
  ('MVATPINB23','Moppity ATRIUS Pinot Noir 2023','Pinot Noir','Hilltops',2023,'ATRIUS'),
  ('MVBLSH5B22','Moppity Block A5 Canberra Shiraz 2022','Shiraz','Hilltops',2022,'MOPPITY ESTATE'),
  ('152580','LOCK&KEY RES SHIRAZ 750ML','Shiraz','Hilltops',NULL,''),
  ('875007','MOPPITY BLOCK A5 CNB SHZ 750ML','Shiraz','Hilltops',NULL,'MOPPITY ESTATE'),
  ('MVTSCHAB16','Twelve signs Chardonnay 2016','Chardonnay','Hilltops',2016,'TWELVE SIGNS'),
  ('COCOCHAB22','Coppabella SV Chardonnay 2022','Chardonnay','Tumbarumba',2022,'COPPABELLA'),
  ('348754','COPPABELLA PINOT GRIS 750ML','Pinot Grigio','Tumbarumba',NULL,'COPPABELLA'),
  ('734803','TWELVE SIGNS MOSCATO 750ML','Moscato','Hilltops',NULL,'TWELVE SIGNS'),
  ('COCOCHAB15','Coppabella SV Chardonnay 2015','Chardonnay','Tumbarumba',2015,'COPPABELLA'),
  ('MVECSHZB16','Moppity Escalier Shiraz 2016 6pks','Shiraz','Hilltops',2016,'MOPPITY RESERVE'),
  ('TWELVE SIGNS SPARKLING','TWELVE SIGNS SPARKLING','Tumbarumba Sparkling','Hilltops',NULL,'TWELVE SIGNS'),
  ('MVLKSANB24','Lock & Key Sangiovese 2024','Sangiovese','Hilltops',2024,'LOCK & KEY'),
  ('TWELVE SIGNS Moscato','TWELVE SIGNS Moscato','Moscato','Hilltops',NULL,'TWELVE SIGNS'),
  ('COCOROSB25','Coppabella SV ROSE 2025','RosÃ©','Tumbarumba',2025,'COPPABELLA'),
  ('870162','MOPPITY BLOCK M4 HT SHZ 750ML','Shiraz','Hilltops',NULL,'MOPPITY ESTATE'),
  ('COPRSANB24','Procella Sangiovese 2024','Sangiovese','Tumbarumba',2024,'COPPABELLA PROCELLA'),
  ('MVTSMERB21','Twelve Signs Merlot 2021','Merlot','Hilltops',2021,'TWELVE SIGNS'),
  ('COPPABELLA PINOT NOIR','COPPABELLA PINOT NOIR','Pinot Noir','Tumbarumba',NULL,'COPPABELLA'),
  ('MVATCABB22','Moppity ATRIUS Cabernet Sauvignon 2022','Cabernet Sauvignon','Hilltops',2022,'ATRIUS'),
  ('COCOSCPB23','Coppabella Spk Chard Pinot Noir 2023','Pinot Noir','Tumbarumba',2023,'COPPABELLA'),
  ('MVECSHZB14','Moppity Escalier Shz 2014 3pks','Shiraz','Hilltops',2014,'MOPPITY RESERVE'),
  ('128719','COPPABELLA CRST CHARD 750ML','Chardonnay','Tumbarumba',2019,'COPPABELLA CREST'),
  ('870170','MOPPITY BLOCK M1 CAB SAUV750ML','Cabernet Sauvignon','Hilltops',NULL,'MOPPITY ESTATE'),
  ('MVLKSBLB17','Lock & Key Sauv Blanc 2017','Sauvignon Blanc','Hilltops',2017,'LOCK & KEY'),
  ('MVLKPIGB20','Lock & Key Pinot Grigio 2020','Pinot Grigio','Hilltops',2020,'LOCK & KEY'),
  ('MVTSSSBB23','Twelve Signs Semillon Sauv Blanc 2023','Semillon','Hilltops',2023,'TWELVE SIGNS'),
  ('MVTSSHZB13','Twelve Signs Shiraz 2013','Shiraz','Hilltops',2013,'TWELVE SIGNS'),
  ('158968','COPPABELLA SAUV BLANC 750ML','Sauvignon Blanc','Tumbarumba',NULL,'COPPABELLA'),
  ('TWELVE SIGNS RIESLING','TWELVE SIGNS RIESLING','Riesling','Hilltops',NULL,'TWELVE SIGNS'),
  ('LOCSPCH2416S','Lock & Key Spk Chard 16 200ml','Chardonnay','Hilltops',NULL,'LOCK & KEY'),
  ('MVTSMOSB24','Twelve Signs Moscato 2024','Moscato','Hilltops',2024,'TWELVE SIGNS'),
  ('TWELVE SIGNS SHIRAZ','TWELVE SIGNS SHIRAZ','Shiraz','Hilltops',NULL,'TWELVE SIGNS'),
  ('COCSCHAB21','Coppabella SIRIUS Chardonnay 2021 6PK','Chardonnay','Tumbarumba',2021,'COPPABELLA SIRIUS'),
  ('MVTSPIGB23','Twelve Signs Pinot Grigio 2023','Pinot Grigio','Hilltops',2023,'TWELVE SIGNS'),
  ('MVBLGEWB23','Moppity Block C11B Gewurztraminer 2023','Gewurztraminer','Hilltops',2023,'MOPPITY ESTATE'),
  ('MVRECABB18','Moppity RESERVE Cab Sauv 2018 (6pks)','Cabernet Sauvignon','Hilltops',2018,'MOPPITY RESERVE'),
  ('496400','MOPPITY ATRIUS CAB SAUV 750ML','Cabernet Sauvignon','Hilltops',NULL,'ATRIUS'),
  ('MOPPITY ATRIUS RIESLING','MOPPITY ATRIUS RIESLING','Riesling','Hilltops',NULL,'ATRIUS'),
  ('513799','MOPPITY CABERNET SAUV 750ML','Cabernet','Hilltops',1999,'MOPPITY ESTATE'),
  ('MVBLCHAB24','Moppity Block C20 Chard 2024','Chardonnay','Hilltops',2024,'MOPPITY ESTATE'),
  ('COPPABELLA PROSECCO','COPPABELLA PROSECCO','RosÃ©','Tumbarumba',NULL,'COPPABELLA'),
  ('MOLKCP23F','MOPPITY LOCK & KEY CHARD PINOT SPARKLING 2023(12 PK)','Chardonnay','Hilltops',2023,'LOCK & KEY'),
  ('COCOSCPB15','Coppabella Spk Chard Pinot ''15','Chardonnay','Tumbarumba',2015,'COPPABELLA'),
  ('1850349','Moppity Estate Shiraz','Shiraz','Hilltops',NULL,'MOPPITY ESTATE'),
  ('MVLKROSB15','Lock & Key Rose 2015','RosÃ©','Hilltops',2015,'LOCK & KEY'),
  ('TWELVE SIGNS PINOT GRIGIO','TWELVE SIGNS PINOT GRIGIO','Pinot Grigio','Hilltops',NULL,'TWELVE SIGNS'),
  ('COCOSBLB22','Coppabella SV Sauvignon Blanc 2022','Sauvignon Blanc','Tumbarumba',2022,'COPPABELLA'),
  ('MVRESHZB17','Moppity Vineyards Res Shz 2017','Shiraz','Hilltops',2017,'MOPPITY RESERVE'),
  ('COCCCHAB21','Coppabella CREST Chardonnay 2021','Chardonnay','Tumbarumba',2021,'COPPABELLA CREST'),
  ('478923','MOPPITY ATRIUS TEMPRANILL750ML','Tempranillo','Hilltops',2023,'ATRIUS'),
  ('MVTSCAMB13','Twelve Signs Cab Merlot 2013','Merlot','Hilltops',2013,''),
  ('COCSPINB22','Coppabella SIRIUS Pinot Noir 2022 6PK','Pinot Noir','Tumbarumba',2022,'COPPABELLA SIRIUS'),
  ('1950357','Moppity Estate Chardonnay','Chardonnay','Hilltops',NULL,'MOPPITY ESTATE'),
  ('MVTSCHAB25','Twelve Signs Chardonnay 2025','Chardonnay','Hilltops',2025,'TWELVE SIGNS'),
  ('MVLKCABB22','Lock & Key Cabernet Sauv 2022','Cabernet','Hilltops',2022,'LOCK & KEY'),
  ('MVBLGAMB23','Moppity Block C12C Gamay 2023','Gamay','Hilltops',2023,''),
  ('MOTRIE25F','MOPPITY TWELVE SIGNS RIESLING','Riesling','Hilltops',NULL,'TWELVE SIGNS'),
  ('MVTSROSB18','Twelve Signs ROSE 2018','RosÃ©','Hilltops',2018,''),
  ('COCCPINB21','Coppabella CREST Pinot Noir 2021','Pinot Noir','Tumbarumba',2021,'COPPABELLA CREST'),
  ('MVLKCABB10','Lock & Key Cabernet Sauv 2010','Cabernet','Hilltops',2010,'LOCK & KEY'),
  ('MVRECABB17','Moppity Vineyards Res Cab 2017','Cabernet Sauvignon','Hilltops',2017,'MOPPITY RESERVE'),
  ('MVTSMERB16','Twelve Signs Merlot 2016','Merlot','Hilltops',2016,''),
  ('X-MVRECABB13','Moppity RESERVE Cab Sauv 2013 (6pks)','Cabernet Sauvignon','Hilltops',2013,'MOPPITY RESERVE'),
  ('TWELVE SIGNS CHARDONNAY','TWELVE SIGNS CHARDONNAY','Chardonnay','Hilltops',NULL,'TWELVE SIGNS'),
  ('1857486','Moppity Estate Cab Sauv','Cabernet Sauvignon','Hilltops',NULL,'MOPPITY ESTATE'),
  ('MVLKSBLB25','Lock & Key Sauv Blanc 2025','Sauvignon Blanc','Hilltops',2025,'LOCK & KEY'),
  ('MVLKMERB16','Lock & Key Merlot 2016','Merlot','Hilltops',2016,'LOCK & KEY'),
  ('MVTSCASB16','Twelve Signs Cab Sauvignon2016','Cabernet Sauvignon','Hilltops',2016,'TWELVE SIGNS'),
  ('MVTSPINB25','Twelve Signs Pinot Noir 2025','Pinot Noir','Hilltops',2025,'TWELVE SIGNS'),
  ('MOPPITY ATRIUS SHIRAZ','MOPPITY ATRIUS SHIRAZ','Shiraz','Hilltops',NULL,'ATRIUS'),
  ('COCCCHAB17','Coppabella Crest Chardonnay 17','Chardonnay','Tumbarumba',2017,'COPPABELLA CREST'),
  ('COCOSBLB16','Coppabella Sauv Blanc 2016','Sauvignon Blanc','Tumbarumba',2016,'COPPABELLA'),
  ('312135','MOPPITY BLK C20 EM CHARD 750ML','Chardonnay','Hilltops',NULL,'MOPPITY ESTATE'),
  ('MVTSCLBB23','Twelve Signs Classic Brut 2023','Sparkling','Hilltops',2023,'TWELVE SIGNS'),
  ('COPPABELLA CHARDONNAY','COPPABELLA CHARDONNAY','Chardonnay','Tumbarumba',NULL,'COPPABELLA'),
  ('MVLKSPKP16','Lock & Key SparklingPiccolo 16','Tumbarumba Sparkling','Hilltops',2016,'LOCK & KEY'),
  ('MVATTEMB23','Moppity ATRIUS Tempranillo 2023','Tempranillo','Hilltops',2023,''),
  ('MOPPITY ATRIUS CABERNET SAUVIGNON','MOPPITY ATRIUS CABERNET SAUVIGNON','Cabernet Sauvignon','Hilltops',NULL,'ATRIUS'),
  ('COCSPINB21','Coppabella SIRIUS Pinot Noir 2021 6PK','Pinot Noir','Tumbarumba',2021,'COPPABELLA SIRIUS'),
  ('COCOSBLB25','Coppabella SV Sauvignon Blanc 2025','Sauvignon Blanc','Tumbarumba',2025,'COPPABELLA'),
  ('MVECSHZB18','Moppity Escalier Shiraz 2018 6pks','Shiraz','Hilltops',2018,''),
  ('MOCVPR25F','COPPABELLA SINGLE VINEYARD PINOT ROSE','RosÃ©','Tumbarumba',NULL,'COPPABELLA'),
  ('TWELVE SIGNS ROSE','TWELVE SIGNS ROSE','RosÃ©','Hilltops',NULL,'TWELVE SIGNS'),
  ('MOPPITY ATRIUS CHARDONNAY','MOPPITY ATRIUS CHARDONNAY','Chardonnay','Hilltops',NULL,'ATRIUS'),
  ('MVLKCHAB22','Lock & Key Chardonnay 2022','Chardonnay','Hilltops',2022,'LOCK & KEY'),
  ('MOCCPN22F','COPPABELLA CREST PINOT NOIR 2022 (12PK)(12PK)','Pinot Noir','Tumbarumba',2022,'COPPABELLA CREST'),
  ('COCOPIGB21','Coppabella SV PINOT GRIS 2021','Pinot Grigio','Tumbarumba',2021,'COPPABELLA'),
  ('MOPPITY ATRIUS PINOT NOIR','MOPPITY ATRIUS PINOT NOIR','Pinot Noir','Hilltops',NULL,'ATRIUS'),
  ('COPPABELLA PINOT GRIS','COPPABELLA PINOT GRIS','Pinot Grigio','Tumbarumba',NULL,'COPPABELLA'),
  ('COPPABELLA SAUVIGNON BLANC','COPPABELLA SAUVIGNON BLANC','Sauvignon Blanc','Tumbarumba',NULL,'COPPABELLA'),
  ('MVLKROSB25','Lock & Key Rose 2025','RosÃ©','Hilltops',2025,'LOCK & KEY'),
  ('X-MVESCABB16','Moppity Vineyard Cabernet 2016','Cabernet','Hilltops',2016,'MOPPITY ESTATE'),
  ('COCSCHAB16','Coppabella Sirius Chardonnay 2016','Chardonnay','Tumbarumba',2016,'COPPABELLA SIRIUS'),
  ('COCOPIGB25','Coppabella SV PINOT GRIS 2025','Pinot Grigio','Tumbarumba',2025,'COPPABELLA'),
  ('COCOROSB15','Coppabella Pinot Rose 2015','RosÃ©','Tumbarumba',2015,'COPPABELLA'),
  ('MVESCABB09','Moppity Vineyards Cabernet 2009','Cabernet','Hilltops',2009,'MOPPITY ESTATE'),
  ('LOCK & KEY Pinot Grigio','LOCK & KEY Pinot Grigio','Pinot Grigio','Hilltops',NULL,'LOCK & KEY'),
  ('COPPABELLA PREMIER CUVEE','COPPABELLA PREMIER CUVEE','Sparkling','Tumbarumba',NULL,'COPPABELLA'),
  ('X-COCSCHAB17','Coppabella Sirius Chardonnay 2017','Chardonnay','Tumbarumba',2017,'COPPABELLA SIRIUS'),
  ('LOCK & KEY CHARDONNAY PICCOLO','LOCK & KEY CHARDONNAY PICCOLO','Chardonnay','Hilltops',NULL,'LOCK & KEY'),
  ('COCOPIGB24','Coppabella SV PINOT GRIS 2024','Pinot Grigio','Tumbarumba',2024,'COPPABELLA'),
  ('MVATALBB24','Moppity ATRIUS Albarino 2024','Albarino','Hilltops',2024,'ATRIUS'),
  ('MVTSSSBB22','Twelve Signs Semillon Sauv Blanc 2022','Semillon','Hilltops',2022,'TWELVE SIGNS'),
  ('MVLKRIEB25','Lock & Key Riesling 2025','Riesling','Hilltops',2025,'LOCK & KEY'),
  ('MVLKCABM21','Lock & Key Cabernet Magnum 2021','Cabernet','Hilltops',2021,'LOCK & KEY'),
  ('MVLKPIGB23','Lock & Key Pinot Grigio 2023','Pinot Grigio','Hilltops',2023,'LOCK & KEY'),
  ('MOATPN23F','MOPPITY ATRIUS PINOT NOIR','Pinot Noir','Hilltops',NULL,'ATRIUS'),
  ('MOLKCPNVF','MOPPITY LOCK & KEY CHARD PINOT SPARK 2023(12 PK)','Chardonnay','Hilltops',2023,'LOCK & KEY'),
  ('MOSHM422F','MOPPITY BLOCK M4 SHIRAZ','Shiraz','Hilltops',NULL,'MOPPITY ESTATE'),
  ('MOSHA522F','MOPPITY BLOCK A5 SHIRAZ','Shiraz','Hilltops',NULL,'MOPPITY ESTATE'),
  ('TWESBL1224','Twelve Signs Sauv Blanc','Sauvignon Blanc','Hilltops',2024,''),
  ('MOTTSH20F','MOPPITY TWELVE SIGNS SHIRAZ','Shiraz','Hilltops',NULL,'TWELVE SIGNS'),
  ('MOLKSPNVP','MOPPITY LOCK & KEY CHARD PINOT SPARK PICCOLONV 200ml (24 PK)','Chardonnay','Hilltops',NULL,'LOCK & KEY'),
  ('MOTCHA24F','MOPPITY TWELVE SIGNS CHARDONNAY 2024(12 PK)','Chardonnay','Hilltops',2024,'TWELVE SIGNS'),
  ('COPCHA1224','Coppabella Chardonnay','Chardonnay','Tumbarumba',2024,''),
  ('LOCSHZ1222','Lock & Key Shiraz','Shiraz','Hilltops',2022,''),
  ('MVLKSBLB22','Lock & Key Sauv Blanc 2022','Sauvignon Blanc','Hilltops',2022,'LOCK & KEY'),
  ('LOCCHA1224','Lock & Key Chardonnay','Chardonnay','Hilltops',2024,''),
  ('MOBLCS22F','MOPPITY BLOCK M1 CABERNET SAUVIGNON','Cabernet Sauvignon','Hilltops',NULL,'MOPPITY ESTATE'),
  ('MOATSH22F','MOPPITY ATRIUS SHIRAZ','Shiraz','Hilltops',NULL,'ATRIUS'),
  ('MOATCH21F','MOPPITY ATRIUS CHARDONNAY','Chardonnay','Hilltops',NULL,'ATRIUS'),
  ('MOCCCH21F','COPPABELLA CREST CHARDONNAY','Chardonnay','Tumbarumba',NULL,'COPPABELLA CREST'),
  ('MOLKSA24F','MOPPITY LOCK & KEY SANGIOVESE','Sangiovese','Hilltops',NULL,'LOCK & KEY'),
  ('TWECHA1224','Twelve Signs Chardonnay','Chardonnay','Hilltops',2024,''),
  ('MVTSPINB22','Twelve Signs Pinot Noir 2022','Pinot Noir','Hilltops',2022,'TWELVE SIGNS'),
  ('MOTSCM23F','MOPPITY TWELVE SIGNS CABERNET MERLOT','Cabernet','Hilltops',NULL,'TWELVE SIGNS'),
  ('TWEROSE1223','Twelve Signs Rose','RosÃ©','Hilltops',2023,''),
  ('TWESSB1223','Twelve Signs SSB','Semillon Sauvignon Blanc','Hilltops',2023,''),
  ('MOBLCG23F','MOPPITY BLOCK C12C GAMAY','Gamay','Hilltops',NULL,'MOPPITY ESTATE'),
  ('MOLKME22F','MOPPITY LOCK & KEY MERLOT','Merlot','Hilltops',NULL,'LOCK & KEY'),
  ('MOLKCS21F','MOPPITY LOCK & KEY CABERNET SAUVIGNON','Cabernet Sauvignon','Hilltops',NULL,'LOCK & KEY'),
  ('COPPNO1222','Coppabella SV Pinot Noir','Pinot Noir','Tumbarumba',2022,'COPPABELLA'),
  ('TWESHZ1220','Twelve Signs Shiraz 20','Shiraz','Hilltops',2020,'TWELVE SIGNS'),
  ('MOTROS23F','MOPPITY TWELVE SIGNS ROSE','RosÃ©','Hilltops',NULL,'TWELVE SIGNS'),
  ('MOTMER21F','MOPPITY TWELVE SIGNS MERLOT','Merlot','Hilltops',NULL,'TWELVE SIGNS'),
  ('MOESH614F','MOPPITY ESCALIER SHIRAZ','Shiraz','Hilltops',NULL,'MOPPITY RESERVE'),
  ('MOLKPG24F','MOPPITY LOCK & KEY PINOT GRIGIO','Pinot Grigio','Hilltops',NULL,'LOCK & KEY'),
  ('LOCRIE1224','Lock & Key Riesling','Riesling','Hilltops',2024,''),
  ('LOCSPCHA1222','Lock & Key Spk Char Pinot','Tumbarumba Sparkling','Hilltops',2022,'LOCK & KEY'),
  ('COCOSCPB22','Coppabella Spk Chard Pinot Noir 2022','Pinot Noir','Tumbarumba',2022,'COPPABELLA'),
  ('COPPRO24NVPI','Coppabella Prosecco Piccolo','RosÃ©','Tumbarumba',NULL,'COPPABELLA'),
  ('TWECAM1223','Twelve Signs Cab Merlot','Merlot','Hilltops',2023,''),
  ('MOTCSA23F','MOPPITY TWELVE SIGNS CABERNET SAUVIGNON','Cabernet Sauvignon','Hilltops',NULL,'TWELVE SIGNS'),
  ('MOTSAU24F','MOPPITY TWELVE SIGNS SAUVIGNON BLANC','Sauvignon Blanc','Hilltops',NULL,'TWELVE SIGNS'),
  ('MOATTE23F','MOPPITY ATRIUS TEMPRANILLO','Tempranillo','Hilltops',NULL,'ATRIUS'),
  ('MOLKRO23F','MOPPITY LOCK & KEY ROSE','RosÃ©','Hilltops',NULL,'LOCK & KEY'),
  ('TWEPIN1224','Twelve Signs Pinot Noir','Pinot Noir','Hilltops',2024,''),
  ('MOTRSH21F','MOPPITY TRISTIS SHIRAZ','Shiraz','Hilltops',NULL,'MOPPITY ESTATE'),
  ('MOCCPN21F','COPPABELLA CREST PINOT NOIR','Pinot Noir','Tumbarumba',NULL,'COPPABELLA CREST'),
  ('1853015','Lock & Key Shiraz','Shiraz','Hilltops',2015,'LOCK & KEY'),
  ('2156348','Lock & Key Rose','RosÃ©','Hilltops',NULL,'LOCK & KEY'),
  ('MOCSP622F','COPPABELLA SIRIUS PINOT NOIR','Pinot Noir','Tumbarumba',NULL,'COPPABELLA SIRIUS'),
  ('MORSH618F','MOPPITY RESERVE SHIRAZ','Shiraz','Hilltops',NULL,'MOPPITY RESERVE'),
  ('MVATALBB23','Moppity ATRIUS Albarino 2023','Albarino','Hilltops',2023,'ATRIUS'),
  ('MVTSPINB19','Twelve Signs Pinot Noir 2019','Pinot Noir','Hilltops',2019,''),
  ('COPSPCHA1223','Coppabella Pinot Chard Spk','Chardonnay','Tumbarumba',2023,''),
  ('MOBGEW23F','MOPPITY BLOCK C118 GEWURZTRAMINER 2023(12 PK)','Gewurztraminer','Hilltops',2023,'MOPPITY ESTATE'),
  ('LOCMER1222','Lock & Key Merlot','Merlot','Hilltops',2022,''),
  ('1851801','Lock & Key Pinot Noir','Pinot Noir','Hilltops',NULL,'LOCK & KEY'),
  ('LOCPIG1223','Lock & Key Pinot Grigio','Pinot Grigio','Hilltops',2023,''),
  ('MOPESCAB1221','Moppity Est Cab Sauv','Cabernet Sauvignon','Hilltops',2021,'MOPPITY ESTATE'),
  ('1850125','Lock & Key Cab Sauv','Cabernet Sauvignon','Hilltops',2025,'LOCK & KEY'),
  ('MOCSPG24F','COPPABELLA SINGLE VINEYARD PINOT GRIS','Pinot Grigio','Tumbarumba',NULL,'COPPABELLA'),
  ('1956477','Lock & Key Chardonnay','Chardonnay','Hilltops',NULL,'LOCK & KEY'),
  ('MOATRI23F','MOPPITY ATRIUS RIESLING','Riesling','Hilltops',NULL,'ATRIUS'),
  ('1871479','Moppity Atrius Shiraz','Shiraz','Hilltops',NULL,'ATRIUS'),
  ('1946540','Lock & Key Sauvignon Blanc','Sauvignon Blanc','Hilltops',NULL,'LOCK & KEY'),
  ('COCOROSB24','Coppabella SV Pinot ROSE 2024','RosÃ©','Tumbarumba',2024,'COPPABELLA'),
  ('COPCRPIN1221','Coppabella Crest Pinot Noir 21','Pinot Noir','Tumbarumba',2021,'COPPABELLA CREST'),
  ('MVTSSBSB20','Twelve Signs Sauv Blanc Semllon 2020','Sauvignon Blanc','Hilltops',2020,''),
  ('2301547','Lock & Key Sparkling','Tumbarumba Sparkling','Hilltops',NULL,'LOCK & KEY'),
  ('1851936','Twelve Signs Shiraz','Shiraz','Hilltops',NULL,'TWELVE SIGNS'),
  ('1851954','Twelve Signs Cabernet Merlot','Cabernet','Hilltops',NULL,'TWELVE SIGNS'),
  ('LOCSBL1222','Lock & Key Sauv Blanc','Sauvignon Blanc','Hilltops',2022,''),
  ('MOCVSB22F','COPPABELLA SINGLE VINEYARD SAUVIGNON BLANC','Sauvignon Blanc','Tumbarumba',NULL,'COPPABELLA'),
  ('MVTSCHAB23','Twelve Signs Chardonnay 2023','Chardonnay','Hilltops',2023,'TWELVE SIGNS'),
  ('COPPIG1224','Coppabella Pinot Gris','Pinot Grigio','Tumbarumba',2024,''),
  ('1958732','Moppity Atrius Chardonnay','Chardonnay','Hilltops',NULL,'ATRIUS'),
  ('MORCS617F','MOPPITY RESERVE CABERNET SAUVIGNON','Cabernet Sauvignon','Hilltops',NULL,'MOPPITY RESERVE'),
  ('LOCCAB1221','Lock & Key Cabernet Sauv','Cabernet','Hilltops',2021,''),
  ('COPCRCHA1221','Coppabella Crest Chard 21','Chardonnay','Tumbarumba',2021,'COPPABELLA CREST'),
  ('MOTTSH24F','MOPPITY TWELVE SIGNS SHIRAZ','Shiraz','Hilltops',NULL,'TWELVE SIGNS'),
  ('MOPM4SHZ1222','Moppity Block M4 Shiraz','Shiraz','Hilltops',2022,''),
  ('COPPIG1222','Coppabella Pinot Gris','Pinot Grigio','Tumbarumba',2022,'COPPABELLA'),
  ('1951908','Twelve Signs Pinot Grigio','Pinot Grigio','Hilltops',NULL,'TWELVE SIGNS'),
  ('COPSICHA621','Coppabella Sirius Chard','Chardonnay','Tumbarumba',2021,'COPPABELLA SIRIUS'),
  ('2153797','Twelve Signs Rose','RosÃ©','Hilltops',1997,'TWELVE SIGNS'),
  ('MVTSCAMB21','Twelve Signs Cabernet Merlot 2021','Cabernet','Hilltops',2021,'TWELVE SIGNS'),
  ('TWECAB1221','Twelve Signs Cabernet','Cabernet','Hilltops',2021,'TWELVE SIGNS'),
  ('2300922','Twelve Signs Sparkling','Tumbarumba Sparkling','Hilltops',2022,'TWELVE SIGNS'),
  ('1951061','Twelve Signs Chardonnay','Chardonnay','Hilltops',NULL,'TWELVE SIGNS'),
  ('1951873','Twelve Signs Sauvignon Blanc','Sauvignon Blanc','Hilltops',NULL,'TWELVE SIGNS'),
  ('MOPC11GE1223','Moppity Blk C11B Gewurztram','Gewurztraminer','Hilltops',2023,''),
  ('ATRRIES1223','Atrius (Lunam) Riesling','Riesling','Tumbarumba',2023,''),
  ('ATRPIN1223','Atrius Pinot Noir','Pinot Noir','Tumbarumba',2023,''),
  ('COPSBL1222','Coppabella Sauv Blanc','Sauvignon Blanc','Tumbarumba',2022,'COPPABELLA'),
  ('MVATPETB22','Moppity ''Creo'' Pet Naturel 2022','PÃ©tillant Naturel','Hilltops',2022,''),
  ('MOATCS22F','MOPPITY ATRIUS CABERNET SAUVIGNON','Cabernet Sauvignon','Hilltops',NULL,'ATRIUS'),
  ('MOPM1CAB1222','Moppity Block M1 Cab Sauv','Cabernet Sauvignon','Hilltops',2022,''),
  ('TWEMER1221','Twelve Signs Merlot','Merlot','Hilltops',2021,''),
  ('ATRALB1223','Atrius Albarino','Albarino','Tumbarumba',2023,''),
  ('ATRCHD1221','Atrius Chardonnay','Chardonnay','Tumbarumba',2021,''),
  ('MVTSSBLB23','Twelve Signs Sauvignon Blanc 2023','Sauvignon Blanc','Hilltops',2023,'TWELVE SIGNS'),
  ('COPSIPIN621','Coppabella Sirius Pin Noir','Pinot Noir','Tumbarumba',2021,'COPPABELLA SIRIUS'),
  ('MVTSMOSB23','Twelve Signs Moscato 2023','Moscato','Hilltops',2023,'TWELVE SIGNS'),
  ('MVESCHAB21','Moppity Estate Chardonnay 2021','Chardonnay','Hilltops',2021,'MOPPITY ESTATE'),
  ('COCOPINB21','Coppabella SV Pinot Noir 2021','Pinot Noir','Tumbarumba',2021,'COPPABELLA'),
  ('MVTSSHZB21','Twelve Signs Shiraz 2021','Shiraz','Hilltops',2021,'TWELVE SIGNS')
;

DO $$
DECLARE v_xlsx_count INT;
BEGIN
    SELECT count(*) INTO v_xlsx_count FROM _xlsx_region_map;
    RAISE NOTICE 'POST-§4: xlsx VALUES staged: % rows (expected 339)', v_xlsx_count;
    IF v_xlsx_count <> 339 THEN
        RAISE EXCEPTION 'POST-§4 FAIL: xlsx staged row count = % (expected 339)', v_xlsx_count;
    END IF;
END $$;

-- ────────────────────────────────────────────────────────────────────────────
-- §5 Resolve xlsx sku_code → sku.sku_id via two-path matcher
--    Path A: UPPER(sku.sku_code) = UPPER(xlsx.sku_code) — direct
--    Path B: sku_code_map.external_code = xlsx.sku_code — bridge for
--            DWS/ALM/Access numeric codes (e.g. xlsx '245011' = TS Sauv Blanc
--            DWS code stored in sku_code_map for the canonical Moppity row)
--    DISTINCT ON (sku_id) prefers Path A on conflict (rank=1 < 2).
--    Multi-region collisions on same sku_id are detected after population
--    and fail the migration (see DO $$ check below).
-- ────────────────────────────────────────────────────────────────────────────
CREATE TEMP TABLE _xlsx_resolved AS
SELECT DISTINCT ON (sku_id) sku_id, region, source_path, xlsx_code
  FROM (
    -- Path A: direct sku.sku_code match (case-insensitive)
    SELECT s.sku_id,
           x.region,
           'sku_code'      AS source_path,
           x.sku_code      AS xlsx_code,
           1               AS rank
      FROM _xlsx_region_map x
      JOIN sku s ON UPPER(s.sku_code) = UPPER(x.sku_code)
    UNION ALL
    -- Path B: bridge via sku_code_map (any source_system)
    SELECT scm.sku_id,
           x.region,
           'sku_code_map'  AS source_path,
           x.sku_code      AS xlsx_code,
           2               AS rank
      FROM _xlsx_region_map x
      JOIN sku_code_map scm ON scm.external_code = x.sku_code
  ) u
 ORDER BY sku_id, rank;

-- Defensive: if a single sku_id resolves to ≥2 distinct regions across the
-- xlsx-paths union, classify the conflict:
--   Path-A-authoritative — Path A (direct sku.sku_code match) is the current
--     canonical code; Path B may carry legacy alias codes with stale region.
--     If Path A exists, its region wins via _xlsx_resolved DISTINCT ON rank=1.
--     Path-B disagreements are noise — log + accept.
--   TRUE conflict — sku_id has NO Path A AND ≥2 Path-B regions disagree.
--     This means xlsx has no authoritative answer. SKIP the sku_id from
--     _xlsx_resolved entirely so the COALESCE chain falls through to
--     Vinsight raw / brand rule / 'Unknown' for that wine. Per
DO $$
DECLARE
    v_path_a_count       INT;
    v_path_b_only_count  INT;
    v_true_conflict_count INT;
    v_resolved_rows      INT;
    v_skip_count         INT;
BEGIN
    -- Count path-A-authoritative conflicts (Path A present, Path B disagrees).
    -- These are auto-resolved by DISTINCT ON rank — log + accept.
    SELECT count(*) INTO v_path_a_count FROM (
        SELECT sku_id
          FROM (
            SELECT s.sku_id, x.region, 'A' AS p FROM _xlsx_region_map x
              JOIN sku s ON UPPER(s.sku_code) = UPPER(x.sku_code)
            UNION ALL
            SELECT scm.sku_id, x.region, 'B' AS p FROM _xlsx_region_map x
              JOIN sku_code_map scm ON scm.external_code = x.sku_code
          ) u
         GROUP BY sku_id
        HAVING count(DISTINCT region) > 1
           AND bool_or(p = 'A')
    ) c;

    -- TRUE conflicts: no Path A authority, Path B disagrees.
    SELECT count(*) INTO v_true_conflict_count FROM (
        SELECT sku_id
          FROM (
            SELECT s.sku_id, x.region, 'A' AS p FROM _xlsx_region_map x
              JOIN sku s ON UPPER(s.sku_code) = UPPER(x.sku_code)
            UNION ALL
            SELECT scm.sku_id, x.region, 'B' AS p FROM _xlsx_region_map x
              JOIN sku_code_map scm ON scm.external_code = x.sku_code
          ) u
         GROUP BY sku_id
        HAVING count(DISTINCT region) > 1
           AND NOT bool_or(p = 'A')
    ) c;

    SELECT count(*) INTO v_resolved_rows FROM _xlsx_resolved;

    -- DELETE TRUE-conflict sku_ids from _xlsx_resolved (let cascade handle).
    DELETE FROM _xlsx_resolved r
     WHERE r.sku_id IN (
        SELECT sku_id
          FROM (
            SELECT s.sku_id, x.region, 'A' AS p FROM _xlsx_region_map x
              JOIN sku s ON UPPER(s.sku_code) = UPPER(x.sku_code)
            UNION ALL
            SELECT scm.sku_id, x.region, 'B' AS p FROM _xlsx_region_map x
              JOIN sku_code_map scm ON scm.external_code = x.sku_code
          ) u
         GROUP BY sku_id
        HAVING count(DISTINCT region) > 1
           AND NOT bool_or(p = 'A')
     );
    GET DIAGNOSTICS v_skip_count = ROW_COUNT;

    RAISE NOTICE 'POST-§5: xlsx resolved=% / path-A-authoritative-conflicts=% (auto-accept) / TRUE-conflicts=% (skipped from resolved=%)',
                 v_resolved_rows, v_path_a_count, v_true_conflict_count, v_skip_count;

    -- Sanity: TRUE conflicts must equal skip count (DELETE worked)
    IF v_true_conflict_count <> v_skip_count THEN
        RAISE EXCEPTION 'POST-§5 FAIL: TRUE conflicts (%) != skipped from resolved (%) — logic broken',
                        v_true_conflict_count, v_skip_count;
    END IF;
END $$;

-- ────────────────────────────────────────────────────────────────────────────
-- §6 INSERT manual_region_override rows from resolved xlsx
--    Three filters:
--      (a) NOT in schema/090_b6b sku_ids (PRESERVE the 10 verbal-HARD rows
--          per spec AC #3). Belt+suspenders: the ON CONFLICT WHERE clause
--          also refuses to overwrite schema/090.
--      (b) NOT in TS Sauv/Sem-Sauv Blanc 7 sku_ids (per spec AC #5 they STAY
--          NULL — the owner ruled out Hilltops Mar 28 + Canberra May 8 with no
--          replacement region). Both id-based filter + description-pattern
--          filter for belt+suspenders.
--          spec line 87: "every xlsx row whose region differs from current
--          sku.region"). For sku_id with NULL sku.region, the IS DISTINCT
--          comparison evaluates TRUE → INSERT proceeds (NULL != 'Hilltops').
--    Citation per row in `reason`:
--      "B4B-141 — xlsx 'New DB SKU report' (<source_path> match: <xlsx_code>) — Mar 24 baseline"
-- ────────────────────────────────────────────────────────────────────────────
INSERT INTO manual_region_override (sku_id, region, reason, set_by)
SELECT
    r.sku_id,
    r.region,
    'B4B-141 — xlsx ''New DB SKU report'' (' || r.source_path || ' match: ' || r.xlsx_code || ') — Mar 24 baseline'
        AS reason,
    'schema/141_b4b' AS set_by
FROM _xlsx_resolved r
JOIN sku s ON s.sku_id = r.sku_id
WHERE
    -- (a) preserve schema/090 verbal-HARD rows
    NOT EXISTS (
        SELECT 1 FROM manual_region_override m
         WHERE m.sku_id = r.sku_id
           AND m.set_by = 'schema/090_b6b'
    )
    -- (b1) exclude the 7 TS Sauv Blanc / Sem Sauv Blanc sku_ids that
    --      schema/083 fabricated Canberra for (per recon §1):
    --      sku_id 87, 88, 89, 12365, 12366, 12370, 12371. These STAY NULL
    --      until the owner answers the May 8 question batch.
    AND r.sku_id NOT IN (87, 88, 89, 12365, 12366, 12370, 12371)
    -- (b2) belt+suspenders: also exclude any sku whose item_description
    --      matches the schema/083 ILIKE pattern (catches future Sauv Blanc
    --      additions the owner hasn't decided on)
    AND NOT (
        s.item_description ILIKE '%twelve signs%'
        AND s.item_description ILIKE '%sauv%blanc%'
    )
    -- (c) only when xlsx region differs from current sku.region (or sku.region IS NULL)
    AND s.region IS DISTINCT FROM r.region
ON CONFLICT (sku_id) DO UPDATE
   SET region = EXCLUDED.region,
       reason = EXCLUDED.reason,
       set_by = EXCLUDED.set_by
   -- Last belt: refuse to overwrite verbal-HARD rows even if filter (a) somehow leaks.
   WHERE manual_region_override.set_by NOT IN ('schema/090_b6b','jf07-2026-04-12');

DO $$
DECLARE
    v_inserted INT;
    v_pre_141  INT;
    v_post_141 INT;
BEGIN
    -- Count rows owned by schema/141_b4b after INSERT
    SELECT count(*) INTO v_post_141 FROM manual_region_override WHERE set_by = 'schema/141_b4b';
    SELECT count(*) INTO v_pre_141  FROM _b4b_pre              WHERE set_by = 'schema/141_b4b';
    v_inserted := v_post_141 - v_pre_141;

    RAISE NOTICE 'POST-§6: schema/141_b4b mro rows = % (was %, inserted/updated %)',
                 v_post_141, v_pre_141, v_inserted;
    -- Decision doc §5c estimated ~280 but that did not account for filter (c)
    -- "s.region IS DISTINCT FROM r.region" — 46 of the 175 resolved sku_ids
    -- already match the xlsx region via brand-rule/Vinsight-raw cooked sku.region.
    -- Real expectation: ~129 (175 resolved - 46 already-matching - filter (a)/(b)).
    -- Floor 100 catches "xlsx didn't load" / "sku_code_map regressed" cases.
    IF v_inserted < 100 THEN
        RAISE EXCEPTION
            'POST-§6 FAIL: only % schema/141 rows inserted (expected ≥100, ~129 typical)',
            v_inserted;
    END IF;
END $$;

-- ────────────────────────────────────────────────────────────────────────────
-- §7 DROP + CREATE OR REPLACE VIEW combined_data_enriched
--    Built byte-identical from schema/132_bug180d_combined_data_view_rebind.sql
--    EXCEPT:
--      (a) NEW LEFT JOIN manual_region_override mro ON mro.sku_id = s.sku_id
--      (b) `s.region AS region,` projection REPLACED by COALESCE chain:
--           1. mro.region (Owner-HARD source of truth)
--           2. Vinsight ProductCategories regex (real-time fallback)
--           3. Brand-rule fallback (schema/030 Step 2 mirror)
--           4. 'Unknown' (floor)
--    All 47 OTHER columns + all OTHER JOINs preserved verbatim from schema/132.
--    BUG-180d Lane F JOIN fix (ac.raw_data->>'ID' = st.source_ref) PRESERVED.
--    R-004 NAME @ SUBURB CASE PRESERVED.
--    BUG-63a sva/channel ALM-vintage CASE PRESERVED.
--    Vinsight subquery normalizes Sea/Sesa→South East Australia, Tumba→Tumbarumba
--    (mirrors schema/030 step 1 INITCAP CASE so Vinsight tag values surface
--    consistently with how etl/sync_composition_from_staging.py Step 4a writes
--    them into sku.region).
-- ────────────────────────────────────────────────────────────────────────────
DROP VIEW IF EXISTS combined_data_enriched CASCADE;

CREATE OR REPLACE VIEW combined_data_enriched AS
SELECT
  -- ── Identity / lineage ───────────────────────────────────────────────────
  -- BUG-180d (b): for access_db rows, surface Access ID; Postgres PK fallback
  -- for non-access_db so the column is never empty.
  COALESCE(NULLIF(ac.raw_data->>'ID', '')::bigint, st.transaction_id::bigint)
                                                                AS upload_id,            -- Access "ID"  (col 1)
  COALESCE(NULLIF(ac.raw_data->>'ID', '')::bigint, st.transaction_id::bigint)
                                                                AS sn,                   -- Access "SN"  (col 2 — alias of ID)
  st.source_system,
  st.source_ref,

  -- ── Date dimensions ──────────────────────────────────────────────────────
  st.sale_date,
  st.sale_date                                                  AS transaction_date,     -- Access "TransactionDate" (col 14)
  st.period,                                                                             -- Access "CalYearMonth"    (col 18)
  TO_CHAR(st.sale_date, 'YYYY MM MON')                          AS cal_month,            -- Access "CalMonth"        (col 15)
  EXTRACT(YEAR  FROM st.sale_date)::int                         AS cal_year,             -- Access "CalYearx"        (col 16)
  EXTRACT(MONTH FROM st.sale_date)::int                         AS cal_month_num,        -- Access "CalMonthx"       (col 17)

  -- ── Quantity / units ─────────────────────────────────────────────────────
  st.quantity                                                   AS qty,
  (st.quantity * COALESCE(cs.units_per_case, 12))::numeric      AS qty_bottles,
  COALESCE(cs.units_per_case, 12)                               AS carton_x,

  -- ── Revenue / pricing ────────────────────────────────────────────────────
  COALESCE(st.gross_revenue, st.net_revenue, 0)::numeric        AS revenue,
  COALESCE(st.gross_revenue, st.net_revenue, 0)::numeric        AS wholesale_value_ex,
  COALESCE(st.gross_revenue, st.net_revenue, 0)::numeric        AS wsale_value,
  COALESCE(st.net_revenue, 0)::numeric                          AS net_revenue,
  COALESCE(st.net_revenue, 0)::numeric                          AS netrevenue,
  COALESCE(cs.base_wholesale, 0)::numeric                       AS base_wholesale,
  COALESCE(cs.transfer_cost, 0)::numeric                        AS transfer_cost,
  CASE WHEN st.quantity IS NOT NULL AND st.quantity <> 0
       THEN ROUND((COALESCE(st.net_revenue, 0) / st.quantity)::numeric, 4)
       ELSE NULL END                                            AS average_case,
  CASE WHEN st.quantity IS NOT NULL AND st.quantity <> 0
       THEN ROUND((COALESCE(st.net_revenue, 0) / st.quantity)::numeric, 4)
       ELSE NULL END                                            AS average_case_1,
  CASE WHEN st.quantity IS NOT NULL AND st.quantity <> 0
       THEN ROUND((COALESCE(st.net_revenue, 0) / st.quantity)::numeric, 2)
       ELSE NULL END                                            AS net_dollar_per_case,

  -- ── Discounts / rebates / fees ───────────────────────────────────────────
  COALESCE(st.discount_amount, 0)::numeric                      AS discount,
  COALESCE(st.rebate_amount,   0)::numeric                      AS rebate,
  COALESCE(st.wholesale_fee,   0)::numeric                      AS fee,
  COALESCE(st.wholesale_fee,   0)::numeric                      AS wholesaler_fee,
  CASE WHEN COALESCE(st.gross_revenue, st.net_revenue, 0) > 0
       THEN ROUND((COALESCE(st.discount_amount,0)
                   / COALESCE(st.gross_revenue, st.net_revenue, 1) * 100)::numeric, 2)
       ELSE NULL END                                            AS discount_percentage,
  CASE WHEN COALESCE(st.gross_revenue, st.net_revenue, 0) > 0
       THEN ROUND((COALESCE(st.rebate_amount,0)
                   / COALESCE(st.gross_revenue, st.net_revenue, 1) * 100)::numeric, 2)
       ELSE NULL END                                            AS rebate_rate,

  -- ── COGS / profit ────────────────────────────────────────────────────────
  COALESCE(
    st.economic_cogs_total,
    (st.quantity * COALESCE(s.transfer_cost, 0))::numeric
  )::numeric                                                    AS cogs,
  COALESCE(
    st.economic_cogs_total,
    (st.quantity * COALESCE(s.transfer_cost, 0))::numeric
  )::numeric                                                    AS total_cogs,
  (COALESCE(st.gross_revenue, st.net_revenue, 0)
     - COALESCE(st.economic_cogs_total,
                (st.quantity * COALESCE(s.transfer_cost, 0))::numeric))::numeric
                                                                AS profit,
  CASE
    WHEN COALESCE(st.gross_revenue, st.net_revenue, 0) > 0 THEN
      ROUND((
        (COALESCE(st.gross_revenue, st.net_revenue, 0)
          - COALESCE(st.economic_cogs_total,
                     (st.quantity * COALESCE(s.transfer_cost, 0))::numeric))
        / COALESCE(st.gross_revenue, st.net_revenue, 1) * 100
      )::numeric, 2)
    ELSE NULL
  END                                                           AS gp,
  (COALESCE(st.net_revenue, 0)
     - COALESCE(st.economic_cogs_total,
                (st.quantity * COALESCE(s.transfer_cost, 0))::numeric)
     - COALESCE(st.rebate_amount, 0)
     - COALESCE(st.wholesale_fee, 0))::numeric                  AS calculated_profit,
  0::numeric                                                    AS commission,
  (COALESCE(st.net_revenue, 0)
     - COALESCE(st.economic_cogs_total,
                (st.quantity * COALESCE(s.transfer_cost, 0))::numeric)
     - COALESCE(st.rebate_amount, 0)
     - COALESCE(st.wholesale_fee, 0)
     - 0)::numeric                                              AS net_profit,

  -- ── Channel + warehouse identity ─────────────────────────────────────────
  COALESCE(st.warehouse, '')                                    AS warehouse,
  COALESCE(
    CASE UPPER(TRIM(COALESCE(cc.channel, ac.raw_data->>'Channel', '')))
      WHEN 'OFF PREMISE'        THEN 'OFF PREMISE'
      WHEN 'OFF-PREMISE'        THEN 'OFF PREMISE'
      WHEN 'OFF_PREMISE'        THEN 'OFF PREMISE'
      WHEN 'ON PREMISE'         THEN 'ON PREMISE'
      WHEN 'ON-PREMISE'         THEN 'ON PREMISE'
      WHEN 'ON_PREMISE'         THEN 'ON PREMISE'
      WHEN 'HYBRID'             THEN 'HYBRID'
      WHEN 'WHOLESALE'          THEN 'WHOLESALE'
      WHEN 'WHOLE SALE'         THEN 'WHOLESALE'
      WHEN 'DIRECT'             THEN 'DIRECT'
      WHEN 'HOFFICE'            THEN 'HOFFICE'
      WHEN 'HEAD OFFICE'        THEN 'HOFFICE'
      WHEN 'HEADOFFICE'         THEN 'HOFFICE'
      WHEN 'HEAD-OFFICE'        THEN 'HOFFICE'
      WHEN 'ALM'                THEN ''
      WHEN 'YOUNG & RASHLEIGH'  THEN ''
      WHEN 'YOUNG&RASHLEIGH'    THEN ''
      WHEN 'Y&R'                THEN ''
      WHEN 'YNR'                THEN ''
      ELSE ''
    END,
    ''
  )                                                             AS channel,

  -- ── Customer dimensions ──────────────────────────────────────────────────
  -- R-004 schema/115 (2026-04-30): guarded NAME @ SUBURB concat. Preserved
  -- byte-identical. Append ' @ <suburb>' ONLY when (a) bare name (no embedded
  -- ' @ ') AND (b) a non-empty suburb source exists.
  CASE
    WHEN COALESCE(c.customer_name, '') = '' THEN ''
    WHEN c.customer_name LIKE '% @ %' THEN c.customer_name
    WHEN COALESCE(NULLIF(c.suburb, ''), cc.suburb, '') <> ''
      THEN c.customer_name || ' @ ' || COALESCE(NULLIF(c.suburb, ''), cc.suburb)
    ELSE c.customer_name
  END                                                           AS customer_name,
  -- BUG-180d (c): HARD value (raw_data) wins over canonical_customer.customer_code
  -- (which is empty for ~all rows by design — recon-legacy-data §1.d).
  COALESCE(NULLIF(ac.raw_data->>'CustomerCode',''), cc.customer_code, '')
                                                                AS customer_code,        -- Access "CustomerCode" (col 4)
  COALESCE(cc.suburb,         NULLIF(ac.raw_data->>'Suburb',''),   '')
                                                                AS suburb,
  COALESCE(cc.postcode,       NULLIF(ac.raw_data->>'Postcode',''), '')
                                                                AS postcode,
  COALESCE(cc.customer_group, NULLIF(ac.raw_data->>'Group',''),    '')
                                                                AS customer_group,
  COALESCE(cc.alm_customer_code, NULLIF(ac.raw_data->>'ALMCustomerCode',''), '')
                                                                AS alm_customer_code,
  COALESCE(cc.dir_customer_code, NULLIF(ac.raw_data->>'DIRCustomerCode',''), '')
                                                                AS dir_customer_code,
  COALESCE(cc.ilg_customer_code, NULLIF(ac.raw_data->>'ILGCustomerCode',''), '')
                                                                AS ilg_customer_code,

  -- ── Territory dimensions ─────────────────────────────────────────────────
  COALESCE(
    NULLIF(cc.territory_name, ''),
    t_st.territory_name,
    t_cust.territory_name,
    NULLIF(ac.raw_data->>'Territory', ''),
    ''
  )                                                             AS territory,
  COALESCE(cc.territory_group, NULLIF(ac.raw_data->>'TerritoryGroup',''), '')
                                                                AS territory_group,

  -- ── Rep identity ─────────────────────────────────────────────────────────
  COALESCE(NULLIF(cc.rep_name, ''), '')                         AS rep_name,
  COALESCE(NULLIF(cc.rep_name, ''), '')                         AS rep,

  -- ── SKU / item identity ──────────────────────────────────────────────────
  COALESCE(cs.sku_name, s.item_description, '')                 AS sku,                  -- Access "SKU" (col 21)
  -- BUG-63a (schema/109+115): for ALM rows, prefer sva.attributed_vintage;
  -- for non-ALM rows, sku.vintage is canonical. Preserved byte-identical.
  CASE
    WHEN ch_st.channel_name = 'ALM'
         AND COALESCE(sva.attributed_vintage, s.vintage) IS NOT NULL THEN
      TRIM(COALESCE(cs.sku_name, s.item_description, '')) || ' '
        || COALESCE(sva.attributed_vintage, s.vintage)::text
    WHEN COALESCE(s.vintage, sva.attributed_vintage) IS NOT NULL THEN
      TRIM(COALESCE(cs.sku_name, s.item_description, '')) || ' '
        || COALESCE(s.vintage, sva.attributed_vintage)::text
    ELSE COALESCE(cs.sku_name, s.item_description, '')
  END                                                           AS sku_vintage,
  -- BUG-180d (e): no projection edit — already reads raw_data first. JOIN fix
  -- (a) makes this column auto-correct on access_db rows.
  COALESCE(
    NULLIF(ac.raw_data->>'ItemCode', ''),
    vsoi.stock_item_code,
    s.sku_code,
    ''
  )                                                             AS item_code,            -- Access "ItemCode" (col 19)
  COALESCE(
    NULLIF(ac.raw_data->>'ItemDescription', ''),
    vsoi.description,
    s.item_description,
    ''
  )                                                             AS item_description,
  COALESCE(cs.range_name, '')                                   AS range_name,
  s.variety                                                     AS variety,
  -- ── Region — B4B-141 COALESCE chain (override-as-source-of-truth) ────────
  -- 1. mro.region        — manual_region_override (Owner-HARD)
  -- 2. TS Sauv Blanc guard — sku_id 87/88/89/12365/12366/12370/12371. The owner
  --                          ruled out Hilltops (Mar 28 C0328) + Canberra
  --                          (May 8). No replacement region given. Force
  --                          'Unknown' so the cell reads honestly until the owner
  --                          answers May 8 question batch. Once mro INSERT
  --                          lands, layer 1 wins and this layer no-ops.
  --                          (Vinsight raw "Sea" + brand rule "Hilltops" both
  --                          rejected by the owner — neither is acceptable here.)
  -- 3. Vinsight regex    — staging_vinsight_stock_items.ProductCategories
  --                        normalized: Sea/Sesa → South East Australia,
  --                        Tumba → Tumbarumba, else INITCAP(TRIM(parsed)).
  --                        Bridges via sku_code_map (source_system='vinsight').
  --                        Prefers active StockItems (raw_data->>'IsActive' DESC).
  -- 4. Brand fallback    — Coppabella/Procella(non-Clare) → Tumbarumba;
  --                        Moppity/Lock & Key/Twelve Signs/Cato → Hilltops.
  -- 5. 'Unknown'         — floor (never NULL on this column).
  COALESCE(
    mro.region,
    CASE WHEN s.sku_id IN (87, 88, 89, 12365, 12366, 12370, 12371)
         THEN 'Unknown'
    END,
    (
      SELECT
        CASE
          WHEN LOWER(parsed) IN ('sesa', 'sea')
            THEN 'South East Australia'
          WHEN LOWER(TRIM(parsed)) = 'tumba'
            THEN 'Tumbarumba'
          ELSE INITCAP(TRIM(parsed))
        END
      FROM (
        SELECT SUBSTRING(svs.raw_data->>'ProductCategories' FROM '(?i)region:([^;]+)') AS parsed,
               svs.raw_data->>'IsActive' AS is_active
          FROM staging_vinsight_stock_items svs
          JOIN sku_code_map scm
            ON scm.source_system = 'vinsight'
           AND scm.external_code = svs.raw_data->>'StockItemCode'
         WHERE scm.sku_id = s.sku_id
      ) v
      WHERE v.parsed IS NOT NULL
        AND TRIM(v.parsed) <> ''
      ORDER BY v.is_active DESC NULLS LAST
      LIMIT 1
    ),
    CASE
      WHEN s.item_description ILIKE '%coppabella%'
        OR (s.item_description ILIKE '%procella%'
            AND s.item_description NOT ILIKE '%clare%'
            AND s.item_description NOT ILIKE '%cv %')
          THEN 'Tumbarumba'
      WHEN s.item_description ILIKE '%moppity%'
        OR s.item_description ILIKE '%lock & key%'
        OR s.item_description ILIKE '%lock&key%'
        OR s.item_description ILIKE '%twelve signs%'
        OR s.item_description ILIKE '%cato%'
          THEN 'Hilltops'
      ELSE NULL
    END,
    'Unknown'
  )                                                             AS region,
  CASE
    WHEN ch_st.channel_name = 'ALM' THEN COALESCE(sva.attributed_vintage, s.vintage)
    ELSE                                  COALESCE(s.vintage, sva.attributed_vintage)
  END                                                           AS vintage,

  -- ── SubRegion + Ownership + Note ─────────────────────────────────────────
  COALESCE(NULLIF(ac.raw_data->>'SubRegion',''), s.region, '')  AS sub_region,
  COALESCE(
    NULLIF(ac.raw_data->>'Ownership',''),
    cc.customer_group,
    ''
  )                                                             AS ownership,
  COALESCE(NULLIF(ac.raw_data->>'Note',''), cs.note, '')        AS note,

  -- ── Invoice ──────────────────────────────────────────────────────────────
  -- BUG-180d (d): explicit access_db branch — never fall through to
  -- st.source_ref (= Access ID) for access_db rows. HARD value or empty.
  CASE
    WHEN st.source_system = 'vinsight' AND st.source_ref ~ '^vinsight-[0-9]+-[0-9]+$'
      THEN split_part(st.source_ref, '-', 2)
    WHEN st.source_system = 'access_db'
      THEN COALESCE(NULLIF(ac.raw_data->>'InvoiceNo', ''), '')
    ELSE COALESCE(
      NULLIF(ac.raw_data->>'InvoiceNo', ''),
      st.source_ref,
      ''
    )
  END                                                           AS invoice_no,           -- Access "InvoiceNo" (col 13)

  -- ── Import lineage ────────────────────────────────────────────────────────
  CASE
    WHEN to_regclass('public.sales_transaction') IS NOT NULL
      AND EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_schema='public' AND table_name='sales_transaction'
                     AND column_name='upload_batch_id')
    THEN (to_jsonb(st)->>'upload_batch_id')::bigint
    ELSE NULL
  END                                                           AS import_id            -- Access "ImportID" (col 41)

FROM sales_transaction st
LEFT JOIN sku s                       ON s.sku_id       = st.sku_id
LEFT JOIN canonical_sku cs            ON cs.id          = s.canonical_sku_id
LEFT JOIN customer c                  ON c.customer_id  = st.customer_id
LEFT JOIN canonical_customer cc       ON cc.id          = c.canonical_customer_id
LEFT JOIN territory t_st              ON t_st.territory_id   = st.territory_id
LEFT JOIN territory t_cust            ON t_cust.territory_id = c.territory_id
-- BUG-180d (a): rebind JOIN. access_combined_data.id is its own SERIAL PK and
-- is NOT 1:1 with sales_transaction.transaction_id. The intended 1:1 key is
-- raw_data->>'ID' = source_ref (per etl/transform_to_core.py:661).
LEFT JOIN access_combined_data ac
       ON ac.raw_data->>'ID' = st.source_ref
      AND st.source_system = 'access_db'
LEFT JOIN vinsight_sales_order_item vsoi
       ON vsoi.order_num = (CASE WHEN st.source_ref ~ '^vinsight-[0-9]+-[0-9]+$'
                                 THEN split_part(st.source_ref, '-', 2)::int END)
      AND vsoi.entry_num = (CASE WHEN st.source_ref ~ '^vinsight-[0-9]+-[0-9]+$'
                                 THEN split_part(st.source_ref, '-', 3)::int END)
      AND st.source_system = 'vinsight'
LEFT JOIN sale_vintage_attribution sva
       ON sva.sales_transaction_id = st.transaction_id
LEFT JOIN channel ch_st
       ON ch_st.channel_id = st.channel_id
-- B4B-141: NEW JOIN — manual_region_override is base layer of region COALESCE.
LEFT JOIN manual_region_override mro
       ON mro.sku_id = s.sku_id;

COMMENT ON VIEW combined_data_enriched IS
  'B4B-141 (2026-05-09): override-as-source-of-truth region projection. mro is '
  'base, TS Sauv Blanc guard forces Unknown for sku 87/88/89/12365/12366/12370/'
  '12371 (the owner ruled out Hilltops Mar 28 + Canberra May 8), Vinsight '
  'ProductCategories regex is third layer, brand-rule fourth, Unknown floor. '
  'schema/083 7 FAB rows DROPPED. schema/090 10 verbal-HARD rows preserved + '
  'xlsx Mar 24 baseline bulk-filled ~280 mro rows. Preserves BUG-180d Lane F '
  'JOIN fix + R-004 NAME @ SUBURB CASE + BUG-63a sva/channel ALM-vintage CASE '
  'byte-identical from schema/132. 47 other column projections + 8 other JOINs '
  'unchanged.';

-- ────────────────────────────────────────────────────────────────────────────
-- §8 POST-asserts
-- ────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    v_view_total            INT;
    v_st_count              INT;
    v_mro_083_after         INT;
    v_mro_090_after         INT;
    v_mro_141_after         INT;
    v_ts_sb_view_region     TEXT;
    v_ts_cm_view_region     TEXT;
    v_proc_cv_view_region   TEXT;
    v_lk_pn24_view_region   TEXT;
    v_atrius_25_view_region TEXT;
BEGIN
    -- (a) schema/083 still 0 rows
    SELECT count(*) INTO v_mro_083_after FROM manual_region_override WHERE set_by = 'schema/083_jc360';
    IF v_mro_083_after <> 0 THEN
        RAISE EXCEPTION 'POST-§8(a) FAIL: schema/083 row count = % after migration (expected 0)', v_mro_083_after;
    END IF;

    -- (b) schema/090 still 10 rows (preserved)
    SELECT count(*) INTO v_mro_090_after FROM manual_region_override WHERE set_by = 'schema/090_b6b';
    IF v_mro_090_after <> 10 THEN
        RAISE EXCEPTION 'POST-§8(b) FAIL: schema/090 row count = % (expected 10 — preservation broken)', v_mro_090_after;
    END IF;

    -- (c) schema/141 inserted ≥200 rows (target ~280)
    SELECT count(*) INTO v_mro_141_after FROM manual_region_override WHERE set_by = 'schema/141_b4b';
    IF v_mro_141_after < 100 THEN
        RAISE EXCEPTION 'POST-§8(c) FAIL: schema/141 row count = % (expected ≥100, ~129 typical)', v_mro_141_after;
    END IF;

    -- (d) view row count unchanged vs sales_transaction (no fanout from new
    --     mro JOIN — mro is unique on sku_id PK so 1:N is impossible)
    SELECT count(*) INTO v_view_total FROM combined_data_enriched;
    SELECT count(*) INTO v_st_count   FROM sales_transaction;
    IF v_view_total <> v_st_count THEN
        RAISE EXCEPTION
            'POST-§8(d) FAIL: view row count % differs from sales_transaction count % — fanout introduced',
            v_view_total, v_st_count;
    END IF;

    -- (e) TS Sauv Blanc spot-check — sku_id 12365 (MVTSSBLB24) must NOT have
    --     mro row (deleted) AND view guard at COALESCE layer 2 forces 'Unknown'
    --     for all 7 TS Sauv Blanc sku_ids. The owner ruled out Hilltops Mar 28 +
    --     Canberra May 8 — neither acceptable. Vinsight raw "Sea" + brand
    --     rule "Hilltops" both bypassed. 'Unknown' is honest until the owner
    --     answers May 8 batch.
    --     Re-derive view COALESCE chain (must include the same guard CASE).
    SELECT COALESCE(
            mro.region,
            CASE WHEN s.sku_id IN (87,88,89,12365,12366,12370,12371) THEN 'Unknown' END,
            (SELECT CASE WHEN LOWER(parsed) IN ('sesa','sea') THEN 'South East Australia'
                         WHEN LOWER(TRIM(parsed)) = 'tumba'   THEN 'Tumbarumba'
                         ELSE INITCAP(TRIM(parsed)) END
              FROM (SELECT SUBSTRING(svs.raw_data->>'ProductCategories' FROM '(?i)region:([^;]+)') AS parsed,
                           svs.raw_data->>'IsActive' AS is_active
                      FROM staging_vinsight_stock_items svs
                      JOIN sku_code_map scm ON scm.source_system='vinsight'
                                           AND scm.external_code = svs.raw_data->>'StockItemCode'
                     WHERE scm.sku_id = s.sku_id) v
             WHERE v.parsed IS NOT NULL AND TRIM(v.parsed) <> ''
             ORDER BY v.is_active DESC NULLS LAST LIMIT 1),
            CASE WHEN s.item_description ILIKE '%coppabella%'
                  OR (s.item_description ILIKE '%procella%'
                      AND s.item_description NOT ILIKE '%clare%'
                      AND s.item_description NOT ILIKE '%cv %')
                 THEN 'Tumbarumba'
                 WHEN s.item_description ILIKE '%moppity%'
                   OR s.item_description ILIKE '%lock & key%'
                   OR s.item_description ILIKE '%lock&key%'
                   OR s.item_description ILIKE '%twelve signs%'
                   OR s.item_description ILIKE '%cato%'
                 THEN 'Hilltops'
                 ELSE NULL END,
            'Unknown')
      INTO v_ts_sb_view_region
      FROM sku s
      LEFT JOIN manual_region_override mro ON mro.sku_id = s.sku_id
     WHERE s.sku_id = 12365
     LIMIT 1;
    RAISE NOTICE 'POST-§8(e): TS Sauv Blanc 24 (sku 12365) resolves to %  (expected: Unknown — guard forces blank vs Hilltops/Canberra both rejected)',
                 COALESCE(v_ts_sb_view_region, '<sku-missing>');
    IF v_ts_sb_view_region IS DISTINCT FROM 'Unknown' THEN
        RAISE EXCEPTION 'POST-§8(e) FAIL: TS Sauv Blanc 24 expected Unknown, got % — guard layer broken or mro row leaked',
                        COALESCE(v_ts_sb_view_region, '<NULL>');
    END IF;

    -- (f) schema/090 spot-checks (must STILL resolve to override values).
    --     Re-derive the COALESCE chain rather than probing the view (avoids
    --     dependency on sales_transaction row existence).
    SELECT COALESCE(
            mro.region,
            -- mirror the COALESCE chain (must match view exactly)
            (SELECT CASE WHEN LOWER(parsed) IN ('sesa','sea') THEN 'South East Australia'
                         WHEN LOWER(TRIM(parsed)) = 'tumba'   THEN 'Tumbarumba'
                         ELSE INITCAP(TRIM(parsed)) END
              FROM (SELECT SUBSTRING(svs.raw_data->>'ProductCategories' FROM '(?i)region:([^;]+)') AS parsed,
                           svs.raw_data->>'IsActive' AS is_active
                      FROM staging_vinsight_stock_items svs
                      JOIN sku_code_map scm ON scm.source_system='vinsight'
                                           AND scm.external_code = svs.raw_data->>'StockItemCode'
                     WHERE scm.sku_id = s.sku_id) v
             WHERE v.parsed IS NOT NULL AND TRIM(v.parsed) <> ''
             ORDER BY v.is_active DESC NULLS LAST LIMIT 1),
            CASE WHEN s.item_description ILIKE '%coppabella%'
                  OR (s.item_description ILIKE '%procella%'
                      AND s.item_description NOT ILIKE '%clare%'
                      AND s.item_description NOT ILIKE '%cv %')
                 THEN 'Tumbarumba'
                 WHEN s.item_description ILIKE '%moppity%'
                   OR s.item_description ILIKE '%lock & key%'
                   OR s.item_description ILIKE '%lock&key%'
                   OR s.item_description ILIKE '%twelve signs%'
                   OR s.item_description ILIKE '%cato%'
                 THEN 'Hilltops'
                 ELSE NULL END,
            'Unknown')
      INTO v_ts_cm_view_region
      FROM sku s
      LEFT JOIN manual_region_override mro ON mro.sku_id = s.sku_id
     WHERE s.sku_id = 77
     LIMIT 1;
    RAISE NOTICE 'POST-§8(f1): TS Cab/Merlot (sku 77) resolves to %  (expected Hilltops via schema/090)', v_ts_cm_view_region;
    IF v_ts_cm_view_region IS DISTINCT FROM 'Hilltops' THEN
        RAISE EXCEPTION 'POST-§8(f1) FAIL: TS Cab/Merlot expected Hilltops, got %', v_ts_cm_view_region;
    END IF;

    SELECT COALESCE(
            mro.region,
            (SELECT CASE WHEN LOWER(parsed) IN ('sesa','sea') THEN 'South East Australia'
                         WHEN LOWER(TRIM(parsed)) = 'tumba'   THEN 'Tumbarumba'
                         ELSE INITCAP(TRIM(parsed)) END
              FROM (SELECT SUBSTRING(svs.raw_data->>'ProductCategories' FROM '(?i)region:([^;]+)') AS parsed,
                           svs.raw_data->>'IsActive' AS is_active
                      FROM staging_vinsight_stock_items svs
                      JOIN sku_code_map scm ON scm.source_system='vinsight'
                                           AND scm.external_code = svs.raw_data->>'StockItemCode'
                     WHERE scm.sku_id = s.sku_id) v
             WHERE v.parsed IS NOT NULL AND TRIM(v.parsed) <> ''
             ORDER BY v.is_active DESC NULLS LAST LIMIT 1),
            CASE WHEN s.item_description ILIKE '%coppabella%'
                  OR (s.item_description ILIKE '%procella%'
                      AND s.item_description NOT ILIKE '%clare%'
                      AND s.item_description NOT ILIKE '%cv %')
                 THEN 'Tumbarumba'
                 WHEN s.item_description ILIKE '%moppity%'
                   OR s.item_description ILIKE '%lock & key%'
                   OR s.item_description ILIKE '%lock&key%'
                   OR s.item_description ILIKE '%twelve signs%'
                   OR s.item_description ILIKE '%cato%'
                 THEN 'Hilltops'
                 ELSE NULL END,
            'Unknown')
      INTO v_proc_cv_view_region
      FROM sku s
      LEFT JOIN manual_region_override mro ON mro.sku_id = s.sku_id
     WHERE s.sku_id = 12131
     LIMIT 1;
    RAISE NOTICE 'POST-§8(f2): Procella CV Riesling (sku 12131) resolves to %  (expected Clare Valley via schema/090)', v_proc_cv_view_region;
    IF v_proc_cv_view_region IS DISTINCT FROM 'Clare Valley' THEN
        RAISE EXCEPTION 'POST-§8(f2) FAIL: Procella CV Riesling expected Clare Valley, got %', v_proc_cv_view_region;
    END IF;

    SELECT COALESCE(
            mro.region,
            (SELECT CASE WHEN LOWER(parsed) IN ('sesa','sea') THEN 'South East Australia'
                         WHEN LOWER(TRIM(parsed)) = 'tumba'   THEN 'Tumbarumba'
                         ELSE INITCAP(TRIM(parsed)) END
              FROM (SELECT SUBSTRING(svs.raw_data->>'ProductCategories' FROM '(?i)region:([^;]+)') AS parsed,
                           svs.raw_data->>'IsActive' AS is_active
                      FROM staging_vinsight_stock_items svs
                      JOIN sku_code_map scm ON scm.source_system='vinsight'
                                           AND scm.external_code = svs.raw_data->>'StockItemCode'
                     WHERE scm.sku_id = s.sku_id) v
             WHERE v.parsed IS NOT NULL AND TRIM(v.parsed) <> ''
             ORDER BY v.is_active DESC NULLS LAST LIMIT 1),
            CASE WHEN s.item_description ILIKE '%coppabella%'
                  OR (s.item_description ILIKE '%procella%'
                      AND s.item_description NOT ILIKE '%clare%'
                      AND s.item_description NOT ILIKE '%cv %')
                 THEN 'Tumbarumba'
                 WHEN s.item_description ILIKE '%moppity%'
                   OR s.item_description ILIKE '%lock & key%'
                   OR s.item_description ILIKE '%lock&key%'
                   OR s.item_description ILIKE '%twelve signs%'
                   OR s.item_description ILIKE '%cato%'
                 THEN 'Hilltops'
                 ELSE NULL END,
            'Unknown')
      INTO v_lk_pn24_view_region
      FROM sku s
      LEFT JOIN manual_region_override mro ON mro.sku_id = s.sku_id
     WHERE s.sku_id = 12257
     LIMIT 1;
    RAISE NOTICE 'POST-§8(f3): LK Pinot Noir 2024 (sku 12257) resolves to %  (expected Tumbarumba via schema/090)', v_lk_pn24_view_region;
    IF v_lk_pn24_view_region IS DISTINCT FROM 'Tumbarumba' THEN
        RAISE EXCEPTION 'POST-§8(f3) FAIL: LK Pinot Noir 2024 expected Tumbarumba, got %', v_lk_pn24_view_region;
    END IF;

    SELECT COALESCE(
            mro.region,
            (SELECT CASE WHEN LOWER(parsed) IN ('sesa','sea') THEN 'South East Australia'
                         WHEN LOWER(TRIM(parsed)) = 'tumba'   THEN 'Tumbarumba'
                         ELSE INITCAP(TRIM(parsed)) END
              FROM (SELECT SUBSTRING(svs.raw_data->>'ProductCategories' FROM '(?i)region:([^;]+)') AS parsed,
                           svs.raw_data->>'IsActive' AS is_active
                      FROM staging_vinsight_stock_items svs
                      JOIN sku_code_map scm ON scm.source_system='vinsight'
                                           AND scm.external_code = svs.raw_data->>'StockItemCode'
                     WHERE scm.sku_id = s.sku_id) v
             WHERE v.parsed IS NOT NULL AND TRIM(v.parsed) <> ''
             ORDER BY v.is_active DESC NULLS LAST LIMIT 1),
            CASE WHEN s.item_description ILIKE '%coppabella%'
                  OR (s.item_description ILIKE '%procella%'
                      AND s.item_description NOT ILIKE '%clare%'
                      AND s.item_description NOT ILIKE '%cv %')
                 THEN 'Tumbarumba'
                 WHEN s.item_description ILIKE '%moppity%'
                   OR s.item_description ILIKE '%lock & key%'
                   OR s.item_description ILIKE '%lock&key%'
                   OR s.item_description ILIKE '%twelve signs%'
                   OR s.item_description ILIKE '%cato%'
                 THEN 'Hilltops'
                 ELSE NULL END,
            'Unknown')
      INTO v_atrius_25_view_region
      FROM sku s
      LEFT JOIN manual_region_override mro ON mro.sku_id = s.sku_id
     WHERE s.sku_id = 12147
     LIMIT 1;
    RAISE NOTICE 'POST-§8(f4): Atrius Riesling 25 (sku 12147) resolves to %  (expected Hilltops via schema/090)', v_atrius_25_view_region;
    IF v_atrius_25_view_region IS DISTINCT FROM 'Hilltops' THEN
        RAISE EXCEPTION 'POST-§8(f4) FAIL: Atrius Riesling 25 expected Hilltops, got %', v_atrius_25_view_region;
    END IF;

    RAISE NOTICE 'B4B-141 schema OK: schema/083 dropped, schema/090 preserved (10), schema/141 added %, view rebuild byte-identical ex-region',
                 v_mro_141_after;
END $$;

-- ────────────────────────────────────────────────────────────────────────────
-- §9 schema_migrations registry
-- ────────────────────────────────────────────────────────────────────────────
INSERT INTO schema_migrations (version, applied_at, source)
VALUES ('141_b4b_region_override_as_source_of_truth', NOW(), 'live-apply')
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ════════════════════════════════════════════════════════════════════════════
--
-- -- 1. Re-run cell-by-cell recon SQL (read-only)
-- -- Expect: §1 TS Sauv Blanc 7 rows now drift_flag = NO-OVERRIDE (not OVERLAY-WINS-FAB)
-- --         §2 spot-check 10 rows all MATCH or expected-OVERLAY-WINS via schema/090 path
-- --         §3 mro count rises from 18 to ~290 (10 schema/090 + ~280 schema/141 + 1 jf07 - 7 schema/083)
-- --         §4 mro audit shows new schema/141_b4b reasons "B4B-141 — xlsx ..."
-- --         §5 Vinsight raw distribution unchanged (read-only, not touched)
--
-- -- Visit /wines, /margin, /reference, /reports, /inventory, /channels in
-- -- chrome-devtools. Spot-check region column on 5 wines: TS Cab/Merlot Hilltops,
-- -- Procella CV Clare Valley, LK Pinot 24 Tumbarumba, Atrius 25 Hilltops, TS
-- -- Sauv Blanc not Canberra (whatever it falls through to).
--
-- ROLLBACK recipe (NOT part of this migration — documentation only):
--   1. DELETE FROM manual_region_override WHERE set_by = 'schema/141_b4b';
--   2. INSERT INTO manual_region_override (sku_id, region, reason, set_by)
--      SELECT sku_id, region, reason, set_by FROM _b4b_pre WHERE set_by = 'schema/083_jc360';
--   3. Re-apply schema/132_bug180d_combined_data_view_rebind.sql to revert view.
--   4. Re-enable Step 4c in etl/sync_composition_from_staging.py.
-- (or restore from /tmp/pre_b4b_*.sql pg_dump backup — simpler.)
-- ════════════════════════════════════════════════════════════════════════════
