export const dynamic = 'force-dynamic';

import { NextRequest, NextResponse } from 'next/server';
import getPool from '@/lib/db';

/**
 * GET /api/browse?table=<table_name>&page=<page>&limit=<limit>
 *
 * Returns paginated rows from any public table.
 * Table name is validated against information_schema whitelist.
 */

const TABLE_NAME_RE = /^[a-z_][a-z0-9_]*$/;

export async function GET(request: NextRequest) {
  const tableName = request.nextUrl.searchParams.get('table');
  const page = Math.max(1, parseInt(request.nextUrl.searchParams.get('page') || '1', 10));
  const limit = Math.min(100, Math.max(1, parseInt(request.nextUrl.searchParams.get('limit') || '50', 10)));
  const offset = (page - 1) * limit;

  if (!tableName || !TABLE_NAME_RE.test(tableName)) {
    return NextResponse.json(
      { error: 'Invalid or missing table parameter' },
      { status: 400 }
    );
  }

  try {
    const pool = getPool();

    // Validate table exists in public schema (prevents injection)
    const check = await pool.query(
      `SELECT 1 FROM information_schema.tables
       WHERE table_schema = 'public'
         AND table_type IN ('BASE TABLE', 'VIEW')
         AND table_name = $1`,
      [tableName]
    );

    if (check.rows.length === 0) {
      return NextResponse.json(
        { error: `Table "${tableName}" not found` },
        { status: 404 }
      );
    }

    // Get total count
    const countResult = await pool.query(
      `SELECT count(*)::integer AS total FROM "${tableName}"`
    );
    const total = countResult.rows[0].total;

    // Check if table has a raw_data JSONB column (staging tables)
    const colCheck = await pool.query(
      `SELECT column_name, data_type FROM information_schema.columns
       WHERE table_schema = 'public' AND table_name = $1
       ORDER BY ordinal_position`,
      [tableName]
    );
    const colTypes = colCheck.rows as { column_name: string; data_type: string }[];
    const hasRawData = colTypes.some(
      (c) => c.column_name === 'raw_data' && (c.data_type === 'jsonb' || c.data_type === 'json')
    );

    let columns: string[];
    let rows: unknown[][];

    if (hasRawData) {
      // Flatten JSONB: extract keys from first rows, then select them as columns
      const keysResult = await pool.query(
        `SELECT DISTINCT jsonb_object_keys(raw_data) AS k
         FROM "${tableName}" WHERE raw_data IS NOT NULL LIMIT 200`
      );
      const jsonKeys = (keysResult.rows as { k: string }[]).map((r) => r.k);

      // Build SELECT: id, each JSON key, imported_at
      const otherCols = colTypes
        .filter((c) => c.column_name !== 'raw_data')
        .map((c) => c.column_name);

      const jsonSelects = jsonKeys.map(
        (k) => `raw_data->>'${k.replace(/'/g, "''")}' AS "${k}"`
      );

      const allSelects = [
        ...otherCols.map((c) => `"${c}"`),
        ...jsonSelects,
      ];

      const result = await pool.query(
        `SELECT ${allSelects.join(', ')} FROM "${tableName}" ORDER BY 1 LIMIT ${limit} OFFSET ${offset}`
      );

      columns = result.fields.map((f: { name: string }) => f.name);
      rows = result.rows.map((row: Record<string, unknown>) =>
        columns.map((col: string) => row[col] ?? null)
      );
    } else {
      // Normal table — select as-is
      const result = await pool.query(
        `SELECT * FROM "${tableName}" ORDER BY 1 LIMIT ${limit} OFFSET ${offset}`
      );

      columns = result.fields.map((f: { name: string }) => f.name);
      rows = result.rows.map((row: Record<string, unknown>) =>
        columns.map((col: string) => row[col] ?? null)
      );
    }

    return NextResponse.json({
      table: tableName,
      columns,
      rows,
      total,
      page,
      limit,
      totalPages: Math.ceil(total / limit),
    });
  } catch (err) {
    console.error(`[/api/browse] Error browsing "${tableName}":`, err);
    return NextResponse.json(
      { error: `Failed to browse table: ${tableName}` },
      { status: 500 }
    );
  }
}
