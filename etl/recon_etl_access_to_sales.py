#!/usr/bin/env python3
"""
RECON-04: Re-derive sales_transaction from access_combined_data.

Reads raw JSONB from access_combined_data, matches SKU + customer + territory,
and inserts correct rows into sales_transaction.

Key fixes vs old ETL:
  1. gross_revenue = WholesaleValueExEx (line total, NOT qty * price)
  2. unit_price = WholesaleValueExEx / qty (per-unit)
  3. wholesale_fee = 0 (was monthly bulk total $N)
  4. Case-insensitive SKU/territory matching
  5. source_ref = Access ID (dedup key)

BUG-105 (2026-04-24): added content_hash SQL-side computation + ON CONFLICT
(content_hash) DO NOTHING so a re-run is idempotent against the 119,124 rows
already in sales_transaction. Hash formula matches schema/049 Option D exactly.
Expected effect of re-run today: recover the 1,219 rows previously dead-lettered
as sku_not_found on the 2026-03-29 run (Phases B1/C1/F/R grew canonical_sku).
"""

import os
import sys
import json
import psycopg2
from psycopg2.extras import execute_values
from datetime import datetime

DB_URL = os.environ.get("DATABASE_URL", "postgresql://127.0.0.1:5432/moppity_db")

BATCH_SIZE = 1000


def parse_numeric(val, default=0.0):
    """Safely parse a numeric value from JSONB string."""
    if val is None or val == '' or val == 'None':
        return default
    try:
        return float(val)
    except (ValueError, TypeError):
        return default


def parse_date(val):
    """Parse transaction date from Access format (MM/DD/YY HH:MM:SS)."""
    if not val:
        return None
    try:
        # Access format: "07/24/19 00:00:00"
        dt = datetime.strptime(val.split(' ')[0], '%m/%d/%y')
        return dt.date()
    except (ValueError, IndexError):
        try:
            # Try ISO format
            return datetime.strptime(val[:10], '%Y-%m-%d').date()
        except ValueError:
            return None


# R-001: warehouse rename map for Access CombinedData. Validated against
# 117,124 already-populated rows with ZERO exceptions on prod 2026-04-30.
# Returns None for unmapped raw values so the row inserts with warehouse=NULL
# (caller can dead-letter or accept; today's universe has no unmapped values).
_WAREHOUSE_RENAME_MAP = {
    "Y & R":   "DWS",
    "ALM":     "ALM",
    "Direct":  "Direct",
    "ILG":     "ILG",
    "Y&R-ALM": "Y&R-ALM",
}


def _warehouse_canonical(raw_w):
    if raw_w is None:
        return None
    return _WAREHOUSE_RENAME_MAP.get(raw_w.strip(), None)


_INSERT_SQL = """
    INSERT INTO sales_transaction
    (sku_id, customer_id, rep_id, territory_id, channel_id,
     sale_date, period, quantity, unit_price, discount_amount,
     rebate_amount, wholesale_fee, net_revenue, source_system,
     source_ref, warehouse, gross_revenue, stock_unit, content_hash)
    VALUES %s
    ON CONFLICT (content_hash) DO NOTHING
"""

# BUG-105: SQL-side content_hash compute. Mirrors schema/049_part1 backfill
# formula exactly (identity fields only, Option D). Explicit type casts
# (%s::int / %s::date / %s::numeric(12,2)) guarantee textification matches
# the stored hash basis regardless of psycopg2 parameter-type hints.
# BUG-118 AC2 follow-up: stock_unit is column #17 (between gross_revenue and
# content_hash). access_combined_data is case-quantity (CARTONS column = case
# count), so the value is hardcoded to 'case'. stock_unit is a derived
# attribute, NOT part of the content_hash basis (BUG-113 Option D rule:
# identity ≠ derived).
_INSERT_TEMPLATE = """(
    %s, %s, %s, %s, %s,
    %s, %s, %s, %s, %s,
    %s, %s, %s, %s, %s, %s, %s, %s,
    encode(sha256((
        coalesce(%s, '')                    || '|' ||
        coalesce(%s, '')                    || '|' ||
        coalesce((%s::int)::text, '')       || '|' ||
        coalesce((%s::int)::text, '')       || '|' ||
        (%s::date)::text                    || '|' ||
        (%s::numeric(12,2))::text
    )::bytea), 'hex')
)"""


def _flush_batch(insert_cur, batch):
    execute_values(insert_cur, _INSERT_SQL, batch, template=_INSERT_TEMPLATE)


def build_lookups(conn):
    """Build in-memory lookup dicts for matching."""
    cur = conn.cursor()

    # SKU lookup: UPPER(sku_name from canonical_sku) -> sku_id (pick first match from sku table)
    # We need: raw SKU name -> canonical_sku_id -> any sku row with that canonical_sku_id
    cur.execute("""
        SELECT cs.id as canonical_id, UPPER(cs.sku_name) as sku_upper,
               (SELECT s.sku_id FROM sku s WHERE s.canonical_sku_id = cs.id ORDER BY s.sku_id LIMIT 1) as sku_id
        FROM canonical_sku cs
    """)
    sku_lookup = {}
    for canonical_id, sku_upper, sku_id in cur.fetchall():
        sku_lookup[sku_upper] = {"canonical_id": canonical_id, "sku_id": sku_id}
    print(f"  SKU lookup: {len(sku_lookup)} canonical SKUs")

    # Customer lookup: UPPER(customer_name) -> customer_id, territory_id, channel_id
    cur.execute("""
        SELECT customer_id, UPPER(customer_name) as name_upper, territory_id, channel_id
        FROM customer
    """)
    customer_lookup = {}
    for cid, name_upper, tid, chid in cur.fetchall():
        customer_lookup[name_upper] = {"customer_id": cid, "territory_id": tid, "channel_id": chid}
    print(f"  Customer lookup: {len(customer_lookup)} customers")

    # Territory lookup: UPPER(territory_name) -> territory_id
    cur.execute("SELECT territory_id, UPPER(territory_name) FROM territory")
    territory_lookup = {upper: tid for tid, upper in cur.fetchall()}
    print(f"  Territory lookup: {len(territory_lookup)} territories")

    # Channel lookup: UPPER(channel_name) -> channel_id
    cur.execute("SELECT channel_id, UPPER(channel_name) FROM channel")
    channel_lookup = {upper: cid for cid, upper in cur.fetchall()}
    print(f"  Channel lookup: {len(channel_lookup)} channels")

    cur.close()
    return sku_lookup, customer_lookup, territory_lookup, channel_lookup


def run_etl():
    conn = psycopg2.connect(DB_URL)
    conn.autocommit = False

    print(f"[{datetime.now()}] RECON-04 ETL starting...")
    print(f"  Database: {DB_URL.split('@')[1] if '@' in DB_URL else DB_URL}")

    # Build lookups
    print("\nBuilding lookups...")
    sku_lookup, customer_lookup, territory_lookup, channel_lookup = build_lookups(conn)

    # BUG-105: capture pre-state sales_transaction[access_db] count so the
    # post-run delta reflects actual inserts (ON CONFLICT DO NOTHING makes the
    # per-row "attempted" counter overstate reality on a re-run).
    pre_cur = conn.cursor()
    pre_cur.execute("SELECT count(*) FROM sales_transaction WHERE source_system='access_db'")
    pre_count = pre_cur.fetchone()[0]
    pre_cur.close()
    print(f"  Pre-run sales_transaction[access_db] = {pre_count:,}")

    # Read all access_combined_data
    cur = conn.cursor("etl_cursor")
    cur.itersize = BATCH_SIZE
    cur.execute("SELECT id, raw_data FROM access_combined_data ORDER BY id")

    insert_cur = conn.cursor()
    dead_letter_cur = conn.cursor()

    stats = {
        "total": 0,
        "inserted": 0,
        "sku_miss": 0,
        "customer_miss": 0,
        "date_miss": 0,
        "errors": 0,
        "pre_count": pre_count,
    }
    dead_letters = []
    batch = []
    seen_refs = set()

    print("\nProcessing rows...")

    for row_id, raw_data in cur:
        stats["total"] += 1

        if stats["total"] % 10000 == 0:
            print(f"  ... {stats['total']} rows processed, {stats['inserted']} inserted")

        try:
            d = raw_data if isinstance(raw_data, dict) else json.loads(raw_data)

            access_id = str(d.get("ID", ""))
            if not access_id:
                access_id = f"acd-{row_id}"

            # Dedup check
            if access_id in seen_refs:
                stats["errors"] += 1
                continue
            seen_refs.add(access_id)

            # Parse fields
            sku_name = (d.get("SKU") or "").strip()
            customer_name = (d.get("CustomerName") or "").strip()
            territory_raw = (d.get("Territory") or "").strip()
            channel_raw = (d.get("Channel") or "").strip()
            cal_month = (d.get("CalMonth") or "").strip()
            txn_date_str = d.get("TransactionDate", "")

            qty = parse_numeric(d.get("QuantitySupplied(Dozens)"))
            wholesale_ex = parse_numeric(d.get("WholesaleValueExEx"))
            discount = parse_numeric(d.get("Discount"))
            rebate = parse_numeric(d.get("Rebate"))

            # Parse date
            sale_date = parse_date(txn_date_str)
            if not sale_date and cal_month:
                # Fallback: use first of month from CalMonth
                try:
                    parts = cal_month.split()  # "2025 10 OCT"
                    year = int(parts[0])
                    month = int(parts[1])
                    sale_date = datetime(year, month, 1).date()
                except (ValueError, IndexError):
                    pass

            if not sale_date:
                stats["date_miss"] += 1
                dead_letters.append((row_id, "access_db", access_id, "no_valid_date",
                                     f"TransactionDate={txn_date_str}, CalMonth={cal_month}"))
                continue

            # Period from CalMonth or sale_date
            if cal_month and len(cal_month) >= 7:
                period = cal_month[:7]  # "2025 10" -> "2025-10"
                period = period[:4] + "-" + period[5:7]
            else:
                period = sale_date.strftime("%Y-%m")

            # SKU matching (case-insensitive)
            sku_upper = sku_name.upper()
            sku_match = sku_lookup.get(sku_upper)
            if not sku_match or not sku_match["sku_id"]:
                stats["sku_miss"] += 1
                dead_letters.append((row_id, "access_db", access_id, "sku_not_found",
                                     f"SKU={sku_name}"))
                continue

            sku_id = sku_match["sku_id"]

            # Customer matching (case-insensitive)
            cust_upper = customer_name.upper()
            cust_match = customer_lookup.get(cust_upper)
            if not cust_match:
                stats["customer_miss"] += 1
                dead_letters.append((row_id, "access_db", access_id, "customer_not_found",
                                     f"CustomerName={customer_name}"))
                continue

            customer_id = cust_match["customer_id"]
            territory_id = cust_match["territory_id"]
            channel_id = cust_match["channel_id"]

            # If customer has no territory, try raw territory field
            if not territory_id and territory_raw:
                territory_id = territory_lookup.get(territory_raw.upper())

            # If customer has no channel, try raw channel field
            if not channel_id and channel_raw:
                channel_id = channel_lookup.get(channel_raw.upper())

            # R-001: warehouse from raw_data CombinedData.Warehouse via rename map
            warehouse = _warehouse_canonical((d.get("Warehouse") or "").strip())

            # Revenue calculations — THE KEY FIX
            gross_revenue = wholesale_ex  # Line total, NOT qty * price
            unit_price = (wholesale_ex / qty) if qty and qty != 0 else 0.0
            wholesale_fee = 0.0  # NOT the $N monthly bulk total
            net_revenue = gross_revenue - discount - rebate - wholesale_fee

            # BUG-105: tuple carries 18 insert values + 6 duplicates fed into
            # the SQL-side content_hash compute (source_system, source_ref,
            # sku_id, customer_id, sale_date, quantity). Hash formula matches
            # schema/049 Option D exactly — identity-only, no revenue fields.
            # BUG-118 AC2 follow-up: stock_unit='case' for access_db (the source
            # access_combined_data CARTONS column is case-count by definition).
            # R-001: warehouse is column 16 (between source_ref and gross_revenue),
            # NOT in the hash basis (classifier, not identity).
            batch.append((
                sku_id,
                customer_id,
                None,  # rep_id — not matching reps in Stage 1
                territory_id,
                channel_id,
                sale_date,
                period,
                round(qty, 2),
                round(unit_price, 2),
                round(discount, 2),
                round(rebate, 2),
                round(wholesale_fee, 2),
                round(net_revenue, 2),
                "access_db",
                access_id,
                warehouse,  # R-001: column 16
                round(gross_revenue, 2),
                "case",  # stock_unit (BUG-118 AC2; access source is case-quantity)
                # --- content_hash basis (mirror of schema/049 backfill) ---
                "access_db",
                access_id,
                sku_id,
                customer_id,
                sale_date,
                round(qty, 2),
            ))

            stats["inserted"] += 1

            # Flush batch
            if len(batch) >= BATCH_SIZE:
                _flush_batch(insert_cur, batch)
                batch = []

        except Exception as e:
            stats["errors"] += 1
            dead_letters.append((row_id, "access_db", str(d.get("ID", "")), "exception",
                                 str(e)[:500]))
            if stats["errors"] > 1000:
                print(f"\n!!! Too many errors ({stats['errors']}), aborting!")
                conn.rollback()
                sys.exit(1)

    # Flush remaining batch
    if batch:
        _flush_batch(insert_cur, batch)

    # Write dead letters
    if dead_letters:
        execute_values(dead_letter_cur, """
            INSERT INTO etl_dead_letter (source, error_message, raw_data)
            VALUES %s
        """, [(src, f"{status}: {detail}", json.dumps({"access_id": ref, "acd_row_id": rid}))
              for rid, src, ref, status, detail in dead_letters])

    # BUG-105: capture real post-state delta (ON CONFLICT DO NOTHING makes
    # stats["inserted"] an ATTEMPT count, not an actual-inserted count).
    insert_cur.execute("SELECT count(*) FROM sales_transaction WHERE source_system='access_db'")
    post_count = insert_cur.fetchone()[0]
    stats["post_count"] = post_count
    stats["actual_insert_delta"] = post_count - stats["pre_count"]

    # Log ETL run
    insert_cur.execute("""
        INSERT INTO etl_run_log (source, endpoint, status, rows_processed, rows_skipped, error_count, started_at, completed_at)
        VALUES ('transform', 'recon-04-access-to-sales', 'success', %s, %s, %s, %s, %s)
    """, (stats["actual_insert_delta"], stats["sku_miss"] + stats["customer_miss"] + stats["date_miss"],
          stats["errors"], datetime.now(), datetime.now()))

    # BUG-105 fix: close the named server-side cursor BEFORE commit. A commit
    # invalidates named cursors in psycopg2, so closing after commit raises
    # ProgrammingError("named cursor isn't valid anymore"). The data is
    # unaffected (commit completed), but the error masks success. Safe-order
    # is: close all cursors first, then commit.
    cur.close()
    insert_cur.close()
    dead_letter_cur.close()
    conn.commit()

    print(f"\n{'='*50}")
    print(f"RECON-04 ETL COMPLETE")
    print(f"{'='*50}")
    print(f"  Total staging rows read:   {stats['total']:,}")
    print(f"  Attempted inserts:         {stats['inserted']:,}  (before ON CONFLICT)")
    print(f"  Pre-run sales_transaction: {stats['pre_count']:,}")
    print(f"  Post-run sales_transaction:{stats['post_count']:,}")
    print(f"  Actual insert delta:       {stats['actual_insert_delta']:,}  (new rows landed)")
    print(f"  SKU misses:                {stats['sku_miss']:,}")
    print(f"  Customer misses:           {stats['customer_miss']:,}")
    print(f"  Date misses:               {stats['date_miss']:,}")
    print(f"  Errors:                    {stats['errors']:,}")
    print(f"  Dead letters (this run):   {len(dead_letters):,}")
    print(f"{'='*50}")

    conn.close()
    return stats


if __name__ == "__main__":
    stats = run_etl()
    # Exit with error if too many failures
    fail_rate = (stats["sku_miss"] + stats["customer_miss"] + stats["date_miss"]) / max(stats["total"], 1)
    if fail_rate > 0.05:
        print(f"\n!!! FAIL RATE {fail_rate:.1%} > 5% threshold. Review dead letters!")
        sys.exit(1)
