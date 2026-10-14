export const dynamic = 'force-dynamic';

import { NextRequest, NextResponse } from 'next/server';
import getPool from '@/lib/db';

/**
 * GET /api/admin
 * Returns all data for the Admin / Data Sources page.
 *
 * Query params:
 *   action=export_csv  — download sales_transaction as CSV
 *   (no action)        — return JSON with sources, etl_runs, sku_mapping,
 *                         channel_assignments, bottling_activity, data_quality
 */
export async function GET(request: NextRequest) {
  try {
    const pool = getPool();
    const action = request.nextUrl.searchParams.get('action');
    const skuFilter = request.nextUrl.searchParams.get('sku_filter') || 'all';
    const dwsOnly = skuFilter === 'dws-eligible';

    // ── CSV Export ─────────────────────────────────────────────────────
    if (action === 'export_csv') {
      return await handleCsvExport(pool);
    }

    // DWS-eligible filter: restrict the SKU Code Mapping widget to SKUs that
    // are either already mapped to a DWS code OR have any DWS-source sales
    // history. Cuts the catalogue-wide 744 down to the ~70 DWS resells.
    // sales_transaction has source_system (text) — channel is via channel_id FK,
    // so source_system='dws' is the simplest correct proxy.
    const dwsEligibleClause = dwsOnly
      ? `AND (
          EXISTS (SELECT 1 FROM sku_code_map scm2 WHERE scm2.sku_id = s.sku_id AND scm2.source_system = 'dws')
          OR EXISTS (SELECT 1 FROM sales_transaction st2 WHERE st2.sku_id = s.sku_id AND st2.source_system = 'dws')
        )`
      : '';

    // ── Default: return admin dashboard JSON ──────────────────────────
    const [
      statusResult,
      etlResult,
      skuMappingResult,
      skuSummaryResult,
      channelAssignResult,
      bottlingResult,
      dqUnmatchedSku,
      dqUnmatchedCustomer,
      dqTotalRows,
    ] = await Promise.all([
      // 1. Source status — latest run per source
      pool.query(`
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
      `),

      // 2. Recent ETL runs
      pool.query(`
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
        LIMIT 20
      `),

      // 3. SKU code mapping — DWS codes (no LIMIT; client paginates ~744 max)
      pool.query(`
        SELECT
          s.sku_code as moppity_code,
          scm.external_code as dws_code
        FROM sku s
        LEFT JOIN sku_code_map scm ON scm.sku_id = s.sku_id AND scm.source_system = 'dws'
        WHERE s.variety IS NOT NULL
        ${dwsEligibleClause}
        ORDER BY CASE WHEN s.sku_code ~ '^[0-9]' THEN 1 ELSE 0 END, s.sku_code
      `),

      // 4. SKU mapping summary
      pool.query(`
        SELECT
          COUNT(*)::int as total,
          COUNT(scm.map_id)::int as mapped,
          (COUNT(*) - COUNT(scm.map_id))::int as unmapped
        FROM sku s
        LEFT JOIN sku_code_map scm ON scm.sku_id = s.sku_id AND scm.source_system = 'dws'
        WHERE s.variety IS NOT NULL
        ${dwsEligibleClause}
      `),

      // 5. Channel assignments — DWS/ALM customers
      pool.query(`
        SELECT c.customer_name, ch.channel_name AS channel
        FROM customer c
        JOIN channel ch ON ch.channel_id = c.channel_id
        WHERE ch.channel_name IN ('DWS', 'ALM')
        ORDER BY ch.channel_name, c.customer_name
        LIMIT 50
      `),

      // 6. Recent bottling activity from staging Vinsight stock items
      pool.query(`
        SELECT
          "StockItemCode",
          "Description",
          "UnitsInStock",
          "LastModifiedOn"
        FROM staging_vinsight_stock_items
        WHERE "Category" ILIKE '%bottled%'
           OR "Category" ILIKE '%wine%'
        ORDER BY "LastModifiedOn" DESC NULLS LAST
        LIMIT 20
      `).catch(() => ({ rows: [] })),

      // 7. Data quality: unmatched SKUs
      pool.query(`
        SELECT COUNT(*)::int as count
        FROM sales_transaction
        WHERE canonical_sku_id IS NULL
          AND quantity > 0
      `).catch(() => ({ rows: [{ count: 0 }] })),

      // 8. Data quality: unmatched customers
      pool.query(`
        SELECT COUNT(*)::int as count
        FROM sales_transaction
        WHERE customer_id IS NULL
          AND quantity > 0
      `).catch(() => ({ rows: [{ count: 0 }] })),

      // 9. Data quality: total rows
      pool.query(`
        SELECT COUNT(*)::int as count
        FROM sales_transaction
        WHERE quantity > 0
      `).catch(() => ({ rows: [{ count: 0 }] })),
    ]);

    // Build source statuses
    const SOURCE_CONFIG = [
      { key: 'vinsight', display_name: 'Vinsight', description: 'Wine operations & inventory' },
      { key: 'xero_trust', display_name: 'Xero (Trust)', description: 'Accounting — Trust tenant' },
      { key: 'xero_wines', display_name: 'Xero (Wines Pty Ltd)', description: 'Accounting — Wines tenant' },
      { key: 'google_sheets', display_name: 'Google Sheets', description: 'Planning sheets (read-only)' },
    ];

    const latestBySource = new Map<string, typeof statusResult.rows[0]>();
    for (const row of statusResult.rows) {
      latestBySource.set(row.source, row);
    }

    const now = new Date();
    const twentyFourHoursAgo = new Date(now.getTime() - 24 * 60 * 60 * 1000);

    const sources = SOURCE_CONFIG.map(cfg => {
      const row = latestBySource.get(cfg.key);
      if (!row) {
        return {
          source: cfg.key,
          display_name: cfg.display_name,
          description: cfg.description,
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
      if (hasErrors) status = 'red';
      else if (lastSyncDate < twentyFourHoursAgo) status = 'yellow';
      else status = 'green';

      return {
        source: cfg.key,
        display_name: cfg.display_name,
        description: cfg.description,
        status,
        last_sync: lastSync,
        rows_total: row.rows_processed || 0,
        error: row.error_detail || null,
      };
    });

    // Format ETL runs with duration
    const etl_runs = etlResult.rows.map(row => {
      let duration: string | null = null;
      if (row.completed_at && row.started_at) {
        const ms = new Date(row.completed_at).getTime() - new Date(row.started_at).getTime();
        const secs = Math.round(ms / 1000);
        duration = secs >= 60 ? `${Math.floor(secs / 60)}m ${secs % 60}s` : `${secs}s`;
      }
      return {
        run_id: row.run_id,
        source: row.source,
        endpoint: row.endpoint,
        status: row.status,
        rows_processed: row.rows_processed || 0,
        rows_skipped: row.rows_skipped || 0,
        error_count: row.error_count || 0,
        error_detail: row.error_detail,
        started_at: row.started_at,
        duration,
      };
    });

    const sku_mapping = skuMappingResult.rows.map(row => ({
      moppity_code: row.moppity_code,
      dws_code: row.dws_code || null,
    }));

    const summary = skuSummaryResult.rows[0];

    // Channel assignments
    const channel_assignments = channelAssignResult.rows.map(row => ({
      customer_name: row.customer_name,
      channel: row.channel,
    }));

    // Bottling activity
    const bottling_activity = bottlingResult.rows.map(row => ({
      stock_item_code: row.StockItemCode,
      description: row.Description,
      units_in_stock: row.UnitsInStock,
      last_modified: row.LastModifiedOn,
    }));

    // Data quality
    const data_quality = {
      total_transactions: dqTotalRows.rows[0]?.count ?? 0,
      unmatched_skus: dqUnmatchedSku.rows[0]?.count ?? 0,
      unmatched_customers: dqUnmatchedCustomer.rows[0]?.count ?? 0,
    };

    return NextResponse.json({
      sources,
      etl_runs,
      sku_mapping,
      sku_mapping_summary: {
        total: summary.total,
        mapped: summary.mapped,
        unmapped: summary.unmapped,
      },
      channel_assignments,
      bottling_activity,
      data_quality,
    });
  } catch (err) {
    console.error('[/api/admin] Error:', err);
    return NextResponse.json(
      { error: 'Failed to load admin data' },
      { status: 500 }
    );
  }
}

// ── CSV Export Handler ──────────────────────────────────────────────────

function escapeCsvField(value: unknown): string {
  if (value === null || value === undefined) return '';
  const str = String(value);
  // Wrap in quotes if contains comma, quote, or newline
  if (str.includes(',') || str.includes('"') || str.includes('\n') || str.includes('\r')) {
    return '"' + str.replace(/"/g, '""') + '"';
  }
  return str;
}

async function handleCsvExport(pool: ReturnType<typeof getPool>) {
  try {
    // BUG-EXPORT-CSV-COLLAPSE (2026-05-13): sources from combined_data_enriched view
    // so sku / item_code / item_description are 3 DISTINCT values per row (canonical name,
    // per-source SKU code, Vinsight ProductName). Prior version joined raw `sku` table,
    // inheriting parent-canonical triple-collapse from the BUG-175 parent-shape rows
    // (sku_code = item_description = canonical_sku.sku_name) for 114,848 of ~120k rows.
    // The owner 2026-05-08 3:34 AM flagged this collapse as Phase 1 close blocker.
    // ADR rule: every CSV export endpoint MUST source from combined_data_enriched view,
    // no direct sku-table joins.
    const result = await pool.query(`
      SELECT
        sale_date::text                                       AS date,
        period                                                AS cal_month,
        COALESCE(customer_name, '')                           AS customer_name,
        COALESCE(customer_group, '')                          AS customer_group,
        COALESCE(channel, '')                                 AS channel,
        COALESCE(territory, '')                               AS territory,
        COALESCE(warehouse, '')                               AS warehouse,
        COALESCE(source_ref, '')                              AS invoice_no,
        COALESCE(sku, '')                                     AS sku,
        COALESCE(item_code, '')                               AS item_code,
        COALESCE(item_description, '')                        AS item_description,
        COALESCE(variety, '')                                 AS variety,
        COALESCE(region, '')                                  AS region,
        COALESCE(vintage::text, '')                           AS vintage,
        COALESCE(range_name, '')                              AS range,
        COALESCE(qty, 0)                                      AS cases_dozens,
        CASE WHEN COALESCE(qty, 0) > 0
          THEN ROUND((net_revenue / qty)::numeric, 4)
          ELSE 0 END                                          AS unit_price,
        COALESCE(base_wholesale, 0)                           AS base_wholesale,
        COALESCE(revenue, 0)                                  AS wholesale_value,
        COALESCE(discount, 0)                                 AS discount,
        COALESCE(rebate, 0)                                   AS rebate,
        COALESCE(fee, 0)                                      AS fee,
        COALESCE(net_revenue, 0)                              AS net_revenue,
        COALESCE(transfer_cost, 0)                            AS transfer_cost,
        COALESCE(total_cogs, 0)                               AS total_cogs,
        CASE WHEN COALESCE(net_revenue, 0) > 0
          THEN ROUND(((net_revenue - COALESCE(total_cogs, 0)) / net_revenue * 100)::numeric, 1)
          ELSE 0 END                                          AS gp_pct,
        CASE WHEN COALESCE(qty, 0) > 0
          THEN ROUND((net_revenue / qty)::numeric, 2)
          ELSE 0 END                                          AS net_per_case,
        COALESCE(source_system, '')                           AS source
      FROM combined_data_enriched
      WHERE qty > 0
      ORDER BY sale_date DESC, customer_name
    `);

    const CSV_HEADERS = [
      'date', 'cal_month', 'customer_name', 'customer_group', 'channel', 'territory',
      'warehouse', 'invoice_no', 'sku', 'item_code', 'item_description', 'variety',
      'region', 'vintage', 'range', 'cases_dozens', 'unit_price', 'base_wholesale',
      'wholesale_value', 'discount', 'rebate', 'fee', 'net_revenue', 'transfer_cost',
      'total_cogs', 'gp_pct', 'net_per_case', 'source',
    ];

    // Build CSV string
    const lines: string[] = [CSV_HEADERS.join(',')];

    for (const row of result.rows) {
      const line = CSV_HEADERS.map(h => escapeCsvField(row[h])).join(',');
      lines.push(line);
    }

    const csv = lines.join('\n');
    const filename = `moppity_combined_data_${new Date().toISOString().slice(0, 10)}.csv`;

    return new Response(csv, {
      status: 200,
      headers: {
        'Content-Type': 'text/csv; charset=utf-8',
        'Content-Disposition': `attachment; filename="${filename}"`,
        'Cache-Control': 'no-store',
      },
    });
  } catch (err) {
    console.error('[/api/admin] CSV export error:', err);
    return NextResponse.json(
      { error: 'Failed to export CSV' },
      { status: 500 }
    );
  }
}
