export const dynamic = 'force-dynamic';

import { NextResponse } from 'next/server';
import getPool from '@/lib/db';

/**
 * GET /api/what-if
 * Returns base data for the What-If Grape Price Calculator:
 * - SKUs with grape composition (via traceability chain)
 * - Current grape_price_rule entries
 * - Reference data for dropdowns
 */
export async function GET() {
  try {
    const pool = getPool();

    const [skuResult, grapeComposition, priceRules, refData] = await Promise.all([
      // 1. SKU base data with 12-month revenue
      pool.query(`
        SELECT
          s.sku_id,
          s.sku_code,
          s.item_description,
          s.variety,
          s.variety_code,
          COALESCE(mro.region, s.region) AS region,
          s.vintage,
          s.base_wholesale,
          s.transfer_cost,
          cs.range_name,
          COALESCE(rev.total_revenue, 0)::numeric(12,2) as total_revenue_12m,
          COALESCE(rev.total_qty, 0) as total_qty_12m
        FROM sku s
        LEFT JOIN canonical_sku cs ON cs.id = s.canonical_sku_id
        LEFT JOIN manual_region_override mro ON mro.sku_id = s.sku_id
        LEFT JOIN LATERAL (
          SELECT
            SUM(st.net_revenue) as total_revenue,
            SUM(st.quantity_cases) as total_qty
          FROM sales_transaction_normalized st
          WHERE st.sku_id = s.sku_id
            AND st.sale_date >= CURRENT_DATE - interval '12 months'
            AND st.quantity > 0
        ) rev ON true
        WHERE s.variety IS NOT NULL
        ORDER BY COALESCE(rev.total_revenue, 0) DESC
      `),

      // 2. Grape composition per SKU via traceability chain
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

      // 3. Current grape price rules
      pool.query(`
        SELECT id, region, color, grade, variety, vintage, price_per_ton
        FROM grape_price_rule
        ORDER BY vintage DESC, region, color, grade, variety
      `),

      // 4. Reference data for dropdowns
      // B3-region (2026-05-10): regions UNIONs region_ref master so master regions
      // (e.g. 'Canberra') surface in the dropdown even when 0 SKUs map to them
      // yet — per the owner May 8 PDF p2-3 "Need to include Canberra as a region" +
      // dropdown spec. SKU-to-Canberra mapping deferred to Q8 in
      // (xlsx 0 Canberra region rows, no HARD verbal naming Canberra SKUs).
      // Pairs with schema/148_b3_region_canberra_assign.sql (ledger-only).
      // B5 (2026-05-11): vintages UNION generate_series(2006..currentYear) so
      // dropdown always covers the owner's PDF p3 ask "vintage range 2006+" even
      // when sku table has narrow vintage span. No fabricated SKU data —
      // dropdown options only; cascade still falls back to nearest real rule
      // per getEffectiveGrapePrice. Style list hardcoded Red/White/Rose/
      // Sparkling on frontend (GrapePriceCalculator.tsx:82) — no API change.
      pool.query(`
        SELECT
          ARRAY(
            SELECT DISTINCT region FROM (
              SELECT region FROM sku WHERE region IS NOT NULL
              UNION
              SELECT region_name AS region FROM region_ref
            ) r ORDER BY region
          ) as regions,
          ARRAY(SELECT DISTINCT variety FROM sku WHERE variety IS NOT NULL ORDER BY variety) as varieties,
          ARRAY(
            SELECT DISTINCT vintage FROM (
              SELECT vintage FROM sku WHERE vintage IS NOT NULL
              UNION
              SELECT generate_series(2006, EXTRACT(YEAR FROM CURRENT_DATE)::int) AS vintage
            ) v ORDER BY vintage DESC
          ) as vintages
      `),
    ]);

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

    // Build SKU response with grape components
    const skus = skuResult.rows.map(sku => ({
      sku_id: sku.sku_id,
      sku_code: sku.sku_code,
      item_description: sku.item_description,
      variety: sku.variety,
      region: sku.region,
      vintage: sku.vintage,
      base_wholesale: parseFloat(sku.base_wholesale) || 0,
      transfer_cost: parseFloat(sku.transfer_cost) || 0,
      range_name: sku.range_name,
      total_revenue_12m: parseFloat(sku.total_revenue_12m) || 0,
      total_qty_12m: parseInt(sku.total_qty_12m) || 0,
      // Use traceability chain if available, otherwise fall back to SKU's own data
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
      grape_price_rules: priceRules.rows.map(r => ({
        ...r,
        price_per_ton: parseFloat(r.price_per_ton),
      })),
      regions: refData.rows[0]?.regions || [],
      varieties: refData.rows[0]?.varieties || [],
      vintages: refData.rows[0]?.vintages || [],
    });
  } catch (err) {
    console.error('[/api/what-if] Error:', err);
    return NextResponse.json(
      { error: 'Failed to load what-if data' },
      { status: 500 }
    );
  }
}

/**
 * POST /api/what-if
 * "Apply to data" — persists grape price rules and triggers COGS recalculation.
 *
 * Body: { rules: [{ region, color, grade, variety, vintage, price_per_ton }] }
 *
 * BUG-18 (CRITICAL #5 from 2026-04-11 CTO audit, combines DASH-04 + ETL-04):
 * This handler used to run three statements with no transaction wrapping:
 *   (1) a loop of DELETE+INSERT per rule, each autocommitting,
 *   (2) an UNCONDITIONAL full-table wipe of economic_cogs_* (no WHERE),
 *   (3) a recalculation CTE.
 * Any failure between (1) and (3) left the DB in a broken state for weeks.
 *
 * The handler now:
 *   - runs everything in a single BEGIN / COMMIT / ROLLBACK transaction on one client,
 *   - computes affected_sku_ids from the incoming rules,
 *   - refuses (409 Conflict) any request that touches rows whose
 *     economic_cogs_lock_date IS NOT NULL (ADR-006 — "Once locked at bottling,
 *     prices are immutable"),
 *   - replaces the unconditional NULL UPDATE with a targeted one scoped to
 *     affected_sku_ids AND economic_cogs_lock_date IS NULL,
 *   - scopes the recalculation CTE to the same affected SKU set.
 *
 * Idempotency: a retry after success is safe because the precheck + targeted
 * UPDATE is deterministic over the same rules payload — the same rows get
 * NULL'd and re-derived to the same values, and the recalculate row count
 * reflects the current affected set, not a growing total.
 */
export async function POST(request: Request) {
  const pool = getPool();
  let body: { rules?: unknown };
  try {
    body = await request.json();
  } catch {
    return NextResponse.json(
      { error: 'Invalid JSON body' },
      { status: 400 }
    );
  }

  const rules = (body as { rules?: unknown }).rules;

  if (!Array.isArray(rules) || rules.length === 0) {
    return NextResponse.json(
      { error: 'rules array required' },
      { status: 400 }
    );
  }

  // AUD-01: Server-side validation — reject negative or absurd grape prices
  for (const rule of rules) {
    if (rule && typeof (rule as { price_per_ton?: unknown }).price_per_ton === 'number') {
      const p = (rule as { price_per_ton: number }).price_per_ton;
      if (p < 0 || p > 10000) {
        return NextResponse.json(
          { error: `Invalid grape price: $${p}/ton. Must be between $0 and $10,000.` },
          { status: 400 }
        );
      }
    }
  }

  // Rules that actually get applied (vintage + price_per_ton required).
  // Anything incomplete is dropped up-front so affected_sku_ids stays tight.
  type AppliedRule = {
    region: string | null;
    color: string | null;
    grade: number | null;
    variety: string | null;
    vintage: number;
    price_per_ton: number;
  };
  const appliedRules: AppliedRule[] = [];
  for (const r of rules) {
    const rule = r as {
      region?: string | null;
      color?: string | null;
      grade?: number | null;
      variety?: string | null;
      vintage?: number;
      price_per_ton?: number;
    };
    if (!rule.vintage || typeof rule.price_per_ton !== 'number') continue;
    appliedRules.push({
      region: rule.region || null,
      color: rule.color || null,
      grade: rule.grade ?? null,
      variety: rule.variety || null,
      vintage: rule.vintage,
      price_per_ton: rule.price_per_ton,
    });
  }

  if (appliedRules.length === 0) {
    return NextResponse.json(
      { error: 'No applicable rules — each rule needs vintage and price_per_ton' },
      { status: 400 }
    );
  }

  // Vintages that any incoming rule targets. Used to derive affected SKUs via
  // sale_vintage_attribution (same join the recalculation CTE uses).
  const ruleVintages = Array.from(new Set(appliedRules.map(r => r.vintage)));

  const client = await pool.connect();
  try {
    await client.query('BEGIN');

    // Step 0: derive affected_sku_ids — every SKU that has at least one sale
    // whose attributed_vintage matches one of the rule vintages. This is a
    // strict superset of what the cascade could actually re-price, but is
    // bounded by the rule payload, so the targeted UPDATE below cannot wipe
    // rows that these rules can never reach.
    const affectedRes = await client.query(
      `
        SELECT DISTINCT st.sku_id
        FROM sales_transaction_normalized st
        JOIN sale_vintage_attribution sva
          ON sva.sales_transaction_id = st.transaction_id
        WHERE sva.attributed_vintage = ANY($1::int[])
          AND st.sku_id IS NOT NULL
      `,
      [ruleVintages]
    );
    const affectedSkuIds: number[] = affectedRes.rows
      .map(r => r.sku_id)
      .filter((id: number | null) => id != null);

    // Step 1: ADR-006 lock guard. If any affected row is bottling-locked, the
    // whole Apply is refused with the list of locked SKUs — nothing mutated.
    if (affectedSkuIds.length > 0) {
      const lockedRes = await client.query(
        `
          SELECT DISTINCT st.sku_id, s.sku_code
          FROM sales_transaction_normalized st
          LEFT JOIN sku s ON s.sku_id = st.sku_id
          WHERE st.sku_id = ANY($1::int[])
            AND st.economic_cogs_lock_date IS NOT NULL
          ORDER BY st.sku_id
        `,
        [affectedSkuIds]
      );
      if (lockedRes.rows.length > 0) {
        await client.query('ROLLBACK');
        return NextResponse.json(
          {
            error: 'economic_cogs_lock_date guard: one or more affected SKUs have bottling-locked rows',
            locked_skus: lockedRes.rows.map(r => ({
              sku_id: r.sku_id,
              sku_code: r.sku_code,
            })),
          },
          { status: 409 }
        );
      }
    }

    // Step 2: Upsert grape price rules (DELETE + INSERT to handle NULLs in unique constraint).
    // Runs on the transaction client so a partial loop rolls back cleanly.
    let rulesUpdated = 0;
    for (const rule of appliedRules) {
      await client.query(
        `
          DELETE FROM grape_price_rule
          WHERE COALESCE(region,'') = COALESCE($1,'')
            AND COALESCE(color,'') = COALESCE($2,'')
            AND COALESCE(grade,0) = COALESCE($3,0)
            AND COALESCE(variety,'') = COALESCE($4,'')
            AND vintage = $5
        `,
        [rule.region, rule.color, rule.grade, rule.variety, rule.vintage]
      );

      await client.query(
        `
          INSERT INTO grape_price_rule
            (region, color, grade, variety, vintage, price_per_ton, updated_at, created_by)
          VALUES ($1, $2, $3, $4, $5, $6, NOW(), 'what-if')
        `,
        [rule.region, rule.color, rule.grade, rule.variety, rule.vintage, rule.price_per_ton]
      );
      rulesUpdated++;
    }

    // Step 3: TARGETED clear of economic COGS — only rows belonging to
    // affected SKUs and not bottling-locked. Replaces the old unconditional
    // full-table wipe. The lock-guard above already guarantees no locked rows
    // are in the affected set, so the AND clause here is belt-and-braces.
    if (affectedSkuIds.length > 0) {
      await client.query(
        `
          UPDATE sales_transaction
             SET economic_cogs_per_unit = NULL,
                 economic_cogs_total    = NULL
           WHERE sku_id = ANY($1::int[])
             AND economic_cogs_lock_date IS NULL
        `,
        [affectedSkuIds]
      );
    }

    // Step 4: Recalculate COGS using the updated grape prices, scoped to the
    // same affected SKU set. Uses the same cascade logic as
    // calculate_economic_cogs.py. For each sale with vintage attribution:
    //   economic_cogs_per_unit = grape_price × TONS_PER_CASE (0.0125)
    let salesUpdated = 0;
    if (affectedSkuIds.length > 0) {
      const cogsResult = await client.query(
        `
          WITH sale_prices AS (
            SELECT
              st.transaction_id,
              st.quantity,
              st.quantity_cases,
              sva.attributed_vintage,
              s.variety,
              COALESCE(mro2.region, s.region) AS region,
              -- Cascade: try most specific grape price rule first.
              -- BUG-WINES-SKUS-REGION-BYPASS: use override-resolved region
              -- so cascade matches the same region the owner sees in /reference.
              COALESCE(
                (SELECT price_per_ton FROM grape_price_rule
                 WHERE COALESCE(region,'') = COALESCE(COALESCE(mro2.region, s.region),'')
                   AND COALESCE(variety,'') = COALESCE(s.variety,'')
                   AND vintage = sva.attributed_vintage
                 LIMIT 1),
                (SELECT price_per_ton FROM grape_price_rule
                 WHERE COALESCE(region,'') = COALESCE(COALESCE(mro2.region, s.region),'')
                   AND vintage = sva.attributed_vintage
                   AND variety IS NULL
                 LIMIT 1),
                (SELECT price_per_ton FROM grape_price_rule
                 WHERE COALESCE(region,'') = COALESCE(COALESCE(mro2.region, s.region),'')
                   AND variety IS NULL AND color IS NULL
                 ORDER BY ABS(vintage - sva.attributed_vintage)
                 LIMIT 1),
                (SELECT price_per_ton FROM grape_price_rule
                 ORDER BY ABS(vintage - sva.attributed_vintage)
                 LIMIT 1)
              ) as grape_price
            FROM sales_transaction_normalized st
            JOIN sale_vintage_attribution sva
              ON sva.sales_transaction_id = st.transaction_id
            JOIN sku s ON s.sku_id = st.sku_id
            LEFT JOIN manual_region_override mro2 ON mro2.sku_id = s.sku_id
            WHERE st.sku_id = ANY($1::int[])
              AND st.economic_cogs_lock_date IS NULL
          )
          UPDATE sales_transaction st
             SET economic_cogs_per_unit = sp.grape_price * 0.0125,
                 -- BUG-118 AC3: 0.0125 = tons/case; multiply by case-normalized
                 -- quantity (not raw st.quantity) so bottle-source rows compute
                 -- correctly. sp.quantity_cases is projected from the CTE above
                 -- which reads from sales_transaction_normalized.
                 economic_cogs_total    = sp.grape_price * 0.0125 * sp.quantity_cases
            FROM sale_prices sp
           WHERE st.transaction_id = sp.transaction_id
             AND sp.grape_price IS NOT NULL
        `,
        [affectedSkuIds]
      );
      salesUpdated = cogsResult.rowCount || 0;
    }

    // Step 5: Summary stats (still inside the transaction so the caller sees
    // the post-commit state and a retry after COMMIT is idempotent).
    const stats = await client.query(`
      SELECT
        COUNT(*) as total_sales,
        COUNT(economic_cogs_per_unit) as with_cogs,
        ROUND(AVG(economic_cogs_per_unit)::numeric, 2) as avg_cogs,
        ROUND(SUM(economic_cogs_total)::numeric, 2) as total_cogs,
        ROUND(SUM(net_revenue)::numeric, 2) as total_revenue
      FROM sales_transaction_normalized
    `);

    await client.query('COMMIT');

    const s = stats.rows[0];
    const totalRevenue = parseFloat(s.total_revenue) || 0;
    const totalCogs = parseFloat(s.total_cogs) || 0;
    const gpPct = totalRevenue > 0 ? ((totalRevenue - totalCogs) / totalRevenue * 100) : 0;

    return NextResponse.json({
      success: true,
      rules_updated: rulesUpdated,
      sales_recalculated: salesUpdated,
      affected_sku_count: affectedSkuIds.length,
      summary: {
        total_sales: parseInt(s.total_sales),
        with_cogs: parseInt(s.with_cogs),
        avg_cogs_per_unit: parseFloat(s.avg_cogs) || 0,
        total_economic_cogs: totalCogs,
        total_revenue: totalRevenue,
        overall_gp_pct: Math.round(gpPct * 10) / 10,
      },
    });
  } catch (err) {
    // Rollback on ANY failure — mid-loop DELETE, mid-loop INSERT, clear,
    // recalculate, or stats. DB state is unchanged from before the request.
    try {
      await client.query('ROLLBACK');
    } catch (rbErr) {
      console.error('[/api/what-if POST] Rollback failed:', rbErr);
    }
    console.error('[/api/what-if POST] Error:', err);
    const isDev = process.env.NODE_ENV !== 'production';
    const message = err instanceof Error ? err.message : String(err);
    return NextResponse.json(
      {
        error: 'Failed to apply grape prices',
        ...(isDev ? { detail: message } : {}),
      },
      { status: 500 }
    );
  } finally {
    client.release();
  }
}

function deriveColor(variety: string | null): string {
  if (!variety) return 'red';
  const v = variety.toLowerCase();
  const whites = ['chardonnay', 'riesling', 'sauvignon', 'pinot gris', 'pinot grigio',
    'moscato', 'prosecco', 'albarino', 'albariño', 'gewurztraminer', 'semillon'];
  return whites.some(w => v.includes(w)) ? 'white' : 'red';
}
