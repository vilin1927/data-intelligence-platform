"""
Phase F.2 unit tests — address-freshness helper (BUG-111).

Locks the reconcile_column contract. 5 actions × multiple columns × null/empty/
here = F.4 breakage.
"""
import sys
from pathlib import Path

# Allow `import etl.lib.address_freshness` when pytest runs from repo root.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from etl.lib.address_freshness import FreshnessDecision, reconcile_column


# -------- action: "filled" (db NULL, access has value) --------

def test_filled_suburb_from_access():
    d = reconcile_column("C1", "suburb", None, "Young")
    assert d == FreshnessDecision(new_value="Young", action="filled", conflict=None)


def test_filled_postcode_when_db_empty_string():
    # Empty string treated as NULL -> fill from access.
    d = reconcile_column("C2", "postcode", "", "2594")
    assert d.action == "filled"
    assert d.new_value == "2594"
    assert d.conflict is None


def test_filled_address_line1_when_db_whitespace():
    # Whitespace-only treated as NULL.
    d = reconcile_column("C3", "address_line1", "   ", "1 Main St")
    assert d.action == "filled"
    assert d.new_value == "1 Main St"


# -------- action: "skipped_null_source" (db has value, access NULL) --------

def test_skipped_null_source_keeps_vinsight_suburb():
    d = reconcile_column("C4", "suburb", "Sydney", None)
    assert d == FreshnessDecision(
        new_value="Sydney", action="skipped_null_source", conflict=None
    )


def test_skipped_null_source_when_access_is_empty_string():
    # Access empty-string treated as NULL; keep Vinsight's live postcode.
    d = reconcile_column("C5", "postcode", "2000", "")
    assert d.action == "skipped_null_source"
    assert d.new_value == "2000"


def test_skipped_null_source_country_when_access_whitespace():
    d = reconcile_column("C6", "country", "Australia", "  \t ")
    assert d.action == "skipped_null_source"
    assert d.new_value == "Australia"


# -------- action: "match" (both non-NULL, equal) --------

def test_match_state_exact():
    d = reconcile_column("C7", "state", "NSW", "NSW")
    assert d == FreshnessDecision(new_value="NSW", action="match", conflict=None)


def test_match_address_line2_exact():
    d = reconcile_column("C8", "address_line2", "Suite 4", "Suite 4")
    assert d.action == "match"
    assert d.new_value == "Suite 4"
    assert d.conflict is None


# -------- action: "skipped_conflict" (both non-NULL, differ) --------

def test_skipped_conflict_suburb_differs():
    d = reconcile_column("C9", "suburb", "Sydney", "Parramatta")
    assert d.action == "skipped_conflict"
    assert d.new_value == "Sydney"  # Vinsight wins.
    assert d.conflict == {
        "customer_id": "C9",
        "column": "suburb",
        "db_value": "Sydney",
        "access_value": "Parramatta",
    }


def test_skipped_conflict_postcode_differs():
    d = reconcile_column("C10", "postcode", "2000", "2150")
    assert d.action == "skipped_conflict"
    assert d.new_value == "2000"
    assert d.conflict["customer_id"] == "C10"
    assert d.conflict["column"] == "postcode"
    assert d.conflict["db_value"] == "2000"
    assert d.conflict["access_value"] == "2150"


def test_case_difference_is_conflict_not_match():
    # Conservative default per F.2 spec: case-sensitive equality.
    d = reconcile_column("C11", "state", "NSW", "nsw")
    assert d.action == "skipped_conflict"
    assert d.new_value == "NSW"
    assert d.conflict == {
        "customer_id": "C11",
        "column": "state",
        "db_value": "NSW",
        "access_value": "nsw",
    }


# -------- action: "both_null" --------

def test_both_null_suburb_none_none():
    d = reconcile_column("C12", "suburb", None, None)
    assert d == FreshnessDecision(new_value=None, action="both_null", conflict=None)


def test_both_null_postcode_empty_and_whitespace():
    # Empty-string db + whitespace access both treated as NULL.
    d = reconcile_column("C13", "postcode", "", "   ")
    assert d.action == "both_null"
    assert d.new_value is None
    assert d.conflict is None


# -------- column coverage smoke test (all 6 required columns) --------

def test_all_six_columns_handle_filled_action():
    columns = ["suburb", "postcode", "state", "address_line1", "address_line2", "country"]
    for col in columns:
        d = reconcile_column("CX", col, None, "ACCESS_VAL")
        assert d.action == "filled", f"{col} expected filled, got {d.action}"
        assert d.new_value == "ACCESS_VAL"


# -------- contract: conflict record shape is exactly 4 keys --------

def test_conflict_record_has_exactly_four_keys():
    d = reconcile_column("C14", "address_line1", "1 Main St", "2 Other Ave")
    assert d.action == "skipped_conflict"
    assert set(d.conflict.keys()) == {"customer_id", "column", "db_value", "access_value"}


# -------- contract: non-conflict actions have conflict=None --------

def test_non_conflict_actions_have_none_conflict():
    cases = [
        reconcile_column("A", "suburb", None, "X"),         # filled
        reconcile_column("A", "suburb", "X", None),         # skipped_null_source
        reconcile_column("A", "suburb", "X", "X"),          # match
        reconcile_column("A", "suburb", None, None),        # both_null
    ]
    for d in cases:
        assert d.conflict is None, f"{d.action} should not carry a conflict record"
