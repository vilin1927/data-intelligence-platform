export const dynamic = 'force-dynamic';

import { NextRequest, NextResponse } from 'next/server';
import getPool from '@/lib/db';

/**
 * POST /api/upload/save-match
 * Persists a customer or SKU mapping to the database immediately,
 * so matches survive import failures and re-uploads.
 *
 * Body: {
 *   type: 'customer' | 'sku',
 *   source_system: string,        // 'dws', 'alm', 'direct'
 *   external_code: string,        // external_name for customers, external_code for SKUs
 *   internal_id: number           // customer_id or sku_id
 * }
 */
export async function POST(request: NextRequest) {
  try {
    const pool = getPool();
    const body = await request.json();
    const { type, source_system, external_code, internal_id } = body as {
      type: 'customer' | 'sku';
      source_system: string;
      external_code: string;
      internal_id: number;
    };

    // Validate inputs
    if (!type || !['customer', 'sku'].includes(type)) {
      return NextResponse.json({ error: 'Invalid type. Must be "customer" or "sku".' }, { status: 400 });
    }
    if (!source_system || !['dws', 'alm', 'direct'].includes(source_system.toLowerCase())) {
      return NextResponse.json({ error: 'Invalid source_system.' }, { status: 400 });
    }
    if (!external_code || !external_code.trim()) {
      return NextResponse.json({ error: 'external_code is required.' }, { status: 400 });
    }
    if (!internal_id || typeof internal_id !== 'number') {
      return NextResponse.json({ error: 'internal_id must be a number.' }, { status: 400 });
    }

    const system = source_system.toLowerCase();

    if (type === 'customer') {
      await pool.query(
        `INSERT INTO customer_code_map (customer_id, source_system, external_name)
         VALUES ($1, $2, $3)
         ON CONFLICT (source_system, external_name) DO UPDATE SET customer_id = $1`,
        [internal_id, system, external_code.trim()]
      );
    } else {
      await pool.query(
        `INSERT INTO sku_code_map (sku_id, source_system, external_code)
         VALUES ($1, $2, $3)
         ON CONFLICT (source_system, external_code) DO UPDATE SET sku_id = $1`,
        [internal_id, system, external_code.trim()]
      );
    }

    return NextResponse.json({ success: true });
  } catch (err) {
    console.error('[/api/upload/save-match] Error:', err);
    return NextResponse.json(
      { error: err instanceof Error ? err.message : 'Failed to save match' },
      { status: 500 }
    );
  }
}
