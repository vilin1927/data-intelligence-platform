"""
B6a / JC-106 + JC-134: Hierarchical pattern matching for unknown DWS/ALM codes.

Given an unknown external code, walk a four-level cascade and return
(canonical_sku_id, confidence, match_type) for the best hit. Caller decides
whether to auto-map (confidence >= 0.85), queue for operator review
(0.50–0.84), or reject (< 0.50).

Cascade:
    1. EXACT          (1.00) — code already in canonical_sku_code_map
    2. PREFIX_STRIP   (0.95) — strip leading "X-", "MO-", "MV-" then re-look up
                                 (handles JC-134: COCSCHAB16 vs X-COCSCHAB16)
    3. VINTAGE_STRIP  (0.85) — drop trailing 2-digit + optional letter then
                                 fall through to PREFIX_STRIP (handles
                                 vintage-rollover for codes that already exist
                                 at a different vintage)
    4. TOKEN_OVERLAP  (0.50–0.79) — token-overlap score against
                                      canonical_sku.sku_name; 60% coverage
                                      threshold + at least 2 matching words.
                                      Confidence scales with coverage.

Read-only by default — does NOT write to canonical_sku_code_map. Caller
(upload pipeline / B6b admin UI) decides the action.

Usage as module:
    from etl.sku_hierarchical_match import hierarchical_match
    result = hierarchical_match(conn, "X-COCSCHAB16", source_system="dws")
"""

import logging
import os
import re
import sys
from typing import Optional

import psycopg2

logger = logging.getLogger("moppity.etl.sku_hierarchical_match")

PREFIX_STRIP_RE = re.compile(r"^(X|MO|MV)-")
VINTAGE_STRIP_RE = re.compile(r"[0-9]{2}[A-Z]?$")


def _normalise(code: str) -> str:
    return (code or "").strip().upper()


def _exact(conn, code: str, source_system: str) -> Optional[int]:
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT m.canonical_sku_id
              FROM canonical_sku_code_map m
              JOIN canonical_sku cs
                ON cs.id = m.canonical_sku_id AND cs.is_active_canonical = true
             WHERE m.source_system = %s AND m.external_code = %s
             LIMIT 1
            """,
            (source_system, code),
        )
        row = cur.fetchone()
        return row[0] if row else None


def _prefix_strip(conn, code: str, source_system: str) -> Optional[int]:
    """Strip a single leading X-/MO-/MV- prefix and re-look up exact."""
    stripped = PREFIX_STRIP_RE.sub("", code, count=1)
    if stripped == code:
        return None
    return _exact(conn, stripped, source_system)


def _vintage_strip(conn, code: str, source_system: str) -> Optional[int]:
    """Drop trailing 2-digit + optional letter then look up by prefix-LIKE."""
    base = VINTAGE_STRIP_RE.sub("", code)
    if base == code or len(base) < 3:
        return None
    pattern = f"{base}%"
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT m.canonical_sku_id
              FROM canonical_sku_code_map m
              JOIN canonical_sku cs
                ON cs.id = m.canonical_sku_id AND cs.is_active_canonical = true
             WHERE m.source_system = %s AND m.external_code LIKE %s
             ORDER BY m.external_code
             LIMIT 1
            """,
            (source_system, pattern),
        )
        row = cur.fetchone()
        return row[0] if row else None


def _token_overlap(conn, code: str) -> tuple[Optional[int], float]:
    """Score `code` (treated as plain text) against every canonical_sku.sku_name."""
    code_words = [w for w in re.split(r"[^A-Z0-9]+", code) if len(w) >= 2]
    if not code_words:
        return None, 0.0

    with conn.cursor() as cur:
        cur.execute("SELECT id, UPPER(sku_name) FROM canonical_sku WHERE is_active_canonical = true")
        candidates = cur.fetchall()

    best_id: Optional[int] = None
    best_score = 0.0

    for cs_id, cs_name in candidates:
        cs_words = [w for w in re.split(r"\s+", cs_name) if len(w) >= 3]
        if not cs_words:
            continue
        hits = sum(1 for w in cs_words if w in code or any(w in cw for cw in code_words))
        if hits < 2:
            continue
        coverage = hits / len(cs_words)
        if coverage < 0.6:
            continue
        score = min(0.79, 0.50 + 0.29 * coverage)
        if score > best_score:
            best_score = score
            best_id = cs_id

    return best_id, best_score


def hierarchical_match(conn, external_code: str, source_system: str = "dws") -> dict:
    """Walk the 4-level cascade. Returns dict with canonical_sku_id / confidence / match_type."""
    code = _normalise(external_code)
    if not code:
        return {"canonical_sku_id": None, "confidence": 0.0, "match_type": "empty", "code": code}

    cs_id = _exact(conn, code, source_system)
    if cs_id is not None:
        return {"canonical_sku_id": cs_id, "confidence": 1.00, "match_type": "exact", "code": code}

    cs_id = _prefix_strip(conn, code, source_system)
    if cs_id is not None:
        return {"canonical_sku_id": cs_id, "confidence": 0.95, "match_type": "prefix_strip", "code": code}

    cs_id = _vintage_strip(conn, code, source_system)
    if cs_id is not None:
        return {"canonical_sku_id": cs_id, "confidence": 0.85, "match_type": "vintage_strip", "code": code}

    cs_id, score = _token_overlap(conn, code)
    if cs_id is not None:
        return {"canonical_sku_id": cs_id, "confidence": round(score, 2), "match_type": "token_overlap", "code": code}

    return {"canonical_sku_id": None, "confidence": 0.0, "match_type": "no_match", "code": code}


def main():
    logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(name)s: %(message)s")
    if len(sys.argv) < 2:
        print("Usage: python -m etl.sku_hierarchical_match <CODE> [source_system]", file=sys.stderr)
        sys.exit(2)
    code = sys.argv[1]
    source = sys.argv[2] if len(sys.argv) > 2 else "dws"

    db_url = os.environ.get("DATABASE_URL")
    if not db_url:
        print("ERROR: DATABASE_URL not set.", file=sys.stderr)
        sys.exit(1)

    conn = psycopg2.connect(db_url)
    try:
        result = hierarchical_match(conn, code, source)
        print(
            f"{result['match_type']}: {result['code']} "
            f"-> canonical_sku_id={result['canonical_sku_id']} (confidence={result['confidence']})"
        )
        sys.exit(0 if result["canonical_sku_id"] is not None else 1)
    finally:
        conn.close()


if __name__ == "__main__":
    main()
