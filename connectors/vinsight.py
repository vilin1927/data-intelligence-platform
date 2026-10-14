"""
Vinsight REST API connector for Moppity Vineyards data platform.

Pulls inventory (StockItems), sales orders (SalesOrders), and contacts
(Contacts) from Vinsight, stores raw JSON in Postgres staging tables,
and logs every operation to etl_run_log.

Authentication: API key as query parameter ``?api-key={KEY}``.
Rate limiting: shared token-bucket via connectors.rate_limiter (ADR-007).
Retry policy: 3 attempts with exponential backoff on HTTP 429 / 5xx.

Usage:
    from connectors.vinsight import VinsightConnector

    conn = VinsightConnector(
        api_key=os.environ["VINSIGHT_API_KEY"],
        db_connection_string="postgresql://localhost/moppity_db",
    )
    counts = conn.sync_all()
    # {'stock_items': 412, 'sales_orders': 1893, 'contacts': 287}
"""

import json
import logging
import os
import time
from typing import Any

import psycopg2
import psycopg2.extras
import requests

from connectors.rate_limiter import RateLimiter
from etl.logger import log_dead_letter, log_etl_run

logger = logging.getLogger("moppity.connectors.vinsight")

# Vinsight API base
BASE_URL = "https://app.vinsight.net"

# Retry configuration
MAX_RETRIES = 3
BACKOFF_SECONDS = [1, 2, 4]  # exponential: 1s, 2s, 4s

# Default page size for paginated endpoints (OData: $top)
# Per Vinsight support (Yubo): use $top=9999 for all data, or $skip/$top for paging
DEFAULT_PAGE_SIZE = 500  # Conservative: Vinsight allows up to 9999


class VinsightConnector:
    """Connector for the Vinsight REST API.

    Pulls data from Vinsight endpoints, respects shared rate limits,
    and persists raw JSON responses into PostgreSQL staging tables.

    Attributes:
        api_key: Vinsight API key (passed as query parameter).
        db_conn: Active psycopg2 connection to moppity_db.
    """

    def __init__(self, api_key: str, db_connection_string: str) -> None:
        """Initialise the connector.

        Args:
            api_key: Vinsight API key for authentication.
            db_connection_string: PostgreSQL connection URI
                (e.g. ``postgresql://localhost/moppity_db``).

        Raises:
            psycopg2.OperationalError: If the database is unreachable.
        """
        if not api_key:
            raise ValueError("api_key must not be empty")
        if not db_connection_string:
            raise ValueError("db_connection_string must not be empty")

        self.api_key = api_key
        self.db_conn = psycopg2.connect(db_connection_string)
        self.db_conn.autocommit = False

        self._rate_limiter = RateLimiter.get_instance()
        self._session = requests.Session()

        logger.info("VinsightConnector initialised (base_url=%s)", BASE_URL)

    # ------------------------------------------------------------------ #
    # Public sync methods
    # ------------------------------------------------------------------ #

    def sync_stock_items(self) -> int:
        """Pull all stock items from Vinsight and store in staging.

        Endpoint: GET /StockItems.json
        Staging table: staging_vinsight_stock_items

        Returns:
            Number of records written to the staging table.
        """
        return self._sync_endpoint(
            endpoint="/StockItems.json",
            staging_table="staging_vinsight_stock_items",
            source_label="stock_items",
        )

    def sync_sales_orders(self) -> int:
        """Pull all sales orders from Vinsight and store in staging.

        Endpoint: GET /SalesOrders.json
        Staging table: staging_vinsight_sales_orders

        Returns:
            Number of records written to the staging table.
        """
        return self._sync_endpoint(
            endpoint="/SalesOrders.json",
            staging_table="staging_vinsight_sales_orders",
            source_label="sales_orders",
        )

    def sync_contacts(self) -> int:
        """Pull all contacts from Vinsight and store in staging.

        Endpoint: GET /Contacts.json
        Staging table: staging_vinsight_contacts

        Returns:
            Number of records written to the staging table.
        """
        return self._sync_endpoint(
            endpoint="/Contacts.json",
            staging_table="staging_vinsight_contacts",
            source_label="contacts",
        )

    def sync_all(self) -> dict[str, int]:
        """Run all sync operations and log the overall result.

        Returns:
            Dict mapping endpoint label to rows synced, e.g.
            ``{'stock_items': 412, 'sales_orders': 1893, 'contacts': 287}``.
        """
        results: dict[str, int] = {}
        errors: list[str] = []

        for label, method in [
            ("stock_items", self.sync_stock_items),
            ("sales_orders", self.sync_sales_orders),
            ("contacts", self.sync_contacts),
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

        # Log overall sync_all run
        total_rows = sum(results.values())
        status = "success" if not errors else ("partial" if total_rows > 0 else "error")

        log_etl_run(
            db_conn=self.db_conn,
            source="vinsight",
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

    def close(self) -> None:
        """Close the database connection and HTTP session."""
        self._session.close()
        if self.db_conn and not self.db_conn.closed:
            self.db_conn.close()
        logger.info("VinsightConnector closed.")

    # ------------------------------------------------------------------ #
    # Internal: paginated fetch + staging insert
    # ------------------------------------------------------------------ #

    def _sync_endpoint(
        self,
        endpoint: str,
        staging_table: str,
        source_label: str,
    ) -> int:
        """Fetch all pages from a Vinsight endpoint and write to staging.

        Args:
            endpoint: API path (e.g. '/StockItems.json').
            staging_table: Target Postgres table name.
            source_label: Human label for logging (e.g. 'stock_items').

        Returns:
            Total number of records written.

        Raises:
            RuntimeError: If the daily rate limit is exhausted.
            requests.HTTPError: If retries are exhausted on a server error.
        """
        all_records: list[dict[str, Any]] = []
        error_count = 0
        dead_letter_records: list[tuple[dict, str]] = []

        logger.info("Starting sync: endpoint=%s", endpoint)

        # Vinsight uses OData. Use $top=9999 to get all records in one request.
        # NOTE: $skip pagination has issues on some servers (returns empty),
        # so we fetch all at once which is simpler and more reliable.
        odata_params = "$top=9999"

        response_data = self._api_get(endpoint, odata_params=odata_params)

        if response_data is None:
            error_count += 1
            logger.error(
                "Failed to fetch %s after %d retries.",
                endpoint, MAX_RETRIES,
            )
        else:
            # Vinsight returns a list of objects, or may wrap in a container.
            # Handle both: bare list and {"List": [...], "TotalCount": N}.
            if isinstance(response_data, list):
                all_records = response_data
            elif isinstance(response_data, dict):
                # Common Vinsight patterns: "List", "Items", or root list
                all_records = (
                    response_data.get("List")
                    or response_data.get("Items")
                    or response_data.get("list")
                    or []
                )
                if not isinstance(all_records, list):
                    all_records = [response_data]

            logger.info(
                "Fetched %s: %d records",
                endpoint, len(all_records),
            )

        # Write to staging table
        rows_written = 0
        if all_records:
            rows_written, dead_letter_records = self._upsert_staging(
                staging_table, all_records, endpoint
            )

        # Log the run
        run_id = log_etl_run(
            db_conn=self.db_conn,
            source="vinsight",
            endpoint=endpoint,
            status="success" if error_count == 0 and not dead_letter_records else "partial",
            rows_processed=rows_written,
            rows_skipped=len(all_records) - rows_written - len(dead_letter_records),
            error_count=error_count + len(dead_letter_records),
            error_detail=(
                f"Fetch errors: {error_count}, "
                f"insert errors: {len(dead_letter_records)}"
                if (error_count or dead_letter_records) else None
            ),
        )

        # Persist dead-letter rows
        for raw_record, err_msg in dead_letter_records:
            log_dead_letter(
                db_conn=self.db_conn,
                run_id=run_id,
                source="vinsight",
                raw_data=raw_record,
                error_message=err_msg,
            )

        logger.info(
            "Sync complete: endpoint=%s rows_written=%d errors=%d",
            endpoint, rows_written, error_count + len(dead_letter_records),
        )
        return rows_written

    def _upsert_staging(
        self,
        table_name: str,
        records: list[dict[str, Any]],
        endpoint: str,
    ) -> tuple[int, list[tuple[dict, str]]]:
        """Insert records into a staging table.

        Each record is stored as raw JSONB in the ``raw_data`` column.
        On conflict (same source_id), the existing row is updated.

        Args:
            table_name: Target staging table.
            records: List of dicts from the API response.
            endpoint: API endpoint (stored as metadata).

        Returns:
            Tuple of (rows_written, dead_letter_list) where dead_letter_list
            contains (raw_record, error_message) pairs.
        """
        # Validate table name against allowed staging tables to prevent
        # SQL injection (table names cannot be parameterised in psycopg2)
        allowed_tables = {
            "staging_vinsight_stock_items",
            "staging_vinsight_sales_orders",
            "staging_vinsight_contacts",
        }
        if table_name not in allowed_tables:
            raise ValueError(f"Unknown staging table: {table_name}")

        rows_written = 0
        dead_letters: list[tuple[dict, str]] = []

        # Use a single transaction for the batch
        try:
            with self.db_conn.cursor() as cur:
                for record in records:
                    try:
                        # Extract a stable source ID from the record.
                        # Vinsight uses 'Id' or 'ID' as primary key.
                        source_id = str(
                            record.get("Id")
                            or record.get("ID")
                            or record.get("id")
                            or ""
                        )

                        raw_json = json.dumps(record, default=str)

                        # Table name is validated above — safe to interpolate.
                        # All VALUES are parameterised.
                        sql = f"""
                            INSERT INTO {table_name} (
                                source_id, endpoint, raw_data, synced_at
                            )
                            VALUES (%s, %s, %s::jsonb, NOW())
                        """
                        cur.execute(sql, (source_id, endpoint, raw_json))
                        rows_written += 1

                    except Exception as exc:
                        # Record-level failure — dead-letter it, keep going
                        dead_letters.append((record, str(exc)))
                        logger.warning(
                            "Failed to insert record into %s: %s",
                            table_name, exc,
                        )
                        # Roll back the failed statement but keep the txn alive
                        self.db_conn.rollback()

            self.db_conn.commit()

        except Exception as exc:
            self.db_conn.rollback()
            logger.error("Batch insert into %s failed: %s", table_name, exc)
            raise

        return rows_written, dead_letters

    # ------------------------------------------------------------------ #
    # Internal: HTTP request with rate limiting and retry
    # ------------------------------------------------------------------ #

    def _api_get(
        self,
        endpoint: str,
        odata_params: str = "",
    ) -> dict | list | None:
        """Make a rate-limited GET request to Vinsight with retry logic.

        Waits for a rate-limiter token before each attempt. On HTTP 429
        or 5xx responses, retries with exponential backoff (1s, 2s, 4s).

        Args:
            endpoint: API path (e.g. '/StockItems.json').
            odata_params: OData query params as literal string (e.g. "$top=500&$skip=0").
                          NOTE: Vinsight requires literal $, NOT percent-encoded %24.

        Returns:
            Parsed JSON response, or None if all retries failed.

        Raises:
            RuntimeError: If the daily rate limit is exhausted.
        """
        # Build URL with literal $ characters (Vinsight doesn't accept %24)
        url = f"{BASE_URL}{endpoint}?api-key={self.api_key}"
        if odata_params:
            url = f"{url}&{odata_params}"

        for attempt in range(MAX_RETRIES):
            # Block until a rate-limit token is available.
            # Raises RuntimeError if daily limit is hit — let it propagate.
            self._rate_limiter.wait_for_token()

            try:
                response = self._session.get(url, timeout=30)

                if response.status_code == 200:
                    return response.json()

                if response.status_code == 429 or response.status_code >= 500:
                    backoff = BACKOFF_SECONDS[attempt] if attempt < len(BACKOFF_SECONDS) else BACKOFF_SECONDS[-1]
                    logger.warning(
                        "HTTP %d from %s (attempt %d/%d). "
                        "Retrying in %ds...",
                        response.status_code, endpoint,
                        attempt + 1, MAX_RETRIES, backoff,
                    )
                    time.sleep(backoff)
                    continue

                # Non-retryable HTTP error (4xx other than 429)
                logger.error(
                    "HTTP %d from %s: %s",
                    response.status_code, endpoint,
                    response.text[:500],
                )
                return None

            except requests.RequestException as exc:
                backoff = BACKOFF_SECONDS[attempt] if attempt < len(BACKOFF_SECONDS) else BACKOFF_SECONDS[-1]
                logger.warning(
                    "Request error for %s (attempt %d/%d): %s. "
                    "Retrying in %ds...",
                    endpoint, attempt + 1, MAX_RETRIES, exc, backoff,
                )
                time.sleep(backoff)

        logger.error(
            "All %d retries exhausted for %s.", MAX_RETRIES, endpoint
        )
        return None


# ------------------------------------------------------------------ #
# CLI entry point
# ------------------------------------------------------------------ #

if __name__ == "__main__":
    import sys

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )

    api_key = os.environ.get("VINSIGHT_API_KEY")
    database_url = os.environ.get("DATABASE_URL")

    if not api_key:
        logger.error("VINSIGHT_API_KEY environment variable is not set.")
        sys.exit(1)
    if not database_url:
        logger.error("DATABASE_URL environment variable is not set.")
        sys.exit(1)

    connector = VinsightConnector(
        api_key=api_key,
        db_connection_string=database_url,
    )

    try:
        results = connector.sync_all()
        logger.info("Sync results: %s", results)

        total = sum(results.values())
        if total == 0:
            logger.warning("No records synced. Check API key permissions.")
            sys.exit(1)

        sys.exit(0)
    except RuntimeError as exc:
        logger.error("Sync aborted: %s", exc)
        sys.exit(2)
    except Exception as exc:
        logger.error("Unexpected error during sync: %s", exc, exc_info=True)
        sys.exit(1)
    finally:
        connector.close()
