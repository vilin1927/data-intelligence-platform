export const dynamic = 'force-dynamic';

import { NextResponse } from 'next/server';
import getPool from '@/lib/db';

/**
 * GET /api/status
 * Returns connection status per data source.
 * Queries etl_run_log for the latest run per source.
 *
 * Status logic:
 *   green  — last sync <24h ago AND no errors
 *   yellow — last sync >24h ago (stale) but no errors
 *   red    — errors on last run OR never synced
 */

interface SourceStatus {
  source: string;
  display_name: string;
  status: 'green' | 'yellow' | 'red';
  last_sync: string | null;
  rows_total: number;
  error: string | null;
}

// Map internal source keys to display names and etl_run_log source values
const SOURCE_CONFIG = [
  { key: 'vinsight',      display_name: 'Vinsight',            source_match: 'vinsight' },
  { key: 'xero_trust',    display_name: 'Xero (Trust)',        source_match: 'xero_trust' },
  { key: 'xero_wines',    display_name: 'Xero (Wines Pty Ltd)', source_match: 'xero_wines' },
  { key: 'google_sheets', display_name: 'Google Sheets',       source_match: 'google_sheets' },
];

export async function GET() {
  try {
    const pool = getPool();

    // Get the latest ETL run for each source using DISTINCT ON
    const query = `
      SELECT DISTINCT ON (source)
        source,
        status,
        started_at,
        completed_at,
        rows_processed,
        error_count,
        error_detail
      FROM etl_run_log
      WHERE source IN ('vinsight', 'xero_trust', 'xero_wines', 'google_sheets')
      ORDER BY source, started_at DESC
    `;

    const result = await pool.query(query);

    // Build a map from etl source name -> latest row
    const latestBySource = new Map<string, typeof result.rows[0]>();
    for (const row of result.rows) {
      latestBySource.set(row.source, row);
    }

    const now = new Date();
    const twentyFourHoursAgo = new Date(now.getTime() - 24 * 60 * 60 * 1000);

    const statuses: SourceStatus[] = SOURCE_CONFIG.map((cfg) => {
      const row = latestBySource.get(cfg.source_match);

      if (!row) {
        // Never synced
        return {
          source: cfg.key,
          display_name: cfg.display_name,
          status: 'red' as const,
          last_sync: null,
          rows_total: 0,
          error: 'Never synced',
        };
      }

      const lastSync = row.completed_at || row.started_at;
      const lastSyncDate = new Date(lastSync);
      const hasErrors = row.error_count > 0 || row.status === 'failed';

      let status: 'green' | 'yellow' | 'red';
      if (hasErrors) {
        status = 'red';
      } else if (lastSyncDate < twentyFourHoursAgo) {
        status = 'yellow';
      } else {
        status = 'green';
      }

      return {
        source: cfg.key,
        display_name: cfg.display_name,
        status,
        last_sync: lastSync,
        rows_total: row.rows_processed || 0,
        error: row.error_detail || null,
      };
    });

    return NextResponse.json(statuses);
  } catch (err) {
    console.error('[/api/status] Error:', err);

    // If DB is unreachable, return all sources as red
    const fallback: SourceStatus[] = SOURCE_CONFIG.map((cfg) => ({
      source: cfg.key,
      display_name: cfg.display_name,
      status: 'red' as const,
      last_sync: null,
      rows_total: 0,
      error: 'Database connection failed',
    }));

    return NextResponse.json(fallback, { status: 500 });
  }
}
