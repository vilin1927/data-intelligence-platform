export const dynamic = 'force-dynamic';

import { NextRequest, NextResponse } from 'next/server';
import getPool from '@/lib/db';

/**
 * GET /api/wholesale-prices
 * Returns all wholesale prices with canonical SKU names.
 */
export async function GET() {
  try {
    const pool = getPool();

    // Demo mirror: wholesale (trade) prices are Moppity-confidential AND a
    // factor-recovery anchor — a real trade price shown next to the scaled
    // base_wholesale for the same SKU reveals the masking scale factor. Serve
    // no prices under VIEW_ONLY. SKU names are public, so the dropdown stays.
    if (process.env.VIEW_ONLY === 'true') {
      const skuOnly = await pool.query(`
        SELECT id, sku_name FROM canonical_sku ORDER BY sku_name
      `);
      return NextResponse.json({ prices: [], skus: skuOnly.rows });
    }

    const result = await pool.query(`
      SELECT
        wp.id,
        wp.canonical_sku_id,
        COALESCE(cs.sku_name, wp.sku_name) as sku_name,
        wp.price_per_case,
        wp.effective_from,
        wp.effective_to,
        wp.notes,
        wp.created_at,
        wp.updated_at
      FROM wholesale_price wp
      LEFT JOIN canonical_sku cs ON cs.id = wp.canonical_sku_id
      ORDER BY COALESCE(cs.sku_name, wp.sku_name), wp.effective_from DESC
    `);

    // Get list of canonical SKUs for dropdown
    const skuResult = await pool.query(`
      SELECT id, sku_name
      FROM canonical_sku
      ORDER BY sku_name
    `);

    return NextResponse.json({
      prices: result.rows,
      skus: skuResult.rows,
    });
  } catch (error) {
    console.error('Error fetching wholesale prices:', error);
    return NextResponse.json(
      { error: 'Failed to fetch wholesale prices' },
      { status: 500 }
    );
  }
}

/**
 * POST /api/wholesale-prices
 * Create a new wholesale price entry.
 * Body: { canonical_sku_id, sku_name?, price_per_case, effective_from, effective_to?, notes? }
 */
export async function POST(request: NextRequest) {
  try {
    const pool = getPool();
    const body = await request.json();

    const { canonical_sku_id, sku_name, price_per_case, effective_from, effective_to, notes } = body;

    if (!price_per_case || !effective_from) {
      return NextResponse.json(
        { error: 'price_per_case and effective_from are required' },
        { status: 400 }
      );
    }

    if (!canonical_sku_id && !sku_name) {
      return NextResponse.json(
        { error: 'Either canonical_sku_id or sku_name is required' },
        { status: 400 }
      );
    }

    const result = await pool.query(
      `INSERT INTO wholesale_price
        (canonical_sku_id, sku_name, price_per_case, effective_from, effective_to, notes)
       VALUES ($1, $2, $3, $4, $5, $6)
       RETURNING *`,
      [canonical_sku_id || null, sku_name || null, price_per_case, effective_from, effective_to || null, notes || null]
    );

    return NextResponse.json({ price: result.rows[0] }, { status: 201 });
  } catch (error) {
    console.error('Error creating wholesale price:', error);
    return NextResponse.json(
      { error: 'Failed to create wholesale price' },
      { status: 500 }
    );
  }
}

/**
 * PUT /api/wholesale-prices
 * Update an existing wholesale price entry.
 * Body: { id, canonical_sku_id?, sku_name?, price_per_case?, effective_from?, effective_to?, notes? }
 */
export async function PUT(request: NextRequest) {
  try {
    const pool = getPool();
    const body = await request.json();

    const { id, canonical_sku_id, sku_name, price_per_case, effective_from, effective_to, notes } = body;

    if (!id) {
      return NextResponse.json(
        { error: 'id is required' },
        { status: 400 }
      );
    }

    const result = await pool.query(
      `UPDATE wholesale_price
       SET canonical_sku_id = COALESCE($2, canonical_sku_id),
           sku_name = COALESCE($3, sku_name),
           price_per_case = COALESCE($4, price_per_case),
           effective_from = COALESCE($5, effective_from),
           effective_to = $6,
           notes = $7,
           updated_at = NOW()
       WHERE id = $1
       RETURNING *`,
      [id, canonical_sku_id, sku_name, price_per_case, effective_from, effective_to, notes]
    );

    if (result.rows.length === 0) {
      return NextResponse.json(
        { error: 'Price entry not found' },
        { status: 404 }
      );
    }

    return NextResponse.json({ price: result.rows[0] });
  } catch (error) {
    console.error('Error updating wholesale price:', error);
    return NextResponse.json(
      { error: 'Failed to update wholesale price' },
      { status: 500 }
    );
  }
}

/**
 * DELETE /api/wholesale-prices?id=123
 * Delete a wholesale price entry.
 */
export async function DELETE(request: NextRequest) {
  try {
    const pool = getPool();
    const id = request.nextUrl.searchParams.get('id');

    if (!id) {
      return NextResponse.json(
        { error: 'id query param is required' },
        { status: 400 }
      );
    }

    const result = await pool.query(
      'DELETE FROM wholesale_price WHERE id = $1 RETURNING id',
      [id]
    );

    if (result.rows.length === 0) {
      return NextResponse.json(
        { error: 'Price entry not found' },
        { status: 404 }
      );
    }

    return NextResponse.json({ deleted: true, id: result.rows[0].id });
  } catch (error) {
    console.error('Error deleting wholesale price:', error);
    return NextResponse.json(
      { error: 'Failed to delete wholesale price' },
      { status: 500 }
    );
  }
}
