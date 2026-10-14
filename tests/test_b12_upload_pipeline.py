"""Bundle B12 — unit tests for upload pipeline helpers.

Covers JC-295 / JC-297 / JC-298 / JC-301 / JC-306 in pure-python (no DB).
"""

from decimal import Decimal

import pytest

from etl.upload_duplicate_detect import compute_row_hash
from etl.import_dws_zip import (
    derive_cases9ltr,
    is_valid_dws_sku_code,
    looks_like_alm_row,
    strip_customer_leading_zeros,
)


# ---------------------------------------------------------------------------
# JC-298 — leading-zero strip
# ---------------------------------------------------------------------------

@pytest.mark.parametrize(
    "raw, expected",
    [
        ("0001234", "1234"),
        ("00123", "123"),
        ("0", ""),
        ("000", ""),
        ("", ""),
        (None, ""),
        ("CUST12", "CUST12"),
        ("0CUST", "CUST"),
        ("1234", "1234"),
    ],
)
def test_strip_customer_leading_zeros(raw, expected):
    assert strip_customer_leading_zeros(raw) == expected


# ---------------------------------------------------------------------------
# JC-301 — DWS code naming convention
# ---------------------------------------------------------------------------

@pytest.mark.parametrize(
    "code, valid",
    [
        ("MOLKSH21F", True),
        ("COCCCHAB22", True),
        ("MOATRI26F", True),
        ("MO_LKSH-21", True),  # underscore + dash allowed after alpha prefix
        ("123456", False),     # pure-numeric rejected
        ("12ABC", False),      # leading numeric rejected
        ("", False),
        (None, False),
        ("XX", False),         # too short (under 3 chars)
        ("A1", False),
    ],
)
def test_is_valid_dws_sku_code(code, valid):
    assert is_valid_dws_sku_code(code) is valid


# ---------------------------------------------------------------------------
# JC-297 — ALM row detection inside DWS upload
# ---------------------------------------------------------------------------

def test_looks_like_alm_row_true():
    assert looks_like_alm_row({"SOURCE": "ALM-NSW"})
    assert looks_like_alm_row({"SOURCE": "AUSTRALIAN LIQUOR MARKETERS"})
    assert looks_like_alm_row({"STOCKITEM": "12345"})  # numeric SKU
    assert looks_like_alm_row({"DRTYPE": "WHOLESALE-ALM"})


def test_looks_like_alm_row_false():
    assert not looks_like_alm_row({"SOURCE": "DWS", "STOCKITEM": "MOLKSH21F"})
    assert not looks_like_alm_row({"SOURCE": "", "STOCKITEM": "COCCCHAB22"})


# ---------------------------------------------------------------------------
# JC-306 — CASES9LTR canonical case unit
# ---------------------------------------------------------------------------

def test_derive_cases9ltr_direct():
    assert derive_cases9ltr({"CASES9LTR": "4.5"}) == Decimal("4.5")


def test_derive_cases9ltr_from_9l_desc():
    assert derive_cases9ltr({"STKDESC1": "9 LITRE BOX", "CARTONS": "12"}) == Decimal("12")
    assert derive_cases9ltr({"STKDESC2": "WINE 9LTR", "CARTONS": "8"}) == Decimal("8")


def test_derive_cases9ltr_from_bottles():
    # 108 bottles / 9 = 12 cases (when CASES9LTR & 9L desc absent)
    assert derive_cases9ltr({"BOTTLES": "108"}) == Decimal("12.0000")


def test_derive_cases9ltr_none_when_no_signal():
    assert derive_cases9ltr({"STKDESC1": "750ML", "CARTONS": "1"}) is None


# ---------------------------------------------------------------------------
# JC-295 — duplicate detection hash
# ---------------------------------------------------------------------------

def test_hash_leading_zero_invariance():
    h1 = compute_row_hash("dws", "0001234", "MOLKSH21F", "2026-02", Decimal("4"))
    h2 = compute_row_hash("dws", "1234", "MOLKSH21F", "2026-02", Decimal("4"))
    assert h1 == h2


def test_hash_case_invariance_on_sku():
    h1 = compute_row_hash("dws", "1234", "MOLKSH21F", "2026-02", Decimal("4"))
    h2 = compute_row_hash("dws", "1234", "molksh21f", "2026-02", Decimal("4"))
    assert h1 == h2


def test_hash_quantity_normalization():
    h1 = compute_row_hash("dws", "1234", "X", "2026-02", Decimal("4"))
    h2 = compute_row_hash("dws", "1234", "X", "2026-02", Decimal("4.0"))
    h3 = compute_row_hash("dws", "1234", "X", "2026-02", "4")
    assert h1 == h2 == h3


def test_hash_channel_isolation():
    h_dws = compute_row_hash("dws", "1234", "X", "2026-02", Decimal("4"))
    h_alm = compute_row_hash("alm", "1234", "X", "2026-02", Decimal("4"))
    assert h_dws != h_alm


def test_hash_quantity_changes_hash():
    h1 = compute_row_hash("dws", "1234", "X", "2026-02", Decimal("4"))
    h2 = compute_row_hash("dws", "1234", "X", "2026-02", Decimal("5"))
    assert h1 != h2
