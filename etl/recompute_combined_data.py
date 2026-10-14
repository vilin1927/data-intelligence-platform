"""
B8 — Combined Data per-period reconcile reporter.

Tickets
-------
JC-251/JC-325 — Combined Data Feb 2026 incomplete (85 vs ~692 expected).
JC-260       — DWS Feb 2026 ≈ 272 rows expected (sanity check Mar+Apr).
JC-254       — Mar 29 proof: 76 SKUs / penny reconcile to the owner's spreadsheet.

Read-only. Prints a per-period × source_system × warehouse breakdown of
  1. Confirm that the recent month's row counts match the owner's reconciliation
     spreadsheet AND the channel-specific source files (DWS xlsx, ALM EDI,
     access_combined_data, vinsight_sales_order_item).
  2. Spot the channel that's under-imported (e.g. DWS Mar 2026 = 1 row vs
     ~272 expected → triggers a B12 upload pipeline run for that file).
     work for diff comparison.

Does NOT mutate sales_transaction. The actual re-import is performed via the
B12 upload pipeline (etl/import_dws_zip.py / etl/import_alm_edi.py /
connectors/vinsight_full_sync.py) — this script is a reconcile lens, not an
ETL job.

Usage
-----
    # All months, JSON output for diffing:
    DATABASE_URL=postgresql://... \\
    python -m etl.recompute_combined_data --format json

    # Specific months only:
    python -m etl.recompute_combined_data \\
        --periods 2026-01 2026-02 2026-03 2026-04 \\
        --format table

    # Compare against an expectation file (the owner's spreadsheet exported as CSV
    # with columns: period,channel,expected_rows,expected_revenue):
    python -m etl.recompute_combined_data \\

Exit codes
----------
    0  ran successfully (regardless of any expectation gaps)
    1  one or more periods had a |diff| > tolerance vs expectations
    2  DB error
    3  input error
"""
from __future__ import annotations

import argparse
import csv
import json
import logging
import os
import sys
from collections import defaultdict
from decimal import Decimal
from pathlib import Path

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
log = logging.getLogger("recompute_combined_data")

# ── Toleance ────────────────────────────────────────────────────────────────
# The owner's reconciliation spreadsheet rounds to dollars; row counts are exact.
ROW_TOLERANCE = 5         # absolute row diff allowed before flagging
REVENUE_TOLERANCE = 100   # absolute dollar diff allowed (rounding noise)


def _parse_args(argv):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--periods", nargs="*", help="Periods YYYY-MM (default: all in DB)")
    p.add_argument("--format", choices=("table", "json"), default="table",
                   help="Output format (default: table)")
    p.add_argument("--expectations", help="CSV with columns: period,channel,expected_rows,expected_revenue")
    p.add_argument("--row-tolerance", type=int, default=ROW_TOLERANCE)
    p.add_argument("--revenue-tolerance", type=Decimal, default=Decimal(REVENUE_TOLERANCE))
    return p.parse_args(argv)


def _connect():
    try:
        import psycopg2
        import psycopg2.extras
    except ImportError:
        log.error("psycopg2 not installed; pip install -r requirements-dev.txt")
        sys.exit(3)
    dsn = os.environ.get("DATABASE_URL")
    if not dsn:
        log.error("DATABASE_URL env var required")
        sys.exit(3)
    return psycopg2.connect(dsn), psycopg2.extras


def _fetch_actuals(conn, periods):
    sql = """
        SELECT period,
               source_system,
               COALESCE(warehouse, '') AS warehouse,
               COUNT(*)::bigint AS rows,
               COALESCE(SUM(net_revenue), 0)::numeric AS revenue
          FROM sales_transaction
          {where}
         GROUP BY period, source_system, warehouse
         ORDER BY period DESC, source_system, warehouse
    """
    where = ""
    args = []
    if periods:
        where = "WHERE period = ANY(%s)"
        args = [periods]
    with conn.cursor() as cur:
        cur.execute(sql.format(where=where), args)
        return cur.fetchall()


def _read_expectations(path):
    p = Path(path)
    if not p.exists():
        log.error("Expectations CSV not found: %s", p)
        sys.exit(3)
    out = {}
    with p.open(newline="", encoding="utf-8") as fh:
        reader = csv.DictReader(fh)
        for row in reader:
            key = (row["period"].strip(), row["channel"].strip().upper())
            out[key] = {
                "rows": int(row["expected_rows"]),
                "revenue": Decimal(row["expected_revenue"]),
            }
    return out


def _print_table(rows, expectations, row_tol, rev_tol):
    by_period = defaultdict(list)
    for period, src, wh, n, rev in rows:
        by_period[period].append((src, wh, n, rev))

    over_threshold = False
    for period in sorted(by_period.keys(), reverse=True):
        print(f"\n=== {period} ===")
        period_total = 0
        period_revenue = Decimal(0)
        for src, wh, n, rev in by_period[period]:
            channel = wh.upper() or src.upper()
            exp = expectations.get((period, channel))
            if exp is None:
                gap = ""
            else:
                row_gap = n - exp["rows"]
                rev_gap = rev - exp["revenue"]
                flag_row = "!" if abs(row_gap) > row_tol else " "
                flag_rev = "!" if abs(rev_gap) > rev_tol else " "
                if flag_row == "!" or flag_rev == "!":
                    over_threshold = True
                gap = f" exp={exp['rows']:>5}/{exp['revenue']:>10}  Δ={row_gap:+d}{flag_row}/{rev_gap:+,.2f}{flag_rev}"
            print(f"  {src:<12s}  {wh:<10s}  rows={n:>5}  net=${rev:>12,.2f}{gap}")
            period_total += n
            period_revenue += rev
        print(f"  {'TOTAL':<12s}  {'':<10s}  rows={period_total:>5}  net=${period_revenue:>12,.2f}")
    return over_threshold


def main(argv=None):
    args = _parse_args(argv if argv is not None else sys.argv[1:])
    expectations = _read_expectations(args.expectations) if args.expectations else {}

    conn, _ = _connect()
    try:
        actuals = _fetch_actuals(conn, args.periods)
    finally:
        conn.close()

    if args.format == "json":
        payload = [
            dict(period=p, source_system=s, warehouse=w, rows=int(n), net_revenue=str(rev))
            for p, s, w, n, rev in actuals
        ]
        print(json.dumps(payload, indent=2))
        return 0

    over = _print_table(actuals, expectations, args.row_tolerance, args.revenue_tolerance)
    if over:
        log.warning("One or more periods exceeded tolerance vs expectations")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
