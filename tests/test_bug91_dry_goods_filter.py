"""
BUG-91 / Phase B1 — dry-goods filter unit test stub.

Validates that the B1 guard in etl/transform_to_core.py:726-732 skips
Vinsight stock items where both IsPackagedWine and IsBulkWine are false.
Does NOT run the full transform (which would duplicate 119k sales_transaction
rows per Phase C plan C3). Treats the guard as a pure function over a
Vinsight-stock-item dict.
"""

EXPECTED_GUARD_LINES = (
    "is_wine = d.get(\"IsPackagedWine\") or d.get(\"IsBulkWine\")",
    "if not is_wine:",
    "continue",
)


def _filter_keeps(d: dict) -> bool:
    """Mirror of the guard on transform_to_core.py:726-732."""
    is_wine = d.get("IsPackagedWine") or d.get("IsBulkWine")
    return bool(is_wine)


def test_packaged_wine_is_kept():
    assert _filter_keeps({"StockItemCode": "MVLKSHZB21",
                          "IsPackagedWine": True, "IsBulkWine": False}) is True


def test_bulk_wine_is_kept():
    assert _filter_keeps({"StockItemCode": "BULK-CHD-2024",
                          "IsPackagedWine": False, "IsBulkWine": True}) is True


def test_both_flags_true_is_kept():
    assert _filter_keeps({"StockItemCode": "MIX",
                          "IsPackagedWine": True, "IsBulkWine": True}) is True


def test_carton_dry_good_is_skipped():
    assert _filter_keeps({"StockItemCode": "B-COCOGSPC12",
                          "Description": "Coppabella Sparkling Generic 12x750 carton",
                          "IsPackagedWine": False, "IsBulkWine": False}) is False


def test_cork_label_foil_all_skipped():
    for code, desc in [
        ("B-CORK-45MM", "Natural cork 45mm"),
        ("B-LBL-MV-LSK", "Lock & Key Shiraz front label"),
        ("B-FOIL-BLK",  "Black tin foil capsule"),
        ("B-CAP-SCREW", "Screwcap silver"),
        ("B-BOTTLE-750", "Empty 750ml Antique bottle"),
    ]:
        assert _filter_keeps({"StockItemCode": code, "Description": desc,
                              "IsPackagedWine": False, "IsBulkWine": False}) is False


def test_missing_flags_defaults_to_skip():
    # Vinsight stock items without either flag == not a wine; filter skips.
    assert _filter_keeps({"StockItemCode": "UNKNOWN"}) is False


def test_guard_literal_is_present_in_transform_to_core():
    """Codebase check: the 3 guard lines exist verbatim in the ETL module."""
    with open("etl/transform_to_core.py", "r", encoding="utf-8") as fh:
        src = fh.read()
    for needle in EXPECTED_GUARD_LINES:
        assert needle in src, f"B1 guard line missing: {needle!r}"


if __name__ == "__main__":
    for fn in [f for f in globals().values() if callable(f) and getattr(f, "__name__", "").startswith("test_")]:
        fn()
        print(f"ok {fn.__name__}")
    print("ALL OK")
