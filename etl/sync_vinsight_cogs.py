"""
Vinsight COGS Data Sync - Wine Batches, Vessels, Packaging Operations.

Syncs traceability data from Vinsight API for M2 COGS calculations:
- WineBatches: Grape batches processed into wine
- Vessels: Tanks and barrels for wine aging
- PackagingOperations: Bottling runs producing SKUs

Uses the new M2 foundation staging tables (schema/008_m2_foundation.sql).

Usage:
    DATABASE_URL=postgresql://... VINSIGHT_API_KEY=... python -m etl.sync_vinsight_cogs
"""

import json
import logging
import os
import re
import sys
import time
from typing import Any

import psycopg2
import psycopg2.extras
import requests

from etl.logger import log_etl_run

logger = logging.getLogger("moppity.etl.sync_vinsight_cogs")

# Vinsight API base
BASE_URL = "https://app.vinsight.net"

# Retry configuration
MAX_RETRIES = 3
BACKOFF_SECONDS = [1, 2, 4]

# BUG-176 (2026-05-04): Vinsight `StockItemNum` is the per-batch packaging-operation
# integer (e.g. 1644, 1645, 1974) — the WRONG GRAIN for sku_code_map. Real Moppity
# SKU codes are alphanumeric strings like 'COCSCHAB22', 'MVLKSHZB21'. Without this
# filter, every nightly Vinsight sync re-introduces 8+ numeric per-batch IDs into
# sku_code_map (BUG-175 schema/129 deleted them retroactively for canonical_sku_id=14;
# BUG-175b filed the broader 50+ row Tier-2 cleanup). The pattern below is applied
# in the WHERE clause via Postgres `~` regex so the filter happens server-side
# before any row reaches sku_code_map.
#
# pattern below and will block deploy if it disappears.
VINSIGHT_NUMERIC_STOCK_ITEM_NUM_PATTERN = r'^[0-9]+$'


class VinsightCOGSSyncer:
    """Syncs Vinsight COGS-related data: batches, vessels, packaging operations."""

    # Vinsight endpoint mappings for COGS traceability
    # NOTE: $expand parameters are REQUIRED to get linked data (discovered 2026-03-15)
    ENDPOINTS = {
        "wine_batches": {
            "api_path": "/WineBatches.json",
            "expand": "PackagingOperationVessels",  # Links batch → vessel → packaging
            "staging_table": "staging_vinsight_wine_batches",
        },
        "vessels": {
            "api_path": "/Vessels.json",
            "expand": None,
            "staging_table": "staging_vinsight_vessels",
        },
        "packaging_operations": {
            "api_path": "/PackagingOperations.json",
            "expand": "StockItemsPackaged",  # Links packaging → SKU
            "staging_table": "staging_vinsight_packaging_operations",
        },
        "stock_items": {
            "api_path": "/StockItems.json",
            "expand": None,
            "staging_table": "staging_vinsight_stock_items",
        },
    }

    def __init__(self, api_key: str, db_connection_string: str) -> None:
        if not api_key:
            raise ValueError("api_key must not be empty")
        if not db_connection_string:
            raise ValueError("db_connection_string must not be empty")

        self.api_key = api_key
        self.db_conn = psycopg2.connect(db_connection_string)
        self.db_conn.autocommit = False
        self._session = requests.Session()

        logger.info("VinsightCOGSSyncer initialised")

    def sync_wine_batches(self) -> int:
        """Sync wine batches from Vinsight to staging."""
        return self._sync_endpoint("wine_batches")

    def sync_vessels(self) -> int:
        """Sync vessels (tanks/barrels) from Vinsight to staging."""
        return self._sync_endpoint("vessels")

    def sync_packaging_operations(self) -> int:
        """Sync packaging operations from Vinsight to staging."""
        return self._sync_endpoint("packaging_operations")

    def sync_all(self) -> dict[str, int]:
        """Run all COGS sync operations."""
        results: dict[str, int] = {}
        errors: list[str] = []

        for endpoint_name in self.ENDPOINTS.keys():
            try:
                count = self._sync_endpoint(endpoint_name)
                results[endpoint_name] = count
                logger.info("sync_%s completed: %d rows", endpoint_name, count)
            except Exception as exc:
                results[endpoint_name] = 0
                error_msg = f"{endpoint_name}: {exc}"
                errors.append(error_msg)
                logger.error("sync_%s failed: %s", endpoint_name, exc)

        total_rows = sum(results.values())
        status = "success" if not errors else ("partial" if total_rows > 0 else "error")

        log_etl_run(
            db_conn=self.db_conn,
            source="vinsight_cogs",
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

    def transform_to_core(self) -> dict[str, int]:
        """Transform staging data into core M2 tables.

        Moves data from staging_vinsight_* tables into:
        - wine_batch
        - vessel
        - packaging_operation
        - packaging_vessel

        Returns dict of {table_name: rows_inserted}.
        """
        results = {}

        try:
            with self.db_conn.cursor() as cur:
                # Transform wine batches
                results["wine_batch"] = self._transform_wine_batches(cur)

                # Transform vessels (depends on wine_batch)
                results["vessel"] = self._transform_vessels(cur)

                # Transform packaging operations (with StockItemsPackaged data)
                results["packaging_operation"] = self._transform_packaging_operations(cur)

                # Transform packaging_vessel junction (from PackagingOperationVessels in wine_batches)
                results["packaging_vessel"] = self._transform_packaging_vessels(cur)

                # Transform StockItems → sku_code_map + link packaging_operation.sku_id
                results["sku_code_map"] = self._transform_stock_items(cur)

            self.db_conn.commit()
            logger.info("Transform complete: %s", results)

        except Exception as exc:
            self.db_conn.rollback()
            logger.error("Transform failed: %s", exc)
            raise

        return results

    def _transform_wine_batches(self, cursor) -> int:
        """Transform staging wine batches to core wine_batch table.

        Vinsight WineBatches JSON structure:
        - $id: unique identifier
        - Code: batch code (e.g., "12PICCSU01CTU")
        - Description: wine description (e.g., "Tumba Pinot Chard NV")
        - WineCode: wine variety code (e.g., "PIC", "CHARD", "SHIRAZ")
        - WineTypeCode: type (e.g., "Spark", "Still")
        - IsActive: boolean
        """
        cursor.execute("""
            INSERT INTO wine_batch (
                vinsight_batch_id,
                batch_code,
                description,
                variety,
                region,
                vintage,
                color,
                status,
                raw_data,
                synced_at
            )
            SELECT
                raw_data->>'$id',
                raw_data->>'Code',
                raw_data->>'Description',
                -- Extract variety from WineCode or Description
                COALESCE(raw_data->>'WineCode',
                    CASE
                        WHEN raw_data->>'Description' ILIKE '%chardonnay%' THEN 'Chardonnay'
                        WHEN raw_data->>'Description' ILIKE '%shiraz%' THEN 'Shiraz'
                        WHEN raw_data->>'Description' ILIKE '%pinot noir%' THEN 'Pinot Noir'
                        WHEN raw_data->>'Description' ILIKE '%pinot%' THEN 'Pinot'
                        WHEN raw_data->>'Description' ILIKE '%riesling%' THEN 'Riesling'
                        WHEN raw_data->>'Description' ILIKE '%cabernet%' THEN 'Cabernet'
                        WHEN raw_data->>'Description' ILIKE '%merlot%' THEN 'Merlot'
                        WHEN raw_data->>'Description' ILIKE '%sauvignon%' THEN 'Sauvignon Blanc'
                        ELSE NULL
                    END),
                -- Extract region: description keywords → batch_code suffix → brand code → block pattern
                CASE
                    WHEN raw_data->>'Description' ILIKE '%tumba%' OR raw_data->>'Description' ILIKE '%tumby%' THEN 'Tumbarumba'
                    WHEN raw_data->>'Description' ILIKE '%hilltop%' THEN 'Hilltops'
                    WHEN raw_data->>'Description' ILIKE '%barossa%' THEN 'Barossa Valley'
                    WHEN raw_data->>'Description' ILIKE '%tassie%' OR raw_data->>'Description' ILIKE '%tasmania%' THEN 'Tasmania'
                    WHEN raw_data->>'Description' ILIKE '%hunter%' THEN 'Hunter Valley'
                    WHEN raw_data->>'Description' ILIKE '%coppabella%' THEN 'Tumbarumba'
                    WHEN RIGHT(raw_data->>'Code', 2) = 'TU' THEN 'Tumbarumba'
                    WHEN RIGHT(raw_data->>'Code', 2) = 'HI' THEN 'Hilltops'
                    WHEN RIGHT(raw_data->>'Code', 2) = 'BV' THEN 'Barossa Valley'
                    WHEN RIGHT(raw_data->>'Code', 2) = 'TA' THEN 'Tasmania'
                    WHEN raw_data->>'Code' LIKE '%MOP%' THEN 'Hilltops'
                    WHEN raw_data->>'Code' LIKE '%COP%' THEN 'Tumbarumba'
                    WHEN raw_data->>'Code' ~ '[A-Z]{2,3}H[0-9]' THEN 'Hilltops'
                    WHEN raw_data->>'Code' ~ '[A-Z]{2,3}T[0-9]' THEN 'Tumbarumba'
                    ELSE NULL
                END,
                -- Extract vintage year from Code or Description (look for 4-digit year or 2-digit prefix)
                CASE
                    WHEN raw_data->>'Code' ~ '^[0-9]{2}' THEN
                        (2000 + (SUBSTRING(raw_data->>'Code' FROM 1 FOR 2))::integer)
                    WHEN raw_data->>'Description' ~ '[0-9]{4}' THEN
                        (REGEXP_MATCH(raw_data->>'Description', '([0-9]{4})'))[1]::integer
                    ELSE NULL
                END,
                -- Determine color from WineTypeCode or Description
                CASE
                    WHEN raw_data->>'WineTypeCode' = 'Spark' THEN 'white'
                    WHEN raw_data->>'Description' ILIKE '%chardonnay%' THEN 'white'
                    WHEN raw_data->>'Description' ILIKE '%riesling%' THEN 'white'
                    WHEN raw_data->>'Description' ILIKE '%sauvignon%' THEN 'white'
                    WHEN raw_data->>'Description' ILIKE '%pinot gris%' THEN 'white'
                    WHEN raw_data->>'Description' ILIKE '%shiraz%' THEN 'red'
                    WHEN raw_data->>'Description' ILIKE '%cabernet%' THEN 'red'
                    WHEN raw_data->>'Description' ILIKE '%merlot%' THEN 'red'
                    WHEN raw_data->>'Description' ILIKE '%pinot noir%' THEN 'red'
                    ELSE NULL
                END,
                CASE WHEN (raw_data->>'IsActive')::boolean THEN 'active' ELSE 'inactive' END,
                raw_data,
                synced_at
            FROM staging_vinsight_wine_batches
            WHERE raw_data->>'$id' IS NOT NULL
            ON CONFLICT (vinsight_batch_id) DO UPDATE SET
                batch_code = EXCLUDED.batch_code,
                description = EXCLUDED.description,
                variety = EXCLUDED.variety,
                region = COALESCE(EXCLUDED.region, wine_batch.region),
                vintage = EXCLUDED.vintage,
                color = EXCLUDED.color,
                status = EXCLUDED.status,
                raw_data = EXCLUDED.raw_data,
                synced_at = EXCLUDED.synced_at
        """)
        count = cursor.rowcount
        logger.info("Transformed %d wine batches", count)
        return count

    def _transform_vessels(self, cursor) -> int:
        """Transform staging vessels to core vessel table.

        Vinsight Vessels JSON structure:
        - $id: unique identifier
        - VesselCode: vessel code (e.g., "001")
        - Description: vessel name (e.g., "Vessel 001")
        - TypeCode: vessel type (e.g., "CW", "Red")
        - Volume: current volume
        - BatchCode: linked batch code (may be null)
        - Location: vessel location
        - IsActive: boolean
        """
        cursor.execute("""
            INSERT INTO vessel (
                vinsight_vessel_id,
                vessel_code,
                name,
                vessel_type,
                wine_batch_id,
                current_volume_litres,
                raw_data,
                synced_at
            )
            SELECT DISTINCT ON (s.raw_data->>'$id')
                s.raw_data->>'$id',
                s.raw_data->>'VesselCode',
                s.raw_data->>'Description',
                s.raw_data->>'TypeCode',
                wb.id,
                (s.raw_data->>'Volume')::numeric,
                s.raw_data,
                s.synced_at
            FROM staging_vinsight_vessels s
            LEFT JOIN wine_batch wb ON wb.batch_code = s.raw_data->>'BatchCode'
            WHERE s.raw_data->>'$id' IS NOT NULL
            ORDER BY s.raw_data->>'$id', s.synced_at DESC
            ON CONFLICT (vinsight_vessel_id) DO UPDATE SET
                vessel_code = EXCLUDED.vessel_code,
                name = EXCLUDED.name,
                vessel_type = EXCLUDED.vessel_type,
                wine_batch_id = EXCLUDED.wine_batch_id,
                current_volume_litres = EXCLUDED.current_volume_litres,
                raw_data = EXCLUDED.raw_data,
                synced_at = EXCLUDED.synced_at
        """)
        count = cursor.rowcount
        logger.info("Transformed %d vessels", count)
        return count

    def _transform_packaging_operations(self, cursor) -> int:
        """Transform staging packaging operations to core tables.

        Vinsight PackagingOperations JSON structure (with $expand=StockItemsPackaged):
        - $id: unique identifier
        - OperationNum: operation number (e.g., 645)
        - Description: description (e.g., "2024 Coppabella Chardonnay Labelling")
        - DateCommenced, DateCompleted: dates
        - OperationTypeCode: operation type (e.g., "Pack Addition")
        - StockItemsPackaged: array with StockItemNum, CostPerUnit, Quantity
        - IsUpdated, IsDirty: status flags
        """
        # First, extract vinsight_stock_item_id from StockItemsPackaged array
        # and link to SKU if we have a matching sku_code_map entry
        cursor.execute("""
            INSERT INTO packaging_operation (
                vinsight_packaging_id,
                operation_code,
                description,
                vinsight_stock_item_id,
                bottling_date,
                cases_produced,
                status,
                raw_data,
                synced_at
            )
            SELECT
                s.raw_data->>'$id',
                s.raw_data->>'OperationNum',
                s.raw_data->>'Description',
                -- Get first StockItemNum from StockItemsPackaged array
                (s.raw_data->'StockItemsPackaged'->0->>'StockItemNum'),
                (s.raw_data->>'DateCompleted')::timestamp::date,
                -- Get quantity from first StockItemsPackaged entry (cast via numeric to handle decimals)
                (s.raw_data->'StockItemsPackaged'->0->>'QuantityFinal')::numeric::integer,
                COALESCE(s.raw_data->>'OperationTypeCode', 'unknown'),
                s.raw_data,
                s.synced_at
            FROM staging_vinsight_packaging_operations s
            WHERE s.raw_data->>'$id' IS NOT NULL
            ON CONFLICT (vinsight_packaging_id) DO UPDATE SET
                operation_code = EXCLUDED.operation_code,
                description = EXCLUDED.description,
                vinsight_stock_item_id = EXCLUDED.vinsight_stock_item_id,
                bottling_date = EXCLUDED.bottling_date,
                cases_produced = EXCLUDED.cases_produced,
                status = EXCLUDED.status,
                raw_data = EXCLUDED.raw_data,
                synced_at = EXCLUDED.synced_at
        """)
        op_count = cursor.rowcount
        logger.info("Transformed %d packaging operations", op_count)

        # Count how many have StockItemsPackaged data
        cursor.execute("""
            SELECT COUNT(*) FROM packaging_operation
            WHERE vinsight_stock_item_id IS NOT NULL
        """)
        linked_count = cursor.fetchone()[0]
        logger.info("Packaging operations with StockItemNum: %d/%d", linked_count, op_count)

        return op_count

    def _transform_packaging_vessels(self, cursor) -> int:
        """Transform PackagingOperationVessels from wine_batches to packaging_vessel junction.

        The vessel→packaging link comes from WineBatches (with $expand=PackagingOperationVessels):
        - PackagingOperationVessels array with: VesselCode, OperationNum, VolumeTransfer, BatchCode
        """
        # R-009 (2026-04-30): also persist wine_batch_id from BatchCode. Without
        # this column the /wines Traceability Chain fell back to vessel.wine_batch_id
        # ("current contents") and showed wrong batches per packaging op.
        #
        # BUG-178 (2026-05-05): replaced `SELECT DISTINCT` with
        # `SELECT DISTINCT ON (po.id, v.id) ... ORDER BY po.id, v.id,
        # wb.synced_at DESC NULLS LAST, wb.id DESC NULLS LAST`. Vinsight rotates
        # `$id` for the same business batch across snapshots, so wine_batch has
        # multiple rows sharing the same `batch_code`. The R-009 LEFT JOIN against
        # `wine_batch.batch_code` (non-unique) projected `wb.id` through DISTINCT,
        # producing rows that share `(po_id, v_id)` but differ in `wb.id`. The
        # ON CONFLICT target is `(po_id, v_id)`, so duplicate keys survived into
        # the INSERT batch → CardinalityViolation (SQLSTATE 21000) on May 4 cron.
        # This pattern mirrors `_transform_vessels` (line 306). Tie-breaker prefers
        # the most-recently-seen wine_batch (matches "as-of-packaging" intent);
        # NULLS LAST ensures LEFT JOIN misses lose to matches.
        #
        # BUG-178 monitor (pre-INSERT cardinality assertion): logs raw vs deduped
        # counts for visibility. If raw cardinality blows up >10x distinct keys,
        # surface a named RuntimeError instead of a generic SQLSTATE 21000.
        cursor.execute("""
            SELECT
                COUNT(*) AS total,
                COUNT(DISTINCT (po.id, v.id)) AS distinct_keys
            FROM staging_vinsight_wine_batches s
            CROSS JOIN LATERAL jsonb_array_elements(s.raw_data->'PackagingOperationVessels') AS pov
            JOIN vessel v ON v.vessel_code = pov->>'VesselCode'
            JOIN packaging_operation po ON po.operation_code = pov->>'OperationNum'
            LEFT JOIN wine_batch wb ON wb.batch_code = pov->>'BatchCode'
            WHERE s.raw_data->'PackagingOperationVessels' IS NOT NULL
                AND jsonb_array_length(s.raw_data->'PackagingOperationVessels') > 0
        """)
        raw_total, raw_distinct_keys = cursor.fetchone()
        dup_collisions = raw_total - raw_distinct_keys
        logger.info(
            "[BUG-178 monitor] packaging_vessel JOIN cardinality: "
            "total=%d, distinct (po_id, v_id) keys=%d, dedup collisions=%d",
            raw_total, raw_distinct_keys, dup_collisions,
        )
        if raw_distinct_keys > 0 and raw_total > 10 * raw_distinct_keys:
            raise RuntimeError(
                f"_transform_packaging_vessels BUG-178 monitor: cardinality "
                f"blowup detected — raw JOIN yields {raw_total} rows but only "
                f"{raw_distinct_keys} distinct (po_id, v_id) keys "
                f"({raw_total / raw_distinct_keys:.1f}x explosion). Refusing to "
                f"INSERT to avoid silent data masking. Investigate "
                f"wine_batch.batch_code, vessel.vessel_code, or "
                f"packaging_operation.operation_code for runaway duplicates from "
                f"Vinsight $id rotation or schema change."
            )

        cursor.execute("""
            INSERT INTO packaging_vessel (
                packaging_operation_id,
                vessel_id,
                volume_litres,
                proportion,
                wine_batch_id
            )
            SELECT DISTINCT ON (po.id, v.id)
                po.id,
                v.id,
                (pov->>'VolumeTransfer')::numeric,
                NULL::numeric,  -- Proportion can be calculated later
                wb.id
            FROM staging_vinsight_wine_batches s
            CROSS JOIN LATERAL jsonb_array_elements(s.raw_data->'PackagingOperationVessels') AS pov
            JOIN vessel v ON v.vessel_code = pov->>'VesselCode'
            JOIN packaging_operation po ON po.operation_code = pov->>'OperationNum'
            LEFT JOIN wine_batch wb ON wb.batch_code = pov->>'BatchCode'
            WHERE s.raw_data->'PackagingOperationVessels' IS NOT NULL
                AND jsonb_array_length(s.raw_data->'PackagingOperationVessels') > 0
            ORDER BY po.id, v.id, wb.synced_at DESC NULLS LAST, wb.id DESC NULLS LAST
            ON CONFLICT (packaging_operation_id, vessel_id) DO UPDATE SET
                volume_litres = EXCLUDED.volume_litres,
                wine_batch_id = COALESCE(EXCLUDED.wine_batch_id, packaging_vessel.wine_batch_id)
        """)
        link_count = cursor.rowcount
        logger.info("Linked %d vessel-packaging relationships from PackagingOperationVessels", link_count)

        return link_count

    def _transform_stock_items(self, cursor) -> int:
        """Transform Vinsight StockItems into sku_code_map entries and link packaging_operation.sku_id.

        Creates sku_code_map entries (source_system='vinsight') linking:
        StockItemCode (e.g., MVLKSHZB24) → sku.sku_code

        Then updates packaging_operation.sku_id using:
        vinsight_stock_item_id → StockItemNum → StockItemCode → sku_code_map → sku_id

        BUG-176 (2026-05-04): the SELECT below was emitting per-batch numeric
        StockItemNum integers (e.g. 1644, 1645) into sku_code_map. Those are
        packaging-operation IDs, NOT SKU codes. The
        `si.raw_data->>'StockItemNum' !~ VINSIGHT_NUMERIC_STOCK_ITEM_NUM_PATTERN`
        clause on line 472 below filters them out before the INSERT runs, so
        only Moppity-style alphanumeric codes like 'COCSCHAB22' land in
        sku_code_map. Per-batch StockItemNum values still flow to
        staging_vinsight_stock_items (the correct destination).
        """
        # Step 1: Insert sku_code_map entries for packaged wine StockItems
        # Skip duplicates by checking existence.
        # BUG-176 fix: filter out purely-numeric StockItemNum (per-batch integers).
        cursor.execute(
            """
            INSERT INTO sku_code_map (sku_id, source_system, external_code)
            SELECT DISTINCT
                s_sku.sku_id,
                'vinsight',
                si.raw_data->>'StockItemNum'
            FROM staging_vinsight_stock_items si
            JOIN sku s_sku ON s_sku.sku_code = si.raw_data->>'StockItemCode'
            WHERE (si.raw_data->>'IsPackagedWine')::boolean = true
                AND si.raw_data->>'StockItemCode' IS NOT NULL
                AND si.raw_data->>'StockItemNum' IS NOT NULL
                -- BUG-176: skip per-batch numeric StockItemNum (wrong grain).
                AND si.raw_data->>'StockItemNum' !~ %s
                AND NOT EXISTS (
                    SELECT 1 FROM sku_code_map existing
                    WHERE existing.source_system = 'vinsight'
                        AND existing.external_code = si.raw_data->>'StockItemNum'
                )
            """,
            (VINSIGHT_NUMERIC_STOCK_ITEM_NUM_PATTERN,),
        )
        map_count = cursor.rowcount
        logger.info("Created %d sku_code_map entries for Vinsight StockItems", map_count)

        # Step 2: Update packaging_operation.sku_id via sku_code_map
        cursor.execute("""
            UPDATE packaging_operation po
            SET sku_id = scm.sku_id
            FROM sku_code_map scm
            WHERE scm.source_system = 'vinsight'
                AND scm.external_code = po.vinsight_stock_item_id
                AND po.sku_id IS NULL
        """)
        linked_count = cursor.rowcount
        logger.info("Linked %d packaging_operations to SKU via sku_code_map", linked_count)

        return map_count

    def _sync_endpoint(self, endpoint_name: str) -> int:
        """Fetch from Vinsight API and store in staging table."""
        config = self.ENDPOINTS[endpoint_name]
        api_path = config["api_path"]
        staging_table = config["staging_table"]
        expand = config.get("expand")

        logger.info("Syncing %s from %s", endpoint_name, api_path)

        # Fetch from API (with $expand if specified)
        data = self._api_get(api_path, expand=expand)
        if data is None:
            raise RuntimeError(f"Failed to fetch {api_path}")

        # Parse response
        records = self._parse_response(data)
        if not records:
            logger.warning("No records returned from %s", api_path)
            return 0

        # Clear old staging data and insert new
        rows_written = self._insert_staging(staging_table, records)

        log_etl_run(
            db_conn=self.db_conn,
            source="vinsight_cogs",
            endpoint=api_path,
            status="success",
            rows_processed=rows_written,
            rows_skipped=0,
            error_count=0,
            error_detail=None,
        )

        return rows_written

    def _parse_response(self, data: dict | list) -> list[dict]:
        """Parse Vinsight API response into list of records."""
        if isinstance(data, list):
            return data
        if isinstance(data, dict):
            return (
                data.get("List")
                or data.get("Items")
                or data.get("list")
                or [data]
            )
        return []

    # Allowed staging tables — validated before ANY DDL/DML with dynamic name.
    # NEVER allow caller-supplied table names without membership check here.
    _ALLOWED_STAGING_TABLES = frozenset({
        "staging_vinsight_wine_batches",
        "staging_vinsight_vessels",
        "staging_vinsight_packaging_operations",
        "staging_vinsight_stock_items",
    })

    # BUG-24: batch size for execute_values inserts into the shadow staging
    # table. 500 rows/round-trip is a good sweet spot: keeps statement text
    # under the 1MB wire size limit for typical Vinsight records.
    _BATCH_SIZE = 500

    def _insert_staging(self, table_name: str, records: list[dict]) -> int:
        """Insert records into staging table using shadow-table + atomic rename.

        BUG-23 (ETL-01): The original implementation did TRUNCATE-then-INSERT,
        which meant a mid-sync crash (e.g. DB lost between TRUNCATE and the
        final row INSERT) would leave the staging table partially populated or
        empty, destroying the previous good snapshot. Re-running without
        first re-fetching from Vinsight is not safe — and re-fetching burns
        rate limit budget (60/min, 5000/day). Vladimir flagged this pattern

        The new approach:
          1. Create a shadow table `{table}_new` with an identical schema.
          2. Insert all fetched records into the shadow.
          3. On success: atomic rename within a single transaction so the
             staging table is either fully-old or fully-new, never partial.
          4. On failure: drop the shadow, leaving the original untouched.

        The original staging table is the source of truth for downstream
        transforms — _transform_wine_batches, _transform_vessels, etc. all
        read from the same table name — so the rename must happen atomically
        before any transform runs.
        """
        # Validate table name — only allow the known staging tables.
        # This is the ONLY place caller-supplied table names are interpolated
        # into SQL; the whitelist check guards against injection.
        if table_name not in self._ALLOWED_STAGING_TABLES:
            raise ValueError(f"Unknown staging table: {table_name}")

        shadow_table = f"{table_name}_new"
        old_table = f"{table_name}_old"

        start_time = time.monotonic()
        rows_written = 0

        try:
            # Prepare the shadow table in its own transaction so CREATE/TRUNCATE
            # commits even if the subsequent INSERT loop partially fails —
            # we still want to be able to clean it up on failure.
            with self.db_conn.cursor() as cur:
                # Drop any stale shadow from a previous crashed run.
                cur.execute(f"DROP TABLE IF EXISTS {shadow_table} CASCADE")
                # Shadow with identical schema (columns, defaults, indexes,
                # constraints). INCLUDING ALL mirrors PK/defaults/checks.
                cur.execute(
                    f"CREATE TABLE {shadow_table} "
                    f"(LIKE {table_name} INCLUDING ALL)"
                )
            self.db_conn.commit()

            # Insert records into shadow. This is row-by-row for now; BUG-24
            # replaces the inner loop with a batched execute_values.
            with self.db_conn.cursor() as cur:
                rows_written = self._write_records_to_table(cur, shadow_table, records)

            # Atomic swap: original → _old, shadow → original, drop _old.
            # All in a single transaction so observers never see a missing
            # staging table.
            with self.db_conn.cursor() as cur:
                cur.execute(f"DROP TABLE IF EXISTS {old_table} CASCADE")
                cur.execute(f"ALTER TABLE {table_name} RENAME TO {old_table}")
                cur.execute(f"ALTER TABLE {shadow_table} RENAME TO {table_name}")
                cur.execute(f"DROP TABLE {old_table} CASCADE")
            self.db_conn.commit()

            # BUG-VIEW-CASCADE-DROP (2026-05-10): refresh wrapper table that
            # decouples combined_data_enriched view from this staging swap.
            # See schema/145, schema/146, etl/refresh_region_wrapper.sql.
            # Without this refresh, view would carry stale region data after
            # nightly sync. ~947 rows, <1s. Refresh failure non-fatal —
            # wrapper retains prior contents; view still works.
            if table_name == "staging_vinsight_stock_items":
                try:
                    with self.db_conn.cursor() as cur:
                        cur.execute("TRUNCATE TABLE staging_vinsight_region_lookup")
                        cur.execute("""
                            INSERT INTO staging_vinsight_region_lookup
                              (stock_item_code, product_categories, parsed_region, is_active)
                            SELECT DISTINCT ON (raw_data->>'StockItemCode')
                              raw_data->>'StockItemCode',
                              raw_data->>'ProductCategories',
                              SUBSTRING(raw_data->>'ProductCategories' FROM '(?i)region:([^;]+)'),
                              raw_data->>'IsActive'
                            FROM staging_vinsight_stock_items
                            WHERE raw_data->>'StockItemCode' IS NOT NULL
                              AND raw_data->>'ProductCategories' IS NOT NULL
                            ORDER BY raw_data->>'StockItemCode',
                                     raw_data->>'IsActive' DESC NULLS LAST
                        """)
                        wrapper_rows = cur.rowcount
                    self.db_conn.commit()
                    logger.info(
                        "Refreshed staging_vinsight_region_lookup wrapper: "
                        "rows=%d (combined_data_enriched view stays bound)",
                        wrapper_rows,
                    )
                except Exception:
                    self.db_conn.rollback()
                    logger.exception(
                        "Wrapper refresh FAILED — staging_vinsight_region_lookup "
                        "may be stale. View still works on prior contents. "
                        "Manual refresh: psql -f etl/refresh_region_wrapper.sql"
                    )

            elapsed = time.monotonic() - start_time
            logger.info(
                "Shadow-table sync OK: table=%s rows=%d elapsed=%.2fs "
                "(atomic rename complete)",
                table_name, rows_written, elapsed,
            )

        except Exception as exc:
            # Roll back whatever partial DB state exists in this txn.
            try:
                self.db_conn.rollback()
            except Exception:
                logger.exception("Rollback after insert failure also failed")

            # Best-effort: drop the shadow so the next run can retry cleanly.
            # The original {table_name} is untouched — raw data survives.
            try:
                with self.db_conn.cursor() as cur:
                    cur.execute(f"DROP TABLE IF EXISTS {shadow_table} CASCADE")
                self.db_conn.commit()
            except Exception:
                logger.exception(
                    "Failed to drop shadow table %s after error. "
                    "Manual cleanup may be required.",
                    shadow_table,
                )

            elapsed = time.monotonic() - start_time
            logger.error(
                "Shadow-table sync FAILED: table=%s rows_before_fail=%d "
                "elapsed=%.2fs error=%s — original table untouched",
                table_name, rows_written, elapsed, exc,
            )
            raise

        return rows_written

    def _write_records_to_table(self, cur, target_table: str, records: list[dict]) -> int:
        """Batched insert of raw Vinsight records into the shadow staging table.

        BUG-24 (ETL-07): replaces the old row-by-row INSERT loop with
        psycopg2.extras.execute_values in chunks of _BATCH_SIZE. The old
        loop was O(N) round-trips; this is O(N/batch). On batch failure
        we fall back to single-row inserts (per-row SAVEPOINTs) so a
        single bad record can't blow up the whole chunk.

        The caller (_insert_staging) already validated target_table against
        the whitelist of allowed staging tables — this method does NOT
        re-check the name.

        Note: the shadow table always has raw_data + a synced_at (or
        fetched_at) column. The INSERT only writes raw_data + synced_at;
        tables whose column is named fetched_at would fail the INSERT here,
        which is fine because the current codebase consistently uses
        synced_at on these staging tables (see schema/008_m2_foundation.sql
        and the historical behaviour of this method).
        """
        if not records:
            return 0

        total = len(records)
        rows_written = 0

        # Prebuild (raw_json, ) per record for execute_values. The COLS
        # expansion produces `VALUES (%s::jsonb, NOW()), (%s::jsonb, NOW()),...`
        # via the template argument.
        json_rows = [(json.dumps(r, default=str),) for r in records]

        batch_no = 0
        for batch_start in range(0, total, self._BATCH_SIZE):
            batch = json_rows[batch_start:batch_start + self._BATCH_SIZE]
            batch_no += 1
            t0 = time.monotonic()
            try:
                cur.execute("SAVEPOINT batch_sp")
                psycopg2.extras.execute_values(
                    cur,
                    f"INSERT INTO {target_table} (raw_data, synced_at) VALUES %s",
                    batch,
                    template="(%s::jsonb, NOW())",
                    page_size=self._BATCH_SIZE,
                )
                cur.execute("RELEASE SAVEPOINT batch_sp")
                rows_written += len(batch)
                elapsed = time.monotonic() - t0
                logger.info(
                    "vinsight_cogs batch %d/%d: %d rows in %.3fs (target=%s)",
                    batch_no,
                    (total + self._BATCH_SIZE - 1) // self._BATCH_SIZE,
                    len(batch), elapsed, target_table,
                )
            except psycopg2.Error as batch_exc:
                cur.execute("ROLLBACK TO SAVEPOINT batch_sp")
                logger.warning(
                    "vinsight_cogs batch %d failed (%s) — falling back to "
                    "per-row inserts for %d records (target=%s)",
                    batch_no, batch_exc, len(batch), target_table,
                )
                landed = 0
                for json_tuple in batch:
                    try:
                        cur.execute("SAVEPOINT fallback_sp")
                        cur.execute(
                            f"INSERT INTO {target_table} (raw_data, synced_at) "
                            f"VALUES (%s::jsonb, NOW())",
                            json_tuple,
                        )
                        cur.execute("RELEASE SAVEPOINT fallback_sp")
                        landed += 1
                    except psycopg2.Error as row_exc:
                        cur.execute("ROLLBACK TO SAVEPOINT fallback_sp")
                        logger.error(
                            "vinsight_cogs fallback row failed (target=%s): %s",
                            target_table, row_exc,
                        )
                rows_written += landed
                logger.info(
                    "vinsight_cogs batch %d fallback: %d/%d rows landed "
                    "(target=%s)",
                    batch_no, landed, len(batch), target_table,
                )
        return rows_written

    def _api_get(self, endpoint: str, expand: str | None = None) -> dict | list | None:
        """Make API GET request with retry logic."""
        url = f"{BASE_URL}{endpoint}?api-key={self.api_key}&$top=9999"
        if expand:
            url += f"&$expand={expand}"
            logger.info("Using $expand=%s for %s", expand, endpoint)

        for attempt in range(MAX_RETRIES):
            try:
                response = self._session.get(url, timeout=30)

                if response.status_code == 200:
                    return response.json()

                if response.status_code == 429 or response.status_code >= 500:
                    backoff = BACKOFF_SECONDS[min(attempt, len(BACKOFF_SECONDS) - 1)]
                    logger.warning(
                        "HTTP %d from %s (attempt %d/%d). Retrying in %ds...",
                        response.status_code, endpoint, attempt + 1, MAX_RETRIES, backoff,
                    )
                    time.sleep(backoff)
                    continue

                logger.error(
                    "HTTP %d from %s: %s",
                    response.status_code, endpoint, response.text[:500],
                )
                return None

            except requests.RequestException as exc:
                backoff = BACKOFF_SECONDS[min(attempt, len(BACKOFF_SECONDS) - 1)]
                logger.warning(
                    "Request error for %s (attempt %d/%d): %s. Retrying in %ds...",
                    endpoint, attempt + 1, MAX_RETRIES, exc, backoff,
                )
                time.sleep(backoff)

        logger.error("All %d retries exhausted for %s", MAX_RETRIES, endpoint)
        return None

    def close(self) -> None:
        """Close connections."""
        self._session.close()
        if self.db_conn and not self.db_conn.closed:
            self.db_conn.close()
        logger.info("VinsightCOGSSyncer closed")


# CLI entry point
if __name__ == "__main__":
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

    syncer = VinsightCOGSSyncer(api_key=api_key, db_connection_string=database_url)

    try:
        # Sync from Vinsight API to staging
        print("=== Syncing from Vinsight API ===")
        sync_results = syncer.sync_all()
        print(f"Sync results: {sync_results}")

        # Transform staging to core tables
        print("\n=== Transforming to core tables ===")
        transform_results = syncer.transform_to_core()
        print(f"Transform results: {transform_results}")

        total = sum(sync_results.values())
        if total == 0:
            logger.warning("No records synced. Check API key permissions.")
            sys.exit(1)

        sys.exit(0)

    except RuntimeError as exc:
        logger.error("Sync aborted: %s", exc)
        sys.exit(2)
    except Exception as exc:
        logger.error("Unexpected error: %s", exc, exc_info=True)
        sys.exit(1)
    finally:
        syncer.close()
