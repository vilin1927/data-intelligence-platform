"""
Address-freshness reconciliation helper — Phase F.2 (BUG-111).

Encodes the owner's Mar 24 HARD rule for reconciling customer contact columns
(suburb, postcode, state, address_line1, address_line2, country) between our
live DB (Vinsight-sourced) and the Access canonical export:

    Fill NULL from Access only. Never overwrite a non-NULL Vinsight value.
    Log all conflicts for per-row the owner triage.

imports `reconcile_column` and the `FreshnessDecision` shape.
"""
from dataclasses import dataclass
from typing import Optional


@dataclass
class FreshnessDecision:
    new_value: Optional[str]
    action: str
    conflict: Optional[dict]


_VALID_ACTIONS = frozenset({
    "filled",
    "skipped_null_source",
    "match",
    "skipped_conflict",
    "both_null",
})


def _is_nullish(v: Optional[str]) -> bool:
    """Treat None, empty string, and whitespace-only as NULL."""
    return v is None or (isinstance(v, str) and v.strip() == "")


def reconcile_column(
    customer_id: str,
    column: str,
    db_value: Optional[str],
    access_value: Optional[str],
) -> FreshnessDecision:
    db_null = _is_nullish(db_value)
    access_null = _is_nullish(access_value)

    if db_null and access_null:
        return FreshnessDecision(new_value=None, action="both_null", conflict=None)

    if db_null and not access_null:
        return FreshnessDecision(new_value=access_value, action="filled", conflict=None)

    if not db_null and access_null:
        return FreshnessDecision(
            new_value=db_value, action="skipped_null_source", conflict=None
        )

    # Both non-NULL — case-sensitive equality.
    if db_value == access_value:
        return FreshnessDecision(new_value=db_value, action="match", conflict=None)

    return FreshnessDecision(
        new_value=db_value,
        action="skipped_conflict",
        conflict={
            "customer_id": customer_id,
            "column": column,
            "db_value": db_value,
            "access_value": access_value,
        },
    )
