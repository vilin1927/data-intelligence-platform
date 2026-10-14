export const dynamic = 'force-dynamic';

import { NextResponse } from 'next/server';
import getPool from '@/lib/db';

/**
 * GET /api/inventory/by-location
 *
 * B9 JC-262 / JC-265 / JC-270 / JC-281: per-SKU per-location stock with
 * months-of-cover, sourced from the `inventory_by_location_drill` view
 * (schema/096). ALM excluded by view definition; warehouse_owner is
 * either 'Moppity' or 'DWS'.
 *
 * Optional query params:
 *   ?canonical_sku_id=NN  → filter to one canonical product (vintage drill).
 *   ?stock_item_code=XXX  → filter to one Vinsight code.
 */
export async function GET(req: Request) {
  try {
    const { searchParams } = new URL(req.url);
    const canonicalSkuId = searchParams.get('canonical_sku_id');
    const stockItemCode  = searchParams.get('stock_item_code');

    const params: (string | number)[] = [];
    const where: string[] = [];

    if (canonicalSkuId) {
      params.push(parseInt(canonicalSkuId, 10));
      where.push(`canonical_sku_id = $${params.length}`);
    }
    if (stockItemCode) {
      params.push(stockItemCode);
      where.push(`stock_item_code = $${params.length}`);
    }

    const whereClause = where.length ? `WHERE ${where.join(' AND ')}` : '';

    const pool = getPool();
    const result = await pool.query(
      `
      SELECT
        soh_id,
        stock_item_code,
        description,
        stock_location_code,
        warehouse_owner,
        units_in_stock,
        units_in_stock_uom,
        cost_per_unit,
        total_value_of_stock,
        status,
        sku_id,
        vintage,
        canonical_sku_id,
        canonical_sku_name,
        range_name,
        units_per_case,
        velocity_12m,
        months_of_cover
      FROM inventory_by_location_drill
      ${whereClause}
      ORDER BY canonical_sku_name NULLS LAST, vintage DESC NULLS LAST,
               warehouse_owner, stock_location_code
      `,
      params,
    );

    return NextResponse.json({
      rows: result.rows.map(r => ({
        soh_id: r.soh_id,
        stock_item_code: r.stock_item_code,
        description: r.description,
        stock_location_code: r.stock_location_code,
        warehouse_owner: r.warehouse_owner,
        units_in_stock: parseFloat(r.units_in_stock) || 0,
        units_in_stock_uom: r.units_in_stock_uom,
        cost_per_unit: r.cost_per_unit !== null ? parseFloat(r.cost_per_unit) : null,
        total_value_of_stock: r.total_value_of_stock !== null ? parseFloat(r.total_value_of_stock) : null,
        status: r.status,
        sku_id: r.sku_id,
        vintage: r.vintage,
        canonical_sku_id: r.canonical_sku_id,
        canonical_sku_name: r.canonical_sku_name,
        range_name: r.range_name,
        units_per_case: r.units_per_case !== null ? parseFloat(r.units_per_case) : null,
        velocity_12m: parseFloat(r.velocity_12m) || 0,
        months_of_cover: r.months_of_cover !== null ? parseFloat(r.months_of_cover) : null,
      })),
    });
  } catch (err) {
    console.error('[/api/inventory/by-location] Error:', err);
    return NextResponse.json(
      { error: 'Failed to load inventory drill data' },
      { status: 500 },
    );
  }
}
