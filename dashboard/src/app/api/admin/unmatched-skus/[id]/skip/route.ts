export const dynamic = 'force-dynamic';

/**
 * POST /api/admin/unmatched-skus/[id]/skip
 *
 * B6b — JC-107: Mark an unmatched SKU as "skipped" — reviewer has seen it
 * and decided not to link a canonical now (likely needs the owner input or is
 * an obsolete code that should never get a canonical).
 *
 * Body: { notes?: string, reviewer?: string }
 *
 * Action:
 *   - INSERT INTO sku_match_review (...) action='skipped'
 *   - DOES NOT change sku.canonical_sku_id
 *
 * Returns 200 { success, sku_id }
 *  404  sku not found
 *  501  sku_match_review table missing (apply schema/091)
 *
 * Auth: protected by middleware.ts session cookie.
 */

import { NextRequest, NextResponse } from 'next/server';
import getPool from '@/lib/db';

interface SkipBody {
  notes?: string;
  reviewer?: string;
}

export async function POST(
  request: NextRequest,
  { params }: { params: { id: string } }
): Promise<NextResponse> {
  const pool = getPool();
  const skuId = parseInt(params.id, 10);

  if (isNaN(skuId)) {
    return NextResponse.json({ error: 'Invalid sku id' }, { status: 400 });
  }

  let body: SkipBody = {};
  try {
    const text = await request.text();
    if (text.trim()) {
      body = JSON.parse(text);
    }
  } catch {
    return NextResponse.json({ error: 'Invalid JSON body' }, { status: 400 });
  }

  const { notes, reviewer } = body;

  try {
    const skuCheck = await pool.query<{ sku_id: number }>(
      `SELECT sku_id FROM sku WHERE sku_id = $1`,
      [skuId]
    );
    if (skuCheck.rows.length === 0) {
      return NextResponse.json({ error: 'SKU not found' }, { status: 404 });
    }

    const tableCheck = await pool.query<{ exists: boolean }>(`
      SELECT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'public' AND table_name = 'sku_match_review'
      ) AS exists
    `);
    if (!tableCheck.rows[0]?.exists) {
      return NextResponse.json(
        {
          error: 'SKU match review table is not available. Contact an administrator.',
        },
        { status: 501 }
      );
    }

    await pool.query(
      `INSERT INTO sku_match_review
         (sku_id, action, suggested_canonical_sku_id, applied_canonical_sku_id,
          score, reviewer, notes, bucket, reviewed_at)
       VALUES ($1, 'skipped', NULL, NULL, NULL, $2, $3, NULL, NOW())`,
      [skuId, reviewer ?? 'admin', notes ?? null]
    );

    return NextResponse.json({ success: true, sku_id: skuId });
  } catch (err) {
    console.error('[/api/admin/unmatched-skus/[id]/skip] POST error:', err);
    return NextResponse.json(
      { error: 'Failed to record skip' },
      { status: 500 }
    );
  }
}
