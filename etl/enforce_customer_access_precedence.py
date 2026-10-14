"""
Phase F.4 DRAFT — Customer Access-precedence enforcement.

Tickets: BUG-94 (Customer→Channel), BUG-99 (Customer→Territory),
BUG-111 (suburb/postcode).

Purpose
-------
Flip customer master so Access canonical wins where our DB is NULL, while
NEVER overwriting a non-NULL Vinsight-sourced value (the owner Mar 24 rule —
re-confirmed with the owner at F.0 pre-auth before wet-run).

Reconciliation columns: territory, channel, suburb, postcode, rep.
SKIPPED: customer_group (Phase F.3 classified taxonomy MESSY — deferred to

Status
------
DRAFT — not yet dry-run-tested against prod. Do NOT run via cron or CI.
Intended sequence:
    F.5 = dry-run on prod, Vladimir reviews expected-vs-actual counts
    F.6 = wet-run after the owner pre-auth + snapshot + git tag

Usage
-----
    DATABASE_URL=postgresql://... \\
    python -m etl.enforce_customer_access_precedence \\
        --dry-run          # default TRUE; must pass --commit explicitly to mutate

Exit codes
----------
    0  success (dry-run or committed)
    1  guard-threshold violation (abort before mutating)
    2  DB error (transaction rolled back)
    3  input error (missing CSV, bad args)
"""
from __future__ import annotations

import argparse
import csv
import logging
import os
import sys
from collections import defaultdict
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Optional

import psycopg2
import psycopg2.extras

from etl.lib.address_freshness import FreshnessDecision, reconcile_column

logger = logging.getLogger("moppity.etl.enforce_customer_access_precedence")

# Columns reconciled in F.4. customer_group excluded per F.3 defer (BUG-116).
# channel excluded per BUG-127 (canonical.channel=venue-type ∉ channel table=sales-channel).
RECONCILED_COLUMNS = ("territory", "suburb", "postcode", "rep")

# If actual counts exceed these, something is wrong — abort before mutating.
GUARD_MAX_FILL_CANDIDATES = 20_250
# F.5 dry-run 2026-04-22 observed 2,968 conflicts (mostly territory 1,832 + rep
# 3,500 with 15% headroom above that observation. If a wet-run ever exceeds
# this, something has changed and we want to stop and look.
GUARD_MAX_TRUE_CONFLICTS = 3_500
GUARD_MAX_LINKED_UNIVERSE = 7_000  # scout: 6,809


# --------------------------------------------------------------------------- #
# Data classes                                                                #
# --------------------------------------------------------------------------- #
@dataclass
class RunStats:
    """Per-column action counters and conflict record accumulator."""
    per_column: dict[str, dict[str, int]] = field(
        default_factory=lambda: {
            col: defaultdict(int) for col in RECONCILED_COLUMNS
        }
    )
    conflict_records: list[dict] = field(default_factory=list)
    customers_considered: int = 0
    customers_updated: int = 0
    customers_no_access_match: int = 0

    def bump(self, column: str, action: str) -> None:
        self.per_column[column][action] += 1

    def summary_lines(self) -> list[str]:
        lines = [
            f"customers_considered:      {self.customers_considered}",
            f"customers_updated:         {self.customers_updated}",
            f"customers_no_access_match: {self.customers_no_access_match}",
            f"conflicts_logged:          {len(self.conflict_records)}",
            "",
            "per-column action counts:",
        ]
        for col in RECONCILED_COLUMNS:
            counts = self.per_column[col]
            lines.append(
                f"  {col:<10} filled={counts.get('filled', 0):>6}  "
                f"skipped_null_source={counts.get('skipped_null_source', 0):>6}  "
                f"match={counts.get('match', 0):>6}  "
                f"skipped_conflict={counts.get('skipped_conflict', 0):>6}  "
                f"both_null={counts.get('both_null', 0):>6}"
            )
        return lines


# --------------------------------------------------------------------------- #
# Access CSV loading                                                          #
# --------------------------------------------------------------------------- #
def load_access_customers(csv_path: Path) -> list[dict[str, str]]:
    """Load active (IsDelete=0) rows from the Access Customers CSV export."""
    if not csv_path.exists():
        raise FileNotFoundError(f"Access CSV not found: {csv_path}")
    active = []
    with csv_path.open(newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            if row.get("IsDelete") == "0":
                active.append(row)
    logger.info("Loaded %d active Access rows from %s", len(active), csv_path)
    return active


def build_access_lookup(access_rows: list[dict]) -> dict[str, dict]:
    """Build a multi-key lookup: canonical_customer join-candidates keyed by
    normalized join key. F.4 resolves canonical→Access via:
      - alm_customer_code / dir_customer_code / ynr_customer_code (primary)
      - "<xCustomerName> @ <Suburb>" composite (fallback)
    """
    by_key: dict[str, dict] = {}
    for row in access_rows:
        for code_col in ("ALMCustomerCode", "DIRCustomerCode", "YNRCustomerCode"):
            code = (row.get(code_col) or "").strip()
            if code:
                by_key[f"{code_col.lower()}:{code}"] = row
        name = (row.get("xCustomerName") or "").strip()
        suburb = (row.get("Suburb") or "").strip()
        if name:
            composite = f"{name} @ {suburb}" if suburb else name
            by_key[f"composite:{composite}"] = row
    logger.info("Built Access lookup with %d keys", len(by_key))
    return by_key


def _clean_postcode(raw: Optional[str]) -> Optional[str]:
    """BUG-126: Australian postcodes are exactly 4 digits. Treat anything else
    (empty, 'Not applicable' sentinels, letters, wrong length) as NULL so we
    never try to write it into customer.postcode VARCHAR(10).
    """
    if raw is None:
        return None
    v = raw.strip()
    if len(v) == 4 and v.isdigit():
        return v
    return None


def _clean_rep(raw: Optional[str]) -> Optional[str]:
    """BUG-129: F.1 CSV sentinel audit found 3 Access customer rows (CustomerIDs
    11208, 13737, 14867) with Rep='NONE' as a human-entered 'no rep assigned'
    sentinel. Treat 'NONE' / 'UNKNOWN' (case-insensitive) and empty strings as
    NULL so they never land in canonical_customer.rep_name where downstream
    joins cannot resolve them. 'UNKNOWN' is a defensive guard — not observed
    in the current CSV but cheap to add.
    """
    if raw is None:
        return None
    v = raw.strip()
    if not v:
        return None
    if v.upper() in ("NONE", "UNKNOWN"):
        return None
    return v


def resolve_access_row(canonical: dict, access_lookup: dict) -> Optional[dict]:
    """Resolve an Access row for a canonical_customer via multi-key match."""
    for code_field, access_key in (
        ("alm_customer_code", "almcustomercode"),
        ("dir_customer_code", "dircustomercode"),
        ("ynr_customer_code", "ynrcustomercode"),
    ):
        code = (canonical.get(code_field) or "").strip()
        if code:
            hit = access_lookup.get(f"{access_key}:{code}")
            if hit:
                return hit
    # Composite fallback — canonical_customer.customer_name is already "<name> @ <suburb>"
    composite = (canonical.get("customer_name") or "").strip()
    if composite:
        return access_lookup.get(f"composite:{composite}")
    return None


# --------------------------------------------------------------------------- #
# Column-level reconciliation                                                 #
# --------------------------------------------------------------------------- #
def reconcile_customer_row(
    *,
    customer_id: int,
    current: dict,
    access: dict,
    territory_name_to_id: dict,
    channel_name_to_id: dict,
    rep_name_to_id: dict,
    stats: RunStats,
) -> dict[str, Any]:
    """Run per-column freshness reconciliation, return field→new_value map for UPDATE.
    Only columns whose action is 'filled' contribute to the returned update map.
    """
    updates: dict[str, Any] = {}

    # --- Territory (customer.territory_id ← Access.Territory via name lookup) ---
    access_territory_name = (access.get("Territory") or "").strip() or None
    current_territory_name = (current.get("territory_name") or "").strip() or None
    d = reconcile_column(
        customer_id=str(customer_id),
        column="territory",
        db_value=current_territory_name,
        access_value=access_territory_name,
    )
    stats.bump("territory", d.action)
    if d.conflict:
        stats.conflict_records.append(d.conflict)
    if d.action == "filled" and d.new_value:
        new_id = territory_name_to_id.get(d.new_value.strip().lower())
        if new_id:
            updates["territory_id"] = new_id
        else:
            # Target territory doesn't exist in our territory table yet.
            # TERR-01 flag — territory naming alignment prereq.
            stats.bump("territory", "target_missing_in_territory_table")

    # --- Channel SKIPPED pending BUG-127 resolution (venue-type vs sales-channel mismatch) ---
    # Kept as a gated block so re-enabling requires only flipping the constant
    # back to include "channel" after Vladimir+the owner pick schema option b/c.
    if "channel" in RECONCILED_COLUMNS:
        access_channel_name = (access.get("Channel") or "").strip() or None
        current_channel_name = (current.get("channel_name") or "").strip() or None
        d = reconcile_column(
            customer_id=str(customer_id),
            column="channel",
            db_value=current_channel_name,
            access_value=access_channel_name,
        )
        stats.bump("channel", d.action)
        if d.conflict:
            stats.conflict_records.append(d.conflict)
        if d.action == "filled" and d.new_value:
            new_id = channel_name_to_id.get(d.new_value.strip().lower())
            if new_id:
                updates["channel_id"] = new_id
            else:
                stats.bump("channel", "target_missing_in_channel_table")

    # --- Suburb (direct string column on customer) ---
    d = reconcile_column(
        customer_id=str(customer_id),
        column="suburb",
        db_value=(current.get("suburb") or None),
        access_value=(access.get("Suburb") or None),
    )
    stats.bump("suburb", d.action)
    if d.conflict:
        stats.conflict_records.append(d.conflict)
    if d.action == "filled":
        updates["suburb"] = d.new_value

    # --- Postcode --- BUG-126: coerce non-4-digit Access values (e.g. "Not applicable") to None.
    d = reconcile_column(
        customer_id=str(customer_id),
        column="postcode",
        db_value=(current.get("postcode") or None),
        access_value=_clean_postcode(access.get("Postcode")),
    )
    stats.bump("postcode", d.action)
    if d.conflict:
        stats.conflict_records.append(d.conflict)
    if d.action == "filled":
        updates["postcode"] = d.new_value

    # --- Rep (customer.rep_id ← Access.Rep via name lookup) ---
    # BUG-129: coerce 'NONE'/'UNKNOWN'/empty sentinels to None so they never
    # land in rep_name where downstream joins can't resolve them.
    access_rep_name = _clean_rep(access.get("Rep"))
    current_rep_name = (current.get("rep_name") or "").strip() or None
    d = reconcile_column(
        customer_id=str(customer_id),
        column="rep",
        db_value=current_rep_name,
        access_value=access_rep_name,
    )
    stats.bump("rep", d.action)
    if d.conflict:
        stats.conflict_records.append(d.conflict)
    if d.action == "filled" and d.new_value:
        new_id = rep_name_to_id.get(d.new_value.strip().lower())
        if new_id:
            updates["rep_id"] = new_id
        else:
            stats.bump("rep", "target_missing_in_rep_table")

    return updates


def apply_update(cur, customer_id: int, updates: dict[str, Any]) -> None:
    """Issue a parameterised UPDATE on customer. Called inside an open transaction."""
    if not updates:
        return
    set_clauses = ", ".join(f"{col} = %s" for col in updates.keys())
    params = list(updates.values()) + [customer_id]
    sql = (
        f"UPDATE customer SET {set_clauses}, updated_at = now() "
        f"WHERE customer_id = %s"
    )
    cur.execute(sql, params)


# --------------------------------------------------------------------------- #
# Lookup helpers                                                              #
# --------------------------------------------------------------------------- #
# BUG-125: connection uses RealDictCursor, so rows are dicts. Iterating `for tid, name in rows`
# would unpack each dict's two keys (the column-name strings) instead of values.
# BUG-141: loaders raise RuntimeError on empty map. An empty lookup map means
# every downstream .get(name) returns None and every customer UPDATE silently
# drops its territory_id / channel_id / rep_id assignment — a no-op F.6 run
# that looks successful in logs (`skipped=N, filled=0`) but accomplishes
# nothing. Prod row counts (territory >= 30, channel = 3, representative >= 70)
# make an empty map a hard signal that the table is unexpectedly empty or the
# cursor factory regressed. Surface it at load time, not in post-run diffs.
class LookupMapEmptyError(RuntimeError):
    """Raised when a lookup loader returns a zero-entry map.

    Carries the source table name for fast diagnosis.
    """

    def __init__(self, table: str) -> None:
        super().__init__(
            f"Lookup map for {table!r} is empty — refusing to run "
            "reconciliation with a degenerate map (BUG-141). Check the "
            "table row count, the cursor factory (RealDictCursor required), "
            "and the loader column names."
        )
        self.table = table


def _ensure_non_empty(m: dict[str, int], table: str) -> dict[str, int]:
    if not m:
        raise LookupMapEmptyError(table)
    return m


def load_territory_name_to_id(cur) -> dict[str, int]:
    cur.execute("SELECT territory_id, territory_name FROM territory")
    m = {
        r["territory_name"].strip().lower(): r["territory_id"]
        for r in cur.fetchall()
        if r["territory_name"]
    }
    return _ensure_non_empty(m, "territory")


def load_channel_name_to_id(cur) -> dict[str, int]:
    cur.execute("SELECT channel_id, channel_name FROM channel")
    m = {
        r["channel_name"].strip().lower(): r["channel_id"]
        for r in cur.fetchall()
        if r["channel_name"]
    }
    return _ensure_non_empty(m, "channel")


def load_rep_name_to_id(cur) -> dict[str, int]:
    cur.execute("SELECT rep_id, rep_name FROM representative")
    m = {
        r["rep_name"].strip().lower(): r["rep_id"]
        for r in cur.fetchall()
        if r["rep_name"]
    }
    return _ensure_non_empty(m, "representative")


def load_linked_customers(cur) -> list[dict]:
    """Fetch the 6,809-row linked universe with joined current-name columns for
    the freshness helper's db_value side.
    """
    cur.execute(
        """
        SELECT
            c.customer_id,
            c.canonical_customer_id,
            c.suburb,
            c.postcode,
            t.territory_name,
            ch.channel_name,
            r.rep_name,
            cc.customer_name       AS canonical_customer_name,
            cc.alm_customer_code,
            cc.dir_customer_code,
            cc.ynr_customer_code
        FROM customer c
        JOIN canonical_customer cc ON c.canonical_customer_id = cc.id
        LEFT JOIN territory t ON c.territory_id = t.territory_id
        LEFT JOIN channel ch ON c.channel_id = ch.channel_id
        LEFT JOIN representative r ON c.rep_id = r.rep_id
        ORDER BY c.customer_id
        """
    )
    return [dict(row) for row in cur.fetchall()]


# --------------------------------------------------------------------------- #
# Conflict log                                                                #
# --------------------------------------------------------------------------- #
def write_conflict_log(path: Path, records: list[dict]) -> None:
    if not records:
        logger.info("No conflicts to log.")
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="") as f:
        writer = csv.DictWriter(
            f, fieldnames=["customer_id", "column", "db_value", "access_value"]
        )
        writer.writeheader()
        writer.writerows(records)
    logger.info("Wrote %d conflict records → %s", len(records), path)


# --------------------------------------------------------------------------- #
# Guards                                                                      #
# --------------------------------------------------------------------------- #
def guard_pre_mutation(
    stats: RunStats, linked_universe: int
) -> tuple[bool, list[str]]:
    """Pre-commit sanity check — refuse to mutate if counts look wrong."""
    errors: list[str] = []
    if linked_universe > GUARD_MAX_LINKED_UNIVERSE:
        errors.append(
            f"linked universe {linked_universe} exceeds guard "
            f"{GUARD_MAX_LINKED_UNIVERSE} (F.1 scout recorded 6,809)"
        )
    total_fills = sum(
        c.get("filled", 0) for c in stats.per_column.values()
    )
    if total_fills > GUARD_MAX_FILL_CANDIDATES:
        errors.append(
            f"total fills {total_fills} exceeds guard "
            f"{GUARD_MAX_FILL_CANDIDATES}"
        )
    total_conflicts = len(stats.conflict_records)
    if total_conflicts > GUARD_MAX_TRUE_CONFLICTS:
        errors.append(
            f"total conflicts {total_conflicts} exceeds guard "
            f"{GUARD_MAX_TRUE_CONFLICTS}"
        )
    return (not errors, errors)


# --------------------------------------------------------------------------- #
# Main                                                                        #
# --------------------------------------------------------------------------- #
def parse_args() -> argparse.Namespace:
    default_access = (
        Path(__file__).resolve().parent.parent
        / "audit"
        / "phase-f-access-customers-2026-04-22.csv"
    )
    default_conflicts = (
        Path(__file__).resolve().parent.parent
        / "audit"
        / "customer-address-conflicts-2026-04-22.csv"
    )
    p = argparse.ArgumentParser(description=__doc__.strip().splitlines()[0])
    p.add_argument("--access-csv", type=Path, default=default_access)
    p.add_argument("--conflict-log-out", type=Path, default=default_conflicts)
    # --dry-run is default TRUE — must pass --commit explicitly to mutate.
    group = p.add_mutually_exclusive_group()
    group.add_argument(
        "--dry-run",
        dest="dry_run",
        action="store_true",
        default=True,
        help="SELECTs + counters only, ROLLBACK at end (default)",
    )
    group.add_argument(
        "--commit",
        dest="dry_run",
        action="store_false",
        help="COMMIT the transaction. Requires explicit opt-in.",
    )
    return p.parse_args()


def main() -> int:
    logging.basicConfig(
        level=os.environ.get("LOG_LEVEL", "INFO"),
        format="%(asctime)s %(name)s %(levelname)s %(message)s",
    )
    args = parse_args()

    db_url = os.environ.get("DATABASE_URL")
    if not db_url:
        logger.error("DATABASE_URL env var required")
        return 3

    try:
        access_rows = load_access_customers(args.access_csv)
    except FileNotFoundError as exc:
        logger.error("%s", exc)
        return 3

    access_lookup = build_access_lookup(access_rows)

    conn = psycopg2.connect(db_url)
    conn.autocommit = False  # single-transaction wrapper
    try:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            territory_name_to_id = load_territory_name_to_id(cur)
            channel_name_to_id = load_channel_name_to_id(cur)
            rep_name_to_id = load_rep_name_to_id(cur)
            linked = load_linked_customers(cur)
            logger.info(
                "Loaded %d linked customers; territory_map=%d, channel_map=%d, rep_map=%d",
                len(linked),
                len(territory_name_to_id),
                len(channel_name_to_id),
                len(rep_name_to_id),
            )

            stats = RunStats()
            stats.customers_considered = len(linked)

            for cust in linked:
                access = resolve_access_row(
                    canonical={
                        "customer_name": cust["canonical_customer_name"],
                        "alm_customer_code": cust.get("alm_customer_code"),
                        "dir_customer_code": cust.get("dir_customer_code"),
                        "ynr_customer_code": cust.get("ynr_customer_code"),
                    },
                    access_lookup=access_lookup,
                )
                if access is None:
                    stats.customers_no_access_match += 1
                    continue

                updates = reconcile_customer_row(
                    customer_id=cust["customer_id"],
                    current=cust,
                    access=access,
                    territory_name_to_id=territory_name_to_id,
                    channel_name_to_id=channel_name_to_id,
                    rep_name_to_id=rep_name_to_id,
                    stats=stats,
                )
                if updates:
                    apply_update(cur, cust["customer_id"], updates)
                    stats.customers_updated += 1

            # Always emit the summary + conflict log so a guard abort still
            # leaves diagnostic artifacts for the next run.
            write_conflict_log(args.conflict_log_out, stats.conflict_records)
            for line in stats.summary_lines():
                logger.info(line)

            # Pre-commit guard check
            ok, errors = guard_pre_mutation(stats, len(linked))
            if not ok:
                logger.error("Guard threshold violation — aborting:")
                for e in errors:
                    logger.error("  %s", e)
                conn.rollback()
                return 1

            if args.dry_run:
                logger.info("DRY-RUN: rolling back (no changes persisted)")
                conn.rollback()
            else:
                logger.info("COMMIT: persisting %d customer updates", stats.customers_updated)
                conn.commit()
    except psycopg2.Error as exc:
        conn.rollback()
        logger.exception("DB error — transaction rolled back: %s", exc)
        return 2
    finally:
        conn.close()

    return 0


if __name__ == "__main__":
    sys.exit(main())
