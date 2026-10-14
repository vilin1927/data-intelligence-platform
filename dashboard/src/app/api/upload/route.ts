export const dynamic = 'force-dynamic';

import { NextRequest, NextResponse } from 'next/server';
import { exec } from 'child_process';
import { writeFile, unlink, mkdir } from 'fs/promises';
import { join } from 'path';

const UPLOAD_DIR = '/tmp/moppity-uploads';
const VENV_PREFIX = 'cd /opt/moppity && source venv/bin/activate';

// Build channel commands using environment variables.
// B12.1 (2026-04-29): runs the new staging parser FIRST (audit trail to
// alm_edi_segment_5{0..3} / dws_staging_114 / vinsight_sales_detail_28
// + upload_batch), THEN the legacy importer for canonical sales_transaction
// inserts. The staging parsers are additive — they do not write to
// sales_transaction themselves. `|| true` on the staging command ensures a
// staging-side failure (e.g. a non-Vinsight Direct CSV) does not block the
// canonical import.
function getChannelCommands(): Record<string, (filePath: string) => string> {
  const DATABASE_URL = process.env.DATABASE_URL;

  return {
    dws: (fp) =>
      `bash -c '${VENV_PREFIX} && DATABASE_URL="${DATABASE_URL}" python3 -m etl.import_dws_zip "${fp}" || true; DATABASE_URL="${DATABASE_URL}" python3 -m etl.import_dws "${fp}"'`,
    alm: (fp) =>
      `bash -c '${VENV_PREFIX} && DATABASE_URL="${DATABASE_URL}" python3 -m etl.import_alm_edi "${fp}" || true; DATABASE_URL="${DATABASE_URL}" python3 -m etl.import_alm "${fp}"'`,
    direct: (fp) =>
      `bash -c '${VENV_PREFIX} && (head -1 "${fp}" | grep -qi "sales detail" && DATABASE_URL="${DATABASE_URL}" python3 -m etl.import_vinsight_sales_detail "${fp}" || true); DATABASE_URL="${DATABASE_URL}" python3 -m etl.import_direct "${fp}"'`,
  };
}

const VALID_CHANNELS = ['dws', 'alm', 'direct'];

const TIMEOUT_MS = 180_000; // 3 minutes for large files

export async function POST(request: NextRequest) {
  let savedPath = '';

  try {
    // Validate required environment variables
    if (!process.env.DATABASE_URL) {
      console.error('[/api/upload] Missing DATABASE_URL env var');
      return NextResponse.json(
        { success: false, error: 'Server configuration error. Check server logs.' },
        { status: 500 }
      );
    }

    const formData = await request.formData();
    const channel = formData.get('channel') as string;
    const file = formData.get('file') as File;

    if (!channel || !VALID_CHANNELS.includes(channel)) {
      return NextResponse.json(
        { success: false, error: `Invalid channel. Must be one of: ${VALID_CHANNELS.join(', ')}` },
        { status: 400 }
      );
    }

    if (!file || file.size === 0) {
      return NextResponse.json(
        { success: false, error: 'No file uploaded or file is empty.' },
        { status: 400 }
      );
    }

    // Save file to temp directory
    await mkdir(UPLOAD_DIR, { recursive: true });
    const timestamp = Date.now();
    const safeName = file.name.replace(/[^a-zA-Z0-9._-]/g, '_');
    savedPath = join(UPLOAD_DIR, `${timestamp}_${safeName}`);

    const buffer = Buffer.from(await file.arrayBuffer());
    await writeFile(savedPath, buffer);

    // Run the appropriate importer
    const CHANNEL_COMMANDS = getChannelCommands();
    const command = CHANNEL_COMMANDS[channel](savedPath);

    const output = await new Promise<string>((resolve, reject) => {
      exec(command, { timeout: TIMEOUT_MS, maxBuffer: 10 * 1024 * 1024 }, (error, stdout, stderr) => {
        const combinedOutput = [stdout, stderr].filter(Boolean).join('\n').trim();
        if (error) {
          // Include output even on error — importers print results before exiting
          const full = [combinedOutput, error.message].filter(Boolean).join('\n').trim();
          reject(new Error(full || 'Import command failed'));
          return;
        }
        resolve(combinedOutput || 'Import completed successfully');
      });
    });

    // Clean up temp file
    try { await unlink(savedPath); } catch { /* ignore */ }

    return NextResponse.json({ success: true, output, channel, filename: file.name });
  } catch (err) {
    // Clean up temp file on error
    if (savedPath) {
      try { await unlink(savedPath); } catch { /* ignore */ }
    }

    const message = err instanceof Error ? err.message : 'Unknown error';
    console.error(`[/api/upload] Error:`, message);

    return NextResponse.json(
      { success: false, error: message },
      { status: 500 }
    );
  }
}
