export const dynamic = 'force-dynamic';

import { NextRequest, NextResponse } from 'next/server';
import getPool from '@/lib/db';

/**
 * GET /api/skus/export?search=term
 *
 * INFRA-04 RP-2 input: canonical_sku master as CSV with the Access SKU 10-col
 * schema (ID, SKU, Range, RangeGroup, UnitsperCase, Cogs, BaseWholesale,
 * TransferCost, Note, Units) plus an extra `attached_codes_count` column for
 *
 * Units = live point-in-time stock-on-hand summed across every Vinsight code
 * mapped to the canonical via sku_code_map (matches /api/inventory which
 * reads `staging_vinsight_stock_items.UnitsInStock` filtered by IsPackagedWine).
 * Restored 2026-05-05 per BUG-187 -- Access HARD's Units col is also a
 * point-in-time stock-on-hand snapshot the owner curates, but binding to live data
 * is the correct shape for an export (the canonical_sku table itself has no
 * units column per schema/088). Drift vs HARD is expected and temporal: HARD
 * is Apr 14 snapshot, OURS is now. Recon caps the column at AMBER pending
 * The owner confirming the binding direction (live vs HARD-mirror).
 *
 * attached_codes_count = COUNT(*) FROM canonical_sku_code_map. Surfaces fan-out
 * to the recon's BUG-175 secondary section without a second API hit.
 *
 * OWNER-MAY8-B1 (May 8 feedback): added 5 per-source code columns
 * (ALMCode, DWSCode, AccessCode, VinsightCode, ILGCode) sourced from
 * canonical_sku_code_map per source_system. Multi-code per source is rendered
 * comma-separated (sorted) within a single CSV cell; empty when the canonical
 * has no mapping in that source. Counts at populate time (May 8): 116 ALM /
 * 348 DWS / 792 Vinsight / 22 ILG / 899 Access rows over ~130 distinct canonicals.
 */

const HEADERS = [
  'ID',
  'SKU',
  'Range',
  'RangeGroup',
  'UnitsperCase',
  'Cogs',
  'BaseWholesale',
  'TransferCost',
  'Note',
  'Units',
  'attached_codes_count',
  // OWNER-MAY8-B1: per-source code columns from canonical_sku_code_map.
  // Multi-code per source is comma-separated (sorted by code). Empty when no
  // mapping exists. Source values are lowercase 'alm','dws','access','vinsight','ilg'
  // per schema/001_initial.sql:117 + etl/import_access_crossref.py.
  'ALMCode',
  'DWSCode',
  'AccessCode',
  'VinsightCode',
  'ILGCode',
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
        WHERE LOWER(cs.sku_name)                  LIKE LOWER($1)
           OR LOWER(COALESCE(cs.range_name,''))   LIKE LOWER($1)
           OR LOWER(COALESCE(cs.range_group,''))  LIKE LOWER($1)
           OR LOWER(COALESCE(cs.note,''))         LIKE LOWER($1)
      `;
    }

    const result = await pool.query(
      `SELECT
         cs.id,
         cs.sku_name,
         cs.range_name,
         cs.range_group,
         cs.units_per_case,
         cs.cogs,
         cs.base_wholesale,
         cs.transfer_cost,
         cs.note,
         (SELECT COUNT(*)::int
            FROM canonical_sku_code_map cscm
           WHERE cscm.canonical_sku_id = cs.id) AS attached_codes_count,
         (SELECT ROUND(SUM((si.raw_data->>'UnitsInStock')::numeric)::numeric, 4)
            FROM sku s
            JOIN sku_code_map scm
              ON scm.sku_id = s.sku_id
             AND scm.source_system = 'vinsight'
            JOIN staging_vinsight_stock_items si
              ON si.raw_data->>'StockItemCode' = scm.external_code
             AND (si.raw_data->>'IsPackagedWine')::boolean = true
           WHERE s.canonical_sku_id = cs.id) AS units_on_hand,
         -- OWNER-MAY8-B1: per-source code aggregations from canonical_sku_code_map.
         -- One scalar subquery per source. STRING_AGG yields comma-separated
         -- multi-code values (sorted lexicographically for deterministic output);
         -- NULL when no mapping exists -- escapeCsv() converts NULL to empty string.
         (SELECT STRING_AGG(cscm.external_code, ',' ORDER BY cscm.external_code)
            FROM canonical_sku_code_map cscm
           WHERE cscm.canonical_sku_id = cs.id
             AND cscm.source_system = 'alm') AS alm_code,
         (SELECT STRING_AGG(cscm.external_code, ',' ORDER BY cscm.external_code)
            FROM canonical_sku_code_map cscm
           WHERE cscm.canonical_sku_id = cs.id
             AND cscm.source_system = 'dws') AS dws_code,
         (SELECT STRING_AGG(cscm.external_code, ',' ORDER BY cscm.external_code)
            FROM canonical_sku_code_map cscm
           WHERE cscm.canonical_sku_id = cs.id
             AND cscm.source_system = 'access') AS access_code,
         (SELECT STRING_AGG(cscm.external_code, ',' ORDER BY cscm.external_code)
            FROM canonical_sku_code_map cscm
           WHERE cscm.canonical_sku_id = cs.id
             AND cscm.source_system = 'vinsight') AS vinsight_code,
         (SELECT STRING_AGG(cscm.external_code, ',' ORDER BY cscm.external_code)
            FROM canonical_sku_code_map cscm
           WHERE cscm.canonical_sku_id = cs.id
             AND cscm.source_system = 'ilg') AS ilg_code
       FROM canonical_sku cs
       ${whereClause}
       ORDER BY cs.sku_name`,
      params,
    );

    const lines: string[] = [];
    lines.push(HEADERS.join(','));
    for (const r of result.rows) {
      lines.push(
        [
          r.id,
          r.sku_name,
          r.range_name,
          r.range_group,
          r.units_per_case,
          r.cogs,
          r.base_wholesale,
          r.transfer_cost,
          r.note,
          // BUG-187: live stock-on-hand summed across all Vinsight codes mapped
          // to this canonical (NULL when no Vinsight stock rows match -> emit
          // empty string so HARD-EMPTY/OURS-EMPTY rows stay BOTH_EMPTY).
          r.units_on_hand !== null && r.units_on_hand !== undefined ? r.units_on_hand : '',
          r.attached_codes_count,
          // OWNER-MAY8-B1: per-source code columns. escapeCsv handles NULL -> ''
          // and quotes the value when STRING_AGG produced a comma-separated list.
          r.alm_code,
          r.dws_code,
          r.access_code,
          r.vinsight_code,
          r.ilg_code,
        ].map(escapeCsv).join(','),
      );
    }
    const csv = lines.join('\r\n') + '\r\n';

    const today = new Date().toISOString().slice(0, 10);
    const filename = `moppity-skus-${today}.csv`;

    return new NextResponse(csv, {
      status: 200,
      headers: {
        'Content-Type': 'text/csv; charset=utf-8',
        'Content-Disposition': `attachment; filename="${filename}"`,
        'Cache-Control': 'no-store',
      },
    });
  } catch (err) {
    console.error('[/api/skus/export] error:', err);
    return NextResponse.json({ error: 'Failed to export SKUs' }, { status: 500 });
  }
}
