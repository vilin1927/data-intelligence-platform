export const dynamic = 'force-dynamic';

import { NextResponse } from 'next/server';
import getPool from '@/lib/db';
import { LEGACY_REPORTS } from '@/lib/legacyReports';

/**
 * GET /api/legacy-reports
 *
 * row count + last-imported timestamp, for the `/legacy-reports` index UI.
 *
 * Response shape:
 *   [{ name, accessName, displayName, description, rowCount, lastImported }]
 *
 * The table-name list is hard-coded via `LEGACY_REPORTS` (see
 * `dashboard/src/lib/legacyReports.ts`) — this prevents SQL injection on
 * the per-table count queries since table names cannot be parameterized.
 */
export async function GET() {
  try {
    const pool = getPool();

    // Execute the 14 (count + max(_imported_at)) queries in parallel. Each
    // table name is taken from a hard-coded allowlist constant — no user
    // input is interpolated.
    const results = await Promise.all(
      LEGACY_REPORTS.map(async (report) => {
        try {
          const { rows } = await pool.query(
            `SELECT count(*)::bigint AS row_count,
                    MAX(_imported_at) AS last_imported
               FROM ${report.tableName}`
          );
          const row = rows[0] ?? { row_count: 0, last_imported: null };
          return {
            name: report.tableName,
            accessName: report.accessName,
            displayName: report.displayName,
            description: report.description,
            rowCount: Number(row.row_count ?? 0),
            lastImported: row.last_imported as string | null,
          };
        } catch (innerErr) {
          // Per-table failure (e.g. table not yet migrated on a fresh DB)
          // surfaces as rowCount=null instead of failing the whole index.
          console.error(
            `[/api/legacy-reports] ${report.tableName} count failed:`,
            innerErr,
          );
          return {
            name: report.tableName,
            accessName: report.accessName,
            displayName: report.displayName,
            description: report.description,
            rowCount: null,
            lastImported: null,
          };
        }
      }),
    );

    return NextResponse.json(results);
  } catch (err) {
    console.error('[/api/legacy-reports] Error:', err);
    return NextResponse.json(
      { error: 'Failed to load legacy reports index' },
      { status: 500 },
    );
  }
}
