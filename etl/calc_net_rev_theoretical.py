"""
B8 — Theoretical revenue check + per-row net_rev reconcile.

Tickets
-------
JC-241 — Net rev (post rebate/discount/fees) + theoretical.
JC-253 — Revenue match the owner's spreadsheet to penny.
JC-252/JC-316 — Y&R $0 transactions reconcile to 234.51 cases.

What this script does
---------------------
1. (Default, read-only) Reports per-row deltas where:
       theoretical = qty × canonical_sku.base_wholesale
       actual_net  = sales_transaction.net_revenue
   It flags rows where |theoretical - actual_net| / theoretical > tolerance
   so the owner's reconciliation spreadsheet has a single place to look for
   pricing drift, missed discounts, or stuck NULL gross_revenue.

2. (--commit mode) Backfills `gross_revenue` on rows where it is NULL but
   the row has a valid (qty × base_wholesale) theoretical price.

3. Y&R $0 sanity: filters rows where source_system='vinsight' AND
   net_revenue=0, and prints case totals so the 234.51-case figure (the owner)
   can be cross-checked.

Usage
-----
    # Read-only dry-run (default):
    DATABASE_URL=postgresql://... \\
    python -m etl.calc_net_rev_theoretical \\
        --period 2026-02 --tolerance 0.05

    # Commit gross_revenue backfill (rows where gross_revenue IS NULL):
    DATABASE_URL=postgresql://... \\
    python -m etl.calc_net_rev_theoretical \\
        --period 2026-02 --commit-backfill

    # Y&R $0 reconcile:
    DATABASE_URL=postgresql://... \\
    python -m etl.calc_net_rev_theoretical --ynr-zero

Exit codes
----------
    0  ran cleanly (no commit needed or commit succeeded)
    1  rows exceeded tolerance — check is_active flag
    2  DB error
    3  input error
"""
from __future__ import annotations

import argparse
import logging
import os
import sys
from decimal import Decimal

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
log = logging.getLogger("calc_net_rev_theoretical")

DEFAULT_TOLERANCE = Decimal("0.05")  # 5% drift before flagging


def _parse_args(argv):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--period", help="Filter to a single period YYYY-MM")
    p.add_argument("--tolerance", type=Decimal, default=DEFAULT_TOLERANCE,
                   help="Relative tolerance before flagging (default 0.05 = 5%%)")
    p.add_argument("--ynr-zero", action="store_true",
                   help="Print Y&R / Vinsight $0 rows for 234.51-case reconcile")
    p.add_argument("--commit-backfill", action="store_true",
                   help="Backfill NULL gross_revenue from base_wholesale × qty in a transaction")
    p.add_argument("--limit", type=int, default=50, help="Max flagged rows to print (default 50)")
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
    return psycopg2.connect(dsn)


def _report_drift(conn, period, tolerance, limit):
    sql = """
        SELECT st.transaction_id,
               st.period,
               st.source_system,
               COALESCE(st.warehouse,'') AS warehouse,
               st.quantity,
               cs.sku_name,
               cs.base_wholesale,
               COALESCE(st.gross_revenue, 0)::numeric  AS actual_gross,
               COALESCE(st.net_revenue, 0)::numeric    AS actual_net,
               (st.quantity * COALESCE(cs.base_wholesale, 0))::numeric AS theoretical
          FROM sales_transaction st
          LEFT JOIN sku s         ON s.sku_id = st.sku_id
          LEFT JOIN canonical_sku cs ON cs.id = s.canonical_sku_id
         WHERE cs.base_wholesale IS NOT NULL
           AND cs.base_wholesale > 0
           AND st.quantity > 0
           {period_filter}
    """
    args = []
    period_filter = ""
    if period:
        period_filter = "AND st.period = %s"
        args.append(period)
    with conn.cursor() as cur:
        cur.execute(sql.format(period_filter=period_filter), args)
        rows = cur.fetchall()

    flagged = []
    total = len(rows)
    for tx_id, p, src, wh, qty, sku_name, bw, actual_gross, actual_net, theoretical in rows:
        if theoretical == 0:
            continue
        drift = abs(actual_net - theoretical) / theoretical
        if drift > tolerance:
            flagged.append((tx_id, p, src, wh, qty, sku_name, bw, actual_net, theoretical, drift))

    print(f"Scanned {total} rows{f' for period={period}' if period else ''}, tolerance={tolerance}")
    print(f"Flagged {len(flagged)} rows with |actual - theoretical| / theoretical > {tolerance}")
    print()
    print(f"{'tx_id':>8} {'period':<8} {'src':<10} {'wh':<6} {'qty':>6} {'sku':<35} {'BW':>8} {'actual':>10} {'theory':>10} {'drift':>6}")
    for tx_id, p, src, wh, qty, sku_name, bw, actual_net, theoretical, drift in flagged[:limit]:
        sku_short = (sku_name or "")[:35]
        print(f"{tx_id:>8} {p:<8} {src:<10} {wh:<6} {qty:>6} {sku_short:<35} {bw:>8.2f} {actual_net:>10.2f} {theoretical:>10.2f} {drift:>6.1%}")
    if len(flagged) > limit:
        print(f"... ({len(flagged) - limit} more)")
    return len(flagged)


def _ynr_zero_reconcile(conn, period):
    sql = """
        SELECT period,
               COUNT(*)::int AS rows,
               COALESCE(SUM(quantity), 0)::numeric AS total_cases,
               COALESCE(SUM(net_revenue), 0)::numeric AS total_net
          FROM sales_transaction
         WHERE source_system = 'vinsight'
           AND COALESCE(net_revenue, 0) = 0
           {period_filter}
         GROUP BY period
         ORDER BY period
    """
    period_filter = ""
    args = []
    if period:
        period_filter = "AND period = %s"
        args.append(period)
    with conn.cursor() as cur:
        cur.execute(sql.format(period_filter=period_filter), args)
        rows = cur.fetchall()
    print("Y&R / Vinsight $0 reconcile (JC-252/JC-316 — the owner: 234.51 cases)")
    print(f"{'period':<8} {'rows':>6} {'cases':>10} {'net':>10}")
    grand_cases = Decimal(0)
    for p, n, cases, net in rows:
        print(f"{p:<8} {n:>6} {cases:>10.2f} {net:>10.2f}")
        grand_cases += cases
    print(f"{'TOTAL':<8} {'':<6} {grand_cases:>10.2f}")
    return grand_cases


def _commit_backfill(conn, period):
    """Backfill NULL gross_revenue from theoretical (qty × base_wholesale).

    Wrapped in BEGIN/COMMIT — partial run is rolled back automatically by
    psycopg2's context manager on any exception.
    """
    sql = """
        UPDATE sales_transaction st
           SET gross_revenue = (st.quantity * cs.base_wholesale)::numeric(12,2)
          FROM sku s
          JOIN canonical_sku cs ON cs.id = s.canonical_sku_id
         WHERE st.gross_revenue IS NULL
           AND st.sku_id = s.sku_id
           AND cs.base_wholesale IS NOT NULL
           AND cs.base_wholesale > 0
           AND st.quantity > 0
           {period_filter}
        RETURNING st.transaction_id
    """
    period_filter = ""
    args = []
    if period:
        period_filter = "AND st.period = %s"
        args.append(period)
    with conn:  # BEGIN/COMMIT context
        with conn.cursor() as cur:
            cur.execute(sql.format(period_filter=period_filter), args)
            updated = cur.rowcount
    log.info("Backfilled gross_revenue on %d sales_transaction rows.", updated)
    return updated


def main(argv=None):
    args = _parse_args(argv if argv is not None else sys.argv[1:])
    conn = _connect()
    try:
        if args.ynr_zero:
            _ynr_zero_reconcile(conn, args.period)
            return 0
        if args.commit_backfill:
            _commit_backfill(conn, args.period)
            return 0
        flagged = _report_drift(conn, args.period, args.tolerance, args.limit)
        return 1 if flagged > 0 else 0
    finally:
        conn.close()


if __name__ == "__main__":
    sys.exit(main())
