"""
B6a / JC-105 + JC-104: DWS new-vintage auto-detection.

Given an unmapped DWS code (e.g. "MOLKSH22F"), parse it as
    prefix + variety_code + vintage_yy + optional packaging suffix
and look up the prefix+variety against canonical_sku_code_map for
source_system='dws'. If a match exists at a different vintage, this is a
new-vintage variant of the same canonical product → INSERT a new row into
canonical_sku_code_map sharing the same canonical_sku_id.

DWS code grammar (the owner Mar 24 / JC-104):
    MO[A-Z]+[0-9]{2}[A-Z]?
        MO     — Moppity vendor prefix
        [A-Z]+ — variety/range mnemonic (LKSH = Lock & Key Shiraz, etc.)
        [0-9]{2} — vintage year (last two digits)
        [A-Z]?  — optional packaging suffix (F = full case, P = piccolo, etc.)

This script is idempotent. Re-running with the same code is a no-op (ON
CONFLICT DO NOTHING via the canonical_sku_code_map UNIQUE
(canonical_sku_id, external_code) constraint
canonical_sku_code_map_canonical_code_uniq, added by schema/173 on
2026-05-13 (PHASE1-CLOSE-B1-CSCM-DEDUP). Earlier UNIQUE
(source_system, external_code) from schema/012 was DROPPED by schema/173;
do NOT reintroduce as the ON CONFLICT target here.

Usage (one code at a time, mainly called by upload pipeline):
    DATABASE_URL=postgresql://... python -m etl.dws_new_vintage_detect MOLKSH22F

Returns process exit 0 = mapped (existing or new), 1 = no canonical match.

"""

import logging
import os
import re
import sys
from typing import Optional

import psycopg2

logger = logging.getLogger("moppity.etl.dws_new_vintage_detect")

DWS_CODE_RE = re.compile(r"^(?P<prefix>MO[A-Z]+?)(?P<vintage>[0-9]{2})(?P<suffix>[A-Z]?)$")


def parse_dws_code(code: str) -> Optional[dict]:
    """Parse a DWS code into (prefix, vintage_yy, suffix). Returns None on miss."""
    if not code:
        return None
    m = DWS_CODE_RE.match(code.strip().upper())
    if not m:
        return None
    return {
        "prefix":  m.group("prefix"),   # e.g. MOLKSH
        "vintage": int(m.group("vintage")),  # e.g. 22  -> caller can prepend 20
        "suffix":  m.group("suffix") or "",  # e.g. F
        "raw":     code.strip().upper(),
    }


def find_canonical_for_prefix(conn, prefix: str, suffix: str) -> Optional[int]:
    """Look up canonical_sku_id for any DWS external code that shares the same
    prefix+suffix. The first hit wins — by design DWS uses one code per
    prefix+vintage+suffix and they all collapse to the same canonical product.
    """
    pattern = f"{prefix}__{suffix}" if suffix else f"{prefix}__"
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT canonical_sku_id, external_code
              FROM canonical_sku_code_map
             WHERE source_system = 'dws'
               AND external_code LIKE %s
             ORDER BY external_code
             LIMIT 1
            """,
            (pattern,),
        )
        row = cur.fetchone()
        return row[0] if row else None


def insert_new_vintage(conn, canonical_sku_id: int, new_code: str) -> bool:
    """INSERT new DWS external_code with confidence 0.85 (auto-detected, not
    operator-confirmed). Returns True if a new row was inserted, False if the
    code already existed.
    """
    with conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO canonical_sku_code_map
                (canonical_sku_id, source_system, external_code, confidence, notes)
            VALUES (%s, 'dws', %s, 0.85, %s)
            ON CONFLICT (canonical_sku_id, external_code) DO NOTHING
            RETURNING id
            """,
            (
                canonical_sku_id,
                new_code,
                f"auto-detected new-vintage variant by dws_new_vintage_detect.py",
            ),
        )
        return cur.fetchone() is not None


def detect_and_map(conn, code: str) -> dict:
    """Parse `code`, look up canonical, INSERT mapping if new.

    Returns:
        {"status": "mapped"|"new"|"no_match"|"invalid", "canonical_sku_id": int|None}
    """
    parsed = parse_dws_code(code)
    if not parsed:
        return {"status": "invalid", "canonical_sku_id": None, "code": code}

    canonical_id = find_canonical_for_prefix(conn, parsed["prefix"], parsed["suffix"])
    if canonical_id is None:
        return {"status": "no_match", "canonical_sku_id": None, "code": code}

    try:
        was_new = insert_new_vintage(conn, canonical_id, parsed["raw"])
        conn.commit()
    except Exception:
        conn.rollback()
        raise

    return {
        "status": "new" if was_new else "mapped",
        "canonical_sku_id": canonical_id,
        "code": parsed["raw"],
    }


def main():
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    )
    if len(sys.argv) < 2:
        print("Usage: python -m etl.dws_new_vintage_detect <DWS_CODE>", file=sys.stderr)
        sys.exit(2)
    code = sys.argv[1]

    db_url = os.environ.get("DATABASE_URL")
    if not db_url:
        print("ERROR: DATABASE_URL not set.", file=sys.stderr)
        sys.exit(1)

    conn = psycopg2.connect(db_url)
    try:
        result = detect_and_map(conn, code)
        print(f"{result['status']}: {result['code']} -> canonical_sku_id={result['canonical_sku_id']}")
        sys.exit(0 if result["status"] in ("mapped", "new") else 1)
    finally:
        conn.close()


if __name__ == "__main__":
    main()
