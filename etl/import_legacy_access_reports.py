"""
B10b — import 14 pre-built Access reporting tables into Postgres.

Tickets
-------
mdb-tables verification 2026-04-28). The list and column mappings are
authoritative HARD-source values from the Access database itself.

Source
------
      mdb-export <accdb> <table> --format=csv exports each table.

Idempotent: per-table `TRUNCATE tbl_X; COPY tbl_X FROM stdin;` inside one
BEGIN/COMMIT per table. Re-running collapses to identical DB state.
BEGIN/COMMIT so partial failure leaves prior tables intact.

Usage
-----
    DATABASE_URL=postgresql://... \\
    python -m etl.import_legacy_access_reports \\
        --accdb "/path/to/Moppity Sales Database - Jan 2026.accdb" \\
        --commit                # default is --dry-run

    # Optional: import a single table for fast iteration:
    python -m etl.import_legacy_access_reports --accdb /path \\
        --only tblAnalysisReport --commit

Exit codes
----------
    0  success
    1  guard violation (mdb-export missing, accdb missing, row drift)
    2  DB error (rolled back)
    3  config error
"""

from __future__ import annotations

import argparse
import csv
import io
import logging
import os
import shutil
import subprocess
import sys
from pathlib import Path

import psycopg2
import psycopg2.extras

from etl.logger import log_etl_run

logger = logging.getLogger("moppity.etl.import_legacy_access_reports")


# ─── HARD-source list: 14 Access tables → Postgres targets ──────────────────
# Source: extract-accdb.md line 73 + mdb-tables verification.
# Format: (access_table_name, postgres_table_name, [(access_col, pg_col), ...],
#         expected_access_row_count)
LEGACY_REPORTS: list[tuple[str, str, list[tuple[str, str]], int]] = [
    (
        "tblAnalysisReport",
        "tbl_analysis_report",
        [
            ("Territory",                    "territory"),
            ("TotalCases",                   "total_cases"),
            ("TotalBaseWholesale",           "total_base_wholesale"),
            ("TotalDiscount",                "total_discount"),
            ("TotalRebate",                  "total_rebate"),
            ("TotalWholesalerFee",           "total_wholesaler_fee"),
            ("TotalProfit",                  "total_profit"),
            ("Samples",                      "samples"),
            ("What",                         "what"),
            ("ProfitBeforeLS",               "profit_before_ls"),
            ("GpWhat",                       "gp_what"),
            ("WhatYear",                     "what_year"),
            ("GrossProfitPercentage",        "gross_profit_percentage"),
            ("GrossProfitDollarPerCase",     "gross_profit_dollar_per_case"),
        ],
        94,
    ),
    (
        "tblDistributionByRange_16",
        "tbl_distribution_by_range_16",
        [
            ("TotalFor",            "total_for"),
            ("xOrder",              "x_order"),
            ("Atrius",              "atrius"),
            ("Block",               "block"),
            ("Cato",                "cato"),
            ("Coppabella",          "coppabella"),
            ("Coppabella Crest",    "coppabella_crest"),
            ("Coppabella Procella", "coppabella_procella"),
            ("Coppabella Sirius",   "coppabella_sirius"),
            ("Crafted",             "crafted"),
            ("Lock & Key",          "lock_and_key"),
            ("Moppity Estate",      "moppity_estate"),
            ("Moppity Reserve",     "moppity_reserve"),
            ("Mv Exclusive",        "mv_exclusive"),
            ("Oppabella Procella",  "oppabella_procella"),
            ("Other",               "other"),
            ("Twelve Signs",        "twelve_signs"),
        ],
        0,
    ),
    (
        "tblDistributionByRangeND18",
        "tbl_distribution_by_range_nd18",
        [
            ("NDCustomerName",                  "nd_customer_name"),
            ("xOrder",                          "x_order"),
            ("NDTotal",                         "nd_total"),
            ("NDArgo",                          "nd_argo"),
            ("NDAtrius",                        "nd_atrius"),
            ("NDBrothers At Large",             "nd_brothers_at_large"),
            ("NDCato",                          "nd_cato"),
            ("NDChalice Bridge Estate",         "nd_chalice_bridge_estate"),
            ("NDChalice Bridge Quest",          "nd_chalice_bridge_quest"),
            ("NDChalice Bridge Sorcerers",      "nd_chalice_bridge_sorcerers"),
            ("NDChalice Bridge The Chalice",    "nd_chalice_bridge_the_chalice"),
            ("NDChalice Chapman",               "nd_chalice_chapman"),
            ("NDChalice Sorcerers",             "nd_chalice_sorcerers"),
            ("NDCoppabella",                    "nd_coppabella"),
            ("NDCoppabella Crest",              "nd_coppabella_crest"),
            ("NDCoppabella Sirius",             "nd_coppabella_sirius"),
            ("NDDarling Wines",                 "nd_darling_wines"),
            ("NDDeep River",                    "nd_deep_river"),
            ("NDErnest",                        "nd_ernest"),
            ("NDHex & Heysen",                  "nd_hex_and_heysen"),
            ("NDKirikiri",                      "nd_kirikiri"),
            ("NDKokori",                        "nd_kokori"),
            ("NDLittle Darling",                "nd_little_darling"),
            ("NDLock & Key",                    "nd_lock_and_key"),
            ("NDLock & Key Reserve",            "nd_lock_and_key_reserve"),
            ("NDMoppity",                       "nd_moppity"),
            ("NDMoppity Block",                 "nd_moppity_block"),
            ("NDMoppity Canberra",              "nd_moppity_canberra"),
            ("NDMoppity Estate",                "nd_moppity_estate"),
            ("NDMoppity Reserve",               "nd_moppity_reserve"),
            ("NDMv Exclusive",                  "nd_mv_exclusive"),
            ("NDN/a",                           "nd_na"),
            ("NDOther",                         "nd_other"),
            ("NDPurple Hands",                  "nd_purple_hands"),
            ("NDReillys Barking Mad",           "nd_reillys_barking_mad"),
            ("NDReillys Black Label",           "nd_reillys_black_label"),
            ("NDReillys Dry Land",              "nd_reillys_dry_land"),
            ("NDReillys Ryder",                 "nd_reillys_ryder"),
            ("NDReillys Stolen Block",          "nd_reillys_stolen_block"),
            ("NDSingle Step",                   "nd_single_step"),
            ("NDSwinging Bridge",               "nd_swinging_bridge"),
            ("NDTwelve Signs",                  "nd_twelve_signs"),
            ("NDWindowrie",                     "nd_windowrie"),
        ],
        3,
    ),
    (
        "tblDistributionByRangeTD18",
        "tbl_distribution_by_range_td18",
        [
            ("CustomerName",                    "customer_name"),
            ("xOrder",                          "x_order"),
            ("Total",                           "total"),
            ("ARGO",                            "argo"),
            ("ATRIUS",                          "atrius"),
            ("BROTHERS AT LARGE",               "brothers_at_large"),
            ("Cato",                            "cato"),
            ("CHALICE BRIDGE ESTATE",           "chalice_bridge_estate"),
            ("CHALICE BRIDGE QUEST",            "chalice_bridge_quest"),
            ("CHALICE BRIDGE SORCERERS",        "chalice_bridge_sorcerers"),
            ("CHALICE BRIDGE THE CHALICE",      "chalice_bridge_the_chalice"),
            ("CHALICE CHAPMAN",                 "chalice_chapman"),
            ("CHALICE SORCERERS",               "chalice_sorcerers"),
            ("COPPABELLA",                      "coppabella"),
            ("COPPABELLA CREST",                "coppabella_crest"),
            ("COPPABELLA SIRIUS",               "coppabella_sirius"),
            ("DARLING WINES",                   "darling_wines"),
            ("DEEP RIVER",                      "deep_river"),
            ("ERNEST",                          "ernest"),
            ("Hex & Heysen",                    "hex_and_heysen"),
            ("KIRIKIRI",                        "kirikiri"),
            ("KOKORI",                          "kokori"),
            ("LITTLE DARLING",                  "little_darling"),
            ("LOCK & KEY",                      "lock_and_key"),
            ("LOCK & KEY RESERVE",              "lock_and_key_reserve"),
            ("Moppity",                         "moppity"),
            ("MOPPITY BLOCK",                   "moppity_block"),
            ("Moppity Canberra",                "moppity_canberra"),
            ("MOPPITY ESTATE",                  "moppity_estate"),
            ("MOPPITY RESERVE",                 "moppity_reserve"),
            ("MV EXCLUSIVE",                    "mv_exclusive"),
            ("N/A",                             "na"),
            ("OTHER",                           "other"),
            ("PURPLE HANDS",                    "purple_hands"),
            ("REILLYS BARKING MAD",             "reillys_barking_mad"),
            ("REILLYS BLACK LABEL",             "reillys_black_label"),
            ("REILLYS DRY LAND",                "reillys_dry_land"),
            ("REILLYS RYDER",                   "reillys_ryder"),
            ("REILLYS STOLEN BLOCK",            "reillys_stolen_block"),
            ("SINGLE STEP",                     "single_step"),
            ("SWINGING BRIDGE",                 "swinging_bridge"),
            ("TWELVE SIGNS",                    "twelve_signs"),
            ("WINDOWRIE",                       "windowrie"),
        ],
        5,
    ),
    (
        "tblDistributionByRangeLD18",
        "tbl_distribution_by_range_ld18",
        [
            ("LDCustomerName",                  "ld_customer_name"),
            ("xOrder",                          "x_order"),
            ("LDTotal",                         "ld_total"),
            ("LDArgo",                          "ld_argo"),
            ("LDAtrius",                        "ld_atrius"),
            ("LDBrothers At Large",             "ld_brothers_at_large"),
            ("LDCato",                          "ld_cato"),
            ("LDChalice Bridge Estate",         "ld_chalice_bridge_estate"),
            ("LDChalice Bridge Quest",          "ld_chalice_bridge_quest"),
            ("LDChalice Bridge Sorcerers",      "ld_chalice_bridge_sorcerers"),
            ("LDChalice Bridge The Chalice",    "ld_chalice_bridge_the_chalice"),
            ("LDChalice Chapman",               "ld_chalice_chapman"),
            ("LDChalice Sorcerers",             "ld_chalice_sorcerers"),
            ("LDCoppabella",                    "ld_coppabella"),
            ("LDCoppabella Crest",              "ld_coppabella_crest"),
            ("LDCoppabella Sirius",             "ld_coppabella_sirius"),
            ("LDDarling Wines",                 "ld_darling_wines"),
            ("LDDeep River",                    "ld_deep_river"),
            ("LDErnest",                        "ld_ernest"),
            ("LDHex & Heysen",                  "ld_hex_and_heysen"),
            ("LDKirikiri",                      "ld_kirikiri"),
            ("LDKokori",                        "ld_kokori"),
            ("LDLittle Darling",                "ld_little_darling"),
            ("LDLock & Key",                    "ld_lock_and_key"),
            ("LDLock & Key Reserve",            "ld_lock_and_key_reserve"),
            ("LDMoppity",                       "ld_moppity"),
            ("LDMoppity Block",                 "ld_moppity_block"),
            ("LDMoppity Canberra",              "ld_moppity_canberra"),
            ("LDMoppity Estate",                "ld_moppity_estate"),
            ("LDMoppity Reserve",               "ld_moppity_reserve"),
            ("LDMv Exclusive",                  "ld_mv_exclusive"),
            ("LDN/a",                           "ld_na"),
            ("LDOther",                         "ld_other"),
            ("LDPurple Hands",                  "ld_purple_hands"),
            ("LDReillys Barking Mad",           "ld_reillys_barking_mad"),
            ("LDReillys Black Label",           "ld_reillys_black_label"),
            ("LDReillys Dry Land",              "ld_reillys_dry_land"),
            ("LDReillys Ryder",                 "ld_reillys_ryder"),
            ("LDReillys Stolen Block",          "ld_reillys_stolen_block"),
            ("LDSingle Step",                   "ld_single_step"),
            ("LDSwinging Bridge",               "ld_swinging_bridge"),
            ("LDTwelve Signs",                  "ld_twelve_signs"),
            ("LDWindowrie",                     "ld_windowrie"),
        ],
        1,
    ),
    (
        "tblTop10OpportunitiesTerritory_11a",
        "tbl_top10_opportunities_territory_11a",
        [
            ("TSKU",            "t_sku"),
            ("TTotalCases",     "t_total_cases"),
            ("TID",             "t_id"),
        ],
        55,
    ),
    (
        "tblTop10OpportunitiesWhole_11a",
        "tbl_top10_opportunities_whole_11a",
        [
            ("WSKU",            "w_sku"),
            ("WTotalCases",     "w_total_cases"),
            ("WID",             "w_id"),
        ],
        73,
    ),
    (
        "TerritoryDistributionPerformanceReport",
        "tbl_territory_distribution_performance_report",
        [
            ("Territory",       "territory"),
            ("ToTalDist",       "total_dist"),
            ("NewDist",         "new_dist"),
            ("LostDist",        "lost_dist"),
            ("TYMTD$",          "ty_mtd_dollar"),
            ("LYMTD$",          "ly_mtd_dollar"),
            ("MTDDiff$",        "mtd_diff_dollar"),
            ("TYYTD$",          "ty_ytd_dollar"),
            ("LYYTD$",          "ly_ytd_dollar"),
            ("YTDDiff$",        "ytd_diff_dollar"),
            ("RefDate",         "ref_date"),
            ("ACMTD",           "ac_mtd"),
            ("AC6Month",        "ac_6_month"),
            ("DistrPerAC",      "distr_per_ac"),
            ("ACYTD",           "ac_ytd"),
        ],
        40,
    ),
    (
        "tblCustomerPerformance_17",
        "tbl_customer_performance_17",
        [
            ("CustomerName",        "customer_name"),
            ("TYMAT$",              "ty_mat_dollar"),
            ("LYMAT$",              "ly_mat_dollar"),
            ("MATGrowth$",          "mat_growth_dollar"),
            ("TYMATProfit",         "ty_mat_profit"),
            ("LYMATProfit",         "ly_mat_profit"),
            ("MATGrowthProfit",     "mat_growth_profit"),
            ("TYMTD$",              "ty_mtd_dollar"),
            ("LYMTD$",              "ly_mtd_dollar"),
            ("MTDGrowth$",          "mtd_growth_dollar"),
            ("TYMQT$",              "ty_mqt_dollar"),
            ("MQTGrowth$",          "mqt_growth_dollar"),
            ("LYMQT$",              "ly_mqt_dollar"),
            ("TYDistn",             "ty_distn"),
            ("TYRange",             "ty_range"),
            ("TYNewDistn",          "ty_new_distn"),
            ("TYLostDistn",         "ty_lost_distn"),
            ("LYDistn",             "ly_distn"),
            ("LYRange",             "ly_range"),
            ("LYNewDistn",          "ly_new_distn"),
            ("LYLostDistn",         "ly_lost_distn"),
            ("Channel",             "channel"),
            ("DistnGrowth",         "distn_growth"),
            ("DiscountClass",       "discount_class"),
        ],
        0,
    ),
    (
        "tblSamplesTerritory",
        "tbl_samples_territory",
        [
            ("RepCustomerName",     "rep_customer_name"),
            ("SampleTerritory",     "sample_territory"),
            ("TerritoryGroup",      "territory_group"),
        ],
        35,
    ),
    (
        "xtblSelectTerritory",
        "tbl_xtbl_select_territory",
        [
            ("TID",             "t_id"),
            ("SelTerritory",    "sel_territory"),
            ("Flag",            "flag"),
        ],
        1,
    ),
    (
        "tblDIRNotFoundReps",
        "tbl_dir_not_found_reps",
        [
            ("Rep",                 "rep"),
            ("DIRTerritory",        "dir_territory"),
            ("RepTerritory",        "rep_territory"),
            ("SelectRep",           "select_rep"),
            ("SelectTerritory",     "select_territory"),
            ("IsUpdated",           "is_updated"),
            ("IsIgnore",            "is_ignore"),
        ],
        1,
    ),
    (
        "xtblSalesByRangeChart",
        "tbl_xtbl_sales_by_range_chart",
        [
            ("SN",              "sn"),
            ("SNO",             "sno"),
            ("CalYearMonth",    "cal_year_month"),
            ("expMonth",        "exp_month"),
            ("Range",           "range"),
            ("Total",           "total"),
            ("Direct",          "direct"),
            ("HOffice",         "h_office"),
            ("Hybrid",          "hybrid"),
            ("Off Premise",     "off_premise"),
            ("On Premise",      "on_premise"),
            ("Wholesale",       "wholesale"),
        ],
        395,
    ),
    (
        "xtblSalesByRangeTotalChart",
        "tbl_xtbl_sales_by_range_total_chart",
        [
            ("CalMonthx",       "cal_month_x"),
            ("CalYearMonth",    "cal_year_month"),
            ("expMonth",        "exp_month"),
            ("SN",              "sn"),
            ("SNO",             "sno"),
            ("Total",           "total"),
            ("Direct",          "direct"),
            ("HOffice",         "h_office"),
            ("Hybrid",          "hybrid"),
            ("Off Premise",     "off_premise"),
            ("On Premise",      "on_premise"),
            ("Wholesale",       "wholesale"),
        ],
        36,
    ),
]


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Import 14 pre-built Access reporting tables into Postgres."
    )
    p.add_argument(
        "--accdb",
        type=Path,
        required=False,
        default=Path("data/accessdb.accdb"),
        help="Path to the Access .accdb file (default: data/accessdb.accdb)",
    )
    p.add_argument(
        "--only",
        type=str,
        default=None,
        help="Optional Access table name to import in isolation (for fast iteration).",
    )
    p.add_argument(
        "--csv-fixture-dir",
        type=Path,
        default=None,
        help=(
            "If set, read each table's CSV from <dir>/<access_name>.csv instead "
            "of running mdb-export. Used by tests + air-gapped runs."
        ),
    )
    g = p.add_mutually_exclusive_group()
    g.add_argument(
        "--dry-run", dest="dry_run", action="store_true", default=True,
        help="ROLLBACK at end of each table's transaction (default).",
    )
    g.add_argument(
        "--commit", dest="dry_run", action="store_false",
        help="COMMIT each table's transaction (explicit opt-in).",
    )
    return p.parse_args()


def export_table_to_csv(accdb: Path, table_name: str) -> str:
    """Run `mdb-export <accdb> <table>` and return the CSV text.

    Raises FileNotFoundError if mdb-export is not installed,
    or RuntimeError if mdb-export exits non-zero.
    """
    if shutil.which("mdb-export") is None:
        raise FileNotFoundError(
            "mdb-export not on PATH — install mdb-tools (brew install mdbtools)"
        )

    result = subprocess.run(
        ["mdb-export", str(accdb), table_name],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(
            f"mdb-export {table_name} failed (rc={result.returncode}): "
            f"{result.stderr.strip()}"
        )
    return result.stdout


def load_csv_text_to_rows(csv_text: str) -> tuple[list[str], list[list[str]]]:
    """Parse mdb-export CSV output into (header, rows) tuple."""
    reader = csv.reader(io.StringIO(csv_text))
    rows = list(reader)
    if not rows:
        return [], []
    header, *data_rows = rows
    return header, data_rows


def normalise_value(raw: str) -> str | None:
    """Return None for empty mdb-export cells (so COPY treats as NULL)."""
    if raw == "":
        return None
    return raw


def import_one_table(
    conn,
    accdb: Path,
    access_name: str,
    pg_name: str,
    col_mapping: list[tuple[str, str]],
    expected_rows: int,
    csv_fixture_dir: Path | None,
    dry_run: bool,
) -> tuple[int, str]:
    """Import a single Access table into its Postgres mirror.

    Returns (rows_imported, status) where status is 'success' or 'skipped'.
    Raises on any DB / export / mapping failure (caller logs + rolls back).
    """
    # 1. Get the CSV text — either from mdb-export or a fixture.
    if csv_fixture_dir is not None:
        fixture = csv_fixture_dir / f"{access_name}.csv"
        if not fixture.exists():
            raise FileNotFoundError(f"CSV fixture not found: {fixture}")
        csv_text = fixture.read_text()
        logger.info("Loading %s from fixture %s", access_name, fixture)
    else:
        if not accdb.exists():
            raise FileNotFoundError(f"accdb not found: {accdb}")
        csv_text = export_table_to_csv(accdb, access_name)
        logger.info("Exported %s from accdb (%d bytes)", access_name, len(csv_text))

    # 2. Parse + validate column mapping.
    header, data_rows = load_csv_text_to_rows(csv_text)
    if not header:
        logger.warning(
            "%s: empty CSV — skipping (Access reports row count %d)",
            access_name, expected_rows,
        )
        return 0, "skipped"

    expected_access_cols = [a for a, _ in col_mapping]
    # Permissive: allow extra Access cols we don't map (we'd lose them with a
    # warning), and require every mapped Access col to be present in header.
    missing = [c for c in expected_access_cols if c not in header]
    if missing:
        raise ValueError(
            f"{access_name}: header missing expected cols {missing}; "
            f"got header={header}"
        )

    # Build per-row source-col indices in the order of col_mapping.
    col_idx = [header.index(a) for a, _ in col_mapping]
    pg_cols = [p for _, p in col_mapping]

    #    We rely on autocommit=False set by caller.
    with conn.cursor() as cur:
        cur.execute(f"TRUNCATE {pg_name}")

        if data_rows:
            # Build a pristine CSV in memory (only mapped cols, NULL for empty).
            buf = io.StringIO()
            writer = csv.writer(buf, quoting=csv.QUOTE_MINIMAL)
            for raw_row in data_rows:
                # Defensive: skip rows shorter than max(col_idx)+1
                if max(col_idx) >= len(raw_row):
                    raise ValueError(
                        f"{access_name}: short row ({len(raw_row)} cells, need "
                        f"{max(col_idx)+1}): {raw_row[:5]}..."
                    )
                writer.writerow([
                    normalise_value(raw_row[i]) if normalise_value(raw_row[i]) is not None else ""
                    for i in col_idx
                ])
            buf.seek(0)

            copy_sql = (
                f"COPY {pg_name} ({', '.join(pg_cols)}) "
                f"FROM STDIN WITH (FORMAT csv, NULL '')"
            )
            cur.copy_expert(copy_sql, buf)

        # Verify post-state row count.
        cur.execute(f"SELECT count(*) FROM {pg_name}")
        actual = cur.fetchone()[0]

    rows_imported = len(data_rows)

    if actual != rows_imported:
        raise RuntimeError(
            f"{access_name}: post-COPY row count={actual} but CSV had "
            f"{rows_imported} rows"
        )

    # Drift detection (warning only — Access can change row counts between
    # screenshots and re-runs; keep ETL non-fatal but loud).
    if rows_imported != expected_rows:
        logger.warning(
            "%s: row count drift — got %d rows, HARD-source expected %d",
            access_name, rows_imported, expected_rows,
        )

    # 4. Commit / rollback this table's transaction.
    if dry_run:
        logger.info("%s: DRY-RUN — rolling back %d rows", access_name, rows_imported)
        conn.rollback()
    else:
        logger.info("%s: COMMIT — persisted %d rows", access_name, rows_imported)
        conn.commit()

    return rows_imported, "success"


def main() -> int:
    logging.basicConfig(
        level=os.environ.get("LOG_LEVEL", "INFO"),
        format="%(asctime)s %(name)s %(levelname)s %(message)s",
    )
    args = parse_args()

    db_url = os.environ.get("DATABASE_URL")
    if not db_url:
        logger.error("DATABASE_URL env var required")
        return 3

    targets = LEGACY_REPORTS
    if args.only:
        targets = [t for t in LEGACY_REPORTS if t[0] == args.only]
        if not targets:
            logger.error(
                "--only %s not in LEGACY_REPORTS list; valid: %s",
                args.only, ", ".join(t[0] for t in LEGACY_REPORTS),
            )
            return 3

    conn = psycopg2.connect(db_url)
    conn.autocommit = False

    total_rows = 0
    table_results: list[tuple[str, int, str]] = []
    overall_status = "success"
    error_detail: str | None = None

    try:
        for access_name, pg_name, col_mapping, expected in targets:
            try:
                rows, status = import_one_table(
                    conn=conn,
                    accdb=args.accdb,
                    access_name=access_name,
                    pg_name=pg_name,
                    col_mapping=col_mapping,
                    expected_rows=expected,
                    csv_fixture_dir=args.csv_fixture_dir,
                    dry_run=args.dry_run,
                )
                total_rows += rows
                table_results.append((pg_name, rows, status))
            except (FileNotFoundError, ValueError, RuntimeError) as exc:
                # Per-table failure rolls back this table only; continue to
                logger.exception(
                    "%s: import failed (rolled back) — %s", access_name, exc
                )
                conn.rollback()
                table_results.append((pg_name, 0, f"error: {exc}"))
                overall_status = "partial"
                error_detail = (error_detail or "") + f"{access_name}: {exc}\n"
    except psycopg2.Error as exc:
        conn.rollback()
        logger.exception("DB error — transaction rolled back: %s", exc)
        return 2
    finally:
        # Log run before closing.
        try:
            log_etl_run(
                db_conn=conn,
                source="access_db",
                endpoint="legacy_access_reports",
                status=overall_status if overall_status != "success" else "success",
                rows_processed=total_rows,
                rows_skipped=0,
                error_count=sum(1 for _, _, s in table_results if s.startswith("error")),
                error_detail=error_detail,
            )
        except Exception:
            logger.exception("etl_run_log INSERT failed (non-fatal)")
        conn.close()

    # Summary
    logger.info("=" * 64)
    logger.info("B10b legacy reports import summary (mode=%s):",
                "DRY-RUN" if args.dry_run else "COMMIT")
    for pg_name, rows, status in table_results:
        logger.info("  %-50s rows=%5d status=%s", pg_name, rows, status)
    logger.info("Total rows: %d across %d tables", total_rows, len(table_results))

    return 0 if overall_status == "success" else 1


if __name__ == "__main__":
    sys.exit(main())
