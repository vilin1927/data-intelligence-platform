"""
B11 — unit tests for connectors/vinsight_direct_filter.py (JC-047, AC5).

Verifies the Vinsight Direct exclusion rule:
  Exclude only ALM Fyshwick / Huntingwood / Laverton (channel-transfer),
  any DWS-prefixed customer (channel-transfer), and ML category
  (mail-order). Everything else imports.
"""
from __future__ import annotations

import pytest

from connectors.vinsight_direct_filter import (
    should_include_direct,
    EXCLUDE_NAME_EXACT,
    EXCLUDE_CATEGORY_TAGS,
)


@pytest.mark.parametrize(
    "name",
    [
        "ALM Fyshwick",
        "ALM FYSHWICK",
        "alm huntingwood",   # case-insensitive
        "ALM Laverton",
        "  ALM Laverton  ",  # leading/trailing whitespace
    ],
)
def test_alm_transfer_dummies_excluded(name: str) -> None:
    assert should_include_direct(name) is False


@pytest.mark.parametrize(
    "name",
    [
        "DWS NSW",
        "DWS QLD",
        "DWS Victoria",
        "DWS WA",
        "Domaine Wine Shippers Pty Ltd",
        "DOMAINE WINE SHIPPERS",
    ],
)
def test_dws_transfer_dummies_excluded(name: str) -> None:
    assert should_include_direct(name) is False


@pytest.mark.parametrize(
    "category",
    [
        "ML",
        ["ML"],
        ["GROWER", "ML"],
        "Wholesale; ML; ON PREMISE",
        ["Wholesale", "ml"],          # case-insensitive
        "MAIL ORDER",
        ["mail order"],
    ],
)
def test_ml_category_excluded(category) -> None:
    assert should_include_direct("Real Customer Pty Ltd", category) is False


def test_real_direct_customer_included() -> None:
    assert should_include_direct("Customer 104", []) is True
    assert should_include_direct("Vintage Cellars Brisbane", "ON PREMISE") is True
    assert should_include_direct(
        "Dan Murphy's Chatswood",
        ["OFF PREMISE", "Wholesale"],
    ) is True


def test_empty_or_none_name_returns_true_when_no_excluding_category() -> None:
    # Empty name is not the filter's job to reject — importer guards that.
    assert should_include_direct(None) is True
    assert should_include_direct("") is True


def test_empty_name_with_ml_category_excluded() -> None:
    # Even with no name, if category says ML, exclude.
    assert should_include_direct(None, "ML") is False


def test_constants_are_frozensets() -> None:
    # Light contract test — protects against accidental mutation.
    assert isinstance(EXCLUDE_NAME_EXACT, frozenset)
    assert isinstance(EXCLUDE_CATEGORY_TAGS, frozenset)
    assert "ALM FYSHWICK" in EXCLUDE_NAME_EXACT
    assert "ML" in EXCLUDE_CATEGORY_TAGS
