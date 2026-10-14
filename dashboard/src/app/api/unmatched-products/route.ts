export const dynamic = 'force-dynamic';

import { NextResponse } from 'next/server';
import getPool from '@/lib/db';

// BUG-81: dead-letter visibility surface for DWS/ALM uploads where the SKU
// lookup (sku_code_map → sku.sku_code → fuzzy-on-description) all fail and
// the row is inserted with sku_id=NULL. Read-only. No auto-linking — the owner
// reviews the list and uses the upload wizard's map-to-existing flow to
// resolve each code manually. Zero destructive writes.
//
// Data sources:
//   1. `etl_dead_letter` rows logged by `etl.import_dws._prepare_row` when
//      `_lookup_sku` returns None. Error message format is pinned in
//      `etl/import_dws.py:611-614`:
//        "Row {N}: unrecognised {CHANNEL} SKU code '{CODE}' — row inserted with sku_id=NULL."
//      Regex-extracted per row so we can group by CODE and count occurrences.
//   2. Current `sales_transaction` rows where sku_id IS NULL — the live
//      orphan pool. We surface a summary count + most-recent samples so the owner
//      can see the backlog at a glance even if older dead-letter rows have
//      been pruned.

interface UnmatchedCode {
  external_code: string;
  source: string;
  occurrences: number;
  first_seen: string | null;
  last_seen: string | null;
  sample_error: string;
}

interface OrphanSample {
  transaction_id: number;
  source_system: string;
  sale_date: string;
  customer_name: string | null;
  quantity: number;
  net_revenue: number | null;
  source_ref: string | null;
}

export async function GET() {
  try {
    const pool = getPool();

    // 1. Aggregate SKU-miss dead-letter entries — regex-extract the code from
    //    the error_message (format pinned in import_dws.py:611-614).
    const deadLetterResult = await pool.query(
      `SELECT
         source,
         (regexp_match(error_message, 'SKU code ''([^'']+)'''))[1] AS external_code,
         COUNT(*) AS occurrences,
         MIN(created_at) AS first_seen,
         MAX(created_at) AS last_seen,
         (array_agg(error_message ORDER BY created_at DESC))[1] AS sample_error
       FROM etl_dead_letter
       WHERE error_message ILIKE '%unrecognised%SKU code%'
         AND error_message ~ 'SKU code ''[^'']+'''
       GROUP BY source, (regexp_match(error_message, 'SKU code ''([^'']+)'''))[1]
       ORDER BY MAX(created_at) DESC, COUNT(*) DESC
       LIMIT 500`
    );

    const unmatched_codes: UnmatchedCode[] = deadLetterResult.rows.map((r) => ({
      external_code: r.external_code,
      source: r.source,
      occurrences: parseInt(r.occurrences, 10),
      first_seen: r.first_seen ? new Date(r.first_seen).toISOString() : null,
      last_seen: r.last_seen ? new Date(r.last_seen).toISOString() : null,
      sample_error: r.sample_error,
    }));

    // 2. Summary of live orphan sales_transaction rows (sku_id IS NULL).
    const orphanSummaryResult = await pool.query(
      `SELECT source_system,
              COUNT(*)::int AS orphan_count,
              MIN(sale_date) AS first_sale,
              MAX(sale_date) AS last_sale
       FROM sales_transaction
       WHERE sku_id IS NULL
       GROUP BY source_system
       ORDER BY source_system`
    );

    // 3. Most-recent orphan samples (50) with customer name for the owner to eyeball.
    const orphanSamplesResult = await pool.query(
      `SELECT st.transaction_id,
              st.source_system,
              st.sale_date,
              c.customer_name,
              st.quantity,
              st.net_revenue,
              st.source_ref
       FROM sales_transaction st
       LEFT JOIN customer c ON c.customer_id = st.customer_id
       WHERE st.sku_id IS NULL
       ORDER BY st.sale_date DESC, st.transaction_id DESC
       LIMIT 50`
    );

    const orphan_samples: OrphanSample[] = orphanSamplesResult.rows.map((r) => ({
      transaction_id: r.transaction_id,
      source_system: r.source_system || '',
      sale_date: r.sale_date ? new Date(r.sale_date).toISOString().slice(0, 10) : '',
      customer_name: r.customer_name || null,
      quantity: parseFloat(r.quantity) || 0,
      net_revenue: r.net_revenue !== null ? parseFloat(r.net_revenue) : null,
      source_ref: r.source_ref,
    }));

    return NextResponse.json({
      unmatched_codes,
      orphan_summary: orphanSummaryResult.rows.map((r) => ({
        source_system: r.source_system || '',
        orphan_count: r.orphan_count,
        first_sale: r.first_sale
          ? new Date(r.first_sale).toISOString().slice(0, 10)
          : null,
        last_sale: r.last_sale
          ? new Date(r.last_sale).toISOString().slice(0, 10)
          : null,
      })),
      orphan_samples,
      total_unmatched_codes: unmatched_codes.length,
      total_orphan_rows: orphanSummaryResult.rows.reduce(
        (sum, r) => sum + (r.orphan_count || 0),
        0
      ),
    });
  } catch (err) {
    console.error('[/api/unmatched-products] GET error:', err);
    return NextResponse.json(
      { error: 'Failed to load unmatched-products data' },
      { status: 500 }
    );
  }
}
