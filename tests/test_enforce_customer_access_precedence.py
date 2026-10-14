"""
Unit tests for etl/enforce_customer_access_precedence.py helpers.

Covers:
  - _clean_postcode (BUG-126 AC3) — Australian 4-digit postcode validator,
    rejects empty, sentinels like 'Not applicable', wrong length, non-digits.
  - _clean_rep     (BUG-129 AC3) — Rep sentinel filter, rejects empty,
    'NONE'/'UNKNOWN' (case-insensitive), preserves real names + trims
    surrounding whitespace.
"""
from __future__ import annotations

import sys
from pathlib import Path

# Make the repo root importable so `etl.enforce_customer_access_precedence`
# resolves when pytest is invoked from repo root or from tests/.
ROOT = Path(__file__).resolve().parent.parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from etl.enforce_customer_access_precedence import (  # noqa: E402
    _clean_postcode,
    _clean_rep,
)


# --------------------------------------------------------------------------- #
# _clean_postcode — BUG-126 AC3                                               #
# --------------------------------------------------------------------------- #
def test_clean_postcode_none_returns_none():
    assert _clean_postcode(None) is None


def test_clean_postcode_empty_returns_none():
    assert _clean_postcode("") is None


def test_clean_postcode_valid_four_digits():
    assert _clean_postcode("3220") == "3220"


def test_clean_postcode_not_applicable_sentinel_returns_none():
    assert _clean_postcode("Not applicable") is None


def test_clean_postcode_trailing_whitespace_trimmed_then_valid():
    assert _clean_postcode("3220 ") == "3220"


def test_clean_postcode_five_digits_returns_none():
    assert _clean_postcode("32200") is None


def test_clean_postcode_letters_returns_none():
    assert _clean_postcode("ABCD") is None


def test_clean_postcode_whitespace_padded_valid():
    assert _clean_postcode("  3220  ") == "3220"


def test_clean_postcode_whitespace_only_returns_none():
    assert _clean_postcode("   ") is None


def test_clean_postcode_three_digits_returns_none():
    assert _clean_postcode("322") is None


# --------------------------------------------------------------------------- #
# _clean_rep — BUG-129 AC3                                                    #
# --------------------------------------------------------------------------- #
def test_clean_rep_none_returns_none():
    assert _clean_rep(None) is None


def test_clean_rep_empty_returns_none():
    assert _clean_rep("") is None


def test_clean_rep_uppercase_none_sentinel_returns_none():
    # The exact sentinel observed for CustomerIDs 11208, 13737, 14867
    assert _clean_rep("NONE") is None


def test_clean_rep_lowercase_none_sentinel_returns_none():
    assert _clean_rep("none") is None


def test_clean_rep_whitespace_padded_none_sentinel_returns_none():
    assert _clean_rep("  NONE  ") is None


def test_clean_rep_real_name_preserved():
    assert _clean_rep("Rep B") == "Rep B"


def test_clean_rep_whitespace_padded_real_name_trimmed():
    assert _clean_rep("  Rep B  ") == "Rep B"


def test_clean_rep_uppercase_unknown_returns_none():
    # Defensive guard — not observed in current CSV but cheap to cover.
    assert _clean_rep("UNKNOWN") is None


def test_clean_rep_lowercase_unknown_returns_none():
    assert _clean_rep("unknown") is None
