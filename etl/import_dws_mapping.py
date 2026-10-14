#!/usr/bin/env python3
"""
Import confirmed DWS → Moppity code mappings into sku_code_map.

Reads a CSV file (reviewed by the owner) and inserts mappings.
Skips rows with empty moppity_code. Uses upsert to avoid duplicates.

Usage:
    python etl/import_dws_mapping.py etl/dws_mapping_confirmed.csv
"""

import csv
import os
import sys
import psycopg2

DATABASE_URL = os.environ.get(
    'DATABASE_URL',
    'postgresql://127.0.0.1:5432/moppity_db'
)


def main():
    if len(sys.argv) < 2:
        print('Usage: python etl/import_dws_mapping.py <confirmed_csv>')
        print('  CSV must have columns: dws_code, suggested_moppity_code')
        sys.exit(1)

    csv_path = sys.argv[1]
    if not os.path.exists(csv_path):
        print(f'File not found: {csv_path}')
        sys.exit(1)

    conn = psycopg2.connect(DATABASE_URL)
    cur = conn.cursor()

    # Read CSV
    with open(csv_path, 'r') as f:
        reader = csv.DictReader(f)
        rows = list(reader)

    # Look up sku_ids for DWS codes
    imported = 0
    skipped = 0
    errors = []

    for row in rows:
        dws_code = row.get('dws_code', '').strip()
        moppity_code = row.get('suggested_moppity_code', '').strip()

        if not dws_code or not moppity_code:
            skipped += 1
            continue

        # Find the DWS SKU's sku_id
        cur.execute('SELECT sku_id FROM sku WHERE sku_code = %s', (dws_code,))
        result = cur.fetchone()
        if not result:
            errors.append(f'DWS code not found in sku table: {dws_code}')
            continue

        dws_sku_id = result[0]

        # Upsert into sku_code_map (unique on source_system + external_code)
        cur.execute("""
            INSERT INTO sku_code_map (sku_id, source_system, external_code)
            VALUES (%s, 'DWS', %s)
            ON CONFLICT (source_system, external_code)
            DO UPDATE SET sku_id = EXCLUDED.sku_id
        """, (dws_sku_id, moppity_code))

        imported += 1

    conn.commit()
    conn.close()

    print(f'Import complete:')
    print(f'  Imported: {imported}')
    print(f'  Skipped (empty moppity code): {skipped}')
    if errors:
        print(f'  Errors: {len(errors)}')
        for e in errors[:10]:
            print(f'    - {e}')


if __name__ == '__main__':
    main()
