export const dynamic = 'force-dynamic';

import { NextRequest, NextResponse } from 'next/server';
import getPool from '@/lib/db';

/**
 * GET /api/sales?period=6|12|24
 * Returns sales analytics data:
 * - 4 KPI metrics with YoY comparison
 * - 13-month revenue by channel (stacked bar + YOY line)
 * - Territory performance table
 * - Rep leaderboard (top 10)
 * - Top customers (top 10 with channel labels)
 * - Filter reference data
 */
export async function GET(request: NextRequest) {
  try {
    const pool = getPool();
    const periodParam = request.nextUrl.searchParams.get('period');
    const period = [6, 12, 24].includes(Number(periodParam)) ? Number(periodParam) : 12;
    const halfPeriod = Math.floor(period / 2);
    const chartMonths = period + 1; // 1 extra month for context
    // R-003: warehouse filter — null/empty/'all' means no filter; values are 'DWS' | 'ALM' | 'ILG' | 'Direct'
    const whParam = request.nextUrl.searchParams.get('warehouse');
    const warehouseFilter = whParam && whParam !== 'all' && whParam !== '' ? whParam : null;
    // JC-345-RPT (schema/122): suburb + territory_group via customer_suburb / customer_territory_group on view.
    const sbParam = request.nextUrl.searchParams.get('suburb');
    const suburbFilter = sbParam && sbParam !== 'all' && sbParam !== '' ? sbParam : null;
    const tgParam = request.nextUrl.searchParams.get('territory_group');
    const territoryGroupFilter = tgParam && tgParam !== 'all' && tgParam !== '' ? tgParam : null;

    const [
      kpiResult,
      kpiPriorYear,
      revenueByChannel,
      territoryPerf,
      repLeaderboard,
      topCustomers,
      filterData,
      distributionResult,
      customerActivityResult,
    ] = await Promise.all([
      // 1. KPIs — current period
      // R-002 (2026-04-30): align to month-aligned [date_trunc(month, today) - period, date_trunc(month, today))
      // so KPI sum equals chart-bar sum (chart is already month-aligned).
      // R-003: warehouse filter on $2 (null = all-warehouses).
      pool.query(`
        SELECT
          COALESCE(SUM(st.quantity_cases), 0)::numeric(12,1) as total_cases,
          COALESCE(SUM(st.net_revenue), 0)::numeric(12,2) as total_revenue,
          COUNT(DISTINCT st.customer_id) as active_customers,
          CASE WHEN COALESCE(SUM(st.quantity_cases), 0) > 0
            THEN ROUND((SUM(st.net_revenue) / SUM(st.quantity_cases))::numeric, 2)
            ELSE 0
          END as avg_wholesale_per_case
        FROM sales_transaction_normalized st
        WHERE st.sale_date >= date_trunc('month', CURRENT_DATE) - interval '1 month' * $1
          AND st.sale_date < date_trunc('month', CURRENT_DATE)
          AND st.quantity > 0
          AND (cast($2 AS text) IS NULL OR st.warehouse = $2)
          AND (cast($3 AS text) IS NULL OR st.customer_suburb = $3)
          AND (cast($4 AS text) IS NULL OR st.customer_territory_group = $4)
      `, [period, warehouseFilter, suburbFilter, territoryGroupFilter]),

      // 2. KPIs — prior period (for YoY)
      // R-002: same month-aligned shift as query 1, but offset by `period` months for YoY.
      // R-003: warehouse filter on $3.
      pool.query(`
        SELECT
          COALESCE(SUM(st.quantity_cases), 0)::numeric(12,1) as total_cases,
          COALESCE(SUM(st.net_revenue), 0)::numeric(12,2) as total_revenue,
          COUNT(DISTINCT st.customer_id) as active_customers,
          CASE WHEN COALESCE(SUM(st.quantity_cases), 0) > 0
            THEN ROUND((SUM(st.net_revenue) / SUM(st.quantity_cases))::numeric, 2)
            ELSE 0
          END as avg_wholesale_per_case
        FROM sales_transaction_normalized st
        WHERE st.sale_date >= date_trunc('month', CURRENT_DATE) - interval '1 month' * $1
          AND st.sale_date < date_trunc('month', CURRENT_DATE) - interval '1 month' * $2
          AND st.quantity > 0
          AND (cast($3 AS text) IS NULL OR st.warehouse = $3)
          AND (cast($4 AS text) IS NULL OR st.customer_suburb = $4)
          AND (cast($5 AS text) IS NULL OR st.customer_territory_group = $5)
      `, [period * 2, period, warehouseFilter, suburbFilter, territoryGroupFilter]),

      // 3. Revenue by warehouse — ending at previous complete month
      // by COUNT(DISTINCT warehouse) in the YOY month (= 4× in observed data) and
      // also inflated the `total` column by the same factor (and over-counted
      // NULL-warehouse rows in `total`). `monthly` is keyed (month, warehouse) — both
      // cur and yoy joined to m on month alone → N×M cross product per month. Fix
      // `monthly` to one row per month in `monthly_total`, join yoy to that, and
      // derive `total` from the same scalar so it's no longer inflated.
      pool.query(`
        WITH monthly AS (
          SELECT
            date_trunc('month', sale_date)::date as month,
            warehouse,
            SUM(net_revenue) as rev
          FROM sales_transaction_normalized
          WHERE sale_date >= date_trunc('month', CURRENT_DATE - interval '1 month' * $1)
            AND sale_date < date_trunc('month', CURRENT_DATE)
            AND quantity > 0
            AND (cast($3 AS text) IS NULL OR warehouse = $3)
            AND (cast($4 AS text) IS NULL OR customer_suburb = $4)
            AND (cast($5 AS text) IS NULL OR customer_territory_group = $5)
          GROUP BY 1, 2
        ),
        monthly_total AS (
          SELECT month, SUM(rev) AS rev FROM monthly GROUP BY month
        ),
        months AS (
          SELECT generate_series(
            date_trunc('month', CURRENT_DATE - interval '1 month' * $2),
            date_trunc('month', CURRENT_DATE - interval '1 month'),
            '1 month'
          )::date as month
        )
        SELECT
          to_char(m.month, 'Mon YY') as month,
          m.month as month_date,
          COALESCE(SUM(CASE WHEN cur.warehouse = 'DWS' THEN cur.rev END), 0)::numeric(10,2) as dws,
          COALESCE(SUM(CASE WHEN cur.warehouse IN ('ALM', 'ILG') THEN cur.rev END), 0)::numeric(10,2) as alm,
          COALESCE(SUM(CASE WHEN cur.warehouse = 'Direct' THEN cur.rev END), 0)::numeric(10,2) as direct,
          COALESCE(MAX(cur_total.rev), 0)::numeric(10,2) as total,
          COALESCE(MAX(yoy.rev), 0)::numeric(10,2) as yoy_total
        FROM months m
        LEFT JOIN monthly cur ON cur.month = m.month
        LEFT JOIN monthly_total cur_total ON cur_total.month = m.month
        LEFT JOIN monthly_total yoy ON yoy.month = (m.month - interval '12 months')::date
        GROUP BY m.month
        ORDER BY m.month
      `, [chartMonths + 12, chartMonths, warehouseFilter, suburbFilter, territoryGroupFilter]),

      // 4. Territory performance — cases, revenue, deductions, GP%, trend, MQT (M3-09 + M3-14)
      pool.query(`
        WITH current_period AS (
          SELECT
            COALESCE(t.territory_name, 'Unassigned') as territory,
            SUM(st.quantity_cases)::numeric(10,1) as cases,
            COALESCE(SUM(st.gross_revenue), SUM(st.quantity_cases * st.unit_price))::numeric(12,2) as gross_revenue,
            COALESCE(SUM(st.discount_amount), 0)::numeric(12,2) as total_discounts,
            COALESCE(SUM(st.rebate_amount), 0)::numeric(12,2) as total_rebates,
            COALESCE(SUM(st.wholesale_fee), 0)::numeric(12,2) as total_fees,
            SUM(st.net_revenue)::numeric(12,2) as revenue,
            CASE WHEN SUM(st.net_revenue) > 0
              THEN ROUND(((SUM(st.net_revenue) - COALESCE(SUM(
                COALESCE(st.economic_cogs_total, st.quantity_cases * COALESCE(sk.transfer_cost, 0))
              ), 0)) / SUM(st.net_revenue) * 100)::numeric, 1)
              ELSE 0
            END as gp_pct
          FROM sales_transaction_normalized st
          LEFT JOIN territory t ON t.territory_id = st.territory_id
          LEFT JOIN sku sk ON sk.sku_id = st.sku_id
          WHERE st.sale_date >= CURRENT_DATE - interval '1 month' * $1
            AND st.quantity > 0
            AND (cast($4 AS text) IS NULL OR st.warehouse = $4)
            AND (cast($5 AS text) IS NULL OR st.customer_suburb = $5)
            AND (cast($6 AS text) IS NULL OR st.customer_territory_group = $6)
          GROUP BY COALESCE(t.territory_name, 'Unassigned')
        ),
        prior_period AS (
          SELECT
            COALESCE(t.territory_name, 'Unassigned') as territory,
            SUM(st.net_revenue)::numeric(12,2) as revenue
          FROM sales_transaction_normalized st
          LEFT JOIN territory t ON t.territory_id = st.territory_id
          WHERE st.sale_date >= CURRENT_DATE - interval '1 month' * $2
            AND st.sale_date < CURRENT_DATE - interval '1 month' * $3
            AND st.quantity > 0
            AND (cast($4 AS text) IS NULL OR st.warehouse = $4)
            AND (cast($5 AS text) IS NULL OR st.customer_suburb = $5)
            AND (cast($6 AS text) IS NULL OR st.customer_territory_group = $6)
          GROUP BY COALESCE(t.territory_name, 'Unassigned')
        ),
        mqt_current AS (
          SELECT
            COALESCE(t.territory_name, 'Unassigned') as territory,
            COALESCE(SUM(st.net_revenue), 0)::numeric(12,2) as mqt_revenue
          FROM sales_transaction_normalized st
          LEFT JOIN territory t ON t.territory_id = st.territory_id
          WHERE st.sale_date >= date_trunc('month', CURRENT_DATE) - interval '3 months'
            AND st.sale_date < date_trunc('month', CURRENT_DATE)
            AND st.quantity > 0
            AND (cast($4 AS text) IS NULL OR st.warehouse = $4)
            AND (cast($5 AS text) IS NULL OR st.customer_suburb = $5)
            AND (cast($6 AS text) IS NULL OR st.customer_territory_group = $6)
          GROUP BY COALESCE(t.territory_name, 'Unassigned')
        ),
        mqt_prior AS (
          SELECT
            COALESCE(t.territory_name, 'Unassigned') as territory,
            COALESCE(SUM(st.net_revenue), 0)::numeric(12,2) as mqt_revenue
          FROM sales_transaction_normalized st
          LEFT JOIN territory t ON t.territory_id = st.territory_id
          WHERE st.sale_date >= date_trunc('month', CURRENT_DATE) - interval '6 months'
            AND st.sale_date < date_trunc('month', CURRENT_DATE) - interval '3 months'
            AND st.quantity > 0
            AND (cast($4 AS text) IS NULL OR st.warehouse = $4)
            AND (cast($5 AS text) IS NULL OR st.customer_suburb = $5)
            AND (cast($6 AS text) IS NULL OR st.customer_territory_group = $6)
          GROUP BY COALESCE(t.territory_name, 'Unassigned')
        )
        SELECT
          cp.territory,
          cp.cases,
          cp.gross_revenue,
          cp.total_discounts,
          cp.total_rebates,
          cp.total_fees,
          cp.revenue,
          cp.gp_pct,
          CASE WHEN COALESCE(pp.revenue, 0) > 0
            THEN ROUND(((cp.revenue - pp.revenue) / pp.revenue * 100)::numeric, 1)
            ELSE NULL
          END as trend_pct,
          COALESCE(mc.mqt_revenue, 0) as mqt_revenue,
          CASE WHEN COALESCE(mp.mqt_revenue, 0) > 0
            THEN ROUND(((COALESCE(mc.mqt_revenue, 0) - mp.mqt_revenue) / mp.mqt_revenue * 100)::numeric, 1)
            ELSE NULL
          END as mqt_variance_pct
        FROM current_period cp
        LEFT JOIN prior_period pp ON pp.territory = cp.territory
        LEFT JOIN mqt_current mc ON mc.territory = cp.territory
        LEFT JOIN mqt_prior mp ON mp.territory = cp.territory
        ORDER BY cp.revenue DESC
      `, [halfPeriod, period, halfPeriod, warehouseFilter, suburbFilter, territoryGroupFilter]),

      // 5. Rep leaderboard — top 10 by revenue
      // BUG-11 fix (2026-04-11): sales_transaction.rep_id is NULL on 100% of rows
      // (0/119172) — the Direct/DWS/ALM ETL never populated it, and customer.rep_id
      // is also effectively empty (2/10966). The canonical source of truth for rep
      // assignment post-JF-22 is canonical_customer.rep_name (populated 4007/4007
      // as a free-text string). So we resolve rep by joining
      //   sales_transaction → customer → canonical_customer.rep_name
      // and aggregate territory via the same path (canonical_customer.territory_name).
      // This mirrors the BUG-06 Top Customers rollup pattern in query #6 below.
      //
      // JF-24 fix (2026-04-11): the owner wants reps with zero transactions hidden but
      // zero-value transactions kept visible (waste/sample tracking). Counting txns
      // via COUNT(DISTINCT transaction_id) > 0 in the HAVING clause naturally hides
      // reps with no txns, while not filtering on net_revenue keeps $0 rows in.
      // Empty / blank rep_name is also excluded so the leaderboard isn't polluted
      // by unlabelled customers.
      pool.query(`
        SELECT
          cc.rep_name,
          string_agg(DISTINCT NULLIF(cc.territory_name, ''), ', ' ORDER BY NULLIF(cc.territory_name, '')) as territories,
          SUM(st.quantity_cases)::numeric(10,1) as cases,
          SUM(st.net_revenue)::numeric(12,2) as revenue
        FROM sales_transaction_normalized st
        JOIN customer cu ON cu.customer_id = st.customer_id
        JOIN canonical_customer cc ON cc.id = cu.canonical_customer_id
        WHERE st.sale_date >= CURRENT_DATE - interval '1 month' * $1
          AND st.quantity > 0
          AND cc.rep_name IS NOT NULL
          AND cc.rep_name <> ''
          AND (cast($2 AS text) IS NULL OR st.warehouse = $2)
          AND (cast($3 AS text) IS NULL OR st.customer_suburb = $3)
          AND (cast($4 AS text) IS NULL OR st.customer_territory_group = $4)
        GROUP BY cc.rep_name
        HAVING COUNT(DISTINCT st.transaction_id) > 0
        ORDER BY SUM(st.net_revenue) DESC NULLS LAST
        LIMIT 10
      `, [period, warehouseFilter, suburbFilter, territoryGroupFilter]),

      // 6. Top customers — top 10 by revenue with channel source
      // BUG-06 fix (2026-04-11): Roll up by canonical_customer_id so that raw
      // customer rows that point to the same entity (e.g. three Pegasus variants
      // all mapping to canonical_customer.id=2715) collapse into ONE row. Falls
      // back to raw customer_id when no canonical mapping exists, so coverage
      // is never worse than before. Also checks customer_alias as an override
      // lookup by name for any future manual dedupe entries that aren't yet in
      // canonical_customer (long-term dedupe review UI comes with JF-27).
      //
      // JC-021/375/376 (2026-04-05): Display "NAME @ SUBURB" composite — same
      // business name in different suburbs is a different physical account, so
      // we prefer the raw `cu.customer_name` (which carries the suffix on
      // ALM/DWS/Direct rows) over the cleaned `cc.customer_name`. Reverses the
      // earlier BUG-07 strip, which was masking distinct accounts.
      pool.query(`
        WITH resolved AS (
          SELECT
            st.*,
            COALESCE(
              ca.canonical_customer_id,
              cu.canonical_customer_id,
              -- Synthetic negative id so unmapped raw customers still dedupe
              -- against themselves without colliding with canonical ids.
              -1 * cu.customer_id
            ) as group_key,
            -- JC-021/375/376 + R-004 (schema/115 mirror): keep " @ SUBURB" suffix.
            -- Legacy access rows already carry it inside cu.customer_name (B1 2026-04-27);
            -- 2026-02+ DWS+Direct ingest writes bare names — append at read-time when
            -- a suburb source exists. Guard LIKE prevents doubling.
            COALESCE(
              NULLIF(TRIM(
                CASE
                  WHEN cu.customer_name LIKE '% @ %' THEN cu.customer_name
                  WHEN COALESCE(NULLIF(cu.suburb, ''), cc.suburb, '') <> ''
                    THEN cu.customer_name || ' @ ' || COALESCE(NULLIF(cu.suburb, ''), cc.suburb)
                  ELSE cu.customer_name
                END
              ), ''),
              cc.customer_name
            ) as display_name
          FROM sales_transaction_normalized st
          JOIN customer cu ON cu.customer_id = st.customer_id
          LEFT JOIN customer_alias ca
            ON LOWER(ca.alias_name) = LOWER(cu.customer_name)
          LEFT JOIN canonical_customer cc
            ON cc.id = COALESCE(ca.canonical_customer_id, cu.canonical_customer_id)
          WHERE st.sale_date >= CURRENT_DATE - interval '1 month' * $1
            AND st.quantity > 0
            AND (cast($2 AS text) IS NULL OR st.warehouse = $2)
            AND (cast($3 AS text) IS NULL OR st.customer_suburb = $3)
            AND (cast($4 AS text) IS NULL OR st.customer_territory_group = $4)
        )
        SELECT
          r.display_name as customer_name,
          MAX(c.channel_name) as channel_name,
          MAX(COALESCE(t.territory_name, '')) as territory,
          SUM(r.quantity_cases)::numeric(10,1) as cases,
          SUM(r.net_revenue)::numeric(12,2) as revenue,
          EXTRACT(YEAR FROM MIN(r.sale_date))::int as first_sale_year
        FROM resolved r
        LEFT JOIN channel c ON c.channel_id = r.channel_id
        LEFT JOIN territory t ON t.territory_id = r.territory_id
        GROUP BY r.group_key, r.display_name
        ORDER BY SUM(r.net_revenue) DESC
        LIMIT 10
      `, [period, warehouseFilter, suburbFilter, territoryGroupFilter]),

      // 7. Filter reference data
      // JC-345-RPT: pull suburb + territory_group dropdown options from canonical_customer
      // (4070 rows, fast) rather than DISTINCT over the 121k-row sales view.
      pool.query(`
        SELECT
          ARRAY(SELECT DISTINCT channel_name FROM channel ORDER BY channel_name) as channels,
          ARRAY(SELECT territory_name FROM canonical_territory ORDER BY territory_name) as territories,
          ARRAY(SELECT DISTINCT suburb FROM canonical_customer
                WHERE suburb IS NOT NULL AND suburb <> '' ORDER BY suburb) as suburbs,
          ARRAY(SELECT DISTINCT territory_group FROM canonical_customer
                WHERE territory_group IS NOT NULL AND territory_group <> '' ORDER BY territory_group) as territory_groups
      `),

      // 8. Distribution metrics (M3-14): active, new, lost
      pool.query(`
        WITH recent AS (
          SELECT DISTINCT st.customer_id, sk.canonical_sku_id
          FROM sales_transaction_normalized st
          JOIN sku sk ON sk.sku_id = st.sku_id
          WHERE st.sale_date >= CURRENT_DATE - interval '1 month' * $1
            AND st.quantity > 0
            AND sk.canonical_sku_id IS NOT NULL
            AND (cast($4 AS text) IS NULL OR st.warehouse = $4)
            AND (cast($5 AS text) IS NULL OR st.customer_suburb = $5)
            AND (cast($6 AS text) IS NULL OR st.customer_territory_group = $6)
        ),
        prior AS (
          SELECT DISTINCT st.customer_id, sk.canonical_sku_id
          FROM sales_transaction_normalized st
          JOIN sku sk ON sk.sku_id = st.sku_id
          WHERE st.sale_date >= CURRENT_DATE - interval '1 month' * $2
            AND st.sale_date < CURRENT_DATE - interval '1 month' * $3
            AND st.quantity > 0
            AND sk.canonical_sku_id IS NOT NULL
            AND (cast($4 AS text) IS NULL OR st.warehouse = $4)
            AND (cast($5 AS text) IS NULL OR st.customer_suburb = $5)
            AND (cast($6 AS text) IS NULL OR st.customer_territory_group = $6)
        )
        SELECT
          (SELECT COUNT(*) FROM recent) as active_distributions,
          (SELECT COUNT(*) FROM recent r WHERE NOT EXISTS (
            SELECT 1 FROM prior p
            WHERE p.customer_id = r.customer_id
              AND p.canonical_sku_id = r.canonical_sku_id
          )) as new_distributions,
          (SELECT COUNT(*) FROM prior p WHERE NOT EXISTS (
            SELECT 1 FROM recent r
            WHERE r.customer_id = p.customer_id
              AND r.canonical_sku_id = p.canonical_sku_id
          )) as lost_distributions
      `, [halfPeriod, period, halfPeriod, warehouseFilter, suburbFilter, territoryGroupFilter]),

      // 9. Customer activity classification (BUG-51 / JR-060)
      // The owner Mar 25 definitions (verbatim):
      //   - New: customer has not ordered in previous 12 months (their earliest
      //     order is within the last 12 months — i.e. no prior history).
      //   - Lost: customer bought 7-12 months ago but NOT in last 6.
      //   - Active: customer ordered in the last 6 months.
      // Each customer falls into exactly ONE bucket so the three counts sum
      // to the distinct-customer population with any recorded order.
      pool.query(`
        WITH customer_windows AS (
          SELECT
            st.customer_id,
            MAX(st.sale_date) AS last_order_date,
            MIN(st.sale_date) AS first_order_date
          FROM sales_transaction_normalized st
          WHERE st.quantity > 0
            AND (cast($1 AS text) IS NULL OR st.warehouse = $1)
            AND (cast($2 AS text) IS NULL OR st.customer_suburb = $2)
            AND (cast($3 AS text) IS NULL OR st.customer_territory_group = $3)
          GROUP BY st.customer_id
        ),
        classified AS (
          SELECT
            customer_id,
            CASE
              WHEN last_order_date >= CURRENT_DATE - interval '6 months'
                THEN 'active'
              WHEN first_order_date >= CURRENT_DATE - interval '12 months'
                THEN 'new'
              WHEN last_order_date >= CURRENT_DATE - interval '12 months'
                AND last_order_date < CURRENT_DATE - interval '6 months'
                THEN 'lost'
              ELSE 'dormant'
            END AS bucket
          FROM customer_windows
        )
        SELECT
          COUNT(*) FILTER (WHERE bucket = 'new') AS new_customers,
          COUNT(*) FILTER (WHERE bucket = 'lost') AS lost_customers,
          COUNT(*) FILTER (WHERE bucket = 'active') AS active_customers_window
        FROM classified
      `, [warehouseFilter, suburbFilter, territoryGroupFilter]),
    ]);

    // Calculate YoY percentages
    const curr = kpiResult.rows[0];
    const prior = kpiPriorYear.rows[0];
    const dist = distributionResult.rows[0];
    const cust = customerActivityResult.rows[0];

    const yoyPct = (currVal: string, priorVal: string): number | null => {
      const c = parseFloat(currVal) || 0;
      const p = parseFloat(priorVal) || 0;
      if (p === 0) return null;
      return Math.round(((c - p) / p) * 1000) / 10;
    };

    return NextResponse.json({
      kpis: {
        total_cases: parseFloat(curr.total_cases) || 0,
        total_cases_yoy: yoyPct(curr.total_cases, prior.total_cases),
        total_revenue: parseFloat(curr.total_revenue) || 0,
        total_revenue_yoy: yoyPct(curr.total_revenue, prior.total_revenue),
        active_customers: parseInt(curr.active_customers) || 0,
        active_customers_prior: parseInt(prior.active_customers) || 0,
        avg_wholesale_per_case: parseFloat(curr.avg_wholesale_per_case) || 0,
        avg_wholesale_per_case_yoy: yoyPct(curr.avg_wholesale_per_case, prior.avg_wholesale_per_case),
        active_distributions: parseInt(dist.active_distributions) || 0,
        new_distributions: parseInt(dist.new_distributions) || 0,
        lost_distributions: parseInt(dist.lost_distributions) || 0,
        // BUG-51 / JR-060 — customer activity tiles (the owner Mar 25 definitions)
        new_customers: parseInt(cust.new_customers) || 0,
        lost_customers: parseInt(cust.lost_customers) || 0,
        active_customers_window: parseInt(cust.active_customers_window) || 0,
      },
      revenue_by_channel: revenueByChannel.rows.map(r => ({
        month: r.month,
        dws: parseFloat(r.dws) || 0,
        alm: parseFloat(r.alm) || 0,
        direct: parseFloat(r.direct) || 0,
        total: parseFloat(r.total) || 0,
        yoy_total: parseFloat(r.yoy_total) || 0,
      })),
      territory_performance: territoryPerf.rows.map(r => ({
        territory: r.territory,
        cases: parseFloat(r.cases) || 0,
        gross_revenue: parseFloat(r.gross_revenue) || 0,
        total_discounts: parseFloat(r.total_discounts) || 0,
        total_rebates: parseFloat(r.total_rebates) || 0,
        total_fees: parseFloat(r.total_fees) || 0,
        revenue: parseFloat(r.revenue) || 0,
        gp_pct: parseFloat(r.gp_pct) || 0,
        trend_pct: r.trend_pct !== null ? parseFloat(r.trend_pct) : null,
        mqt_revenue: parseFloat(r.mqt_revenue) || 0,
        mqt_variance_pct: r.mqt_variance_pct !== null ? parseFloat(r.mqt_variance_pct) : null,
      })),
      rep_leaderboard: repLeaderboard.rows.map(r => ({
        rep_name: r.rep_name,
        territories: r.territories || '',
        cases: parseFloat(r.cases) || 0,
        revenue: parseFloat(r.revenue) || 0,
      })),
      top_customers: topCustomers.rows.map(r => ({
        customer_name: r.customer_name,
        channel: r.channel_name,
        territory: r.territory,
        cases: parseFloat(r.cases) || 0,
        revenue: parseFloat(r.revenue) || 0,
        since: r.first_sale_year,
      })),
      filters: {
        channels: filterData.rows[0]?.channels || [],
        territories: filterData.rows[0]?.territories || [],
        suburbs: filterData.rows[0]?.suburbs || [],
        territory_groups: filterData.rows[0]?.territory_groups || [],
      },
    });
  } catch (err) {
    console.error('[/api/sales] Error:', err);
    return NextResponse.json(
      { error: 'Failed to load sales data' },
      { status: 500 }
    );
  }
}
