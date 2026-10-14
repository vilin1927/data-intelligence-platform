"""
Phase J — unit tests for etl/get_wholesale_price.py (BUG-103).

Mocks the psycopg2 cursor because the helper opens a short-lived DB
connection via DATABASE_URL. Full integration coverage against moppity_test
(restored from full_pre_phase_i_v2_2026-04-24.pgdump) is tracked under
BUG-141 and is not in scope for Phase J.

Test matrix (per ADR-009):
  1. Closed period + canonical has base_wholesale → returns canonical price.
  2. Closed period + canonical missing → returns None (caller policy).
  3. Open period + Vinsight has price → returns Vinsight price.
  4. Open period + Vinsight missing → returns None.
  5. pack_size non-NULL on closed-period path → logger.warning fires
     (ADR-009 Known Limitation / BUG-140).
"""
from __future__ import annotations

import logging
import os
from datetime import date
from decimal import Decimal
from unittest.mock import MagicMock, patch

import pytest

from etl import get_wholesale_price as gwp_mod
from etl.get_wholesale_price import get_wholesale_price


class _FakeCursor:
    """Minimal cursor stub: returns pre-loaded rows in call order."""

    def __init__(self, rows):
        self._rows = list(rows)
        self._last = None

    def execute(self, *_args, **_kwargs):
        self._last = self._rows.pop(0) if self._rows else None

    def fetchone(self):
        return self._last

    def __enter__(self):
        return self

    def __exit__(self, *_):
        return False


class _FakeConn:
    def __init__(self, cursor):
        self._cursor = cursor

    def cursor(self):
        return self._cursor

    def __enter__(self):
        return self

    def __exit__(self, *_):
        return False


def _patch_connect(rows):
    cur = _FakeCursor(rows)
    conn = _FakeConn(cur)
    return patch.object(gwp_mod.psycopg2, "connect", return_value=conn)


@pytest.fixture(autouse=True)
def _env_db():
    os.environ["DATABASE_URL"] = "postgresql://localhost/test"
    yield
    os.environ.pop("DATABASE_URL", None)


def test_closed_period_returns_canonical_base_wholesale():
    # Rows in call order: (1) month_end_snapshot hit → closed=True,
    # (2) canonical_sku.base_wholesale=170.00, pack_size=NULL.
    with _patch_connect([(1,), (Decimal("170.00"), None)]):
        price = get_wholesale_price(sku_id=68, as_of_date=date(2025, 3, 15))
    assert price == Decimal("170.00")


def test_closed_period_missing_canonical_returns_none():
    with _patch_connect([(1,), None]):
        price = get_wholesale_price(sku_id=99999, as_of_date=date(2025, 3, 15))
    assert price is None


def test_open_period_returns_vinsight_price():
    # (1) month_end_snapshot miss → open, (2) Vinsight price row.
    with _patch_connect([None, (Decimal("185.50"),)]):
        price = get_wholesale_price(sku_id=68, as_of_date=date(2026, 4, 15))
    assert price == Decimal("185.50")


def test_open_period_missing_vinsight_returns_none():
    with _patch_connect([None, None]):
        price = get_wholesale_price(sku_id=68, as_of_date=date(2026, 4, 15))
    assert price is None


def test_pack_size_emits_warning_on_closed_period(caplog):
    # Closed period + canonical price + pack_size='375ml' → warning fires.
    with caplog.at_level(logging.WARNING, logger="moppity.etl.get_wholesale_price"):
        with _patch_connect([(1,), (Decimal("170.00"), "375ml")]):
            price = get_wholesale_price(sku_id=11678, as_of_date=date(2025, 3, 15))
    assert price == Decimal("170.00")
    assert any("pack_size=375ml" in rec.message and "BUG-140" in rec.message
               for rec in caplog.records), caplog.text


def test_pack_size_null_is_silent(caplog):
    with caplog.at_level(logging.WARNING, logger="moppity.etl.get_wholesale_price"):
        with _patch_connect([(1,), (Decimal("170.00"), None)]):
            get_wholesale_price(sku_id=68, as_of_date=date(2025, 3, 15))
    assert not any("BUG-140" in rec.message for rec in caplog.records)


def test_missing_database_url_raises():
    os.environ.pop("DATABASE_URL", None)
    with pytest.raises(RuntimeError, match="DATABASE_URL"):
        get_wholesale_price(sku_id=1, as_of_date=date(2025, 3, 15))
