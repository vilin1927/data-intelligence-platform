export const dynamic = 'force-dynamic';

import { NextRequest, NextResponse } from 'next/server';
import getPool from '@/lib/db';

/**
 * GET /api/reps/[repId]/customers
 *
 * transactions related to these two reps in order to make the correct
 * assignment. I'd need to see the customer and the suburb."
 *
 * Read-only listing of customers assigned to a rep, plus suburb / postcode /
 * channel / territory / last transaction date. Drives the expand-row accordion
 * on /reference?tab=reps.
 *
 * customer.canonical_rep_id → canonical_representative(id) is the Owner-master
 * link (schema/055 BUG-95). canonical_customer carries territory_name + channel
 * (schema/012). last_txn_date = MAX(sale_date) from sales_transaction_normalized
 * joined on customer_id.
 *
 * Returns 200 { customers: [...] } — empty array if rep has no customers.
 * Returns 400 if repId is not a positive integer.
 * Returns 500 on DB error.
 */

interface CustomerRow {
  customer_name: string;
  suburb: string | null;
  postcode: string | null;
  channel: string | null;
  territory_name: string | null;
  last_txn_date: string | null;
}

export async function GET(
  _request: NextRequest,
  { params }: { params: { repId: string } }
): Promise<NextResponse> {
  const repId = parseInt(params.repId, 10);

  if (!Number.isInteger(repId) || repId <= 0) {
    return NextResponse.json(
      { error: 'Invalid rep id — must be a positive integer' },
      { status: 400 }
    );
  }

  try {
    const pool = getPool();

    const result = await pool.query<CustomerRow>(
      `SELECT
         c.customer_name,
         c.suburb,
         c.postcode,
         cc.channel,
         cc.territory_name,
         to_char(lt.last_txn_date, 'YYYY-MM-DD') AS last_txn_date
       FROM customer c
       LEFT JOIN canonical_customer cc
         ON cc.id = c.canonical_customer_id
       LEFT JOIN (
         SELECT customer_id, MAX(sale_date) AS last_txn_date
         FROM sales_transaction_normalized
         WHERE quantity > 0
         GROUP BY customer_id
       ) lt ON lt.customer_id = c.customer_id
       WHERE c.canonical_rep_id = $1
       ORDER BY c.suburb NULLS LAST, c.customer_name`,
      [repId]
    );

    return NextResponse.json({
      customers: result.rows.map((r) => ({
        customer_name: r.customer_name,
        suburb: r.suburb || '',
        postcode: r.postcode || '',
        channel: r.channel || '',
        territory_name: r.territory_name || '',
        last_txn_date: r.last_txn_date,
      })),
    });
  } catch (err) {
    console.error('[/api/reps/[repId]/customers] GET error:', err);
    return NextResponse.json(
      { error: 'Failed to load rep customers' },
      { status: 500 }
    );
  }
}
