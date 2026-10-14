/**
 * GET /api/admin/upload-batches  → list every upload_batch with reconcile
 * status counts. Used by /admin/reconcile.
 *
 * Query params:
 *   id      — when set, return only that batch + its full per-dim breakdown
 *   limit   — default 50, max 200
 *
 * Bundle B12 (JC-288 / JC-311).
 */

import { NextRequest, NextResponse } from 'next/server';
import { Pool } from 'pg';

export const dynamic = 'force-dynamic';

let pool: Pool | undefined;
function getPool(): Pool {
  if (!pool) {
    pool = new Pool({ connectionString: process.env.DATABASE_URL });
  }
  return pool;
}

export async function GET(request: NextRequest) {
  const url = new URL(request.url);
  const id = url.searchParams.get('id');
  const limit = Math.min(Number(url.searchParams.get('limit') ?? 50), 200);

  try {
    const client = await getPool().connect();
    try {
      if (id) {
        const idNum = Number(id);
        if (!Number.isFinite(idNum)) {
          return NextResponse.json({ ok: false, error: 'bad id' }, { status: 400 });
        }
        const batchRes = await client.query(
          `SELECT upload_batch_id, channel, file_name, file_hash_sha256,
                  status, row_count_seen, row_count_inserted,
                  row_count_duplicates, started_at, ended_at, period_label
             FROM upload_batch WHERE upload_batch_id = $1`,
          [idNum],
        );
        if (batchRes.rowCount === 0) {
          return NextResponse.json({ ok: false, error: 'not found' }, { status: 404 });
        }
        const dimRes = await client.query(
          `SELECT dimension, dimension_key, source_value, db_value, diff,
                  tolerance, status, notes
             FROM upload_batch_reconcile
            WHERE upload_batch_id = $1
            ORDER BY dimension, dimension_key`,
          [idNum],
        );
        return NextResponse.json({
          ok: true,
          batch: batchRes.rows[0],
          reconcile: dimRes.rows,
        });
      }

      // List view: include reconcile status_counts inline.
      const listRes = await client.query(
        `SELECT b.upload_batch_id, b.channel, b.file_name, b.period_label,
                b.started_at, b.ended_at, b.status,
                b.row_count_seen, b.row_count_inserted, b.row_count_duplicates,
                COALESCE(jsonb_object_agg(r.status, r.cnt) FILTER (WHERE r.status IS NOT NULL),
                          '{}'::jsonb) AS status_counts
           FROM upload_batch b
      LEFT JOIN (SELECT upload_batch_id, status, COUNT(*) AS cnt
                   FROM upload_batch_reconcile
                  GROUP BY upload_batch_id, status) r
             ON r.upload_batch_id = b.upload_batch_id
          GROUP BY b.upload_batch_id
          ORDER BY b.upload_batch_id DESC
          LIMIT $1`,
        [limit],
      );
      return NextResponse.json({ ok: true, batches: listRes.rows });
    } finally {
      client.release();
    }
  } catch (err) {
    const message = err instanceof Error ? err.message : 'unknown';
    return NextResponse.json({ ok: false, error: message }, { status: 500 });
  }
}
