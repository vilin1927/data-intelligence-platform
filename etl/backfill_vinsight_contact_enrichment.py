"""
Backfill Vinsight Contact enrichment fields onto customer table.

BUG-34 fix. The existing transform_to_core.py Vinsight Contacts loop ignored
PhysicalCity, PhysicalPostCode, DefaultSalesPersonNum, ContactCategory SALESAREA
and channel. As a result customer.suburb/postcode/rep_id/channel_id are at 0.02%
coverage. This script reads staging_vinsight_contacts and writes the enrichment
values without re-running the full transform.

Safe to run repeatedly — uses COALESCE so existing values are never clobbered.

Usage:
    DATABASE_URL="postgresql://localhost/moppity_db" \\
        python3 etl/backfill_vinsight_contact_enrichment.py
"""

from __future__ import annotations

import json
import logging
import os
import sys

import psycopg2

from etl.transform_to_core import (
    _build_salesperson_rep_cache,
    _channel_id_to_warehouse,
    _int,
    _map_vinsight_channel,
    _parse_contact_category,
    populate_salesperson_code_map,
)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
log = logging.getLogger("backfill_vinsight_contact_enrichment")


# Mirror of salesarea_to_territory in populate_from_vinsight so this script is
# self-contained.
SALESAREA_TO_TERRITORY = {
    "NSW": "NSW Sydney CBD",
    "VIC": "VIC Melbourne CBD",
    "QLD": "Queensland Metro",
    "WA":  "WA Metro",
    "SA":  "SA Metro",
    "NT":  "NT",
    "TAS": "TAS",
    "ACT": "ACT on premise",
    "HEAD": "Head Office",
}


def backfill(cur) -> dict[str, int]:
    """Apply enrichment from staging_vinsight_contacts to customer rows.

    Returns a dict of counts useful for verification.
    """
    # Step 1: populate salesperson_code_map from staging.
    populate_salesperson_code_map(cur)
    _build_salesperson_rep_cache.cache_clear()
    sp_num_to_rep = _build_salesperson_rep_cache(cur)
    log.info("  sp_num -> rep_id cache size: %d", len(sp_num_to_rep))

    # Step 2: load territory cache.
    # BUG-165 (2026-05-12): also build reverse id->name map for
    # canonical_customer.territory_name derive (L6 constraint
    # canonical_customer_must_have_territory in schema/162:120 REJECTS NULL
    # territory_name on new inserts). customer.territory_id REFERENCES
    # territory(territory_id) (schema/001:128); canonical_customer.territory_name
    # is a STRING (schema/012:75) — derive from id->name lookup.
    terr_cache: dict[str, int] = {}
    terr_id_to_name: dict[int, str] = {}
    cur.execute("SELECT territory_id, territory_name FROM territory")
    for tid, tname in cur.fetchall():
        terr_cache[tname.lower()] = tid
        terr_id_to_name[tid] = tname
    log.info("  territory cache size: %d", len(terr_cache))

    # Step 3: fetch latest snapshot per contact (debtors only).
    cur.execute("""
        SELECT DISTINCT ON (raw_data->>'ContactCode') raw_data
        FROM staging_vinsight_contacts
        WHERE raw_data->>'ContactCode' IS NOT NULL
          AND raw_data->>'ContactCode' != ''
          AND raw_data->>'IsDebtor' = 'true'
        ORDER BY raw_data->>'ContactCode', synced_at DESC NULLS LAST
    """)
    rows = cur.fetchall()
    log.info("  fetched %d distinct debtor contacts from staging", len(rows))

    counters = {
        "total": 0,
        "matched_customer": 0,
        "no_customer": 0,
        "set_suburb": 0,
        "set_postcode": 0,
        "set_rep": 0,
        "set_channel": 0,
        "set_territory": 0,
    }

    for (raw,) in rows:
        d = raw if isinstance(raw, dict) else json.loads(raw)
        name = (d.get("ContactCode") or "").strip()
        if not name:
            continue
        counters["total"] += 1

        suburb = (d.get("PhysicalCity") or "").strip() or None
        postcode = (d.get("PhysicalPostCode") or "").strip() or None

        cats = _parse_contact_category(d.get("ContactCategory") or "")
        salesarea = (cats.get("SALESAREA") or "").strip()
        channel_cat = (cats.get("channel") or "").strip()

        territory_id = None
        if salesarea:
            territory_id = terr_cache.get(salesarea.lower())
            if not territory_id:
                mapped = SALESAREA_TO_TERRITORY.get(salesarea.upper())
                if mapped:
                    territory_id = terr_cache.get(mapped.lower())

        channel_id = _map_vinsight_channel(channel_cat)
        # BUG-127: denormalize channel_id to warehouse_channel string at write
        # site so the customer.warehouse_channel invariant holds without a trigger.
        warehouse_channel = _channel_id_to_warehouse(channel_id)
        sp_num = _int(d.get("DefaultSalesPersonNum"))
        rep_id = sp_num_to_rep.get(sp_num) if sp_num else None

        # Skip if there's absolutely nothing to enrich.
        if not any([suburb, postcode, rep_id, channel_id, territory_id]):
            continue

        # BUG-165 (2026-05-12): embed NAME @ SUBURB form on writes. Bare-name
        # writes are a faucet producing orphan customers + bare/at-form twin
        # pairs (schema/161 dedup migration). Embedded form preserves uniqueness
        # across cities + matches schema/060 line 107 legacy access-DB convention.
        embedded_name = (
            f"{name} @ {suburb.upper().strip()}"
            if suburb and " @ " not in name
            else name
        )

        # BUG-165 (2026-05-12): resolve canonical_customer_id via lookup-or-create
        # BEFORE the customer INSERT. L6 constraint customer_must_have_canonical
        # (schema/162 NOT VALID; future schema/163 VALIDATE) requires every new
        # customer row to carry a canonical link. Auto-create canonical when no
        # match — uses embedded NAME @ SUBURB form so canonical_customer.customer_name
        # UNIQUE constraint (schema/012:71) holds.
        #
        # BUG-165 territory derive (2026-05-12): L6 constraint
        # canonical_customer_must_have_territory (schema/162:120, NOT VALID;
        # future schema/163 VALIDATE) REJECTS new inserts with
        # territory_name IS NULL. canonical_customer.territory_name is a STRING
        # (schema/012:75) — derive from the resolved territory_id via
        # terr_id_to_name lookup. When territory_id is missing/unresolved, bake
        # 'Unassigned' (conservative default per
        # The owner review; do not block the write).
        resolved_territory_name = "Unassigned"
        if territory_id:
            resolved_territory_name = terr_id_to_name.get(territory_id, "Unassigned")
            if resolved_territory_name == "Unassigned":
                log.warning(
                    "  territory_id=%s for contact '%s' not found in territory table — "
                    "falling back to 'Unassigned' for canonical_customer.territory_name",
                    territory_id, name,
                )

        cur.execute(
            "SELECT id FROM canonical_customer WHERE LOWER(customer_name) = LOWER(%s) LIMIT 1",
            (embedded_name,),
        )
        cc_row = cur.fetchone()
        if cc_row:
            canonical_customer_id = cc_row[0]
        else:
            # ON CONFLICT no-op upsert fires RETURNING without overwriting an
            # existing row's territory_name — territory_name = EXCLUDED.territory_name
            # is deliberately omitted from the DO UPDATE SET clause so prior
            # data wins. Same idempotent pattern as before.
            cur.execute(
                """
                INSERT INTO canonical_customer (customer_name, channel, territory_name)
                VALUES (%s, %s, %s)
                ON CONFLICT (customer_name) DO UPDATE SET customer_name = EXCLUDED.customer_name
                RETURNING id
                """,
                (embedded_name, warehouse_channel, resolved_territory_name),
            )
            canonical_customer_id = cur.fetchone()[0]

        # Upsert — create row if missing (should not happen since ETL already
        # ran, but safe), and only fill NULLs via COALESCE.
        # BUG-165: name = embedded form, canonical_customer_id SET. ON CONFLICT
        # target = embedded_name (same as INSERT column value), preserving
        # idempotent behaviour for repeat runs.
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
            RETURNING customer_id
        """, (embedded_name, canonical_customer_id, suburb, postcode, rep_id, channel_id, territory_id, warehouse_channel))
        row = cur.fetchone()
        if row:
            counters["matched_customer"] += 1
        else:
            counters["no_customer"] += 1

        if suburb:       counters["set_suburb"] += 1
        if postcode:     counters["set_postcode"] += 1
        if rep_id:       counters["set_rep"] += 1
        if channel_id:   counters["set_channel"] += 1
        if territory_id: counters["set_territory"] += 1

    return counters


def verify(cur) -> dict[str, float]:
    """Return coverage metrics under two denominators.

    Scope A — "Vinsight customers currently in staging" (3,130-ish): the honest
    population matching B2 audit's CSV row count. This is what the acceptance

    Scope B — "any customer ever tagged vinsight via customer_code_map": includes
    historical contacts that Vinsight no longer returns. Reported for
    transparency — we can't enrich rows whose staging data vanished.
    """
    # Scope A: customers whose name appears in current staging_vinsight_contacts
    # (IsDebtor=true). This is the source-of-truth population.
    cur.execute("""
        WITH staging_names AS (
            SELECT DISTINCT raw_data->>'ContactCode' AS name
            FROM staging_vinsight_contacts
            WHERE raw_data->>'IsDebtor' = 'true'
              AND raw_data->>'ContactCode' IS NOT NULL
              AND raw_data->>'ContactCode' != ''
        )
        SELECT
            COUNT(*)                                                AS total,
            COUNT(*) FILTER (WHERE c.suburb       IS NOT NULL)      AS s,
            COUNT(*) FILTER (WHERE c.postcode     IS NOT NULL)      AS p,
            COUNT(*) FILTER (WHERE c.rep_id       IS NOT NULL)      AS r,
            COUNT(*) FILTER (WHERE c.channel_id   IS NOT NULL)      AS ch,
            COUNT(*) FILTER (WHERE c.territory_id IS NOT NULL)      AS t
        FROM customer c
        JOIN staging_names sn ON sn.name = c.customer_name
    """)
    total_a, s_a, p_a, r_a, ch_a, t_a = cur.fetchone()

    # Scope B: ever-tagged in customer_code_map
    cur.execute("""
        WITH vin AS (
            SELECT DISTINCT c.customer_id,
                            c.suburb, c.postcode, c.rep_id,
                            c.channel_id, c.territory_id
            FROM customer c
            JOIN customer_code_map m
              ON m.customer_id = c.customer_id
             AND m.source_system = 'vinsight'
        )
        SELECT
            COUNT(*)                                                AS total,
            COUNT(*) FILTER (WHERE suburb       IS NOT NULL)        AS s,
            COUNT(*) FILTER (WHERE postcode     IS NOT NULL)        AS p,
            COUNT(*) FILTER (WHERE rep_id       IS NOT NULL)        AS r,
            COUNT(*) FILTER (WHERE channel_id   IS NOT NULL)        AS ch,
            COUNT(*) FILTER (WHERE territory_id IS NOT NULL)        AS t
        FROM vin
    """)
    total_b, s_b, p_b, r_b, ch_b, t_b = cur.fetchone()

    def pct(n, d):
        return round(100.0 * n / d, 2) if d else 0.0

    return {
        "scope_A_current_staging": {
            "total":         total_a,
            "suburb_pct":    pct(s_a, total_a),
            "postcode_pct":  pct(p_a, total_a),
            "rep_pct":       pct(r_a, total_a),
            "channel_pct":   pct(ch_a, total_a),
            "territory_pct": pct(t_a, total_a),
        },
        "scope_B_ever_tagged": {
            "total":         total_b,
            "suburb_pct":    pct(s_b, total_b),
            "postcode_pct":  pct(p_b, total_b),
            "rep_pct":       pct(r_b, total_b),
            "channel_pct":   pct(ch_b, total_b),
            "territory_pct": pct(t_b, total_b),
        },
    }


def main() -> int:
    database_url = os.environ.get("DATABASE_URL")
    if not database_url:
        log.error("DATABASE_URL not set")
        return 1

    conn = psycopg2.connect(database_url)
    conn.autocommit = False
    try:
        with conn.cursor() as cur:
            log.info("=" * 60)
            log.info("BUG-34 BACKFILL: Vinsight contact enrichment")
            log.info("=" * 60)
            counters = backfill(cur)
            conn.commit()
            log.info("Backfill counters: %s", counters)
            metrics = verify(cur)
            log.info("Post-backfill Vinsight customer coverage: %s", metrics)

        # Print JSON line for machine-readable CI/verification pipelines.
        import json as _json
        print(_json.dumps({"counters": counters, "verify": metrics}, default=str))
        return 0
    except Exception as exc:
        conn.rollback()
        log.exception("Backfill failed: %s", exc)
        return 1
    finally:
        conn.close()


if __name__ == "__main__":
    sys.exit(main())
