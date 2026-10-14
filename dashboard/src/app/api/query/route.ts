export const dynamic = 'force-dynamic';

import { NextRequest, NextResponse } from 'next/server';
import getPool from '@/lib/db';

/**
 * POST /api/query
 * Runs a pre-defined, whitelisted SQL query by queryId.
 * NO arbitrary SQL is accepted — only the queries defined below.
 */

interface QueryDefinition {
  name: string;
  sql: string;
}

// VIEW_ONLY demo mirror drops `staging_xero_invoices` and `access_combined_data`.
// When set, top_wines/channel_breakdown repoint to the masked
// combined_data_enriched view, and the two Xero queries return an empty set
// without touching the dropped table (handled in POST). Flag unset (live
// editor) => the base QUERIES below run verbatim, zero behavior change.
const VIEW_ONLY = process.env.VIEW_ONLY === 'true';

const QUERIES: Record<string, QueryDefinition> = {
  top_wines: {
    name: 'Top 10 Wines by Sales Volume',
    sql: `
      SELECT raw_data->>'SKU' as sku, raw_data->>'ItemDescription' as wine, COUNT(*) as transactions
      FROM access_combined_data
      WHERE raw_data->>'SKU' IS NOT NULL AND raw_data->>'SKU' <> ''
      GROUP BY 1, 2 ORDER BY transactions DESC LIMIT 10
    `,
  },
  channel_breakdown: {
    name: 'Sales by Channel',
    sql: `
      SELECT UPPER(raw_data->>'Channel') as channel, COUNT(*) as transactions
      FROM access_combined_data
      WHERE raw_data->>'Channel' IS NOT NULL AND raw_data->>'Channel' <> ''
      GROUP BY UPPER(raw_data->>'Channel')
      ORDER BY transactions DESC
    `,
  },
  code_mappings: {
    name: 'DWS to MV Code Mappings',
    sql: `
      SELECT a.external_code as dws_code, b.external_code as mv_code
      FROM sku_code_map a, sku_code_map b
      WHERE a.source_system = 'dws' AND b.source_system = 'MOPPITY'
      AND a.map_id + 1 = b.map_id
      ORDER BY a.external_code
    `,
  },
  xero_summary: {
    name: 'Xero Invoices by Entity',
    sql: `
      SELECT
        CASE WHEN tenant_id = '00000000-0000-4000-8000-000000000001' THEN 'Moppity Trust'
             WHEN tenant_id = '00000000-0000-4000-8000-000000000002' THEN 'Wines Pty Ltd'
        END as entity,
        COUNT(*) as invoices,
        COALESCE(SUM(total), 0) as total_value
      FROM staging_xero_invoices GROUP BY tenant_id
    `,
  },
  recent_invoices: {
    name: 'Latest 10 Xero Invoices',
    sql: `
      SELECT contact_name, invoice_number, status, total, date
      FROM staging_xero_invoices
      WHERE contact_name IS NOT NULL
      ORDER BY date DESC LIMIT 10
    `,
  },
};

// VIEW_ONLY overrides: repoint the two access_combined_data queries at the
// already-masked combined_data_enriched view (its `sku`, `item_description`
// and `channel` columns cover both). Preserves the original output shapes.
const VIEW_ONLY_QUERY_OVERRIDES: Record<string, QueryDefinition> = {
  top_wines: {
    name: 'Top 10 Wines by Sales Volume',
    sql: `
      SELECT sku, item_description AS wine, COUNT(*) AS transactions
      FROM combined_data_enriched
      WHERE sku IS NOT NULL AND sku <> ''
      GROUP BY sku, item_description ORDER BY transactions DESC LIMIT 10
    `,
  },
  channel_breakdown: {
    name: 'Sales by Channel',
    sql: `
      SELECT UPPER(channel) AS channel, COUNT(*) AS transactions
      FROM combined_data_enriched
      WHERE channel IS NOT NULL AND channel <> ''
      GROUP BY UPPER(channel)
      ORDER BY transactions DESC
    `,
  },
};

// VIEW_ONLY: queryIds whose source table is dropped — return an empty result
// set with the same columns the client expects, without hitting the DB.
const VIEW_ONLY_EMPTY_COLUMNS: Record<string, string[]> = {
  xero_summary: ['entity', 'invoices', 'total_value'],
  recent_invoices: ['contact_name', 'invoice_number', 'status', 'total', 'date'],
};

export async function POST(request: NextRequest) {
  try {
    const body = await request.json();
    const { queryId } = body;

    if (!queryId || typeof queryId !== 'string') {
      return NextResponse.json(
        { error: 'Missing or invalid queryId' },
        { status: 400 }
      );
    }

    const baseDef = QUERIES[queryId];
    if (!baseDef) {
      return NextResponse.json(
        { error: `Unknown queryId: ${queryId}. Valid options: ${Object.keys(QUERIES).join(', ')}` },
        { status: 400 }
      );
    }

    // VIEW_ONLY: dropped-table queries return an empty set (no DB hit).
    if (VIEW_ONLY && VIEW_ONLY_EMPTY_COLUMNS[queryId]) {
      return NextResponse.json({
        columns: VIEW_ONLY_EMPTY_COLUMNS[queryId],
        rows: [],
        queryName: baseDef.name,
      });
    }

    // VIEW_ONLY: repoint access_combined_data queries at the masked view.
    const queryDef = VIEW_ONLY
      ? VIEW_ONLY_QUERY_OVERRIDES[queryId] ?? baseDef
      : baseDef;

    const pool = getPool();
    const result = await pool.query(queryDef.sql);

    // Extract column names from the first result
    const columns = result.fields.map((f) => f.name);

    // Convert rows to arrays (ordered by column position)
    const rows = result.rows.map((row) =>
      columns.map((col) => row[col])
    );

    return NextResponse.json({
      columns,
      rows,
      queryName: queryDef.name,
    });
  } catch (err) {
    console.error('[/api/query] Error:', err);

    // Check for common Postgres errors (table doesn't exist yet, etc.)
    const pgErr = err as { code?: string; message?: string };
    if (pgErr.code === '42P01') {
      return NextResponse.json(
        { error: 'Table not found — this data source may not be loaded yet.' },
        { status: 404 }
      );
    }

    return NextResponse.json(
      { error: 'Query execution failed' },
      { status: 500 }
    );
  }
}
