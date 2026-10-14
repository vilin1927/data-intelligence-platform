export const dynamic = 'force-dynamic';

/**
 * POST /api/admin/unmatched-skus/[id]/match
 *
 * B6b — JC-107 / JC-120: Apply a canonical_sku match for an unmatched sku.
 *
 * Body: {
 *   canonical_sku_id: number,
 *   suggested_canonical_sku_id?: number,
 *   score?: number,
 *   bucket?: string,                 // HIGH_CONFIDENCE_AUTO | REVIEW_NEEDED | NO_MATCH | MANUAL
 *   notes?: string,
 *   reviewer?: string                // 'admin' or operator email; 'system' for bulk auto-apply
 * }
 *
 * Actions (single transaction):
 *   1. UPDATE sku SET canonical_sku_id = $1 WHERE sku_id = $2 AND canonical_sku_id IS NULL
 *   2. INSERT INTO sku_match_review (...) action='matched'
 *
 * Returns 200 { success: true, sku_id, canonical_sku_id }
 *  400  invalid body
 *  404  sku not found
 *  409  sku already has a canonical
 *  404  canonical_sku not found
 *
 * Auth: protected by middleware.ts session cookie.
 *
 * Schema dependency: sku_match_review (schema/091_b6b_sku_match_review.sql).
 * If table missing, only the sku UPDATE is performed (no audit row).
 */

import { NextRequest, NextResponse } from 'next/server';
import getPool from '@/lib/db';

interface MatchBody {
  canonical_sku_id: number;
  suggested_canonical_sku_id?: number;
  score?: number;
  bucket?: string;
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

  let body: MatchBody;
  try {
    body = await request.json();
  } catch {
    return NextResponse.json({ error: 'Invalid JSON body' }, { status: 400 });
  }

  const {
    canonical_sku_id,
    suggested_canonical_sku_id,
    score,
    bucket,
    notes,
    reviewer,
  } = body;

  if (!canonical_sku_id || typeof canonical_sku_id !== 'number') {
    return NextResponse.json(
      { error: 'canonical_sku_id is required and must be a number' },
      { status: 400 }
    );
  }

  const client = await pool.connect();
  try {
    await client.query('BEGIN');

    const skuCheck = await client.query<{ sku_id: number; canonical_sku_id: number | null }>(
      `SELECT sku_id, canonical_sku_id FROM sku WHERE sku_id = $1`,
      [skuId]
    );
    if (skuCheck.rows.length === 0) {
      await client.query('ROLLBACK');
      return NextResponse.json({ error: 'SKU not found' }, { status: 404 });
    }
    if (skuCheck.rows[0].canonical_sku_id !== null) {
      await client.query('ROLLBACK');
      return NextResponse.json(
        {
          error: 'SKU already has a canonical match',
          current_canonical_sku_id: skuCheck.rows[0].canonical_sku_id,
        },
        { status: 409 }
      );
    }

    const canonicalCheck = await client.query<{ id: number }>(
      `SELECT id FROM canonical_sku WHERE id = $1`,
      [canonical_sku_id]
    );
    if (canonicalCheck.rows.length === 0) {
      await client.query('ROLLBACK');
      return NextResponse.json({ error: 'Canonical SKU not found' }, { status: 404 });
    }

    await client.query(
      `UPDATE sku SET canonical_sku_id = $1 WHERE sku_id = $2`,
      [canonical_sku_id, skuId]
    );

    const tableCheck = await client.query<{ exists: boolean }>(`
      SELECT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'public' AND table_name = 'sku_match_review'
      ) AS exists
    `);
    if (tableCheck.rows[0]?.exists) {
      await client.query(
        `INSERT INTO sku_match_review
           (sku_id, action, suggested_canonical_sku_id, applied_canonical_sku_id,
            score, reviewer, notes, bucket, reviewed_at)
         VALUES ($1, 'matched', $2, $3, $4, $5, $6, $7, NOW())`,
        [
          skuId,
          suggested_canonical_sku_id ?? null,
          canonical_sku_id,
          score ?? null,
          reviewer ?? 'admin',
          notes ?? null,
          bucket ?? null,
        ]
      );
    }

    await client.query('COMMIT');

    return NextResponse.json({
      success: true,
      sku_id: skuId,
      canonical_sku_id,
    });
  } catch (err) {
    await client.query('ROLLBACK');
    console.error('[/api/admin/unmatched-skus/[id]/match] POST error:', err);
    return NextResponse.json(
      { error: 'Failed to apply SKU match' },
      { status: 500 }
    );
  } finally {
    client.release();
  }
}
