export const dynamic = 'force-dynamic';

import { NextResponse } from 'next/server';
import getPool from '@/lib/db';

/**
 * GET /api/etl
 * Returns the last 10 ETL runs from etl_run_log, most recent first.
 */

export async function GET() {
  try {
    const pool = getPool();

    const result = await pool.query(`
      SELECT
        run_id,
        source,
        endpoint,
        status,
        rows_processed,
        rows_skipped,
        error_count,
        error_detail,
        started_at,
        completed_at
      FROM etl_run_log
      ORDER BY started_at DESC
      LIMIT 10
    `);

    return NextResponse.json(result.rows);
  } catch (err) {
    console.error('[/api/etl] Error:', err);
    return NextResponse.json(
      { error: 'Failed to fetch ETL run log' },
      { status: 500 }
    );
  }
}
