"""
Unit tests for etl/enforce_customer_access_precedence.py lookup loaders.

BUG-125 AC3 regression guard.

The connection in production uses psycopg2.extras.RealDictCursor, so cursor.fetchall()
returns a list of row-dicts, NOT tuples. The original loader impls iterated with
`for tid, name in cur.fetchall()` which unpacks each dict into its two KEY strings
('territory_id', 'territory_name'), collapsing every lookup map to size 1.

Fix (applied 2026-04-22 F.5 session): dict-key access via r['<col>_name'] / r['<col>_id'].

These tests simulate a RealDictCursor returning 3 rows and assert each loader
returns a dict with 3 distinct entries keyed by the lower-cased name.
"""
from __future__ import annotations

import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent.parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

import pytest  # noqa: E402

from etl.enforce_customer_access_precedence import (  # noqa: E402
    LookupMapEmptyError,
    load_channel_name_to_id,
    load_rep_name_to_id,
    load_territory_name_to_id,
)


class _FakeRealDictCursor:
    """Mock psycopg2.extras.RealDictCursor: fetchall() returns list[dict] instead of list[tuple].

    Matches the real cursor surface used by the loaders: execute() is a no-op stub,
    fetchall() returns the rows the test pre-loaded.
    """

    def __init__(self, rows: list[dict[str, Any]]):
        self._rows = rows
        self.last_sql: str | None = None

    def execute(self, sql: str, params: Any = None) -> None:
        self.last_sql = sql

    def fetchall(self) -> list[dict[str, Any]]:
        return list(self._rows)


# --------------------------------------------------------------------------- #
# load_territory_name_to_id                                                   #
# --------------------------------------------------------------------------- #
def test_load_territory_name_to_id_returns_three_entries():
    """BUG-125: with 3 RealDictCursor rows, map must have 3 entries (not 1)."""
    cur = _FakeRealDictCursor(
        [
            {"territory_id": 1, "territory_name": "NSW Sydney West"},
            {"territory_id": 2, "territory_name": "Queensland"},
            {"territory_id": 3, "territory_name": "Head Office"},
        ]
    )
    out = load_territory_name_to_id(cur)
    assert len(out) == 3
    assert out["nsw sydney west"] == 1
    assert out["queensland"] == 2
    assert out["head office"] == 3


def test_load_territory_name_to_id_skips_null_names():
    cur = _FakeRealDictCursor(
        [
            {"territory_id": 1, "territory_name": "NSW Sydney West"},
            {"territory_id": 2, "territory_name": None},
            {"territory_id": 3, "territory_name": "Head Office"},
        ]
    )
    out = load_territory_name_to_id(cur)
    assert len(out) == 2
    assert "nsw sydney west" in out
    assert "head office" in out


def test_load_territory_name_to_id_lowercases_and_strips():
    cur = _FakeRealDictCursor(
        [
            {"territory_id": 1, "territory_name": "  Queensland  "},
        ]
    )
    out = load_territory_name_to_id(cur)
    assert out == {"queensland": 1}


# --------------------------------------------------------------------------- #
# load_channel_name_to_id                                                     #
# --------------------------------------------------------------------------- #
def test_load_channel_name_to_id_returns_three_entries():
    """BUG-125: with 3 RealDictCursor rows, map must have 3 entries (not 1)."""
    cur = _FakeRealDictCursor(
        [
            {"channel_id": 1, "channel_name": "DWS"},
            {"channel_id": 2, "channel_name": "ALM"},
            {"channel_id": 3, "channel_name": "Direct"},
        ]
    )
    out = load_channel_name_to_id(cur)
    assert len(out) == 3
    assert out["dws"] == 1
    assert out["alm"] == 2
    assert out["direct"] == 3


# --------------------------------------------------------------------------- #
# load_rep_name_to_id                                                         #
# --------------------------------------------------------------------------- #
def test_load_rep_name_to_id_returns_three_entries():
    """BUG-125: with 3 RealDictCursor rows, map must have 3 entries (not 1)."""
    cur = _FakeRealDictCursor(
        [
            {"rep_id": 10, "rep_name": "Rep B"},
            {"rep_id": 20, "rep_name": "Sarah Jones"},
            {"rep_id": 30, "rep_name": "Customer 11"},
        ]
    )
    out = load_rep_name_to_id(cur)
    assert len(out) == 3
    assert out["rep b"] == 10
    assert out["sarah jones"] == 20
    assert out["customer 11"] == 30


def test_load_rep_name_to_id_tuple_unpack_regression_guard():
    """Negative control: if a future refactor reverts to `for tid, name in cur.fetchall()`
    against a dict cursor, the returned map would have size 1 (the two column-name keys
    collapsing to a single entry). This test confirms the loader rejects that failure mode
    with a size-3 input."""
    cur = _FakeRealDictCursor(
        [
            {"rep_id": 1, "rep_name": "Rep A"},
            {"rep_id": 2, "rep_name": "Rep B"},
            {"rep_id": 3, "rep_name": "Rep C"},
        ]
    )
    out = load_rep_name_to_id(cur)
    # If tuple-unpack bug recurred, len(out) would be 1 here.
    assert len(out) == 3, (
        "Loader collapsed to size 1 — tuple-unpack regression (BUG-125). "
        f"Got: {out!r}"
    )


# --------------------------------------------------------------------------- #
# BUG-141: empty-map RuntimeError hardening                                   #
# --------------------------------------------------------------------------- #
def test_load_territory_name_to_id_raises_on_empty_table():
    """BUG-141: empty cursor result must raise LookupMapEmptyError, not silently
    return {}. A zero-entry map would cause every reconcile_customer_row to drop
    its territory_id update — a no-op F.6 that looks like success in logs."""
    cur = _FakeRealDictCursor([])
    with pytest.raises(LookupMapEmptyError) as excinfo:
        load_territory_name_to_id(cur)
    assert excinfo.value.table == "territory"
    assert "territory" in str(excinfo.value)


def test_load_channel_name_to_id_raises_on_empty_table():
    cur = _FakeRealDictCursor([])
    with pytest.raises(LookupMapEmptyError) as excinfo:
        load_channel_name_to_id(cur)
    assert excinfo.value.table == "channel"


def test_load_rep_name_to_id_raises_on_empty_table():
    cur = _FakeRealDictCursor([])
    with pytest.raises(LookupMapEmptyError) as excinfo:
        load_rep_name_to_id(cur)
    assert excinfo.value.table == "representative"


def test_load_territory_name_to_id_raises_when_all_names_null():
    """Integration: rows present but every name is NULL → filtered away →
    map is empty → still raises (guards against a bad migration that nulled
    the name column)."""
    cur = _FakeRealDictCursor(
        [
            {"territory_id": 1, "territory_name": None},
            {"territory_id": 2, "territory_name": None},
        ]
    )
    with pytest.raises(LookupMapEmptyError):
        load_territory_name_to_id(cur)


def test_lookup_map_empty_error_is_runtimeerror_subclass():
    """Callers may catch RuntimeError; LookupMapEmptyError must be a subclass
    so the scope-prompt-level contract ('loaders raise RuntimeError on empty
    map') holds."""
    assert issubclass(LookupMapEmptyError, RuntimeError)


def test_loader_accepts_single_row_map():
    """Integration: one-row result is not 'empty' — shouldn't raise.
    Documents the precise contract: the guard fires at len(m) == 0, not
    len(m) < N."""
    cur = _FakeRealDictCursor(
        [{"territory_id": 1, "territory_name": "Single"}]
    )
    out = load_territory_name_to_id(cur)
    assert out == {"single": 1}
