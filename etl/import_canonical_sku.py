"""
F-01: Import 99 Canonical SKUs from the owner's reconciliation spreadsheet.

Reads the "SKU table" tab from the Database reconciliation xlsx and UPSERTs
into the canonical_sku table. Then auto-links existing sku rows to their
canonical counterpart via fuzzy matching on sku_group / item_description.

Usage:
    DATABASE_URL=postgresql://... python -m etl.import_canonical_sku
"""

import logging
import os
import sys
from decimal import Decimal, InvalidOperation

import openpyxl
import psycopg2

from etl.logger import log_etl_run

logger = logging.getLogger("moppity.etl.import_canonical_sku")

XLSX_PATH = os.path.join(
    os.path.dirname(os.path.dirname(__file__)),
    "reference", "owner-feedback-mar26", "Database reconciliation (1).xlsx",
)
SHEET_NAME = "SKU table"
SOURCE = "canonical_sku_import"


def _parse_decimal(value) -> Decimal | None:
    if value is None:
        return None
    if isinstance(value, (int, float)):
        return Decimal(str(value))
    text = str(value).strip().replace(",", "").replace("$", "")
    if not text:
        return None
    try:
        return Decimal(text)
    except InvalidOperation:
        return None


def _parse_int(value) -> int | None:
    if value is None:
        return None
    try:
        return int(float(value))
    except (ValueError, TypeError):
        return None


def read_sku_rows(xlsx_path: str) -> list[dict]:
    """Read SKU table tab and return list of dicts."""
    wb = openpyxl.load_workbook(xlsx_path, read_only=True, data_only=True)
    ws = wb[SHEET_NAME]
    rows = list(ws.iter_rows(values_only=True))
    wb.close()

    if len(rows) < 2:
        raise ValueError(f"SKU table has {len(rows)} rows — expected header + data.")

    # Header: ('ID', 'SKU', 'Range', 'RangeGroup', 'UnitsperCase', 'Cogs',
    #          'BaseWholesale', 'TransferCost', 'Note', 'Units')
    header = [str(h).strip().lower() if h else "" for h in rows[0]]

    # Build column index
    col_map = {}
    for idx, h in enumerate(header):
        col_map[h] = idx

    results = []
    for row in rows[1:]:
        sku_name = row[col_map.get("sku", 1)]
        if sku_name is None or str(sku_name).strip() == "":
            continue  # skip empty rows

        results.append({
            "sku_name": str(sku_name).strip(),
            "range_name": str(row[col_map.get("range", 2)]).strip() if row[col_map.get("range", 2)] else None,
            "range_group": str(row[col_map.get("rangegroup", 3)]).strip() if row[col_map.get("rangegroup", 3)] else None,
            "units_per_case": _parse_int(row[col_map.get("unitspercase", 4)]),
            "cogs": _parse_decimal(row[col_map.get("cogs", 5)]),
            "base_wholesale": _parse_decimal(row[col_map.get("basewholesale", 6)]),
            "transfer_cost": _parse_decimal(row[col_map.get("transfercost", 7)]),
        })

    return results


def upsert_canonical_skus(conn, sku_rows: list[dict]) -> dict:
    """UPSERT rows into canonical_sku. Returns stats dict."""
    inserted = 0
    updated = 0
    errors = []

    with conn.cursor() as cur:
        for row in sku_rows:
            try:
                cur.execute("""
                    INSERT INTO canonical_sku
                        (sku_name, range_name, range_group, units_per_case,
                         cogs, base_wholesale, transfer_cost, updated_at)
                    VALUES (%s, %s, %s, %s, %s, %s, %s, NOW())
                    ON CONFLICT (sku_name) DO UPDATE SET
                        range_name     = EXCLUDED.range_name,
                        range_group    = EXCLUDED.range_group,
                        units_per_case = EXCLUDED.units_per_case,
                        cogs           = EXCLUDED.cogs,
                        base_wholesale = EXCLUDED.base_wholesale,
                        transfer_cost  = EXCLUDED.transfer_cost,
                        updated_at     = NOW()
                    RETURNING (xmax = 0) AS is_insert
                """, (
                    row["sku_name"],
                    row["range_name"],
                    row["range_group"],
                    row["units_per_case"],
                    row["cogs"],
                    row["base_wholesale"],
                    row["transfer_cost"],
                ))
                is_insert = cur.fetchone()[0]
                if is_insert:
                    inserted += 1
                else:
                    updated += 1
            except Exception as exc:
                errors.append(f"SKU '{row['sku_name']}': {exc}")
                conn.rollback()

    conn.commit()
    return {"inserted": inserted, "updated": updated, "errors": errors}


def auto_link_skus(conn) -> dict:
    """
    Auto-link existing sku.canonical_sku_id by fuzzy matching.

    Strategy:
    1. Exact match: UPPER(sku.sku_group) = UPPER(canonical_sku.sku_name)
    2. Contained match: canonical_sku.sku_name is contained in sku.item_description (case-insensitive)
    3. Word-overlap match: all words from canonical_sku.sku_name appear in sku.item_description
    """
    matched = 0
    unmatched = 0

    with conn.cursor() as cur:
        # Step 1: Exact match on sku_group
        cur.execute("""
            UPDATE sku s
            SET canonical_sku_id = cs.id
            FROM canonical_sku cs
            WHERE s.canonical_sku_id IS NULL
              AND cs.is_active_canonical = true
              AND s.sku_group IS NOT NULL
              AND UPPER(TRIM(s.sku_group)) = UPPER(TRIM(cs.sku_name))
        """)
        step1 = cur.rowcount
        logger.info("Step 1 (exact sku_group match): linked %d SKUs", step1)

        # Step 2: Contained match — canonical name appears inside item_description
        cur.execute("""
            UPDATE sku s
            SET canonical_sku_id = cs.id
            FROM canonical_sku cs
            WHERE s.canonical_sku_id IS NULL
              AND cs.is_active_canonical = true
              AND s.item_description IS NOT NULL
              AND UPPER(s.item_description) LIKE '%%' || UPPER(TRIM(cs.sku_name)) || '%%'
        """)
        step2 = cur.rowcount
        logger.info("Step 2 (contained in item_description): linked %d SKUs", step2)

        # Step 3: Normalize and match — strip common prefixes like "Moppity", "Lock & Key" etc.
        # Match when the canonical name words are all present in item_description
        # This is done in Python for flexibility
        cur.execute("SELECT id, sku_name FROM canonical_sku WHERE is_active_canonical = true")
        canonical_rows = cur.fetchall()

        cur.execute("""
            SELECT sku_id, item_description, sku_group
            FROM sku
            WHERE canonical_sku_id IS NULL
              AND item_description IS NOT NULL
        """)
        unlinked = cur.fetchall()

        step3 = 0
        for sku_id, item_desc, sku_group in unlinked:
            desc_upper = item_desc.upper() if item_desc else ""
            group_upper = sku_group.upper() if sku_group else ""

            best_match = None
            best_word_count = 0

            for cs_id, cs_name in canonical_rows:
                cs_words = [w for w in cs_name.upper().split() if len(w) > 2]
                if not cs_words:
                    continue

                # Count how many canonical words appear in description or group
                matches_in_desc = sum(1 for w in cs_words if w in desc_upper)
                matches_in_group = sum(1 for w in cs_words if w in group_upper)
                best_hits = max(matches_in_desc, matches_in_group)

                # Require at least 2 matching words and > 60% coverage
                if best_hits >= 2 and best_hits / len(cs_words) > 0.6:
                    if best_hits > best_word_count:
                        best_word_count = best_hits
                        best_match = cs_id

            if best_match is not None:
                cur.execute(
                    "UPDATE sku SET canonical_sku_id = %s WHERE sku_id = %s AND canonical_sku_id IS NULL",
                    (best_match, sku_id),
                )
                step3 += cur.rowcount

        logger.info("Step 3 (word-overlap match): linked %d SKUs", step3)

        matched = step1 + step2 + step3

        # Count remaining unlinked
        cur.execute("SELECT COUNT(*) FROM sku WHERE canonical_sku_id IS NULL")
        unmatched = cur.fetchone()[0]

    conn.commit()
    return {"matched": matched, "unmatched": unmatched}


def main():
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    )

    db_url = os.environ.get("DATABASE_URL")
    if not db_url:
        print("ERROR: DATABASE_URL environment variable is not set.", file=sys.stderr)
        sys.exit(1)

    xlsx_path = XLSX_PATH
    if len(sys.argv) > 1:
        xlsx_path = sys.argv[1]

    if not os.path.isfile(xlsx_path):
        print(f"ERROR: File not found: {xlsx_path}", file=sys.stderr)
        sys.exit(1)

    conn = psycopg2.connect(db_url)

    try:
        # 1. Read xlsx
        print(f"\n{'='*60}")
        print("F-01: Import Canonical SKUs")
        print(f"{'='*60}")
        print(f"Source: {xlsx_path}")
        print(f"Sheet:  {SHEET_NAME}")

        sku_rows = read_sku_rows(xlsx_path)
        print(f"Read {len(sku_rows)} SKU rows from spreadsheet")

        # 2. UPSERT into canonical_sku
        stats = upsert_canonical_skus(conn, sku_rows)
        print(f"\nCanonical SKU UPSERT:")
        print(f"  Inserted: {stats['inserted']}")
        print(f"  Updated:  {stats['updated']}")
        if stats["errors"]:
            print(f"  Errors:   {len(stats['errors'])}")
            for err in stats["errors"][:10]:
                print(f"    - {err}")

        # 3. Auto-link existing sku rows
        print(f"\nAuto-linking existing sku rows to canonical_sku...")
        link_stats = auto_link_skus(conn)
        print(f"  Matched:   {link_stats['matched']}")
        print(f"  Unmatched: {link_stats['unmatched']}")

        # 4. Log ETL run
        total_processed = stats["inserted"] + stats["updated"]
        status = "success" if not stats["errors"] else "partial"
        log_etl_run(
            conn,
            source=SOURCE,
            endpoint=SHEET_NAME,
            status=status,
            rows_processed=total_processed,
            rows_skipped=0,
            error_count=len(stats["errors"]),
            error_detail="\n".join(stats["errors"][:50]) if stats["errors"] else None,
        )

        print(f"\n{'='*60}")
        print(f"DONE: {total_processed} canonical SKUs loaded, "
              f"{link_stats['matched']} existing SKUs linked.")
        print(f"{'='*60}\n")

    except Exception as exc:
        conn.rollback()
        print(f"FATAL: {exc}", file=sys.stderr)
        try:
            log_etl_run(
                conn, source=SOURCE, endpoint=SHEET_NAME,
                status="error", rows_processed=0, error_count=1,
                error_detail=str(exc),
            )
        except Exception:
            pass
        sys.exit(1)
    finally:
        conn.close()


if __name__ == "__main__":
    main()
