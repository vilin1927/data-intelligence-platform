export const dynamic = 'force-dynamic';

import { NextRequest, NextResponse } from 'next/server';
import getPool from '@/lib/db';

/**
 * GET /api/legacy-data
 * Unified Combined Data view: Access DB + Vinsight + DWS/ALM uploads.
 * Queries sales_transaction directly and enriches with canonical_sku, canonical_customer,
 * and access_combined_data (for access_db rows).
 *
 * JF-15 fixes:
 *   - Vinsight rows now have territory (via customer.territory_id fallback).
 *   - Channel (on-premise/off-premise) is distinguished from Warehouse (DWS/ALM/Direct).
 *   - sku = canonical SKU name (e.g. "LOCK & KEY SHIRAZ").
 *   - sku_vintage = canonical name + vintage (e.g. "LOCK & KEY SHIRAZ 2021").
 *   - item_code = source-system code (access ItemCode / vinsight stock_item_code / fallback sku_code).
 *   - item_description = source description.
 *   - upload_id = sales_transaction.transaction_id (chronological insert order).
 *   - invoice_no = 5-digit Vinsight OrderNumber (parsed from source_ref middle segment)
 *     for Vinsight rows, not the synthetic `vinsight-{order}-{line}` string.
 *     DWS/ALM rows carry source_ref as-is (already a clean invoice-like string).
 *
 * Params:
 *   type: 'territory' | 'sku' | 'customer' (pivot view)
 *   name: filter value (e.g. 'ACT South Coast')
 *   from: start month (e.g. '2025-02')
 *   to: end month (e.g. '2026-02')
 *   warehouse: 'DWS' | 'ALM' | 'Direct' | 'ILG' (source_system-neutral)
 *   channel: 'ON PREMISE' | 'OFF PREMISE' | 'WHOLESALE' | 'DIRECT' | 'HYBRID'
 *   rep: sales rep name filter (e.g. 'REP I') — JF-24
 *   search: free-text search (customer, invoice, item code)
 *   page: pagination (default 1)
 *   limit: rows per page (default 50, max 100)
 *   format: 'csv' to download
 */

// BUG-20 (2026-04-12): the 10-way join body that used to live here as an inline
// CTE is now a Postgres VIEW (combined_data_enriched, see schema/027). All six
// queries below SELECT directly from the view instead of re-pasting the CTE,
// so the JOIN tree is parsed/planned once and the pool no longer saturates on
// /legacy-data clicks.
const ENRICHED_VIEW = 'combined_data_enriched';

// Interactive CSV rows cap. Larger exports must go through the background
// export path (out of scope for BUG-20 — separate ticket).
const CSV_MAX_ROWS = 50000;

export async function GET(req: NextRequest) {
  try {
    const pool = getPool();
    const params = req.nextUrl.searchParams;

    const type = params.get('type') || 'territory';
    const name = params.get('name') || '';
    const from = params.get('from') || '2025-02';
    const to = params.get('to') || '2026-02';
    const warehouse = params.get('warehouse') || '';
    const channel = params.get('channel') || '';
    const rep = params.get('rep') || '';
    const search = params.get('search') || '';
    const page = Math.max(1, parseInt(params.get('page') || '1'));
    const isCSV = params.get('format') === 'csv';

    // BUG-20: CSV export is capped at 50K rows on the interactive path. If the
    // caller explicitly asks for more, return 413 with a pointer to the
    // background export route (to be built as a separate ticket).
    const requestedLimitRaw = parseInt(params.get('limit') || '0', 10);
    if (isCSV && Number.isFinite(requestedLimitRaw) && requestedLimitRaw > CSV_MAX_ROWS) {
      return new NextResponse(
        `Use background export for >${CSV_MAX_ROWS} rows (interactive CSV is capped for memory safety)`,
        { status: 413 }
      );
    }
    const limit = isCSV
      ? Math.min(CSV_MAX_ROWS, requestedLimitRaw > 0 ? requestedLimitRaw : CSV_MAX_ROWS)
      : Math.min(100, Math.max(1, requestedLimitRaw > 0 ? requestedLimitRaw : 50));
    const offset = (page - 1) * limit;
    // BUG-09/BUG-10: upload_id range filter — when present, bypass the default date
    // range so the post-import "View imported transactions" link shows every row the
    // upload wrote, regardless of sale_date / period.
    const uploadIdMinStr = params.get('upload_id_min');
    const uploadIdMaxStr = params.get('upload_id_max');
    const uploadIdMin = uploadIdMinStr && /^\d+$/.test(uploadIdMinStr) ? parseInt(uploadIdMinStr, 10) : null;
    const uploadIdMax = uploadIdMaxStr && /^\d+$/.test(uploadIdMaxStr) ? parseInt(uploadIdMaxStr, 10) : null;
    const hasUploadIdFilter = uploadIdMin != null && uploadIdMax != null;

    // Build WHERE conditions on the enriched CTE
    const conditions: string[] = [];
    const values: (string | number)[] = [];
    let paramIdx = 1;

    if (hasUploadIdFilter) {
      // Filter purely by transaction_id range — no date bounds so new-vintage/future rows
      // are visible even when they fall outside the default period window.
      conditions.push(`upload_id >= $${paramIdx}`);
      values.push(uploadIdMin as number);
      paramIdx++;
      conditions.push(`upload_id <= $${paramIdx}`);
      values.push(uploadIdMax as number);
      paramIdx++;
    } else {
      // Date range (period column = 'YYYY-MM')
      conditions.push(`period >= $${paramIdx}`);
      values.push(from);
      paramIdx++;
      conditions.push(`period <= $${paramIdx}`);
      values.push(to);
      paramIdx++;
    }

    // Pivot filter
    if (name) {
      if (type === 'territory') {
        conditions.push(`UPPER(territory) = UPPER($${paramIdx})`);
      } else if (type === 'sku') {
        conditions.push(`UPPER(sku) = UPPER($${paramIdx})`);
      } else if (type === 'customer') {
        conditions.push(`UPPER(customer_name) LIKE UPPER($${paramIdx})`);
      }
      values.push(name);
      paramIdx++;
    }

    // Warehouse filter (DWS/ALM/Direct/ILG).
    // Accept legacy 'Y & R' alias from the old page UI by mapping to DWS.
    if (warehouse) {
      if (warehouse === 'Y & R' || warehouse === 'Y&R') {
        conditions.push(`UPPER(warehouse) IN ('DWS', 'Y & R', 'Y&R')`);
      } else {
        conditions.push(`UPPER(warehouse) = UPPER($${paramIdx})`);
        values.push(warehouse);
        paramIdx++;
      }
    }

    // Channel filter (ON PREMISE / OFF PREMISE / WHOLESALE / DIRECT / HYBRID)
    if (channel) {
      conditions.push(`UPPER(channel) = UPPER($${paramIdx})`);
      values.push(channel);
      paramIdx++;
    }

    // JF-24: Rep filter (sales rep name from canonical_customer.rep_name via the view)
    if (rep) {
      conditions.push(`UPPER(rep_name) = UPPER($${paramIdx})`);
      values.push(rep);
      paramIdx++;
    }

    // Free-text search across customer, invoice, item_code, sku
    if (search) {
      conditions.push(`(
        customer_name ILIKE $${paramIdx}
        OR invoice_no ILIKE $${paramIdx}
        OR item_code ILIKE $${paramIdx}
        OR sku ILIKE $${paramIdx}
      )`);
      values.push(`%${search}%`);
      paramIdx++;
    }

    const whereClause = conditions.length > 0 ? `WHERE ${conditions.join(' AND ')}` : '';

    // RECON-OWNER-03 (Phase E §3 default, 2026-04-26): exclude $0-revenue DWS
    // stock-movement rows from revenue/case-count aggregations. The owner's
    // canonical spreadsheet filters these out (276-row delta on Feb25-Jan26
    // sample at audit time; ~1,585 rows / ~231 cases on current prod). They
    // are inventory transfers / consignment movements, not sell-through.
    //
    //   exclude from revenue reports; keep visible in stock-movement audit.
    //
    // Applied to: summary totals, monthly breakdown, pivot, vintage breakdown.
    // NOT applied to: transactions grid + count (grid is the audit surface),
    // reps dropdown (independent of revenue).
    //
    // Override path: if the owner wants these counted, drop this clause from the
    // four aggregation queries below (it is a single AND-joined filter, no
    // schema change required).
    const PHASE_E_EXCLUDE_DWS_STOCK_MOVEMENTS = `NOT (
      COALESCE(net_revenue, 0) = 0
      AND COALESCE(qty, 0) > 0
      AND UPPER(warehouse) = 'DWS'
    )`;
    const aggWhereClause = conditions.length > 0
      ? `WHERE ${conditions.join(' AND ')} AND ${PHASE_E_EXCLUDE_DWS_STOCK_MOVEMENTS}`
      : `WHERE ${PHASE_E_EXCLUDE_DWS_STOCK_MOVEMENTS}`;

    // Run all queries in parallel. Every query targets the combined_data_enriched
    // VIEW (schema/027) so the 10-way JOIN is planned once on the DB side
    // instead of being re-parsed six times per request.
    const [summaryResult, monthlyResult, pivotResult, transactionsResult, countResult, vintageResult, repsResult] = await Promise.all([
      // 1. Summary totals (RECON-OWNER-03 filter applied)
      pool.query(`
        SELECT
          count(*)::bigint                                             AS total_rows,
          round(COALESCE(sum(revenue), 0)::numeric, 2)                 AS total_revenue,
          round(COALESCE(sum(qty), 0)::numeric, 2)                     AS total_cases
        FROM ${ENRICHED_VIEW}
        ${aggWhereClause}
      `, values),

      // 2. Monthly breakdown (RECON-OWNER-03 filter applied)
      pool.query(`
        SELECT
          period                                                       AS month_key,
          cal_month,
          count(*)::bigint                                             AS rows,
          round(COALESCE(sum(revenue), 0)::numeric, 2)                 AS revenue,
          round(COALESCE(sum(qty), 0)::numeric, 2)                     AS cases
        FROM ${ENRICHED_VIEW}
        ${aggWhereClause}
        GROUP BY period, cal_month
        ORDER BY period
      `, values),

      // 3. Pivot (by territory, sku, or customer) (RECON-OWNER-03 filter applied)
      pool.query(`
        SELECT
          ${type === 'territory' ? `UPPER(territory)` :
            type === 'sku'       ? `UPPER(sku)` :
                                   `customer_name`}                     AS pivot_key,
          count(*)::bigint                                             AS rows,
          round(COALESCE(sum(revenue), 0)::numeric, 2)                 AS revenue,
          round(COALESCE(sum(qty), 0)::numeric, 2)                     AS cases
        FROM ${ENRICHED_VIEW}
        ${aggWhereClause}
        GROUP BY pivot_key
        ORDER BY revenue DESC NULLS LAST
        LIMIT 200
      `, values),

      // 4. Paginated transactions — B8 JC-234: project all 52 Access cols.
      // The first 22 columns retain the JF-15 contract for the existing UI;
      // the remaining 30 are appended so the CSV export (and any future grid
      // expansion) has access to the full Access CombinedData schema.
      pool.query(`
        SELECT
          upload_id,
          sale_date::text                                              AS transaction_date,
          cal_month,
          customer_name,
          territory,
          warehouse,
          channel,
          sku,
          sku_vintage,
          item_code,
          item_description,
          invoice_no,
          qty,
          round(revenue::numeric, 2)                                   AS revenue,
          round(net_revenue::numeric, 2)                               AS net_revenue,
          round(discount::numeric, 2)                                  AS discount,
          round(rebate::numeric, 2)                                    AS rebate,
          round(fee::numeric, 2)                                       AS fee,
          round(cogs::numeric, 2)                                      AS cogs,
          CASE
            WHEN net_revenue > 0
              THEN round(((net_revenue - cogs) / net_revenue * 100)::numeric, 1)::text
            ELSE ''
          END                                                          AS gp_pct,
          source_system,
          source_ref,
          -- B8 JC-234 52-col extension (Access CombinedData mirror) ───────────
          sn,
          customer_code,
          suburb,
          postcode,
          rep,
          territory_group,
          customer_group,
          cal_year,
          cal_month_num,
          period                                                       AS cal_year_month,
          range_name,
          qty_bottles,
          round(wholesale_value_ex::numeric, 2)                        AS wholesale_value_ex,
          round(average_case::numeric, 2)                              AS average_case,
          round(base_wholesale::numeric, 2)                            AS base_wholesale,
          round(transfer_cost::numeric, 2)                             AS transfer_cost,
          round(discount_percentage::numeric, 2)                       AS discount_percentage,
          round(rebate_rate::numeric, 2)                               AS rebate_rate,
          round(profit::numeric, 2)                                    AS profit,
          round(gp::numeric, 2)                                        AS gp,
          note,
          round(wsale_value::numeric, 2)                               AS wsale_value,
          sub_region,
          ownership,
          -- M18b (the owner 2026-05-14): per-customer ALM/DIR/ILG codes belong on
          -- canonical_customer (one customer = one row of codes), not denormalised
          -- onto every transaction. Dropped alm/dir/ilg_customer_code from this
          -- projection + the CSV header + formatRow below.
          round(net_dollar_per_case::numeric, 2)                       AS net_dollar_per_case,
          carton_x,
          round(calculated_profit::numeric, 2)                         AS calculated_profit,
          round(commission::numeric, 2)                                AS commission,
          round(netrevenue::numeric, 2)                                AS netrevenue,
          round(total_cogs::numeric, 2)                                AS total_cogs,
          round(average_case_1::numeric, 2)                            AS average_case_1,
          round(net_profit::numeric, 2)                                AS net_profit,
          round(wholesaler_fee::numeric, 2)                            AS wholesaler_fee,
          import_id
        FROM ${ENRICHED_VIEW}
        ${whereClause}
        ORDER BY period DESC, upload_id DESC
        LIMIT $${paramIdx} OFFSET $${paramIdx + 1}
      `, [...values, limit, offset]),

      // 5. Total count for pagination
      pool.query(`
        SELECT count(*)::bigint AS total FROM ${ENRICHED_VIEW} ${whereClause}
      `, values),

      // 6. Vintage breakdown (only when filtered by SKU) (RECON-OWNER-03 filter applied)
      (name && type === 'sku') ? pool.query(`
        SELECT
          COALESCE(vintage::text, 'NV')                                 AS vintage_hint,
          item_code,
          count(*)::bigint                                             AS rows,
          round(COALESCE(sum(revenue), 0)::numeric, 2)                 AS revenue,
          round(COALESCE(sum(qty), 0)::numeric, 2)                     AS cases
        FROM ${ENRICHED_VIEW}
        ${aggWhereClause}
        GROUP BY vintage, item_code
        ORDER BY revenue DESC NULLS LAST
      `, values) : Promise.resolve({ rows: [] }),

      // 7. JF-24: Distinct rep names for the dropdown filter.
      // Uses HAVING COUNT(*) > 0 per JF-24 requirement (hide reps with zero
      // transactions but keep $0-value transactions visible). Excludes blank/null
      // rep_name so the dropdown isn't polluted. This query ignores all filters
      // except the date range (or upload_id range) so the dropdown always shows
      // the full rep list for the selected period.
      (() => {
        const repConditions: string[] = [];
        const repValues: (string | number)[] = [];
        let rIdx = 1;
        if (hasUploadIdFilter) {
          repConditions.push(`upload_id >= $${rIdx}`); repValues.push(uploadIdMin as number); rIdx++;
          repConditions.push(`upload_id <= $${rIdx}`); repValues.push(uploadIdMax as number); rIdx++;
        } else {
          repConditions.push(`period >= $${rIdx}`); repValues.push(from); rIdx++;
          repConditions.push(`period <= $${rIdx}`); repValues.push(to); rIdx++;
        }
        const repWhere = repConditions.length > 0 ? `WHERE ${repConditions.join(' AND ')}` : '';
        return pool.query(`
          SELECT rep_name, COUNT(*)::bigint AS txn_count
          FROM ${ENRICHED_VIEW}
          ${repWhere}
            AND rep_name IS NOT NULL AND rep_name <> ''
          GROUP BY rep_name
          HAVING COUNT(*) > 0
          ORDER BY rep_name
        `, repValues);
      })(),
    ]);

    const summary = summaryResult.rows[0] || { total_rows: 0, total_revenue: 0, total_cases: 0 };
    const totalRows = parseInt(countResult.rows[0]?.total || '0');
    const totalCasesNum = parseFloat(summary.total_cases || '0');
    const totalRevenueNum = parseFloat(summary.total_revenue || '0');

    // CSV export — BUG-20: streamed via ReadableStream instead of building a
    // single giant string. The underlying query is still capped at CSV_MAX_ROWS
    // (50K) on this interactive path; anything larger returned 413 above.
    // Each chunk is ~500 rows encoded to a Uint8Array and enqueued; this keeps
    // the Node heap footprint bounded (no ~500MB String.join step that used
    // to OOM the process at 200K rows × ~10x growth).
    if (isCSV) {
      const csvRows = transactionsResult.rows;
      // B8 JC-234: 52-col CSV header set mirroring Access CombinedData.
      // Columns 1-22 retain the JF-15 contract; 23-52 are the new Access mirror.
      const headers = [
        'Upload ID', 'Date', 'Month', 'Customer', 'Territory', 'Warehouse', 'Channel',
        'SKU', 'SKU-Vintage', 'Item Code', 'Item Description', 'Invoice #',
        'Qty', 'Revenue', 'Net Revenue', 'Discount', 'Rebate', 'Fee', 'COGS', 'GP %',
        'Source', 'Source Ref',
        'SN', 'Customer Code', 'Suburb', 'Postcode', 'Rep', 'Territory Group',
        'Group', 'Cal Year', 'Cal Month #', 'Cal Year-Month', 'Range',
        'Qty Bottles', 'Wholesale Value Ex', 'Average Case', 'BaseWholesale',
        'Transfer Cost', 'Discount %', 'Rebate Rate', 'Profit', 'GP', 'Note',
        'WSale Value', 'SubRegion', 'Ownership',
        'Net $/Case', 'CartonX', 'Calculated Profit', 'Commission',
        'NetRevenue', 'Total COGS', 'Average Case 1', 'Net Profit',
        'Wholesaler Fee', 'Import ID',
      ];
      const escape = (v: unknown): string => {
        if (v === null || v === undefined) return '';
        const s = String(v);
        if (s.includes(',') || s.includes('"') || s.includes('\n') || s.includes('\r')) {
          return '"' + s.replace(/"/g, '""') + '"';
        }
        return s;
      };
      const formatRow = (r: Record<string, unknown>): string => [
        r.upload_id,
        r.transaction_date,
        r.cal_month,
        r.customer_name,
        r.territory,
        r.warehouse,
        r.channel,
        r.sku,
        r.sku_vintage,
        r.item_code,
        r.item_description,
        r.invoice_no,
        r.qty,
        r.revenue,
        r.net_revenue,
        r.discount,
        r.rebate,
        r.fee,
        r.cogs,
        r.gp_pct,
        r.source_system,
        r.source_ref,
        // B8 JC-234 52-col extension
        r.sn,
        r.customer_code,
        r.suburb,
        r.postcode,
        r.rep,
        r.territory_group,
        r.customer_group,
        r.cal_year,
        r.cal_month_num,
        r.cal_year_month,
        r.range_name,
        r.qty_bottles,
        r.wholesale_value_ex,
        r.average_case,
        r.base_wholesale,
        r.transfer_cost,
        r.discount_percentage,
        r.rebate_rate,
        r.profit,
        r.gp,
        r.note,
        r.wsale_value,
        r.sub_region,
        r.ownership,
        r.net_dollar_per_case,
        r.carton_x,
        r.calculated_profit,
        r.commission,
        r.netrevenue,
        r.total_cogs,
        r.average_case_1,
        r.net_profit,
        r.wholesaler_fee,
        r.import_id,
      ].map(escape).join(',');

      const CHUNK_ROWS = 500;
      const encoder = new TextEncoder();

      const stream = new ReadableStream<Uint8Array>({
        start(controller) {
          try {
            // Emit the header row first.
            controller.enqueue(encoder.encode(headers.join(',') + '\n'));

            // Emit rows in CHUNK_ROWS batches so we never materialize the
            // whole CSV as a single string.
            let buffer: string[] = [];
            for (let i = 0; i < csvRows.length; i++) {
              buffer.push(formatRow(csvRows[i] as Record<string, unknown>));
              if (buffer.length >= CHUNK_ROWS) {
                controller.enqueue(encoder.encode(buffer.join('\n') + '\n'));
                buffer = [];
              }
            }
            if (buffer.length > 0) {
              // Final chunk — no trailing newline so the file doesn't end with
              // a blank line. (Matches the previous join('\n') behaviour.)
              controller.enqueue(encoder.encode(buffer.join('\n')));
            }
            controller.close();
          } catch (err) {
            controller.error(err);
          }
        },
      });

      return new Response(stream, {
        headers: {
          'Content-Type': 'text/csv; charset=utf-8',
          'Content-Disposition': `attachment; filename="combined-data-export-${new Date().toISOString().slice(0, 10)}.csv"`,
          'Cache-Control': 'no-store',
        },
      });
    }

    return NextResponse.json({
      summary: {
        total_rows: parseInt(summary.total_rows || '0'),
        total_revenue: totalRevenueNum,
        total_cases: totalCasesNum,
        avg_per_case: totalCasesNum > 0
          ? Math.round((totalRevenueNum / totalCasesNum) * 100) / 100
          : 0,
      },
      monthly: monthlyResult.rows.map(r => ({
        month_key: r.month_key,
        cal_month: r.cal_month,
        rows: parseInt(r.rows),
        revenue: parseFloat(r.revenue),
        cases: parseFloat(r.cases),
      })),
      pivot: pivotResult.rows.map(r => ({
        name: r.pivot_key,
        rows: parseInt(r.rows),
        revenue: parseFloat(r.revenue),
        cases: parseFloat(r.cases),
      })),
      transactions: {
        data: transactionsResult.rows,
        total: totalRows,
        page,
        pages: Math.ceil(totalRows / limit),
        limit,
      },
      vintages: vintageResult.rows.map(r => ({
        item_code: r.item_code,
        vintage: r.vintage_hint,
        rows: parseInt(r.rows),
        revenue: parseFloat(r.revenue),
        cases: parseFloat(r.cases),
      })),
      // JF-24: distinct reps for the dropdown (only those with >=1 transaction)
      reps: repsResult.rows.map(r => r.rep_name as string),
    });
  } catch (error) {
    console.error('Legacy data API error:', error);
    return NextResponse.json(
      { error: 'Failed to fetch legacy data', details: String(error) },
      { status: 500 }
    );
  }
}
