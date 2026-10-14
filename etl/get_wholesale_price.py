"""
Wholesale-price single-source-of-truth helper — Phase J (BUG-103).


  - Open period (no row in month_end_snapshot for the sale's YYYY-MM):
      read current price from vinsight_stock_items.
  - Closed period (row exists in month_end_snapshot):
      read frozen price from canonical_sku.base_wholesale.
  - Scheduling Google Sheet ("Vladimir notes" tab) is NEVER read by this path
    — it is a planning layer per the owner Mar 25 and is now terminal at
    staging_sheets_wholesale for drift-diagnostic purposes only.

This module is the blessed single entry point. All new pricing / reporting
consumers MUST route through `get_wholesale_price(sku_id, as_of_date)` rather
than querying any of the three underlying sources directly. Existing sites
that hard-code `canonical_sku.base_wholesale` (schema/018, schema/038,
schema/041, schema/050, etl/transform_to_core.py) are migration debt to be
folded behind this helper in Phases K / L.

Not wired to any consumer yet. Phase K is responsible for the first caller.

TODO(Phase K consumer): migrate sync_vinsight_direct_sales and
transform_to_core.py to call this helper instead of COALESCE(..., base_wholesale).
"""

from __future__ import annotations

import logging
import os
from datetime import date
from decimal import Decimal
from typing import Optional

import psycopg2
import psycopg2.extras

logger = logging.getLogger("moppity.etl.get_wholesale_price")


def _period_str(as_of: date) -> str:
    """Return YYYY-MM string for a given date, matching month_end_snapshot.period format."""
    return as_of.strftime("%Y-%m")


def _is_period_closed(cur, as_of: date) -> bool:
    """
    Return True if the YYYY-MM of `as_of` has a row in month_end_snapshot.

    Per ADR-008 (Month-End Snapshot Strategy), the existence of a row in
    month_end_snapshot for a period is sufficient to treat it as closed.
    The table has no is_closed column — existence is the signal.
    """
    cur.execute(
        "SELECT 1 FROM month_end_snapshot WHERE period = %s LIMIT 1",
        (_period_str(as_of),),
    )
    return cur.fetchone() is not None


def _fetch_vinsight_current_price(cur, sku_id: int) -> Optional[Decimal]:
    """
    Return the latest Vinsight-reported wholesale price for a SKU.

    Queries staging_vinsight_stock_items.raw_data->>'BaseWholesale' for the
    most recent fetched row matching the given sku_id (resolved via
    sku.sku_code ↔ raw_data->>'ItemCode').

    Returns None if no Vinsight stock-item row exists for this SKU; callers
    should decide whether to fall back or raise.
    """
    cur.execute(
        """
        -- B3-4 shape guard (2026-05-11): LENGTH <= 30. schema/155.
        SELECT (sv.raw_data->>'BaseWholesale')::DECIMAL(10,2) AS base_wholesale
        FROM staging_vinsight_stock_items sv
        JOIN sku s ON s.sku_code = sv.raw_data->>'ItemCode'
        WHERE s.sku_id = %s
          AND sv.raw_data->>'BaseWholesale' IS NOT NULL
          AND LENGTH(sv.raw_data->>'ItemCode') <= 30
        ORDER BY sv.fetched_at DESC
        LIMIT 1
        """,
        (sku_id,),
    )
    row = cur.fetchone()
    if row is None:
        return None
    return row[0]


def _fetch_canonical_frozen_price(cur, sku_id: int) -> Optional[Decimal]:
    """
    Return the frozen canonical_sku.base_wholesale for a SKU.

    Resolves sku → canonical_sku via the canonical_sku_id FK populated by
    etl/build_canonical_sku_map.py. Returns None if the SKU has not been
    linked to a canonical row yet.

    Also reads `sku.pack_size` and emits a logger.warning when non-NULL: this
    flags the ADR-009 pack_size Known Limitation (BUG-140) — canonical price
    is at canonical grain, half-bottles almost certainly shouldn't inherit
    750ml LIST. The price is still returned (no fallback decided yet); the
    warning lets log-greps quantify occurrences before the owner picks a fix.
    """
    cur.execute(
        """
        SELECT cs.base_wholesale, s.pack_size
        FROM sku s
        JOIN canonical_sku cs ON cs.id = s.canonical_sku_id
        WHERE s.sku_id = %s
        """,
        (sku_id,),
    )
    row = cur.fetchone()
    if row is None:
        return None
    price, pack_size = row[0], row[1]
    if pack_size is not None:
        logger.warning(
            "get_wholesale_price sku_id=%s has pack_size=%s but returning "
            "canonical base_wholesale=%s (ADR-009 Known Limitation, BUG-140): "
            "canonical price is at canonical grain; non-majority pack sizes "
            "may ship wrong LIST until the owner confirms fix option.",
            sku_id, pack_size, price,
        )
    return price


def get_wholesale_price(sku_id: int, as_of_date: date) -> Optional[Decimal]:
    """
    Return the authoritative wholesale LIST price for a SKU at a given date.

    Source selection follows ADR-009:
      * as_of_date in an OPEN period  → live Vinsight price
      * as_of_date in a CLOSED period → frozen canonical_sku.base_wholesale

    Scheduling sheet ("Vladimir notes") is dropped from the read path.

    Args:
        sku_id: primary key of the `sku` table (NOT canonical_sku.id).
        as_of_date: the sale / reporting date. Used to look up the YYYY-MM
            in month_end_snapshot and decide open vs closed.

    Returns:
        The wholesale list price per case as Decimal, or None if the
        underlying source has no row for the SKU. Callers should treat
        None as "unknown price" and fall back per their own policy
        (transform pipelines typically emit a warning and carry NULL).

    Raises:
        psycopg2.DatabaseError: on connection / query failure. The helper
        does not swallow DB errors — let callers decide retry policy.

    Example:
        >>> from datetime import date
        >>> price = get_wholesale_price(sku_id=42, as_of_date=date(2025, 3, 15))
        >>> # If 2025-03 is closed: reads from canonical_sku.base_wholesale.
        >>> # If 2025-03 is open:   reads latest vinsight_stock_items price.

    TODO(Phase K consumer): wire this helper into
        - etl/transform_to_core.py (sku base_wholesale upsert path)
        - schema/050 sync_vinsight_direct_sales fallback branch
        - dashboard margin / revenue reports
      Each call-site migration should be its own commit.
    """
    database_url = os.environ.get("DATABASE_URL")
    if not database_url:
        raise RuntimeError(
            "DATABASE_URL env var is required; get_wholesale_price opens its own "
            "short-lived connection per call. Set DATABASE_URL before invoking."
        )

    with psycopg2.connect(database_url) as conn:
        with conn.cursor() as cur:
            closed = _is_period_closed(cur, as_of_date)

            if closed:
                price = _fetch_canonical_frozen_price(cur, sku_id)
                source = "canonical_sku.base_wholesale (closed period)"
            else:
                price = _fetch_vinsight_current_price(cur, sku_id)
                source = "vinsight_stock_items (open period)"

            logger.debug(
                "get_wholesale_price sku_id=%s as_of=%s closed=%s source=%s price=%s",
                sku_id, as_of_date, closed, source, price,
            )
            return price
