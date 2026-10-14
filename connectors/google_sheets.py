"""
Google Sheets connector for Moppity Vineyards data platform.

Read-only access to the owner's 4 planning spreadsheets via service account.
Pulls Scheduling ('Plan' tab) and Cashflow data into Postgres staging
tables as JSONB rows, and logs every operation to etl_run_log.

Authentication: Google service account JSON key file.
Scopes: spreadsheets.readonly (read-only, no writes).

The 4 spreadsheets:
    - Scheduling (Plan tab) — SKU mapping, SOH, velocity, COGS breakdown
    - Cashflow             — forecasting inputs
    - Crop 2026            — vineyard operations  (read-only, not synced yet)
    - Inventory            — stock position        (read-only, not synced yet)

Usage:
    from connectors.google_sheets import GoogleSheetsConnector

    conn = GoogleSheetsConnector(
        service_account_path="config/service_account.json",
        db_connection_string="postgresql://localhost/moppity_db",
    )
    counts = conn.sync_all()
    # {'scheduling': 247, 'cashflow': 85}
"""

import json
import logging
import os
import sys
from typing import Any

import gspread
import psycopg2
from google.oauth2.service_account import Credentials

from etl.logger import log_etl_run

logger = logging.getLogger("moppity.connectors.google_sheets")

# Google API scopes — read-only access to spreadsheets
SCOPES = ["https://www.googleapis.com/auth/spreadsheets.readonly"]

# Spreadsheet IDs extracted from the owner's shared URLs
SPREADSHEET_IDS = {
    "scheduling": os.environ.get("GOOGLE_SHEET_SCHEDULING_ID", ""),
    "cashflow": os.environ.get("GOOGLE_SHEET_CASHFLOW_ID", ""),
    "crop_2026": os.environ.get("GOOGLE_SHEET_CROP_2026_ID", ""),
    "inventory": os.environ.get("GOOGLE_SHEET_INVENTORY_ID", ""),
}

# Staging table name whitelist — prevents SQL injection since table names
# cannot be parameterised in psycopg2
ALLOWED_STAGING_TABLES = {
    "staging_sheets_scheduling",
    "staging_sheets_cashflow",
    "staging_sheets_wholesale",
}


class GoogleSheetsConnector:
    """Connector for Google Sheets via service account (read-only).

    Authenticates with a service account JSON key, pulls data from
    The owner's planning spreadsheets, and stores each row as a JSONB
    record in PostgreSQL staging tables.

    Attributes:
        gc: Authorised gspread client.
        db_conn: Active psycopg2 connection to moppity_db.
    """

    def __init__(
        self,
        service_account_path: str,
        db_connection_string: str,
    ) -> None:
        """Initialise the connector.

        Args:
            service_account_path: Filesystem path to the Google service
                account JSON key file (e.g. ``config/service_account.json``).
            db_connection_string: PostgreSQL connection URI
                (e.g. ``postgresql://localhost/moppity_db``).

        Raises:
            FileNotFoundError: If the service account file does not exist.
            ValueError: If either argument is empty.
            psycopg2.OperationalError: If the database is unreachable.
            google.auth.exceptions.DefaultCredentialsError: If the key file
                is malformed.
        """
        if not service_account_path:
            raise ValueError("service_account_path must not be empty")
        if not db_connection_string:
            raise ValueError("db_connection_string must not be empty")
        if not os.path.isfile(service_account_path):
            raise FileNotFoundError(
                f"Service account file not found: {service_account_path}"
            )

        # Authenticate with Google
        credentials = Credentials.from_service_account_file(
            service_account_path, scopes=SCOPES
        )
        self.gc = gspread.authorize(credentials)

        # Connect to Postgres
        self.db_conn = psycopg2.connect(db_connection_string)
        self.db_conn.autocommit = False

        self._last_error: str | None = None

        logger.info(
            "GoogleSheetsConnector initialised "
            "(service_account=%s, sheets=%d)",
            service_account_path,
            len(SPREADSHEET_IDS),
        )

    # ------------------------------------------------------------------ #
    # Public sync methods
    # ------------------------------------------------------------------ #

    def sync_scheduling(self) -> int:
        """Pull the Scheduling spreadsheet 'Plan' tab into Postgres.

        The Plan tab contains SKU mapping data, stock-on-hand, velocity
        metrics, and COGS breakdown that feeds into M1-07 code mapping.

        Staging table: staging_sheets_scheduling
        Strategy: truncate-and-reload (planning data, not transactional).

        Returns:
            Number of rows written to staging_sheets_scheduling.
        """
        return self._sync_sheet(
            spreadsheet_id=SPREADSHEET_IDS["scheduling"],
            sheet_index=0,  # First sheet = Plan tab
            staging_table="staging_sheets_scheduling",
            source_label="scheduling",
        )

    def sync_cashflow(self) -> int:
        """Pull the Cashflow spreadsheet first sheet into Postgres.

        Contains cashflow forecasting inputs linked to bottling schedules
        and grape revenue timing.

        Staging table: staging_sheets_cashflow
        Strategy: truncate-and-reload.

        Returns:
            Number of rows written to staging_sheets_cashflow.
        """
        return self._sync_sheet(
            spreadsheet_id=SPREADSHEET_IDS["cashflow"],
            sheet_index=0,
            staging_table="staging_sheets_cashflow",
            source_label="cashflow",
        )

    def sync_wholesale_prices(self) -> int:
        """Pull the 'Vladimir notes' tab from Scheduling spreadsheet.

        Contains wholesale price history by SKU and date range.
        Used to calculate discount = wholesale_price - net_revenue.

        Staging table: staging_sheets_wholesale
        Strategy: truncate-and-reload.

        Returns:
            Number of rows written to staging_sheets_wholesale.
        """
        return self._sync_sheet_by_name(
            spreadsheet_id=SPREADSHEET_IDS["scheduling"],
            sheet_name="Vladimir notes",
            staging_table="staging_sheets_wholesale",
            source_label="wholesale",
        )

    def sync_all(self) -> dict[str, int]:
        """Run all sheet sync operations and log the overall result.

        Currently syncs Scheduling (Plan tab) and Cashflow. Crop 2026
        and Inventory are not yet synced (no staging tables defined).

        Returns:
            Dict mapping sheet label to rows synced, e.g.
            ``{'scheduling': 247, 'cashflow': 85}``.
        """
        results: dict[str, int] = {}
        errors: list[str] = []

        for label, method in [
            ("scheduling", self.sync_scheduling),
            ("cashflow", self.sync_cashflow),
            ("wholesale", self.sync_wholesale_prices),
        ]:
            try:
                count = method()
                results[label] = count
                logger.info("sync_%s completed: %d rows", label, count)
            except Exception as exc:
                results[label] = 0
                error_msg = f"{label}: {exc}"
                errors.append(error_msg)
                logger.error("sync_%s failed: %s", label, exc)

        # Log the overall sync_all run to etl_run_log
        total_rows = sum(results.values())
        status = (
            "success" if not errors
            else ("partial" if total_rows > 0 else "error")
        )

        log_etl_run(
            db_conn=self.db_conn,
            source="google_sheets",
            endpoint="sync_all",
            status=status,
            rows_processed=total_rows,
            rows_skipped=0,
            error_count=len(errors),
            error_detail="; ".join(errors) if errors else None,
        )

        logger.info(
            "sync_all finished: status=%s total_rows=%d errors=%d",
            status, total_rows, len(errors),
        )
        return results

    def get_connection_status(self) -> dict[str, Any]:
        """Check whether we can reach Google Sheets and report status.

        Attempts to open the Scheduling spreadsheet (lightest call)
        to verify credentials and sharing permissions.

        Returns:
            Dict with keys:
                - connected (bool): True if the API responds.
                - last_sync (str | None): ISO timestamp of last successful
                  sync from etl_run_log, or None.
                - error (str | None): Error message if not connected.
        """
        result: dict[str, Any] = {
            "connected": False,
            "last_sync": None,
            "error": None,
        }

        # Check last sync from etl_run_log
        try:
            with self.db_conn.cursor() as cur:
                cur.execute(
                    """
                    SELECT run_timestamp
                    FROM etl_run_log
                    WHERE source = %s AND status IN ('success', 'partial')
                    ORDER BY run_timestamp DESC
                    LIMIT 1
                    """,
                    ("google_sheets",),
                )
                row = cur.fetchone()
                if row:
                    result["last_sync"] = row[0].isoformat()
        except Exception as exc:
            logger.warning(
                "Could not query etl_run_log for last sync: %s", exc
            )
            self.db_conn.rollback()

        # Verify we can reach the Sheets API
        try:
            spreadsheet = self.gc.open_by_key(
                SPREADSHEET_IDS["scheduling"]
            )
            # Access the title to confirm the API call succeeded
            _ = spreadsheet.title
            result["connected"] = True
            self._last_error = None
        except gspread.exceptions.SpreadsheetNotFound:
            msg = (
                "Scheduling spreadsheet not found. "
                "Ensure the sheet is shared with the service account email."
            )
            result["error"] = msg
            self._last_error = msg
            logger.error(msg)
        except gspread.exceptions.APIError as exc:
            msg = f"Google Sheets API error: {exc}"
            result["error"] = msg
            self._last_error = msg
            logger.error(msg)
        except Exception as exc:
            msg = f"Google Sheets connection check failed: {exc}"
            result["error"] = msg
            self._last_error = msg
            logger.error(msg)

        return result

    def close(self) -> None:
        """Close the database connection."""
        if self.db_conn and not self.db_conn.closed:
            self.db_conn.close()
        logger.info("GoogleSheetsConnector closed.")

    # ------------------------------------------------------------------ #
    # Internal: fetch sheet data and write to staging
    # ------------------------------------------------------------------ #

    def _sync_sheet(
        self,
        spreadsheet_id: str,
        sheet_index: int,
        staging_table: str,
        source_label: str,
    ) -> int:
        """Fetch all rows from a Google Sheet and write to a staging table.

        Uses truncate-and-reload: the staging table is cleared before
        inserting fresh data. This is appropriate for planning sheets
        (not transactional data) where the entire sheet is the
        source of truth.

        Args:
            spreadsheet_id: Google Sheets document ID.
            sheet_index: Zero-based index of the worksheet tab to read.
            staging_table: Target Postgres table name.
            source_label: Human label for logging (e.g. 'scheduling').

        Returns:
            Number of rows written to the staging table.

        Raises:
            gspread.exceptions.SpreadsheetNotFound: If the sheet is not
                shared with the service account.
            gspread.exceptions.APIError: On Google API errors.
        """
        if staging_table not in ALLOWED_STAGING_TABLES:
            raise ValueError(f"Unknown staging table: {staging_table}")

        logger.info(
            "Starting sync: sheet=%s table=%s",
            source_label, staging_table,
        )

        rows_written = 0
        error_detail = None

        try:
            # Open the spreadsheet and get the target worksheet
            spreadsheet = self.gc.open_by_key(spreadsheet_id)
            worksheet = spreadsheet.get_worksheet(sheet_index)

            if worksheet is None:
                raise ValueError(
                    f"Worksheet at index {sheet_index} not found in "
                    f"spreadsheet {spreadsheet_id}"
                )

            # get_all_records() returns a list of dicts using row 1 as headers.
            # Empty rows at the bottom are automatically excluded by gspread.
            records = worksheet.get_all_records()

            logger.info(
                "Fetched %d rows from '%s' (sheet: %s)",
                len(records), worksheet.title, spreadsheet.title,
            )

            # Truncate-and-reload within a single transaction
            rows_written = self._write_staging(
                staging_table, records
            )

        except gspread.exceptions.SpreadsheetNotFound:
            error_detail = (
                f"Spreadsheet {spreadsheet_id} not found. "
                "Check sharing with service account."
            )
            logger.error(error_detail)
            raise

        except gspread.exceptions.APIError as exc:
            error_detail = f"Google API error: {exc}"
            logger.error(error_detail)
            raise

        except Exception as exc:
            error_detail = f"Unexpected error syncing {source_label}: {exc}"
            logger.error(error_detail, exc_info=True)
            raise

        finally:
            # Always log the ETL run, even on failure
            status = "success" if rows_written > 0 and not error_detail else "error"
            if rows_written > 0 and error_detail:
                status = "partial"

            try:
                log_etl_run(
                    db_conn=self.db_conn,
                    source="google_sheets",
                    endpoint=source_label,
                    status=status,
                    rows_processed=rows_written,
                    rows_skipped=0,
                    error_count=1 if error_detail else 0,
                    error_detail=error_detail,
                )
            except Exception as log_exc:
                logger.error(
                    "Failed to log ETL run for %s: %s",
                    source_label, log_exc,
                )

        return rows_written

    def _sync_sheet_by_name(
        self,
        spreadsheet_id: str,
        sheet_name: str,
        staging_table: str,
        source_label: str,
    ) -> int:
        """Fetch rows from a named worksheet tab and write to staging.

        Same as _sync_sheet but uses tab name instead of index.

        Args:
            spreadsheet_id: Google Sheets document ID.
            sheet_name: Name of the worksheet tab (e.g. 'Vladimir notes').
            staging_table: Target Postgres table name.
            source_label: Human label for logging.

        Returns:
            Number of rows written to the staging table.
        """
        if staging_table not in ALLOWED_STAGING_TABLES:
            raise ValueError(f"Unknown staging table: {staging_table}")

        logger.info(
            "Starting sync: sheet=%s (tab=%s) table=%s",
            source_label, sheet_name, staging_table,
        )

        rows_written = 0
        error_detail = None

        try:
            spreadsheet = self.gc.open_by_key(spreadsheet_id)
            worksheet = spreadsheet.worksheet(sheet_name)

            records = worksheet.get_all_records()

            logger.info(
                "Fetched %d rows from '%s' (sheet: %s)",
                len(records), worksheet.title, spreadsheet.title,
            )

            rows_written = self._write_staging(staging_table, records)

        except gspread.exceptions.WorksheetNotFound:
            error_detail = (
                f"Worksheet '{sheet_name}' not found in spreadsheet. "
                "Check that the tab exists."
            )
            logger.error(error_detail)
            raise

        except gspread.exceptions.SpreadsheetNotFound:
            error_detail = (
                f"Spreadsheet {spreadsheet_id} not found. "
                "Check sharing with service account."
            )
            logger.error(error_detail)
            raise

        except gspread.exceptions.APIError as exc:
            error_detail = f"Google API error: {exc}"
            logger.error(error_detail)
            raise

        except Exception as exc:
            error_detail = f"Unexpected error syncing {source_label}: {exc}"
            logger.error(error_detail, exc_info=True)
            raise

        finally:
            status = "success" if rows_written > 0 and not error_detail else "error"
            if rows_written > 0 and error_detail:
                status = "partial"

            try:
                log_etl_run(
                    db_conn=self.db_conn,
                    source="google_sheets",
                    endpoint=source_label,
                    status=status,
                    rows_processed=rows_written,
                    rows_skipped=0,
                    error_count=1 if error_detail else 0,
                    error_detail=error_detail,
                )
            except Exception as log_exc:
                logger.error(
                    "Failed to log ETL run for %s: %s",
                    source_label, log_exc,
                )

        return rows_written

    def _write_staging(
        self,
        table_name: str,
        records: list[dict[str, Any]],
    ) -> int:
        """Truncate a staging table and insert fresh records.

        Each record (a dict from get_all_records) is stored as a JSONB
        value in the ``raw_data`` column.

        Args:
            table_name: Target staging table (must be in ALLOWED_STAGING_TABLES).
            records: List of dicts — one per spreadsheet row.

        Returns:
            Number of rows inserted.
        """
        if table_name not in ALLOWED_STAGING_TABLES:
            raise ValueError(f"Unknown staging table: {table_name}")

        if not records:
            logger.info("No records to write to %s.", table_name)
            return 0

        rows_written = 0

        try:
            with self.db_conn.cursor() as cur:
                # Truncate old data — planning sheets are full-reload
                # Table name is validated above, safe to interpolate.
                cur.execute(f"TRUNCATE TABLE {table_name}")

                for record in records:
                    # Skip fully empty rows (all values blank)
                    if all(v == "" or v is None for v in record.values()):
                        continue

                    raw_json = json.dumps(record, default=str)

                    cur.execute(
                        f"""
                        INSERT INTO {table_name} (raw_data, fetched_at)
                        VALUES (%s::jsonb, NOW())
                        """,
                        (raw_json,),
                    )
                    rows_written += 1

            self.db_conn.commit()

        except Exception as exc:
            self.db_conn.rollback()
            logger.error(
                "Failed to write %d records to %s: %s",
                len(records), table_name, exc,
            )
            raise

        logger.info(
            "Wrote %d rows to %s (skipped %d empty rows).",
            rows_written, table_name, len(records) - rows_written,
        )
        return rows_written


# ------------------------------------------------------------------ #
# CLI entry point
# ------------------------------------------------------------------ #

if __name__ == "__main__":
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )

    service_account_path = os.environ.get("SERVICE_ACCOUNT_PATH")
    database_url = os.environ.get("DATABASE_URL")

    if not service_account_path:
        logger.error("SERVICE_ACCOUNT_PATH environment variable is not set.")
        sys.exit(1)
    if not database_url:
        logger.error("DATABASE_URL environment variable is not set.")
        sys.exit(1)

    connector = GoogleSheetsConnector(
        service_account_path=service_account_path,
        db_connection_string=database_url,
    )

    try:
        # Check connection first
        status = connector.get_connection_status()
        if not status["connected"]:
            logger.error(
                "Cannot connect to Google Sheets: %s", status["error"]
            )
            sys.exit(1)

        logger.info("Google Sheets connection OK.")

        # Run full sync
        results = connector.sync_all()
        logger.info("Sync results: %s", results)

        total = sum(results.values())
        if total == 0:
            logger.warning(
                "No records synced. Check that sheets are shared "
                "with the service account email."
            )
            sys.exit(1)

        sys.exit(0)

    except Exception as exc:
        logger.error(
            "Unexpected error during sync: %s", exc, exc_info=True
        )
        sys.exit(1)
    finally:
        connector.close()
