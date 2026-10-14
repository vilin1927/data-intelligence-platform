"""
Centralized ETL logging for Moppity Vineyards data platform.

Provides functions to record ETL run outcomes and dead-letter rows
into PostgreSQL. Every sync operation — regardless of source system —
should call log_etl_run() on completion and log_dead_letter() for
any rows that could not be processed.

Tables referenced:
    etl_run_log     — one row per sync attempt (success or failure)
    etl_dead_letter — one row per unprocessable record (raw data preserved)
"""

import datetime
import json
import logging

logger = logging.getLogger("moppity.etl.logger")


def log_etl_run(
    db_conn,
    source: str,
    endpoint: str,
    status: str,
    rows_processed: int,
    rows_skipped: int = 0,
    error_count: int = 0,
    error_detail: str | None = None,
) -> int:
    """Insert a record into etl_run_log and return the generated run_id.

    Args:
        db_conn: psycopg2 connection object.
        source: Source system name (e.g. 'vinsight', 'xero', 'access_db').
        endpoint: API endpoint or table name that was synced.
        status: Outcome — 'success', 'partial', or 'error'.
        rows_processed: Number of rows successfully written.
        rows_skipped: Number of rows intentionally skipped (duplicates, etc.).
        error_count: Number of rows that failed processing.
        error_detail: Free-text description of errors encountered (truncated
            to 2000 chars to avoid bloating the log table).

    Returns:
        The auto-generated run_id for this log entry.

    Raises:
        psycopg2.Error: If the INSERT fails (caller should handle).
    """
    if error_detail and len(error_detail) > 2000:
        error_detail = error_detail[:2000]

    sql = """
        INSERT INTO etl_run_log (
            source, endpoint, status, rows_processed, rows_skipped,
            error_count, error_detail, started_at, completed_at, run_timestamp
        )
        VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
        RETURNING run_id
    """
    now = datetime.datetime.now(datetime.timezone.utc)

    with db_conn.cursor() as cur:
        cur.execute(sql, (
            source,
            endpoint,
            status,
            rows_processed,
            rows_skipped,
            error_count,
            error_detail,
            now,
            now,
            now,
        ))
        run_id = cur.fetchone()[0]

    db_conn.commit()

    logger.info(
        "ETL run logged: id=%d source=%s endpoint=%s status=%s "
        "rows=%d skipped=%d errors=%d",
        run_id, source, endpoint, status,
        rows_processed, rows_skipped, error_count,
    )
    return run_id


def log_dead_letter(
    db_conn,
    run_id: int,
    source: str,
    raw_data: dict | list | str,
    error_message: str,
) -> int:
    """Preserve a failed record in the etl_dead_letter table.

    Dead-letter rows are never silently dropped. They stay in this table
    until an operator investigates and either fixes the transform or
    marks the record as resolved.

    Args:
        db_conn: psycopg2 connection object.
        run_id: The etl_run_log.id for the sync run that produced this failure.
        source: Source system name (e.g. 'vinsight', 'xero').
        raw_data: The raw record that failed processing. Stored as JSONB.
            If already a string, it will be wrapped in a JSON object.
        error_message: Human-readable description of what went wrong.

    Returns:
        The auto-generated dead_letter id.

    Raises:
        psycopg2.Error: If the INSERT fails (caller should handle).
    """
    # Normalise raw_data to a JSON-serialisable value
    if isinstance(raw_data, str):
        raw_json = json.dumps({"raw_text": raw_data})
    else:
        raw_json = json.dumps(raw_data, default=str)

    sql = """
        INSERT INTO etl_dead_letter (
            run_id, source, raw_data, error_message, created_at
        )
        VALUES (%s, %s, %s::jsonb, %s, %s)
        RETURNING id
    """
    now = datetime.datetime.now(datetime.timezone.utc)

    with db_conn.cursor() as cur:
        cur.execute(sql, (
            run_id,
            source,
            raw_json,
            error_message,
            now,
        ))
        dead_letter_id = cur.fetchone()[0]

    db_conn.commit()

    logger.warning(
        "Dead letter recorded: id=%d run_id=%d source=%s error=%s",
        dead_letter_id, run_id, source, error_message,
    )
    return dead_letter_id
