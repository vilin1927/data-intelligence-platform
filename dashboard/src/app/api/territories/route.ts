export const dynamic = 'force-dynamic';

import { NextRequest, NextResponse } from 'next/server';
import getPool from '@/lib/db';

/**
 * GET /api/territories?search=term
 * Returns canonical territories with customer_count and distinct rep_names,
 * case-insensitive join against canonical_customer.territory_name to surface drift.
 *
 * Also returns `unmatched_territories` — distinct territory_name values that appear
 * in canonical_customer but do NOT map to any canonical_territory row (drift debt).
 *
 * Used by the Territories tab on /reference for spot-checking.
 */
export async function GET(request: NextRequest) {
  try {
    const pool = getPool();
    const search = (request.nextUrl.searchParams.get('search') || '').trim();

    const params: string[] = [];
    let whereClause = '';
    if (search.length >= 2) {
      whereClause = `WHERE LOWER(ct.territory_name) LIKE LOWER($1)`;
      params.push(`%${search}%`);
    }

    // Canonical territories with aggregates
    const result = await pool.query(
      `SELECT
         ct.id,
         ct.territory_name,
         COALESCE(cust.customer_count, 0) AS customer_count,
         COALESCE(cust.rep_names, ARRAY[]::text[]) AS rep_names,
         COALESCE(reps.rep_count, 0) AS rep_count
       FROM canonical_territory ct
       LEFT JOIN (
         SELECT
           LOWER(cc.territory_name) AS tn_lower,
           COUNT(*) AS customer_count,
           ARRAY_AGG(DISTINCT cc.rep_name) FILTER (WHERE cc.rep_name IS NOT NULL) AS rep_names
         FROM canonical_customer cc
         WHERE cc.territory_name IS NOT NULL
         GROUP BY LOWER(cc.territory_name)
       ) cust ON cust.tn_lower = LOWER(ct.territory_name)
       LEFT JOIN (
         SELECT
           r.territory_id,
           COUNT(*) AS rep_count
         FROM representative r
         WHERE r.territory_id IS NOT NULL
         GROUP BY r.territory_id
       ) reps ON reps.territory_id = ct.id
       ${whereClause}
       ORDER BY ct.territory_name`,
      params
    );

    // Unmatched drift: distinct territory_name from customers that has no
    // case-insensitive equivalent in canonical_territory
    const driftResult = await pool.query(
      `SELECT cc.territory_name, COUNT(*) AS customer_count
       FROM canonical_customer cc
       WHERE cc.territory_name IS NOT NULL
         AND NOT EXISTS (
           SELECT 1 FROM canonical_territory ct
           WHERE LOWER(ct.territory_name) = LOWER(cc.territory_name)
         )
       GROUP BY cc.territory_name
       ORDER BY COUNT(*) DESC, cc.territory_name`
    );

    const countResult = await pool.query('SELECT COUNT(*) FROM canonical_territory');

    return NextResponse.json({
      territories: result.rows.map((r) => ({
        id: r.id,
        name: r.territory_name,
        customer_count: parseInt(r.customer_count, 10) || 0,
        rep_count: parseInt(r.rep_count, 10) || 0,
        rep_names: (r.rep_names as string[]) || [],
      })),
      unmatched_territories: driftResult.rows.map((r) => ({
        name: r.territory_name,
        customer_count: parseInt(r.customer_count, 10) || 0,
      })),
      total: parseInt(countResult.rows[0].count, 10),
      filtered: result.rows.length,
    });
  } catch (err) {
    console.error('[/api/territories] GET error:', err);
    return NextResponse.json({ error: 'Failed to load territories' }, { status: 500 });
  }
}
