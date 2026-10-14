"""
F-02: Import 4,030 Canonical Customers from the owner's reconciliation spreadsheet.

Reads the "Customer table" tab from the Database reconciliation xlsx and UPSERTs
into the canonical_customer table. Then auto-links existing customer rows to
their canonical counterpart via case-insensitive name matching.

Usage:
    DATABASE_URL=postgresql://... python -m etl.import_canonical_customer
"""

import logging
import os
import sys

import openpyxl
import psycopg2

from etl.logger import log_etl_run

logger = logging.getLogger("moppity.etl.import_canonical_customer")

XLSX_PATH = os.path.join(
    os.path.dirname(os.path.dirname(__file__)),
    "reference", "owner-feedback-2026-05-14", "Database reconciliation (4).xlsx",
)
SHEET_NAME = "Customers Postgres Updated"
# 2026-05-14: default flipped from (1).xlsx / "Customer table" to (4).xlsx / "Customers Postgres Updated"
# per the owner May 14 ingest (M12). NOTE: (4).xlsx has 12 mojibake-encoded customer names
# (e.g. ALDO'S CAFÎ˜) that do NOT match prod customer_name (ALDO'S CAFΘ) on ON CONFLICT clause.
# A manual full re-import would create 12 dupe rows.
# Preferred path: scripts/apply-schema-175-customer-ingest.py — matches via xlsx ID → canonical_customer.id PK.
SOURCE = "canonical_customer_import"

# Column header mapping — maps normalised header to our field names
# Header: ('ID', 'IsDelete', 'CustomerCode', 'ALMCustomerCode',
#          'DIRCustomerCode', 'ILGCustomerCode', 'YNRCustomerCode',
#          'YNRALMCustomerCode', 'CustomerName', 'Suburb', 'Postcode',
#          'Rep', 'Territory', 'TerritoryGroup', 'Group', 'Channel',
#          'Remark', 'Notes', 'xCustomerName', 'EditedOn', 'AddedOn', 'MaxID')
COLUMN_FIELDS = {
    "customername": "customer_name",
    "customercode": "customer_code",
    "almcustomercode": "alm_customer_code",
    "dircustomercode": "dir_customer_code",
    "ilgcustomercode": "ilg_customer_code",
    "ynrcustomercode": "ynr_customer_code",
    "ynralmcustomercode": "ynr_alm_customer_code",
    "rep": "rep_name",
    "territory": "territory_name",
    "territorygroup": "territory_group",
    "group": "customer_group",
    "channel": "channel",
    "suburb": "suburb",
    "postcode": "postcode",
    "remark": "remark",
    "notes": "notes",
    "xcustomername": "x_customer_name",
    "editedon": "edited_on_raw",
    "addedon": "added_on_raw",
    "maxid": "max_id_raw",
    "isdelete": "is_delete",
}

# B4 JC-016: mandatory fields rejected as NULL on import
MANDATORY_FIELDS = ("customer_name", "suburb", "postcode")


def read_customer_rows(xlsx_path: str) -> list[dict]:
    """Read Customer table tab and return list of dicts (skipping deleted rows)."""
    wb = openpyxl.load_workbook(xlsx_path, read_only=True, data_only=True)
    ws = wb[SHEET_NAME]
    rows = list(ws.iter_rows(values_only=True))
    wb.close()

    if len(rows) < 2:
        raise ValueError(f"Customer table has {len(rows)} rows — expected header + data.")

    header = [str(h).strip().lower().replace(" ", "") if h else "" for h in rows[0]]

    # Build column index: field_name -> column_index
    col_map = {}
    for idx, h in enumerate(header):
        if h in COLUMN_FIELDS:
            col_map[COLUMN_FIELDS[h]] = idx

    if "customer_name" not in col_map:
        raise ValueError(f"Cannot find CustomerName column. Headers: {header}")

    results = []
    skipped_deleted = 0

    for row in rows[1:]:
        # Skip deleted customers
        is_delete_idx = col_map.get("is_delete")
        if is_delete_idx is not None:
            is_delete_val = row[is_delete_idx]
            if is_delete_val and str(is_delete_val).strip().lower() in ("yes", "true", "1"):
                skipped_deleted += 1
                continue

        name_val = row[col_map["customer_name"]]
        if name_val is None or str(name_val).strip() == "":
            continue

        def _str_or_none(idx_key):
            idx = col_map.get(idx_key)
            if idx is None or idx >= len(row):
                return None
            val = row[idx]
            if val is None:
                return None
            # BUG-35: openpyxl reads numeric cells (ALM/DIR/YNR customer codes)
            # as floats, so `str(78275079.0)` yields '78275079.0'. Cast
            # whole-number floats to int before stringifying so codes are
            # stored as clean digit strings.
            if isinstance(val, float) and val.is_integer():
                s = str(int(val))
            else:
                s = str(val).strip()
            return s if s else None

        # B4 JC-006 + BUG-172: parse Access date values tolerantly.
        # The owner's Access export uses US-style MM/DD/YY (proven: 3,502 of 4,027
        # EditedOn rows have second-part > 12, 0 have first-part > 12 — so day
        # is always the second token, month the first). Earlier code tried
        # DD/MM/YY first which silently failed on rows where day > 12 (3,462
        # NULLed) and produced wrong values where day <= 12 (519 swapped).
        # Behaviour:
        #   1. If openpyxl already returned a datetime (xlsx cell parsed
        #      directly by Excel), use it as-is — Excel's locale-aware parse
        #      is already correct for this dataset.
        #   2. If the cell is a string (CSV reimport, mdb-export route, or
        #      text-typed xlsx cell), try MM/DD/YY first, then DD/MM/YY
        #      (defensive fallback in case source format ever drifts), then
        #      ISO formats.
        # claim by parsing the CSV directly (4,027 rows; format unambiguous).
        from datetime import datetime
        def _date_or_none(idx_key):
            idx = col_map.get(idx_key)
            if idx is None or idx >= len(row):
                return None
            val = row[idx]
            if val is None:
                return None
            # BUG-172 path 1: openpyxl handed us a real datetime — trust it.
            if isinstance(val, datetime):
                return val
            raw = str(val).strip()
            if not raw:
                return None
            for fmt in (
                "%m/%d/%y %H:%M:%S",  # BUG-172: US-style MM/DD/YY (Access source)
                "%m/%d/%Y %H:%M:%S",  # MM/DD/YYYY full year variant
                "%d/%m/%y %H:%M:%S",  # legacy DD/MM/YY fallback (defensive)
                "%d/%m/%Y %H:%M:%S",
                "%Y-%m-%d %H:%M:%S",
                "%Y-%m-%dT%H:%M:%S",
            ):
                try:
                    return datetime.strptime(raw, fmt)
                except ValueError:
                    continue
            return None

        def _int_or_none(idx_key):
            s = _str_or_none(idx_key)
            if s is None:
                return None
            try:
                return int(float(s))
            except (TypeError, ValueError):
                return None

        results.append({
            "customer_name": str(name_val).strip(),
            "customer_code": _str_or_none("customer_code"),
            "alm_customer_code": _str_or_none("alm_customer_code"),
            "dir_customer_code": _str_or_none("dir_customer_code"),
            "ilg_customer_code": _str_or_none("ilg_customer_code"),
            "ynr_customer_code": _str_or_none("ynr_customer_code"),
            "ynr_alm_customer_code": _str_or_none("ynr_alm_customer_code"),
            "territory_name": _str_or_none("territory_name"),
            "territory_group": _str_or_none("territory_group"),
            "rep_name": _str_or_none("rep_name"),
            "channel": _str_or_none("channel"),
            "customer_group": _str_or_none("customer_group"),
            "suburb": _str_or_none("suburb"),
            "postcode": _str_or_none("postcode"),
            "remark": _str_or_none("remark"),
            "notes": _str_or_none("notes"),
            "x_customer_name": _str_or_none("x_customer_name"),
            "edited_on": _date_or_none("edited_on_raw"),
            "added_on": _date_or_none("added_on_raw"),
            "max_id": _int_or_none("max_id_raw"),
        })

    logger.info("Read %d customers (%d deleted skipped)", len(results), skipped_deleted)
    return results


def validate_mandatory_fields(customer_rows: list[dict]) -> tuple[list[dict], list[str]]:
    """B4 JC-016: reject rows missing mandatory name/suburb/postcode.

    Returns (valid_rows, rejection_messages). Empty rejection list means all
    rows pass; non-empty means caller should decide whether to abort or
    proceed with partial set.
    """
    valid: list[dict] = []
    rejections: list[str] = []
    for row in customer_rows:
        missing = [f for f in MANDATORY_FIELDS if not row.get(f)]
        if missing:
            rejections.append(
                f"Customer '{row.get('customer_name') or '<no name>'}' rejected: "
                f"missing mandatory field(s) {missing}"
            )
            continue
        valid.append(row)
    return valid, rejections


# master has 23 (xCustomerName, Suburb) groups with two ID rows each (e.g.
# CUSTOMER 16 @ COLLINGWOOD ID 11344+11345). On UPSERT keyed on
# customer_name, the second row's distinct channel-code values were dropped
# because COALESCE(EXCLUDED, existing) preserves the first-arriving non-NULL.
# Fix: pre-merge dupe groups in Python before UPSERT — produce one synthetic
# row per (xCustomerName, Suburb) holding the UNION of all 5 channel-code
# columns from both source rows. Where both rows have a non-empty distinct
# value in the SAME column (the BERMAGUI ILG 1105/3604 case), the wide column
# keeps the latest by edited_on (matching schema/127's precedence rule); the
# secondary code is recorded in DUPE_PAIR_SECONDARY_CODES for downstream
# customer_channel_code emission. Idempotent — re-running on already-merged
# data is a no-op (groups of 1 pass through unchanged).
DUPE_PAIR_SECONDARY_CODES_KEY = "_dupe_secondary_codes"
CHANNEL_CODE_FIELDS = (
    "alm_customer_code",
    "dir_customer_code",
    "ilg_customer_code",
    "ynr_customer_code",
    "ynr_alm_customer_code",
)


def coalesce_dupe_pairs(customer_rows: list[dict]) -> tuple[list[dict], list[dict]]:
    """BUG-174: merge HARD-side (xCustomerName, Suburb) dupe groups by union
    of channel codes. Returns (merged_rows, secondary_codes).

    secondary_codes is a list of dicts {customer_key, channel_code,
    external_code} for cases where two source rows have DIFFERENT non-empty
    values in the same channel column — these are stored in
    customer_channel_code (audit-trail form) without overwriting the wide
    column.

    Rows are grouped by (UPPER(TRIM(x_customer_name)), UPPER(TRIM(suburb))).
    Rows missing either key are passed through individually (cannot dedupe
    safely). Within a group:
      - Mandatory fields (customer_name, suburb, postcode) come from the
        row with the latest edited_on.
      - Each channel-code column: if all rows agree (or only one is non-
        empty), use that value. If two rows have different non-empty
        values, keep the latest-edited row's value in the wide column and
        emit the other(s) as secondary_codes.
      - Non-channel scalars (rep_name, territory_name, channel, etc.):
        prefer the latest-edited row's value, COALESCE-fall-back to other.
    """
    from collections import defaultdict
    groups: dict[tuple[str, str], list[dict]] = defaultdict(list)
    passthrough: list[dict] = []

    for row in customer_rows:
        xname = (row.get("x_customer_name") or "").strip().upper()
        suburb = (row.get("suburb") or "").strip().upper()
        if not xname or not suburb:
            # Cannot group — pass through unchanged.
            passthrough.append(row)
            continue
        groups[(xname, suburb)].append(row)

    merged: list[dict] = list(passthrough)
    secondary_codes: list[dict] = []

    for key, group in groups.items():
        if len(group) == 1:
            merged.append(group[0])
            continue

        # Order by edited_on DESC (latest first; None last)
        # so latest-edited row wins ties on the wide-column read fast-path.
        sorted_group = sorted(
            group,
            key=lambda r: (r.get("edited_on") is None, r.get("edited_on")),
            reverse=True,
        )
        # First row = "latest" winner for non-channel fields.
        winner = sorted_group[0]
        merged_row = dict(winner)

        # Channel codes: union with conflict detection.
        for field in CHANNEL_CODE_FIELDS:
            values = [
                r.get(field) for r in sorted_group
                if r.get(field) is not None and str(r.get(field)).strip() != ""
            ]
            distinct = list(dict.fromkeys(values))  # preserve order, dedupe
            if not distinct:
                merged_row[field] = None
            elif len(distinct) == 1:
                merged_row[field] = distinct[0]
            else:
                # CONFLICT: multiple distinct non-empty values across pair.
                # Wide column = latest-edited's value (sorted_group[0]'s).
                # Secondary values land in customer_channel_code lookup.
                merged_row[field] = sorted_group[0].get(field) or distinct[0]
                channel_code_label = {
                    "alm_customer_code": "ALM",
                    "dir_customer_code": "DIR",
                    "ilg_customer_code": "ILG",
                    "ynr_customer_code": "YNR",
                    "ynr_alm_customer_code": "YNRALM",
                }[field]
                primary_value = merged_row[field]
                for v in distinct:
                    if v != primary_value:
                        secondary_codes.append({
                            "customer_name": winner["customer_name"],
                            "channel_code": channel_code_label,
                            "external_code": v,
                        })

        # Non-channel scalars: COALESCE across sorted group (winner first).
        non_channel_fields = (
            "customer_code", "territory_name", "territory_group", "rep_name",
            "channel", "customer_group", "remark", "notes",
            "edited_on", "added_on", "max_id",
        )
        for field in non_channel_fields:
            for r in sorted_group:
                v = r.get(field)
                if v is not None and (not isinstance(v, str) or v.strip() != ""):
                    merged_row[field] = v
                    break

        merged.append(merged_row)

    if secondary_codes:
        logger.info(
            "BUG-174 dupe-merge: %d secondary channel codes preserved for "
            "customer_channel_code lookup table.", len(secondary_codes)
        )

    return merged, secondary_codes


def upsert_secondary_channel_codes(conn, secondary_codes: list[dict]) -> int:
    """BUG-174: insert secondary channel codes (BERMAGUI ILG 1105 case) into
    customer_channel_code lookup — preserves both values without mutating
    the wide column.
    """
    if not secondary_codes:
        return 0
    inserted = 0
    with conn.cursor() as cur:
        for sc in secondary_codes:
            try:
                cur.execute("""
                    INSERT INTO customer_channel_code
                        (canonical_customer_id, channel_code, external_code, source)
                    SELECT cc.id, %(channel_code)s, %(external_code)s,
                           'etl-bug174-dupe-secondary'
                      FROM canonical_customer cc
                     WHERE cc.customer_name = %(customer_name)s
                    ON CONFLICT (canonical_customer_id, channel_code, external_code)
                    DO NOTHING
                """, sc)
                inserted += cur.rowcount
            except Exception as exc:
                logger.warning(
                    "Secondary channel code insert failed for %s/%s/%s: %s",
                    sc.get("customer_name"), sc.get("channel_code"),
                    sc.get("external_code"), exc,
                )
                conn.rollback()
    conn.commit()
    return inserted


def upsert_canonical_customers(conn, customer_rows: list[dict]) -> dict:
    """UPSERT rows into canonical_customer. Returns stats dict."""
    inserted = 0
    updated = 0
    errors = []

    # B4 JC-003/004/005/006/007/008/009/039: extended UPSERT covering all 22
    # Access cols. New cols are populated only when supplied (use COALESCE so
    # a partial xlsx import doesn't blank out previously-populated fields).
    with conn.cursor() as cur:
        for row in customer_rows:
            try:
                cur.execute("""
                    INSERT INTO canonical_customer (
                        customer_name, customer_code,
                        alm_customer_code, dir_customer_code, ilg_customer_code,
                        ynr_customer_code, ynr_alm_customer_code,
                        territory_name, territory_group, rep_name, channel,
                        customer_group, suburb, postcode, remark, notes,
                        x_customer_name, edited_on, added_on, max_id
                    )
                    VALUES (
                        %(customer_name)s, %(customer_code)s,
                        %(alm_customer_code)s, %(dir_customer_code)s, %(ilg_customer_code)s,
                        %(ynr_customer_code)s, %(ynr_alm_customer_code)s,
                        %(territory_name)s, %(territory_group)s, %(rep_name)s, %(channel)s,
                        %(customer_group)s, %(suburb)s, %(postcode)s, %(remark)s, %(notes)s,
                        %(x_customer_name)s, %(edited_on)s, %(added_on)s, %(max_id)s
                    )
                    ON CONFLICT (customer_name) DO UPDATE SET
                        customer_code         = COALESCE(EXCLUDED.customer_code,         canonical_customer.customer_code),
                        alm_customer_code     = COALESCE(EXCLUDED.alm_customer_code,     canonical_customer.alm_customer_code),
                        dir_customer_code     = COALESCE(EXCLUDED.dir_customer_code,     canonical_customer.dir_customer_code),
                        ilg_customer_code     = COALESCE(EXCLUDED.ilg_customer_code,     canonical_customer.ilg_customer_code),
                        ynr_customer_code     = COALESCE(EXCLUDED.ynr_customer_code,     canonical_customer.ynr_customer_code),
                        ynr_alm_customer_code = COALESCE(EXCLUDED.ynr_alm_customer_code, canonical_customer.ynr_alm_customer_code),
                        territory_name        = COALESCE(EXCLUDED.territory_name,        canonical_customer.territory_name),
                        territory_group       = COALESCE(EXCLUDED.territory_group,       canonical_customer.territory_group),
                        rep_name              = COALESCE(EXCLUDED.rep_name,              canonical_customer.rep_name),
                        channel               = COALESCE(EXCLUDED.channel,               canonical_customer.channel),
                        customer_group        = COALESCE(EXCLUDED.customer_group,        canonical_customer.customer_group),
                        suburb                = COALESCE(EXCLUDED.suburb,                canonical_customer.suburb),
                        postcode              = COALESCE(EXCLUDED.postcode,              canonical_customer.postcode),
                        remark                = COALESCE(EXCLUDED.remark,                canonical_customer.remark),
                        notes                 = COALESCE(EXCLUDED.notes,                 canonical_customer.notes),
                        x_customer_name       = COALESCE(EXCLUDED.x_customer_name,       canonical_customer.x_customer_name),
                        edited_on             = COALESCE(EXCLUDED.edited_on,             canonical_customer.edited_on),
                        added_on              = COALESCE(EXCLUDED.added_on,              canonical_customer.added_on),
                        max_id                = COALESCE(EXCLUDED.max_id,                canonical_customer.max_id)
                    RETURNING (xmax = 0) AS is_insert
                """, row)
                is_insert = cur.fetchone()[0]
                if is_insert:
                    inserted += 1
                else:
                    updated += 1
            except Exception as exc:
                errors.append(f"Customer '{row['customer_name']}': {exc}")
                conn.rollback()

    conn.commit()
    return {"inserted": inserted, "updated": updated, "errors": errors}


def auto_link_customers(conn) -> dict:
    """
    Auto-link existing customer.canonical_customer_id by matching customer_name.

    Strategy:
    1. Exact match: UPPER(TRIM(customer.customer_name)) = UPPER(TRIM(canonical_customer.customer_name))
    2. Contained match: canonical name appears in customer name or vice versa
    """
    matched = 0
    unmatched = 0

    with conn.cursor() as cur:
        # Step 1: Exact match (case-insensitive, trimmed)
        cur.execute("""
            UPDATE customer c
            SET canonical_customer_id = cc.id
            FROM canonical_customer cc
            WHERE c.canonical_customer_id IS NULL
              AND UPPER(TRIM(c.customer_name)) = UPPER(TRIM(cc.customer_name))
        """)
        step1 = cur.rowcount
        logger.info("Step 1 (exact name match): linked %d customers", step1)

        # Step 2: Contained match — canonical name inside customer name
        cur.execute("""
            UPDATE customer c
            SET canonical_customer_id = cc.id
            FROM canonical_customer cc
            WHERE c.canonical_customer_id IS NULL
              AND UPPER(TRIM(c.customer_name)) LIKE '%%' || UPPER(TRIM(cc.customer_name)) || '%%'
        """)
        step2 = cur.rowcount
        logger.info("Step 2 (contained match): linked %d customers", step2)

        # Step 3: Reverse contained — customer name inside canonical name
        cur.execute("""
            UPDATE customer c
            SET canonical_customer_id = cc.id
            FROM canonical_customer cc
            WHERE c.canonical_customer_id IS NULL
              AND UPPER(TRIM(cc.customer_name)) LIKE '%%' || UPPER(TRIM(c.customer_name)) || '%%'
              AND LENGTH(TRIM(c.customer_name)) >= 5
        """)
        step3 = cur.rowcount
        logger.info("Step 3 (reverse contained match): linked %d customers", step3)

        matched = step1 + step2 + step3

        # Count remaining unlinked
        cur.execute("SELECT COUNT(*) FROM customer WHERE canonical_customer_id IS NULL")
        unmatched = cur.fetchone()[0]

    conn.commit()
    return {"matched": matched, "unmatched": unmatched}


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
        print("F-02: Import Canonical Customers")
        print(f"{'='*60}")
        print(f"Source: {xlsx_path}")
        print(f"Sheet:  {SHEET_NAME}")

        customer_rows = read_customer_rows(xlsx_path)
        print(f"Read {len(customer_rows)} customer rows from spreadsheet")

        # B4 JC-016: mandatory-field validator (name, suburb, postcode)
        valid_rows, rejections = validate_mandatory_fields(customer_rows)
        if rejections:
            print(f"\nMandatory-field validator rejected {len(rejections)} row(s):")
            for msg in rejections[:10]:
                print(f"  - {msg}")
            if len(rejections) > 10:
                print(f"  ... and {len(rejections) - 10} more")
        print(f"Proceeding with {len(valid_rows)} valid row(s).")

        # BUG-174 (2026-05-04): pre-merge HARD-side (xCustomerName, Suburb)
        # dupe groups so the second row's distinct channel codes don't get
        # silently dropped by ON CONFLICT (customer_name) DO UPDATE +
        # COALESCE(EXCLUDED, existing). 23 known dupe pairs in the owner's
        pre_merge_count = len(valid_rows)
        valid_rows, secondary_codes = coalesce_dupe_pairs(valid_rows)
        print(f"BUG-174 dupe-merge: {pre_merge_count} -> {len(valid_rows)} rows "
              f"(merged {pre_merge_count - len(valid_rows)} dupe-pair rows; "
              f"{len(secondary_codes)} secondary codes for lookup table).")

        # 2. UPSERT into canonical_customer
        stats = upsert_canonical_customers(conn, valid_rows)
        print(f"\nCanonical Customer UPSERT:")
        print(f"  Inserted: {stats['inserted']}")
        print(f"  Updated:  {stats['updated']}")
        if stats["errors"]:
            print(f"  Errors:   {len(stats['errors'])}")
            for err in stats["errors"][:10]:
                print(f"    - {err}")
            if len(stats["errors"]) > 10:
                print(f"    ... and {len(stats['errors']) - 10} more")

        # 2b. BUG-174: insert secondary channel codes from dupe-pair conflicts
        #     into customer_channel_code (audit-trail / historical preservation).
        if secondary_codes:
            secondary_inserted = upsert_secondary_channel_codes(conn, secondary_codes)
            print(f"\nBUG-174 secondary channel codes:")
            print(f"  Inserted: {secondary_inserted} (skipped duplicates via ON CONFLICT)")

        # 3. Auto-link existing customer rows
        print(f"\nAuto-linking existing customer rows to canonical_customer...")
        link_stats = auto_link_customers(conn)
        print(f"  Matched:   {link_stats['matched']}")
        print(f"  Unmatched: {link_stats['unmatched']}")

        # 4. Log ETL run
        total_processed = stats["inserted"] + stats["updated"]
        status = "success" if not stats["errors"] else "partial"
        log_etl_run(
            conn,
            source=SOURCE,
            endpoint=SHEET_NAME,
            status=status,
            rows_processed=total_processed,
            rows_skipped=0,
            error_count=len(stats["errors"]),
            error_detail="\n".join(stats["errors"][:50]) if stats["errors"] else None,
        )

        print(f"\n{'='*60}")
        print(f"DONE: {total_processed} canonical customers loaded, "
              f"{link_stats['matched']} existing customers linked.")
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
