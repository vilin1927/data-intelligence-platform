"""
B4 JC-033 + JC-034 + JC-035 + JC-047:
Filter Vinsight Contacts (7,967 staging rows) → Moppity sales-customer subset
(~4,030) by setting `staging_vinsight_contacts.is_moppity_customer = TRUE`.

Why: the Vinsight Contacts feed is a superset — growers, suppliers, employees,
channel-transfer dummies (DWS NSW/QLD/..., ALM Fyshwick/Huntingwood/Laverton),
mail-order subscribers, inactive contacts. Only the sales-customer subset
should reach the canonical_customer master / sales reconciliation pipeline.

- EXCLUDE if Contact Category contains any of:
    GROWER / SUPPLIER / EMPLOYEE / DWS / ML / MAIL ORDER / INACTIVE
- EXCLUDE if customer name matches channel-transfer pattern (DWS prefix,
  ALM Fyshwick/Huntingwood/Laverton, "MAIL ORDER" prefix).
- INCLUDE otherwise.


Usage:
    DATABASE_URL=postgresql://... python -m etl.filter_vinsight_moppity_customers [--dry-run]

Idempotent: re-running re-evaluates the predicate (handles late-arriving
Contact Category updates).
"""

from __future__ import annotations

import argparse
import logging
import os
import sys

import psycopg2

logger = logging.getLogger("moppity.etl.filter_vinsight_moppity_customers")

SOURCE = "vinsight_moppity_filter"

# Case-folded substrings that, when found in the joined Contact Category bag,
# mark the contact as NON-customer.
EXCLUDE_CATEGORIES = (
    "GROWER",
    "SUPPLIER",
    "EMPLOYEE",
    "DWS",          # Domaine Wine Shippers — channel transfer
    "ML",           # mail-order
    "MAIL ORDER",
    "INACTIVE",
)

# Customer-name prefixes / exact matches that flag channel-transfer dummies.
EXCLUDE_NAME_EXACT = (
    "ALM FYSHWICK",
    "ALM HUNTINGWOOD",
    "ALM LAVERTON",
)
EXCLUDE_NAME_PREFIX = (
    "DWS ",
    "DOMAINE WINE SHIPPERS",
    "MAIL ORDER",
)


def is_moppity_customer(contact_name: str | None, categories: list[str]) -> bool:
    """B4 JC-033 predicate. Return True iff this Vinsight contact is a
    canonical Moppity sales customer per the owner's filter spec."""
    if not contact_name:
        return False
    n = contact_name.strip().upper()
    if not n:
        return False
    if n in EXCLUDE_NAME_EXACT:
        return False
    if any(n.startswith(p) for p in EXCLUDE_NAME_PREFIX):
        return False
    bag = " | ".join((c or "").upper() for c in categories)
    if any(tag in bag for tag in EXCLUDE_CATEGORIES):
        return False
    return True


def is_moppity_customer_full(
    contact_name: str | None,
    categories: list[str],
    is_active: bool | None,
    is_grower: bool | None,
    is_employee: bool | None,
    is_creditor: bool | None,
    is_mail_order: bool | None,
    is_debtor: bool | None,
) -> bool:
    """Full predicate that combines name/category exclusions with the
    boolean role flags Vinsight ships in the contact JSONB.

    Approach: a contact is a Moppity sales customer iff it is a debtor
    (i.e. someone we sell to), is active, and is NOT one of the
    excluded role categories (grower / employee / creditor-only /
    mail-order subscription / channel-transfer dummy)."""
    if not contact_name:
        return False
    if is_active is False:
        return False
    if is_grower or is_employee or is_mail_order:
        return False
    # Creditor-only contacts (suppliers we pay) are not customers — but
    # contacts can be both debtor + creditor (rare; trust IsDebtor).
    if is_creditor and not is_debtor:
        return False
    # Must be a debtor — the role marker for "we sell to them"
    if is_debtor is False:
        return False
    n = contact_name.strip().upper()
    if not n:
        return False
    if n in EXCLUDE_NAME_EXACT:
        return False
    if any(n.startswith(p) for p in EXCLUDE_NAME_PREFIX):
        return False
    bag = " | ".join((c or "").upper() for c in categories)
    if any(tag in bag for tag in EXCLUDE_CATEGORIES):
        return False
    return True


def evaluate_filter(conn, dry_run: bool = False) -> dict:
    """Walk staging_vinsight_contacts, classify each row, persist
    is_moppity_customer. Returns counts dict.

    Reads ContactCode (Vinsight's actual contact-name key) plus the
    boolean role flags (IsActive/IsDebtor/IsGrower/IsEmployee/...)
    that Vinsight ships in the contact JSONB. ContactCategory is a
    single ;-delimited string."""
    classified_yes = 0
    classified_no = 0

    select_sql = """
        SELECT
          id,
          COALESCE(raw_data->>'ContactCode',
                   raw_data->>'LegalName',
                   raw_data->>'CompanyName',
                   raw_data->>'ContactName')                  AS contact_name,
          raw_data->>'ContactCategory'                         AS category_str,
          NULLIF(raw_data->>'IsActive', '')::boolean           AS is_active,
          NULLIF(raw_data->>'IsGrower', '')::boolean           AS is_grower,
          NULLIF(raw_data->>'IsEmployee', '')::boolean         AS is_employee,
          NULLIF(raw_data->>'IsCreditor', '')::boolean         AS is_creditor,
          NULLIF(raw_data->>'IsMailOrder', '')::boolean        AS is_mail_order,
          NULLIF(raw_data->>'IsDebtor', '')::boolean           AS is_debtor
        FROM staging_vinsight_contacts
    """

    with conn:
        with conn.cursor(name="moppity_filter_cursor") as cur:
            cur.itersize = 1000
            cur.execute(select_sql)
            with conn.cursor() as upd_cur:
                batch: list[tuple[bool, int]] = []
                for row in cur:
                    (row_id, contact_name, category_str,
                     is_active, is_grower, is_employee,
                     is_creditor, is_mail_order, is_debtor) = row
                    cats: list[str] = []
                    if isinstance(category_str, str) and category_str:
                        cats = [s.strip() for s in category_str.split(";") if s.strip()]
                    flag = is_moppity_customer_full(
                        contact_name, cats,
                        is_active=is_active,
                        is_grower=is_grower,
                        is_employee=is_employee,
                        is_creditor=is_creditor,
                        is_mail_order=is_mail_order,
                        is_debtor=is_debtor,
                    )
                    if flag:
                        classified_yes += 1
                    else:
                        classified_no += 1
                    batch.append((flag, row_id))
                    if len(batch) >= 500 and not dry_run:
                        upd_cur.executemany(
                            "UPDATE staging_vinsight_contacts "
                            "SET is_moppity_customer = %s WHERE id = %s",
                            batch,
                        )
                        batch.clear()
                if batch and not dry_run:
                    upd_cur.executemany(
                        "UPDATE staging_vinsight_contacts "
                        "SET is_moppity_customer = %s WHERE id = %s",
                        batch,
                    )

    return {
        "moppity_customers": classified_yes,
        "non_customers": classified_no,
        "total": classified_yes + classified_no,
        "dry_run": dry_run,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Classify but do not persist is_moppity_customer.",
    )
    args = parser.parse_args(argv)

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    )

    db_url = os.environ.get("DATABASE_URL")
    if not db_url:
        print("ERROR: DATABASE_URL environment variable is not set.", file=sys.stderr)
        return 1

    conn = psycopg2.connect(db_url)
    try:
        stats = evaluate_filter(conn, dry_run=args.dry_run)
    finally:
        conn.close()

    print(
        f"Vinsight contacts: total={stats['total']}, "
        f"moppity_customers={stats['moppity_customers']}, "
        f"non_customers={stats['non_customers']}, "
        f"dry_run={stats['dry_run']}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
