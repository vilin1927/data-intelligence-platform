export const dynamic = 'force-dynamic';

import { NextRequest, NextResponse } from 'next/server';
import getPool from '@/lib/db';

/**
 * GET /api/skus?search=term
 * Returns matching SKUs for search dropdown with code, description, variety,
 * region, and vintage. Vintage NULL is preserved (NV sentinel — JC-125 / JC-160).
 *
 * POST /api/skus
 * Creates a new sku ROW (warehouse-level identifier). Body:
 *   { sku_code, description, variety, region, vintage, source_system, external_code }
 *
 * B6b note (JC-108): this endpoint does NOT create a canonical_sku. New
 * canonical SKUs come exclusively from etl/import_sku_from_access_first.py
 * (the accdb-driven pipeline). The /admin/unmatched-skus admin UI links
 * existing canonicals; SkuMatchModal does the same. POST here is for
 * legacy upload flows that need a warehouse-level sku stub before fuzzy
 * matching can attach a canonical.
 *
 * Returns the new sku_id.
 */

export async function GET(request: NextRequest) {
  try {
    const pool = getPool();
    const search = request.nextUrl.searchParams.get('search') || '';

    if (search.length < 2) {
      return NextResponse.json({ skus: [] });
    }

    const result = await pool.query(
      `SELECT s.sku_id, s.sku_code, s.item_description, s.variety,
              COALESCE(mro.region, s.region) AS region,
              s.vintage
       FROM sku s
       LEFT JOIN manual_region_override mro ON mro.sku_id = s.sku_id
       WHERE LOWER(s.sku_code) LIKE LOWER($1)
          OR LOWER(s.item_description) LIKE LOWER($1)
          OR LOWER(s.variety) LIKE LOWER($1)
       ORDER BY s.sku_code
       LIMIT 30`,
      [`%${search}%`]
    );

    return NextResponse.json({
      skus: result.rows.map(r => ({
        sku_id: r.sku_id,
        sku_code: r.sku_code,
        description: r.item_description || '',
        variety: r.variety || '',
        region: r.region || '',
        // JC-125 / JC-160: NV sentinel — preserve NULL as 'NV', don't coerce to 0.
        vintage: r.vintage,
        vintage_label: r.vintage == null ? 'NV' : String(r.vintage),
      })),
    });
  } catch (err) {
    console.error('[/api/skus] GET error:', err);
    return NextResponse.json({ error: 'Failed to search SKUs' }, { status: 500 });
  }
}

export async function POST(request: NextRequest) {
  try {
    const pool = getPool();
    const body = await request.json();
    const {
      sku_code,
      description,
      variety,
      region,
      vintage,
      source_system,
      external_code,
    } = body as {
      sku_code: string;
      description: string;
      variety: string;
      region?: string | null;
      vintage?: number | null;
      source_system?: string;
      external_code?: string;
    };

    // Validate required fields
    if (!sku_code || !sku_code.trim()) {
      return NextResponse.json({ error: 'SKU code is required' }, { status: 400 });
    }
    if (!description || !description.trim()) {
      return NextResponse.json({ error: 'Description is required' }, { status: 400 });
    }
    if (!variety || !variety.trim()) {
      return NextResponse.json({ error: 'Variety is required' }, { status: 400 });
    }

    // Check for duplicate SKU code
    const existing = await pool.query(
      'SELECT sku_id FROM sku WHERE LOWER(sku_code) = LOWER($1)',
      [sku_code.trim()]
    );
    if (existing.rows.length > 0) {
      return NextResponse.json({
        error: `SKU code "${sku_code}" already exists`,
        sku_id: existing.rows[0].sku_id,
      }, { status: 409 });
    }

    // Insert new sku row. Vintage stays NULL when not provided (NV sentinel
    // per JC-125 / JC-160). canonical_sku_id is intentionally NOT set here:
    // the new row will surface in /admin/unmatched-skus for human review.
    const result = await pool.query(
      `INSERT INTO sku (sku_code, item_description, variety, region, vintage)
       VALUES ($1, $2, $3, $4, $5)
       RETURNING sku_id, sku_code, item_description`,
      [
        sku_code.trim(),
        description.trim(),
        variety.trim(),
        region || null,
        // Treat 0 / falsy as NULL so NV stays NV; only insert real vintages.
        vintage && Number(vintage) > 0 ? Number(vintage) : null,
      ]
    );

    const newSku = result.rows[0];

    // If source_system and external_code provided, create mapping
    if (source_system && external_code) {
      await pool.query(
        `INSERT INTO sku_code_map (sku_id, source_system, external_code)
         VALUES ($1, $2, $3)
         ON CONFLICT DO NOTHING`,
        [newSku.sku_id, source_system.toLowerCase(), external_code]
      );
    }

    return NextResponse.json({
      success: true,
      sku_id: newSku.sku_id,
      sku_code: newSku.sku_code,
      description: newSku.item_description,
    });
  } catch (err) {
    console.error('[/api/skus] POST error:', err);
    return NextResponse.json({ error: 'Failed to create SKU' }, { status: 500 });
  }
}
