-- ════════════════════════════════════════════════════════════════════════════
-- schema/104_b10b_legacy_access_reports.sql
-- Preserve 14 pre-built Access reporting tables as queryable Postgres tables.
-- ════════════════════════════════════════════════════════════════════════════
-- Date: 2026-04-28
-- Bundle: B10b (Legacy Access Reports — data-side half of B10)
--
--   - 14 pre-built report tables: extract-accdb.md line 73 + mdb-tables on
--   - Column lists: mdb-export <accdb> <table> | head -1 (verified 2026-04-28).
--   - Row counts (Access): tblAnalysisReport=94, tblDistributionByRange_16=0,
--     tblDistributionByRangeND18=3, tblDistributionByRangeTD18=5,
--     tblDistributionByRangeLD18=1, tblTop10OpportunitiesTerritory_11a=55,
--     tblTop10OpportunitiesWhole_11a=73,
--     TerritoryDistributionPerformanceReport=40, tblCustomerPerformance_17=0,
--     tblSamplesTerritory=35, xtblSelectTerritory=1, tblDIRNotFoundReps=1,
--     xtblSalesByRangeChart=395, xtblSalesByRangeTotalChart=36.
--
-- Note: spec text says "13 preserved Access reports" but mdb-tables confirms
-- 14 distinct reporting tables. We ship all 14 — clarification logged so
-- The owner can confirm "14 not 13" is correct.
--
-- DESIGN — column-faithful preservation:
--   We mirror Access column names verbatim (lower-snake-case in Postgres).
--   All numeric metrics use NUMERIC (no precision/scale to preserve raw fidelity).
--   All text fields use TEXT. Dates are TEXT (Access stores them as ISO via
--   mdb-export; if the owner needs date math, B10c can ALTER COLUMN to DATE).
--   Every table carries `_imported_at TIMESTAMPTZ DEFAULT NOW()` audit column
--   so /api/legacy-reports can show "last refreshed" without a join.
--
-- FORWARD-ONLY (ADR-015):
--   - All `CREATE TABLE IF NOT EXISTS` — re-running is safe.
--   - No existing prod table named tbl_* in this list (verified via
--     extract-accdb.md "NEW tables not in our prior project context").
--
-- BLAST RADIUS: zero — new tables, no existing reads. ETL writes via
-- etl/import_legacy_access_reports.py (B10b) only.
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ────────────────────────────────────────────────────────────────────────────
-- 1. PRE-state assertion
-- ────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
  v_existing TEXT[];
BEGIN
  SELECT ARRAY_AGG(table_name ORDER BY table_name)
    INTO v_existing
    FROM information_schema.tables
   WHERE table_schema = 'public'
     AND table_name IN (
       'tbl_analysis_report',
       'tbl_distribution_by_range_16',
       'tbl_distribution_by_range_nd18',
       'tbl_distribution_by_range_td18',
       'tbl_distribution_by_range_ld18',
       'tbl_top10_opportunities_territory_11a',
       'tbl_top10_opportunities_whole_11a',
       'tbl_territory_distribution_performance_report',
       'tbl_customer_performance_17',
       'tbl_samples_territory',
       'tbl_xtbl_select_territory',
       'tbl_dir_not_found_reps',
       'tbl_xtbl_sales_by_range_chart',
       'tbl_xtbl_sales_by_range_total_chart'
     );
  RAISE NOTICE 'B10b PRE: pre-existing legacy report tables=%',
    COALESCE(v_existing, ARRAY[]::TEXT[]);
END;
$$;

-- ────────────────────────────────────────────────────────────────────────────
-- 2. tbl_analysis_report (Access: tblAnalysisReport, 94 rows, 14 cols)
--    Header: Territory,TotalCases,TotalBaseWholesale,TotalDiscount,
--            TotalRebate,TotalWholesalerFee,TotalProfit,Samples,What,
--            ProfitBeforeLS,GpWhat,WhatYear,GrossProfitPercentage,
--            GrossProfitDollarPerCase
-- ────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS tbl_analysis_report (
    id                              SERIAL PRIMARY KEY,
    territory                       TEXT,
    total_cases                     NUMERIC,
    total_base_wholesale            NUMERIC,
    total_discount                  NUMERIC,
    total_rebate                    NUMERIC,
    total_wholesaler_fee            NUMERIC,
    total_profit                    NUMERIC,
    samples                         NUMERIC,
    what                            TEXT,
    profit_before_ls                NUMERIC,
    gp_what                         TEXT,
    what_year                       TEXT,
    gross_profit_percentage         NUMERIC,
    gross_profit_dollar_per_case    NUMERIC,
    _imported_at                    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE tbl_analysis_report IS
  'B10b legacy Access report: tblAnalysisReport (94 rows). Pre-built territory '
  'analysis with cases/wholesale/discount/profit totals + GP metrics. Read-only.';

-- ────────────────────────────────────────────────────────────────────────────
-- 3. tbl_distribution_by_range_16 (Access: tblDistributionByRange_16, 0 rows)
--    17 cols: TotalFor + xOrder + 15 brand-name columns.
--    Brand columns are dynamic; preserved as TEXT to match Access schema.
-- ────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS tbl_distribution_by_range_16 (
    id                  SERIAL PRIMARY KEY,
    total_for           TEXT,
    x_order             NUMERIC,
    atrius              NUMERIC,
    block               NUMERIC,
    cato                NUMERIC,
    coppabella          NUMERIC,
    coppabella_crest    NUMERIC,
    coppabella_procella NUMERIC,
    coppabella_sirius   NUMERIC,
    crafted             NUMERIC,
    lock_and_key        NUMERIC,
    moppity_estate      NUMERIC,
    moppity_reserve     NUMERIC,
    mv_exclusive        NUMERIC,
    oppabella_procella  NUMERIC,
    other               NUMERIC,
    twelve_signs        NUMERIC,
    _imported_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE tbl_distribution_by_range_16 IS
  'B10b legacy Access report: tblDistributionByRange_16 (0 rows in Access — '
  'placeholder for the 16-brand distribution view). Read-only.';

-- ────────────────────────────────────────────────────────────────────────────
-- 4. tbl_distribution_by_range_nd18 (Access: tblDistributionByRangeND18, 3 rows)
--    42 cols: NDCustomerName, xOrder, NDTotal + 39 brand-prefixed ND* cols.
-- ────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS tbl_distribution_by_range_nd18 (
    id                                  SERIAL PRIMARY KEY,
    nd_customer_name                    TEXT,
    x_order                             NUMERIC,
    nd_total                            NUMERIC,
    nd_argo                             NUMERIC,
    nd_atrius                           NUMERIC,
    nd_brothers_at_large                NUMERIC,
    nd_cato                             NUMERIC,
    nd_chalice_bridge_estate            NUMERIC,
    nd_chalice_bridge_quest             NUMERIC,
    nd_chalice_bridge_sorcerers         NUMERIC,
    nd_chalice_bridge_the_chalice       NUMERIC,
    nd_chalice_chapman                  NUMERIC,
    nd_chalice_sorcerers                NUMERIC,
    nd_coppabella                       NUMERIC,
    nd_coppabella_crest                 NUMERIC,
    nd_coppabella_sirius                NUMERIC,
    nd_darling_wines                    NUMERIC,
    nd_deep_river                       NUMERIC,
    nd_ernest                           NUMERIC,
    nd_hex_and_heysen                   NUMERIC,
    nd_kirikiri                         NUMERIC,
    nd_kokori                           NUMERIC,
    nd_little_darling                   NUMERIC,
    nd_lock_and_key                     NUMERIC,
    nd_lock_and_key_reserve             NUMERIC,
    nd_moppity                          NUMERIC,
    nd_moppity_block                    NUMERIC,
    nd_moppity_canberra                 NUMERIC,
    nd_moppity_estate                   NUMERIC,
    nd_moppity_reserve                  NUMERIC,
    nd_mv_exclusive                     NUMERIC,
    nd_na                               NUMERIC,
    nd_other                            NUMERIC,
    nd_purple_hands                     NUMERIC,
    nd_reillys_barking_mad              NUMERIC,
    nd_reillys_black_label              NUMERIC,
    nd_reillys_dry_land                 NUMERIC,
    nd_reillys_ryder                    NUMERIC,
    nd_reillys_stolen_block             NUMERIC,
    nd_single_step                      NUMERIC,
    nd_swinging_bridge                  NUMERIC,
    nd_twelve_signs                     NUMERIC,
    nd_windowrie                        NUMERIC,
    _imported_at                        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE tbl_distribution_by_range_nd18 IS
  'B10b legacy Access report: tblDistributionByRangeND18 (3 rows). New '
  'Distribution by Range — 18-brand cut. Read-only.';

-- ────────────────────────────────────────────────────────────────────────────
-- 5. tbl_distribution_by_range_td18 (Access: tblDistributionByRangeTD18, 5 rows)
--    42 cols (same shape as ND18 but uppercase brand cols, no ND/LD prefix).
-- ────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS tbl_distribution_by_range_td18 (
    id                                  SERIAL PRIMARY KEY,
    customer_name                       TEXT,
    x_order                             NUMERIC,
    total                               NUMERIC,
    argo                                NUMERIC,
    atrius                              NUMERIC,
    brothers_at_large                   NUMERIC,
    cato                                NUMERIC,
    chalice_bridge_estate               NUMERIC,
    chalice_bridge_quest                NUMERIC,
    chalice_bridge_sorcerers            NUMERIC,
    chalice_bridge_the_chalice          NUMERIC,
    chalice_chapman                     NUMERIC,
    chalice_sorcerers                   NUMERIC,
    coppabella                          NUMERIC,
    coppabella_crest                    NUMERIC,
    coppabella_sirius                   NUMERIC,
    darling_wines                       NUMERIC,
    deep_river                          NUMERIC,
    ernest                              NUMERIC,
    hex_and_heysen                      NUMERIC,
    kirikiri                            NUMERIC,
    kokori                              NUMERIC,
    little_darling                      NUMERIC,
    lock_and_key                        NUMERIC,
    lock_and_key_reserve                NUMERIC,
    moppity                             NUMERIC,
    moppity_block                       NUMERIC,
    moppity_canberra                    NUMERIC,
    moppity_estate                      NUMERIC,
    moppity_reserve                     NUMERIC,
    mv_exclusive                        NUMERIC,
    na                                  NUMERIC,
    other                               NUMERIC,
    purple_hands                        NUMERIC,
    reillys_barking_mad                 NUMERIC,
    reillys_black_label                 NUMERIC,
    reillys_dry_land                    NUMERIC,
    reillys_ryder                       NUMERIC,
    reillys_stolen_block                NUMERIC,
    single_step                         NUMERIC,
    swinging_bridge                     NUMERIC,
    twelve_signs                        NUMERIC,
    windowrie                           NUMERIC,
    _imported_at                        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE tbl_distribution_by_range_td18 IS
  'B10b legacy Access report: tblDistributionByRangeTD18 (5 rows). Total '
  'Distribution by Range — 18-brand cut. Read-only.';

-- ────────────────────────────────────────────────────────────────────────────
-- 6. tbl_distribution_by_range_ld18 (Access: tblDistributionByRangeLD18, 1 row)
--    42 cols, LD-prefix variant of the same shape.
-- ────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS tbl_distribution_by_range_ld18 (
    id                                  SERIAL PRIMARY KEY,
    ld_customer_name                    TEXT,
    x_order                             NUMERIC,
    ld_total                            NUMERIC,
    ld_argo                             NUMERIC,
    ld_atrius                           NUMERIC,
    ld_brothers_at_large                NUMERIC,
    ld_cato                             NUMERIC,
    ld_chalice_bridge_estate            NUMERIC,
    ld_chalice_bridge_quest             NUMERIC,
    ld_chalice_bridge_sorcerers         NUMERIC,
    ld_chalice_bridge_the_chalice       NUMERIC,
    ld_chalice_chapman                  NUMERIC,
    ld_chalice_sorcerers                NUMERIC,
    ld_coppabella                       NUMERIC,
    ld_coppabella_crest                 NUMERIC,
    ld_coppabella_sirius                NUMERIC,
    ld_darling_wines                    NUMERIC,
    ld_deep_river                       NUMERIC,
    ld_ernest                           NUMERIC,
    ld_hex_and_heysen                   NUMERIC,
    ld_kirikiri                         NUMERIC,
    ld_kokori                           NUMERIC,
    ld_little_darling                   NUMERIC,
    ld_lock_and_key                     NUMERIC,
    ld_lock_and_key_reserve             NUMERIC,
    ld_moppity                          NUMERIC,
    ld_moppity_block                    NUMERIC,
    ld_moppity_canberra                 NUMERIC,
    ld_moppity_estate                   NUMERIC,
    ld_moppity_reserve                  NUMERIC,
    ld_mv_exclusive                     NUMERIC,
    ld_na                               NUMERIC,
    ld_other                            NUMERIC,
    ld_purple_hands                     NUMERIC,
    ld_reillys_barking_mad              NUMERIC,
    ld_reillys_black_label              NUMERIC,
    ld_reillys_dry_land                 NUMERIC,
    ld_reillys_ryder                    NUMERIC,
    ld_reillys_stolen_block             NUMERIC,
    ld_single_step                      NUMERIC,
    ld_swinging_bridge                  NUMERIC,
    ld_twelve_signs                     NUMERIC,
    ld_windowrie                        NUMERIC,
    _imported_at                        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE tbl_distribution_by_range_ld18 IS
  'B10b legacy Access report: tblDistributionByRangeLD18 (1 row). Lost '
  'Distribution by Range — 18-brand cut. Read-only.';

-- ────────────────────────────────────────────────────────────────────────────
-- 7. tbl_top10_opportunities_territory_11a (55 rows, 3 cols)
--    Header: TSKU, TTotalCases, TID
-- ────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS tbl_top10_opportunities_territory_11a (
    id              SERIAL PRIMARY KEY,
    t_sku           TEXT,
    t_total_cases   NUMERIC,
    t_id            NUMERIC,
    _imported_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE tbl_top10_opportunities_territory_11a IS
  'B10b legacy Access report: tblTop10OpportunitiesTerritory_11a (55 rows). '
  'Pre-built top-10 territory opportunities by SKU. Read-only.';

-- ────────────────────────────────────────────────────────────────────────────
-- 8. tbl_top10_opportunities_whole_11a (73 rows, 3 cols)
--    Header: WSKU, WTotalCases, WID
-- ────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS tbl_top10_opportunities_whole_11a (
    id              SERIAL PRIMARY KEY,
    w_sku           TEXT,
    w_total_cases   NUMERIC,
    w_id            NUMERIC,
    _imported_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE tbl_top10_opportunities_whole_11a IS
  'B10b legacy Access report: tblTop10OpportunitiesWhole_11a (73 rows). '
  'Pre-built top-10 wholesale opportunities by SKU. Read-only.';

-- ────────────────────────────────────────────────────────────────────────────
-- 9. tbl_territory_distribution_performance_report (40 rows, 15 cols)
--    Header: Territory,ToTalDist,NewDist,LostDist,TYMTD$,LYMTD$,MTDDiff$,
--            TYYTD$,LYYTD$,YTDDiff$,RefDate,ACMTD,AC6Month,DistrPerAC,ACYTD
-- ────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS tbl_territory_distribution_performance_report (
    id                  SERIAL PRIMARY KEY,
    territory           TEXT,
    total_dist          NUMERIC,
    new_dist            NUMERIC,
    lost_dist           NUMERIC,
    ty_mtd_dollar       NUMERIC,
    ly_mtd_dollar       NUMERIC,
    mtd_diff_dollar     NUMERIC,
    ty_ytd_dollar       NUMERIC,
    ly_ytd_dollar       NUMERIC,
    ytd_diff_dollar     NUMERIC,
    ref_date            TEXT,
    ac_mtd              NUMERIC,
    ac_6_month          NUMERIC,
    distr_per_ac        NUMERIC,
    ac_ytd              NUMERIC,
    _imported_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE tbl_territory_distribution_performance_report IS
  'B10b legacy Access report: TerritoryDistributionPerformanceReport (40 rows). '
  'Pre-built territory distribution performance with TY/LY MTD+YTD + AC perf. '
  'Read-only.';

-- ────────────────────────────────────────────────────────────────────────────
-- 10. tbl_customer_performance_17 (0 rows in Access — placeholder, 24 cols)
--     Header: CustomerName,TYMAT$,LYMAT$,MATGrowth$,TYMATProfit,LYMATProfit,
--             MATGrowthProfit,TYMTD$,LYMTD$,MTDGrowth$,TYMQT$,MQTGrowth$,
--             LYMQT$,TYDistn,TYRange,TYNewDistn,TYLostDistn,LYDistn,LYRange,
--             LYNewDistn,LYLostDistn,Channel,DistnGrowth,DiscountClass
-- ────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS tbl_customer_performance_17 (
    id                      SERIAL PRIMARY KEY,
    customer_name           TEXT,
    ty_mat_dollar           NUMERIC,
    ly_mat_dollar           NUMERIC,
    mat_growth_dollar       NUMERIC,
    ty_mat_profit           NUMERIC,
    ly_mat_profit           NUMERIC,
    mat_growth_profit       NUMERIC,
    ty_mtd_dollar           NUMERIC,
    ly_mtd_dollar           NUMERIC,
    mtd_growth_dollar       NUMERIC,
    ty_mqt_dollar           NUMERIC,
    mqt_growth_dollar       NUMERIC,
    ly_mqt_dollar           NUMERIC,
    ty_distn                NUMERIC,
    ty_range                NUMERIC,
    ty_new_distn            NUMERIC,
    ty_lost_distn           NUMERIC,
    ly_distn                NUMERIC,
    ly_range                NUMERIC,
    ly_new_distn            NUMERIC,
    ly_lost_distn           NUMERIC,
    channel                 TEXT,
    distn_growth            NUMERIC,
    discount_class          TEXT,
    _imported_at            TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE tbl_customer_performance_17 IS
  'B10b legacy Access report: tblCustomerPerformance_17 (0 rows in Access — '
  'empty pre-built shell). Customer performance MAT/MTD/MQT pivot. Read-only.';

-- ────────────────────────────────────────────────────────────────────────────
-- 11. tbl_samples_territory (35 rows, 3 cols)
--     Header: RepCustomerName, SampleTerritory, TerritoryGroup
-- ────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS tbl_samples_territory (
    id                  SERIAL PRIMARY KEY,
    rep_customer_name   TEXT,
    sample_territory    TEXT,
    territory_group     TEXT,
    _imported_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE tbl_samples_territory IS
  'B10b legacy Access report: tblSamplesTerritory (35 rows). Sample tracking '
  'by rep+territory. Read-only.';

-- ────────────────────────────────────────────────────────────────────────────
-- 12. tbl_xtbl_select_territory (1 row, 3 cols)
--     Header: TID, SelTerritory, Flag
--     Note: original Access name xtblSelectTerritory; we prefix tbl_ to keep
--     the AC5 LIKE 'tbl_%' invariant clean.
-- ────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS tbl_xtbl_select_territory (
    id              SERIAL PRIMARY KEY,
    t_id            NUMERIC,
    sel_territory   TEXT,
    flag            TEXT,
    _imported_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE tbl_xtbl_select_territory IS
  'B10b legacy Access report: xtblSelectTerritory (1 row). Territory '
  'selector lookup. Read-only.';

-- ────────────────────────────────────────────────────────────────────────────
-- 13. tbl_dir_not_found_reps (1 row, 7 cols)
--     Header: Rep,DIRTerritory,RepTerritory,SelectRep,SelectTerritory,
--             IsUpdated,IsIgnore
-- ────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS tbl_dir_not_found_reps (
    id                  SERIAL PRIMARY KEY,
    rep                 TEXT,
    dir_territory       TEXT,
    rep_territory       TEXT,
    select_rep          TEXT,
    select_territory    TEXT,
    is_updated          TEXT,
    is_ignore           TEXT,
    _imported_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE tbl_dir_not_found_reps IS
  'B10b legacy Access report: tblDIRNotFoundReps (1 row). Direct-channel '
  'rep mismatch log. Read-only.';

-- ────────────────────────────────────────────────────────────────────────────
-- 14. tbl_xtbl_sales_by_range_chart (395 rows, 12 cols)
--     Header: SN,SNO,CalYearMonth,expMonth,Range,Total,Direct,HOffice,Hybrid,
--             Off Premise,On Premise,Wholesale
--     Note "Off Premise" + "On Premise" headers contain spaces — we
--     normalise to off_premise / on_premise.
-- ────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS tbl_xtbl_sales_by_range_chart (
    id                  SERIAL PRIMARY KEY,
    sn                  NUMERIC,
    sno                 NUMERIC,
    cal_year_month      TEXT,
    exp_month           TEXT,
    range               TEXT,
    total               NUMERIC,
    direct              NUMERIC,
    h_office            NUMERIC,
    hybrid              NUMERIC,
    off_premise         NUMERIC,
    on_premise          NUMERIC,
    wholesale           NUMERIC,
    _imported_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE tbl_xtbl_sales_by_range_chart IS
  'B10b legacy Access report: xtblSalesByRangeChart (395 rows). Per-range '
  'monthly sales by venue (Direct/HOffice/Hybrid/OnPrem/OffPrem/Wholesale). '
  'Read-only.';

-- ────────────────────────────────────────────────────────────────────────────
-- 15. tbl_xtbl_sales_by_range_total_chart (36 rows, 12 cols)
--     Header: CalMonthx,CalYearMonth,expMonth,SN,SNO,Total,Direct,HOffice,
--             Hybrid,Off Premise,On Premise,Wholesale
-- ────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS tbl_xtbl_sales_by_range_total_chart (
    id                  SERIAL PRIMARY KEY,
    cal_month_x         TEXT,
    cal_year_month      TEXT,
    exp_month           TEXT,
    sn                  NUMERIC,
    sno                 NUMERIC,
    total               NUMERIC,
    direct              NUMERIC,
    h_office            NUMERIC,
    hybrid              NUMERIC,
    off_premise         NUMERIC,
    on_premise          NUMERIC,
    wholesale           NUMERIC,
    _imported_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE tbl_xtbl_sales_by_range_total_chart IS
  'B10b legacy Access report: xtblSalesByRangeTotalChart (36 rows). Total '
  'monthly sales by venue. Read-only.';

-- ────────────────────────────────────────────────────────────────────────────
-- 16. POST-state assertion: AC5 — all 14 legacy report tables exist
-- ────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
  v_count   INT;
  v_target  INT := 14;
BEGIN
  SELECT count(*)
    INTO v_count
    FROM information_schema.tables
   WHERE table_schema = 'public'
     AND table_name IN (
       'tbl_analysis_report',
       'tbl_distribution_by_range_16',
       'tbl_distribution_by_range_nd18',
       'tbl_distribution_by_range_td18',
       'tbl_distribution_by_range_ld18',
       'tbl_top10_opportunities_territory_11a',
       'tbl_top10_opportunities_whole_11a',
       'tbl_territory_distribution_performance_report',
       'tbl_customer_performance_17',
       'tbl_samples_territory',
       'tbl_xtbl_select_territory',
       'tbl_dir_not_found_reps',
       'tbl_xtbl_sales_by_range_chart',
       'tbl_xtbl_sales_by_range_total_chart'
     );

  RAISE NOTICE 'B10b POST: legacy report tables present=% (target=%)',
    v_count, v_target;

  IF v_count <> v_target THEN
    RAISE EXCEPTION
      'B10b POST AC5: expected % legacy report tables, found %',
      v_target, v_count;
  END IF;
END;
$$;

-- ────────────────────────────────────────────────────────────────────────────
-- 17. Record migration
-- ────────────────────────────────────────────────────────────────────────────
INSERT INTO schema_migrations (version, source)
VALUES ('104_b10b_legacy_access_reports', 'live-apply')
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ════════════════════════════════════════════════════════════════════════════
-- ROLLBACK / DOWN-MIGRATION RECIPE (manual; not auto-run)
-- ════════════════════════════════════════════════════════════════════════════
-- Only safe before any ETL/UI users depend on these tables.
--   BEGIN;
--   DROP TABLE IF EXISTS tbl_analysis_report CASCADE;
--   DROP TABLE IF EXISTS tbl_distribution_by_range_16 CASCADE;
--   DROP TABLE IF EXISTS tbl_distribution_by_range_nd18 CASCADE;
--   DROP TABLE IF EXISTS tbl_distribution_by_range_td18 CASCADE;
--   DROP TABLE IF EXISTS tbl_distribution_by_range_ld18 CASCADE;
--   DROP TABLE IF EXISTS tbl_top10_opportunities_territory_11a CASCADE;
--   DROP TABLE IF EXISTS tbl_top10_opportunities_whole_11a CASCADE;
--   DROP TABLE IF EXISTS tbl_territory_distribution_performance_report CASCADE;
--   DROP TABLE IF EXISTS tbl_customer_performance_17 CASCADE;
--   DROP TABLE IF EXISTS tbl_samples_territory CASCADE;
--   DROP TABLE IF EXISTS tbl_xtbl_select_territory CASCADE;
--   DROP TABLE IF EXISTS tbl_dir_not_found_reps CASCADE;
--   DROP TABLE IF EXISTS tbl_xtbl_sales_by_range_chart CASCADE;
--   DROP TABLE IF EXISTS tbl_xtbl_sales_by_range_total_chart CASCADE;
--   DELETE FROM schema_migrations
--     WHERE version = '104_b10b_legacy_access_reports';
--   COMMIT;
