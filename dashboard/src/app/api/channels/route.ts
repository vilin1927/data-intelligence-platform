export const dynamic = 'force-dynamic';

import { NextResponse } from 'next/server';
import getPool from '@/lib/db';

/**
 * B11 — GET /api/channels
 *
 * Returns the 6 D2 venue channels that combined_data_enriched.channel
 * canonicalises to (JC-076 + JC-078):
 *
 *   DIRECT, HOFFICE, HYBRID, OFF PREMISE, ON PREMISE, WHOLESALE
 *
 * (No ALM — ALM is the D1 warehouse axis, not a venue type. ALM rows live
 * under `warehouse=ALM` in combined_data; the channel filter dropdown is
 * the venue dimension only.)
 *
 * Source of truth: `SELECT DISTINCT channel FROM combined_data_enriched
 * WHERE channel <> ''` after schema/090 view refactor. The hard-coded
 * fallback below is the JC-077/JC-078 canonical list — used only if the
 * view query returns 0 rows (cold-start or empty DB), so the dropdown is
 * never empty.
 */
const CANONICAL_VENUE_CHANNELS = [
  'DIRECT',
  'HOFFICE',
  'HYBRID',
  'OFF PREMISE',
  'ON PREMISE',
  'WHOLESALE',
] as const;

export async function GET() {
  try {
    const pool = getPool();
    const result = await pool.query(
      `SELECT DISTINCT channel
         FROM combined_data_enriched
        WHERE channel IS NOT NULL
          AND channel <> ''
        ORDER BY channel`
    );
    const fromDb = result.rows.map((r: { channel: string }) => r.channel);
    const channels =
      fromDb.length > 0 ? fromDb : [...CANONICAL_VENUE_CHANNELS];

    return NextResponse.json({
      channels,
      count: channels.length,
      source: fromDb.length > 0 ? 'combined_data_enriched' : 'fallback',
    });
  } catch (err) {
    // Never fail the dropdown — fall back to the canonical list.
    console.error('[/api/channels] DB query failed, returning canonical fallback', err);
    return NextResponse.json({
      channels: [...CANONICAL_VENUE_CHANNELS],
      count: CANONICAL_VENUE_CHANNELS.length,
      source: 'fallback',
    });
  }
}
