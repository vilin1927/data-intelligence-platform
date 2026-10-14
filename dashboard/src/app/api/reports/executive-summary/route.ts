export const dynamic = 'force-dynamic';

import { NextRequest, NextResponse } from 'next/server';
import getPool from '@/lib/db';

/**
 * GET /api/reports/executive-summary?month=YYYY-MM
 *
 * JC-332/JC-367: 1-click "Executive Summary" — returns the headline numbers
 * for the as-at month: revenue, GP, MAT, MMT, YOY, top wines, alerts.
 *
 * Defaults to previous complete calendar month when ?month is omitted (JC-337).
 * Read-only — no writes.
 */

const YEAR_MONTH_RE = /^\d{4}-(0[1-9]|1[0-2])$/;

function previousCompleteMonth(today: Date = new Date()): string {
  const d = new Date(today.getFullYear(), today.getMonth() - 1, 1);
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}`;
}

export async function GET(request: NextRequest) {
  try {
    const monthParam = request.nextUrl.searchParams.get('month');
    const month = monthParam && YEAR_MONTH_RE.test(monthParam) ? monthParam : previousCompleteMonth();
    const monthStart = `${month}-01`;

    const pool = getPool();

    const [
      headline,
      mat,
      yoy,
      topWines,
      alerts,
      activeCustomers,
    ] = await Promise.all([
      // Revenue + GP for the as-at month + previous month (for MMT)
      pool.query(
        `SELECT
           date_trunc('month', sale_date)::date AS month,
           SUM(net_revenue)::numeric(14,2) AS revenue,
           SUM(quantity)::int AS cases,
           SUM(net_revenue) - SUM(
             COALESCE(st.economic_cogs_total, st.quantity * COALESCE(sk.transfer_cost, 0))
           ) ::numeric(14,2) AS gross_profit
         FROM sales_transaction st
         LEFT JOIN sku sk ON sk.sku_id = st.sku_id
         WHERE st.quantity > 0
           AND st.sale_date >= ($1::date - interval '1 month')
           AND st.sale_date <  ($1::date + interval '1 month')
         GROUP BY 1
         ORDER BY 1`,
        [monthStart]
      ),

      // Moving Annual Total — 12 complete months ending at the as-at month
      pool.query(
        `SELECT
           SUM(net_revenue)::numeric(14,2) AS revenue,
           SUM(quantity)::int AS cases,
           SUM(net_revenue) - SUM(
             COALESCE(st.economic_cogs_total, st.quantity * COALESCE(sk.transfer_cost, 0))
           )::numeric(14,2) AS gross_profit
         FROM sales_transaction st
         LEFT JOIN sku sk ON sk.sku_id = st.sku_id
         WHERE st.quantity > 0
           AND st.sale_date >= ($1::date - interval '11 months')
           AND st.sale_date <  ($1::date + interval '1 month')`,
        [monthStart]
      ),

      // Same month one year ago (for YOY)
      pool.query(
        `SELECT
           SUM(net_revenue)::numeric(14,2) AS revenue,
           SUM(quantity)::int AS cases
         FROM sales_transaction
         WHERE quantity > 0
           AND sale_date >= ($1::date - interval '1 year')
           AND sale_date <  ($1::date - interval '1 year' + interval '1 month')`,
        [monthStart]
      ),

      // Top 5 wines by revenue in the 12 months ending at the as-at month
      pool.query(
        `SELECT
           sk.sku_code,
           sk.item_description,
           sk.variety,
           sk.region,
           SUM(st.net_revenue)::numeric(14,2) AS revenue,
           SUM(st.quantity)::int AS cases
         FROM sales_transaction st
         JOIN sku sk ON sk.sku_id = st.sku_id
         WHERE st.quantity > 0
           AND st.sale_date >= ($1::date - interval '11 months')
           AND st.sale_date <  ($1::date + interval '1 month')
         GROUP BY sk.sku_code, sk.item_description, sk.variety, sk.region
         ORDER BY revenue DESC
         LIMIT 5`,
        [monthStart]
      ),

      // Alerts: ETL errors in last 24h + dead-letter rows.
      // B10a fix 2026-04-28: prod tables are etl_run_log + etl_dead_letter (not etl_run / dead_letter_queue).
      pool.query(
        `SELECT
           (SELECT COUNT(*) FROM etl_run_log WHERE status = 'error'
              AND started_at >= NOW() - interval '24 hours')::int AS recent_errors,
           (SELECT COUNT(*) FROM etl_dead_letter
              WHERE created_at >= NOW() - interval '24 hours')::int AS recent_dead_letters,
           (SELECT MAX(started_at) FROM etl_run_log WHERE status = 'success') AS last_sync`
      ),

      // Active distinct customers in the 12 months ending at the as-at month
      pool.query(
        `SELECT COUNT(DISTINCT customer_id)::int AS active_customers
         FROM sales_transaction
         WHERE quantity > 0
           AND sale_date >= ($1::date - interval '11 months')
           AND sale_date <  ($1::date + interval '1 month')`,
        [monthStart]
      ),
    ]);

    const headlineRows = headline.rows;
    const asAt = headlineRows.find((r) => r.month && r.month.toISOString().slice(0, 7) === month) || null;
    const prev = headlineRows.find((r) => r.month && r.month.toISOString().slice(0, 7) !== month) || null;

    const num = (v: unknown): number => {
      if (v === null || v === undefined) return 0;
      const n = typeof v === 'number' ? v : parseFloat(String(v));
      return Number.isFinite(n) ? n : 0;
    };

    const revenue = num(asAt?.revenue);
    const grossProfit = num(asAt?.gross_profit);
    const cases = num(asAt?.cases);
    const prevRevenue = num(prev?.revenue);
    const prevGp = num(prev?.gross_profit);
    const matRevenue = num(mat.rows[0]?.revenue);
    const matGp = num(mat.rows[0]?.gross_profit);
    const matCases = num(mat.rows[0]?.cases);
    const yoyRevenue = num(yoy.rows[0]?.revenue);

    const mmtPct = prevRevenue > 0 ? ((revenue - prevRevenue) / prevRevenue) * 100 : null;
    const yoyPct = yoyRevenue > 0 ? ((revenue - yoyRevenue) / yoyRevenue) * 100 : null;
    const gpPct = revenue > 0 ? (grossProfit / revenue) * 100 : null;

    return NextResponse.json({
      month,
      generated_at: new Date().toISOString(),
      headline: {
        revenue,
        cases,
        gross_profit: grossProfit,
        gp_pct: gpPct,
        mmt_pct: mmtPct,
        yoy_pct: yoyPct,
        prev_month_revenue: prevRevenue,
        prev_month_gp: prevGp,
        yoy_revenue: yoyRevenue,
      },
      mat: {
        revenue: matRevenue,
        cases: matCases,
        gross_profit: matGp,
        gp_pct: matRevenue > 0 ? (matGp / matRevenue) * 100 : null,
      },
      active_customers: num(activeCustomers.rows[0]?.active_customers),
      top_wines: topWines.rows.map((r) => ({
        sku_code: r.sku_code,
        item_description: r.item_description,
        variety: r.variety,
        region: r.region,
        revenue: num(r.revenue),
        cases: num(r.cases),
      })),
      alerts: {
        recent_errors: num(alerts.rows[0]?.recent_errors),
        recent_dead_letters: num(alerts.rows[0]?.recent_dead_letters),
        last_sync: alerts.rows[0]?.last_sync ?? null,
      },
    });
  } catch (err) {
    console.error('[/api/reports/executive-summary] error', err);
    return NextResponse.json(
      { error: 'Failed to compute executive summary' },
      { status: 500 }
    );
  }
}
