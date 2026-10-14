export const dynamic = 'force-dynamic';

import { NextResponse } from 'next/server';
import getPool from '@/lib/db';

/**
 * GET /api/wines/vintage-breakdown?sku_id=N
 *
 * B13-wp-polish — supports the Wine Profile polish (Phase 1 close-out):
 *   - next_vintage:  string|null — the next-vintage-to-bottle for the SKU's
 *                    canonical_sku group. Currently always null because the
 *                    canonical_sku.next_vintage column does NOT exist in the
 *                    schema. Returning null is the agreed default; a
 *                    post-delivery clarification asks the owner whether to add
 *                    the column (and where the data comes from). Do NOT
 *                    ALTER TABLE here — schema changes are out of bundle
 *                    scope per AC4.
 *   - breakdown:     [{ vintage_label, cases_sold, revenue }] — past-13-months
 *                    sales aggregate for every vintage of the same canonical
 *                    SKU, sorted vintage desc. NV (vintage IS NULL or 0) is
 *                    bucketed under "NV".
 *
 * The Wine Profile already aggregates similar data (sales_by_month, channel
 * breakdown). The new vintage breakdown is the same idea grouped on
 * sku.vintage instead of channel/month.
 */
export async function GET(request: Request) {
  try {
    const { searchParams } = new URL(request.url);
    const skuIdParam = searchParams.get('sku_id');

    if (!skuIdParam || !/^\d+$/.test(skuIdParam)) {
      return NextResponse.json({ error: 'sku_id must be a positive integer' }, { status: 400 });
    }
    const skuId = parseInt(skuIdParam);
    const pool = getPool();

    // 1. canonical_sku_id for the requested SKU. We aggregate the breakdown
    //    over the same canonical group (so vintage rows for the same wine
    //    across different warehouses / SKU codes roll up correctly).
    const canonicalLookup = await pool.query(
      `
      SELECT s.canonical_sku_id, cs.sku_name AS canonical_sku_name
      FROM sku s
      LEFT JOIN canonical_sku cs ON cs.id = s.canonical_sku_id
      WHERE s.sku_id = $1
      `,
      [skuId],
    );

    if (canonicalLookup.rows.length === 0) {
      return NextResponse.json({ error: 'SKU not found' }, { status: 404 });
    }

    const canonicalSkuId: number | null = canonicalLookup.rows[0].canonical_sku_id;

    // 2. next_vintage — column does not yet exist on canonical_sku; return null.
    //    See post-delivery-clarifications.md for the open question with the owner.
    const nextVintage: string | null = null;

    // 3. Vintage breakdown — past 13 months of sales for every SKU in the
    //    same canonical group. If the SKU has no canonical_sku_id, fall back
    //    to the SKU itself so the table at least shows the wine's own row.
    const breakdownResult = canonicalSkuId
      ? await pool.query(
          `
          SELECT
            CASE
              WHEN s.vintage IS NULL OR s.vintage = 0 THEN 'NV'
              ELSE s.vintage::text
            END AS vintage_label,
            COALESCE(s.vintage, 0) AS vintage_sort,
            COALESCE(SUM(st.quantity_cases), 0)::numeric(12,1) AS cases_sold,
            COALESCE(SUM(st.net_revenue), 0)::numeric(12,2) AS revenue
          FROM sales_transaction_normalized st
          JOIN sku s ON s.sku_id = st.sku_id
          WHERE s.canonical_sku_id = $1
            AND st.sale_date >= CURRENT_DATE - interval '13 months'
            AND st.quantity > 0
          GROUP BY vintage_label, vintage_sort
          ORDER BY vintage_sort DESC NULLS LAST, vintage_label DESC
          `,
          [canonicalSkuId],
        )
      : await pool.query(
          `
          SELECT
            CASE
              WHEN s.vintage IS NULL OR s.vintage = 0 THEN 'NV'
              ELSE s.vintage::text
            END AS vintage_label,
            COALESCE(s.vintage, 0) AS vintage_sort,
            COALESCE(SUM(st.quantity_cases), 0)::numeric(12,1) AS cases_sold,
            COALESCE(SUM(st.net_revenue), 0)::numeric(12,2) AS revenue
          FROM sales_transaction_normalized st
          JOIN sku s ON s.sku_id = st.sku_id
          WHERE s.sku_id = $1
            AND st.sale_date >= CURRENT_DATE - interval '13 months'
            AND st.quantity > 0
          GROUP BY vintage_label, vintage_sort
          ORDER BY vintage_sort DESC NULLS LAST, vintage_label DESC
          `,
          [skuId],
        );

    return NextResponse.json({
      next_vintage: nextVintage,
      breakdown: breakdownResult.rows.map((r) => ({
        vintage_label: r.vintage_label,
        cases_sold: parseFloat(r.cases_sold),
        revenue: parseFloat(r.revenue),
      })),
    });
  } catch (err) {
    console.error('[/api/wines/vintage-breakdown] Error:', err);
    return NextResponse.json({ error: 'Failed to load vintage breakdown' }, { status: 500 });
  }
}
