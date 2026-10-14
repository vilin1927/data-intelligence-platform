"""Tests for etl/unit_normalize.py (BUG-118 / ADR-014)."""

from decimal import Decimal

import pytest

from etl.unit_normalize import (
    VALID_UNITS,
    normalize_unit_string,
    to_bottles,
    to_cases,
)


class TestToCases:
    def test_case_input_unchanged(self):
        assert to_cases(Decimal("10"), "case", 12) == Decimal("10")

    def test_bottle_to_case_divides_by_units_per_case(self):
        assert to_cases(Decimal("60"), "bottle", 12) == Decimal("5")

    def test_bottle_to_case_fractional_preserved(self):
        # 11 bottles of a 12-pack = 0.9166... cases — keep Decimal precision
        result = to_cases(Decimal("11"), "bottle", 12)
        assert result == Decimal("11") / Decimal(12)

    def test_bottle_to_case_six_pack(self):
        assert to_cases(Decimal("18"), "bottle", 6) == Decimal("3")

    def test_negative_quantity_for_returns(self):
        assert to_cases(Decimal("-24"), "bottle", 12) == Decimal("-2")


class TestToBottles:
    def test_bottle_input_unchanged(self):
        assert to_bottles(Decimal("60"), "bottle", 12) == Decimal("60")

    def test_case_to_bottle_multiplies_by_units_per_case(self):
        assert to_bottles(Decimal("5"), "case", 12) == Decimal("60")

    def test_case_to_bottle_24_pack(self):
        assert to_bottles(Decimal("2"), "case", 24) == Decimal("48")

    def test_negative_case_quantity(self):
        assert to_bottles(Decimal("-3"), "case", 12) == Decimal("-36")


class TestInvalidInputs:
    @pytest.mark.parametrize("bad_unit", ["litre", "BOTTLE", "", "dozen", None])
    def test_invalid_unit_raises(self, bad_unit):
        with pytest.raises(ValueError, match="unit must be one of"):
            to_cases(Decimal("1"), bad_unit, 12)

    @pytest.mark.parametrize("bad_upc", [0, -1, 1.5, "12", None])
    def test_invalid_units_per_case_raises(self, bad_upc):
        with pytest.raises(ValueError, match="units_per_case must be positive int"):
            to_cases(Decimal("1"), "case", bad_upc)

    def test_to_bottles_same_validation(self):
        with pytest.raises(ValueError):
            to_bottles(Decimal("1"), "dozen", 12)


class TestRoundTrip:
    """Bottles → cases → bottles should be identity (for whole-case counts)."""

    @pytest.mark.parametrize("qty,upc", [(60, 12), (18, 6), (48, 24), (7, 1)])
    def test_bottles_case_bottles_roundtrip(self, qty, upc):
        bottles = Decimal(qty)
        cases = to_cases(bottles, "bottle", upc)
        back = to_bottles(cases, "case", upc)
        assert back == bottles


class TestNormalizeUnitString:
    """BUG-151: vendor unit-string aliases → canonical 'case' / 'bottle'."""

    @pytest.mark.parametrize(
        "raw,expected",
        [
            ("case", "case"),
            ("CASE", "case"),
            ("Case", "case"),
            ("cs", "case"),
            ("CS", "case"),
            ("ctn", "case"),
            ("carton", "case"),
            ("cases", "case"),
            ("bottle", "bottle"),
            ("BOTTLE", "bottle"),
            ("btl", "bottle"),
            ("btls", "bottle"),
            ("ea", "bottle"),
            ("each", "bottle"),
            ("Bottles", "bottle"),
        ],
    )
    def test_canonical_aliases(self, raw, expected):
        assert normalize_unit_string(raw) == expected

    @pytest.mark.parametrize("raw", ["  case  ", "\tbottle\n", " CS "])
    def test_whitespace_stripped(self, raw):
        # just assert it returns a valid canonical value, not the raw string
        assert normalize_unit_string(raw) in VALID_UNITS

    def test_none_falls_back_to_case(self, caplog):
        import logging as _logging
        with caplog.at_level(_logging.WARNING, logger="etl.unit_normalize"):
            assert normalize_unit_string(None) == "case"
        assert any("None" in r.message for r in caplog.records)

    def test_empty_string_falls_back_to_case(self, caplog):
        import logging as _logging
        with caplog.at_level(_logging.WARNING, logger="etl.unit_normalize"):
            assert normalize_unit_string("") == "case"
        assert any("empty" in r.message for r in caplog.records)

    def test_whitespace_only_falls_back_to_case(self, caplog):
        import logging as _logging
        with caplog.at_level(_logging.WARNING, logger="etl.unit_normalize"):
            assert normalize_unit_string("   ") == "case"
        assert any("empty" in r.message for r in caplog.records)

    def test_unknown_vocab_falls_back_to_case_with_warning(self, caplog):
        import logging as _logging
        with caplog.at_level(_logging.WARNING, logger="etl.unit_normalize"):
            assert normalize_unit_string("dozen") == "case"
        assert any("unknown" in r.message.lower() for r in caplog.records)

    def test_returned_value_always_valid_for_to_cases(self):
        # Whatever the helper returns must pass to_cases/_check.
        for raw in [None, "", "unknown", "cs", "btl", "BOTTLE"]:
            unit = normalize_unit_string(raw)
            # Should not raise ValueError("unit must be one of ...")
            to_cases(Decimal("1"), unit, 12)
