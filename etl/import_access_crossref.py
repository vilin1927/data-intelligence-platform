#!/usr/bin/env python3
"""
Import cross-channel SKU code mappings from Access DB crossref CSV.

Reads etl/access_db_code_crossref.csv (generated from the Access DB CombinedData
table) and inserts DWS/ALM/ILG code mappings into sku_code_map.

Strategy:
  1. For each CSV row, use the Vinsight codes to find the canonical sku_id
     (Vinsight codes are already well-mapped in sku_code_map or sku table)
  2. Once sku_id is found, insert all DWS/ALM/ILG codes for that SKU
  3. For rows without Vinsight codes, fuzzy-match sku_name to sku.item_description

Usage:
    DATABASE_URL=postgresql://... python etl/import_access_crossref.py [csv_path]
    # Defaults to etl/access_db_code_crossref.csv
"""

import csv
import os
import sys

import psycopg2

DATABASE_URL = os.environ.get(
    "DATABASE_URL",
    "postgresql://127.0.0.1:5432/moppity_db",
)

DEFAULT_CSV = os.path.join(os.path.dirname(__file__), "access_db_code_crossref.csv")


def find_sku_id_by_vinsight_codes(cur, vinsight_codes: list[str]) -> int | None:
    """Find sku_id using any of the Vinsight codes."""
    for code in vinsight_codes:
        code = code.strip()
        if not code:
            continue
        # Try sku_code_map (vinsight source)
        cur.execute(
            "SELECT sku_id FROM sku_code_map "
            "WHERE source_system = 'vinsight' AND LOWER(external_code) = LOWER(%s)",
            (code,),
        )
        row = cur.fetchone()
        if row:
            return row[0]
        # Try canonical sku table
        cur.execute(
            "SELECT sku_id FROM sku WHERE LOWER(sku_code) = LOWER(%s)",
            (code,),
        )
        row = cur.fetchone()
        if row:
            return row[0]
    return None


def find_sku_id_by_name(cur, sku_name: str) -> int | None:
    """Fuzzy-match Access DB SKU name to sku.item_description."""
    # Exact match first
    cur.execute(
        "SELECT sku_id FROM sku WHERE UPPER(item_description) = UPPER(%s) LIMIT 1",
        (sku_name,),
    )
    row = cur.fetchone()
    if row:
        return row[0]

    # Fuzzy: match on first 2-3 keywords
    words = [w for w in sku_name.upper().split() if len(w) > 2
             and w not in ("THE", "AND", "750ML", "375ML")]
    if len(words) >= 2:
        pattern = "%" + "%".join(words[:3]) + "%"
        cur.execute(
            "SELECT sku_id FROM sku WHERE UPPER(item_description) LIKE %s LIMIT 1",
            (pattern,),
        )
        row = cur.fetchone()
        if row:
            return row[0]

    return None


def upsert_mapping(cur, sku_id: int, source_system: str, external_code: str) -> bool:
    """Insert a mapping, skip if already exists."""
    cur.execute(
        """
        INSERT INTO sku_code_map (sku_id, source_system, external_code)
        VALUES (%s, %s, %s)
        ON CONFLICT (source_system, external_code) DO NOTHING
        """,
        (sku_id, source_system, external_code),
    )
    return cur.rowcount > 0


def main():
    csv_path = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_CSV
    if not os.path.exists(csv_path):
        print(f"File not found: {csv_path}", file=sys.stderr)
        sys.exit(1)

    conn = psycopg2.connect(DATABASE_URL)
    cur = conn.cursor()

    with open(csv_path, "r") as f:
        reader = csv.DictReader(f)
        rows = list(reader)

    stats = {
        "total_rows": len(rows),
        "sku_matched": 0,
        "sku_unmatched": 0,
        "dws_inserted": 0,
        "alm_inserted": 0,
        "ilg_inserted": 0,
        "dws_skipped": 0,
        "alm_skipped": 0,
        "ilg_skipped": 0,
    }
    unmatched = []

    for row in rows:
        sku_name = row["sku_name"].strip()
        vinsight_codes = [c for c in row.get("vinsight_codes", "").split("|") if c.strip()]
        dws_codes = [c for c in row.get("dws_codes", "").split("|") if c.strip()]
        alm_codes = [c for c in row.get("alm_codes", "").split("|") if c.strip()]
        ilg_codes = [c for c in row.get("ilg_codes", "").split("|") if c.strip()]

        # Skip if no DWS/ALM/ILG codes to import
        if not dws_codes and not alm_codes and not ilg_codes:
            continue

        # Find sku_id via Vinsight codes first, then by name
        sku_id = None
        if vinsight_codes:
            sku_id = find_sku_id_by_vinsight_codes(cur, vinsight_codes)
        if sku_id is None:
            sku_id = find_sku_id_by_name(cur, sku_name)

        if sku_id is None:
            stats["sku_unmatched"] += 1
            unmatched.append(sku_name)
            continue

        stats["sku_matched"] += 1

        # Insert DWS codes
        for code in dws_codes:
            if upsert_mapping(cur, sku_id, "dws", code.strip()):
                stats["dws_inserted"] += 1
            else:
                stats["dws_skipped"] += 1

        # Insert ALM codes
        for code in alm_codes:
            if upsert_mapping(cur, sku_id, "alm", code.strip()):
                stats["alm_inserted"] += 1
            else:
                stats["alm_skipped"] += 1

        # Insert ILG codes
        for code in ilg_codes:
            if upsert_mapping(cur, sku_id, "ilg", code.strip()):
                stats["ilg_inserted"] += 1
            else:
                stats["ilg_skipped"] += 1

    conn.commit()
    cur.close()
    conn.close()

    print("=== Access DB Crossref Import Complete ===")
    print(f"  CSV rows:      {stats['total_rows']}")
    print(f"  SKUs matched:  {stats['sku_matched']}")
    print(f"  SKUs unmatched:{stats['sku_unmatched']}")
    print(f"  DWS inserted:  {stats['dws_inserted']} (skipped {stats['dws_skipped']} existing)")
    print(f"  ALM inserted:  {stats['alm_inserted']} (skipped {stats['alm_skipped']} existing)")
    print(f"  ILG inserted:  {stats['ilg_inserted']} (skipped {stats['ilg_skipped']} existing)")
    total_inserted = stats["dws_inserted"] + stats["alm_inserted"] + stats["ilg_inserted"]
    print(f"  TOTAL NEW:     {total_inserted}")

    if unmatched:
        print(f"\nUnmatched SKU names ({len(unmatched)}):")
        for name in unmatched:
            print(f"  - {name}")


if __name__ == "__main__":
    main()
