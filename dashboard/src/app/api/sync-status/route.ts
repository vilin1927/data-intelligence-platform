export const dynamic = 'force-dynamic';

import { NextResponse } from 'next/server';
import getPool from '@/lib/db';

/**
 * GET /api/sync-status
 * Returns per-staging-table freshness for Vinsight sync health.
 *
 * Status logic:
 *   fresh — synced within 48 hours
 *   stale — synced more than 48 hours ago
 *   error — null timestamp (never synced or table empty)
 */

interface SyncSource {
  source: string;
  display_name: string;
  last_sync: string | null;
  rows: number;
  status: 'fresh' | 'stale' | 'error';
}

export async function GET() {
  try {
    const pool = getPool();

    const result = await pool.query(`
      SELECT 'stock_items' as source, max(synced_at) as last_sync, count(*)::int as rows FROM staging_vinsight_stock_items
      UNION ALL SELECT 'contacts', max(synced_at), count(*)::int FROM staging_vinsight_contacts
      UNION ALL SELECT 'sales_orders', max(synced_at), count(*)::int FROM staging_vinsight_sales_orders
      UNION ALL SELECT 'wine_batches', max(synced_at), count(*)::int FROM staging_vinsight_wine_batches
      UNION ALL SELECT 'vessels', max(synced_at), count(*)::int FROM staging_vinsight_vessels
      UNION ALL SELECT 'packaging_ops', max(synced_at), count(*)::int FROM staging_vinsight_packaging_operations
      UNION ALL SELECT 'sales_order_items', max(synced_at), count(*)::int FROM vinsight_sales_order_item
      ORDER BY last_sync
    `);

    const DISPLAY_NAMES: Record<string, string> = {
      stock_items: 'Stock Items',
      contacts: 'Contacts',
      sales_orders: 'Sales Orders',
      wine_batches: 'Wine Batches',
      vessels: 'Vessels',
      packaging_ops: 'Packaging Ops',
      sales_order_items: 'Order Items',
    };

    // BUG-74: Fall back to etl_run_log for sources whose staging tables are
    // empty but whose ETL job succeeded recently. The cogs cron hits
    // /WineBatches.json /Vessels.json /PackagingOperations.json daily under
    // source='vinsight_cogs'; when Vinsight returns 0 rows, synced_at stays
    // NULL and the widget incorrectly showed these rows as red "Error".
    // Now: show them as fresh/stale based on the most recent successful run.
    const ETL_FALLBACK_ENDPOINTS: Record<string, string> = {
      wine_batches: '/WineBatches.json',
      vessels: '/Vessels.json',
      packaging_ops: '/PackagingOperations.json',
    };

    const fallbackRows = await pool.query(
      `SELECT endpoint, MAX(completed_at) AS last_run
         FROM etl_run_log
        WHERE status = 'success'
          AND endpoint = ANY($1::text[])
        GROUP BY endpoint`,
      [Object.values(ETL_FALLBACK_ENDPOINTS)]
    );
    const endpointLastRun = new Map<string, Date>();
    for (const row of fallbackRows.rows) {
      if (row.last_run) endpointLastRun.set(row.endpoint, new Date(row.last_run));
    }

    // BUG-74 AC#4: staging tables for wine_batches/vessels/packaging_ops are
    // legitimately empty (Vinsight returns 0 via those endpoints for this
    // tenant); the real population happens inline during Stock/Order pulls +
    // cogs cron. Widget showing rows=0 misleads users — pull the core-table
    // count so they see the actual data volume backing the "Fresh" label.
    const coreCountRows = await pool.query(`
      SELECT 'wine_batches' AS source, COUNT(*)::int AS rows FROM wine_batch
      UNION ALL SELECT 'vessels', COUNT(*)::int FROM vessel
      UNION ALL SELECT 'packaging_ops', COUNT(*)::int FROM packaging_operation
    `);
    const coreCountBySource = new Map<string, number>();
    for (const row of coreCountRows.rows) {
      coreCountBySource.set(row.source, row.rows ?? 0);
    }

    const now = new Date();
    const fortyEightHoursAgo = new Date(now.getTime() - 48 * 60 * 60 * 1000);

    const sources: SyncSource[] = result.rows.map((row) => {
      // If staging table is empty but the ETL run succeeded recently,
      // use the ETL completion timestamp so the widget doesn't mislead.
      let effectiveLastSync: Date | null = row.last_sync ? new Date(row.last_sync) : null;
      const fallbackEndpoint = ETL_FALLBACK_ENDPOINTS[row.source];
      if (!effectiveLastSync && fallbackEndpoint) {
        const etlTs = endpointLastRun.get(fallbackEndpoint);
        if (etlTs) effectiveLastSync = etlTs;
      }

      let status: 'fresh' | 'stale' | 'error';
      if (!effectiveLastSync) {
        status = 'error';
      } else if (effectiveLastSync < fortyEightHoursAgo) {
        status = 'stale';
      } else {
        status = 'fresh';
      }

      const coreCount = coreCountBySource.get(row.source);
      const effectiveRows = coreCount !== undefined ? coreCount : (row.rows ?? 0);

      return {
        source: row.source,
        display_name: DISPLAY_NAMES[row.source] || row.source,
        last_sync: effectiveLastSync ? effectiveLastSync.toISOString() : null,
        rows: effectiveRows,
        status,
      };
    });

    return NextResponse.json({ sources });
  } catch (err) {
    console.error('[/api/sync-status] Error:', err);
    return NextResponse.json(
      { error: 'Failed to load sync status' },
      { status: 500 }
    );
  }
}
