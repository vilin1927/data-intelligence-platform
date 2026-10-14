"""
Upload duplicate detection (Bundle B12 / JC-295).

Provides a content-addressed hash for each upload row and a query helper that
detects rows already seen on a prior upload of the same channel.

Hash scope: (channel, customer_key, sku_key, month_key, quantity).
- channel:       'dws' | 'alm' | 'direct' | 'ilg' | 'ynr'
- customer_key:  raw customer code or canonical name (strip leading zeros first)
- sku_key:       raw SKU/product code (uppercased)
- month_key:     'YYYY-MM' derived from sale_date
- quantity:      Decimal, 4 decimal places, '0.0000' if None

The hash IS NOT the same as `sales_transaction.content_hash`. content_hash
guarantees idempotency on canonical insert (used by importers' ON CONFLICT
clause). upload_row_hash is the user-facing "this looks like a duplicate"
signal that survives even if a row got rejected before insert.

Storage: `upload_row_hash` (schema/096) — PK on row_hash, FK on upload_batch.

Usage::

    from etl.upload_duplicate_detect import compute_row_hash, detect_duplicates

    rows = [
        {'customer_key': '1234', 'sku_key': 'MOLKSH21F',
         'month_key': '2026-02', 'quantity': Decimal('4')},
        ...
    ]
    dup_set = detect_duplicates(conn, channel='dws', rows=rows)
    # dup_set is a set[str] of row_hash values that already exist.

    persist_row_hashes(conn, channel='dws', upload_batch_id=42, rows=rows)
"""

from __future__ import annotations

import hashlib
from decimal import Decimal
from typing import Iterable

import psycopg2.extras


# ---------------------------------------------------------------------------
# Hash helpers
# ---------------------------------------------------------------------------

def _strip_leading_zeros(value: str) -> str:
    """JC-298: strip leading zeros from numeric customer codes.

    "0001234" -> "1234"; "00123" -> "123"; "0" -> "" (matches schema/096
    customer_code_stripped column derivation).
    """
    if value is None:
        return ""
    text = str(value).strip()
    if not text:
        return ""
    if text.lstrip("0") == "":
        return ""
    return text.lstrip("0") if text.isdigit() or text.lstrip("0").isdigit() else text


def _normalize_quantity(qty) -> str:
    if qty is None:
        return "0.0000"
    if not isinstance(qty, Decimal):
        try:
            qty = Decimal(str(qty))
        except (ValueError, TypeError):
            return "0.0000"
    return f"{qty:.4f}"


def compute_row_hash(
    channel: str,
    customer_key: str | None,
    sku_key: str | None,
    month_key: str | None,
    quantity,
) -> str:
    """Return SHA-256 hex (64 chars) of the canonical row identity tuple."""
    customer = _strip_leading_zeros(customer_key or "").upper()
    sku = (sku_key or "").strip().upper()
    month = (month_key or "").strip()
    qty = _normalize_quantity(quantity)
    payload = f"{channel}|{customer}|{sku}|{month}|{qty}".encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


# ---------------------------------------------------------------------------
# DB helpers
# ---------------------------------------------------------------------------

def detect_duplicates(
    conn,
    *,
    channel: str,
    rows: Iterable[dict],
) -> set[str]:
    """Given an iterable of row dicts, return the set of hashes already in DB.

    Each row dict must carry: customer_key, sku_key, month_key, quantity.
    """
    hashes: list[str] = []
    for row in rows:
        h = compute_row_hash(
            channel,
            row.get("customer_key"),
            row.get("sku_key"),
            row.get("month_key"),
            row.get("quantity"),
        )
        hashes.append(h)
        row.setdefault("row_hash", h)

    if not hashes:
        return set()

    with conn.cursor() as cur:
        cur.execute(
            "SELECT row_hash FROM upload_row_hash WHERE row_hash = ANY(%s)",
            (hashes,),
        )
        existing = {r[0] for r in cur.fetchall()}
    return existing


def persist_row_hashes(
    conn,
    *,
    channel: str,
    upload_batch_id: int,
    rows: Iterable[dict],
) -> int:
    """Insert (row_hash, ...) for each row. ON CONFLICT DO NOTHING.

    Returns the number of NEW hashes successfully persisted (i.e. not seen
    before in this channel).
    """
    payload = []
    for row in rows:
        h = row.get("row_hash") or compute_row_hash(
            channel,
            row.get("customer_key"),
            row.get("sku_key"),
            row.get("month_key"),
            row.get("quantity"),
        )
        payload.append((
            h,
            upload_batch_id,
            channel,
            (row.get("customer_key") or "")[:200],
            (row.get("sku_key") or "")[:200],
            (row.get("month_key") or "")[:10],
            _normalize_quantity(row.get("quantity")),
        ))
    if not payload:
        return 0
    with conn.cursor() as cur:
        before = cur.rowcount
        psycopg2.extras.execute_values(
            cur,
            "INSERT INTO upload_row_hash "
            "(row_hash, upload_batch_id, channel, customer_key, sku_key, month_key, quantity) "
            "VALUES %s ON CONFLICT (row_hash) DO NOTHING",
            payload,
        )
        return cur.rowcount if cur.rowcount and cur.rowcount > 0 else 0


__all__ = [
    "compute_row_hash",
    "detect_duplicates",
    "persist_row_hashes",
]
