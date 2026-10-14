export const dynamic = 'force-dynamic';

import { NextRequest, NextResponse } from 'next/server';
import { exec } from 'child_process';

// Build sync commands using environment variables
function getSyncCommands(): Record<string, string> {
  const DATABASE_URL = process.env.DATABASE_URL;
  const VINSIGHT_API_KEY = process.env.VINSIGHT_API_KEY;
  const XERO_CLIENT_ID = process.env.XERO_CLIENT_ID;
  const XERO_CLIENT_SECRET = process.env.XERO_CLIENT_SECRET;
  const XERO_TOKEN_FILE = process.env.XERO_TOKEN_FILE || '/opt/moppity/config/xero_tokens.json';
  const GOOGLE_API_KEY = process.env.GOOGLE_API_KEY;

  return {
    vinsight: `bash -c 'cd /opt/moppity && source venv/bin/activate && DATABASE_URL="${DATABASE_URL}" VINSIGHT_API_KEY="${VINSIGHT_API_KEY}" python3 -m connectors.vinsight'`,
    xero: `bash -c 'cd /opt/moppity && source venv/bin/activate && DATABASE_URL="${DATABASE_URL}" XERO_CLIENT_ID="${XERO_CLIENT_ID}" XERO_CLIENT_SECRET="${XERO_CLIENT_SECRET}" XERO_TOKEN_FILE="${XERO_TOKEN_FILE}" python3 -m connectors.xero'`,
    sheets: `bash -c 'cd /opt/moppity && source venv/bin/activate && DATABASE_URL="${DATABASE_URL}" GOOGLE_API_KEY="${GOOGLE_API_KEY}" python3 /opt/moppity/connectors/sheets_sync.py'`,
  };
}

const VALID_SOURCES = ['vinsight', 'xero', 'sheets'];

const TIMEOUT_MS = 120_000; // 120 seconds

export async function POST(request: NextRequest) {
  try {
    // Validate required environment variables
    const requiredEnvVars = ['DATABASE_URL'];
    const missingVars = requiredEnvVars.filter((v) => !process.env[v]);
    if (missingVars.length > 0) {
      console.error(`[/api/sync] Missing env vars: ${missingVars.join(', ')}`);
      return NextResponse.json(
        { success: false, error: 'Server configuration error. Check server logs.' },
        { status: 500 }
      );
    }

    const body = await request.json();
    const { source } = body;

    if (!source || !VALID_SOURCES.includes(source)) {
      return NextResponse.json(
        {
          success: false,
          error: `Invalid source. Must be one of: ${VALID_SOURCES.join(', ')}`,
        },
        { status: 400 }
      );
    }

    // Check source-specific env vars
    if (source === 'vinsight' && !process.env.VINSIGHT_API_KEY) {
      return NextResponse.json(
        { success: false, error: 'VINSIGHT_API_KEY not configured' },
        { status: 500 }
      );
    }
    if (source === 'xero' && (!process.env.XERO_CLIENT_ID || !process.env.XERO_CLIENT_SECRET)) {
      return NextResponse.json(
        { success: false, error: 'XERO credentials not configured' },
        { status: 500 }
      );
    }

    const SYNC_COMMANDS = getSyncCommands();
    const command = SYNC_COMMANDS[source];

    const output = await new Promise<string>((resolve, reject) => {
      exec(command, { timeout: TIMEOUT_MS, maxBuffer: 10 * 1024 * 1024 }, (error, stdout, stderr) => {
        if (error) {
          // Include both stdout and stderr in the error for debugging
          const combinedOutput = [stdout, stderr, error.message]
            .filter(Boolean)
            .join('\n')
            .trim();
          reject(new Error(combinedOutput || 'Command failed with no output'));
          return;
        }
        const combinedOutput = [stdout, stderr].filter(Boolean).join('\n').trim();
        resolve(combinedOutput || 'Sync completed successfully');
      });
    });

    return NextResponse.json({ success: true, output });
  } catch (err) {
    const message = err instanceof Error ? err.message : 'Unknown error';
    console.error(`[/api/sync] Error:`, message);

    return NextResponse.json(
      { success: false, error: message },
      { status: 500 }
    );
  }
}
