"""Pure-function helpers for stock_unit normalization (BUG-118 / ADR-014).

Callers supply `quantity`, `unit`, and `units_per_case` — these helpers do
NOT hit the database. Look up `sku.units_per_case` at the caller (join,
cache, or direct query) before calling.

Contract:
    - `unit` is one of {'bottle','case'} (matches sales_transaction.stock_unit
      CHECK constraint from schema/063).
    - `units_per_case` is a positive integer. 1, 6, 12, or 24 on prod today.
    - `quantity` is any Decimal (including negative returns / adjustments).
    - Functions raise `ValueError` on invalid unit or non-positive units_per_case.
    - Conversion preserves Decimal precision; caller decides quantize().

Use `to_cases` before aggregating across source_systems in margin / channel /
reconciliation queries. Use `to_bottles` for per-bottle pricing comparisons.
"""

import logging
from decimal import Decimal
from typing import Optional

VALID_UNITS = ("bottle", "case")

logger = logging.getLogger(__name__)

# BUG-151: raw unit strings arriving from importer CSVs (Vinsight, DWS, ALM,
# Direct) vary in case and use vendor-specific shorthand. Map them to the
# canonical sales_transaction.stock_unit values ('case' | 'bottle') before
# INSERT. Unknowns fall through to 'case' with a warning (safer default than
# raising; mirrors current prod data where every row is 'case').
_UNIT_ALIASES: dict[str, str] = {
    "case": "case",
    "cases": "case",
    "cs": "case",
    "ctn": "case",
    "carton": "case",
    "bottle": "bottle",
    "bottles": "bottle",
    "btl": "bottle",
    "btls": "bottle",
    "ea": "bottle",
    "each": "bottle",
}


def _check(unit: str, units_per_case: int) -> None:
    if unit not in VALID_UNITS:
        raise ValueError(
            f"unit must be one of {VALID_UNITS}; got {unit!r}"
        )
    if not isinstance(units_per_case, int) or units_per_case < 1:
        raise ValueError(
            f"units_per_case must be positive int; got {units_per_case!r}"
        )


def to_cases(quantity: Decimal, unit: str, units_per_case: int) -> Decimal:
    """Convert `quantity` expressed in `unit` to cases.

    case    → returned unchanged.
    bottle  → divided by units_per_case (fractional cases are legitimate, e.g.
              partial-case sales).
    """
    _check(unit, units_per_case)
    if unit == "case":
        return quantity
    return quantity / Decimal(units_per_case)


def to_bottles(quantity: Decimal, unit: str, units_per_case: int) -> Decimal:
    """Convert `quantity` expressed in `unit` to bottles.

    bottle → returned unchanged.
    case   → multiplied by units_per_case.
    """
    _check(unit, units_per_case)
    if unit == "bottle":
        return quantity
    return quantity * Decimal(units_per_case)


def normalize_unit_string(raw: Optional[str]) -> str:
    """Coerce a vendor-supplied unit string to the canonical stock_unit value.

    Returns 'case' or 'bottle' (the only values allowed by the
    sales_transaction.stock_unit CHECK constraint from schema/063).

    Behaviour:
        - case-insensitive match on the alias table ('case'/'cs'/'ctn'/'carton'
          → 'case'; 'bottle'/'btl'/'ea'/'each' → 'bottle')
        - surrounding whitespace stripped
        - None, empty string, or unknown vocabulary → 'case' with a warning
          log (matches prod data where every row is 'case'; avoids raising
          on malformed vendor CSVs — importer resilience per ADR-014)
    """
    if raw is None:
        logger.warning("normalize_unit_string: None -> 'case' (fallback)")
        return "case"
    key = raw.strip().lower()
    if not key:
        logger.warning("normalize_unit_string: empty -> 'case' (fallback)")
        return "case"
    if key in _UNIT_ALIASES:
        return _UNIT_ALIASES[key]
    logger.warning(
        "normalize_unit_string: unknown unit %r -> 'case' (fallback)", raw
    )
    return "case"
