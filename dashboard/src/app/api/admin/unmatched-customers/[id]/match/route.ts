export const dynamic = 'force-dynamic';

/**
 * POST /api/admin/unmatched-customers/[id]/match
 *
 * CLARIFY-12: Apply a canonical_customer match for an unmatched customer.
 *
 * Body: {
 *   canonical_customer_id: number,   // The canonical to link to
 *   suggested_canonical_id?: number, // The algo-suggested canonical (may differ)
 *   score?: number,                  // Fuzzy score at decision time
 *   bucket?: string,                 // HIGH_CONFIDENCE_AUTO | REVIEW_NEEDED | NO_MATCH
 *   notes?: string,                  // Optional reviewer notes
 *   reviewer?: string                // Reviewer email / 'system' for bulk auto-apply
 * }
 *
 * Actions:
 * 1. UPDATE customer SET canonical_customer_id = $canonical_customer_id WHERE customer_id = $id
 * 2. INSERT INTO customer_match_review (audit log)
 *
 * Returns 200 { success: true, customer_id, canonical_customer_id }
 * Returns 400 if body is invalid
 * Returns 404 if customer not found or already matched
 * Returns 500 on DB error
 *
 * Auth: protected by middleware.ts session cookie.
 *
 * Schema dependency: customer_match_review from schema/080 must be applied.
 * If table missing, only the customer UPDATE is performed (no audit log).
 */

import { NextRequest, NextResponse } from 'next/server';
import getPool from '@/lib/db';

interface MatchBody {
  canonical_customer_id: number;
  suggested_canonical_id?: number;
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
  const customerId = parseInt(params.id, 10);

  if (isNaN(customerId)) {
    return NextResponse.json({ error: 'Invalid customer id' }, { status: 400 });
  }

  let body: MatchBody;
  try {
    body = await request.json();
  } catch {
    return NextResponse.json({ error: 'Invalid JSON body' }, { status: 400 });
  }

  const { canonical_customer_id, suggested_canonical_id, score, bucket, notes, reviewer } = body;

  if (!canonical_customer_id || typeof canonical_customer_id !== 'number') {
    return NextResponse.json(
      { error: 'canonical_customer_id is required and must be a number' },
      { status: 400 }
    );
  }

  const client = await pool.connect();
  try {
    await client.query('BEGIN');

    // 1. Verify the customer exists and is currently unmatched
    const customerCheck = await client.query<{ customer_id: number; canonical_customer_id: number | null }>(
      `SELECT customer_id, canonical_customer_id FROM customer WHERE customer_id = $1`,
      [customerId]
    );

    if (customerCheck.rows.length === 0) {
      await client.query('ROLLBACK');
      return NextResponse.json({ error: 'Customer not found' }, { status: 404 });
    }

    if (customerCheck.rows[0].canonical_customer_id !== null) {
      await client.query('ROLLBACK');
      return NextResponse.json(
        {
          error: 'Customer already has a canonical match',
          current_canonical_id: customerCheck.rows[0].canonical_customer_id,
        },
        { status: 409 }
      );
    }

    // 2. Verify the canonical customer exists and is active
    const canonicalCheck = await client.query<{ id: number }>(
      `SELECT id FROM canonical_customer WHERE id = $1 AND is_active = TRUE`,
      [canonical_customer_id]
    );

    if (canonicalCheck.rows.length === 0) {
      await client.query('ROLLBACK');
      return NextResponse.json(
        { error: 'Canonical customer not found or inactive' },
        { status: 404 }
      );
    }

    // 3. Apply the match
    await client.query(
      `UPDATE customer SET canonical_customer_id = $1, updated_at = NOW() WHERE customer_id = $2`,
      [canonical_customer_id, customerId]
    );

    // 4. Write audit log (if table exists)
    const tableCheck = await client.query<{ exists: boolean }>(`
      SELECT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'public' AND table_name = 'customer_match_review'
      ) AS exists
    `);

    if (tableCheck.rows[0]?.exists) {
      await client.query(
        `INSERT INTO customer_match_review
           (customer_id, action, suggested_canonical_id, applied_canonical_id,
            score, reviewer, notes, bucket, reviewed_at)
         VALUES ($1, 'matched', $2, $3, $4, $5, $6, $7, NOW())`,
        [
          customerId,
          suggested_canonical_id ?? null,
          canonical_customer_id,
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
      customer_id: customerId,
      canonical_customer_id,
    });
  } catch (err) {
    await client.query('ROLLBACK');
    console.error('[/api/admin/unmatched-customers/[id]/match] POST error:', err);
    return NextResponse.json(
      { error: 'Failed to apply customer match' },
      { status: 500 }
    );
  } finally {
    client.release();
  }
}
