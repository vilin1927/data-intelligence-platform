#!/usr/bin/env python3
"""
Generate DWS → Moppity code mapping suggestions.

Connects to the database, finds DWS-format codes that need mapping,
and auto-matches them to Moppity codes by brand line + variety + vintage.

Output: CSV file for the owner to review before importing.

Usage:
    python etl/generate_dws_mapping.py
    # Outputs: etl/dws_mapping_suggestions.csv
"""

import csv
import os
import re
import sys
import psycopg2

DATABASE_URL = os.environ.get(
    'DATABASE_URL',
    'postgresql://127.0.0.1:5432/moppity_db'
)

# ─── Brand line extraction ────────────────────────────────────────────────
# Maps keywords in wine names to a normalized brand line
BRAND_PATTERNS = [
    (r'LOCK\s*&?\s*KEY|L&K|L\+K', 'lock_key'),
    (r'TWELVE\s+SIGNS|12\s+SIGNS', 'twelve_signs'),
    (r'COPPABELLA|COPABELLA', 'coppabella'),
    (r'ATRIUS', 'atrius'),
    (r'ESCALIER', 'escalier'),
    (r'RESERVE', 'reserve'),
    (r'CRAFTED', 'crafted'),
    (r'BLOCK\s*M4', 'block_m4'),
    (r'BLOCK\s*A5', 'block_a5'),
    (r'TRISTIS', 'tristis'),
    (r'PROCELLA', 'procella'),
    (r'SIRIUS', 'sirius'),
    (r'OPERA', 'opera'),
    (r'LOTUS', 'lotus'),
    (r'ESTATE|EST\b', 'estate'),
]

# DWS code prefix → brand line
DWS_CODE_BRANDS = {
    'MOLK': 'lock_key',
    'MOT': 'twelve_signs',
    'MOCV': 'coppabella',
    'MOCS': 'coppabella',
    'MOAT': 'atrius',
    'MOES': 'escalier',
    'MORS': 'reserve',
    'MOSH': 'block_m4',    # MOSHM4 = Block M4
    'MOSHA': 'block_a5',   # MOSHA5 = Block A5
    'MOTR': 'tristis',
}


def extract_brand(name: str, sku_code: str = '') -> str:
    """Extract normalized brand line from wine name or SKU code."""
    upper = name.upper()
    for pattern, brand in BRAND_PATTERNS:
        if re.search(pattern, upper):
            return brand

    # Try DWS code prefix
    for prefix, brand in DWS_CODE_BRANDS.items():
        if sku_code.upper().startswith(prefix):
            return brand

    return 'unknown'


def normalize_variety(variety: str | None) -> str:
    """Normalize variety names for matching."""
    if not variety:
        return ''
    v = variety.lower().strip()
    # Common normalizations
    v = re.sub(r'ros[eé]', 'rose', v)
    v = re.sub(r'shiraz\s+grenache.*', 'gsm', v)
    return v


def main():
    conn = psycopg2.connect(DATABASE_URL)
    cur = conn.cursor()

    # 1. Get all DWS-format codes needing mapping (ending in F, short codes)
    cur.execute("""
        SELECT s.sku_id, s.sku_code, s.item_description, s.variety, s.vintage,
               SUM(st.net_revenue)::numeric(12,2) as total_revenue
        FROM sales_transaction st
        JOIN sku s ON s.sku_id = st.sku_id
        JOIN channel c ON c.channel_id = st.channel_id AND c.channel_name = 'DWS'
        WHERE (s.sku_code ~ '^MO[A-Z]' AND s.sku_code ~ 'F$' AND length(s.sku_code) <= 12)
           OR s.sku_code ~ '^[0-9]'
        GROUP BY s.sku_id, s.sku_code, s.item_description, s.variety, s.vintage
        ORDER BY SUM(st.net_revenue) DESC
    """)
    dws_skus = cur.fetchall()

    # 2. Get all Moppity-format codes (potential match targets)
    cur.execute("""
        SELECT s.sku_id, s.sku_code, s.item_description, s.variety, s.vintage
        FROM sku s
        WHERE s.sku_code ~ '^[A-Z]'
          AND s.sku_code NOT LIKE 'MO%'
          AND s.variety IS NOT NULL
        ORDER BY s.sku_code
    """)
    moppity_skus = cur.fetchall()

    # 3. Build lookup by brand + variety + vintage
    moppity_index: dict[tuple, list] = {}
    for sku_id, code, name, variety, vintage in moppity_skus:
        brand = extract_brand(name, code)
        var_norm = normalize_variety(variety)
        key = (brand, var_norm, vintage)
        if key not in moppity_index:
            moppity_index[key] = []
        moppity_index[key].append((sku_id, code, name))

    # 4. Match DWS codes to Moppity codes
    results = []
    for sku_id, dws_code, dws_name, variety, vintage, revenue in dws_skus:
        brand = extract_brand(dws_name, dws_code)
        var_norm = normalize_variety(variety)

        # Try exact match (brand + variety + vintage)
        key = (brand, var_norm, vintage)
        matches = moppity_index.get(key, [])

        if len(matches) == 1:
            mv_id, mv_code, mv_name = matches[0]
            results.append({
                'dws_code': dws_code,
                'dws_name': dws_name,
                'dws_variety': variety or '',
                'dws_vintage': vintage or '',
                'dws_revenue': float(revenue),
                'suggested_moppity_code': mv_code,
                'moppity_name': mv_name,
                'confidence': 'HIGH',
                'notes': '',
            })
        elif len(matches) > 1:
            # Multiple matches — pick most similar name, flag as MEDIUM
            best = matches[0]
            results.append({
                'dws_code': dws_code,
                'dws_name': dws_name,
                'dws_variety': variety or '',
                'dws_vintage': vintage or '',
                'dws_revenue': float(revenue),
                'suggested_moppity_code': best[1],
                'moppity_name': best[2],
                'confidence': 'MEDIUM',
                'notes': f'Multiple matches: {", ".join(m[1] for m in matches[:5])}',
            })
        else:
            # No vintage match — try brand + variety only
            no_vintage_matches = []
            for k, v in moppity_index.items():
                if k[0] == brand and k[1] == var_norm:
                    no_vintage_matches.extend(v)

            if len(no_vintage_matches) == 1:
                mv_id, mv_code, mv_name = no_vintage_matches[0]
                results.append({
                    'dws_code': dws_code,
                    'dws_name': dws_name,
                    'dws_variety': variety or '',
                    'dws_vintage': vintage or '',
                    'dws_revenue': float(revenue),
                    'suggested_moppity_code': mv_code,
                    'moppity_name': mv_name,
                    'confidence': 'MEDIUM',
                    'notes': 'Matched by brand+variety only (no vintage)',
                })
            elif no_vintage_matches:
                # Pick latest vintage
                best = sorted(no_vintage_matches, key=lambda x: x[1], reverse=True)[0]
                results.append({
                    'dws_code': dws_code,
                    'dws_name': dws_name,
                    'dws_variety': variety or '',
                    'dws_vintage': vintage or '',
                    'dws_revenue': float(revenue),
                    'suggested_moppity_code': best[1],
                    'moppity_name': best[2],
                    'confidence': 'LOW',
                    'notes': f'No vintage match. Candidates: {", ".join(m[1] for m in no_vintage_matches[:5])}',
                })
            else:
                results.append({
                    'dws_code': dws_code,
                    'dws_name': dws_name,
                    'dws_variety': variety or '',
                    'dws_vintage': vintage or '',
                    'dws_revenue': float(revenue),
                    'suggested_moppity_code': '',
                    'moppity_name': '',
                    'confidence': 'NONE',
                    'notes': f'No match found (brand={brand})',
                })

    conn.close()

    # 5. Write CSV
    outpath = os.path.join(os.path.dirname(__file__), 'dws_mapping_suggestions.csv')
    with open(outpath, 'w', newline='') as f:
        writer = csv.DictWriter(f, fieldnames=[
            'dws_code', 'dws_name', 'dws_variety', 'dws_vintage', 'dws_revenue',
            'suggested_moppity_code', 'moppity_name', 'confidence', 'notes',
        ])
        writer.writeheader()
        writer.writerows(results)

    # Summary
    high = sum(1 for r in results if r['confidence'] == 'HIGH')
    medium = sum(1 for r in results if r['confidence'] == 'MEDIUM')
    low = sum(1 for r in results if r['confidence'] == 'LOW')
    none = sum(1 for r in results if r['confidence'] == 'NONE')

    print(f'Generated {len(results)} mapping suggestions → {outpath}')
    print(f'  HIGH confidence:   {high}')
    print(f'  MEDIUM confidence: {medium}')
    print(f'  LOW confidence:    {low}')
    print(f'  NO match:          {none}')
    print()
    print('Next steps:')
    print('  1. Send CSV to the owner for review')
    print('  2. The owner confirms/corrects mappings')
    print('  3. Run: python etl/import_dws_mapping.py etl/dws_mapping_confirmed.csv')


if __name__ == '__main__':
    main()
