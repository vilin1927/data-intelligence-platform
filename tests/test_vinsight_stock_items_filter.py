"""
BUG-176 (2026-05-04) — unit test for the per-batch-integer leak filter in
etl/sync_vinsight_cogs.py:_transform_stock_items().

Vinsight `StockItemNum` is a per-batch packaging-operation integer
(e.g. 1644, 1645, 1974) — the WRONG GRAIN for sku_code_map. Real Moppity
SKU codes are alphanumeric strings like 'COCSCHAB22'. Without the BUG-176
filter (a Postgres `~` regex `^[0-9]+$` on the SELECT WHERE clause), every
nightly Vinsight sync re-introduces 8+ numeric per-batch IDs into
sku_code_map and silently regresses the BUG-175 + BUG-175b cleanup.

This test verifies three things WITHOUT touching a real database:

  1. The module-level constant `VINSIGHT_NUMERIC_STOCK_ITEM_NUM_PATTERN`
     correctly matches numeric strings and rejects alphanumeric ones.
  2. The literal SQL filter clause is present verbatim in the writer's
     `_transform_stock_items()` source — codebase regression catch.
  3. End-to-end Python-side simulation of the SQL filter on a synthetic
     Vinsight payload: only the Moppity-style code lands in the
     emitted-rows list, the integer is dropped.

Mirrors the proven pattern from tests/test_bug91_dry_goods_filter.py
(literal-line check + pure-function mirror — no live DB).
"""

from __future__ import annotations

import re

import pytest

from etl.sync_vinsight_cogs import VINSIGHT_NUMERIC_STOCK_ITEM_NUM_PATTERN


# ─── 1. Constant correctness ────────────────────────────────────────────

def test_pattern_is_anchored_numeric_only() -> None:
    """Pattern must be exactly `^[0-9]+$` per BUG-176 spec."""
    assert VINSIGHT_NUMERIC_STOCK_ITEM_NUM_PATTERN == r'^[0-9]+$'


@pytest.mark.parametrize(
    "value",
    ["1644", "1645", "1646", "1974", "1975", "2017", "2371", "2611",  # the BUG-175 8
     "0", "1", "999999"],
)
def test_pattern_matches_numeric_stock_item_nums(value: str) -> None:
    """All purely-numeric per-batch IDs must match (and therefore be filtered)."""
    assert re.match(VINSIGHT_NUMERIC_STOCK_ITEM_NUM_PATTERN, value) is not None


@pytest.mark.parametrize(
    "value",
    [
        "COCSCHAB22",       # Coppabella Sirius Chardonnay 2022 (the canonical example)
        "MVLKSHZB21",       # Moppity Vineyards Lock & Key Shiraz 2021
        "MVLKSHZB24",       # current vintage
        "X-COCSCHAB17",     # alt-prefixed variant
        "B-COCSATLC06",     # bulk-prefixed
        "ML-CAB-2024",      # any mixed code
        "12PICCSU01CTU",    # batch code with leading digits but alpha mixed in
    ],
)
def test_pattern_does_not_match_moppity_codes(value: str) -> None:
    """Real Moppity SKU codes (alphanumeric) must NOT match — they should pass through."""
    assert re.match(VINSIGHT_NUMERIC_STOCK_ITEM_NUM_PATTERN, value) is None


def test_pattern_does_not_match_negative_or_decimal() -> None:
    # Edge cases — negatives/decimals are not strictly numeric IDs and would
    # never appear as StockItemNum anyway, but document the contract.
    assert re.match(VINSIGHT_NUMERIC_STOCK_ITEM_NUM_PATTERN, "-1644") is None
    assert re.match(VINSIGHT_NUMERIC_STOCK_ITEM_NUM_PATTERN, "16.44") is None
    assert re.match(VINSIGHT_NUMERIC_STOCK_ITEM_NUM_PATTERN, "") is None


# ─── 2. Literal-line presence in the writer (regression catch) ──────────

EXPECTED_FILTER_FRAGMENTS = (
    # The constant must be defined.
    "VINSIGHT_NUMERIC_STOCK_ITEM_NUM_PATTERN = r'^[0-9]+$'",
    # The WHERE clause must reference the constant via the `!~` operator.
    "si.raw_data->>'StockItemNum' !~ %s",
    # The execute() call must pass the constant as a parameter.
    "(VINSIGHT_NUMERIC_STOCK_ITEM_NUM_PATTERN,),",
)


def test_filter_fragments_are_present_in_writer() -> None:
    """Codebase check — the BUG-176 filter wiring must exist verbatim in the
    writer. Catches a future refactor that drops the regex param or rewires
    the INSERT in a way that bypasses the filter.
    """
    with open("etl/sync_vinsight_cogs.py", "r", encoding="utf-8") as fh:
        src = fh.read()
    for needle in EXPECTED_FILTER_FRAGMENTS:
        assert needle in src, f"BUG-176 filter wiring missing: {needle!r}"


# ─── 3. Python-side mirror of the SQL filter on a synthetic payload ─────

# Synthetic Vinsight /StockItems.json payload — one Moppity-style code +
# one per-batch integer. Mirrors the shape of staging_vinsight_stock_items.raw_data.
SYNTHETIC_PAYLOAD = [
    {
        # GOOD: alphanumeric Moppity code — must land in sku_code_map.
        "StockItemNum": "COCSCHAB22",
        "StockItemCode": "COCSCHAB22",
        "Description": "Coppabella Sirius Chardonnay 2022",
        "IsPackagedWine": True,
    },
    {
        # BAD: per-batch integer — must be filtered out (BUG-176).
        "StockItemNum": "1644",
        "StockItemCode": "COCSCHAB22",   # joins to same canonical sku
        "Description": "Packaging op #1644 against COCSCHAB22",
        "IsPackagedWine": True,
    },
]


def _mirror_bug176_filter(payload: list[dict]) -> list[str]:
    """Pure-Python mirror of the SQL filter applied in
    sync_vinsight_cogs._transform_stock_items().

    Returns the StockItemNum values that WOULD land in sku_code_map after
    the BUG-176 filter runs. The real implementation does this server-side
    via Postgres `~` regex; this mirror lets us exercise it without spinning
    up a database.
    """
    pattern = re.compile(VINSIGHT_NUMERIC_STOCK_ITEM_NUM_PATTERN)
    emitted: list[str] = []
    for raw in payload:
        # Mirror the SELECT WHERE clauses, in the same order:
        if not raw.get("IsPackagedWine"):
            continue
        if not raw.get("StockItemCode"):
            continue
        stock_item_num = raw.get("StockItemNum")
        if stock_item_num is None:
            continue
        # BUG-176: skip purely-numeric StockItemNum.
        if pattern.match(str(stock_item_num)):
            continue
        emitted.append(str(stock_item_num))
    return emitted


def test_mixed_payload_only_emits_moppity_code() -> None:
    """End-to-end: synthetic Vinsight payload with one Moppity code + one
    integer should emit ONLY the Moppity code (BUG-176 acceptance criterion 3).
    """
    emitted = _mirror_bug176_filter(SYNTHETIC_PAYLOAD)
    assert emitted == ["COCSCHAB22"], (
        f"BUG-176 filter failed: expected ['COCSCHAB22'], got {emitted!r}. "
        f"Per-batch integer '1644' must be filtered out."
    )


def test_all_eight_bug175_integers_filtered() -> None:
    """The 8 per-batch StockItemNum integers BUG-175 schema/129 deleted
    (1644, 1645, 1646, 1974, 1975, 2017, 2371, 2611) must all be filtered
    by the BUG-176 source-of-leak fix so the cleanup never regresses on the
    next nightly Vinsight sync.
    """
    payload = [
        {
            "StockItemNum": str(n),
            "StockItemCode": "COCSCHAB22",
            "IsPackagedWine": True,
        }
        for n in (1644, 1645, 1646, 1974, 1975, 2017, 2371, 2611)
    ]
    assert _mirror_bug176_filter(payload) == [], (
        "BUG-176 leak: at least one of the BUG-175 8 numeric per-batch "
        "StockItemNum values bypassed the filter."
    )


def test_only_moppity_codes_pass_when_no_integers_present() -> None:
    """Sanity check — payload of only alphanumeric codes is unchanged."""
    payload = [
        {"StockItemNum": "COCSCHAB22", "StockItemCode": "COCSCHAB22", "IsPackagedWine": True},
        {"StockItemNum": "MVLKSHZB21", "StockItemCode": "MVLKSHZB21", "IsPackagedWine": True},
        {"StockItemNum": "X-COCSCHAB17", "StockItemCode": "X-COCSCHAB17", "IsPackagedWine": True},
    ]
    assert _mirror_bug176_filter(payload) == [
        "COCSCHAB22", "MVLKSHZB21", "X-COCSCHAB17",
    ]


def test_non_packaged_wine_still_skipped() -> None:
    """Pre-existing IsPackagedWine guard must continue to work alongside BUG-176."""
    payload = [
        {"StockItemNum": "COCSCHAB22", "StockItemCode": "COCSCHAB22", "IsPackagedWine": False},
        {"StockItemNum": "B-CORK-45MM", "StockItemCode": "B-CORK-45MM", "IsPackagedWine": False},
    ]
    assert _mirror_bug176_filter(payload) == []


if __name__ == "__main__":
    # Allows running the file directly without pytest for quick local checks.
    import sys
    fns = [v for v in globals().values()
           if callable(v) and getattr(v, "__name__", "").startswith("test_")
           and not getattr(v, "pytestmark", None)]
    failed = []
    for fn in fns:
        try:
            fn()
            print(f"ok {fn.__name__}")
        except AssertionError as exc:
            failed.append((fn.__name__, exc))
            print(f"FAIL {fn.__name__}: {exc}")
    if failed:
        sys.exit(1)
    print("ALL OK")
