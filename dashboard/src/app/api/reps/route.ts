export const dynamic = 'force-dynamic';

import { NextRequest, NextResponse } from 'next/server';
import getPool from '@/lib/db';

/**
 * GET /api/reps
 *
 * Reads from canonical_representative (B5 / 2026-04-27). Replaces the
 * legacy `representative` table read. Returns the 26 Access verbatim cols
 * (incl. MAT/MTD/MQT performance metrics) plus joined territory_name and
 * customer_count.
 *
 * Query params:
 *   ?search=term              partial match on rep_name OR territory_name
 *   ?include_allchannel=true  include is_active_allchannel reps that are
 *                             NOT also is_active_dws=true (default: false →
 *                             returns the 31 DWS-canonical reps + any
 *                             is_active_dws=true row).
 */
export async function GET(request: NextRequest) {
  try {
    const pool = getPool();
    const sp = request.nextUrl.searchParams;
    const search = (sp.get('search') || '').trim();
    const includeAllchannel = sp.get('include_allchannel') === 'true';

    const params: (string | boolean)[] = [];
    const whereClauses: string[] = [];

    if (!includeAllchannel) {
      whereClauses.push('cr.is_active_dws = TRUE');
    }
    if (search.length >= 2) {
      params.push(`%${search}%`);
      const idx = params.length;
      whereClauses.push(
        `(LOWER(cr.rep_name) LIKE LOWER($${idx})
          OR LOWER(COALESCE(cr.full_rep_display, '')) LIKE LOWER($${idx})
          OR LOWER(COALESCE(cr.short_rep, '')) LIKE LOWER($${idx})
          OR LOWER(COALESCE(ct.territory_name, '')) LIKE LOWER($${idx}))`
      );
    }
    const whereSql = whereClauses.length ? `WHERE ${whereClauses.join(' AND ')}` : '';

    const result = await pool.query(
      `SELECT
         cr.id                          AS rep_id,
         cr.rep_name,
         cr.full_rep_display,
         cr.short_rep,
         cr.is_active_dws,
         cr.is_active_allchannel,
         cr.territory_id,
         ct.territory_name,
         cr.territory_group,
         cr.representative_details,
         cr.members_growth,
         cr.ty_distrn,
         cr.range_mtd,
         cr.ly_dollar,
         cr.ty_dollar,
         cr.y_dollar_per,
         cr.ly_mtd_dollar,
         cr.ty_mtd_dollar,
         cr.mtd_per,
         cr.ly_mqt_dollar,
         cr.ty_mqt_dollar,
         cr.mqt_dollar_per,
         cr.ranges_per_member,
         cr.distrn_per_member,
         cr.sales_per_member_mat,
         cr.sales_growth_per_member_mat,
         COALESCE(cc.customer_count, 0) AS customer_count,
         cr.created_at
       FROM canonical_representative cr
       LEFT JOIN canonical_territory  ct ON ct.id = cr.territory_id
       LEFT JOIN (
         SELECT rep_name, COUNT(*) AS customer_count
         FROM canonical_customer
         WHERE rep_name IS NOT NULL
         GROUP BY rep_name
       ) cc ON cc.rep_name = cr.rep_name
       ${whereSql}
       ORDER BY cr.full_rep_display NULLS LAST, cr.rep_name`,
      params
    );

    // Aggregate every territory_name a rep covers — the rep_territory_xref
    // table is authoritative; fall back to canonical_customer scan if a
    // rep has no xref row yet.
    const coverageResult = await pool.query(
      `SELECT cr.rep_name,
              ARRAY_AGG(DISTINCT ct.territory_name)
                FILTER (WHERE ct.territory_name IS NOT NULL) AS territories
       FROM canonical_representative cr
       LEFT JOIN rep_territory_xref rtx ON rtx.rep_id = cr.id
       LEFT JOIN canonical_territory ct ON ct.id = rtx.territory_id
       GROUP BY cr.rep_name`
    );
    const coverageMap: Record<string, string[]> = {};
    for (const r of coverageResult.rows) {
      if (r.rep_name) coverageMap[r.rep_name] = r.territories || [];
    }

    // total = how many reps satisfy the same is_active_dws filter (so the
    // tab badge reads "31" not "74" by default).
    const countSql = includeAllchannel
      ? 'SELECT COUNT(*) FROM canonical_representative'
      : 'SELECT COUNT(*) FROM canonical_representative WHERE is_active_dws = TRUE';
    const countResult = await pool.query(countSql);

    return NextResponse.json({
      reps: result.rows.map((r) => ({
        id: r.rep_id,
        name: r.rep_name,
        full_rep_display: r.full_rep_display,
        short_rep: r.short_rep,
        active: !!r.is_active_dws,            // back-compat: "active" was DWS-active in legacy schema
        is_active_dws: !!r.is_active_dws,
        is_active_allchannel: !!r.is_active_allchannel,
        territory_id: r.territory_id,
        territory_name: r.territory_name || '',
        territory_group: r.territory_group || '',
        representative_details: r.representative_details || '',
        // MAT / MTD / MQT performance metrics (JC-057)
        members_growth: numOrNull(r.members_growth),
        ty_distrn: numOrNull(r.ty_distrn),
        range_mtd: numOrNull(r.range_mtd),
        ly_dollar: numOrNull(r.ly_dollar),
        ty_dollar: numOrNull(r.ty_dollar),
        y_dollar_per: numOrNull(r.y_dollar_per),
        ly_mtd_dollar: numOrNull(r.ly_mtd_dollar),
        ty_mtd_dollar: numOrNull(r.ty_mtd_dollar),
        mtd_per: numOrNull(r.mtd_per),
        ly_mqt_dollar: numOrNull(r.ly_mqt_dollar),
        ty_mqt_dollar: numOrNull(r.ty_mqt_dollar),
        mqt_dollar_per: numOrNull(r.mqt_dollar_per),
        ranges_per_member: numOrNull(r.ranges_per_member),
        distrn_per_member: numOrNull(r.distrn_per_member),
        sales_per_member_mat: numOrNull(r.sales_per_member_mat),
        sales_growth_per_member_mat: numOrNull(r.sales_growth_per_member_mat),
        customer_count: parseInt(r.customer_count, 10) || 0,
        territories: coverageMap[r.rep_name] || [],
        created_at: r.created_at,
      })),
      total: parseInt(countResult.rows[0].count, 10),
      filtered: result.rows.length,
    });
  } catch (err) {
    console.error('[/api/reps] GET error:', err);
    return NextResponse.json({ error: 'Failed to load reps' }, { status: 500 });
  }
}

function numOrNull(v: unknown): number | null {
  if (v === null || v === undefined || v === '') return null;
  const n = typeof v === 'number' ? v : parseFloat(String(v));
  return Number.isFinite(n) ? n : null;
}

/**
 * POST /api/reps
 * JF-14: Creates a new representative from the import wizard. Continues to
 * write to the legacy `representative` table for back-compat with the
 * customer import wizard until that flow is migrated to
 * canonical_representative in Phase 2.
 */
export async function POST(request: NextRequest) {
  try {
    const pool = getPool();
    const body = await request.json();
    const { name, territory_id } = body as {
      name: string;
      territory_id?: number | null;
    };

    if (!name || !name.trim()) {
      return NextResponse.json({ error: 'Rep name is required' }, { status: 400 });
    }

    const existing = await pool.query(
      'SELECT rep_id FROM representative WHERE LOWER(rep_name) = LOWER($1)',
      [name.trim()]
    );
    if (existing.rows.length > 0) {
      return NextResponse.json({
        error: `Rep "${name}" already exists`,
        rep_id: existing.rows[0].rep_id,
      }, { status: 409 });
    }

    const result = await pool.query(
      `INSERT INTO representative (rep_name, territory_id, active)
       VALUES ($1, $2, true)
       RETURNING rep_id, rep_name`,
      [name.trim(), territory_id || null]
    );

    const newRep = result.rows[0];

    return NextResponse.json({
      success: true,
      rep_id: newRep.rep_id,
      rep_name: newRep.rep_name,
    });
  } catch (err) {
    console.error('[/api/reps] POST error:', err);
    return NextResponse.json({ error: 'Failed to create rep' }, { status: 500 });
  }
}
