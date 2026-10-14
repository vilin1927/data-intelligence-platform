export const dynamic = 'force-dynamic';

import { NextRequest, NextResponse } from 'next/server';
import { exec } from 'child_process';
import { writeFile, unlink, mkdir } from 'fs/promises';
import { join } from 'path';

const UPLOAD_DIR = '/tmp/moppity-uploads';
const VENV_PREFIX = 'cd /opt/moppity && source venv/bin/activate';
const VALID_CHANNELS = ['dws', 'alm', 'direct'];
const TIMEOUT_MS = 120_000; // 2 minutes for preview

/**
 * POST /api/upload/preview
 * Accepts file upload, runs Python preview (dry-run), returns parsed rows with match status.
 * Does NOT insert anything into the database.
 */
export async function POST(request: NextRequest) {
  let savedPath = '';

  try {
    const DATABASE_URL = process.env.DATABASE_URL;
    if (!DATABASE_URL) {
      return NextResponse.json(
        { success: false, error: 'Server configuration error: DATABASE_URL not set.' },
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

    // Save file to temp directory (keep it for confirm step)
    await mkdir(UPLOAD_DIR, { recursive: true });
    const timestamp = Date.now();
    const safeName = file.name.replace(/[^a-zA-Z0-9._-]/g, '_');
    savedPath = join(UPLOAD_DIR, `${timestamp}_${safeName}`);

    const buffer = Buffer.from(await file.arrayBuffer());
    await writeFile(savedPath, buffer);

    // Run Python preview (dry-run)
    const command = `bash -c '${VENV_PREFIX} && DATABASE_URL="${DATABASE_URL}" python3 -m etl.preview --channel ${channel} --file "${savedPath}"'`;

    const output = await new Promise<string>((resolve, reject) => {
      exec(command, { timeout: TIMEOUT_MS, maxBuffer: 50 * 1024 * 1024 }, (error, stdout, stderr) => {
        if (error) {
          const errMsg = [stderr, error.message].filter(Boolean).join('\n').trim();
          reject(new Error(errMsg || 'Preview failed'));
          return;
        }
        resolve(stdout);
      });
    });

    // Parse Python JSON output
    const previewData = JSON.parse(output);

    // Return preview data + the saved file path (needed for confirm step)
    return NextResponse.json({
      success: true,
      saved_path: savedPath, // Frontend sends this back on confirm
      ...previewData,
    });
  } catch (err) {
    // Don't delete file on error — user may want to retry
    const message = err instanceof Error ? err.message : 'Unknown error';
    console.error('[/api/upload/preview] Error:', message);

    return NextResponse.json(
      { success: false, error: message },
      { status: 500 }
    );
  }
}
