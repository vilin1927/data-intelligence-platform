"""
Xero API Connector for Moppity Vineyards.

Connects to two Xero tenants via OAuth 2.0:
  - Moppity Trust (grape costs)
  - Moppity Wines Pty Ltd (wine sales)

Syncs Invoices, Contacts, and Accounts (chart of accounts) into
staging_xero_* tables in Postgres.  Uses the shared rate limiter
(ADR-007) and ETL logger.

Usage:
    python -m connectors.xero          # sync both tenants
    python connectors/xero.py          # sync both tenants (standalone)

Environment variables (or pass to constructor):
    XERO_CLIENT_ID, XERO_CLIENT_SECRET, XERO_TOKEN_FILE, DATABASE_URL
"""

from __future__ import annotations

import json
import logging
import os
import time
from base64 import b64encode
from datetime import datetime, timezone
from typing import Any

import psycopg2
import psycopg2.extras
import requests

# ---------------------------------------------------------------------------
# Shared infrastructure imports (M1-09).  These modules may not exist yet;
# provide graceful fallbacks so the connector can be developed and tested
# independently.
# ---------------------------------------------------------------------------
try:
    from connectors.rate_limiter import wait_for_token  # ADR-007
except ImportError:
    def wait_for_token() -> None:  # noqa: D401
        """No-op fallback when rate_limiter is not yet available."""


try:
    from etl.logger import log_etl_run
except ImportError:
    def log_etl_run(  # type: ignore[misc]
        conn: Any,
        *,
        source: str,
        status: str,
        rows_processed: int = 0,
        rows_skipped: int = 0,
        errors: str | None = None,
        details: str | None = None,
    ) -> None:
        """No-op fallback when etl.logger is not yet available."""


logger = logging.getLogger(__name__)
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
XERO_TOKEN_URL = "https://identity.xero.com/connect/token"
XERO_API_BASE = "https://api.xero.com/api.xro/2.0"

TENANTS = {
    "trust": {
        "tenant_id": "00000000-0000-4000-8000-000000000001",
        "name": "Moppity Trust",
    },
    "wines": {
        "tenant_id": "00000000-0000-4000-8000-000000000002",
        "name": "Moppity Wines Pty Ltd",
    },
}

MAX_RETRIES = 3
INITIAL_BACKOFF_SECS = 1.0
RETRYABLE_STATUS_CODES = {429, 500, 503}

# Xero access tokens last 30 minutes.  Refresh proactively when fewer than
# 5 minutes remain.
TOKEN_REFRESH_BUFFER_SECS = 300


# ---------------------------------------------------------------------------
# Schema helpers — ensure staging tables exist
# ---------------------------------------------------------------------------
_STAGING_DDL = {
    "staging_xero_invoices": """
        CREATE TABLE IF NOT EXISTS staging_xero_invoices (
            id              SERIAL PRIMARY KEY,
            tenant_id       VARCHAR(64)  NOT NULL,
            invoice_id      VARCHAR(64)  NOT NULL,
            invoice_number  VARCHAR(64),
            invoice_type    VARCHAR(32),
            contact_name    VARCHAR(256),
            contact_id      VARCHAR(64),
            status          VARCHAR(32),
            date            DATE,
            due_date        DATE,
            currency_code   VARCHAR(8),
            sub_total       DECIMAL(12,2),
            total_tax       DECIMAL(12,2),
            total           DECIMAL(12,2),
            amount_due      DECIMAL(12,2),
            amount_paid     DECIMAL(12,2),
            raw_json        JSONB,
            synced_at       TIMESTAMP NOT NULL DEFAULT NOW(),
            UNIQUE(tenant_id, invoice_id)
        );
    """,
    "staging_xero_contacts": """
        CREATE TABLE IF NOT EXISTS staging_xero_contacts (
            id              SERIAL PRIMARY KEY,
            tenant_id       VARCHAR(64)  NOT NULL,
            contact_id      VARCHAR(64)  NOT NULL,
            contact_name    VARCHAR(256),
            contact_status  VARCHAR(32),
            email           VARCHAR(256),
            is_supplier     BOOLEAN,
            is_customer     BOOLEAN,
            raw_json        JSONB,
            synced_at       TIMESTAMP NOT NULL DEFAULT NOW(),
            UNIQUE(tenant_id, contact_id)
        );
    """,
    "staging_xero_accounts": """
        CREATE TABLE IF NOT EXISTS staging_xero_accounts (
            id              SERIAL PRIMARY KEY,
            tenant_id       VARCHAR(64)  NOT NULL,
            account_id      VARCHAR(64)  NOT NULL,
            code            VARCHAR(32),
            name            VARCHAR(256),
            account_type    VARCHAR(64),
            tax_type        VARCHAR(64),
            "class"         VARCHAR(64),
            status          VARCHAR(32),
            raw_json        JSONB,
            synced_at       TIMESTAMP NOT NULL DEFAULT NOW(),
            UNIQUE(tenant_id, account_id)
        );
    """,
}


class XeroConnector:
    """Sync Invoices, Contacts, and Accounts from Xero into Postgres staging tables.

    Handles OAuth 2.0 token refresh, rate limiting (ADR-007), and retry with
    exponential backoff on transient errors.
    """

    def __init__(
        self,
        client_id: str,
        client_secret: str,
        token_file_path: str,
        db_connection_string: str,
    ) -> None:
        """Initialise the Xero connector.

        Args:
            client_id: Xero OAuth app client ID.
            client_secret: Xero OAuth app client secret.
            token_file_path: Path to xero_tokens.json (read/write).
            db_connection_string: PostgreSQL DSN or keyword connection string.
        """
        self.client_id = client_id
        self.client_secret = client_secret
        self.token_file_path = token_file_path
        self.db_connection_string = db_connection_string

        # Loaded lazily by _ensure_tokens()
        self._access_token: str | None = None
        self._refresh_token: str | None = None
        self._token_expiry: float = 0.0  # epoch seconds

        self._session = requests.Session()
        self._load_tokens()

    # ------------------------------------------------------------------
    # Token management
    # ------------------------------------------------------------------

    def _load_tokens(self) -> None:
        """Load tokens from the JSON file written by xero_auth.py."""
        try:
            with open(self.token_file_path, "r") as fh:
                data = json.load(fh)
        except (FileNotFoundError, json.JSONDecodeError) as exc:
            raise RuntimeError(
                f"Cannot read Xero token file at {self.token_file_path}: {exc}"
            ) from exc

        tokens = data.get("tokens", {})
        self._access_token = tokens.get("access_token")
        self._refresh_token = tokens.get("refresh_token")

        # The file does not persist the exact expiry timestamp.  Assume the
        # token is already expired so the first API call triggers a refresh.
        self._token_expiry = 0.0

        if not self._refresh_token:
            raise RuntimeError(
                "No refresh_token found in token file.  "
                "Re-run xero_auth.py to re-authorise."
            )

        logger.info("Loaded Xero tokens from %s", self.token_file_path)

    def _refresh_token_if_needed(self) -> None:
        """Refresh the access token if it has expired or is close to expiry.

        Posts to Xero's token endpoint using Basic auth (client_id:client_secret).
        On success, saves the new tokens back to the JSON file so future runs
        can pick them up without re-authorisation.
        """
        now = time.time()
        if self._access_token and now < (self._token_expiry - TOKEN_REFRESH_BUFFER_SECS):
            return  # Token still valid

        logger.info("Refreshing Xero access token ...")

        credentials = b64encode(
            f"{self.client_id}:{self.client_secret}".encode()
        ).decode()

        for attempt in range(1, MAX_RETRIES + 1):
            try:
                resp = requests.post(
                    XERO_TOKEN_URL,
                    headers={
                        "Authorization": f"Basic {credentials}",
                        "Content-Type": "application/x-www-form-urlencoded",
                    },
                    data={
                        "grant_type": "refresh_token",
                        "refresh_token": self._refresh_token,
                    },
                    timeout=30,
                )
                resp.raise_for_status()
                break
            except requests.RequestException as exc:
                if attempt == MAX_RETRIES:
                    raise RuntimeError(
                        f"Failed to refresh Xero token after {MAX_RETRIES} attempts"
                    ) from exc
                wait = INITIAL_BACKOFF_SECS * (2 ** (attempt - 1))
                logger.warning(
                    "Token refresh attempt %d failed (%s), retrying in %.1fs ...",
                    attempt, exc, wait,
                )
                time.sleep(wait)

        body = resp.json()
        self._access_token = body["access_token"]
        self._refresh_token = body["refresh_token"]
        self._token_expiry = now + body.get("expires_in", 1800)

        # Persist tokens so the next run (or a concurrent process) picks up
        # the fresh refresh_token.
        self._save_tokens(body)
        logger.info("Xero access token refreshed (expires in %ds)", body.get("expires_in", 1800))

    def _save_tokens(self, token_response: dict[str, Any]) -> None:
        """Write refreshed tokens back to xero_tokens.json.

        Preserves the tenants list from the original file.
        """
        try:
            with open(self.token_file_path, "r") as fh:
                data = json.load(fh)
        except (FileNotFoundError, json.JSONDecodeError):
            data = {}

        data["tokens"] = token_response
        # Keep tenants untouched
        data.setdefault("tenants", [])

        with open(self.token_file_path, "w") as fh:
            json.dump(data, fh, indent=2)

        logger.debug("Tokens saved to %s", self.token_file_path)

    # ------------------------------------------------------------------
    # HTTP request helper with rate limiting + retry
    # ------------------------------------------------------------------

    def _make_request(
        self,
        endpoint: str,
        tenant_id: str,
        params: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        """Make an authenticated GET request to the Xero API.

        Args:
            endpoint: API path relative to the base URL, e.g. ``/Invoices``.
            tenant_id: Xero tenant (organisation) UUID.
            params: Optional query parameters.

        Returns:
            Parsed JSON response body.

        Raises:
            RuntimeError: After exhausting retries on transient errors.
            requests.HTTPError: On non-retryable HTTP errors (4xx other than 429).
        """
        self._refresh_token_if_needed()

        url = f"{XERO_API_BASE}{endpoint}"
        headers = {
            "Authorization": f"Bearer {self._access_token}",
            "Xero-Tenant-Id": tenant_id,
            "Accept": "application/json",
        }

        last_exc: Exception | None = None
        for attempt in range(1, MAX_RETRIES + 1):
            # ADR-007: acquire a rate-limit token before every call
            wait_for_token()

            try:
                resp = self._session.get(
                    url, headers=headers, params=params, timeout=30
                )

                if resp.status_code in RETRYABLE_STATUS_CODES:
                    wait = INITIAL_BACKOFF_SECS * (2 ** (attempt - 1))
                    # Respect Retry-After header if present (Xero sends it on 429)
                    retry_after = resp.headers.get("Retry-After")
                    if retry_after:
                        try:
                            ra = float(retry_after)
                            if ra > 120:
                                # Xero daily limit hit — don't sleep for hours
                                logger.warning(
                                    "Xero %s: Retry-After=%ds exceeds 120s cap — daily limit likely hit, aborting retries.",
                                    endpoint, ra,
                                )
                                raise RuntimeError(
                                    f"Xero daily rate limit hit on {endpoint} (Retry-After: {ra}s). Try again later."
                                )
                            wait = max(wait, ra)
                        except ValueError:
                            pass
                    logger.warning(
                        "Xero %s returned %d (attempt %d/%d), retrying in %.1fs ...",
                        endpoint, resp.status_code, attempt, MAX_RETRIES, wait,
                    )
                    time.sleep(wait)
                    continue

                resp.raise_for_status()
                return resp.json()

            except requests.RequestException as exc:
                last_exc = exc
                if attempt < MAX_RETRIES:
                    wait = INITIAL_BACKOFF_SECS * (2 ** (attempt - 1))
                    logger.warning(
                        "Xero %s network error (attempt %d/%d): %s — retrying in %.1fs",
                        endpoint, attempt, MAX_RETRIES, exc, wait,
                    )
                    time.sleep(wait)

        raise RuntimeError(
            f"Xero API {endpoint} failed after {MAX_RETRIES} retries: {last_exc}"
        )

    # ------------------------------------------------------------------
    # Database helpers
    # ------------------------------------------------------------------

    def _get_connection(self) -> psycopg2.extensions.connection:
        """Open a new Postgres connection."""
        return psycopg2.connect(self.db_connection_string)

    def _ensure_staging_tables(self, conn: psycopg2.extensions.connection) -> None:
        """Create staging tables if they do not already exist."""
        with conn.cursor() as cur:
            for ddl in _STAGING_DDL.values():
                cur.execute(ddl)
        conn.commit()

    # ------------------------------------------------------------------
    # Sync methods
    # ------------------------------------------------------------------

    def sync_invoices(self, tenant_id: str) -> int:
        """Fetch all invoices from a Xero tenant and upsert into staging.

        Xero paginates invoices with ``page=1, 2, ...`` returning up to 100
        per page.  An empty ``Invoices`` list signals end of data.

        Args:
            tenant_id: Xero tenant UUID.

        Returns:
            Total number of invoices upserted.
        """
        logger.info("Syncing invoices for tenant %s ...", tenant_id)
        total = 0
        page = 1

        conn = self._get_connection()
        try:
            self._ensure_staging_tables(conn)

            while True:
                data = self._make_request(
                    "/Invoices", tenant_id, params={"page": page}
                )
                invoices = data.get("Invoices", [])
                if not invoices:
                    break

                with conn.cursor() as cur:
                    for inv in invoices:
                        contact = inv.get("Contact", {})
                        cur.execute(
                            """
                            INSERT INTO staging_xero_invoices
                                (tenant_id, invoice_id, invoice_number, invoice_type,
                                 contact_name, contact_id, status,
                                 date, due_date, currency_code,
                                 sub_total, total_tax, total,
                                 amount_due, amount_paid, raw_json, synced_at)
                            VALUES
                                (%s, %s, %s, %s,
                                 %s, %s, %s,
                                 %s, %s, %s,
                                 %s, %s, %s,
                                 %s, %s, %s, NOW())
                            ON CONFLICT (tenant_id, invoice_id) DO UPDATE SET
                                invoice_number = EXCLUDED.invoice_number,
                                invoice_type   = EXCLUDED.invoice_type,
                                contact_name   = EXCLUDED.contact_name,
                                contact_id     = EXCLUDED.contact_id,
                                status         = EXCLUDED.status,
                                date           = EXCLUDED.date,
                                due_date       = EXCLUDED.due_date,
                                currency_code  = EXCLUDED.currency_code,
                                sub_total      = EXCLUDED.sub_total,
                                total_tax      = EXCLUDED.total_tax,
                                total          = EXCLUDED.total,
                                amount_due     = EXCLUDED.amount_due,
                                amount_paid    = EXCLUDED.amount_paid,
                                raw_json       = EXCLUDED.raw_json,
                                synced_at      = NOW()
                            """,
                            (
                                tenant_id,
                                inv.get("InvoiceID"),
                                inv.get("InvoiceNumber"),
                                inv.get("Type"),
                                contact.get("Name"),
                                contact.get("ContactID"),
                                inv.get("Status"),
                                inv.get("DateString"),
                                inv.get("DueDateString"),
                                inv.get("CurrencyCode"),
                                inv.get("SubTotal"),
                                inv.get("TotalTax"),
                                inv.get("Total"),
                                inv.get("AmountDue"),
                                inv.get("AmountPaid"),
                                json.dumps(inv),
                            ),
                        )
                conn.commit()

                count = len(invoices)
                total += count
                logger.info("  page %d: %d invoices", page, count)
                page += 1

        finally:
            conn.close()

        logger.info("Invoices sync complete: %d total", total)
        return total

    def sync_contacts(self, tenant_id: str) -> int:
        """Fetch all contacts from a Xero tenant and upsert into staging.

        Xero paginates contacts the same way as invoices (``page=1, 2, ...``).

        Args:
            tenant_id: Xero tenant UUID.

        Returns:
            Total number of contacts upserted.
        """
        logger.info("Syncing contacts for tenant %s ...", tenant_id)
        total = 0
        page = 1

        conn = self._get_connection()
        try:
            self._ensure_staging_tables(conn)

            while True:
                data = self._make_request(
                    "/Contacts", tenant_id, params={"page": page}
                )
                contacts = data.get("Contacts", [])
                if not contacts:
                    break

                with conn.cursor() as cur:
                    for ct in contacts:
                        cur.execute(
                            """
                            INSERT INTO staging_xero_contacts
                                (tenant_id, contact_id, contact_name,
                                 contact_status, email,
                                 is_supplier, is_customer, raw_json, synced_at)
                            VALUES
                                (%s, %s, %s,
                                 %s, %s,
                                 %s, %s, %s, NOW())
                            ON CONFLICT (tenant_id, contact_id) DO UPDATE SET
                                contact_name   = EXCLUDED.contact_name,
                                contact_status = EXCLUDED.contact_status,
                                email          = EXCLUDED.email,
                                is_supplier    = EXCLUDED.is_supplier,
                                is_customer    = EXCLUDED.is_customer,
                                raw_json       = EXCLUDED.raw_json,
                                synced_at      = NOW()
                            """,
                            (
                                tenant_id,
                                ct.get("ContactID"),
                                ct.get("Name"),
                                ct.get("ContactStatus"),
                                ct.get("EmailAddress"),
                                ct.get("IsSupplier", False),
                                ct.get("IsCustomer", False),
                                json.dumps(ct),
                            ),
                        )
                conn.commit()

                count = len(contacts)
                total += count
                logger.info("  page %d: %d contacts", page, count)
                page += 1

        finally:
            conn.close()

        logger.info("Contacts sync complete: %d total", total)
        return total

    def sync_accounts(self, tenant_id: str) -> int:
        """Fetch chart of accounts from a Xero tenant and upsert into staging.

        The Accounts endpoint is *not* paginated — it returns all accounts in
        a single response.

        Args:
            tenant_id: Xero tenant UUID.

        Returns:
            Total number of accounts upserted.
        """
        logger.info("Syncing accounts for tenant %s ...", tenant_id)

        data = self._make_request("/Accounts", tenant_id)
        accounts = data.get("Accounts", [])

        conn = self._get_connection()
        try:
            self._ensure_staging_tables(conn)

            with conn.cursor() as cur:
                for acct in accounts:
                    cur.execute(
                        """
                        INSERT INTO staging_xero_accounts
                            (tenant_id, account_id, code, name,
                             account_type, tax_type, "class", status,
                             raw_json, synced_at)
                        VALUES
                            (%s, %s, %s, %s,
                             %s, %s, %s, %s,
                             %s, NOW())
                        ON CONFLICT (tenant_id, account_id) DO UPDATE SET
                            code         = EXCLUDED.code,
                            name         = EXCLUDED.name,
                            account_type = EXCLUDED.account_type,
                            tax_type     = EXCLUDED.tax_type,
                            "class"      = EXCLUDED."class",
                            status       = EXCLUDED.status,
                            raw_json     = EXCLUDED.raw_json,
                            synced_at    = NOW()
                        """,
                        (
                            tenant_id,
                            acct.get("AccountID"),
                            acct.get("Code"),
                            acct.get("Name"),
                            acct.get("Type"),
                            acct.get("TaxType"),
                            acct.get("Class"),
                            acct.get("Status"),
                            json.dumps(acct),
                        ),
                    )
            conn.commit()

        finally:
            conn.close()

        total = len(accounts)
        logger.info("Accounts sync complete: %d total", total)
        return total

    # ------------------------------------------------------------------
    # ------------------------------------------------------------------

    def sync_tenant(self, tenant_id: str, tenant_name: str, tenant_key: str = "") -> dict[str, int]:
        """Run all sync methods for a single Xero tenant.

        Args:
            tenant_id: Xero tenant UUID.
            tenant_name: Human-readable name for logging.
            tenant_key: Short key for ETL log source (e.g. "trust", "wines").

        Returns:
            Dict mapping entity type to row count, e.g.
            ``{"invoices": 142, "contacts": 87, "accounts": 45}``.
        """
        logger.info("=" * 60)
        logger.info("Starting full sync for tenant: %s (%s)", tenant_name, tenant_id)
        logger.info("=" * 60)

        results: dict[str, int] = {}
        errors: list[str] = []

        for entity, sync_fn in [
            ("invoices", self.sync_invoices),
            ("contacts", self.sync_contacts),
            ("accounts", self.sync_accounts),
        ]:
            try:
                results[entity] = sync_fn(tenant_id)
            except Exception as exc:
                msg = f"{entity} sync failed for {tenant_name}: {exc}"
                logger.error(msg, exc_info=True)
                errors.append(msg)
                results[entity] = 0

        # Log to etl_run_log
        total_rows = sum(results.values())
        status = "success" if not errors else "partial_failure"
        try:
            conn = self._get_connection()
            try:
                log_etl_run(
                    conn,
                    source=f"xero_{tenant_key}" if tenant_key else f"xero_{tenant_name.lower().split()[0]}",
                    endpoint="sync_all",
                    status=status,
                    rows_processed=total_rows,
                    rows_skipped=0,
                    error_count=len(errors),
                    error_detail="; ".join(errors) if errors else None,
                )
                conn.commit()
            finally:
                conn.close()
        except Exception as log_exc:
            logger.warning("Could not write to etl_run_log: %s", log_exc)

        logger.info(
            "Tenant %s sync %s — invoices=%d, contacts=%d, accounts=%d",
            tenant_name,
            status,
            results.get("invoices", 0),
            results.get("contacts", 0),
            results.get("accounts", 0),
        )
        return results

    def sync_all(self) -> dict[str, dict[str, int]]:
        """Sync both Xero tenants (Trust + Wines Pty Ltd).

        Returns:
            Nested dict keyed by tenant short name, e.g.
            ``{"trust": {"invoices": 142, ...}, "wines": {...}}``.
        """
        start = datetime.now(tz=timezone.utc)
        logger.info("Xero full sync started at %s", start.isoformat())

        all_results: dict[str, dict[str, int]] = {}
        all_errors: list[str] = []

        for key, tenant_info in TENANTS.items():
            try:
                all_results[key] = self.sync_tenant(
                    tenant_info["tenant_id"], tenant_info["name"], tenant_key=key
                )
            except Exception as exc:
                msg = f"Tenant {tenant_info['name']} sync failed entirely: {exc}"
                logger.error(msg, exc_info=True)
                all_errors.append(msg)
                all_results[key] = {"invoices": 0, "contacts": 0, "accounts": 0}

        # Summary log entry
        elapsed = (datetime.now(tz=timezone.utc) - start).total_seconds()
        total_rows = sum(
            sum(tenant.values()) for tenant in all_results.values()
        )
        status = "success" if not all_errors else "partial_failure"
        try:
            conn = self._get_connection()
            try:
                log_etl_run(
                    conn,
                    source="xero",
                    endpoint="sync_all",
                    status=status,
                    rows_processed=total_rows,
                    rows_skipped=0,
                    error_count=len(all_errors),
                    error_detail="; ".join(all_errors) if all_errors else None,
                )
                conn.commit()
            finally:
                conn.close()
        except Exception as log_exc:
            logger.warning("Could not write summary to etl_run_log: %s", log_exc)

        logger.info(
            "Xero full sync complete in %.1fs — total rows: %d, status: %s",
            elapsed, total_rows, status,
        )
        return all_results


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    client_id = os.environ.get("XERO_CLIENT_ID")
    client_secret = os.environ.get("XERO_CLIENT_SECRET")
    token_file = os.environ.get("XERO_TOKEN_FILE", "xero_tokens.json")
    database_url = os.environ.get("DATABASE_URL")

    if not client_id or not client_secret:
        raise SystemExit(
            "Set XERO_CLIENT_ID and XERO_CLIENT_SECRET environment variables."
        )
    if not database_url:
        raise SystemExit("Set DATABASE_URL environment variable.")

    connector = XeroConnector(
        client_id=client_id,
        client_secret=client_secret,
        token_file_path=token_file,
        db_connection_string=database_url,
    )
    connector.sync_all()
