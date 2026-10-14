export const dynamic = 'force-dynamic';

import { NextResponse } from 'next/server';
import getPool from '@/lib/db';

/**
 * GET /api/reference
 * Returns reference data for forms: territories, channels, customer groups.
 */
export async function GET() {
  try {
    const pool = getPool();

    const [territories, channels, groups, varieties, regions, reps] = await Promise.all([
      // BUG-72: switched source from legacy `territory` (40 rows, id 6..98) to
      // canonical_territory (30 rows, id 1..30) so the dropdown IDs match
      // representative.territory_id after the schema/044 FK swap.
      pool.query('SELECT id AS territory_id, territory_name FROM canonical_territory ORDER BY territory_name'),
      pool.query('SELECT channel_id, channel_name FROM channel ORDER BY channel_name'),
      pool.query('SELECT DISTINCT customer_group FROM customer WHERE customer_group IS NOT NULL ORDER BY customer_group LIMIT 200'),
      pool.query('SELECT DISTINCT variety FROM sku WHERE variety IS NOT NULL ORDER BY variety'),
      pool.query('SELECT DISTINCT region FROM sku WHERE region IS NOT NULL ORDER BY region'),
      pool.query('SELECT rep_id, rep_name, territory_id FROM representative WHERE active = true ORDER BY rep_name'),
    ]);

    return NextResponse.json({
      territories: territories.rows.map(r => ({ id: r.territory_id, name: r.territory_name })),
      channels: channels.rows.map(r => ({ id: r.channel_id, name: r.channel_name })),
      groups: groups.rows.map(r => r.customer_group),
      varieties: varieties.rows.map(r => r.variety),
      regions: regions.rows.map(r => r.region),
      reps: reps.rows.map(r => ({ id: r.rep_id, name: r.rep_name, territory_id: r.territory_id || null })),
    });
  } catch (err) {
    console.error('[/api/reference] Error:', err);
    return NextResponse.json({ error: 'Failed to load reference data' }, { status: 500 });
  }
}
