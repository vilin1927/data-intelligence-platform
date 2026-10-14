"""
B11 — Vinsight Direct exclusion filter (JC-047).

Consolidates the channel-transfer + mail-order exclusion rule for Vinsight
Direct sales imports. Two layers of input:

  * `contact_name`     — the Vinsight Contact `Name` (or `CompanyName` /
                         `ContactName` fallback) from `staging_vinsight_contacts`.
  * `contact_category` — the joined Vinsight `ContactCategory` bag (list or
                         semicolon-delimited string).

JC-047 spec (extract-docx-0061):
  Vinsight Direct imports must filter to exclude only:
    - ALM Fyshwick / Huntingwood / Laverton
    - DWS (Domaine Wine Shippers; covers DWS NSW, DWS QLD, DWS Victoria, etc.)
    - Mail-order: Vinsight Contact Category "ML"
  All other Direct rows imported.

Why this lives in `connectors/`
-------------------------------
`etl/import_direct.py` already does name-based exclusion (added in B4) but
does NOT see ContactCategory because the Direct CSV does not carry it. This
module gives B12 (upload-pipeline hardening) a single function it can call
*after* joining a Direct row to its Vinsight contact, so the ML-category
exclusion lands consistently across all import paths.

`etl/filter_vinsight_moppity_customers.py` already encodes the same rule for
the contact-level `is_moppity_customer` flag — but that's per-contact, not
per-sale. This module is the per-sale-row equivalent.

This module is intentionally pure-Python with no DB imports — easy to unit
test (`tests/test_vinsight_direct_filter.py`).
"""
from __future__ import annotations

from typing import Iterable, Optional, Union

CategoryInput = Union[str, Iterable[str], None]

EXCLUDE_NAME_EXACT: frozenset[str] = frozenset({
    "ALM FYSHWICK",
    "ALM HUNTINGWOOD",
    "ALM LAVERTON",
})

EXCLUDE_NAME_PREFIX: tuple[str, ...] = (
    "DWS ",                  # DWS NSW, DWS QLD, DWS Victoria, DWS WA, ...
    "DOMAINE WINE SHIPPERS", # DWS brand
    "MAIL ORDER",            # belt-and-braces alongside ML category
)

EXCLUDE_CATEGORY_TAGS: frozenset[str] = frozenset({
    "ML",            # mail-order subscription
    "MAIL ORDER",    # spelled-out variant
    "DWS",           # DWS-as-category
})


def _normalise_categories(categories: CategoryInput) -> list[str]:
    """Coerce string|list|None → uppercase list of trimmed tags."""
    if categories is None:
        return []
    if isinstance(categories, str):
        # Split on ';' (Vinsight ContactCategoryString shape).
        parts = [p.strip() for p in categories.split(";")]
    else:
        parts = [str(c).strip() for c in categories]
    return [p.upper() for p in parts if p]


def should_include_direct(
    contact_name: Optional[str],
    contact_category: CategoryInput = None,
) -> bool:
    """Return True if this Vinsight Direct row should be imported as a
    genuine Direct sale; False if it is a channel-transfer dummy or a
    mail-order subscription drop that JC-047 excludes.

    Empty / None contact_name returns True (the importer's own guards
    handle missing names — this filter is for *positive* exclusion only).
    """
    if contact_name:
        n = contact_name.strip().upper()
        if n in EXCLUDE_NAME_EXACT:
            return False
        for prefix in EXCLUDE_NAME_PREFIX:
            if n.startswith(prefix):
                return False

    cats = _normalise_categories(contact_category)
    if any(tag in cats for tag in EXCLUDE_CATEGORY_TAGS):
        return False

    return True


__all__ = [
    "EXCLUDE_NAME_EXACT",
    "EXCLUDE_NAME_PREFIX",
    "EXCLUDE_CATEGORY_TAGS",
    "should_include_direct",
]
