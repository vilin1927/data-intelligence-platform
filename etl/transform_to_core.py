"""
Transform raw/staging data into core tables.

Reads from access_*, staging_vinsight_*, staging_xero_* tables
and populates: territory, representative, sku, customer,
customer_code_map, sales_transaction.
(wine_range is a VIEW over canonical_sku — see BUG-101 / ADR-010.)

Usage:
    DATABASE_URL="postgresql://localhost/moppity_db" python3 etl/transform_to_core.py
"""

import datetime
import json
import logging
import os
import sys
from decimal import Decimal, InvalidOperation

import psycopg2
import psycopg2.extras

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
log = logging.getLogger("transform_to_core")


# ---------------------------------------------------------------------------
# Normalization maps — prevent typos from source systems entering core tables
# ---------------------------------------------------------------------------

RANGE_NAME_MAP = {
    "OPPABELLA PROCELLA": "COPPABELLA PROCELLA",
    "Lock & Key": "LOCK & KEY",
}

TERRITORY_NAME_MAP = {
    # Map ALL-CAPS duplicates to their title-case canonical form
    "ACT ON PREMISE": "ACT on premise",
    "ACT On Premise": "ACT on premise",
    "ACT SOUTH COAST": "ACT South Coast",
    "HEAD OFFICE": "Head Office",
    "NSW CENTRAL COAST": "NSW Central Coast",
    "NSW CENTRAL WEST": "NSW Central West",
    "NSW SOUTHERN HIGHLANDS & ILLAWARRA": "NSW Southern Highlands & Illawarra",
    "NSW SYDNEY CBD": "NSW Sydney CBD",
    "NSW SYDNEY EAST": "NSW Sydney East",
    "NSW SYDNEY NORTH": "NSW Sydney North",
    "NSW SYDNEY SOUTH": "NSW Sydney South",
    "NSW SYDNEY WEST": "NSW Sydney West",
    "QUEENSLAND METRO": "Queensland Metro",
    "SAMPLES": "Samples",
    "VIC MELBOURNE CBD": "VIC Melbourne CBD",
    "VIC MELBOURNE EAST": "VIC Melbourne East",
    "VIC Melbourne EAST": "VIC Melbourne East",
    "VIC MELBOURNE NORTH": "VIC Melbourne North",
    "VIC MELBOURNE REGIONAL": "VIC Melbourne Regional",
    "VIC MELBOURNE SOUTH": "VIC Melbourne South",
    "VIC Melbourne SOUTH": "VIC Melbourne South",
    "VIC MELBOURNE WEST": "VIC Melbourne West",
    "VIC NTH EAST": "VIC Nth East",
    "WA METRO": "WA Metro",
}

VARIETY_MAP = {
    "Rose": "Rosé",
    "Tumbarumba Sparkling": "Sparkling",
}

REGION_BRAND_MAP = {
    # Brand keywords → canonical region
    "coppabella": "Tumbarumba",
    "copabella": "Tumbarumba",
    "sirius": "Tumbarumba",
    "crest ": "Tumbarumba",
    "procella": "Tumbarumba",
    "canberra": "Canberra",
}


def normalize_territory(name):
    """Normalize territory name using canonical map."""
    if not name:
        return name
    name = name.strip()
    return TERRITORY_NAME_MAP.get(name, name)


def normalize_range(name):
    """Normalize wine range name using canonical map."""
    if not name:
        return name
    name = name.strip()
    return RANGE_NAME_MAP.get(name, name)


def normalize_variety(name):
    """Normalize variety name using canonical map."""
    if not name:
        return name
    name = name.strip()
    return VARIETY_MAP.get(name, name)


def infer_region(description):
    """Infer region from wine description keywords."""
    if not description:
        return None
    desc_lower = description.lower()
    for keyword, region in REGION_BRAND_MAP.items():
        if keyword in desc_lower:
            return region
    return None


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _dec(val):
    """Parse a value to Decimal, returning None on failure."""
    if val is None:
        return None
    try:
        text = str(val).strip().replace(",", "").replace("$", "")
        if not text:
            return None
        return Decimal(text)
    except (InvalidOperation, ValueError):
        return None


def _int(val):
    """Parse a value to int, returning None on failure."""
    if val is None:
        return None
    try:
        text = str(val).strip()
        if not text:
            return None
        return int(float(text))
    except (ValueError, TypeError):
        return None


def _parse_date(val):
    """Parse Access DB date formats to date object."""
    if val is None:
        return None
    text = str(val).strip()
    if not text:
        return None
    for fmt in ("%m/%d/%y %H:%M:%S", "%m/%d/%Y %H:%M:%S",
                "%Y-%m-%d %H:%M:%S", "%Y-%m-%dT%H:%M:%S",
                "%d/%m/%Y", "%d/%m/%y", "%Y-%m-%d"):
        try:
            return datetime.datetime.strptime(text, fmt).date()
        except ValueError:
            continue
    return None


def _extract_vintage(description, item_code):
    """Try to extract 4-digit vintage year from description or item code."""
    import re
    for text in [description or "", item_code or ""]:
        m = re.search(r'\b(19|20)\d{2}\b', text)
        if m:
            return int(m.group())
    # Try 2-digit year at end of item_code like "COCOROSB18" -> 2018
    if item_code:
        m = re.search(r'(\d{2})$', item_code)
        if m:
            yr = int(m.group())
            if 15 <= yr <= 30:
                return 2000 + yr
            elif 90 <= yr <= 99:
                return 1900 + yr
    return None


def _map_channel(channel_text, warehouse_text):
    """Map Access DB Channel/Warehouse to our channel_id (DWS=1, ALM=2, Direct=3)."""
    w = (warehouse_text or "").strip().upper()
    c = (channel_text or "").strip().upper()
    if "DIRECT" in w:
        return 3  # Direct
    if "ALM" in w or "ALM" in c:
        return 2  # ALM
    if "DWS" in w or "Y&R" in w or "YNR" in w or "YOUNG" in w:
        return 1  # DWS
    # Default: if warehouse looks like a distributor name, it's likely DWS
    if w and w not in ("DIRECT", ""):
        return 1  # DWS (consignment via distributor)
    return 3  # Default to Direct


def _parse_contact_category(text):
    """Parse Vinsight ContactCategory semicolon-delimited string into a dict.

    Example input:
        ";CATEGORY:RETA;channel:Off Premise;CUSTCODE:V161CELL;GROUP:INDE;SALESAREA:VIC;"
    Returns:
        {'CATEGORY': 'RETA', 'channel': 'Off Premise', 'CUSTCODE': 'V161CELL',
         'GROUP': 'INDE', 'SALESAREA': 'VIC'}
    """
    out = {}
    if not text:
        return out
    for part in text.split(";"):
        part = part.strip()
        if not part or ":" not in part:
            continue
        k, _, v = part.partition(":")
        out[k.strip()] = v.strip()
    return out


def _map_vinsight_channel(channel_str):
    """Map Vinsight ContactCategory channel value to our channel_id.

    Existing convention from populate_customer() (Access path):
      - OFF PREMISE  -> DWS (1)  [off-premise retail typically via distributor]
      - ON PREMISE   -> Direct (3) [on-premise restaurants/hotels buy direct]

    Vinsight variants observed in staging_vinsight_contacts.ContactCategory:
      'Off Premise' / 'offpremise' -> DWS (1)
      'on Premise'  / 'onpremise'  / 'hybrid' -> Direct (3)
      'direct' / 'consumer' / 'export'        -> Direct (3)
      'wholesale'                              -> ALM (2)

    Returns None if the value is unknown/empty so the caller can preserve any
    existing channel_id via COALESCE.
    """
    if not channel_str:
        return None
    s = channel_str.strip().lower().replace(" ", "")
    if s == "offpremise":
        return 1  # DWS
    if s in ("onpremise", "hybrid", "direct", "consumer", "export"):
        return 3  # Direct / on-premise
    if s == "wholesale":
        return 2  # ALM
    return None


# BUG-127 / ADR-017: explicit warehouse-channel string for customer.warehouse_channel.
# Mirrors channel_id 1/2/3 → DWS/ALM/Direct. NULL when no signal so backfill /
# sales-derived classifier can fill later.
_CHANNEL_ID_TO_WAREHOUSE = {1: "DWS", 2: "ALM", 3: "Direct"}


def _channel_id_to_warehouse(channel_id):
    """Map channel_id (1/2/3) → warehouse_channel string ('DWS'/'ALM'/'Direct').
    Returns None for unknown / NULL input so callers can use COALESCE.
    """
    if channel_id is None:
        return None
    return _CHANNEL_ID_TO_WAREHOUSE.get(channel_id)


# ---------------------------------------------------------------------------
# BUG-165 helpers (2026-05-12) — shared faucet-patch primitives
# ---------------------------------------------------------------------------
# Every INSERT INTO customer in this file must (a) embed NAME @ SUBURB form
# and (b) set canonical_customer_id. Helpers below centralize the logic so
# all 4 writers stay aligned with the reference patterns in
# dashboard/src/app/api/customers/route.ts:116-191 (Faucet #1) and
# etl/backfill_vinsight_contact_enrichment.py:128-180 (Faucet #2).
#
# L6 constraint customer_must_have_canonical (schema/162 NOT VALID; future
# schema/163 VALIDATE) REJECTS any INSERT that doesn't set canonical_customer_id.

def _embed_name_with_suburb(name, suburb):
    """Return 'NAME @ SUBURB' form when suburb is present and name not already
    embedded; otherwise return name unchanged. Matches schema/060 line 107
    legacy access-DB convention used by faucets #1 and #2.
    """
    if not name:
        return name
    name = name.strip()
    suburb_clean = (suburb or "").strip()
    if suburb_clean and " @ " not in name:
        return f"{name} @ {suburb_clean.upper()}"
    return name


def _resolve_territory_name(cur, territory_id):
    """Resolve territory_id → territory_name for canonical_customer.territory_name.

    canonical_customer.territory_name has L6 NOT VALID constraint
    canonical_customer_must_have_territory (schema/162:117). Falls back to
    'Unassigned' when no territory_id or no matching row, matching the
    Group 2 (api/customers + backfill) pattern.
    """
    if territory_id is None:
        return "Unassigned"
    cur.execute(
        "SELECT territory_name FROM territory WHERE territory_id = %s",
        (territory_id,),
    )
    row = cur.fetchone()
    if row and row[0]:
        return row[0]
    return "Unassigned"


def _resolve_canonical_for_customer_insert(
    cur, name, suburb, channel, customer_group, territory_id
):
    """Lookup-or-create canonical_customer + return (embedded_name, canonical_id).

    BUG-165 faucet-patch shared primitive. Centralizes the lookup-or-create
    pattern so all 4 INSERT INTO customer sites in this file stay aligned
    with reference faucets #1 + #2:

      - Embed NAME @ SUBURB form via _embed_name_with_suburb (matches
        schema/060:107 legacy access-DB convention).
      - Resolve territory_name via _resolve_territory_name (defaults to
        'Unassigned' to satisfy L6 canonical_customer_must_have_territory).
      - Lookup existing canonical_customer by case-insensitive embedded name.
      - Auto-create canonical_customer with embedded name + channel +
        customer_group + territory_name when no match — ON CONFLICT on
        canonical_customer.customer_name UNIQUE (schema/012:71) keeps it
        idempotent across re-runs.

    Args:
        cur: psycopg2 cursor (transaction-scoped — caller commits).
        name: raw customer name from source row.
        suburb: optional suburb / city — embedded into name when present.
        channel: warehouse_channel string ('DWS'/'ALM'/'Direct') or None;
            stored on canonical_customer.channel.
        customer_group: optional customer_group string or None.
        territory_id: optional FK to territory.territory_id — resolved to
            territory_name; 'Unassigned' when None or unresolved.

    Returns:
        (embedded_name, canonical_customer_id) — caller passes both into the
        customer INSERT (customer_name + canonical_customer_id columns).
    """
    embedded_name = _embed_name_with_suburb(name, suburb)
    territory_name = _resolve_territory_name(cur, territory_id)

    cur.execute(
        "SELECT id FROM canonical_customer WHERE LOWER(customer_name) = LOWER(%s) LIMIT 1",
        (embedded_name,),
    )
    row = cur.fetchone()
    if row:
        return embedded_name, row[0]

    cur.execute(
        """
        INSERT INTO canonical_customer (customer_name, channel, customer_group, territory_name)
        VALUES (%s, %s, %s, %s)
        ON CONFLICT (customer_name) DO UPDATE SET customer_name = EXCLUDED.customer_name
        RETURNING id
        """,
        (embedded_name, channel, customer_group, territory_name),
    )
    return embedded_name, cur.fetchone()[0]


# ---------------------------------------------------------------------------
# Step 1: Populate territory
# ---------------------------------------------------------------------------

def populate_territory(cur):
    log.info("Populating territory...")
    cur.execute("""
        SELECT DISTINCT
            raw_data->>'Territory' as territory_name,
            raw_data->>'TerritoryGroup' as territory_group
        FROM access_combined_data
        WHERE raw_data->>'Territory' IS NOT NULL
          AND raw_data->>'Territory' != ''
    """)
    rows = cur.fetchall()

    count = 0
    for territory_name, territory_group in rows:
        territory_name = normalize_territory(territory_name)
        if not territory_name:
            continue
        # Extract state from territory name (e.g. "VIC Melbourne West" -> "VIC")
        parts = territory_name.split()
        state = parts[0] if parts else None
        if state and len(state) > 4:
            state = None  # Not a state abbreviation

        cur.execute("""
            INSERT INTO territory (territory_name, state, region)
            VALUES (%s, %s, %s)
            ON CONFLICT (territory_name) DO NOTHING
        """, (territory_name, state, territory_group.strip() if territory_group else None))
        count += 1

    log.info("  territory: %d unique territories processed", count)
    return count


# ---------------------------------------------------------------------------
# Step 2: Populate representative
# ---------------------------------------------------------------------------

def populate_representative(cur):
    log.info("Populating representative...")
    cur.execute("""
        SELECT DISTINCT raw_data->>'FullRep' as full_rep,
                        raw_data->>'ShortRep' as short_rep,
                        raw_data->>'Territory' as territory
        FROM access_representative
        WHERE raw_data->>'FullRep' IS NOT NULL
          AND raw_data->>'FullRep' != ''
    """)
    rows = cur.fetchall()

    count = 0
    for full_rep, short_rep, territory in rows:
        full_rep = full_rep.strip()
        if not full_rep:
            continue

        # Look up territory_id
        territory_id = None
        if territory:
            cur.execute("SELECT territory_id FROM territory WHERE territory_name = %s",
                        (territory.strip(),))
            t = cur.fetchone()
            if t:
                territory_id = t[0]

        cur.execute("""
            INSERT INTO representative (rep_name, territory_id, active)
            VALUES (%s, %s, true)
            ON CONFLICT (rep_name) DO NOTHING
        """, (full_rep, territory_id))
        count += 1

    # Also get unique reps from sales data that might not be in the rep table
    cur.execute("""
        SELECT DISTINCT raw_data->>'Rep' as rep
        FROM access_combined_data
        WHERE raw_data->>'Rep' IS NOT NULL
          AND raw_data->>'Rep' != ''
    """)
    for (rep_name,) in cur.fetchall():
        rep_name = rep_name.strip()
        if rep_name:
            cur.execute("""
                INSERT INTO representative (rep_name, active)
                VALUES (%s, true)
                ON CONFLICT (rep_name) DO NOTHING
            """, (rep_name,))
            count += 1

    log.info("  representative: %d processed", count)
    return count


# ---------------------------------------------------------------------------
# Step 3: Populate wine_range — RETIRED 2026-04-23 (BUG-101 / ADR-010).
# wine_range is now a VIEW over canonical_sku.range_name (schema/051).
# canonical_sku is the single source of truth for range data.
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# Step 4: Populate sku
# ---------------------------------------------------------------------------

def populate_sku(cur):
    log.info("Populating sku from access_sku...")
    cur.execute("SELECT raw_data FROM access_sku")
    rows = cur.fetchall()

    count = 0
    for (raw,) in rows:
        d = raw if isinstance(raw, dict) else json.loads(raw)
        sku_name = (d.get("SKU") or "").strip()
        if not sku_name:
            continue

        vintage = _extract_vintage(sku_name, None)

        cur.execute("""
            INSERT INTO sku (sku_code, item_description, vintage,
                             units_per_case, base_wholesale, transfer_cost)
            VALUES (%s, %s, %s, %s, %s, %s)
            ON CONFLICT (sku_code) DO UPDATE SET
                item_description = EXCLUDED.item_description,
                vintage = COALESCE(EXCLUDED.vintage, sku.vintage),
                units_per_case = COALESCE(EXCLUDED.units_per_case, sku.units_per_case),
                base_wholesale = COALESCE(EXCLUDED.base_wholesale, sku.base_wholesale),
                transfer_cost = COALESCE(EXCLUDED.transfer_cost, sku.transfer_cost)
        """, (
            sku_name,
            sku_name,
            vintage,
            _int(d.get("UnitsperCase")),
            _dec(d.get("BaseWholesale")),
            _dec(d.get("TransferCost")),
        ))
        count += 1

    # Also add unique ItemCodes from combined_data that aren't in sku yet.
    # B3-4 shape guard (2026-05-11): reject ItemCode > 30 chars. schema/152
    # revert (155) — description text in raw_data['ItemCode'] cascaded into
    # fake sku rows (sku_code = full description text, ~50-100 chars).
    cur.execute("""
        SELECT DISTINCT
            raw_data->>'ItemCode' as item_code,
            raw_data->>'ItemDescription' as description,
            raw_data->>'SKU' as sku_name,
            raw_data->>'BaseWholesale' as base_wholesale,
            raw_data->>'TransferCost' as transfer_cost
        FROM access_combined_data
        WHERE raw_data->>'ItemCode' IS NOT NULL
          AND raw_data->>'ItemCode' != ''
          AND LENGTH(raw_data->>'ItemCode') <= 30
    """)
    for item_code, description, sku_name, bw, tc in cur.fetchall():
        item_code = item_code.strip()
        if not item_code:
            continue

        vintage = _extract_vintage(description, item_code)

        cur.execute("""
            INSERT INTO sku (sku_code, item_description, vintage,
                             base_wholesale, transfer_cost)
            VALUES (%s, %s, %s, %s, %s)
            ON CONFLICT (sku_code) DO UPDATE SET
                item_description = COALESCE(EXCLUDED.item_description, sku.item_description),
                vintage = COALESCE(EXCLUDED.vintage, sku.vintage)
        """, (
            item_code,
            (description or sku_name or "").strip(),
            vintage,
            _dec(bw),
            _dec(tc),
        ))
        count += 1

    log.info("  sku: %d processed", count)
    return count


# ---------------------------------------------------------------------------
# Step 5: Populate customer + customer_code_map
# ---------------------------------------------------------------------------

def populate_customer(cur):
    log.info("Populating customer from access_customers...")
    cur.execute("SELECT raw_data FROM access_customers")
    rows = cur.fetchall()

    count = 0
    for (raw,) in rows:
        d = raw if isinstance(raw, dict) else json.loads(raw)
        # access_customers uses xCustomerName or CustomerName
        name = (d.get("xCustomerName") or d.get("CustomerName") or "").strip()
        if not name:
            continue

        channel_text = (d.get("Channel") or "").strip()
        territory_text = (d.get("Territory") or "").strip()
        suburb = (d.get("Suburb") or "").strip() or None

        # Look up territory_id
        territory_id = None
        if territory_text:
            cur.execute("SELECT territory_id FROM territory WHERE territory_name = %s",
                        (territory_text,))
            t = cur.fetchone()
            if t:
                territory_id = t[0]

        # Determine channel_id from channel text
        channel_id = None
        if "ON PREMISE" in channel_text.upper():
            channel_id = 3  # Direct
        elif "OFF PREMISE" in channel_text.upper():
            channel_id = 1  # DWS (most off-premise goes through distributors)

        group = (d.get("Group") or "").strip() or None

        # BUG-165 (2026-05-12): embed NAME @ SUBURB form + resolve canonical
        # link BEFORE customer INSERT. L6 customer_must_have_canonical
        # (schema/162 NOT VALID) REJECTS INSERTs missing canonical_customer_id.
        warehouse_channel = _channel_id_to_warehouse(channel_id)
        embedded_name, cc_id = _resolve_canonical_for_customer_insert(
            cur, name, suburb, warehouse_channel, group, territory_id
        )

        cur.execute("""
            INSERT INTO customer (customer_name, canonical_customer_id, channel_id, territory_id, customer_group, suburb)
            VALUES (%s, %s, %s, %s, %s, %s)
            ON CONFLICT (customer_name) DO UPDATE SET
                canonical_customer_id = COALESCE(customer.canonical_customer_id, EXCLUDED.canonical_customer_id),
                channel_id = COALESCE(EXCLUDED.channel_id, customer.channel_id),
                territory_id = COALESCE(EXCLUDED.territory_id, customer.territory_id),
                customer_group = COALESCE(EXCLUDED.customer_group, customer.customer_group),
                suburb = COALESCE(customer.suburb, EXCLUDED.suburb)
        """, (embedded_name, cc_id, channel_id, territory_id, group, suburb))
        count += 1

        # Get the customer_id for code map entries
        cur.execute("SELECT customer_id FROM customer WHERE customer_name = %s", (embedded_name,))
        customer_row = cur.fetchone()
        if not customer_row:
            continue
        cust_id = customer_row[0]

        # Populate customer_code_map from ALM/DIR/ILG/YNR codes
        code_map = {
            "alm": (d.get("ALMCustomerCode") or "").strip(),
            "direct": (d.get("DIRCustomerCode") or "").strip(),
            "dws": (d.get("YNRCustomerCode") or d.get("ILGCustomerCode") or "").strip(),
        }
        for source_system, ext_name in code_map.items():
            if ext_name:
                cur.execute("""
                    INSERT INTO customer_code_map (customer_id, source_system, external_name)
                    VALUES (%s, %s, %s)
                    ON CONFLICT (source_system, external_name) DO NOTHING
                """, (cust_id, source_system, ext_name))

    # Also add unique customer names from combined_data
    cur.execute("""
        SELECT DISTINCT
            raw_data->>'CustomerName' as name,
            raw_data->>'Territory' as territory,
            raw_data->>'Channel' as channel,
            raw_data->>'Suburb' as suburb
        FROM access_combined_data
        WHERE raw_data->>'CustomerName' IS NOT NULL
          AND raw_data->>'CustomerName' != ''
    """)
    for name, territory, channel, suburb in cur.fetchall():
        name = name.strip()
        if not name:
            continue
        suburb = (suburb or "").strip() or None

        territory_id = None
        if territory:
            cur.execute("SELECT territory_id FROM territory WHERE territory_name = %s",
                        (territory.strip(),))
            t = cur.fetchone()
            if t:
                territory_id = t[0]

        # BUG-165 (2026-05-12): embed NAME @ SUBURB form + resolve canonical
        # link BEFORE customer INSERT. L6 customer_must_have_canonical
        # (schema/162 NOT VALID) REJECTS INSERTs missing canonical_customer_id.
        # Channel/group not derivable here — combined_data row only carries
        # transaction-level Channel string; canonical channel left NULL and
        # filled by Vinsight/admin path later.
        embedded_name, cc_id = _resolve_canonical_for_customer_insert(
            cur, name, suburb, None, None, territory_id
        )

        cur.execute("""
            INSERT INTO customer (customer_name, canonical_customer_id, territory_id, suburb)
            VALUES (%s, %s, %s, %s)
            ON CONFLICT (customer_name) DO UPDATE SET
                canonical_customer_id = COALESCE(customer.canonical_customer_id, EXCLUDED.canonical_customer_id),
                territory_id = COALESCE(EXCLUDED.territory_id, customer.territory_id),
                suburb = COALESCE(customer.suburb, EXCLUDED.suburb)
        """, (embedded_name, cc_id, territory_id, suburb))
        count += 1

    log.info("  customer: %d processed", count)
    return count


# ---------------------------------------------------------------------------
# Step 6: Populate sales_transaction from access_combined_data (120K rows)
# ---------------------------------------------------------------------------

def populate_sales_transaction(cur):
    log.info("Populating sales_transaction from access_combined_data (120K rows)...")

    # Build lookup caches for performance
    log.info("  Building lookup caches...")

    # SKU cache: sku_code -> sku_id (both from sku table and sku_code_map)
    sku_cache = {}
    cur.execute("SELECT sku_id, sku_code FROM sku")
    for sid, scode in cur.fetchall():
        sku_cache[scode.lower()] = sid
    cur.execute("SELECT sku_id, external_code FROM sku_code_map")
    for sid, ecode in cur.fetchall():
        sku_cache[ecode.lower()] = sid

    # Customer cache: customer_name -> customer_id
    cust_cache = {}
    cur.execute("SELECT customer_id, customer_name FROM customer")
    for cid, cname in cur.fetchall():
        cust_cache[cname.lower()] = cid

    # Rep cache: rep_name -> rep_id
    rep_cache = {}
    cur.execute("SELECT rep_id, rep_name FROM representative")
    for rid, rname in cur.fetchall():
        rep_cache[rname.lower()] = rid

    # Territory cache: territory_name -> territory_id
    terr_cache = {}
    cur.execute("SELECT territory_id, territory_name FROM territory")
    for tid, tname in cur.fetchall():
        terr_cache[tname.lower()] = tid

    log.info("  Caches built: %d SKUs, %d customers, %d reps, %d territories",
             len(sku_cache), len(cust_cache), len(rep_cache), len(terr_cache))

    # Process in batches for memory efficiency
    batch_size = 5000
    offset = 0
    total_inserted = 0
    total_skipped = 0
    errors = 0

    while True:
        cur.execute("""
            SELECT raw_data FROM access_combined_data
            ORDER BY id
            LIMIT %s OFFSET %s
        """, (batch_size, offset))
        batch = cur.fetchall()
        if not batch:
            break

        for (raw,) in batch:
            d = raw if isinstance(raw, dict) else json.loads(raw)

            item_code = (d.get("ItemCode") or "").strip()
            customer_name = (d.get("CustomerName") or "").strip()
            date_str = d.get("TransactionDate")
            sale_date = _parse_date(date_str)

            if not sale_date:
                errors += 1
                continue

            # Lookups
            sku_id = sku_cache.get(item_code.lower()) if item_code else None
            customer_id = cust_cache.get(customer_name.lower()) if customer_name else None
            rep_name = (d.get("Rep") or "").strip()
            rep_id = rep_cache.get(rep_name.lower()) if rep_name else None
            territory_name = (d.get("Territory") or "").strip()
            territory_id = terr_cache.get(territory_name.lower()) if territory_name else None
            channel_id = _map_channel(d.get("Channel"), d.get("Warehouse"))

            quantity = _dec(d.get("QuantitySupplied(Dozens)")) or Decimal("0")
            unit_price = _dec(d.get("WholesaleValueExEx"))
            discount = _dec(d.get("Discount")) or Decimal("0")
            rebate = _dec(d.get("Rebate")) or Decimal("0")
            # BUG-114 (2026-04-25): WholesalerFee in access_combined_data is a
            # literal constant $N on every row (audit
            # bug-114-wholesalerfee-distribution-2026-04-24.txt). It is garbage
            # — a misplaced aggregate from the Access export, not a per-row fee.
            # Hardcode 0 here to match the canonical ingest path
            # etl/recon_etl_access_to_sales.py:273. schema/077 locks the
            # wholesale_fee=0 invariant on prod with DO $$ pre/post assertions.
            wholesale_fee = Decimal("0")

            # gross_revenue = quantity * unit_price (Wholesale Value Ex total)
            gross_revenue = None
            if unit_price is not None and quantity:
                gross_revenue = (quantity * unit_price).quantize(Decimal("0.01"))

            # BUG-114: net_revenue = gross - discount - rebate (wholesale_fee
            # is locked to 0 above for access_db; Phase E Decision Log default
            if gross_revenue is not None:
                net_revenue = gross_revenue - discount - rebate - wholesale_fee
            else:
                net_revenue = None

            period = sale_date.strftime("%Y-%m")
            # BUG-113 Option D: source_ref = raw Access `ID` only. `ID` is
            # verified unique 120,343/120,343 across access_combined_data
            # access_db rows were populated via recon_etl_access_to_sales.py
            # using `access_id` from the raw JSON — ID-only, no InvoiceNo
            # fallback. Any fallback would break content_hash idempotency.
            source_ref = str(d.get("ID") or "").strip()

            try:
                cur.execute("""
                    INSERT INTO sales_transaction (
                        sku_id, customer_id, rep_id, territory_id, channel_id,
                        sale_date, period, quantity, unit_price,
                        discount_amount, rebate_amount, wholesale_fee,
                        gross_revenue, net_revenue, source_system, source_ref,
                        stock_unit,
                        content_hash
                    )
                    VALUES (
                        %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s,
                        %s,
                        encode(
                            sha256(
                                (
                                    coalesce(%s, '')               || '|' ||
                                    coalesce(%s, '')               || '|' ||
                                    coalesce((%s::int)::text, '')  || '|' ||
                                    coalesce((%s::int)::text, '')  || '|' ||
                                    (%s::date)::text               || '|' ||
                                    (%s::decimal(12,2))::text
                                )::bytea
                            ),
                            'hex'
                        )
                    )
                    ON CONFLICT (content_hash) DO NOTHING
                """, (
                    sku_id, customer_id, rep_id, territory_id, channel_id,
                    sale_date, period, quantity, unit_price,
                    discount, rebate, wholesale_fee,
                    gross_revenue, net_revenue, "access_db", source_ref,
                    # BUG-118 / ADR-014: access_db `QuantitySupplied(Dozens)`
                    # = dozens = 12-pack cases. Always 'case'.
                    "case",
                    # content_hash bindings: source_system, source_ref, sku_id,
                    # customer_id, sale_date, quantity (Option D). stock_unit
                    # is NOT in the hash (derived attribute, not identity).
                    "access_db", source_ref, sku_id, customer_id, sale_date, quantity,
                ))
                total_inserted += 1
            except Exception as e:
                errors += 1
                if errors <= 10:
                    log.warning("  Row error: %s (ref=%s)", e, source_ref)

        offset += batch_size
        if offset % 20000 == 0:
            log.info("  Processed %d rows so far (%d inserted, %d errors)...",
                     offset, total_inserted, errors)

    log.info("  sales_transaction: %d inserted, %d skipped, %d errors",
             total_inserted, total_skipped, errors)
    return total_inserted


# ---------------------------------------------------------------------------
# Step 7: Populate from Vinsight staging
# ---------------------------------------------------------------------------

def populate_from_vinsight(cur):
    log.info("Populating from Vinsight staging...")

    # Stock items -> sku + sku_code_map
    cur.execute("SELECT raw_data FROM staging_vinsight_stock_items")
    vin_count = 0
    for (raw,) in cur.fetchall():
        d = raw if isinstance(raw, dict) else json.loads(raw)
        code = (d.get("StockItemCode") or "").strip()
        desc = (d.get("Description") or "").strip()
        if not code:
            continue

        is_wine = d.get("IsPackagedWine") or d.get("IsBulkWine")
        # BUG-91: skip dry-goods (cork/label/carton/closure/box/foil) Vinsight
        # items. IsPackagedWine=false AND IsBulkWine=false means it's not a
        # saleable wine — ingesting it pollutes sku and mis-links dry-good
        # codes to wine canonicals via sku_code_map.
        if not is_wine:
            continue
        vintage = _extract_vintage(desc, code)

        cur.execute("""
            INSERT INTO sku (sku_code, item_description, vintage)
            VALUES (%s, %s, %s)
            ON CONFLICT (sku_code) DO UPDATE SET
                item_description = COALESCE(EXCLUDED.item_description, sku.item_description),
                vintage = COALESCE(EXCLUDED.vintage, sku.vintage)
        """, (code, desc, vintage))

        # Add to sku_code_map for vinsight source
        cur.execute("SELECT sku_id FROM sku WHERE sku_code = %s", (code,))
        row = cur.fetchone()
        if row:
            cur.execute("""
                INSERT INTO sku_code_map (sku_id, source_system, external_code)
                VALUES (%s, 'vinsight', %s)
                ON CONFLICT (source_system, external_code) DO NOTHING
            """, (row[0], code))
        vin_count += 1

    # Contacts -> customer + customer_code_map (+ enrichment: suburb, postcode,
    # rep_id, channel_id, territory_id via SALESAREA).
    #
    # BUG-34: staging_vinsight_contacts has duplicate rows per ContactCode
    # (re-sync creates new rows without dedupe). Use DISTINCT ON + ORDER BY
    # synced_at DESC to always take the latest snapshot per contact. Only
    # IsDebtor=true rows are customers; skip suppliers/growers/employees.
    populate_salesperson_code_map(cur)
    _build_salesperson_rep_cache.cache_clear()  # refresh after populating map

    # Build caches first (before the contacts query) so we don't clobber the
    # open contacts cursor mid-iteration.
    terr_cache = {}
    cur.execute("SELECT territory_id, territory_name FROM territory")
    for tid, tname in cur.fetchall():
        terr_cache[tname.lower()] = tid

    # Salesarea -> territory_name mapping. Vinsight uses short state codes
    # like 'NSW', 'VIC', 'QLD', 'WA', 'SA', 'NT', 'TAS', 'ACT', 'HEAD'.
    salesarea_to_territory = {
        "NSW": "NSW Sydney CBD",      # Generic NSW -> CBD unless more specific
        "VIC": "VIC Melbourne CBD",   # Generic VIC -> CBD
        "QLD": "Queensland Metro",
        "WA":  "WA Metro",
        "SA":  "SA Metro",
        "NT":  "NT",
        "TAS": "TAS",
        "ACT": "ACT on premise",
        "HEAD": "Head Office",
    }

    # Warm sp_num -> rep_id cache once (uses cur internally, so do it before
    # the contacts fetch too).
    sp_num_to_rep = _build_salesperson_rep_cache(cur)

    cur.execute("""
        SELECT DISTINCT ON (raw_data->>'ContactCode') raw_data
        FROM staging_vinsight_contacts
        WHERE raw_data->>'ContactCode' IS NOT NULL
          AND raw_data->>'ContactCode' != ''
          AND raw_data->>'IsDebtor' = 'true'
        ORDER BY raw_data->>'ContactCode', synced_at DESC NULLS LAST
    """)
    rows_fetched = cur.fetchall()

    cust_count = 0
    enriched_suburb = 0
    enriched_postcode = 0
    enriched_rep = 0
    enriched_channel = 0
    enriched_territory = 0

    for (raw,) in rows_fetched:
        d = raw if isinstance(raw, dict) else json.loads(raw)
        name = (d.get("ContactCode") or "").strip()
        if not name:
            continue

        suburb = (d.get("PhysicalCity") or "").strip() or None
        postcode = (d.get("PhysicalPostCode") or "").strip() or None

        # Parse ContactCategory for SALESAREA and channel tags.
        cats = _parse_contact_category(d.get("ContactCategory") or "")
        salesarea = (cats.get("SALESAREA") or "").strip()
        channel_cat = (cats.get("channel") or "").strip()

        # Resolve territory_id. Prefer direct territory match on SALESAREA
        # value, fall back to state-code map.
        territory_id = None
        if salesarea:
            territory_id = terr_cache.get(salesarea.lower())
            if not territory_id:
                mapped = salesarea_to_territory.get(salesarea.upper())
                if mapped:
                    territory_id = terr_cache.get(mapped.lower())

        # Resolve channel_id from ContactCategory channel tag.
        channel_id = _map_vinsight_channel(channel_cat)

        # Resolve rep_id from DefaultSalesPersonNum via salesperson_code_map.
        sp_num = _int(d.get("DefaultSalesPersonNum"))
        rep_id = sp_num_to_rep.get(sp_num) if sp_num else None

        # BUG-165 (2026-05-12): embed NAME @ SUBURB form + resolve canonical
        # link BEFORE customer INSERT. L6 customer_must_have_canonical
        # (schema/162 NOT VALID) REJECTS INSERTs missing canonical_customer_id.
        # Mirrors etl/backfill_vinsight_contact_enrichment.py:128-180 (Faucet #2).
        warehouse_channel = _channel_id_to_warehouse(channel_id)
        embedded_name, cc_id = _resolve_canonical_for_customer_insert(
            cur, name, suburb, warehouse_channel, None, territory_id
        )

        # Upsert customer row — write enrichment ONLY if we have a value, and
        # only overwrite existing NULLs (COALESCE pattern).
        cur.execute("""
            INSERT INTO customer (
                customer_name, canonical_customer_id, suburb, postcode, rep_id, channel_id, territory_id, warehouse_channel
            )
            VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
            ON CONFLICT (customer_name) DO UPDATE SET
                canonical_customer_id = COALESCE(customer.canonical_customer_id, EXCLUDED.canonical_customer_id),
                suburb            = COALESCE(customer.suburb,            EXCLUDED.suburb),
                postcode          = COALESCE(customer.postcode,          EXCLUDED.postcode),
                rep_id            = COALESCE(customer.rep_id,            EXCLUDED.rep_id),
                channel_id        = COALESCE(customer.channel_id,        EXCLUDED.channel_id),
                territory_id      = COALESCE(customer.territory_id,      EXCLUDED.territory_id),
                warehouse_channel = COALESCE(customer.warehouse_channel, EXCLUDED.warehouse_channel),
                updated_at        = NOW()
        """, (embedded_name, cc_id, suburb, postcode, rep_id, channel_id, territory_id, warehouse_channel))

        if suburb:       enriched_suburb += 1
        if postcode:     enriched_postcode += 1
        if rep_id:       enriched_rep += 1
        if channel_id:   enriched_channel += 1
        if territory_id: enriched_territory += 1

        cur.execute("SELECT customer_id FROM customer WHERE customer_name = %s", (embedded_name,))
        row = cur.fetchone()
        if row:
            cur.execute("""
                INSERT INTO customer_code_map (customer_id, source_system, external_name)
                VALUES (%s, 'vinsight', %s)
                ON CONFLICT (source_system, external_name) DO NOTHING
            """, (row[0], name))
        cust_count += 1

    log.info(
        "  Vinsight: %d SKUs, %d customers "
        "(enriched: suburb=%d, postcode=%d, rep=%d, channel=%d, territory=%d)",
        vin_count, cust_count,
        enriched_suburb, enriched_postcode, enriched_rep,
        enriched_channel, enriched_territory,
    )
    return vin_count + cust_count


# ---------------------------------------------------------------------------
# Step 7b: Populate salesperson_code_map from staging_vinsight_contacts
# ---------------------------------------------------------------------------

def populate_salesperson_code_map(cur):
    """Build salesperson_code_map from staging_vinsight_contacts.

    A salesperson in Vinsight is any contact with IsSalesOperator=true OR
    IsEmployee=true. Their ContactCode (e.g. 'ADRIANMA', 'TMAULE') is the
    code referenced by DefaultSalesPersonCode on customer contacts, and
    ContactNum matches DefaultSalesPersonNum.

    Resolve to representative.rep_id via:
      1. Exact case-insensitive name match (FirstName + LastName, or LegalName)
      2. SP_CODE_REP_NAME_MAP manual override
      3. Auto-create a new representative row with rep_name = sp_code if the
         code still has no match. This keeps customer.rep_id fully populated
         for every customer with a non-null DefaultSalesPersonNum (acceptance
         criterion >=90%). The owner can later merge auto-created reps into
         existing ones via UPDATE.
    """
    cur.execute("""
        CREATE TABLE IF NOT EXISTS salesperson_code_map (
            sp_code     VARCHAR(50)  PRIMARY KEY,
            sp_num      INTEGER      UNIQUE,
            rep_id      INTEGER      REFERENCES representative(rep_id),
            sp_name     VARCHAR(200),
            source      VARCHAR(50)  NOT NULL DEFAULT 'vinsight',
            created_at  TIMESTAMP    NOT NULL DEFAULT NOW(),
            updated_at  TIMESTAMP    NOT NULL DEFAULT NOW()
        )
    """)

    # Load rep cache for fuzzy matching.
    rep_cache = {}
    cur.execute("SELECT rep_id, rep_name FROM representative")
    for rid, rname in cur.fetchall():
        rep_cache[rname.strip().lower()] = rid

    cur.execute("""
        SELECT DISTINCT ON (raw_data->>'ContactCode')
            raw_data->>'ContactCode' AS sp_code,
            raw_data->>'ContactNum' AS sp_num,
            raw_data->>'FirstName' AS first_name,
            raw_data->>'LastName' AS last_name,
            raw_data->>'LegalName' AS legal_name
        FROM staging_vinsight_contacts
        WHERE (raw_data->>'IsSalesOperator' = 'true'
               OR raw_data->>'IsEmployee' = 'true')
          AND raw_data->>'ContactCode' IS NOT NULL
          AND raw_data->>'ContactCode' != ''
        ORDER BY raw_data->>'ContactCode', synced_at DESC NULLS LAST
    """)

    mapped = 0
    auto_created = 0
    unmapped = 0
    for sp_code, sp_num_str, first_name, last_name, legal_name in cur.fetchall():
        sp_code = (sp_code or "").strip()
        sp_num = _int(sp_num_str)
        if not sp_code:
            continue

        # Build display name candidates for rep lookup.
        full_name = " ".join(
            p for p in [(first_name or "").strip(), (last_name or "").strip()] if p
        ).strip()
        candidates = [c for c in [legal_name, full_name, sp_code] if c]

        rep_id = None
        for cand in candidates:
            cand_norm = cand.strip().lower()
            if cand_norm in rep_cache:
                rep_id = rep_cache[cand_norm]
                break

        # Manual overrides for codes where rep_name doesn't tokenise cleanly.
        if not rep_id:
            override = SP_CODE_REP_NAME_MAP.get(sp_code.upper())
            if override:
                rep_id = rep_cache.get(override.lower())

        display_name = full_name or legal_name or sp_code

        # Auto-create rep row if still no match (flagged via Vinsight prefix
        # so it's easy to find in admin UI). The owner can later UPDATE rep_name
        # or merge duplicates.
        if not rep_id:
            auto_rep_name = f"(Vinsight) {sp_code}"
            cur.execute("""
                INSERT INTO representative (rep_name, active)
                VALUES (%s, true)
                ON CONFLICT (rep_name) DO NOTHING
                RETURNING rep_id
            """, (auto_rep_name,))
            r = cur.fetchone()
            if r:
                rep_id = r[0]
                rep_cache[auto_rep_name.strip().lower()] = rep_id
                auto_created += 1
            else:
                # ON CONFLICT didn't return — fetch existing
                cur.execute("SELECT rep_id FROM representative WHERE rep_name = %s",
                            (auto_rep_name,))
                r = cur.fetchone()
                if r:
                    rep_id = r[0]
                    rep_cache[auto_rep_name.strip().lower()] = rep_id

        cur.execute("""
            INSERT INTO salesperson_code_map (sp_code, sp_num, rep_id, sp_name)
            VALUES (%s, %s, %s, %s)
            ON CONFLICT (sp_code) DO UPDATE SET
                sp_num     = COALESCE(EXCLUDED.sp_num,     salesperson_code_map.sp_num),
                rep_id     = COALESCE(EXCLUDED.rep_id,     salesperson_code_map.rep_id),
                sp_name    = COALESCE(EXCLUDED.sp_name,    salesperson_code_map.sp_name),
                updated_at = NOW()
        """, (sp_code, sp_num, rep_id, display_name[:200] if display_name else None))

        if rep_id:
            mapped += 1
        else:
            unmapped += 1

    log.info(
        "  salesperson_code_map: %d rows (mapped=%d, auto_created=%d, unmapped=%d)",
        mapped + unmapped, mapped, auto_created, unmapped,
    )


# Manual overrides: Vinsight ContactCode -> representative.rep_name (case-
# insensitive match against rep table). Only needed for codes where the contact
# FirstName/LastName fields are empty and the code is a compact abbreviation.
# of staging_vinsight_contacts on the VPS.
#
# Codes commented with "CLARIFY" don't have a confident target in representative
# yet — the owner to confirm before we promote them from fall-through-NULL.
SP_CODE_REP_NAME_MAP = {
    # Example entries; the real code-to-rep mapping is environment data.
    "REPA": "Rep A",
    "REPB": "Rep B",
    "REPC": "Rep C",
}


def _build_salesperson_rep_cache(cur):
    """Return {sp_num: rep_id} built from salesperson_code_map. Cached."""
    if hasattr(_build_salesperson_rep_cache, "_cached"):
        return _build_salesperson_rep_cache._cached
    cur.execute("""
        SELECT sp_num, rep_id FROM salesperson_code_map
        WHERE sp_num IS NOT NULL AND rep_id IS NOT NULL
    """)
    cache = {sp_num: rep_id for sp_num, rep_id in cur.fetchall()}
    _build_salesperson_rep_cache._cached = cache
    return cache


# Attach cache_clear so callers can reset between runs.
def _build_salesperson_rep_cache_clear():
    if hasattr(_build_salesperson_rep_cache, "_cached"):
        del _build_salesperson_rep_cache._cached
_build_salesperson_rep_cache.cache_clear = _build_salesperson_rep_cache_clear


# ---------------------------------------------------------------------------
# Step 8: Populate from Xero staging
# ---------------------------------------------------------------------------

def populate_from_xero(cur):
    log.info("Populating from Xero staging contacts...")

    # Xero contacts -> customer + customer_code_map
    cur.execute("""
        SELECT DISTINCT contact_name, contact_id, tenant_id
        FROM staging_xero_contacts
        WHERE contact_name IS NOT NULL AND contact_name != ''
    """)
    rows = cur.fetchall()

    count = 0
    skipped_numeric = 0
    for contact_name, contact_id, tenant_id in rows:
        contact_name = contact_name.strip()
        if not contact_name:
            continue

        # BUG-88: reject numeric-only Xero contact names. These are EAN/account
        # codes leaking into the Name field (e.g. '012712684898279') and would
        # otherwise land as a junk customer row visible on /reference Customers.
        if contact_name.isdigit():
            skipped_numeric += 1
            log.warning(
                "Xero contact skipped: numeric-only name %r (tenant=%s, contact_id=%s)",
                contact_name, tenant_id, contact_id,
            )
            continue

        # BUG-165 (2026-05-12): resolve canonical link BEFORE customer INSERT.
        # L6 customer_must_have_canonical (schema/162 NOT VALID) REJECTS
        # INSERTs missing canonical_customer_id. Xero SELECT exposes only
        # contact_name at the top level — no suburb / city to embed and no
        # channel signal (Xero tenant != warehouse channel, per ADR-017).
        # Pass suburb=None / channel=None — helper falls back to bare name +
        # canonical_customer.territory_name = 'Unassigned'.
        embedded_name, cc_id = _resolve_canonical_for_customer_insert(
            cur, contact_name, None, None, None, None
        )

        cur.execute("""
            INSERT INTO customer (customer_name, canonical_customer_id)
            VALUES (%s, %s)
            ON CONFLICT (customer_name) DO UPDATE SET
                canonical_customer_id = COALESCE(customer.canonical_customer_id, EXCLUDED.canonical_customer_id)
        """, (embedded_name, cc_id))

        cur.execute("SELECT customer_id FROM customer WHERE customer_name = %s",
                    (embedded_name,))
        row = cur.fetchone()
        if row:
            cur.execute("""
                INSERT INTO customer_code_map (customer_id, source_system, external_name)
                VALUES (%s, 'xero', %s)
                ON CONFLICT (source_system, external_name) DO NOTHING
            """, (row[0], contact_name))
        count += 1

    log.info("  Xero: %d contacts processed (skipped %d numeric-only names)",
             count, skipped_numeric)
    return count


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    database_url = os.environ.get("DATABASE_URL")
    if not database_url:
        log.error("DATABASE_URL not set")
        sys.exit(1)

    conn = psycopg2.connect(database_url)
    conn.autocommit = False

    try:
        with conn.cursor() as cur:
            # Check if core tables need UNIQUE constraints for ON CONFLICT
            _ensure_constraints(cur)
            conn.commit()

            log.info("=" * 60)
            log.info("STARTING CORE TABLE TRANSFORM")
            log.info("=" * 60)

            # Step 1-2: Reference tables (Step 3 wine_range retired — see BUG-101 / ADR-010)
            t_count = populate_territory(cur)
            conn.commit()
            r_count = populate_representative(cur)
            conn.commit()

            # Step 4: SKU
            s_count = populate_sku(cur)
            conn.commit()

            # Step 5: Customer + customer_code_map
            c_count = populate_customer(cur)
            conn.commit()

            # Step 6: Sales transaction (120K rows)
            st_count = populate_sales_transaction(cur)
            conn.commit()

            # Step 7-8: Vinsight + Xero
            v_count = populate_from_vinsight(cur)
            conn.commit()
            x_count = populate_from_xero(cur)
            conn.commit()

            # Log the run
            cur.execute("""
                INSERT INTO etl_run_log (
                    source, endpoint, status, rows_processed,
                    started_at, completed_at, run_timestamp
                )
                VALUES ('transform', 'access+vinsight+xero→core', 'success', %s,
                        NOW(), NOW(), NOW())
            """, (t_count + r_count + s_count + c_count + st_count + v_count + x_count,))
            conn.commit()

            log.info("=" * 60)
            log.info("TRANSFORM COMPLETE")
            log.info("  Territories: %d", t_count)
            log.info("  Representatives: %d", r_count)
            log.info("  SKUs: %d", s_count)
            log.info("  Customers: %d", c_count)
            log.info("  Sales transactions: %d", st_count)
            log.info("  Vinsight items: %d", v_count)
            log.info("  Xero contacts: %d", x_count)
            log.info("=" * 60)

            # Print core table counts
            for table in ["territory", "representative", "sku",
                          "customer", "customer_code_map", "sku_code_map",
                          "sales_transaction"]:
                cur.execute(f"SELECT count(*) FROM {table}")
                log.info("  %s: %d rows", table, cur.fetchone()[0])

            # Data quality validation
            _validate_data_quality(cur)

    except Exception as e:
        conn.rollback()
        log.error("Transform failed: %s", e, exc_info=True)
        sys.exit(1)
    finally:
        conn.close()


def _validate_data_quality(cur):
    """Post-import validation: warn about values not in canonical reference tables."""
    log.info("Running data quality validation...")

    # Check regions not in region_ref
    cur.execute("""
        SELECT DISTINCT region FROM sku
        WHERE region IS NOT NULL
          AND region NOT IN (SELECT region_name FROM region_ref)
    """)
    bad_regions = [r[0] for r in cur.fetchall()]
    if bad_regions:
        log.warning("  UNKNOWN REGIONS in sku table: %s", bad_regions)
    else:
        log.info("  Regions: all values in canonical list")

    # Check varieties not in variety_ref
    cur.execute("""
        SELECT DISTINCT variety FROM sku
        WHERE variety IS NOT NULL
          AND variety NOT IN (SELECT variety_name FROM variety_ref)
    """)
    bad_varieties = [r[0] for r in cur.fetchall()]
    if bad_varieties:
        log.warning("  UNKNOWN VARIETIES in sku table: %s", bad_varieties)
    else:
        log.info("  Varieties: all values in canonical list")

    # Check NULL region/variety counts
    cur.execute("SELECT COUNT(*) FROM sku WHERE region IS NULL AND variety IS NOT NULL")
    null_region = cur.fetchone()[0]
    cur.execute("SELECT COUNT(*) FROM sku WHERE variety IS NULL")
    null_variety = cur.fetchone()[0]
    if null_region > 0:
        log.warning("  %d SKUs with NULL region (have variety)", null_region)
    if null_variety > 0:
        log.info("  %d SKUs with NULL variety (likely non-wine items)", null_variety)

    log.info("Data quality validation complete.")


def _ensure_constraints(cur):
    """Add UNIQUE constraints needed for ON CONFLICT if they don't exist."""
    constraints = [
        ("territory", "territory_name", "uq_territory_name",
         "ALTER TABLE territory ADD CONSTRAINT uq_territory_name UNIQUE (territory_name)"),
        ("representative", "rep_name", "uq_rep_name",
         "ALTER TABLE representative ADD CONSTRAINT uq_rep_name UNIQUE (rep_name)"),
        # wine_range entry retired 2026-04-23 (BUG-101 / ADR-010). ALTER TABLE
        # fails against the VIEW created by schema/051; uniqueness is now
        # enforced upstream by canonical_sku.range_name.
        ("sku", "sku_code", "uq_sku_code",
         "ALTER TABLE sku ADD CONSTRAINT uq_sku_code UNIQUE (sku_code)"),
        ("customer", "customer_name", "uq_customer_name",
         "ALTER TABLE customer ADD CONSTRAINT uq_customer_name UNIQUE (customer_name)"),
        ("customer_code_map", "(source_system, external_name)", "uq_customer_code_map_lookup",
         "ALTER TABLE customer_code_map ADD CONSTRAINT uq_customer_code_map_lookup UNIQUE (source_system, external_name)"),
        ("sku_code_map", "(source_system, external_code)", "uq_sku_code_map_lookup",
         "ALTER TABLE sku_code_map ADD CONSTRAINT uq_sku_code_map_lookup UNIQUE (source_system, external_code)"),
    ]

    for table, cols, constraint_name, alter_sql in constraints:
        cur.execute("""
            SELECT 1 FROM pg_constraint
            WHERE conname = %s
        """, (constraint_name,))
        if not cur.fetchone():
            try:
                cur.execute("SAVEPOINT pre_constraint")
                cur.execute(alter_sql)
                cur.execute("RELEASE SAVEPOINT pre_constraint")
                log.info("  Added constraint %s", constraint_name)
            except Exception as e:
                log.warning("  Could not add constraint %s: %s", constraint_name, e)
                cur.execute("ROLLBACK TO SAVEPOINT pre_constraint")


if __name__ == "__main__":
    main()
