export const dynamic = 'force-dynamic';

import { NextResponse } from 'next/server';
import getPool from '@/lib/db';

/**
 * GET /api/overview
 * Returns KPIs, revenue by channel (13 months), and top wines for the Overview Dashboard.
 */
export async function GET() {
  try {
    const pool = getPool();

    // Run all queries in parallel
    const [kpis, revenueByChannel, topWines, alerts] = await Promise.all([
      // 1. KPI Metrics
      pool.query(`
        SELECT
          -- M3-06: Default to previous complete month (current month data arrives mid following month)
          (SELECT COALESCE(SUM(net_revenue), 0) FROM sales_transaction_normalized
           WHERE sale_date >= date_trunc('month', CURRENT_DATE - interval '1 month')
             AND sale_date < date_trunc('month', CURRENT_DATE)
             AND quantity > 0)::numeric(12,2) as revenue_mtd,

          (SELECT COALESCE(SUM(net_revenue), 0) FROM sales_transaction_normalized
           WHERE sale_date >= date_trunc('month', CURRENT_DATE - interval '2 months')
             AND sale_date < date_trunc('month', CURRENT_DATE - interval '1 month')
             AND quantity > 0)::numeric(12,2) as revenue_prev_month,

          -- Gross Profit for previous complete month
          (SELECT COALESCE(SUM(st.net_revenue), 0) - COALESCE(SUM(
            COALESCE(st.economic_cogs_total, st.quantity * COALESCE(sk.transfer_cost, 0))
          ), 0) FROM sales_transaction_normalized st
           LEFT JOIN sku sk ON sk.sku_id = st.sku_id
           WHERE st.sale_date >= date_trunc('month', CURRENT_DATE - interval '1 month')
             AND st.sale_date < date_trunc('month', CURRENT_DATE)
             AND st.quantity > 0)::numeric(12,2) as gross_profit_mtd,

          (SELECT COUNT(DISTINCT sku_id) FROM sales_transaction_normalized
           WHERE sale_date >= CURRENT_DATE - interval '90 days'
             AND quantity > 0) as active_skus,

          -- JR-039: exclude the 37 legacy/discontinued bridge rows (is_active_canonical=false)
          -- so total_skus reports the owner's 99 active canonicals, not the 136 that include ETL dead-letter bridges.
          (SELECT COUNT(*) FROM canonical_sku WHERE is_active_canonical = TRUE) as total_skus,

          -- Inventory Value: catalog wholesale value (no stock-on-hand table exists yet)
          (SELECT COALESCE(SUM(
            CASE WHEN units_per_case > 0
              THEN base_wholesale * units_per_case
              ELSE base_wholesale
            END
          ), 0) FROM sku
           WHERE base_wholesale > 0)::numeric(12,2) as inventory_value_estimate
      `),

      // 2. Revenue by Warehouse — 13 months ending at previous complete month (M3-06)
      // `monthly` is keyed (month, warehouse). Both cur and yoy joined to m on month
      // alone → cur rows × yoy rows = N×M cross product per month, multiplying every
      // cur.rev by COUNT(DISTINCT warehouse) in the YOY month. Fix (Option A from
      // one row per month in `monthly_total`, join yoy to that. cur stays per-warehouse
      // so the CASE-WHEN breakdowns still work; yoy is now scalar per month.
      pool.query(`
        WITH monthly AS (
          SELECT
            date_trunc('month', sale_date)::date as month,
            warehouse,
            SUM(net_revenue) as rev
          FROM sales_transaction_normalized
          WHERE sale_date >= date_trunc('month', CURRENT_DATE - interval '25 months')
            AND sale_date < date_trunc('month', CURRENT_DATE)
            AND quantity > 0
          GROUP BY 1, 2
        ),
        monthly_total AS (
          SELECT month, SUM(rev) AS rev FROM monthly GROUP BY month
        ),
        months AS (
          SELECT generate_series(
            date_trunc('month', CURRENT_DATE - interval '13 months'),
            date_trunc('month', CURRENT_DATE - interval '1 month'),
            '1 month'
          )::date as month
        )
        SELECT
          to_char(m.month, 'Mon YY') as month,
          COALESCE(SUM(CASE WHEN cur.warehouse = 'DWS' THEN cur.rev END), 0)::numeric(10,2) as dws,
          COALESCE(SUM(CASE WHEN cur.warehouse IN ('ALM', 'ILG') THEN cur.rev END), 0)::numeric(10,2) as alm,
          COALESCE(SUM(CASE WHEN cur.warehouse = 'Direct' THEN cur.rev END), 0)::numeric(10,2) as direct,
          COALESCE(MAX(yoy.rev), 0)::numeric(10,2) as yoy_total
        FROM months m
        LEFT JOIN monthly cur ON cur.month = m.month
        LEFT JOIN monthly_total yoy ON yoy.month = (m.month - interval '12 months')::date
        GROUP BY m.month
        ORDER BY m.month
      `),

      // 3. Top 5 Wines by Revenue (GP% uses sku_cogs or sku.transfer_cost)
      // BUG-163 F1b: canonical-shadow `sku` rows (sku_id 1-99) carry
      // descriptive text in `sku_code` by architectural design (matches
      // canonical_sku.sku_name). Substitute the latest non-cancelled
      // MV-prefix Vinsight code from canonical_sku_code_map so Top-Wines
      // displays a real SKU code (e.g. MVLKPINB25). Falls back to
      // s.sku_code if no MV-prefix vinsight code exists for the canonical.
      pool.query(`
        SELECT
          COALESCE(
            (SELECT external_code
               FROM canonical_sku_code_map
              WHERE canonical_sku_id = s.canonical_sku_id
                AND source_system = 'vinsight'
                AND external_code ~ '^MV'
                AND external_code NOT LIKE 'X-%'
              ORDER BY substring(external_code FROM '[0-9]{2}$')::int DESC NULLS LAST,
                       external_code ASC
              LIMIT 1),
            s.sku_code
          ) AS sku_code,
          s.item_description,
          s.variety,
          COALESCE(mro.region, s.region) AS region,
          SUM(st.net_revenue)::numeric(10,2) as total_revenue,
          SUM(st.quantity_cases)::numeric(10,1) as total_qty,
          CASE WHEN SUM(st.net_revenue) > 0
            THEN ROUND(((SUM(st.net_revenue) - COALESCE(SUM(
              COALESCE(st.economic_cogs_total, st.quantity * COALESCE(s.transfer_cost, 0))
            ), 0)) / SUM(st.net_revenue) * 100)::numeric, 1)
            ELSE 0
          END as gp_pct
        FROM sales_transaction_normalized st
        JOIN sku s ON s.sku_id = st.sku_id
        LEFT JOIN manual_region_override mro ON mro.sku_id = s.sku_id
        WHERE st.sale_date >= CURRENT_DATE - interval '12 months'
          AND st.quantity > 0
        GROUP BY s.sku_id, s.canonical_sku_id, s.sku_code, s.item_description, s.variety, COALESCE(mro.region, s.region)
        ORDER BY total_revenue DESC
        LIMIT 5
      `),

      // 4. Alerts — low stock + sync status
      pool.query(`
        SELECT
          (SELECT COUNT(*) FROM etl_run_log
           WHERE status = 'error' AND started_at >= CURRENT_DATE - interval '24 hours') as recent_errors,
          (SELECT MAX(started_at) FROM etl_run_log) as last_sync,
          (SELECT COUNT(*) FROM etl_dead_letter
           WHERE created_at >= CURRENT_DATE - interval '7 days') as recent_dead_letters
      `),
    ]);

    // Calculate revenue trend
    // FIX-15: When MTD is 0, return null (no data yet) instead of misleading -100%
    const revenueMtd = parseFloat(kpis.rows[0].revenue_mtd);
    const revenuePrev = parseFloat(kpis.rows[0].revenue_prev_month);
    const revenueTrend = revenueMtd === 0
      ? null  // No sales data yet this month
      : revenuePrev > 0
        ? ((revenueMtd - revenuePrev) / revenuePrev * 100)
        : null;

    return NextResponse.json({
      kpis: {
        revenue_mtd: revenueMtd,
        revenue_trend: revenueTrend !== null ? Math.round(revenueTrend * 10) / 10 : null,
        gross_profit_mtd: parseFloat(kpis.rows[0].gross_profit_mtd),
        active_skus: parseInt(kpis.rows[0].active_skus),
        total_skus: parseInt(kpis.rows[0].total_skus),
        inventory_value: parseFloat(kpis.rows[0].inventory_value_estimate),
      },
      revenue_by_channel: revenueByChannel.rows,
      top_wines: topWines.rows,
      alerts: {
        recent_errors: parseInt(alerts.rows[0].recent_errors),
        last_sync: alerts.rows[0].last_sync,
        recent_dead_letters: parseInt(alerts.rows[0].recent_dead_letters),
      },
    });
  } catch (err) {
    console.error('[/api/overview] Error:', err);
    return NextResponse.json(
      { error: 'Failed to load overview data' },
      { status: 500 }
    );
  }
}
