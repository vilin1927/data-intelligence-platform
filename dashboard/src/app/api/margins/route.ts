export const dynamic = 'force-dynamic';

import { NextResponse } from 'next/server';
import getPool from '@/lib/db';

/**
 * GET /api/margins
 * Returns SKU margin data for the Margin Analysis page:
 * - SKUs with accounting COGS, revenue by channel, velocity
 * - Grape composition for economic COGS (client-side cascade)
 * - Grape price rules
 * - Filter reference data (channels, ranges, vintages)
 */
function deriveColor(variety: string | null): string {
  if (!variety) return 'red';
  const v = variety.toLowerCase();
  const whites = ['chardonnay', 'riesling', 'sauvignon', 'pinot gris', 'pinot grigio',
    'moscato', 'prosecco', 'albarino', 'gewurztraminer', 'semillon'];
  return whites.some(w => v.includes(w)) ? 'white' : 'red';
}

export async function GET(request: Request) {
  try {
    const pool = getPool();
    const { searchParams } = new URL(request.url);
    const periodParam = searchParams.get('period') || '12m';
    const fromParam = searchParams.get('from'); // YYYY-MM format
    const toParam = searchParams.get('to');     // YYYY-MM format
    const repParam = searchParams.get('rep');             // JF-05: rep_name filter
    const territoryParam = searchParams.get('territory'); // JF-05: territory_name filter
    const channelParam = searchParams.get('channel');     // JF-05: canonical_customer.channel (on/off-premise)
    const periodMonths = periodParam === '3m' ? 3 : periodParam === '6m' ? 6 : 12;

    // Custom date range vs period-based interval
    const useCustomRange = fromParam && toParam &&
      /^\d{4}-\d{2}$/.test(fromParam) && /^\d{4}-\d{2}$/.test(toParam);

    // Build date filter clause and params
    // For custom range: $1 = from date (start of month), $2 = to date (start of month after)
    // For period: $1 = interval string (used as before)
    let dateFilterSku: string;
    let dateFilterChannel: string;
    const queryValues: (string | number)[] = [];

    if (useCustomRange) {
      const fromDate = `${fromParam}-01`;
      // "to" param is inclusive month, so upper bound = first day of next month
      const [toYear, toMonth] = toParam!.split('-').map(Number);
      const nextMonth = toMonth === 12 ? 1 : toMonth + 1;
      const nextYear = toMonth === 12 ? toYear + 1 : toYear;
      const toDate = `${nextYear}-${String(nextMonth).padStart(2, '0')}-01`;
      queryValues.push(fromDate, toDate);
      dateFilterSku = `st.sale_date >= $1::date AND st.sale_date < $2::date`;
      dateFilterChannel = `st.sale_date >= $1::date AND st.sale_date < $2::date`;
    } else {
      const intervalStr = `${periodMonths} months`;
      queryValues.push(intervalStr);
      dateFilterSku = `st.sale_date >= date_trunc('month', CURRENT_DATE) - $1::interval AND st.sale_date < date_trunc('month', CURRENT_DATE)`;
      dateFilterChannel = `st.sale_date >= date_trunc('month', CURRENT_DATE) - $1::interval AND st.sale_date < date_trunc('month', CURRENT_DATE)`;
    }

    // JF-05: Customer-attribute filters (rep / territory / channel).
    // Join sales_transaction -> customer -> canonical_customer once, attached to
    // both the main SKU lateral and the per-channel revenue query via EXISTS so
    // that date-filter params keep positions $1/$2 and attribute filters append.
    // Use EXISTS to avoid row multiplication when a customer could match multiple
    // canonical rows; we ONLY filter, never change the aggregates.
    const custFilterParts: string[] = [];
    if (repParam) {
      queryValues.push(repParam);
      custFilterParts.push(`cc.rep_name = $${queryValues.length}`);
    }
    if (territoryParam) {
      queryValues.push(territoryParam);
      custFilterParts.push(`cc.territory_name = $${queryValues.length}`);
    }
    if (channelParam) {
      queryValues.push(channelParam);
      custFilterParts.push(`cc.channel = $${queryValues.length}`);
    }
    // The EXISTS subquery is empty when no filter is active, so the clause
    // becomes a no-op (we inline only when needed).
    const custFilterClause = custFilterParts.length > 0
      ? ` AND EXISTS (
          SELECT 1 FROM customer cust
          JOIN canonical_customer cc ON cc.id = cust.canonical_customer_id
          WHERE cust.customer_id = st.customer_id
            AND ${custFilterParts.join(' AND ')}
        )`
      : '';

    const [skuResult, channelRevenue, grapeComposition, priceRules, refData, dateRange] = await Promise.all([
      // 1. SKU data with revenue metrics + velocity (3/6/12mo)
      pool.query({
        text: `
        SELECT
          s.sku_id,
          s.sku_code,
          s.item_description,
          s.variety,
          COALESCE(mro.region, s.region) AS region,
          s.vintage,
          s.sku_group,
          s.canonical_sku_id,
          cs.sku_name as canonical_sku_name,
          s.base_wholesale,
          s.transfer_cost,
          s.units_per_case,
          cs.range_name,
          COALESCE(rev.total_revenue, 0)::numeric(12,2) as total_revenue,
          COALESCE(rev.total_qty, 0)::numeric(12,1) as total_qty,
          CASE WHEN COALESCE(rev.months_active, 0) > 0
            THEN ROUND(COALESCE(rev.total_qty, 0) / rev.months_active, 1)
            ELSE 0
          END as velocity_12m,
          COALESCE(v6.velocity, 0)::numeric(10,1) as velocity_6m,
          COALESCE(v3.velocity, 0)::numeric(10,1) as velocity_3m,
          COALESCE(cs.cogs, ecogs.avg_economic_cogs, 0)::numeric(12,4) as economic_cogs_per_unit,
          COALESCE(stock.units_in_stock, 0)::numeric(10,1) as units_in_stock,
          CASE WHEN COALESCE(rev.total_qty, 0) > 0 AND COALESCE(rev.months_active, 0) > 0
            THEN ROUND((COALESCE(stock.units_in_stock, 0) / (rev.total_qty / rev.months_active))::numeric, 1)
            ELSE NULL
          END as stock_cover_months,
          -- OWNER-MAY8-B1: per-source code aggregations from canonical_sku_code_map.
          -- Keyed on s.canonical_sku_id so child sku rows of the same canonical
          -- share the same code set; groupByNv on the client merges the children
          -- into the canonical row so the badge set stays per-canonical.
          -- STRING_AGG yields comma-separated, sorted output for deterministic
          -- rendering. NULL when the canonical has no mapping in that source.
          (SELECT STRING_AGG(cscm.external_code, ',' ORDER BY cscm.external_code)
             FROM canonical_sku_code_map cscm
            WHERE cscm.canonical_sku_id = s.canonical_sku_id
              AND cscm.source_system = 'alm') AS alm_code,
          (SELECT STRING_AGG(cscm.external_code, ',' ORDER BY cscm.external_code)
             FROM canonical_sku_code_map cscm
            WHERE cscm.canonical_sku_id = s.canonical_sku_id
              AND cscm.source_system = 'dws') AS dws_code,
          (SELECT STRING_AGG(cscm.external_code, ',' ORDER BY cscm.external_code)
             FROM canonical_sku_code_map cscm
            WHERE cscm.canonical_sku_id = s.canonical_sku_id
              AND cscm.source_system = 'access') AS access_code,
          (SELECT STRING_AGG(cscm.external_code, ',' ORDER BY cscm.external_code)
             FROM canonical_sku_code_map cscm
            WHERE cscm.canonical_sku_id = s.canonical_sku_id
              AND cscm.source_system = 'vinsight') AS vinsight_code,
          (SELECT STRING_AGG(cscm.external_code, ',' ORDER BY cscm.external_code)
             FROM canonical_sku_code_map cscm
            WHERE cscm.canonical_sku_id = s.canonical_sku_id
              AND cscm.source_system = 'ilg') AS ilg_code
        FROM sku s
        LEFT JOIN canonical_sku cs ON cs.id = s.canonical_sku_id
        LEFT JOIN manual_region_override mro ON mro.sku_id = s.sku_id
        LEFT JOIN LATERAL (
          SELECT
            SUM(st.net_revenue) as total_revenue,
            SUM(st.quantity_cases) as total_qty,
            COUNT(DISTINCT date_trunc('month', st.sale_date)) as months_active
          FROM sales_transaction_normalized st
          WHERE st.sku_id = s.sku_id
            AND ${dateFilterSku}
            AND st.quantity > 0${custFilterClause}
        ) rev ON true
        LEFT JOIN LATERAL (
          SELECT CASE WHEN COUNT(DISTINCT date_trunc('month', st.sale_date)) > 0
            THEN SUM(st.quantity_cases) / COUNT(DISTINCT date_trunc('month', st.sale_date))
            ELSE 0 END as velocity
          FROM sales_transaction_normalized st WHERE st.sku_id = s.sku_id
            AND st.sale_date >= date_trunc('month', CURRENT_DATE) - interval '6 months'
            AND st.sale_date < date_trunc('month', CURRENT_DATE)
            AND st.quantity > 0
        ) v6 ON true
        LEFT JOIN LATERAL (
          SELECT CASE WHEN COUNT(DISTINCT date_trunc('month', st.sale_date)) > 0
            THEN SUM(st.quantity_cases) / COUNT(DISTINCT date_trunc('month', st.sale_date))
            ELSE 0 END as velocity
          FROM sales_transaction_normalized st WHERE st.sku_id = s.sku_id
            AND st.sale_date >= date_trunc('month', CURRENT_DATE) - interval '3 months'
            AND st.sale_date < date_trunc('month', CURRENT_DATE)
            AND st.quantity > 0
        ) v3 ON true
        LEFT JOIN LATERAL (
          SELECT AVG(st.economic_cogs_per_unit) as avg_economic_cogs
          FROM sales_transaction_normalized st
          WHERE st.sku_id = s.sku_id
            AND ${dateFilterSku}
            AND st.economic_cogs_per_unit IS NOT NULL
            AND st.quantity > 0${custFilterClause}
        ) ecogs ON true
        LEFT JOIN LATERAL (
          SELECT COALESCE(
            -- Direct match: sku_code = StockItemCode
            (SELECT (si.raw_data->>'UnitsInStock')::numeric
             FROM staging_vinsight_stock_items si
             WHERE si.raw_data->>'StockItemCode' = s.sku_code
               AND (si.raw_data->>'IsPackagedWine')::boolean = true
             LIMIT 1),
            -- Bridge via wine_product: find Vinsight stock for same wine product
            (SELECT SUM((si2.raw_data->>'UnitsInStock')::numeric)
             FROM sku_wine_product_map swpm
             JOIN staging_vinsight_stock_items si2
               ON si2.raw_data->>'StockItemCode' LIKE swpm.wine_product_code || '__'
               AND (si2.raw_data->>'IsPackagedWine')::boolean = true
               AND (si2.raw_data->>'UnitsInStock')::numeric > 0
             WHERE swpm.sku_id = s.sku_id)
          ) as units_in_stock
        ) stock ON true
        WHERE s.variety IS NOT NULL
          AND COALESCE(rev.total_revenue, 0) > 0
        ORDER BY COALESCE(rev.total_revenue, 0) DESC
      `,
        values: queryValues,
      }),

      // 2. Revenue breakdown by channel per SKU
      pool.query({
        text: `
        SELECT
          st.sku_id,
          c.channel_name,
          SUM(st.net_revenue)::numeric(10,2) as channel_revenue,
          SUM(st.quantity_cases)::numeric(10,1) as channel_qty
        FROM sales_transaction_normalized st
        JOIN channel c ON c.channel_id = st.channel_id
        WHERE ${dateFilterChannel}
          AND st.quantity > 0${custFilterClause}
        GROUP BY st.sku_id, c.channel_name
      `,
        values: queryValues,
      }),

      // 3. Grape composition per SKU via traceability chain
      pool.query(`
        SELECT
          po.sku_id,
          wb.variety,
          wb.region,
          wb.vintage,
          wb.color,
          pv.volume_litres,
          SUM(ABS(pv.volume_litres)) OVER (PARTITION BY po.sku_id) as total_volume
        FROM packaging_vessel pv
        JOIN packaging_operation po ON po.id = pv.packaging_operation_id
        JOIN vessel v ON v.id = pv.vessel_id
        JOIN wine_batch wb ON wb.id = v.wine_batch_id
        WHERE po.sku_id IS NOT NULL
          AND wb.variety IS NOT NULL
      `),

      // 4. Grape price rules
      pool.query(`
        SELECT id, region, color, grade, variety, vintage, price_per_ton
        FROM grape_price_rule
        ORDER BY vintage DESC, region, color, grade, variety
      `),

      // 5. Reference data for filters (M3-10: added territories + reps; JF-05: customer_channels)
      // Note: `channels` = WAREHOUSE channels (DWS/ALM/Direct). `customer_channels` =
      // on-premise/off-premise/wholesale/direct customer attribute from canonical_customer.
      pool.query(`
        SELECT
          ARRAY(SELECT DISTINCT channel_name FROM channel ORDER BY channel_name) as channels,
          ARRAY(SELECT DISTINCT range_name FROM canonical_sku WHERE range_name IS NOT NULL AND range_name <> '' ORDER BY range_name) as ranges,
          ARRAY(SELECT DISTINCT vintage FROM sku WHERE vintage IS NOT NULL ORDER BY vintage DESC) as vintages,
          ARRAY(SELECT territory_name FROM canonical_territory ORDER BY territory_name) as territories,
          ARRAY(SELECT DISTINCT rep_name FROM canonical_customer WHERE rep_name IS NOT NULL AND rep_name != '' ORDER BY rep_name) as reps,
          ARRAY(SELECT DISTINCT channel FROM canonical_customer WHERE channel IS NOT NULL AND channel != '' ORDER BY channel) as customer_channels
      `),

      // 6. Date range of sales data (for custom date picker)
      pool.query(`
        SELECT
          to_char(MIN(sale_date), 'YYYY-MM') as earliest_month,
          to_char(MAX(sale_date), 'YYYY-MM') as latest_month
        FROM sales_transaction_normalized
      `),
    ]);

    // Build channel revenue lookup: sku_id -> { DWS: x, ALM: y, Direct: z }
    const channelMap = new Map<number, Record<string, { revenue: number; qty: number }>>();
    for (const row of channelRevenue.rows) {
      if (!channelMap.has(row.sku_id)) {
        channelMap.set(row.sku_id, {});
      }
      channelMap.get(row.sku_id)![row.channel_name] = {
        revenue: parseFloat(row.channel_revenue),
        qty: parseFloat(row.channel_qty),
      };
    }

    // Build grape composition lookup: sku_id -> components[]
    const compositionMap = new Map<number, Array<{
      variety: string;
      region: string;
      vintage: number;
      color: string;
      proportion: number;
    }>>();

    for (const row of grapeComposition.rows) {
      const skuId = row.sku_id;
      if (!compositionMap.has(skuId)) {
        compositionMap.set(skuId, []);
      }
      const totalVolume = parseFloat(row.total_volume) || 0;
      const volume = Math.abs(parseFloat(row.volume_litres) || 0);
      if (totalVolume <= 0) continue;
      compositionMap.get(skuId)!.push({
        variety: row.variety,
        region: row.region || 'Unknown',
        vintage: row.vintage || 2024,
        color: row.color || 'red',
        proportion: volume / totalVolume,
      });
    }

    // Build response
    const skus = skuResult.rows.map(sku => ({
      sku_id: sku.sku_id,
      sku_code: sku.sku_code,
      item_description: sku.item_description,
      variety: sku.variety,
      region: sku.region,
      vintage: sku.vintage,
      sku_group: sku.sku_group,
      canonical_sku_id: sku.canonical_sku_id || null,
      canonical_sku_name: sku.canonical_sku_name || null,
      base_wholesale: parseFloat(sku.base_wholesale) || 0,
      transfer_cost: parseFloat(sku.transfer_cost) || 0,
      economic_cogs_per_unit: parseFloat(sku.economic_cogs_per_unit) || 0,
      range_name: sku.range_name,
      total_revenue: parseFloat(sku.total_revenue) || 0,
      total_qty: parseFloat(sku.total_qty) || 0,
      velocity_12m: parseFloat(sku.velocity_12m) || 0,
      units_in_stock: parseFloat(sku.units_in_stock) || 0,
      stock_cover_months: sku.stock_cover_months ? parseFloat(sku.stock_cover_months) : null,
      velocity_6m: parseFloat(sku.velocity_6m) || 0,
      velocity_3m: parseFloat(sku.velocity_3m) || 0,
      channels: channelMap.get(sku.sku_id) || {},
      // OWNER-MAY8-B1: per-source codes (string or null). Multi-code is
      // comma-separated. Consumers split on ',' to render badges.
      alm_code: sku.alm_code || null,
      dws_code: sku.dws_code || null,
      access_code: sku.access_code || null,
      vinsight_code: sku.vinsight_code || null,
      ilg_code: sku.ilg_code || null,
      grape_components: compositionMap.get(sku.sku_id) || [{
        variety: sku.variety || 'Unknown',
        region: sku.region || 'Unknown',
        vintage: sku.vintage || 2024,
        color: deriveColor(sku.variety),
        proportion: 1.0,
      }],
    }));

    return NextResponse.json({
      skus,
      period: periodParam,
      grape_price_rules: priceRules.rows.map(r => ({
        ...r,
        price_per_ton: parseFloat(r.price_per_ton),
      })),
      filters: {
        channels: refData.rows[0]?.channels || [],
        ranges: refData.rows[0]?.ranges || [],
        vintages: refData.rows[0]?.vintages || [],
        territories: refData.rows[0]?.territories || [],
        reps: refData.rows[0]?.reps || [],
        customer_channels: refData.rows[0]?.customer_channels || [],
      },
      date_range: {
        earliest_month: dateRange.rows[0]?.earliest_month || null,
        latest_month: dateRange.rows[0]?.latest_month || null,
      },
    });
  } catch (err) {
    console.error('[/api/margins] Error:', err);
    return NextResponse.json(
      { error: 'Failed to load margin data' },
      { status: 500 }
    );
  }
}
