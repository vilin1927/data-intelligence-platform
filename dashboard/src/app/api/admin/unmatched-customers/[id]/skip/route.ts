export const dynamic = 'force-dynamic';

/**
 * POST /api/admin/unmatched-customers/[id]/skip
 *
 * CLARIFY-12: Mark an unmatched customer as "skipped" — reviewer has seen
 * it and decided not to match it now (e.g. needs the owner input, or is a
 * SAMPLES / test record that genuinely has no canonical).
 *
 * Body: {
 *   notes?: string,     // Optional reason for skipping
 *   reviewer?: string   // Reviewer email
 * }
 *
 * Action:
 * - Inserts a customer_match_review row with action='skipped'
 * - Does NOT update customer.canonical_customer_id (customer stays unmatched)
 *
 * Returns 200 { success: true, customer_id }
 * Returns 404 if customer not found
 * Returns 500 on DB error
 *
 * Auth: protected by middleware.ts session cookie.
 *
 * Schema dependency: customer_match_review from schema/080 must be applied.
 * If table missing, returns 501 Not Implemented (skip is audit-only).
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
  const customerId = parseInt(params.id, 10);

  if (isNaN(customerId)) {
    return NextResponse.json({ error: 'Invalid customer id' }, { status: 400 });
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
    // Check if customer exists
    const customerCheck = await pool.query<{ customer_id: number }>(
      `SELECT customer_id FROM customer WHERE customer_id = $1`,
      [customerId]
    );

    if (customerCheck.rows.length === 0) {
      return NextResponse.json({ error: 'Customer not found' }, { status: 404 });
    }

    // Check if audit table exists
    const tableCheck = await pool.query<{ exists: boolean }>(`
      SELECT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'public' AND table_name = 'customer_match_review'
      ) AS exists
    `);

    if (!tableCheck.rows[0]?.exists) {
      return NextResponse.json(
        {
          error: 'Customer match review table is not available. Contact an administrator.',
        },
        { status: 501 }
      );
    }

    // Insert skip record
    await pool.query(
      `INSERT INTO customer_match_review
         (customer_id, action, suggested_canonical_id, applied_canonical_id,
          score, reviewer, notes, bucket, reviewed_at)
       VALUES ($1, 'skipped', NULL, NULL, NULL, $2, $3, NULL, NOW())`,
      [customerId, reviewer ?? 'admin', notes ?? null]
    );

    return NextResponse.json({ success: true, customer_id: customerId });
  } catch (err) {
    console.error('[/api/admin/unmatched-customers/[id]/skip] POST error:', err);
    return NextResponse.json(
      { error: 'Failed to record skip' },
      { status: 500 }
    );
  }
}
