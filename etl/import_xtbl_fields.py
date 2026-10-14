"""
B11 — import xtblFields cross-reference (63 rows) from Access into Postgres.

Tickets
-------
JC-092 (xtblFields field-mapping cross-reference) — 63 rows, 6 columns
       (ID, ALM, ILG, DIRECT, YoungNRashleigh, YoungNRashleighALM) per
       extract-accdb-0049.

Source
------
      64 lines including header (63 data rows).

Idempotent: TRUNCATE + INSERT inside one transaction. Re-running replaces
the table contents with the latest CSV — safe because xtbl_fields has no
FK references (lookup table only).

Usage
-----
    DATABASE_URL=postgresql://... \\
    python -m etl.import_xtbl_fields \\
        --commit          # default is --dry-run

Exit codes
----------
    0  success
    1  guard violation (row count drift from HARD source)
    2  DB error (rolled back)
    3  config error
"""
from __future__ import annotations

import argparse
import csv
import logging
import os
import sys
from pathlib import Path

import psycopg2
import psycopg2.extras

logger = logging.getLogger("moppity.etl.import_xtbl_fields")

EXPECTED_ROWS = 63

DEFAULT_CSV = (
    Path(__file__).resolve().parent.parent
    / "audit"
    / "external-sources"
    / "xtblFields-2026-04-27.csv"
)

ACCESS_TO_DB_COL = {
    "ID":                  "id",
    "ALM":                 "alm_field",
    "ILG":                 "ilg_field",
    "DIRECT":              "direct_field",
    "YoungNRashleigh":     "young_n_rashleigh_field",
    "YoungNRashleighALM":  "young_n_rashleigh_alm_field",
}


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__.strip().splitlines()[0])
    p.add_argument("--import-csv", type=Path, default=DEFAULT_CSV)
    g = p.add_mutually_exclusive_group()
    g.add_argument(
        "--dry-run", dest="dry_run", action="store_true", default=True,
        help="ROLLBACK at end of run (default)",
    )
    g.add_argument(
        "--commit", dest="dry_run", action="store_false",
        help="COMMIT changes (explicit opt-in)",
    )
    return p.parse_args()


def load_csv(path: Path) -> list[dict[str, str]]:
    if not path.exists():
        raise FileNotFoundError(f"xtblFields CSV not found: {path}")
    with open(path, newline="") as f:
        reader = csv.DictReader(f)
        rows = list(reader)
    return rows


def main() -> int:
    logging.basicConfig(
        level=os.environ.get("LOG_LEVEL", "INFO"),
        format="%(asctime)s %(name)s %(levelname)s %(message)s",
    )
    args = parse_args()

    db_url = os.environ.get("DATABASE_URL")
    if not db_url:
        logger.error("DATABASE_URL env var required")
        return 3

    try:
        rows = load_csv(args.import_csv)
    except FileNotFoundError as exc:
        logger.error("%s", exc)
        return 3

    if len(rows) != EXPECTED_ROWS:
        logger.error(
            "row count drift: csv has %d rows but HARD source expects %d — re-run mdb-export?",
            len(rows), EXPECTED_ROWS,
        )
        return 1

    conn = psycopg2.connect(db_url)
    conn.autocommit = False

    try:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute("TRUNCATE xtbl_fields")
            insert_sql = (
                "INSERT INTO xtbl_fields ("
                "id, alm_field, ilg_field, direct_field, "
                "young_n_rashleigh_field, young_n_rashleigh_alm_field"
                ") VALUES (%s, %s, %s, %s, %s, %s)"
            )
            for raw in rows:
                cur.execute(
                    insert_sql,
                    (
                        int(raw["ID"]),
                        raw.get("ALM") or None,
                        raw.get("ILG") or None,
                        raw.get("DIRECT") or None,
                        raw.get("YoungNRashleigh") or None,
                        raw.get("YoungNRashleighALM") or None,
                    ),
                )

            cur.execute("SELECT count(*) AS n FROM xtbl_fields")
            db_count = cur.fetchone()["n"]
            logger.info("Inserted %d rows; xtbl_fields now has %d rows", len(rows), db_count)

            if db_count != EXPECTED_ROWS:
                logger.error(
                    "post-insert count=%d, expected %d — aborting", db_count, EXPECTED_ROWS,
                )
                conn.rollback()
                return 1

            if args.dry_run:
                logger.info("DRY-RUN — rolling back")
                conn.rollback()
            else:
                logger.info("COMMIT — persisting changes")
                conn.commit()
    except psycopg2.Error as exc:
        conn.rollback()
        logger.exception("DB error — transaction rolled back: %s", exc)
        return 2
    finally:
        conn.close()

    return 0


if __name__ == "__main__":
    sys.exit(main())
