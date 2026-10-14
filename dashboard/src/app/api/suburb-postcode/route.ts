export const dynamic = 'force-dynamic';

import { NextRequest, NextResponse } from 'next/server';
import getPool from '@/lib/db';

/**
 * GET /api/suburb-postcode?suburb=Young
 *
 * JF-24: Suburb → postcode auto-populate for the New Customer form.
 * Returns matching postcodes from the au_postcode reference table.
 * Prefers "Delivery Area" type entries (real suburbs, not PO boxes).
 *
 * Response: { results: [{ postcode, locality, state }] }
 */
export async function GET(request: NextRequest) {
  try {
    const pool = getPool();
    const suburb = request.nextUrl.searchParams.get('suburb')?.trim();

    if (!suburb || suburb.length < 2) {
      return NextResponse.json({ results: [] });
    }

    // Try exact match first (case-insensitive), prefer Delivery Area
    const exact = await pool.query(
      `SELECT postcode, locality, state
       FROM au_postcode
       WHERE LOWER(locality) = LOWER($1)
       ORDER BY
         CASE WHEN type = 'Delivery Area' THEN 0 ELSE 1 END,
         postcode
       LIMIT 5`,
      [suburb]
    );

    if (exact.rows.length > 0) {
      return NextResponse.json({
        results: exact.rows.map(r => ({
          postcode: r.postcode,
          locality: r.locality,
          state: r.state,
        })),
      });
    }

    // Fallback: prefix match for partial suburb entry
    const prefix = await pool.query(
      `SELECT postcode, locality, state
       FROM au_postcode
       WHERE LOWER(locality) LIKE LOWER($1)
       ORDER BY
         CASE WHEN type = 'Delivery Area' THEN 0 ELSE 1 END,
         locality,
         postcode
       LIMIT 10`,
      [`${suburb}%`]
    );

    return NextResponse.json({
      results: prefix.rows.map(r => ({
        postcode: r.postcode,
        locality: r.locality,
        state: r.state,
      })),
    });
  } catch (err) {
    console.error('[/api/suburb-postcode] GET error:', err);
    return NextResponse.json({ error: 'Failed to lookup postcode' }, { status: 500 });
  }
}
