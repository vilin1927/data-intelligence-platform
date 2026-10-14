"""
BUG-92 / Phase B2: ingest archived vintages from access_combined_data
into sku + sku_code_map so (canonical_sku, vintage) pairs present in
The owner's Access history that are NOT in Vinsight's current-stock view
become visible on /reference, /wines, and /margin.

schema/031_sku_vintage_from_staging.sql:7-15): Vinsight StockItems
only carries current-stock rows. Archived vintages that exist in
Access as sales history have no Vinsight counterpart, so they never
get an sku row, so Coppabella Rose (and ~128 other canonicals) shows
1 vintage on /reference even when Access holds 3+.

Fix = pure additive:
  1. Resolve canonical_sku_id by name match against canonical_sku.
  2. Derive vintage via regex on ItemDescription / ItemCode
     (mirrors etl/transform_to_core.py:_extract_vintage).
  3. INSERT missing (canonical_sku_id, vintage) pairs as new sku rows
     using the Access ItemCode as sku_code. ON CONFLICT DO NOTHING.
  4. INSERT sku_code_map(source_system='access', external_code=ItemCode)
     for every distinct (sku_id, ItemCode) pair in Access, so the
     access-canonical mapping is first-class rather than fuzzy-matched.

Safety:
  - One top-level transaction. Abort + rollback on any error.
  - No DELETE, no TRUNCATE, no UPDATE of existing rows.
  - ON CONFLICT (sku_code) DO NOTHING on sku insert.
  - ON CONFLICT (source_system, external_code) DO NOTHING on map insert.
    349 missing pairs, 0 CONFLICT, 0 silent-skip risk.

Usage:
    DATABASE_URL=postgresql://... python -m etl.ingest_access_vintages
"""

import logging
import os
import sys

import psycopg2

from etl.logger import log_etl_run

logger = logging.getLogger("moppity.etl.ingest_access_vintages")

SOURCE = "access_vintages"


# ---------------------------------------------------------------------------
# SQL — derive canonical_sku_id + vintage from access_combined_data JSONB
# ---------------------------------------------------------------------------
#
# Vintage extraction mirrors etl/transform_to_core.py:_extract_vintage:
#   1. 4-digit year (19xx|20xx) in ItemDescription
#   2. 4-digit year in ItemCode
#   3. 2-digit suffix at end of ItemCode mapped to 2015-2030 or 1990-1999
#
# Canonical match: UPPER(TRIM(access.SKU)) == UPPER(TRIM(canonical_sku.sku_name))
# — same join used by the pre-check script.

# B3-4 shape guard (2026-05-11): access_guarded CTE rejects ItemCode > 30 chars.
# schema/155 revert — description-text contamination caused vintage regex
# misfire (embedded years like "Pinot Noir 2018" matched as vintage 2018).
# All access raw_data->>'ItemCode' downstream of access_guarded uses the
# guarded column. Long-text rows surface as NULL → resolve as if empty.
ACCESS_PAIRS_SQL = r"""
WITH access_guarded AS (
    SELECT
        a.id,
        a.raw_data,
        CASE WHEN LENGTH(a.raw_data->>'ItemCode') <= 30
             THEN a.raw_data->>'ItemCode' END         AS item_code_raw
    FROM access_combined_data a
),
access_resolved AS (
    SELECT
        ag.id                                   AS access_row_id,
        cs.id                                   AS canonical_sku_id,
        cs.sku_name                             AS canonical_name,
        TRIM(COALESCE(ag.item_code_raw, ''))    AS item_code,
        TRIM(COALESCE(ag.raw_data->>'ItemDescription', '')) AS item_description,
        COALESCE(
            -- BUG-157 fix: outer capture group returns full 4-digit year
            -- (was '(19|20)\d{2}' which returned only the 19/20 prefix);
            -- lookbehind/lookahead (?<![0-9]) / (?![0-9]) prevents false
            -- matches inside numeric invoice IDs like '1946540' while still
            -- matching stuck-to-text years like 'Cabernet2018'.
            NULLIF(SUBSTRING(COALESCE(ag.raw_data->>'ItemDescription','')
                             FROM '(?<![0-9])(19[0-9]{2}|20[0-9]{2})(?![0-9])'), '')::INT,
            NULLIF(SUBSTRING(COALESCE(ag.item_code_raw,'')
                             FROM '(?<![0-9])(19[0-9]{2}|20[0-9]{2})(?![0-9])'), '')::INT,
            CASE
                WHEN SUBSTRING(COALESCE(ag.item_code_raw,'')
                               FROM '(\d{2})$') ~ '^[0-9]{2}$'
                 AND SUBSTRING(COALESCE(ag.item_code_raw,'')
                               FROM '(\d{2})$')::INT BETWEEN 15 AND 30
                  THEN 2000 + SUBSTRING(ag.item_code_raw
                                        FROM '(\d{2})$')::INT
                WHEN SUBSTRING(COALESCE(ag.item_code_raw,'')
                               FROM '(\d{2})$') ~ '^[0-9]{2}$'
                 AND SUBSTRING(COALESCE(ag.item_code_raw,'')
                               FROM '(\d{2})$')::INT BETWEEN 90 AND 99
                  THEN 1900 + SUBSTRING(ag.item_code_raw
                                        FROM '(\d{2})$')::INT
                ELSE NULL
            END
        )                                       AS vintage
    FROM access_guarded ag
    JOIN canonical_sku cs
      ON UPPER(TRIM(cs.sku_name)) = UPPER(TRIM(ag.raw_data->>'SKU'))
    WHERE ag.raw_data->>'SKU' IS NOT NULL
)
SELECT canonical_sku_id, canonical_name, vintage, item_code, item_description
FROM access_resolved
WHERE vintage IS NOT NULL
  AND item_code <> ''
"""


def ingest(conn) -> dict:
    """
    Run the full B2 ingest inside a single transaction.

    Returns stats dict with sku_inserted, map_inserted, pairs_seen, errors.
    """
    stats = {
        "pairs_seen":         0,
        "sku_inserted":       0,
        "sku_skipped_exists": 0,
        "map_inserted":       0,
        "map_skipped_exists": 0,
        "errors":             [],
    }

    with conn.cursor() as cur:
        logger.info("Reading access_combined_data with canonical + vintage resolution...")
        cur.execute(ACCESS_PAIRS_SQL)
        rows = cur.fetchall()
        stats["pairs_seen"] = len(rows)
        logger.info("  %d access rows resolve to (canonical_sku_id, vintage, item_code)", len(rows))

        # ------------------------------------------------------------------
        # Phase A: INSERT missing (canonical_sku_id, vintage) as new sku rows
        # ------------------------------------------------------------------
        # We group by (canonical_sku_id, vintage) and pick ONE item_code
        # (MIN lexically for determinism) to serve as the sku_code for the
        # new sku row.  ON CONFLICT (sku_code) DO NOTHING handles the case
        # where the chosen item_code is already present under another
        # canonical (pre-check said 0 collisions but keep the guard).
        missing_pairs = {}
        for canonical_id, canonical_name, vintage, item_code, item_desc in rows:
            key = (canonical_id, vintage)
            existing = missing_pairs.get(key)
            if existing is None or item_code < existing["item_code"]:
                missing_pairs[key] = {
                    "canonical_name":   canonical_name,
                    "item_code":        item_code,
                    "item_description": item_desc,
                }

        logger.info("Phase A: inserting missing (canonical_sku_id, vintage) sku rows...")
        for (canonical_id, vintage), meta in missing_pairs.items():
            # Only insert if NO sku row exists for this (canonical, vintage).
            cur.execute("""
                SELECT 1 FROM sku
                WHERE canonical_sku_id = %s AND vintage = %s
                LIMIT 1
            """, (canonical_id, vintage))
            if cur.fetchone():
                stats["sku_skipped_exists"] += 1
                continue

            cur.execute("""
                INSERT INTO sku (sku_code, item_description, vintage,
                                 canonical_sku_id, created_at, updated_at)
                VALUES (%s, %s, %s, %s, NOW(), NOW())
                ON CONFLICT (sku_code) DO NOTHING
                RETURNING sku_id
            """, (
                meta["item_code"],
                meta["item_description"] or meta["canonical_name"],
                vintage,
                canonical_id,
            ))
            result = cur.fetchone()
            if result:
                stats["sku_inserted"] += 1
            else:
                # sku_code collision - sku_id already exists under another
                # (canonical, vintage).  Pre-check verified this is 0, but
                # count defensively so a future data-shape change surfaces.
                stats["sku_skipped_exists"] += 1

        logger.info("  sku rows inserted=%d, skipped (already present)=%d",
                    stats["sku_inserted"], stats["sku_skipped_exists"])

        # ------------------------------------------------------------------
        # Phase B: INSERT sku_code_map(source_system='access', external_code)
        # ------------------------------------------------------------------
        # For every distinct Access ItemCode, add a map entry so Access
        # becomes first-class in canonical reconciliation (BUG-89 / BUG-94
        # premise).  The sku_id lookup resolves via:
        #   1. sku.sku_code == item_code (direct match after Phase A)
        #   2. else: find any sku with canonical_sku_id matching this Access
        #      row's canonical (vintage-independent fallback for rows where
        #      vintage regex failed)
        #
        # Phase B covers ALL rows, not just missing-pair ones, so existing
        # Vinsight-shared codes also get an access-source entry pointing
        # at the same sku_id.  ON CONFLICT prevents double-insert.
        logger.info("Phase B: populating sku_code_map with source_system='access'...")

        # Re-read a superset (no vintage filter) so rows with missing
        # vintage still contribute access-source map entries for their
        # canonical.
        cur.execute(r"""
            -- B3-4 shape guard (2026-05-11): LENGTH <= 30. schema/155.
            SELECT DISTINCT
                cs.id AS canonical_sku_id,
                TRIM(a.raw_data->>'ItemCode') AS item_code
            FROM access_combined_data a
            JOIN canonical_sku cs
              ON UPPER(TRIM(cs.sku_name)) = UPPER(TRIM(a.raw_data->>'SKU'))
            WHERE a.raw_data->>'SKU'      IS NOT NULL
              AND a.raw_data->>'ItemCode' IS NOT NULL
              AND TRIM(a.raw_data->>'ItemCode') <> ''
              AND LENGTH(a.raw_data->>'ItemCode') <= 30
        """)
        access_codes = cur.fetchall()
        logger.info("  %d distinct (canonical_sku_id, item_code) pairs to map", len(access_codes))

        for canonical_id, item_code in access_codes:
            # Prefer a sku row with matching sku_code.  Fall back to any
            # sku under this canonical (lowest sku_id for determinism).
            cur.execute("SELECT sku_id FROM sku WHERE sku_code = %s", (item_code,))
            hit = cur.fetchone()
            if not hit:
                cur.execute("""
                    SELECT sku_id FROM sku
                    WHERE canonical_sku_id = %s
                    ORDER BY sku_id
                    LIMIT 1
                """, (canonical_id,))
                hit = cur.fetchone()
            if not hit:
                stats["errors"].append(
                    f"No sku row to map access code {item_code} "
                    f"under canonical_sku_id={canonical_id}"
                )
                continue

            sku_id = hit[0]
            cur.execute("""
                INSERT INTO sku_code_map (sku_id, source_system, external_code)
                VALUES (%s, 'access', %s)
                ON CONFLICT (source_system, external_code) DO NOTHING
                RETURNING map_id
            """, (sku_id, item_code))
            if cur.fetchone():
                stats["map_inserted"] += 1
            else:
                stats["map_skipped_exists"] += 1

        logger.info("  sku_code_map rows inserted=%d, skipped (already present)=%d",
                    stats["map_inserted"], stats["map_skipped_exists"])

    return stats


def main():
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    )

    db_url = os.environ.get("DATABASE_URL")
    if not db_url:
        print("ERROR: DATABASE_URL environment variable is not set.", file=sys.stderr)
        sys.exit(1)

    conn = psycopg2.connect(db_url)

    try:
        print("\n" + "=" * 60)
        print("BUG-92 Phase B2: Ingest archived vintages from Access")
        print("=" * 60)

        stats = ingest(conn)

        conn.commit()

        print("\nResults:")
        print(f"  Access rows resolved:       {stats['pairs_seen']}")
        print(f"  sku rows inserted:          {stats['sku_inserted']}")
        print(f"  sku rows skipped (exists):  {stats['sku_skipped_exists']}")
        print(f"  sku_code_map inserted:      {stats['map_inserted']}")
        print(f"  sku_code_map skipped:       {stats['map_skipped_exists']}")
        print(f"  errors:                     {len(stats['errors'])}")
        if stats["errors"]:
            for err in stats["errors"][:10]:
                print(f"    - {err}")

        status = "success" if not stats["errors"] else "partial"
        log_etl_run(
            conn,
            source=SOURCE,
            endpoint="access_combined_data -> sku + sku_code_map",
            status=status,
            rows_processed=stats["sku_inserted"] + stats["map_inserted"],
            rows_skipped=stats["sku_skipped_exists"] + stats["map_skipped_exists"],
            error_count=len(stats["errors"]),
            error_detail="\n".join(stats["errors"][:50]) if stats["errors"] else None,
        )

        print("\n" + "=" * 60)
        print("DONE")
        print("=" * 60 + "\n")

    except Exception as exc:
        conn.rollback()
        print(f"FATAL: {exc}", file=sys.stderr)
        try:
            log_etl_run(
                conn, source=SOURCE,
                endpoint="access_combined_data -> sku + sku_code_map",
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
