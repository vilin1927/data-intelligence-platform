export const dynamic = 'force-dynamic';

import { NextResponse } from 'next/server';
import getPool from '@/lib/db';

/**
 * GET /api/reconciliation
 * Returns DWS reconciliation data:
 * - KPIs: total compared, matched, mismatched, unmapped
 * - Inventory diff: Moppity stock vs DWS sell-through, by SKU
 * - Unmapped DWS codes
 * - Recent DWS activity summary
 */
export async function GET() {
  try {
    const pool = getPool();

    const [inventoryDiff, unmappedCodes, dwsSummary, kpis] = await Promise.all([
      // 1. M3-08: DWS Reconciliation grouped by canonical_sku (NV level, ~26 products)
      // Only shows SKUs that exist in DWS code mapping, grouped by canonical product
      // BUG-49 / JR-149: includes DWS SOH per canonical — sums UnitsInStock for any stock item
      // whose StockItemCode matches a DWS-mapped external_code (source_system='dws').
      pool.query(`
        SELECT
          cs.id as canonical_sku_id,
          cs.sku_name,
          -- Aggregate Moppity warehouse stock across all vintages
          COALESCE(SUM(DISTINCT stock.units_in_stock), 0)::numeric(10,1) as mv_stock,
          -- DWS SOH: sum of UnitsInStock on Vinsight stock items keyed by DWS external_code
          COALESCE(SUM(DISTINCT dws_stock.units_in_stock), 0)::numeric(10,1) as dws_soh,
          -- DWS codes for this canonical product
          STRING_AGG(DISTINCT dws_map.external_code, ', ') as dws_codes,
          -- Moppity codes
          STRING_AGG(DISTINCT s.sku_code, ', ') as mv_codes,
          -- DWS sales last 3 months
          COALESCE(SUM(CASE WHEN st.sale_date >= CURRENT_DATE - interval '3 months' THEN st.quantity_cases ELSE 0 END), 0)::numeric(10,1) as dws_qty_3m,
          COALESCE(SUM(CASE WHEN st.sale_date >= CURRENT_DATE - interval '3 months' THEN st.net_revenue ELSE 0 END), 0)::numeric(10,2) as dws_revenue_3m,
          -- DWS sales last month
          COALESCE(SUM(CASE WHEN st.sale_date >= CURRENT_DATE - interval '1 month' THEN st.quantity_cases ELSE 0 END), 0)::numeric(10,1) as dws_qty_1m,
          -- Total DWS sales
          COALESCE(SUM(st.quantity_cases), 0)::numeric(10,1) as dws_total_qty,
          COALESCE(SUM(st.net_revenue), 0)::numeric(10,2) as dws_total_revenue,
          MAX(st.sale_date) as last_sale_date
        FROM canonical_sku cs
        JOIN sku s ON s.canonical_sku_id = cs.id
        JOIN sku_code_map dws_map ON dws_map.sku_id = s.sku_id AND dws_map.source_system = 'dws'
        LEFT JOIN sales_transaction_normalized st ON st.sku_id = s.sku_id
          AND st.quantity > 0
          AND EXISTS (SELECT 1 FROM channel c WHERE c.channel_id = st.channel_id AND c.channel_name = 'DWS')
        LEFT JOIN LATERAL (
          SELECT (si.raw_data->>'UnitsInStock')::numeric as units_in_stock
          FROM staging_vinsight_stock_items si
          WHERE si.raw_data->>'StockItemCode' = s.sku_code
            AND (si.raw_data->>'IsPackagedWine')::boolean = true
          LIMIT 1
        ) stock ON true
        LEFT JOIN LATERAL (
          -- BUG-49: one row per DWS external_code (dedup via DISTINCT ON), latest snapshot first
          SELECT DISTINCT ON (si.raw_data->>'StockItemCode')
                 (si.raw_data->>'UnitsInStock')::numeric as units_in_stock
          FROM staging_vinsight_stock_items si
          WHERE si.raw_data->>'StockItemCode' = dws_map.external_code
            AND dws_map.external_code IS NOT NULL
          ORDER BY si.raw_data->>'StockItemCode', si.fetched_at DESC NULLS LAST
        ) dws_stock ON true
        GROUP BY cs.id, cs.sku_name
        ORDER BY COALESCE(SUM(st.net_revenue), 0) DESC
      `),

      // 2. Unmapped DWS codes (SKUs sold via DWS that have no DWS code mapping with external_code)
      pool.query(`
        SELECT
          s.sku_id,
          s.sku_code,
          s.item_description,
          s.variety,
          s.vintage,
          SUM(st.quantity_cases)::numeric(10,1) as total_qty,
          SUM(st.net_revenue)::numeric(10,2) as total_revenue,
          MAX(st.sale_date) as last_sale_date
        FROM sales_transaction_normalized st
        JOIN sku s ON s.sku_id = st.sku_id
        JOIN channel c ON c.channel_id = st.channel_id
        WHERE c.channel_name = 'DWS'
          AND st.quantity > 0
          AND NOT EXISTS (
            SELECT 1 FROM sku_code_map
            WHERE sku_id = s.sku_id
              AND source_system = 'dws'
              AND external_code IS NOT NULL
          )
        GROUP BY s.sku_id, s.sku_code, s.item_description, s.variety, s.vintage
        ORDER BY SUM(st.net_revenue) DESC
      `),

      // 3. DWS monthly summary (last 6 months)
      pool.query(`
        SELECT
          to_char(date_trunc('month', st.sale_date), 'Mon YY') as month,
          date_trunc('month', st.sale_date)::date as month_date,
          SUM(st.quantity_cases)::numeric(10,1) as cases,
          SUM(st.net_revenue)::numeric(10,2) as revenue,
          COUNT(DISTINCT st.sku_id) as skus_sold,
          COUNT(DISTINCT st.customer_id) as customers
        FROM sales_transaction_normalized st
        JOIN channel c ON c.channel_id = st.channel_id
        WHERE c.channel_name = 'DWS'
          AND st.sale_date >= CURRENT_DATE - interval '6 months'
          AND st.quantity > 0
        GROUP BY date_trunc('month', st.sale_date)
        ORDER BY date_trunc('month', st.sale_date) DESC
      `),

      // 4. KPIs
      pool.query(`
        SELECT
          -- Total DWS SKUs (have DWS sales)
          (SELECT COUNT(DISTINCT sku_id) FROM sales_transaction_normalized st
           JOIN channel c ON c.channel_id = st.channel_id WHERE c.channel_name = 'DWS' AND st.quantity > 0) as total_dws_skus,
          -- Mapped (have DWS code with external_code in sku_code_map)
          (SELECT COUNT(DISTINCT s.sku_id) FROM sku s
           JOIN sku_code_map scm ON scm.sku_id = s.sku_id AND scm.source_system = 'dws' AND scm.external_code IS NOT NULL
           JOIN sales_transaction_normalized st ON st.sku_id = s.sku_id AND st.quantity > 0
           JOIN channel c ON c.channel_id = st.channel_id AND c.channel_name = 'DWS') as mapped_skus,
          -- With stock
          (SELECT COUNT(DISTINCT s.sku_id) FROM sku s
           JOIN staging_vinsight_stock_items si ON si.raw_data->>'StockItemCode' = s.sku_code
             AND (si.raw_data->>'IsPackagedWine')::boolean = true
             AND (si.raw_data->>'UnitsInStock')::numeric > 0
           JOIN sales_transaction_normalized st ON st.sku_id = s.sku_id AND st.quantity > 0
           JOIN channel c ON c.channel_id = st.channel_id AND c.channel_name = 'DWS') as with_stock,
          -- Total DWS revenue (12m)
          (SELECT COALESCE(SUM(st.net_revenue), 0)::numeric(12,2) FROM sales_transaction_normalized st
           JOIN channel c ON c.channel_id = st.channel_id WHERE c.channel_name = 'DWS'
           AND st.sale_date >= CURRENT_DATE - interval '12 months' AND st.quantity > 0) as dws_revenue_12m,
          -- Total DWS cases (12m)
          (SELECT COALESCE(SUM(st.quantity_cases), 0)::numeric(10,1) FROM sales_transaction_normalized st
           JOIN channel c ON c.channel_id = st.channel_id WHERE c.channel_name = 'DWS'
           AND st.sale_date >= CURRENT_DATE - interval '12 months' AND st.quantity > 0) as dws_cases_12m
      `),
    ]);

    const k = kpis.rows[0];
    // RECONCILE-PARSEINT-GUARDS-P1.5 (mirrors the 2026-04-28 /api/inventory fix):
    // when source CTEs return zero rows (e.g. empty staging_vinsight_stock_items
    // or no DWS sales yet), the SUM/COUNT aggregates yield NULL → parseInt(null)
    // = NaN → JSON.stringify(NaN) = "null", which then crashes downstream UI calls
    // like `kpis.total_dws_skus.toLocaleString()`. Coerce every integer KPI/row
    // count to 0 on null/NaN. Same pattern applied to parseInt sites below.
    const mapped = parseInt(k.mapped_skus) || 0;
    const totalDws = parseInt(k.total_dws_skus) || 0;

    return NextResponse.json({
      kpis: {
        total_dws_skus: totalDws,
        mapped_skus: mapped,
        unmapped_skus: unmappedCodes.rows.length,
        with_stock: parseInt(k.with_stock) || 0,
        dws_revenue_12m: parseFloat(k.dws_revenue_12m),
        dws_cases_12m: parseFloat(k.dws_cases_12m),
      },
      inventory: inventoryDiff.rows.map(r => ({
        canonical_sku_id: r.canonical_sku_id,
        sku_name: r.sku_name,
        mv_codes: r.mv_codes,
        dws_codes: r.dws_codes,
        mv_stock: parseFloat(r.mv_stock),
        dws_soh: parseFloat(r.dws_soh), // BUG-49 / JR-149
        dws_qty_3m: parseFloat(r.dws_qty_3m),
        dws_revenue_3m: parseFloat(r.dws_revenue_3m),
        dws_qty_1m: parseFloat(r.dws_qty_1m),
        dws_total_qty: parseFloat(r.dws_total_qty),
        dws_total_revenue: parseFloat(r.dws_total_revenue),
        last_sale_date: r.last_sale_date,
      })),
      unmapped: unmappedCodes.rows.map(r => ({
        sku_id: r.sku_id,
        sku_code: r.sku_code,
        item_description: r.item_description,
        variety: r.variety,
        vintage: r.vintage,
        total_qty: parseFloat(r.total_qty),
        total_revenue: parseFloat(r.total_revenue),
        last_sale_date: r.last_sale_date,
      })),
      monthly_summary: dwsSummary.rows.map(r => ({
        month: r.month,
        cases: parseFloat(r.cases),
        revenue: parseFloat(r.revenue),
        skus_sold: parseInt(r.skus_sold) || 0,
        customers: parseInt(r.customers) || 0,
      })),
    });
  } catch (err) {
    console.error('[/api/reconciliation] Error:', err);
    return NextResponse.json({ error: 'Failed to load reconciliation data' }, { status: 500 });
  }
}
