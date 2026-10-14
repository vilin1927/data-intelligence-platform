"""
F-03: Import 30 Canonical Territories from the owner's reconciliation spreadsheet.

Reads the "Territories" tab from the Database reconciliation xlsx and INSERTs
into the canonical_territory table. Then fuzzy-matches existing territory rows
to canonical names and updates them where possible.

Usage:
    DATABASE_URL=postgresql://... python -m etl.import_canonical_territory
"""

import logging
import os
import sys

import openpyxl
import psycopg2

from etl.logger import log_etl_run

logger = logging.getLogger("moppity.etl.import_canonical_territory")

XLSX_PATH = os.path.join(
    os.path.dirname(os.path.dirname(__file__)),
    "reference", "owner-feedback-mar26", "Database reconciliation (1).xlsx",
)
SHEET_NAME = "Territories"
SOURCE = "canonical_territory_import"


def read_territory_rows(xlsx_path: str) -> list[str]:
    """Read Territories tab and return list of territory name strings."""
    wb = openpyxl.load_workbook(xlsx_path, read_only=True, data_only=True)
    ws = wb[SHEET_NAME]
    rows = list(ws.iter_rows(values_only=True))
    wb.close()

    # Territories tab has a single column, no header — just territory names
    results = []
    for row in rows:
        val = row[0] if row else None
        if val is not None and str(val).strip():
            results.append(str(val).strip())

    return results


def insert_canonical_territories(conn, territory_names: list[str]) -> dict:
    """INSERT territory names into canonical_territory (skip duplicates). Returns stats."""
    inserted = 0
    skipped = 0
    errors = []

    with conn.cursor() as cur:
        for name in territory_names:
            try:
                cur.execute("""
                    INSERT INTO canonical_territory (territory_name)
                    VALUES (%s)
                    ON CONFLICT (territory_name) DO NOTHING
                    RETURNING id
                """, (name,))
                row = cur.fetchone()
                if row:
                    inserted += 1
                else:
                    skipped += 1
            except Exception as exc:
                errors.append(f"Territory '{name}': {exc}")
                conn.rollback()

    conn.commit()
    return {"inserted": inserted, "skipped": skipped, "errors": errors}


def fuzzy_match_territories(conn) -> dict:
    """
    Match existing territory rows to canonical_territory names.

    Strategy:
    1. Exact match (case-insensitive, trimmed)
    2. Normalized match (strip extra spaces, lowercase compare)
    3. Word-overlap match (for cases like "NSW SYDNEY NORTH" vs "NSW Sydney North")

    Where a match is found, UPDATE the existing territory.territory_name to
    the canonical spelling (preserving the territory_id).
    """
    matched = 0
    unmatched_territories = []

    with conn.cursor() as cur:
        # Load canonical territory names
        cur.execute("SELECT id, territory_name FROM canonical_territory")
        canonical = {row[1].upper().strip(): row[1] for row in cur.fetchall()}

        # Load existing territory rows
        cur.execute("SELECT territory_id, territory_name FROM territory")
        existing = cur.fetchall()

        for tid, tname in existing:
            if tname is None:
                unmatched_territories.append(f"territory_id={tid}: NULL name")
                continue

            normalized = tname.upper().strip()

            # Step 1: Exact match (case-insensitive)
            if normalized in canonical:
                canonical_name = canonical[normalized]
                if tname != canonical_name:
                    # Update to canonical spelling
                    try:
                        cur.execute(
                            "UPDATE territory SET territory_name = %s WHERE territory_id = %s",
                            (canonical_name, tid),
                        )
                        logger.info("Normalized territory '%s' -> '%s'", tname, canonical_name)
                    except Exception as exc:
                        # Might fail if there's a unique index conflict — means the canonical
                        # already exists as another row. Skip silently.
                        logger.warning("Cannot rename territory '%s' -> '%s': %s", tname, canonical_name, exc)
                        conn.rollback()
                        conn = cur.connection
                matched += 1
                continue

            # Step 2: Word-overlap match
            t_words = set(normalized.split())
            best_match = None
            best_overlap = 0

            for canon_upper, canon_original in canonical.items():
                c_words = set(canon_upper.split())
                overlap = len(t_words & c_words)
                total = max(len(t_words), len(c_words))

                # Require > 60% overlap and at least 2 matching words
                if overlap >= 2 and overlap / total > 0.6:
                    if overlap > best_overlap:
                        best_overlap = overlap
                        best_match = canon_original

            if best_match is not None:
                try:
                    cur.execute(
                        "UPDATE territory SET territory_name = %s WHERE territory_id = %s",
                        (best_match, tid),
                    )
                    logger.info("Fuzzy-matched territory '%s' -> '%s'", tname, best_match)
                except Exception as exc:
                    logger.warning("Cannot rename territory '%s' -> '%s': %s", tname, best_match, exc)
                    conn.rollback()
                    conn = cur.connection
                matched += 1
            else:
                unmatched_territories.append(f"territory_id={tid}: '{tname}'")

    conn.commit()
    return {
        "matched": matched,
        "unmatched": len(unmatched_territories),
        "unmatched_details": unmatched_territories,
    }


def main():
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    )

    db_url = os.environ.get("DATABASE_URL")
    if not db_url:
        print("ERROR: DATABASE_URL environment variable is not set.", file=sys.stderr)
        sys.exit(1)

    xlsx_path = XLSX_PATH
    if len(sys.argv) > 1:
        xlsx_path = sys.argv[1]

    if not os.path.isfile(xlsx_path):
        print(f"ERROR: File not found: {xlsx_path}", file=sys.stderr)
        sys.exit(1)

    conn = psycopg2.connect(db_url)

    try:
        # 1. Read xlsx
        print(f"\n{'='*60}")
        print("F-03: Import Canonical Territories")
        print(f"{'='*60}")
        print(f"Source: {xlsx_path}")
        print(f"Sheet:  {SHEET_NAME}")

        territory_names = read_territory_rows(xlsx_path)
        print(f"Read {len(territory_names)} territory names from spreadsheet")

        # 2. INSERT into canonical_territory
        stats = insert_canonical_territories(conn, territory_names)
        print(f"\nCanonical Territory INSERT:")
        print(f"  Inserted: {stats['inserted']}")
        print(f"  Skipped (already existed): {stats['skipped']}")
        if stats["errors"]:
            print(f"  Errors:   {len(stats['errors'])}")
            for err in stats["errors"]:
                print(f"    - {err}")

        # 3. Fuzzy-match existing territory rows
        print(f"\nMatching existing territory rows to canonical names...")
        match_stats = fuzzy_match_territories(conn)
        print(f"  Matched:   {match_stats['matched']}")
        print(f"  Unmatched: {match_stats['unmatched']}")
        if match_stats["unmatched_details"]:
            print(f"  Unmatched details:")
            for detail in match_stats["unmatched_details"][:20]:
                print(f"    - {detail}")

        # 4. Log ETL run
        status = "success" if not stats["errors"] else "partial"
        log_etl_run(
            conn,
            source=SOURCE,
            endpoint=SHEET_NAME,
            status=status,
            rows_processed=stats["inserted"] + stats["skipped"],
            rows_skipped=stats["skipped"],
            error_count=len(stats["errors"]),
            error_detail="\n".join(stats["errors"][:50]) if stats["errors"] else None,
        )

        print(f"\n{'='*60}")
        print(f"DONE: {stats['inserted']} canonical territories loaded, "
              f"{match_stats['matched']} existing territories matched.")
        print(f"{'='*60}\n")

    except Exception as exc:
        conn.rollback()
        print(f"FATAL: {exc}", file=sys.stderr)
        try:
            log_etl_run(
                conn, source=SOURCE, endpoint=SHEET_NAME,
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
