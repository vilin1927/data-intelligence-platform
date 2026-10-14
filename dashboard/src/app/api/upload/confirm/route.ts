export const dynamic = 'force-dynamic';

import { NextRequest, NextResponse } from 'next/server';
import { execFile } from 'child_process';
import { unlink, access } from 'fs/promises';
import getPool from '@/lib/db';

const VENV_PREFIX = 'cd /opt/moppity && source venv/bin/activate';
// B12.1 (2026-04-29): 'direct' added so the wizard accepts Vinsight 28-col
// Sales Detail CSVs (JC-305). Direct still auto-syncs from Vinsight as the
// primary path (RECON-FIX-17); the wizard now provides a manual upload
// fallback for backfill / one-off imports.
const VALID_CHANNELS = ['dws', 'alm', 'direct'];
const TIMEOUT_MS = 180_000; // 3 minutes for import

/**
 * POST /api/upload/confirm
 * Runs the actual import with optional manual SKU/customer overrides.
 * Expects JSON body (not FormData) since the file is already saved from preview step.
 *
 * BUG-09/BUG-10 (2026-04-11): Captures pre/post transaction_id bounds and returns a
 * structured confirmation payload so the Import Wizard can render a validation screen
 * without exporting Combined Data. Counts null-SKU and null-customer rows separately
 * so silently-dropped new-vintage SKUs surface clearly.
 */
export async function POST(request: NextRequest) {
  try {
    const DATABASE_URL = process.env.DATABASE_URL;
    if (!DATABASE_URL) {
      return NextResponse.json(
        { success: false, error: 'Server configuration error: DATABASE_URL not set.' },
        { status: 500 }
      );
    }

    const body = await request.json();
    const { channel, saved_path, overrides, excluded_rows } = body as {
      channel: string;
      saved_path: string;
      overrides?: { sku?: Record<string, number>; customer?: Record<string, number>; customer_code?: Record<string, number> };
      excluded_rows?: number[];
    };

    if (!channel || !VALID_CHANNELS.includes(channel)) {
      return NextResponse.json(
        { success: false, error: `Invalid channel. Must be one of: ${VALID_CHANNELS.join(', ')}` },
        { status: 400 }
      );
    }

    if (!saved_path) {
      return NextResponse.json(
        { success: false, error: 'Missing saved_path — run preview first.' },
        { status: 400 }
      );
    }

    // Validate saved_path strictly (prevent path traversal + shell injection)
    if (!saved_path.startsWith('/tmp/moppity-uploads/') || !/^\/tmp\/moppity-uploads\/[\w._-]+$/.test(saved_path)) {
      return NextResponse.json(
        { success: false, error: 'Invalid file path.' },
        { status: 400 }
      );
    }

    // Check file exists
    try {
      await access(saved_path);
    } catch {
      return NextResponse.json(
        { success: false, error: 'Upload file expired or not found. Please upload again.' },
        { status: 400 }
      );
    }

    // BUG-32: pass overrides as inline JSON via --overrides (matches preview.py argparse).
    // Shell-safe: wrap JSON in single quotes and escape any embedded single quotes using
    // the POSIX '\'' trick so customer names/SKU codes containing ' or & don't break bash -c.
    // D3 / JF-13 (2026-05-11): excluded_rows is now honored by etl/preview.py
    // confirm_import → import_dws.py / import_alm.py / import_direct.py.
    // Rows with these 1-based preview row_nums are skipped before canonical
    // sales_transaction insert. Staging tables (alm_edi_segment_5{0..3},
    // dws_staging_114, vinsight_sales_detail_28) still capture raw bytes for
    // audit — by design.
    let overridesArg = '';
    if (overrides || excluded_rows) {
      const overridesData = { ...overrides, excluded_rows: excluded_rows || [] };
      const overridesJson = JSON.stringify(overridesData);
      const shellEscaped = overridesJson.replace(/'/g, `'\\''`);
      overridesArg = `--overrides '${shellEscaped}'`;
    }

    // BUG-09: Capture the high-water mark BEFORE the import so we can identify
    // exactly the rows this upload produced. Non-fatal if it fails — the import
    // still runs; we just won't have upload_id_min/max in the confirmation.
    const pool = getPool();
    const channelUpper = channel.toUpperCase();
    let preMaxId = 0;
    try {
      const preMaxResult = await pool.query(
        'SELECT COALESCE(MAX(transaction_id), 0)::bigint AS max_id FROM sales_transaction WHERE source_system = $1',
        [channelUpper]
      );
      preMaxId = Number(preMaxResult.rows[0]?.max_id || 0);
    } catch (preErr) {
      console.error('[/api/upload/confirm] preMaxId query failed (non-fatal):', preErr);
    }

    // Use execFile with explicit args array — no shell interpolation
    const scriptContent = [
      VENV_PREFIX,
      [
        `DATABASE_URL="${DATABASE_URL}"`,
        'python3 -m etl.preview',
        `--channel ${channel}`,
        `--file "${saved_path}"`,
        '--confirm',
        overridesArg,
      ].filter(Boolean).join(' '),
    ].join(' && ');

    const output = await new Promise<string>((resolve, reject) => {
      execFile('bash', ['-c', scriptContent], { timeout: TIMEOUT_MS, maxBuffer: 10 * 1024 * 1024 }, (error, stdout, stderr) => {
        if (error) {
          const errMsg = [stderr, stdout, error.message].filter(Boolean).join('\n').trim();
          reject(new Error(errMsg || 'Import failed'));
          return;
        }
        resolve(stdout);
      });
    });

    // Clean up temp file after successful import
    try { await unlink(saved_path); } catch { /* ignore */ }

    // Parse Python JSON output
    let importResult: Record<string, unknown>;
    try {
      importResult = JSON.parse(output);
    } catch {
      // If Python printed plain text (old format), wrap it
      importResult = { output };
    }

    // Post-import: assign vintage COGS to newly imported rows (RECON-FIX-07)
    try {
      const cogsResult = await pool.query('SELECT * FROM assign_vintage_cogs()');
      const cogsRow = cogsResult.rows[0];
      if (cogsRow && cogsRow.total_updated > 0) {
        importResult.cogs_assigned = {
          total: Number(cogsRow.total_updated),
          vintage_matched: Number(cogsRow.vintage_matched),
          fallback: Number(cogsRow.fallback_used),
        };
      }
    } catch (cogsErr) {
      console.error('[/api/upload/confirm] COGS assignment error (non-fatal):', cogsErr);
    }

    // BUG-09/BUG-10: Build structured confirmation payload by inspecting the exact
    // rows this upload inserted (transaction_id > preMaxId & same source_system).
    let confirmation: {
      total_rows: number;
      imported: number;
      skipped: { count: number; rows: { row_index: number; reason: string }[] };
      new_customers: { count: number; names: string[] };
      new_sku_matches: { count: number; codes: string[] };
      new_reps: { count: number };
      null_sku_rows: number;
      null_customer_rows: number;
      upload_id_min: number | null;
      upload_id_max: number | null;
    } | null = null;

    try {
      const postSummary = await pool.query(
        `SELECT
           COUNT(*)::int                                         AS imported,
           COUNT(*) FILTER (WHERE sku_id IS NULL)::int           AS null_sku_rows,
           COUNT(*) FILTER (WHERE customer_id IS NULL)::int      AS null_customer_rows,
           MIN(transaction_id)::bigint                           AS min_id,
           MAX(transaction_id)::bigint                           AS max_id
         FROM sales_transaction
         WHERE source_system = $1 AND transaction_id > $2`,
        [channelUpper, preMaxId]
      );
      const s = postSummary.rows[0] || {};
      const imported = Number(s.imported || 0);
      const minId = s.min_id != null ? Number(s.min_id) : null;
      const maxId = s.max_id != null ? Number(s.max_id) : null;

      // Parse skipped reasons from the Python warnings/errors list.
      const pyErrors: string[] = Array.isArray(importResult.errors) ? (importResult.errors as string[]) : [];
      const skippedRows: { row_index: number; reason: string }[] = [];
      const nullSkuCodes = new Set<string>();
      const nullCustomerNames = new Set<string>();
      for (const e of pyErrors) {
        // "Row 12: missing sale_date — skipped"
        const skipMatch = e.match(/^Row (\d+):\s*(.*?)\s*—\s*skipped/i);
        if (skipMatch) {
          skippedRows.push({ row_index: parseInt(skipMatch[1], 10), reason: skipMatch[2] });
          continue;
        }
        // "Row N: unrecognised product 'X' — row inserted with sku_id=NULL."
        const skuMatch = e.match(/unrecognised product '([^']+)'/);
        if (skuMatch) {
          nullSkuCodes.add(skuMatch[1]);
          skippedRows.push({
            row_index: parseInt(e.match(/^Row (\d+):/)?.[1] || '0', 10),
            reason: `Inserted with NULL SKU (unmatched: ${skuMatch[1]})`,
          });
          continue;
        }
        // "Row N: unrecognised DWS outlet 'X' — row inserted with customer_id=NULL."
        const custMatch = e.match(/unrecognised \w+ outlet '([^']+)'/);
        if (custMatch) {
          nullCustomerNames.add(custMatch[1]);
          skippedRows.push({
            row_index: parseInt(e.match(/^Row (\d+):/)?.[1] || '0', 10),
            reason: `Inserted with NULL customer (unmatched: ${custMatch[1]})`,
          });
          continue;
        }
      }

      const rowsImported = Number(importResult.rows_imported ?? imported);
      const rowsSkipped = Number(importResult.rows_skipped ?? 0);
      // total = imported + duplicates skipped by the Python loop + rows with parse errors
      const totalRows = rowsImported + rowsSkipped + skippedRows.filter(r => !r.reason.startsWith('Inserted with')).length;

      // new_sku_matches: count of overrides the user saved via save-match before confirm
      // plus Python's new_mappings count (overrides applied at confirm time).
      const newMappings = Number(importResult.new_mappings ?? 0);

      confirmation = {
        total_rows: totalRows,
        imported: rowsImported,
        skipped: { count: rowsSkipped + skippedRows.filter(r => !r.reason.startsWith('Inserted with')).length, rows: skippedRows },
        new_customers: { count: 0, names: [] }, // Frontend already tracks create-new-customer actions; surface N/A here for now.
        new_sku_matches: { count: newMappings, codes: [] },
        new_reps: { count: 0 },
        null_sku_rows: Number(s.null_sku_rows || 0),
        null_customer_rows: Number(s.null_customer_rows || 0),
        upload_id_min: minId,
        upload_id_max: maxId,
      };
    } catch (confirmErr) {
      console.error('[/api/upload/confirm] Confirmation summary query failed (non-fatal):', confirmErr);
    }

    return NextResponse.json({
      success: true,
      ...importResult,
      confirmation,
    });
  } catch (err) {
    const message = err instanceof Error ? err.message : 'Unknown error';
    console.error('[/api/upload/confirm] Error:', message);

    return NextResponse.json(
      { success: false, error: message },
      { status: 500 }
    );
  }
}
