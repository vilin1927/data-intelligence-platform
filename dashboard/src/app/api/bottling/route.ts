export const dynamic = 'force-dynamic';

import { NextRequest, NextResponse } from 'next/server';
import getPool from '@/lib/db';

/**
 * GET /api/bottling — List recent bottling runs
 * POST /api/bottling — Record a new bottling run + optionally lock COGS
 */

export async function GET() {
  try {
    const pool = getPool();
    const result = await pool.query(`
      SELECT
        po.id,
        po.description,
        po.sku_id,
        s.sku_code,
        s.item_description as wine_name,
        po.bottling_date,
        po.cases_produced,
        po.bottles_produced,
        po.status,
        po.synced_at
      FROM packaging_operation po
      LEFT JOIN sku s ON s.sku_id = po.sku_id
      WHERE po.bottling_date IS NOT NULL
      ORDER BY po.bottling_date DESC
      LIMIT 50
    `);

    return NextResponse.json({ bottling_runs: result.rows });
  } catch (err) {
    console.error('[/api/bottling GET] Error:', err);
    return NextResponse.json({ error: 'Failed to load bottling runs' }, { status: 500 });
  }
}

export async function POST(request: NextRequest) {
  try {
    const body = await request.json();
    const { sku_id, bottling_date, cases_produced, description, lock_cogs } = body;

    if (!sku_id || !bottling_date || !cases_produced) {
      return NextResponse.json(
        { error: 'Required: sku_id, bottling_date, cases_produced' },
        { status: 400 }
      );
    }

    const pool = getPool();

    // Insert bottling run
    const insertResult = await pool.query(`
      INSERT INTO packaging_operation (sku_id, bottling_date, cases_produced, bottles_produced, description, status, synced_at)
      VALUES ($1, $2, $3, $4, $5, 'Bulk To Pack', NOW())
      RETURNING id
    `, [sku_id, bottling_date, cases_produced, (cases_produced * 12), description || `Manual bottling run - ${bottling_date}`]);

    const bottlingId = insertResult.rows[0].id;

    // Optionally lock COGS at bottling time
    if (lock_cogs) {
      await pool.query(`
        UPDATE sku_cogs SET lock_date = NOW()
        WHERE sku_id = $1 AND lock_date IS NULL
      `, [sku_id]);
    }

    return NextResponse.json({
      success: true,
      bottling_id: bottlingId,
      cogs_locked: !!lock_cogs,
    });
  } catch (err) {
    console.error('[/api/bottling POST] Error:', err);
    return NextResponse.json({ error: 'Failed to record bottling run' }, { status: 500 });
  }
}
