export const dynamic = 'force-dynamic';

import { NextResponse } from 'next/server';
import type { PoolClient } from 'pg';
import getPool from '@/lib/db';

/**
 * GET /api/export/combined-data
 *
 * Streams Combined Data as CSV — 53 columns, all sales_transaction rows
 * across every channel (DWS / ALM / Direct / access_db / Vinsight),
 * mirroring Access CombinedData verbatim plus a Vintage column.
 *
 * B8 JC-234 (2026-04-28) — extended from 33 cols (CLARIFY-15 / RECON-FIX-23)
 * to all 52 Access cols. Source switched from access_combined_data JSONB
 * (access-only) to combined_data_enriched VIEW (all channels). The
 * duplicate BaseWholesale column has been dropped — the owner's xlsx carries
 * it twice but the canonical 52-col schema (extract-accdb-0002) lists it
 * once. JC-225/JC-507 cols (NetDollarPerCase, ImportID, etc) now ship.
 *
 * BUG-63a (2026-04-30) — appended Vintage at col 53 per the owner Apr-26 ask.
 * For DWS/Direct/Y&R the SKU code carries vintage so sku.vintage populates;
 * for ALM the vintage is estimated via sale_vintage_attribution
 * (attribution_method='alm_estimated_*' from schema/082 backfill) and
 * surfaces through schema/109's COALESCE in combined_data_enriched.vintage.
 *
 * Streaming: PostgreSQL named CURSOR inside a single transaction. FETCH
 * 5,000 rows per batch → encode UTF-8 → enqueue to ReadableStream. Avoids
 * OFFSET O(n²) cost on 120K rows and keeps Node heap bounded.
 *
 * No filter params — this endpoint is the "give me the owner's full Combined
 * Data" surface. Filtered exports go through /api/legacy-data?format=csv.
 */

// 49-column header set, in the canonical Access CombinedData order
// (extract-accdb-0002 — HARD source).
// M18b (the owner May 14): dropped ALMCustomerCode / DIRCustomerCode /
// ILGCustomerCode — per-customer codes live on customer table, not on each
// transaction row. See schema/176 + ADR-022.
const CSV_HEADERS = [
  'ID',                       // 1
  'SN',                       // 2
  'Warehouse',                // 3
  'CustomerCode',             // 4
  'CustomerName',             // 5
  'Suburb',                   // 6
  'Postcode',                 // 7
  'Rep',                      // 8
  'Territory',                // 9
  'TerritoryGroup',           // 10
  'Channel',                  // 11
  'Group',                    // 12
  'InvoiceNo',                // 13
  'TransactionDate',          // 14
  'CalMonth',                 // 15
  'CalYearx',                 // 16
  'CalMonthx',                // 17
  'CalYearMonth',             // 18
  'ItemCode',                 // 19
  'ItemDescription',          // 20
  'SKU',                      // 21
  'Range',                    // 22
  'QuantitySupplied(Bottles)',// 23
  'QuantitySupplied(Dozens)', // 24
  'WholesaleValueExEx',       // 25
  'AverageCase',              // 26
  'BaseWholesale',            // 27
  'TransferCost',             // 28
  'Discount',                 // 29
  'DiscountPercentage',       // 30
  'Cogs',                     // 31
  'RebateRate',               // 32
  'Rebate',                   // 33
  'WholesalerFee',            // 34
  'Profit',                   // 35
  'GP',                       // 36
  'Note',                     // 37
  'WSaleValue',               // 38
  'SubRegion',                // 39
  'Ownership',                // 40
  'ImportID',                 // 41
  'NetDollarPerCase',         // 42
  'CartonX',                  // 43
  'CalculatedProfit',         // 44
  'commission',               // 45
  'netrevenue',               // 46
  'TotalCogs',                // 47
  'AverageCase1',             // 48
  'NetProfit',                // 49
  'Vintage',                  // 50 — BUG-63a (the owner Apr-26)
];

// 50-col SELECT against combined_data_enriched. Column order matches
// CSV_HEADERS above 1:1. NULLs render as empty strings via escapeCsvField.
// BUG-63a (2026-04-30): vintage appended as c50.
// M18b (2026-05-14): channel-code cols dropped — schema/176 + ADR-022.
const SELECT_50_COLS = `
  SELECT
    upload_id                   AS c1,
    sn                          AS c2,
    warehouse                   AS c3,
    customer_code               AS c4,
    customer_name               AS c5,
    suburb                      AS c6,
    postcode                    AS c7,
    rep                         AS c8,
    territory                   AS c9,
    territory_group             AS c10,
    channel                     AS c11,
    customer_group              AS c12,
    invoice_no                  AS c13,
    transaction_date::text      AS c14,
    cal_month                   AS c15,
    cal_year                    AS c16,
    cal_month_num               AS c17,
    period                      AS c18,
    item_code                   AS c19,
    item_description            AS c20,
    sku                         AS c21,
    range_name                  AS c22,
    qty_bottles                 AS c23,
    qty                         AS c24,
    wholesale_value_ex          AS c25,
    average_case                AS c26,
    base_wholesale              AS c27,
    transfer_cost               AS c28,
    discount                    AS c29,
    discount_percentage         AS c30,
    cogs                        AS c31,
    rebate_rate                 AS c32,
    rebate                      AS c33,
    wholesaler_fee              AS c34,
    profit                      AS c35,
    gp                          AS c36,
    note                        AS c37,
    wsale_value                 AS c38,
    sub_region                  AS c39,
    ownership                   AS c40,
    import_id                   AS c41,
    net_dollar_per_case         AS c42,
    carton_x                    AS c43,
    calculated_profit           AS c44,
    commission                  AS c45,
    netrevenue                  AS c46,
    total_cogs                  AS c47,
    average_case_1              AS c48,
    net_profit                  AS c49,
    vintage                     AS c50
  FROM combined_data_enriched
  ORDER BY upload_id
`;

const NUM_COLS = 50;
const FETCH_BATCH = 5000;
const CURSOR_NAME = 'combined_data_export';

// Plain-number pattern. Negative discounts/rebates/totals must ship as
// numbers (not Excel text), so the CSV-injection guard skips values
// matching this regex.
const NUMERIC_RE = /^-?\d+(\.\d+)?$/;

function escapeCsvField(value: unknown): string {
  if (value === null || value === undefined) return '';
  let s = String(value);
  // CWE-1236: prevent CSV injection (=, +, -, @ at start of field is parsed
  // as a formula by Excel/Sheets). Prefix with a single quote so the cell
  // shows the literal value. Skip if the value is a plain number — Excel
  // treats those as numeric regardless of leading sign.
  if (
    s.length > 0 &&
    (s[0] === '=' || s[0] === '+' || s[0] === '-' || s[0] === '@') &&
    !NUMERIC_RE.test(s)
  ) {
    s = "'" + s;
  }
  if (s.includes(',') || s.includes('"') || s.includes('\n') || s.includes('\r')) {
    return '"' + s.replace(/"/g, '""') + '"';
  }
  return s;
}

export async function GET() {
  let conn: PoolClient;
  try {
    const pool = getPool();
    conn = await pool.connect();
  } catch (err) {
    console.error('[/api/export/combined-data] DB connect failed:', err);
    return NextResponse.json(
      { error: 'Failed to acquire DB connection' },
      { status: 500 }
    );
  }

  const encoder = new TextEncoder();

  const stream = new ReadableStream<Uint8Array>({
    async start(controller) {
      try {
        // UTF-8 BOM so Windows Excel renders accented characters correctly.
        controller.enqueue(encoder.encode('﻿' + CSV_HEADERS.join(',') + '\n'));

        await conn.query('BEGIN');
        await conn.query(`DECLARE ${CURSOR_NAME} NO SCROLL CURSOR FOR ${SELECT_50_COLS}`);

        for (;;) {
          const batch = await conn.query(`FETCH ${FETCH_BATCH} FROM ${CURSOR_NAME}`);
          if (batch.rows.length === 0) break;

          const lines: string[] = [];
          for (const row of batch.rows) {
            const fields: string[] = [];
            for (let i = 1; i <= NUM_COLS; i++) {
              fields.push(escapeCsvField((row as Record<string, unknown>)[`c${i}`]));
            }
            lines.push(fields.join(','));
          }
          controller.enqueue(encoder.encode(lines.join('\n') + '\n'));
        }

        await conn.query(`CLOSE ${CURSOR_NAME}`);
        await conn.query('COMMIT');
        controller.close();
      } catch (err) {
        console.error('[/api/export/combined-data] Stream error:', err);
        try { await conn.query('ROLLBACK'); } catch { /* swallow */ }
        controller.error(err);
      } finally {
        conn.release();
      }
    },
    async cancel() {
      try {
        await conn.query(`CLOSE ${CURSOR_NAME}`);
      } catch { /* cursor may not exist */ }
      try { await conn.query('ROLLBACK'); } catch { /* swallow */ }
      conn.release();
    },
  });

  return new Response(stream, {
    headers: {
      'Content-Type': 'text/csv; charset=utf-8',
      'Content-Disposition': `attachment; filename="combined-data-${new Date().toISOString().slice(0, 10)}.csv"`,
      'Cache-Control': 'no-store',
    },
  });
}
