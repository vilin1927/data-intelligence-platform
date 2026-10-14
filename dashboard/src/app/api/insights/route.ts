export const dynamic = 'force-dynamic';

import { NextRequest, NextResponse } from 'next/server';
import getPool from '@/lib/db';

/**
 * GET /api/insights?query=<query_name>
 *
 * Business Insights API — returns cross-source analytics from the
 * sales_transaction fact table joined with dimension tables.
 *
 * Supported queries:
 *   - revenue_by_channel    Revenue by Channel (5yr)
 *   - top_customers         Top 10 Customers by Revenue
 *   - monthly_trend         Monthly Sales Trend (last 12 months)
 *   - top_wines_revenue     Top Wines by Revenue (top 10)
 *   - territory_performance Territory Performance
 *   - code_mapping_coverage SKU Code Mapping Coverage
 */

const QUERIES: Record<string, string> = {
  // 1. Revenue by Channel (5yr) — all-time revenue grouped by channel
  revenue_by_channel: `
    SELECT
      COALESCE(c.channel_name, 'Unknown') AS channel_name,
      COALESCE(c.commercial_model, 'unknown') AS commercial_model,
      SUM(COALESCE(st.net_revenue, 0)) AS total_revenue,
      COUNT(st.transaction_id) AS transaction_count
    FROM sales_transaction_normalized st
    LEFT JOIN channel c ON c.channel_id = st.channel_id
    WHERE st.quantity > 0
    GROUP BY c.channel_name, c.commercial_model
    ORDER BY total_revenue DESC
  `,

  // 2. Top 10 Customers by Revenue
  top_customers: `
    SELECT
      COALESCE(cu.customer_name, 'Unknown') AS customer_name,
      COALESCE(ch.channel_name, 'Unknown') AS channel_name,
      SUM(COALESCE(st.net_revenue, 0)) AS total_revenue,
      COUNT(st.transaction_id) AS transaction_count
    FROM sales_transaction_normalized st
    LEFT JOIN customer cu ON cu.customer_id = st.customer_id
    LEFT JOIN channel ch ON ch.channel_id = st.channel_id
    WHERE st.quantity > 0
    GROUP BY cu.customer_name, ch.channel_name
    ORDER BY total_revenue DESC
    LIMIT 10
  `,

  // 3. Monthly Sales Trend — last 12 months
  monthly_trend: `
    SELECT
      st.period,
      SUM(COALESCE(st.net_revenue, 0)) AS total_revenue,
      COUNT(st.transaction_id) AS transaction_count
    FROM sales_transaction_normalized st
    WHERE st.period >= TO_CHAR(NOW() - INTERVAL '12 months', 'YYYY-MM')
      AND st.quantity > 0
    GROUP BY st.period
    ORDER BY st.period ASC
  `,

  // 4. Top Wines by Revenue (top 10 SKUs)
  top_wines_revenue: `
    SELECT
      COALESCE(s.sku_code, 'Unknown') AS sku_code,
      COALESCE(s.item_description, 'No description') AS item_description,
      COALESCE(s.variety, 'Unknown') AS variety,
      s.vintage,
      SUM(COALESCE(st.net_revenue, 0)) AS total_revenue,
      SUM(COALESCE(st.quantity_cases, 0)) AS total_quantity
    FROM sales_transaction_normalized st
    LEFT JOIN sku s ON s.sku_id = st.sku_id
    WHERE st.quantity > 0
    GROUP BY s.sku_code, s.item_description, s.variety, s.vintage
    ORDER BY total_revenue DESC
    LIMIT 10
  `,

  // 5. Territory Performance
  territory_performance: `
    SELECT
      COALESCE(t.territory_name, 'Unknown') AS territory_name,
      COALESCE(t.state, 'Unknown') AS state,
      SUM(COALESCE(st.net_revenue, 0)) AS total_revenue,
      COUNT(st.transaction_id) AS transaction_count
    FROM sales_transaction_normalized st
    LEFT JOIN territory t ON t.territory_id = st.territory_id
    WHERE st.quantity > 0
    GROUP BY t.territory_name, t.state
    ORDER BY total_revenue DESC
  `,

  // 6. SKU Code Mapping Coverage
  code_mapping_coverage: `
    SELECT
      COUNT(s.sku_id) AS total_skus,
      COUNT(DISTINCT scm.sku_id) AS mapped_skus,
      COUNT(s.sku_id) - COUNT(DISTINCT scm.sku_id) AS unmapped_skus,
      CASE
        WHEN COUNT(s.sku_id) = 0 THEN 0
        ELSE ROUND(
          (COUNT(DISTINCT scm.sku_id)::DECIMAL / COUNT(s.sku_id)) * 100,
          1
        )
      END AS coverage_percent
    FROM sku s
    LEFT JOIN sku_code_map scm ON scm.sku_id = s.sku_id
  `,
};

const VALID_QUERIES = Object.keys(QUERIES);

export async function GET(request: NextRequest) {
  const queryName = request.nextUrl.searchParams.get('query');

  if (!queryName || !VALID_QUERIES.includes(queryName)) {
    return NextResponse.json(
      {
        error: `Invalid or missing query parameter. Must be one of: ${VALID_QUERIES.join(', ')}`,
      },
      { status: 400 }
    );
  }

  try {
    const pool = getPool();
    const sql = QUERIES[queryName];
    const result = await pool.query(sql);

    // Return structured format: { columns, rows, queryName }
    const columns = result.fields.map((f: { name: string }) => f.name);
    const rows = result.rows.map((row: Record<string, unknown>) =>
      columns.map((col: string) => row[col] ?? null)
    );

    return NextResponse.json({ columns, rows, queryName });
  } catch (err) {
    console.error(`[/api/insights] Error running query "${queryName}":`, err);
    return NextResponse.json(
      { error: `Failed to execute insight query: ${queryName}` },
      { status: 500 }
    );
  }
}
