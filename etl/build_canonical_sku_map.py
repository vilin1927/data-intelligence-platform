"""
F-04: Build Complete SKU Code Map — All External Codes → 99 Canonical SKUs

Resolves unmatched sku rows to canonical_sku entries using:
1. Manual override dictionary (for known difficult mappings)
2. Brand + variety matching
3. Fuzzy word-overlap matching

Usage:
    DATABASE_URL=postgresql://... python -m etl.build_canonical_sku_map
"""

import logging
import os
import re
import sys

import psycopg2

from etl.logger import log_etl_run

logger = logging.getLogger("moppity.etl.build_canonical_sku_map")

# ─── Manual overrides for known difficult mappings ─────────────────────
# sku_group (lowercased) → canonical_sku.sku_name (exact, case-insensitive match)
MANUAL_MAP: dict[str, str] = {
    # Abbreviated ALM codes
    "coppabella chard": "COPPABELLA CHARDONNAY",
    "coppabella crst chard": "COPPABELLA THE CREST CHARDONNAY",
    "chal/br estate chard": "N/A",  # Chalice Bridge — obsolete, map to N/A
    "chal/br estate sav blanc": "N/A",
    "chal/br quest cab sauv": "N/A",
    "chal/br sem sauv blanc": "N/A",
    "moppity block a5 cnb shz": "MOPPITY BLK A5 SHIRAZ",
    "moppity block m4 ht shz": "MOPPITY BLK M4 SHIRAZ",
    "moppity block c118 gewurztraminer 2023(12 pk)": "MOPPITY BLK C11B GEWURZTRAMINER",

    # Copabella (typo — missing P)
    "copabella prosecco": "COPPABELLA PROSECCO",
    "copabella pinot rose": "COPPABELLA ROSE",
    "copabella dear frankie rose": "COPPABELLA ROSE",
    "copabella spk vintage rose": "COPPABELLA SPARKLING ROSE",

    # Coppabella variants
    "coppabella cab sauv": "COPPABELLA CABERNET SAUVIGNON",
    "coppabella crest chard": "COPPABELLA THE CREST CHARDONNAY",
    "coppablla diva sauv blc keg": "COPPABELLA SAUVIGNON BLANC",

    # Moppity Vineyards (old naming) → Estate/Reserve
    "moppity vineyards cabernet": "MOPPITY ESTATE CABERNET SAUVIGNON",
    "moppity vineyard cabernet": "MOPPITY ESTATE CABERNET SAUVIGNON",
    "moppity vineyards chard": "MOPPITY ESTATE CHARDONNAY",
    "moppity vineyards merlot": "LOCK & KEY MERLOT",
    "moppity vineyards res shz": "MOPPITY RESERVE SHIRAZ",
    "moppity vineyards res cab": "MOPPITY RESERVE CABERNET SAUVIGNON",
    "moppity sparkling res shz nv": "MOPPITY RESERVE SPARKLING SHIRAZ",

    # Block wines
    "moppity block c20 chard": "MOPPITY BLK C20 CHARDONNAY",
    "moppity block c12 gamay": "MOPPITY BLK C12C GAMAY",
    "moppity 'creo' pet nat": "N/A",  # Not in canonical 99
    "moppity 'creo' pet naturel": "N/A",

    # Cato variants not in canonical
    "cato gruner": "N/A",
    "cato gruner veltliner": "N/A",
    "cato rose": "N/A",

    # Obsolete brands → N/A
    "hex & heysen riesling": "N/A",
    "hex & heysen sauv blanc": "N/A",
    "hex & heysen shiraz": "N/A",
    "hex & heysen cabernet sauv": "N/A",
    "hex & heysen pinot gris": "N/A",
    "opera kitchen sparkling": "N/A",
    "opera kitchen shiraz": "N/A",
    "opera kitchen sauv blanc": "N/A",
    "o-bar sauv blanc": "N/A",
    "o-bar shiraz": "N/A",
    "single step cab sauvign": "N/A",
    "single step sauv blanc": "N/A",
    "single step sparkling": "N/A",
    "single step cabernet sauv": "N/A",
    "single step chardonnay": "N/A",
    "single step spk chard pin": "N/A",
    "chalice br est chadonnay": "N/A",
    "chalice br est ssb": "N/A",
    "chalice br est sauv blanc": "N/A",
    "chalice br quest cab sauv": "N/A",
    "chalice br quest chard": "N/A",
    "chalice br quest sauv blanc": "N/A",
    "argo riesling": "N/A",
    "the darling chardonnay": "N/A",
}

# ─── Variety normalization ─────────────────────────────────────────────
VARIETY_ALIASES = {
    "cabernet": "cabernet sauvignon",
    "cab sauv": "cabernet sauvignon",
    "cab sauvign": "cabernet sauvignon",
    "sauv blanc": "sauvignon blanc",
    "sav blanc": "sauvignon blanc",
    "sem sauv blanc": "sauvignon blanc",
    "chard": "chardonnay",
    "shz": "shiraz",
    "rieb": "riesling",
    "spk": "sparkling",
    "ros": "rose",
    "rose": "rosé",
}


def normalize_for_match(name: str) -> str:
    """Normalize a name for matching: lowercase, strip vintage, normalize variety."""
    if not name:
        return ""
    n = name.lower().strip()
    # Remove vintage year patterns
    n = re.sub(r'\b(19|20)\d{2}\b', '', n)
    # Remove pack info
    n = re.sub(r'\(\d+ pk\)', '', n, flags=re.IGNORECASE)
    # Remove 750ml, 187ml etc
    n = re.sub(r'\d+ml', '', n)
    # Normalize ampersand
    n = n.replace('&', ' & ')
    # Collapse whitespace
    n = re.sub(r'\s+', ' ', n).strip()
    return n


def extract_brand_variety(name: str) -> tuple[str, str]:
    """Extract brand and variety from a SKU name."""
    n = normalize_for_match(name)

    # Known brand prefixes
    brands = [
        "coppabella sirius", "coppabella the crest", "coppabella crest",
        "coppabella procella", "coppabella",
        "lock & key reserve", "lock & key rsv", "lock & key",
        "moppity reserve", "moppity estate", "moppity block", "moppity blk",
        "moppity atrius", "moppity crafted", "moppity escalier", "moppity",
        "twelve signs", "procella", "cato", "kemenys",
    ]

    for brand in brands:
        if n.startswith(brand):
            variety_part = n[len(brand):].strip()
            return brand, variety_part

    return "", n


def main():
    database_url = os.environ.get("DATABASE_URL")
    if not database_url:
        print("ERROR: DATABASE_URL not set", file=sys.stderr)
        sys.exit(1)

    conn = psycopg2.connect(database_url)
    conn.autocommit = False

    try:
        with conn.cursor() as cur:
            # Load canonical SKUs
            cur.execute("SELECT id, sku_name FROM canonical_sku")
            canonical = {row[1].upper().strip(): row[0] for row in cur.fetchall()}
            # Also build normalized lookup
            canonical_normalized = {}
            for name, cid in canonical.items():
                canonical_normalized[normalize_for_match(name)] = (cid, name)

            print(f"Loaded {len(canonical)} canonical SKUs")

            # Find unmatched SKUs with sales
            cur.execute("""
                SELECT s.sku_id, s.sku_code, s.sku_group, s.item_description, s.variety
                FROM sku s
                WHERE s.canonical_sku_id IS NULL
                  AND s.variety IS NOT NULL
                  AND EXISTS (SELECT 1 FROM sales_transaction st WHERE st.sku_id = s.sku_id)
            """)
            unmatched = cur.fetchall()
            print(f"Found {len(unmatched)} unmatched SKUs with sales\n")

            matched = 0
            mapped_to_na = 0
            still_unmatched = []

            for sku_id, sku_code, sku_group, item_desc, variety in unmatched:
                group_lower = (sku_group or "").lower().strip()
                desc_lower = (item_desc or "").lower().strip()
                canonical_id = None
                match_method = None

                # Step 1: Manual override
                if group_lower in MANUAL_MAP:
                    target = MANUAL_MAP[group_lower]
                    if target == "N/A":
                        # Map to N/A canonical (obsolete product)
                        target_upper = "N/A"
                        if target_upper in canonical:
                            canonical_id = canonical[target_upper]
                            match_method = "manual_override_na"
                            mapped_to_na += 1
                    else:
                        target_upper = target.upper().strip()
                        if target_upper in canonical:
                            canonical_id = canonical[target_upper]
                            match_method = "manual_override"

                # Step 2: Exact normalized match
                if canonical_id is None:
                    norm = normalize_for_match(sku_group or item_desc or "")
                    if norm in canonical_normalized:
                        canonical_id = canonical_normalized[norm][0]
                        match_method = "normalized_exact"

                # Step 3: Brand + variety matching
                if canonical_id is None:
                    brand, var_part = extract_brand_variety(sku_group or item_desc or "")
                    if brand and var_part:
                        # Normalize variety
                        var_norm = var_part
                        for alias, full in VARIETY_ALIASES.items():
                            if var_norm.strip() == alias or var_norm.strip().startswith(alias):
                                var_norm = full
                                break

                        # Try to find canonical match with brand + variety
                        for cname, cid in canonical.items():
                            cname_lower = cname.lower()
                            if brand in cname_lower and var_norm in cname_lower:
                                canonical_id = cid
                                match_method = "brand_variety"
                                break

                # Step 4: Variety-only match (last resort for single-variety brands)
                if canonical_id is None and variety:
                    var_lower = variety.lower()
                    # Try matching item description words against canonical names
                    desc_words = set(normalize_for_match(sku_group or "").split())
                    best_score = 0
                    best_id = None
                    for cname, cid in canonical.items():
                        cname_words = set(normalize_for_match(cname).split())
                        overlap = len(desc_words & cname_words)
                        if overlap > best_score and overlap >= 2:
                            best_score = overlap
                            best_id = cid
                            match_method = f"word_overlap_{overlap}"

                    if best_id:
                        canonical_id = best_id

                # Apply match
                if canonical_id:
                    # BUG-94/99: fuzzy match never overwrites an Access-sourced
                    # canonical_sku_id. The SELECT above already pre-filters
                    # canonical_sku_id IS NULL, but carry the guard on the
                    # UPDATE too so a future refactor can't silently regress
                    # this contract. Access-canonical wins.
                    cur.execute(
                        "UPDATE sku SET canonical_sku_id = %s "
                        "WHERE sku_id = %s AND canonical_sku_id IS NULL",
                        (canonical_id, sku_id),
                    )
                    if cur.rowcount == 0:
                        continue
                    matched += 1
                    logger.info("Matched sku_id=%d '%s' → canonical_id=%d (%s)", sku_id, sku_group, canonical_id, match_method)
                else:
                    still_unmatched.append((sku_id, sku_code, sku_group, item_desc))

            conn.commit()

            # Report
            print("=" * 60)
            print("F-04: Build Canonical SKU Code Map")
            print("=" * 60)
            print(f"\nUnmatched SKUs with sales: {len(unmatched)}")
            print(f"  Matched:          {matched}")
            print(f"    - to real SKU:  {matched - mapped_to_na}")
            print(f"    - to N/A:       {mapped_to_na} (obsolete products)")
            print(f"  Still unmatched:  {len(still_unmatched)}")

            if still_unmatched:
                print(f"\nStill unmatched ({len(still_unmatched)}):")
                for sid, scode, sgroup, sdesc in still_unmatched:
                    print(f"  sku_id={sid}: code={scode} group='{sgroup}' desc='{sdesc}'")

            # Final stats
            cur.execute("""
                SELECT
                    COUNT(*) as total,
                    COUNT(*) FILTER (WHERE canonical_sku_id IS NOT NULL) as linked,
                    COUNT(*) FILTER (WHERE canonical_sku_id IS NULL AND variety IS NOT NULL
                        AND EXISTS (SELECT 1 FROM sales_transaction st WHERE st.sku_id = sku.sku_id)) as unlinked_with_sales
                FROM sku
            """)
            total, linked, unlinked_sales = cur.fetchone()
            print(f"\nOverall SKU linkage:")
            print(f"  Total SKU rows:           {total}")
            print(f"  Linked to canonical:      {linked} ({linked*100//total}%)")
            print(f"  Unlinked with sales:      {unlinked_sales}")
            print("=" * 60)

            log_etl_run(
                db_conn=conn,
                source="canonical_sku_map",
                endpoint="build_map",
                status="success" if not still_unmatched else "partial",
                rows_processed=matched,
                rows_skipped=len(still_unmatched),
                error_count=len(still_unmatched),
                error_detail=f"{len(still_unmatched)} unmatched SKUs with sales" if still_unmatched else None,
            )

    except Exception as exc:
        conn.rollback()
        logger.error("Failed: %s", exc)
        raise
    finally:
        conn.close()


if __name__ == "__main__":
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    )
    main()
