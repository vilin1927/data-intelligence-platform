"""
B10b — unit tests for `etl.import_legacy_access_reports`.

Covers:
  - LEGACY_REPORTS list integrity (14 tables).
  - Each entry's column mapping covers the Access header verbatim.
  - CSV parse + normalise_value behavior on empty cells.
  - Idempotency: running the parse pipeline twice on the same fixture
    yields identical (header, row count, normalised cells) — the
    prerequisite for the TRUNCATE-then-COPY idempotency property at the
    via running the ETL twice and comparing row counts).
"""

from __future__ import annotations

import io

import pytest

from etl import import_legacy_access_reports as mod


# ─── Test fixtures ──────────────────────────────────────────────────────────

TINY_CSV_TBL_SAMPLES_TERRITORY = (
    'RepCustomerName,SampleTerritory,TerritoryGroup\n'
    'Test Rep 1,NSW Country,NSW\n'
    'Test Rep 2,VIC City,VIC\n'
    ',,Empty Group\n'  # row with empty rep + sample territory (mdb-style)
)


# ─── LEGACY_REPORTS list integrity ──────────────────────────────────────────

def test_legacy_reports_count_is_14():
    """Spec says '13 preserved Access reports' but extract-accdb.md +
    mdb-tables on the accdb confirms 14 distinct reporting tables.
    """
    assert len(mod.LEGACY_REPORTS) == 14


def test_legacy_reports_all_have_unique_postgres_names():
    pg_names = [t[1] for t in mod.LEGACY_REPORTS]
    assert len(set(pg_names)) == len(pg_names), \
        f"duplicate Postgres table names: {pg_names}"


def test_legacy_reports_all_have_unique_access_names():
    access_names = [t[0] for t in mod.LEGACY_REPORTS]
    assert len(set(access_names)) == len(access_names), \
        f"duplicate Access table names: {access_names}"


def test_legacy_reports_postgres_names_have_tbl_prefix():
    """AC5 self-test SQL is `LIKE 'tbl_%'` — every Postgres mirror must
    start with `tbl_` so the count query catches all 14.
    """
    for access_name, pg_name, _, _ in mod.LEGACY_REPORTS:
        assert pg_name.startswith("tbl_"), \
            f"{access_name}: Postgres mirror {pg_name} missing tbl_ prefix"


def test_legacy_reports_column_mappings_non_empty():
    for access_name, pg_name, mapping, _ in mod.LEGACY_REPORTS:
        assert len(mapping) > 0, f"{access_name}: empty column mapping"


@pytest.mark.parametrize(
    "access_name,expected_first_col",
    [
        ("tblAnalysisReport",                       "Territory"),
        ("tblTop10OpportunitiesTerritory_11a",       "TSKU"),
        ("tblTop10OpportunitiesWhole_11a",           "WSKU"),
        ("TerritoryDistributionPerformanceReport",   "Territory"),
        ("tblSamplesTerritory",                      "RepCustomerName"),
        ("xtblSelectTerritory",                      "TID"),
        ("tblDIRNotFoundReps",                       "Rep"),
        ("xtblSalesByRangeChart",                    "SN"),
        ("xtblSalesByRangeTotalChart",               "CalMonthx"),
    ],
)
def test_legacy_reports_first_col_matches_mdb_export_header(
    access_name: str, expected_first_col: str,
):
    """First Access column for each table must match the verbatim
    mdb-export header captured 2026-04-28.
    """
    entry = next(
        (t for t in mod.LEGACY_REPORTS if t[0] == access_name), None,
    )
    assert entry is not None, f"{access_name} not in LEGACY_REPORTS"
    first_access_col = entry[2][0][0]
    assert first_access_col == expected_first_col


# ─── normalise_value ────────────────────────────────────────────────────────

def test_normalise_value_empty_to_none():
    assert mod.normalise_value("") is None


def test_normalise_value_preserves_non_empty():
    assert mod.normalise_value("Test Rep 1") == "Test Rep 1"
    assert mod.normalise_value("0") == "0"
    assert mod.normalise_value(" ") == " "  # whitespace is NOT empty


# ─── load_csv_text_to_rows ──────────────────────────────────────────────────

def test_load_csv_text_to_rows_parses_header_and_rows():
    header, rows = mod.load_csv_text_to_rows(TINY_CSV_TBL_SAMPLES_TERRITORY)
    assert header == ["RepCustomerName", "SampleTerritory", "TerritoryGroup"]
    assert len(rows) == 3
    assert rows[0] == ["Test Rep 1", "NSW Country", "NSW"]
    assert rows[1] == ["Test Rep 2", "VIC City", "VIC"]
    assert rows[2] == ["", "", "Empty Group"]


def test_load_csv_text_to_rows_empty_input():
    header, rows = mod.load_csv_text_to_rows("")
    assert header == []
    assert rows == []


# ─── Idempotency at the parse layer ─────────────────────────────────────────

def test_parse_pipeline_idempotent_on_repeat():
    """The parse → normalise pipeline must return identical structure on
    repeated calls against the same input. This is the prerequisite for
    DB-side idempotency: TRUNCATE + COPY of identical data = identical
    final state.
    """
    header_1, rows_1 = mod.load_csv_text_to_rows(TINY_CSV_TBL_SAMPLES_TERRITORY)
    header_2, rows_2 = mod.load_csv_text_to_rows(TINY_CSV_TBL_SAMPLES_TERRITORY)
    assert header_1 == header_2
    assert rows_1 == rows_2

    # Normalisation pass
    norm_1 = [[mod.normalise_value(c) for c in r] for r in rows_1]
    norm_2 = [[mod.normalise_value(c) for c in r] for r in rows_2]
    assert norm_1 == norm_2


def test_normalise_pipeline_collapses_empty_to_none():
    """Empty mdb-export cells → None (so COPY treats them as NULL)."""
    _, rows = mod.load_csv_text_to_rows(TINY_CSV_TBL_SAMPLES_TERRITORY)
    last_row_normalised = [mod.normalise_value(c) for c in rows[2]]
    assert last_row_normalised == [None, None, "Empty Group"]


# ─── Column-mapping fidelity check ──────────────────────────────────────────

def test_samples_territory_mapping_is_complete():
    entry = next(t for t in mod.LEGACY_REPORTS if t[0] == "tblSamplesTerritory")
    access_name, pg_name, mapping, expected_rows = entry
    assert pg_name == "tbl_samples_territory"
    assert mapping == [
        ("RepCustomerName",     "rep_customer_name"),
        ("SampleTerritory",     "sample_territory"),
        ("TerritoryGroup",      "territory_group"),
    ]
    assert expected_rows == 35


def test_top10_territory_mapping_is_complete():
    entry = next(t for t in mod.LEGACY_REPORTS
                 if t[0] == "tblTop10OpportunitiesTerritory_11a")
    _, pg_name, mapping, expected_rows = entry
    assert pg_name == "tbl_top10_opportunities_territory_11a"
    assert mapping == [
        ("TSKU",            "t_sku"),
        ("TTotalCases",     "t_total_cases"),
        ("TID",             "t_id"),
    ]
    assert expected_rows == 55


def test_xtbl_select_territory_uses_tbl_xtbl_prefix():
    """Original Access name xtblSelectTerritory; we prefix `tbl_` to keep
    the AC5 LIKE 'tbl_%' invariant clean."""
    entry = next(t for t in mod.LEGACY_REPORTS if t[0] == "xtblSelectTerritory")
    _, pg_name, _, _ = entry
    assert pg_name == "tbl_xtbl_select_territory"
    assert pg_name.startswith("tbl_")
