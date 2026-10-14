"""
Seed vineyard_region and region_lookup from Vinsight.

Part of JF-07: replaces the regex-on-batch-code region derivation with a
real read from Vinsight. This script populates two lookup tables used by
etl/sync_composition_from_staging.py:

  1. region_lookup(region_code PK, region_description)
     Sourced from GET /Regions.json. Keyed on the 2-char region code that
     appears as the suffix of every Moppity batch code (e.g. 'TU' in
     '24PINCOP13LKTU').

  2. vineyard_region(vineyard_code PK, vineyard_description, region_code,
     region_description)
     Sourced from GET /Blocks.json?$expand=Vineyard. The /Vineyards.json
     endpoint alone is sparse (only 4 active records). /Blocks.json exposes
     the full active vineyard set including COP, MOP, WER, CAN, etc.

Usage:
    DATABASE_URL=postgresql://... VINSIGHT_API_KEY=... python -m etl.seed_vineyard_region
"""

import logging
import os
import sys
import time
from typing import Any

import psycopg2
import requests

logger = logging.getLogger("moppity.etl.seed_vineyard_region")

BASE_URL = "https://app.vinsight.net"
MAX_RETRIES = 3
BACKOFF_SECONDS = [1, 2, 4]


def api_get(session: requests.Session, api_key: str, endpoint: str,
            expand: str | None = None, top: int = 9999) -> Any:
    """GET against Vinsight with retry. Returns parsed JSON or None."""
    url = f"{BASE_URL}{endpoint}?api-key={api_key}&$top={top}"
    if expand:
        url += f"&$expand={expand}"

    log_url = url.replace(api_key, "***")
    logger.info("GET %s", log_url)

    for attempt in range(MAX_RETRIES):
        try:
            resp = session.get(url, timeout=30, allow_redirects=True)
            if resp.status_code == 200:
                return resp.json()
            if resp.status_code == 429 or resp.status_code >= 500:
                backoff = BACKOFF_SECONDS[min(attempt, len(BACKOFF_SECONDS) - 1)]
                logger.warning("HTTP %d (attempt %d/%d). Retry in %ds.",
                               resp.status_code, attempt + 1, MAX_RETRIES, backoff)
                time.sleep(backoff)
                continue
            logger.error("HTTP %d from %s: %s",
                         resp.status_code, endpoint, resp.text[:300])
            return None
        except requests.RequestException as exc:
            backoff = BACKOFF_SECONDS[min(attempt, len(BACKOFF_SECONDS) - 1)]
            logger.warning("Request error (attempt %d/%d): %s. Retry in %ds.",
                           attempt + 1, MAX_RETRIES, exc, backoff)
            time.sleep(backoff)

    logger.error("All %d retries exhausted for %s", MAX_RETRIES, endpoint)
    return None


def seed_region_lookup(cursor, session: requests.Session, api_key: str) -> int:
    """Upsert region_lookup rows from /Regions.json."""
    data = api_get(session, api_key, "/Regions.json", top=200)
    if data is None:
        raise RuntimeError("Failed to fetch /Regions.json")

    records = data if isinstance(data, list) else data.get("List", [])
    upserts = 0
    for r in records:
        region_code = r.get("RegionCode")
        description = r.get("Description")
        # Skip malformed rows where both are null or where description is null
        # (Vinsight returns some duplicate/stub rows like "Hilltops"|None).
        if not region_code or not description:
            continue
        # Only accept 2-char codes (the canonical form used in batch-code
        # suffixes). The malformed dup rows use the description string as
        # the code (e.g. "Hilltops" as RegionCode) — reject those.
        if len(region_code) > 4:
            logger.debug("Skipping malformed region row: code=%r desc=%r",
                         region_code, description)
            continue
        cursor.execute(
            """
            INSERT INTO region_lookup (region_code, region_description, last_synced)
            VALUES (%s, %s, NOW())
            ON CONFLICT (region_code) DO UPDATE SET
                region_description = EXCLUDED.region_description,
                last_synced = EXCLUDED.last_synced
            """,
            (region_code, description),
        )
        upserts += 1
    logger.info("region_lookup upserts: %d", upserts)
    return upserts


def seed_vineyard_region(cursor, session: requests.Session, api_key: str) -> int:
    """Upsert vineyard_region from /Blocks.json?$expand=Vineyard."""
    data = api_get(session, api_key, "/Blocks.json", expand="Vineyard")
    if data is None:
        raise RuntimeError("Failed to fetch /Blocks.json")

    records = data if isinstance(data, list) else data.get("List", [])

    # Collapse by vineyard_code (a vineyard can have multiple blocks).
    seen: dict[str, dict[str, Any]] = {}
    for b in records:
        v = b.get("Vineyard") or {}
        if not isinstance(v, dict):
            continue
        vc = v.get("VineyardCode")
        if not vc:
            continue
        vdesc = v.get("Description")
        rcode = v.get("RegionCode")
        if vc not in seen:
            seen[vc] = {"vineyard_description": vdesc, "region_code": rcode}

    # Resolve region_description from region_lookup for each entry
    upserts = 0
    for vc, info in seen.items():
        rcode = info["region_code"]
        # Resolve via region_lookup if region_code is a known 2-char code.
        # Some vineyards have RegionCode as a description string
        # (e.g. MIN has "Tumbarumba" as RegionCode) — those won't join.
        region_desc = None
        if rcode:
            cursor.execute(
                "SELECT region_description FROM region_lookup WHERE region_code = %s",
                (rcode,),
            )
            row = cursor.fetchone()
            if row:
                region_desc = row[0]
            elif len(rcode) > 4:
                # Malformed: description stored in region_code slot.
                region_desc = rcode
                rcode = None

        # If region_code is set but has no FK target in region_lookup, null
        # it out so the FK constraint holds. Also record the description we
        # derived so we don't lose information.
        if rcode:
            cursor.execute(
                "SELECT 1 FROM region_lookup WHERE region_code = %s",
                (rcode,),
            )
            if not cursor.fetchone():
                rcode = None

        cursor.execute(
            """
            INSERT INTO vineyard_region (
                vineyard_code, vineyard_description,
                region_code, region_description, last_synced
            )
            VALUES (%s, %s, %s, %s, NOW())
            ON CONFLICT (vineyard_code) DO UPDATE SET
                vineyard_description = EXCLUDED.vineyard_description,
                region_code = EXCLUDED.region_code,
                region_description = EXCLUDED.region_description,
                last_synced = EXCLUDED.last_synced
            """,
            (vc, info["vineyard_description"], rcode, region_desc),
        )
        upserts += 1

    logger.info("vineyard_region upserts: %d", upserts)
    return upserts


def main() -> int:
    api_key = os.environ.get("VINSIGHT_API_KEY")
    database_url = os.environ.get("DATABASE_URL")
    if not api_key:
        print("ERROR: VINSIGHT_API_KEY not set", file=sys.stderr)
        return 1
    if not database_url:
        print("ERROR: DATABASE_URL not set", file=sys.stderr)
        return 1

    conn = psycopg2.connect(database_url)
    conn.autocommit = False
    session = requests.Session()

    try:
        with conn.cursor() as cur:
            regions_count = seed_region_lookup(cur, session, api_key)
            vineyards_count = seed_vineyard_region(cur, session, api_key)
        conn.commit()
        print("=" * 60)
        print("seed_vineyard_region complete")
        print(f"  region_lookup rows:   {regions_count}")
        print(f"  vineyard_region rows: {vineyards_count}")
        print("=" * 60)
        return 0
    except Exception as exc:
        conn.rollback()
        logger.error("seed failed: %s", exc)
        return 2
    finally:
        session.close()
        conn.close()


if __name__ == "__main__":
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )
    sys.exit(main())
