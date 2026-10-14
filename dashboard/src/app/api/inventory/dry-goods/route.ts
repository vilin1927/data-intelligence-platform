export const dynamic = 'force-dynamic';

import { NextResponse } from 'next/server';
import getPool from '@/lib/db';

/**
 * GET /api/inventory/dry-goods
 *
 * Phase R / BUG-149: dry-goods inventory surface. The owner Q11 / Q14 — corks,
 * cartons, labels, capsules need a home. Vinsight staging classifies these via
 * IsPackagedWine=false AND IsBulkWine=false (the owner 2026-04-22 09:38: "Dry goods
 * shouldn't be counted in bottled wine stock… Should be included in dry goods
 * inventory"). BUG-91 + Phase B1 strips them from `sku` and `sales_transaction`
 * — so Vinsight raw_data is the source of truth for the count.
 *
 * Category is heuristic on the StockItemCode + Description since Vinsight has
 * no dedicated column. Falls through to 'other' so we surface rather than hide.
 */

// Keyword-based dry-goods classifier — keep in sync with etl/transform_to_core.py:~700
// where the BUG-91 filter lives. If the owner reviews and asks us to reclassify,
// that's the paired change.
function classify(code: string, description: string): string {
  const hay = `${code} ${description}`.toLowerCase();
  if (/\bcork\b|\bcorks\b/.test(hay)) return 'cork';
  if (/\bcapsule\b|\bcapsules\b|\bclosure\b|\bscrewcap\b|\bscrew cap\b/.test(hay)) return 'capsule';
  if (/\blabel\b|\blabels\b/.test(hay)) return 'label';
  if (/\bcarton\b|\bcartons\b|\bbox\b|\bboxes\b/.test(hay)) return 'carton';
  if (/\bbottle\b|\bbottles\b|\bglass\b/.test(hay)) return 'bottle';
  return 'other';
}

export async function GET() {
  try {
    const pool = getPool();

    // Dedupe by StockItemCode (staging has historical snapshots). Take the most
    // recent row per code.
    const result = await pool.query(`
      SELECT DISTINCT ON (raw_data->>'StockItemCode')
        raw_data->>'StockItemCode'           AS stock_item_code,
        raw_data->>'Description'              AS description,
        (raw_data->>'UnitsInStock')::numeric AS units_in_stock,
        raw_data->>'UnitsInStockUOM'          AS uom,
        (raw_data->>'StandardCost')::numeric AS standard_cost,
        (raw_data->>'IsPackagedWine')::boolean AS is_packaged_wine,
        (raw_data->>'IsBulkWine')::boolean    AS is_bulk_wine,
        fetched_at
      FROM staging_vinsight_stock_items
      WHERE COALESCE((raw_data->>'IsPackagedWine')::boolean, FALSE) = FALSE
        AND COALESCE((raw_data->>'IsBulkWine')::boolean, FALSE) = FALSE
      ORDER BY raw_data->>'StockItemCode', fetched_at DESC
    `);

    const rows = result.rows.map(r => {
      const code = r.stock_item_code || '';
      const description = r.description || '';
      const units = r.units_in_stock != null ? parseFloat(r.units_in_stock) : 0;
      const cost = r.standard_cost != null ? parseFloat(r.standard_cost) : 0;
      return {
        stock_item_code: code,
        description,
        category: classify(code, description),
        units_in_stock: units,
        uom: r.uom || '',
        standard_cost: cost,
        stock_value: units * cost,
      };
    });

    // KPI rollup
    type Row = typeof rows[number];
    const byCategory = new Map<string, { count: number; units: number; value: number }>();
    let totalUnits = 0;
    let totalValue = 0;
    let inStockCount = 0;
    for (const r of rows) {
      if (r.units_in_stock > 0) inStockCount += 1;
      totalUnits += r.units_in_stock;
      totalValue += r.stock_value;
      const bucket = byCategory.get(r.category) || { count: 0, units: 0, value: 0 };
      bucket.count += 1;
      bucket.units += r.units_in_stock;
      bucket.value += r.stock_value;
      byCategory.set(r.category, bucket);
    }

    const categoryBreakdown = Array.from(byCategory.entries()).map(([category, stats]) => ({
      category,
      line_items: stats.count,
      units: Math.round(stats.units),
      value: Math.round(stats.value),
    })).sort((a: { value: number }, b: { value: number }) => b.value - a.value);

    return NextResponse.json({
      kpis: {
        line_items: rows.length,
        in_stock_items: inStockCount,
        total_units: Math.round(totalUnits),
        total_value: Math.round(totalValue),
      },
      categories: categoryBreakdown,
      rows: rows.sort((a: Row, b: Row) => b.stock_value - a.stock_value),
    });
  } catch (err) {
    console.error('[/api/inventory/dry-goods] Error:', err);
    return NextResponse.json({ error: 'Failed to load dry-goods inventory' }, { status: 500 });
  }
}
