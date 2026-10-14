export const dynamic = 'force-dynamic';

import { NextResponse } from 'next/server';
import getPool from '@/lib/db';

/**
 * GET /api/wines?sku_id=123
 * Returns full detail for a single SKU: KPIs, sales by month, traceability chain,
 * channel breakdown, vintage attribution, and related vintages in same group.
 */
export async function GET(request: Request) {
  try {
    const { searchParams } = new URL(request.url);
    const skuId = searchParams.get('sku_id');

    if (!skuId || !/^\d+$/.test(skuId)) {
      return NextResponse.json({ error: 'sku_id must be a positive integer' }, { status: 400 });
    }

    const pool = getPool();
    const id = parseInt(skuId);

    const [skuResult, salesByMonth, traceability, channelBreakdown, vintageAttribution, relatedVintages, topCustomers, stockRunout] = await Promise.all([
      // 1. SKU base data + KPIs
      pool.query(`
        SELECT
          s.sku_id, s.sku_code, s.item_description, s.variety,
          COALESCE(mro.region, s.region) AS region,
          s.vintage,
          s.base_wholesale, s.transfer_cost, s.units_per_case, s.sku_group,
          s.canonical_sku_id, cs.sku_name as canonical_sku_name,
          cs.range_name,
          COALESCE(rev12.revenue, 0)::numeric(12,2) as revenue_12m,
          COALESCE(rev12.qty, 0)::numeric(12,1) as qty_12m,
          COALESCE(rev12.orders, 0) as orders_12m,
          econ.avg_econ_cogs::numeric(12,4) as economic_cogs_per_unit,
          -- B7a JC-221: gp_pct_* must be NULL (not 0) when COGS or revenue is missing,
          -- otherwise the UI rendered "100% GP" for SKUs with no economic_cogs data.
          CASE WHEN COALESCE(rev12.revenue, 0) > 0 AND s.transfer_cost IS NOT NULL
            THEN ROUND(((rev12.revenue - rev12.qty * s.transfer_cost) / rev12.revenue * 100)::numeric, 1)
            END as gp_pct_accounting,
          CASE WHEN COALESCE(rev12.revenue, 0) > 0 AND econ.avg_econ_cogs IS NOT NULL
            THEN ROUND(((rev12.revenue - rev12.qty * econ.avg_econ_cogs) / rev12.revenue * 100)::numeric, 1)
            END as gp_pct_economic,
          -- Velocity
          CASE WHEN COALESCE(v3.months, 0) > 0 THEN ROUND((v3.qty / v3.months)::numeric, 1) ELSE 0 END as velocity_3m,
          CASE WHEN COALESCE(v6.months, 0) > 0 THEN ROUND((v6.qty / v6.months)::numeric, 1) ELSE 0 END as velocity_6m,
          CASE WHEN COALESCE(v12.months, 0) > 0 THEN ROUND((v12.qty / v12.months)::numeric, 1) ELSE 0 END as velocity_12m
        FROM sku s
        LEFT JOIN canonical_sku cs ON cs.id = s.canonical_sku_id
        LEFT JOIN manual_region_override mro ON mro.sku_id = s.sku_id
        LEFT JOIN LATERAL (
          SELECT SUM(net_revenue) as revenue, SUM(quantity_cases) as qty, COUNT(*) as orders
          FROM sales_transaction_normalized WHERE sku_id = $1 AND sale_date >= CURRENT_DATE - interval '12 months' AND quantity > 0
        ) rev12 ON true
        LEFT JOIN LATERAL (
          SELECT AVG(economic_cogs_per_unit) as avg_econ_cogs
          FROM sales_transaction_normalized WHERE sku_id = $1 AND economic_cogs_per_unit IS NOT NULL AND quantity > 0
        ) econ ON true
        LEFT JOIN LATERAL (
          SELECT SUM(quantity_cases) as qty, COUNT(DISTINCT date_trunc('month', sale_date)) as months
          FROM sales_transaction_normalized WHERE sku_id = $1 AND sale_date >= CURRENT_DATE - interval '3 months' AND quantity > 0
        ) v3 ON true
        LEFT JOIN LATERAL (
          SELECT SUM(quantity_cases) as qty, COUNT(DISTINCT date_trunc('month', sale_date)) as months
          FROM sales_transaction_normalized WHERE sku_id = $1 AND sale_date >= CURRENT_DATE - interval '6 months' AND quantity > 0
        ) v6 ON true
        LEFT JOIN LATERAL (
          SELECT SUM(quantity_cases) as qty, COUNT(DISTINCT date_trunc('month', sale_date)) as months
          FROM sales_transaction_normalized WHERE sku_id = $1 AND sale_date >= CURRENT_DATE - interval '12 months' AND quantity > 0
        ) v12 ON true
        WHERE s.sku_id = $1
      `, [id]),

      // 2. Sales by month (13 months, by channel)
      pool.query(`
        WITH months AS (
          SELECT generate_series(
            date_trunc('month', CURRENT_DATE - interval '12 months'),
            date_trunc('month', CURRENT_DATE),
            '1 month'
          )::date as month
        )
        SELECT
          to_char(m.month, 'Mon YY') as month,
          COALESCE(SUM(CASE WHEN c.channel_name = 'DWS' THEN st.net_revenue END), 0)::numeric(10,2) as dws,
          COALESCE(SUM(CASE WHEN c.channel_name = 'ALM' THEN st.net_revenue END), 0)::numeric(10,2) as alm,
          COALESCE(SUM(CASE WHEN c.channel_name = 'Direct' THEN st.net_revenue END), 0)::numeric(10,2) as direct,
          COALESCE(SUM(st.quantity_cases), 0)::numeric(10,1) as total_qty
        FROM months m
        LEFT JOIN sales_transaction_normalized st ON date_trunc('month', st.sale_date) = m.month AND st.sku_id = $1 AND st.quantity > 0
        LEFT JOIN channel c ON c.channel_id = st.channel_id
        GROUP BY m.month ORDER BY m.month
      `, [id]),

      // 3. Traceability chain: Packaging → Vessel → Batch
      // B2 / WINE-PROFILE-BOTTLING-DATE-P1.5 — previously this query selected
      // wb.vintage, which is regex-derived from the FIRST 2 digits of
      // wine_batch.Code (see etl/sync_vinsight_cogs.py:226-233 — e.g. the
      // batch_code '24SCPCOP17LKTU' produced vintage=2024). For long-aged
      // batches the prefix is NOT the vintage year, so rows showed impossible
      // combinations like vintage 2024 / Bottled 29/07/2019 (bottled BEFORE
      // the supposed vintage).
      // Fix — source the displayed vintage from the SAME row scope as
      // bottling_date: extract the 4-digit year from packaging_operation.description
      // (Vinsight populates this with the vintage, e.g. "2024 Coppabella Chardonnay
      // Labelling" — see etl/sync_vinsight_cogs.py:322-323), falling back to
      // wine_batch.description (e.g. "Tumba Pinot Chard 2018"). The proven
      // 4-digit-year regex shape comes from BUG-157
      // (schema/075_bug157_vintage_parser_fix.sql:83 — anchors with
      // (?<![0-9])(19[0-9]{2}|20[0-9]{2})(?![0-9]) to reject false matches
      // inside numeric IDs while still matching stuck-to-text years).
      // Final safety net: if the derived vintage is somehow still > bottling
      // year, NULL it instead of rendering the impossible value.
      pool.query(`
        SELECT
          po.description as packaging_desc,
          po.bottling_date,
          po.cases_produced,
          v.vessel_code,
          v.name as vessel_name,
          wb.batch_code,
          wb.description as batch_desc,
          wb.variety as batch_variety,
          wb.region as batch_region,
          CASE
            WHEN dv.derived_vintage IS NULL THEN NULL
            -- Sanity: vintage year cannot be after bottling year. If the regex
            -- picked up a non-vintage 4-digit number, drop it.
            WHEN po.bottling_date IS NOT NULL
              AND dv.derived_vintage > EXTRACT(YEAR FROM po.bottling_date)::INT
              THEN NULL
            ELSE dv.derived_vintage
          END AS batch_vintage,
          wb.color as batch_color,
          pv.volume_litres
        -- R-009 (2026-04-30): join wine_batch via packaging_vessel.wine_batch_id
        -- (the historical batch packaged from this vessel into this op, sourced
        -- from staging_vinsight_wine_batches.raw_data->PackagingOperationVessels)
        -- NOT vessel.wine_batch_id (current vessel contents — wrong for any
        -- packaging op older than the vessel's most recent fill).
        FROM packaging_operation po
        JOIN packaging_vessel pv ON pv.packaging_operation_id = po.id
        JOIN vessel v ON v.id = pv.vessel_id
        JOIN wine_batch wb ON wb.id = pv.wine_batch_id
        LEFT JOIN LATERAL (
          SELECT COALESCE(
            NULLIF(SUBSTRING(COALESCE(po.description, '')
                             FROM '(?<![0-9])(19[0-9]{2}|20[0-9]{2})(?![0-9])'), '')::INT,
            NULLIF(SUBSTRING(COALESCE(wb.description, '')
                             FROM '(?<![0-9])(19[0-9]{2}|20[0-9]{2})(?![0-9])'), '')::INT
          ) AS derived_vintage
        ) dv ON true
        WHERE po.sku_id = $1
        ORDER BY pv.volume_litres DESC
      `, [id]),

      // 4. Revenue by channel (12m)
      pool.query(`
        SELECT c.channel_name,
          SUM(st.net_revenue)::numeric(10,2) as revenue,
          SUM(st.quantity_cases)::numeric(10,1) as qty,
          COUNT(*) as transactions
        FROM sales_transaction_normalized st
        JOIN channel c ON c.channel_id = st.channel_id
        WHERE st.sku_id = $1 AND st.sale_date >= CURRENT_DATE - interval '12 months'
          AND st.quantity > 0
        GROUP BY c.channel_name ORDER BY revenue DESC
      `, [id]),

      // 5. Vintage attribution breakdown
      pool.query(`
        SELECT sva.attributed_vintage, sva.attribution_method, sva.confidence,
          COUNT(*) as sales_count,
          SUM(st.net_revenue)::numeric(10,2) as revenue
        FROM sale_vintage_attribution sva
        JOIN sales_transaction_normalized st ON st.transaction_id = sva.sales_transaction_id
        WHERE st.sku_id = $1
          AND st.quantity > 0
        GROUP BY sva.attributed_vintage, sva.attribution_method, sva.confidence
        ORDER BY sva.attributed_vintage DESC
      `, [id]),

      // 6. Related vintages — derived from Vinsight dispatch data (vintage-specific)
      pool.query(`
        SELECT
          vi.vintage,
          string_agg(DISTINCT vi.stock_item_code, ', ' ORDER BY vi.stock_item_code) as sku_codes,
          SUM(vi.quantity)::numeric(10,1) as qty_dispatched,
          COUNT(*) as dispatch_count
        FROM vinsight_sales_order_item vi
        JOIN canonical_sku cs
          ON UPPER(cs.sku_name) = UPPER(REGEXP_REPLACE(vi.description, '\\s*\\d{4}$', ''))
        WHERE cs.id = (SELECT canonical_sku_id FROM sku WHERE sku_id = $1)
          AND vi.vintage IS NOT NULL AND vi.vintage > 0
        GROUP BY vi.vintage
        ORDER BY vi.vintage DESC
      `, [id]),

      // 7. Top 5 customers by revenue (last 12m) with growth/decline indicator
      // Deduplicates by display name (canonical_customer name when linked, else customer name)
      pool.query(`
        WITH sales_named AS (
          SELECT
            COALESCE(cc.customer_name, cu.customer_name) as display_name,
            COALESCE(cc.channel, '') as channel,
            st.quantity,
            st.quantity_cases,
            st.net_revenue,
            st.sale_date
          FROM sales_transaction_normalized st
          JOIN customer cu ON cu.customer_id = st.customer_id
          LEFT JOIN canonical_customer cc ON cc.id = cu.canonical_customer_id
          WHERE st.sku_id = $1 AND st.sale_date >= CURRENT_DATE - interval '12 months'
            AND st.quantity > 0
        ),
        recent AS (
          SELECT display_name, channel,
            SUM(quantity_cases)::numeric(10,1) as cases,
            SUM(net_revenue)::numeric(12,2) as revenue,
            COALESCE(SUM(CASE WHEN sale_date >= CURRENT_DATE - interval '6 months' THEN quantity_cases END), 0) as recent_6m,
            COALESCE(SUM(CASE WHEN sale_date < CURRENT_DATE - interval '6 months' THEN quantity_cases END), 0) as prior_6m
          FROM sales_named
          GROUP BY display_name, channel
          ORDER BY SUM(net_revenue) DESC
          LIMIT 5
        )
        SELECT
          display_name as customer_name,
          channel as channel_name,
          cases,
          revenue,
          recent_6m,
          prior_6m,
          CASE
            WHEN prior_6m = 0 AND recent_6m > 0 THEN 'growth'
            WHEN prior_6m = 0 AND recent_6m = 0 THEN 'stable'
            WHEN ((recent_6m - prior_6m)::numeric / prior_6m) > 0.10 THEN 'growth'
            WHEN ((recent_6m - prior_6m)::numeric / prior_6m) < -0.10 THEN 'decline'
            ELSE 'stable'
          END as trend
        FROM recent
        ORDER BY revenue DESC
      `, [id]),

      // 8. Stock on hand — sum across Vinsight stock items mapped to this SKU.
      // R-008 fix (2026-04-30): previous query joined `staging.StockItemCode = sku.sku_code`
      // but Vinsight's external code is in `sku_code_map` (source_system='vinsight'), not in
      // `sku.sku_code` (which holds the Moppity master code). The two rarely match, so every
      // /wines page returned stock_cases=0 even with real Vinsight stock. Mirror /inventory's
      // working pattern: dedupe staging by StockItemCode, JOIN through sku_code_map, SUM.
      pool.query(`
        WITH deduped AS (
          SELECT DISTINCT ON (si.raw_data->>'StockItemCode')
            si.raw_data->>'StockItemCode' as sku_code,
            (si.raw_data->>'UnitsInStock')::numeric as units_in_stock
          FROM staging_vinsight_stock_items si
          WHERE (si.raw_data->>'IsPackagedWine')::boolean = true
            AND (si.raw_data->>'UnitsInStock')::numeric > 0
          ORDER BY si.raw_data->>'StockItemCode', (si.raw_data->>'UnitsInStock')::numeric DESC
        )
        SELECT COALESCE(SUM(d.units_in_stock), 0) as stock_cases
        FROM deduped d
        JOIN sku_code_map scm
          ON scm.external_code = d.sku_code
         AND scm.source_system = 'vinsight'
        WHERE scm.sku_id = $1
      `, [id]),
    ]);

    if (skuResult.rows.length === 0) {
      return NextResponse.json({ error: 'SKU not found' }, { status: 404 });
    }

    const sku = skuResult.rows[0];

    return NextResponse.json({
      sku: {
        ...sku,
        revenue_12m: parseFloat(sku.revenue_12m),
        qty_12m: parseFloat(sku.qty_12m),
        orders_12m: parseInt(sku.orders_12m),
        base_wholesale: parseFloat(sku.base_wholesale) || 0,
        transfer_cost: parseFloat(sku.transfer_cost) || 0,
        economic_cogs_per_unit: sku.economic_cogs_per_unit === null ? null : parseFloat(sku.economic_cogs_per_unit),
        gp_pct_accounting: sku.gp_pct_accounting === null ? null : parseFloat(sku.gp_pct_accounting),
        gp_pct_economic: sku.gp_pct_economic === null ? null : parseFloat(sku.gp_pct_economic),
        velocity_3m: parseFloat(sku.velocity_3m),
        velocity_6m: parseFloat(sku.velocity_6m),
        velocity_12m: parseFloat(sku.velocity_12m),
      },
      sales_by_month: salesByMonth.rows,
      traceability: traceability.rows.map(r => ({
        ...r,
        volume_litres: parseFloat(r.volume_litres),
      })),
      channels: channelBreakdown.rows.map(r => ({
        channel: r.channel_name,
        revenue: parseFloat(r.revenue),
        qty: parseFloat(r.qty),
        transactions: parseInt(r.transactions),
      })),
      vintage_attribution: vintageAttribution.rows.map(r => ({
        vintage: r.attributed_vintage,
        method: r.attribution_method,
        confidence: parseFloat(r.confidence),
        sales_count: parseInt(r.sales_count),
        revenue: parseFloat(r.revenue),
      })),
      related_vintages: relatedVintages.rows.map(r => ({
        vintage: r.vintage,
        sku_codes: r.sku_codes,
        qty_dispatched: parseFloat(r.qty_dispatched),
        dispatch_count: parseInt(r.dispatch_count),
      })),
      top_customers: topCustomers.rows.map(r => ({
        customer_name: r.customer_name,
        channel: r.channel_name || 'Unknown',
        cases: parseFloat(r.cases),
        revenue: parseFloat(r.revenue),
        trend: r.trend as 'growth' | 'decline' | 'stable',
      })),
      stock_cases: parseFloat(stockRunout.rows[0]?.stock_cases || '0'),
    });
  } catch (err) {
    console.error('[/api/wines] Error:', err);
    return NextResponse.json({ error: 'Failed to load wine data' }, { status: 500 });
  }
}
