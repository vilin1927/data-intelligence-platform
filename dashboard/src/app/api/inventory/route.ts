export const dynamic = 'force-dynamic';

import { NextResponse } from 'next/server';
import getPool from '@/lib/db';

/**
 * GET /api/inventory
 * Returns inventory data: stock on hand, bulk wine vessels, recent bottling runs.
 */
export async function GET() {
  try {
    const pool = getPool();

    const [stockResult, kpis, vesselResult, dwsResult, bottlingResult] = await Promise.all([
      // 1. Packaged wine stock on hand (from Vinsight StockItems) + velocity for run-out
      // AUD-03: DISTINCT ON to deduplicate staging rows with same StockItemCode
      pool.query(`
        SELECT DISTINCT ON (si.raw_data->>'StockItemCode')
          si.raw_data->>'StockItemCode' as sku_code,
          si.raw_data->>'Description' as description,
          (si.raw_data->>'UnitsInStock')::numeric as units_in_stock,
          si.raw_data->>'UnitsInStockUOM' as uom,
          (si.raw_data->>'StandardCost')::numeric as standard_cost,
          s.sku_id,
          s.variety,
          s.region,
          s.vintage,
          s.base_wholesale,
          s.sku_group,
          s.canonical_sku_id,
          cs.sku_name as canonical_sku_name,
          cs.range_name,
          COALESCE(vel.velocity_12m, 0)::numeric(10,1) as velocity_12m,
          COALESCE(vel6.velocity_6m, 0)::numeric(10,1) as velocity_6m,
          COALESCE(vel3.velocity_3m, 0)::numeric(10,1) as velocity_3m,
          CASE WHEN COALESCE(vel.velocity_12m, 0) > 0
            THEN ROUND(((si.raw_data->>'UnitsInStock')::numeric / vel.velocity_12m)::numeric, 1)
            ELSE NULL
          END as months_cover,
          CASE WHEN COALESCE(vel.velocity_12m, 0) > 0
            THEN (CURRENT_DATE + (((si.raw_data->>'UnitsInStock')::numeric / vel.velocity_12m) * 30)::integer)
            ELSE NULL
          END as projected_runout
        FROM staging_vinsight_stock_items si
        LEFT JOIN LATERAL (
          SELECT s2.sku_id, s2.variety,
                 COALESCE(mro2.region, s2.region) AS region,
                 s2.vintage, s2.base_wholesale, s2.sku_group, s2.canonical_sku_id
          FROM sku_code_map scm
          JOIN sku s2 ON s2.sku_id = scm.sku_id
          LEFT JOIN manual_region_override mro2 ON mro2.sku_id = s2.sku_id
          WHERE scm.source_system = 'vinsight'
            AND scm.external_code = si.raw_data->>'StockItemCode'
          ORDER BY s2.sku_id
          LIMIT 1
        ) s ON true
        LEFT JOIN canonical_sku cs ON cs.id = s.canonical_sku_id
        LEFT JOIN LATERAL (
          SELECT CASE WHEN COUNT(DISTINCT date_trunc('month', st.sale_date)) > 0
            THEN SUM(st.quantity_cases) / COUNT(DISTINCT date_trunc('month', st.sale_date))
            ELSE 0 END as velocity_12m
          FROM sales_transaction_normalized st
          WHERE st.sku_id = s.sku_id AND st.sale_date >= CURRENT_DATE - interval '12 months' AND st.quantity > 0
        ) vel ON true
        LEFT JOIN LATERAL (
          SELECT CASE WHEN COUNT(DISTINCT date_trunc('month', st.sale_date)) > 0
            THEN SUM(st.quantity_cases) / COUNT(DISTINCT date_trunc('month', st.sale_date))
            ELSE 0 END as velocity_6m
          FROM sales_transaction_normalized st
          WHERE st.sku_id = s.sku_id AND st.sale_date >= CURRENT_DATE - interval '6 months' AND st.quantity > 0
        ) vel6 ON true
        LEFT JOIN LATERAL (
          SELECT CASE WHEN COUNT(DISTINCT date_trunc('month', st.sale_date)) > 0
            THEN SUM(st.quantity_cases) / COUNT(DISTINCT date_trunc('month', st.sale_date))
            ELSE 0 END as velocity_3m
          FROM sales_transaction_normalized st
          WHERE st.sku_id = s.sku_id AND st.sale_date >= CURRENT_DATE - interval '3 months' AND st.quantity > 0
        ) vel3 ON true
        WHERE (si.raw_data->>'IsPackagedWine')::boolean = true
          AND (si.raw_data->>'UnitsInStock')::numeric > 0
        ORDER BY si.raw_data->>'StockItemCode', (si.raw_data->>'UnitsInStock')::numeric DESC
      `),

      // 2. KPI summary (JR-055 / JR-148: warehouse split — Moppity-held vs DWS consignment vs Total)
      // BUG-28: Use DISTINCT ON (StockItemCode) subquery for KPIs to avoid staging duplicates
      // JR-055 / JR-148: a row is classified as DWS consignment if its Vinsight StockItemCode
      // appears in sku_code_map with source_system='dws'. Vinsight raw_data has no Warehouse
      // value populated (single 'DEFAULT' warehouse across all rows as of 2026-04-18), so
      // the DWS/Moppity discriminator is code-pattern-based, not location-based. Flag: $1.
      pool.query(
        `
        WITH deduped_stock AS (
          SELECT DISTINCT ON (raw_data->>'StockItemCode')
            raw_data->>'StockItemCode' as sku_code,
            (raw_data->>'UnitsInStock')::numeric as units_in_stock,
            (raw_data->>'StandardCost')::numeric as standard_cost
          FROM staging_vinsight_stock_items
          WHERE (raw_data->>'IsPackagedWine')::boolean = true
            AND (raw_data->>'UnitsInStock')::numeric > 0
          ORDER BY raw_data->>'StockItemCode', (raw_data->>'UnitsInStock')::numeric DESC
        ),
        classified AS (
          SELECT
            d.sku_code,
            d.units_in_stock,
            d.standard_cost,
            CASE WHEN EXISTS (
              SELECT 1 FROM sku_code_map scm
              WHERE scm.source_system = $1
                AND scm.external_code = d.sku_code
            ) THEN true ELSE false END AS is_dws
          FROM deduped_stock d
        )
        SELECT
          (SELECT count(*) FROM classified) as wines_in_stock,
          (SELECT ROUND(sum(units_in_stock)::numeric, 0) FROM classified) as total_cases,
          (SELECT ROUND(sum(units_in_stock * standard_cost)::numeric, 0) FROM classified) as total_stock_value,
          (SELECT ROUND(sum(units_in_stock)::numeric, 0) FROM classified WHERE is_dws = false) as moppity_cases,
          (SELECT ROUND(sum(units_in_stock * standard_cost)::numeric, 0) FROM classified WHERE is_dws = false) as moppity_stock_value,
          (SELECT ROUND(sum(units_in_stock)::numeric, 0) FROM classified WHERE is_dws = true) as dws_cases,
          (SELECT ROUND(sum(units_in_stock * standard_cost)::numeric, 0) FROM classified WHERE is_dws = true) as dws_stock_value,
          (SELECT count(*) FROM vessel WHERE current_volume_litres > 0) as active_vessels,
          (SELECT ROUND(sum(current_volume_litres)::numeric, 0) FROM vessel WHERE current_volume_litres > 0) as bulk_litres
      `,
        ['dws']
      ),

      // 3. Bulk wine vessels
      pool.query(`
        SELECT
          v.vessel_code,
          v.name,
          v.vessel_type,
          v.current_volume_litres,
          wb.batch_code,
          wb.description as batch_desc,
          wb.variety,
          wb.region,
          wb.vintage,
          wb.color
        FROM vessel v
        LEFT JOIN wine_batch wb ON wb.id = v.wine_batch_id
        WHERE v.current_volume_litres > 0
        ORDER BY v.current_volume_litres DESC
      `),

      // 4. DWS consignment: SKUs with DWS channel sales (last 12m)
      pool.query(`
        SELECT st.sku_id, SUM(st.quantity_cases)::numeric(10,1) as dws_cases
        FROM sales_transaction_normalized st
        JOIN channel c ON c.channel_id = st.channel_id
        WHERE c.channel_name = 'DWS'
          AND st.sale_date >= CURRENT_DATE - interval '12 months'
          AND st.quantity > 0
        GROUP BY st.sku_id
      `),

      // 5. Recent bottling runs
      pool.query(`
        SELECT
          po.description,
          po.bottling_date,
          po.cases_produced,
          po.status,
          s.sku_code,
          s.item_description
        FROM packaging_operation po
        LEFT JOIN sku s ON s.sku_id = po.sku_id
        WHERE po.bottling_date IS NOT NULL
        ORDER BY po.bottling_date DESC
        LIMIT 20
      `),
    ]);

    const k = kpis.rows[0];

    // Build DWS consignment lookup: sku_id → cases sold through DWS
    const dwsMap = new Map<number, number>();
    dwsResult.rows.forEach((r: { sku_id: number; dws_cases: string }) => {
      dwsMap.set(r.sku_id, parseFloat(r.dws_cases));
    });

    return NextResponse.json({
      kpis: {
        // 2026-04-28 fix: when staging_vinsight_stock_items is empty, the SUM/COUNT
        // CTE returns NULL → parseInt(null) = NaN → JSON.stringify(NaN) = "null",
        // which then crashed the page on `kpis.total_cases.toLocaleString()`.
        // Coerce every KPI to 0 on null/NaN to match the moppity_*/dws_* pattern
        // already used below.
        wines_in_stock: parseInt(k.wines_in_stock) || 0,
        // JR-055 / JR-148: three-way warehouse split. total_* preserved for back-compat.
        total_cases: parseInt(k.total_cases) || 0,
        total_stock_value: parseInt(k.total_stock_value) || 0,
        moppity_cases: parseInt(k.moppity_cases) || 0,
        moppity_stock_value: parseInt(k.moppity_stock_value) || 0,
        dws_cases: parseInt(k.dws_cases) || 0,
        dws_stock_value: parseInt(k.dws_stock_value) || 0,
        active_vessels: parseInt(k.active_vessels) || 0,
        bulk_litres: parseInt(k.bulk_litres) || 0,
      },
      stock: stockResult.rows.map(r => ({
        sku_code: r.sku_code,
        description: r.description,
        units_in_stock: parseFloat(r.units_in_stock),
        uom: r.uom,
        standard_cost: parseFloat(r.standard_cost) || 0,
        sku_id: r.sku_id,
        variety: r.variety,
        region: r.region,
        vintage: r.vintage,
        base_wholesale: parseFloat(r.base_wholesale) || 0,
        range_name: r.range_name,
        sku_group: r.sku_group,
        canonical_sku_id: r.canonical_sku_id || null,
        canonical_sku_name: r.canonical_sku_name || null,
        velocity_12m: parseFloat(r.velocity_12m),
        velocity_6m: parseFloat(r.velocity_6m),
        velocity_3m: parseFloat(r.velocity_3m),
        months_cover: r.months_cover ? parseFloat(r.months_cover) : null,
        projected_runout: r.projected_runout,
        dws_cases: r.sku_id ? (dwsMap.get(parseInt(r.sku_id)) || 0) : 0,
      })),
      vessels: vesselResult.rows.map(r => ({
        vessel_code: r.vessel_code,
        name: r.name,
        vessel_type: r.vessel_type,
        volume_litres: parseFloat(r.current_volume_litres),
        batch_code: r.batch_code,
        batch_desc: r.batch_desc,
        variety: r.variety,
        region: r.region,
        vintage: r.vintage,
        color: r.color,
      })),
      bottling_runs: bottlingResult.rows.map(r => ({
        description: r.description,
        bottling_date: r.bottling_date,
        cases_produced: r.cases_produced,
        status: r.status,
        sku_code: r.sku_code,
        item_description: r.item_description,
      })),
    });
  } catch (err) {
    console.error('[/api/inventory] Error:', err);
    return NextResponse.json({ error: 'Failed to load inventory data' }, { status: 500 });
  }
}
