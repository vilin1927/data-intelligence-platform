export const dynamic = 'force-dynamic';

import { NextResponse } from 'next/server';
import getPool from '@/lib/db';

/**
 * GET /api/wines/cogs?sku_id=N
 *
 * Returns the per-SKU COGS picture used by Wine Profile + Margin pages:
 *   - master_cogs:   per-FY standard COGS rows (from Access tbl_Master_COGS, 636 rows total)
 *   - cascade:       4-level grape-price cascade lookups for the SKU's grape composition,
 *                    each result tagged with `level_matched` (0..4) so the UI can show which
 *                    cascade level produced the price (JC-179 / JC-180 explainability).
 *   - economic_cogs_per_unit: average from sales_transaction_normalized (12m), NULL when missing
 *
 * AC2 / AC3 lookups (two reference wines) live in master_cogs once
 * etl/import_master_cogs_from_access.py runs. Pre-deploy these values do NOT match Access (see
 * post-delivery-clarifications.md — needs the owner confirmation).
 */
export async function GET(request: Request) {
  try {
    const { searchParams } = new URL(request.url);
    const skuIdParam = searchParams.get('sku_id');

    if (!skuIdParam || !/^\d+$/.test(skuIdParam)) {
      return NextResponse.json({ error: 'sku_id must be a positive integer' }, { status: 400 });
    }
    const skuId = parseInt(skuIdParam);
    const pool = getPool();

    const [skuMeta, masterCogs, cascadeRows, economic] = await Promise.all([
      // SKU descriptor for the lookup keys
      pool.query(
        `
        SELECT s.sku_id, s.sku_code, s.item_description, s.variety,
               COALESCE(mro.region, s.region) AS region,
               s.vintage,
               s.canonical_sku_id, cs.sku_name AS canonical_sku_name, cs.range_name
        FROM sku s
        LEFT JOIN canonical_sku cs ON cs.id = s.canonical_sku_id
        LEFT JOIN manual_region_override mro ON mro.sku_id = s.sku_id
        WHERE s.sku_id = $1
        `,
        [skuId],
      ),

      // master_cogs rows for the canonical product name (or item_description fallback).
      // Access uses product description, NOT sku_code, so we join via the SKU's
      // canonical_sku.sku_name (preferred) or item_description.
      pool.query(
        `
        SELECT mc.id, mc.sku, mc.financial_year, mc.cogs_value
        FROM master_cogs mc
        JOIN sku s ON s.sku_id = $1
        LEFT JOIN canonical_sku cs ON cs.id = s.canonical_sku_id
        WHERE mc.sku = COALESCE(cs.sku_name, s.item_description)
        ORDER BY mc.financial_year DESC
        `,
        [skuId],
      ),

      // Per-component grape price via the 4-level cascade.
      // Uses get_effective_grape_price_v2() from schema/100 to also return level_matched
      // (0..4) so the UI can render "matched on region+color+grade+variety" vs "fell back to
      // region only" — the AC6 explainability requirement.
      pool.query(
        `
        WITH components AS (
          SELECT
            wb.region,
            wb.color,
            wb.variety,
            wb.vintage,
            SUM(ABS(pv.volume_litres)) AS volume_litres,
            SUM(ABS(pv.volume_litres)) /
              NULLIF(SUM(SUM(ABS(pv.volume_litres))) OVER (), 0) AS proportion
          FROM packaging_vessel pv
          JOIN packaging_operation po ON po.id = pv.packaging_operation_id
          JOIN vessel v               ON v.id = pv.vessel_id
          JOIN wine_batch wb          ON wb.id = v.wine_batch_id
          WHERE po.sku_id = $1
            AND wb.variety IS NOT NULL
          GROUP BY wb.region, wb.color, wb.variety, wb.vintage
        )
        SELECT
          c.region, c.color, c.variety, c.vintage, c.proportion,
          gp.price_per_ton, gp.level_matched, gp.rule_id
        FROM components c
        LEFT JOIN LATERAL get_effective_grape_price_v2(
          c.region, c.color, NULL::int, c.variety, c.vintage
        ) gp ON true
        ORDER BY c.proportion DESC NULLS LAST
        `,
        [skuId],
      ),

      // Live economic_cogs_per_unit averaged from sales (12m), NULL when missing.
      pool.query(
        `
        SELECT AVG(economic_cogs_per_unit) AS avg_econ_cogs
        FROM sales_transaction_normalized
        WHERE sku_id = $1
          AND economic_cogs_per_unit IS NOT NULL
          AND quantity > 0
          AND sale_date >= CURRENT_DATE - interval '12 months'
        `,
        [skuId],
      ),
    ]);

    if (skuMeta.rows.length === 0) {
      return NextResponse.json({ error: 'SKU not found' }, { status: 404 });
    }
    const sku = skuMeta.rows[0];
    const econAvg = economic.rows[0]?.avg_econ_cogs;

    return NextResponse.json({
      sku: {
        sku_id: sku.sku_id,
        sku_code: sku.sku_code,
        item_description: sku.item_description,
        canonical_sku_name: sku.canonical_sku_name,
        range_name: sku.range_name,
        variety: sku.variety,
        region: sku.region,
        vintage: sku.vintage,
      },
      master_cogs: masterCogs.rows.map((r) => ({
        id: r.id,
        sku: r.sku,
        financial_year: r.financial_year,
        cogs_value: parseFloat(r.cogs_value),
      })),
      cascade: cascadeRows.rows.map((r) => ({
        region: r.region,
        color: r.color,
        variety: r.variety,
        vintage: r.vintage,
        proportion: r.proportion === null ? null : parseFloat(r.proportion),
        price_per_ton: r.price_per_ton === null ? null : parseFloat(r.price_per_ton),
        // level_matched: 4 = region+color+grade+variety; 1 = region-only fallback; 0 = wildcard rule
        level_matched: r.level_matched === null ? null : parseInt(r.level_matched),
        rule_id: r.rule_id === null ? null : parseInt(r.rule_id),
      })),
      economic_cogs_per_unit: econAvg === null || econAvg === undefined ? null : parseFloat(econAvg),
    });
  } catch (err) {
    console.error('[/api/wines/cogs] Error:', err);
    return NextResponse.json({ error: 'Failed to load COGS data' }, { status: 500 });
  }
}
