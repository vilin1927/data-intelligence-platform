export const dynamic = 'force-dynamic';

import { NextRequest, NextResponse } from 'next/server';
import getPool from '@/lib/db';

/**
 * GET /api/customers/export?search=term
 *
 * B4 JC-027 / JC-028: Download canonical_customer master as CSV with the
 * full Access 22-col schema (ID, IsDelete, CustomerCode, ALM/DIR/ILG/YNR/
 * YNRALM codes, CustomerName, Suburb, Postcode, Rep, Territory, TerritoryGroup,
 * Group, Channel, Remark, Notes, xCustomerName, EditedOn, AddedOn, MaxID).
 *
 * Optional `search` parameter narrows by name/group/channel/territory/rep
 * substring (case-insensitive). Empty `search` exports the whole master
 * (~4,030 rows).
 *
 * Requires schema/060 + schema/061 to be applied — references the new
 * canonical_customer columns directly.
 */

// Order matches Access Customers table column order verbatim — keep stable.
const HEADERS = [
  'ID',
  'IsDelete',
  'CustomerCode',
  'ALMCustomerCode',
  'DIRCustomerCode',
  'ILGCustomerCode',
  'YNRCustomerCode',
  'YNRALMCustomerCode',
  'CustomerName',
  'Suburb',
  'Postcode',
  'Rep',
  'Territory',
  'TerritoryGroup',
  'Group',
  'Channel',
  'Remark',
  'Notes',
  'xCustomerName',
  'EditedOn',
  'AddedOn',
  'MaxID',
];

function escapeCsv(v: unknown): string {
  if (v === null || v === undefined) return '';
  const s = typeof v === 'string' ? v : String(v);
  if (s.includes(',') || s.includes('"') || s.includes('\n') || s.includes('\r')) {
    return `"${s.replace(/"/g, '""')}"`;
  }
  return s;
}

export async function GET(request: NextRequest) {
  try {
    const pool = getPool();
    const search = (request.nextUrl.searchParams.get('search') || '').trim();

    const params: string[] = [];
    let whereClause = '';
    if (search.length >= 2) {
      params.push(`%${search}%`);
      whereClause = `
        WHERE LOWER(customer_name)            LIKE LOWER($1)
           OR LOWER(COALESCE(customer_group,''))    LIKE LOWER($1)
           OR LOWER(COALESCE(channel,''))           LIKE LOWER($1)
           OR LOWER(COALESCE(territory_name,''))    LIKE LOWER($1)
           OR LOWER(COALESCE(rep_name,''))          LIKE LOWER($1)
           OR LOWER(COALESCE(suburb,''))            LIKE LOWER($1)
           OR LOWER(COALESCE(postcode,''))          LIKE LOWER($1)
           OR LOWER(COALESCE(customer_code,''))     LIKE LOWER($1)
           OR LOWER(COALESCE(x_customer_name,''))   LIKE LOWER($1)
      `;
    }

    const result = await pool.query(
      `SELECT
         id,
         is_deleted,
         customer_code,
         alm_customer_code,
         dir_customer_code,
         ilg_customer_code,
         ynr_customer_code,
         ynr_alm_customer_code,
         customer_name,
         suburb,
         postcode,
         rep_name,
         territory_name,
         territory_group,
         customer_group,
         channel,
         remark,
         notes,
         x_customer_name,
         edited_on,
         added_on,
         max_id
       FROM canonical_customer
       ${whereClause}
       ORDER BY customer_name`,
      params,
    );

    const lines: string[] = [];
    lines.push(HEADERS.join(','));
    for (const r of result.rows) {
      lines.push(
        [
          r.id,
          r.is_deleted ? '1' : '0',
          r.customer_code,
          r.alm_customer_code,
          r.dir_customer_code,
          r.ilg_customer_code,
          r.ynr_customer_code,
          r.ynr_alm_customer_code,
          r.customer_name,
          r.suburb,
          r.postcode,
          r.rep_name,
          r.territory_name,
          r.territory_group,
          r.customer_group,
          r.channel,
          r.remark,
          r.notes,
          r.x_customer_name,
          r.edited_on ? new Date(r.edited_on).toISOString() : '',
          r.added_on ? new Date(r.added_on).toISOString() : '',
          r.max_id ?? '',
        ].map(escapeCsv).join(','),
      );
    }
    const csv = lines.join('\r\n') + '\r\n';

    const today = new Date().toISOString().slice(0, 10);
    const filename = `moppity-customers-${today}.csv`;

    return new NextResponse(csv, {
      status: 200,
      headers: {
        'Content-Type': 'text/csv; charset=utf-8',
        'Content-Disposition': `attachment; filename="${filename}"`,
        'Cache-Control': 'no-store',
      },
    });
  } catch (err) {
    console.error('[/api/customers/export] error:', err);
    return NextResponse.json({ error: 'Failed to export customers' }, { status: 500 });
  }
}
