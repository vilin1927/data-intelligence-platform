export const dynamic = 'force-dynamic';

import { NextRequest, NextResponse } from 'next/server';
import getPool from '@/lib/db';
import {
  LEGACY_REPORT_TABLE_NAMES,
  findLegacyReport,
} from '@/lib/legacyReports';

/**
 * GET /api/legacy-reports/[table]?limit=200
 *
 * report table, used by the drill page at `/legacy-reports/<table>`.
 *
 * Allowlist guard: `[table]` MUST be one of the 14 names in
 * `LEGACY_REPORT_TABLE_NAMES`. SQL injection is prevented by rejecting any
 * value not in the allowlist BEFORE interpolation — table names cannot be
 * parameterized in `SELECT * FROM <ident>`.
 *
 * Pagination is intentionally minimal (LIMIT only, no OFFSET) — pagination
 * polish is a Phase-2 deliverable per B10b prompt.
 */
export async function GET(
  req: NextRequest,
  { params }: { params: { table: string } },
) {
  try {
    const { table } = params;

    // 1. Allowlist guard — reject anything not in our 14-table set.
    if (!LEGACY_REPORT_TABLE_NAMES.has(table)) {
      return NextResponse.json(
        { error: `Unknown legacy report table: ${table}` },
        { status: 404 },
      );
    }

    // 2. Parse limit (defensive: clamp to [1, 1000]).
    const limitParam = req.nextUrl.searchParams.get('limit') ?? '200';
    let limit = parseInt(limitParam, 10);
    if (Number.isNaN(limit) || limit < 1) limit = 200;
    if (limit > 1000) limit = 1000;

    const pool = getPool();

    // 3. Run the SELECT. Table name is interpolated only after the allowlist
    //    check above; LIMIT is a parameterized integer.
    const { rows, fields } = await pool.query(
      `SELECT * FROM ${table} ORDER BY id LIMIT $1`,
      [limit],
    );

    // 4. Surface column metadata so the drill UI can render dynamic headers.
    const columns = fields.map((f) => ({ name: f.name }));

    // 5. Total row count (for pagination hint in UI; cheap on these small tables).
    const { rows: countRows } = await pool.query(
      `SELECT count(*)::bigint AS total FROM ${table}`,
    );
    const total = Number(countRows[0]?.total ?? 0);

    const meta = findLegacyReport(table);

    return NextResponse.json({
      table,
      accessName: meta?.accessName ?? null,
      displayName: meta?.displayName ?? table,
      description: meta?.description ?? null,
      columns,
      rows,
      total,
      limit,
    });
  } catch (err) {
    console.error('[/api/legacy-reports/[table]] Error:', err);
    return NextResponse.json(
      { error: 'Failed to load legacy report rows' },
      { status: 500 },
    );
  }
}
