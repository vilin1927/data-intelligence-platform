"""
BUG-178 (2026-05-05) — unit test for the DISTINCT ON dedup in
etl/sync_vinsight_cogs.py:_transform_packaging_vessels().

Vinsight rotates `$id` for the same business wine_batch across snapshots
(e.g. batch_code='24SHIMOP04ESHI' has rows with $id=374 from Mar 15,
$id=977 from Apr 17, $id=978 from May 3). The R-009 patch (commit
db8b04e, 2026-04-30) added a `LEFT JOIN wine_batch ON batch_code` to
persist `wine_batch_id` per packaging_vessel. Because `wine_batch.batch_code`
is non-unique, the JOIN multiplied output rows; `SELECT DISTINCT` projected
`wb.id` so duplicate `(po_id, v_id)` keys survived into the INSERT batch
(conflict target is `(po_id, v_id)`, NOT `wb.id`). Result: CardinalityViolation
(SQLSTATE 21000) on May 4 cron. Apr 17–23 had 7 silent COGS failures before
anyone noticed.

The fix:
  1. SQL — replace `SELECT DISTINCT` with `SELECT DISTINCT ON (po.id, v.id)`
     plus `ORDER BY po.id, v.id, wb.synced_at DESC NULLS LAST, wb.id DESC
     NULLS LAST` (most-recent wine_batch wins; deterministic tie-break).
  2. Python — pre-INSERT cardinality monitor logs raw vs deduped counts;
     raises RuntimeError on >10x cardinality blowup so we get a named
     exception instead of a generic SQLSTATE 21000.

This test verifies four things WITHOUT touching a real database:

  1. The literal SQL fragments (`SELECT DISTINCT ON (po.id, v.id)`,
     `ORDER BY po.id, v.id, wb.synced_at DESC NULLS LAST, wb.id DESC NULLS LAST`)
     are present in the writer — codebase regression catch.
  2. The cardinality monitor query + RuntimeError tripwire are present in
     the writer — regression catch on the prevention pattern itself.
  3. End-to-end Python-side simulation of the DISTINCT ON dedup on a
     synthetic (po, v, wb, synced_at) tuple list: dups collapse, the
     most-recent wine_batch wins.
  4. The 10x-blowup tripwire fires when fed contrived input.

Mirrors the proven pattern from tests/test_vinsight_stock_items_filter.py
(literal-line check + pure-function mirror — no live DB).
"""

from __future__ import annotations

from datetime import datetime
from typing import Any

import pytest


# ─── 1. Literal-line presence in the writer (regression catch) ──────────

EXPECTED_DEDUP_FRAGMENTS = (
    # The DISTINCT ON clause must be present verbatim.
    "SELECT DISTINCT ON (po.id, v.id)",
    # The ORDER BY tie-breaker chain must be present verbatim — this is
    # the deterministic-winner contract: most-recent wb.synced_at wins,
    # wb.id is the fallback, NULLS LAST means LEFT JOIN misses lose to matches.
    "ORDER BY po.id, v.id, wb.synced_at DESC NULLS LAST, wb.id DESC NULLS LAST",
    # The conflict target must remain (po, v) — this is the structural
    # invariant the DISTINCT ON above protects.
    "ON CONFLICT (packaging_operation_id, vessel_id)",
)

EXPECTED_MONITOR_FRAGMENTS = (
    # Pre-INSERT cardinality probe must run before the INSERT.
    "[BUG-178 monitor] packaging_vessel JOIN cardinality:",
    # The named RuntimeError tripwire — surfaces a clear error instead
    # of a generic Postgres SQLSTATE 21000.
    "BUG-178 monitor: cardinality",
    "blowup detected",
    # The 10x threshold guards against runaway $id rotation or
    # Vinsight schema change.
    "raw_total > 10 * raw_distinct_keys",
)


def test_dedup_fragments_present_in_writer() -> None:
    """Codebase check — the BUG-178 dedup wiring must exist verbatim in
    the writer. Catches a future refactor that strips DISTINCT ON or
    breaks the deterministic ORDER BY chain.
    """
    with open("etl/sync_vinsight_cogs.py", "r", encoding="utf-8") as fh:
        src = fh.read()
    for needle in EXPECTED_DEDUP_FRAGMENTS:
        assert needle in src, f"BUG-178 dedup wiring missing: {needle!r}"


def test_monitor_fragments_present_in_writer() -> None:
    """Codebase check — the BUG-178 cardinality monitor + RuntimeError
    tripwire must exist verbatim. Catches a future refactor that drops
    the prevention pattern and reverts to silent SQLSTATE 21000 failures.
    """
    with open("etl/sync_vinsight_cogs.py", "r", encoding="utf-8") as fh:
        src = fh.read()
    for needle in EXPECTED_MONITOR_FRAGMENTS:
        assert needle in src, f"BUG-178 monitor wiring missing: {needle!r}"


# ─── 2. Python-side mirror of the DISTINCT ON dedup ─────────────────────

# Synthetic (po_id, v_id, wb_id, wb_synced_at) tuples mirroring the JOIN
# OperationNum=636, VesselCode=017, BatchCode=24SHIMOP04ESHI matched 3
# wine_batch rows (synced Mar 15, Apr 17, May 3).
SYNTHETIC_JOIN_OUTPUT: list[dict[str, Any]] = [
    # Collision case 1: same (po, v) key, 3 wine_batch matches with
    # different synced_at — most-recent (May 3) must win.
    {"po_id": 30, "v_id": 167, "wb_id": 374,  "wb_synced_at": datetime(2026, 3, 15, 15, 2)},
    {"po_id": 30, "v_id": 167, "wb_id": 797,  "wb_synced_at": datetime(2026, 4, 17, 15, 44)},
    {"po_id": 30, "v_id": 167, "wb_id": 7520, "wb_synced_at": datetime(2026, 5, 3, 20, 0)},
    # Collision case 2: same (po, v) key, 2 wine_batch matches.
    {"po_id": 5, "v_id": 154, "wb_id": 100, "wb_synced_at": datetime(2026, 4, 1, 12, 0)},
    {"po_id": 5, "v_id": 154, "wb_id": 200, "wb_synced_at": datetime(2026, 4, 30, 12, 0)},
    # Clean case: no dup, single wine_batch match.
    {"po_id": 99, "v_id": 1, "wb_id": 50, "wb_synced_at": datetime(2026, 3, 1, 0, 0)},
    # LEFT JOIN miss case: no wine_batch match (wb_id NULL, synced_at NULL).
    {"po_id": 100, "v_id": 2, "wb_id": None, "wb_synced_at": None},
    # NULLS LAST case: same (po, v), one match, one miss — match must win.
    {"po_id": 101, "v_id": 3, "wb_id": 60, "wb_synced_at": datetime(2026, 1, 1, 0, 0)},
    {"po_id": 101, "v_id": 3, "wb_id": None, "wb_synced_at": None},
]


def _mirror_distinct_on_dedup(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Pure-Python mirror of the SQL `DISTINCT ON (po.id, v.id) ... ORDER BY
    po.id, v.id, wb.synced_at DESC NULLS LAST, wb.id DESC NULLS LAST` clause.

    Postgres semantics:
      - Group rows by (po_id, v_id).
      - Within each group, sort by (wb_synced_at DESC, wb_id DESC) with
        NULLs at the END (NULLS LAST in DESC means smallest, i.e. last).
      - Pick the first row of each group.

    Returns one row per (po_id, v_id) — the deterministic winner.
    """
    groups: dict[tuple[int, int], list[dict[str, Any]]] = {}
    for row in rows:
        key = (row["po_id"], row["v_id"])
        groups.setdefault(key, []).append(row)

    def sort_key(r: dict[str, Any]) -> tuple[int, datetime, int, int]:
        # NULLS LAST in DESC means we want non-NULL values FIRST.
        # We achieve this by giving NULLs a sort tag of 1 (loses to 0).
        synced_at = r["wb_synced_at"]
        wb_id = r["wb_id"]
        synced_at_null_tag = 1 if synced_at is None else 0
        wb_id_null_tag = 1 if wb_id is None else 0
        # Within non-NULL: DESC means we negate. For datetime, we use
        # negative timestamp; for int, we negate.
        synced_at_sort = -(synced_at.timestamp()) if synced_at is not None else 0
        wb_id_sort = -(wb_id) if wb_id is not None else 0
        return (synced_at_null_tag, synced_at_sort, wb_id_null_tag, wb_id_sort)

    winners = []
    for key in sorted(groups.keys()):
        group = groups[key]
        group.sort(key=sort_key)
        winners.append(group[0])
    return winners


def test_dedup_collapses_multi_wine_batch_collisions() -> None:
    """Two collision cases (3-way and 2-way) must each collapse to a
    single row. Also one clean case + one LEFT JOIN miss + one
    NULLS-LAST case = 5 distinct (po, v) keys total.
    """
    deduped = _mirror_distinct_on_dedup(SYNTHETIC_JOIN_OUTPUT)
    assert len(deduped) == 5, (
        f"DISTINCT ON dedup failed: expected 5 rows for 5 distinct "
        f"(po_id, v_id) keys, got {len(deduped)}: {deduped!r}"
    )


def test_dedup_picks_most_recent_wine_batch() -> None:
    """For batch_code='24SHIMOP04ESHI' (po_id=30, v_id=167), the May 3
    wine_batch (id=7520, synced_at=2026-05-03) must win over Apr 17
    (id=797) and Mar 15 (id=374). This is the "as-of-packaging" intent
    the R-009 ticket meant to capture.
    """
    deduped = _mirror_distinct_on_dedup(SYNTHETIC_JOIN_OUTPUT)
    by_key = {(r["po_id"], r["v_id"]): r for r in deduped}
    winner = by_key[(30, 167)]
    assert winner["wb_id"] == 7520, (
        f"DISTINCT ON tie-break failed: expected wb_id=7520 (May 3 row, "
        f"most recent synced_at), got wb_id={winner['wb_id']}"
    )


def test_dedup_picks_apr30_over_apr1() -> None:
    """For (po_id=5, v_id=154), the Apr 30 wine_batch (id=200) must win
    over Apr 1 (id=100). Confirms ORDER BY synced_at DESC works for
    smaller groups.
    """
    deduped = _mirror_distinct_on_dedup(SYNTHETIC_JOIN_OUTPUT)
    by_key = {(r["po_id"], r["v_id"]): r for r in deduped}
    winner = by_key[(5, 154)]
    assert winner["wb_id"] == 200


def test_dedup_left_join_miss_preserved() -> None:
    """LEFT JOIN miss (no wine_batch) is a valid output row when no
    other wine_batch matches that (po, v). The output is a single
    row with wb_id=NULL.
    """
    deduped = _mirror_distinct_on_dedup(SYNTHETIC_JOIN_OUTPUT)
    by_key = {(r["po_id"], r["v_id"]): r for r in deduped}
    miss = by_key[(100, 2)]
    assert miss["wb_id"] is None
    assert miss["wb_synced_at"] is None


def test_dedup_nulls_last_match_wins_over_miss() -> None:
    """For (po_id=101, v_id=3), a wine_batch match (wb_id=60, synced_at
    Jan 1) must win over the LEFT JOIN miss (wb_id=NULL). NULLS LAST in
    DESC means non-NULL beats NULL.
    """
    deduped = _mirror_distinct_on_dedup(SYNTHETIC_JOIN_OUTPUT)
    by_key = {(r["po_id"], r["v_id"]): r for r in deduped}
    winner = by_key[(101, 3)]
    assert winner["wb_id"] == 60, (
        "NULLS LAST violated: LEFT JOIN miss should never win over a "
        "real wine_batch match."
    )


def test_dedup_clean_case_unchanged() -> None:
    """Single (po, v) with one wine_batch match — should pass through
    unchanged."""
    deduped = _mirror_distinct_on_dedup(SYNTHETIC_JOIN_OUTPUT)
    by_key = {(r["po_id"], r["v_id"]): r for r in deduped}
    clean = by_key[(99, 1)]
    assert clean["wb_id"] == 50


# ─── 3. Cardinality blowup tripwire ─────────────────────────────────────

def _mirror_blowup_check(raw_total: int, raw_distinct_keys: int) -> bool:
    """Mirror of the Python-side guard:

        if raw_distinct_keys > 0 and raw_total > 10 * raw_distinct_keys:
            raise RuntimeError(...)

    Returns True if the guard would raise.
    """
    return raw_distinct_keys > 0 and raw_total > 10 * raw_distinct_keys


def test_blowup_tripwire_does_not_fire_on_today_data() -> None:
    """Today's prod data: 1972 raw rows / 1251 distinct keys = 1.58x.
    Guard must NOT fire on this — it's normal post-R-009 cardinality.
    """
    assert _mirror_blowup_check(raw_total=1972, raw_distinct_keys=1251) is False


def test_blowup_tripwire_does_not_fire_on_clean_data() -> None:
    """Pre-R-009 baseline: 1251 raw rows / 1251 distinct keys = 1x.
    Guard must NOT fire on this either."""
    assert _mirror_blowup_check(raw_total=1251, raw_distinct_keys=1251) is False


def test_blowup_tripwire_fires_on_10x_explosion() -> None:
    """If somehow the JOIN produces 12,510 rows for 1251 distinct keys
    (10x explosion), the guard must fire — that's the runaway-cardinality
    sentinel. Real-world trigger would be Vinsight rotating $id 10x more
    aggressively or a schema change creating cartesian fan-out.
    """
    assert _mirror_blowup_check(raw_total=12511, raw_distinct_keys=1251) is True


def test_blowup_tripwire_does_not_fire_on_zero_rows() -> None:
    """Empty staging table — guard must not divide-by-zero or fire."""
    assert _mirror_blowup_check(raw_total=0, raw_distinct_keys=0) is False


def test_blowup_tripwire_at_exact_10x_does_not_fire() -> None:
    """Guard uses strict greater-than (>), so exactly 10x must NOT fire.
    This is the boundary contract — only true blowups trigger.
    """
    assert _mirror_blowup_check(raw_total=12510, raw_distinct_keys=1251) is False


if __name__ == "__main__":
    # Allows running the file directly without pytest for quick local checks.
    import sys
    fns = [v for v in globals().values()
           if callable(v) and getattr(v, "__name__", "").startswith("test_")
           and not getattr(v, "pytestmark", None)]
    failed = []
    for fn in fns:
        try:
            fn()
            print(f"ok {fn.__name__}")
        except AssertionError as exc:
            failed.append((fn.__name__, exc))
            print(f"FAIL {fn.__name__}: {exc}")
    if failed:
        sys.exit(1)
    print("ALL OK")
