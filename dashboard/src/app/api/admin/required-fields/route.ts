/**
 * GET  /api/admin/required-fields?channel=dws → channel-specific JC-487
 *      required-field config from upload_required_field_toggle.
 * POST /api/admin/required-fields → update toggles (post-delivery override).
 *
 * Bundle B12 (JC-487).
 */

import { NextRequest, NextResponse } from 'next/server';
import { Pool } from 'pg';

export const dynamic = 'force-dynamic';

const VALID_CHANNELS = ['dws', 'alm', 'direct', 'ilg', 'ynr'] as const;
type Channel = (typeof VALID_CHANNELS)[number];

let pool: Pool | undefined;
function getPool(): Pool {
  if (!pool) pool = new Pool({ connectionString: process.env.DATABASE_URL });
  return pool;
}

export async function GET(request: NextRequest) {
  const url = new URL(request.url);
  const channel = (url.searchParams.get('channel') || '').toLowerCase();
  if (!VALID_CHANNELS.includes(channel as Channel)) {
    return NextResponse.json({ ok: false, error: 'invalid channel' }, { status: 400 });
  }
  try {
    const client = await getPool().connect();
    try {
      const r = await client.query(
        `SELECT channel, require_customer, require_sku, require_cases,
                require_rep, require_date, last_updated, updated_by
           FROM upload_required_field_toggle
          WHERE channel = $1`,
        [channel],
      );
      if (r.rowCount === 0) {
        return NextResponse.json({ ok: false, error: 'no row' }, { status: 404 });
      }
      return NextResponse.json({ ok: true, config: r.rows[0] });
    } finally {
      client.release();
    }
  } catch (err) {
    const message = err instanceof Error ? err.message : 'unknown';
    return NextResponse.json({ ok: false, error: message }, { status: 500 });
  }
}

export async function POST(request: NextRequest) {
  let body: Record<string, unknown>;
  try {
    body = await request.json();
  } catch {
    return NextResponse.json({ ok: false, error: 'bad json' }, { status: 400 });
  }
  const channel = String(body.channel || '').toLowerCase();
  if (!VALID_CHANNELS.includes(channel as Channel)) {
    return NextResponse.json({ ok: false, error: 'invalid channel' }, { status: 400 });
  }
  const fields = ['require_customer', 'require_sku', 'require_cases',
                   'require_rep', 'require_date'];
  const values = fields.map((k) => Boolean(body[k]));
  try {
    const client = await getPool().connect();
    try {
      await client.query(
        `UPDATE upload_required_field_toggle
            SET require_customer = $2, require_sku = $3, require_cases = $4,
                require_rep = $5, require_date = $6,
                last_updated = now(), updated_by = $7
          WHERE channel = $1`,
        [channel, ...values, String(body.updated_by || 'admin-ui')],
      );
      return NextResponse.json({ ok: true });
    } finally {
      client.release();
    }
  } catch (err) {
    const message = err instanceof Error ? err.message : 'unknown';
    return NextResponse.json({ ok: false, error: message }, { status: 500 });
  }
}
