"""Google Sheets sync using API key for public sheets."""
import requests
import json
import psycopg2
import os
import sys

# Read from environment variables - no hardcoded defaults
API_KEY = os.environ.get("GOOGLE_API_KEY")
DATABASE_URL = os.environ.get("DATABASE_URL")

# Validate required env vars at module load
if not API_KEY:
    print("ERROR: GOOGLE_API_KEY environment variable is required", file=sys.stderr)
    sys.exit(1)
if not DATABASE_URL:
    print("ERROR: DATABASE_URL environment variable is required", file=sys.stderr)
    sys.exit(1)

SHEETS = {
    "scheduling": {
        "id": os.environ.get("GOOGLE_SHEET_SCHEDULING_ID", ""),
        "tab": "Planner",
        "staging_table": "staging_sheets_scheduling",
    },
    "cashflow": {
        "id": os.environ.get("GOOGLE_SHEET_CASHFLOW_ID", ""),
        "tab": "Trust",
        "staging_table": "staging_sheets_cashflow",
    },
}


def sync_sheet(conn, name, config):
    """Pull one sheet tab into staging table."""
    sheet_id = config["id"]
    tab = config["tab"]
    table = config["staging_table"]

    url = f"https://sheets.googleapis.com/v4/spreadsheets/{sheet_id}/values/{tab}?key={API_KEY}"
    r = requests.get(url)
    if r.status_code != 200:
        print(f"  {name}: FAILED {r.status_code} - {r.text[:200]}")
        return 0

    data = r.json()
    rows = data.get("values", [])
    if len(rows) < 2:
        print(f"  {name}: no data rows")
        return 0

    headers = rows[0]
    cur = conn.cursor()
    cur.execute(f"DELETE FROM {table}")

    count = 0
    for row in rows[1:]:
        row_dict = {}
        for i, h in enumerate(headers):
            if h and i < len(row):
                row_dict[h] = row[i]
        if row_dict:
            cur.execute(
                f"INSERT INTO {table} (raw_data) VALUES (%s)",
                [json.dumps(row_dict)]
            )
            count += 1

    conn.commit()

    cur.execute(
        "INSERT INTO etl_run_log (source, endpoint, status, rows_processed, rows_skipped, error_count, run_timestamp) VALUES (%s, %s, %s, %s, %s, %s, NOW())",
        (f"google_sheets", tab, "success", count, 0, 0)
    )
    conn.commit()
    cur.close()
    print(f"  {name}: {count} rows synced")
    return count


def main():
    """Sync all configured sheets."""
    conn = psycopg2.connect(DATABASE_URL)
    total = 0
    for name, config in SHEETS.items():
        try:
            total += sync_sheet(conn, name, config)
        except Exception as e:
            print(f"  {name}: ERROR - {e}")
    conn.close()
    print(f"Google Sheets sync complete: {total} total rows")


if __name__ == "__main__":
    main()
