import { NextRequest, NextResponse } from 'next/server';
import { cookies } from 'next/headers';
import crypto from 'crypto';

export const dynamic = 'force-dynamic';

// Session cookie config
const SESSION_COOKIE_NAME = 'moppity_session';
const SESSION_MAX_AGE = 60 * 60 * 24 * 7; // 7 days

/**
 * Validate SESSION_SECRET on module load. Fail loud — never silent.
 * A weak/missing secret means signed cookies are worthless.
 * BUG-14 (SEC-04): previously cookies were unsigned — any value was accepted.
 */
function getSessionSecret(): string {
  const secret = process.env.SESSION_SECRET;
  if (!secret) {
    throw new Error(
      'SESSION_SECRET env var is not set. Generate with: openssl rand -hex 32'
    );
  }
  if (secret.length < 32) {
    throw new Error(
      'SESSION_SECRET must be at least 32 characters (ideally 64 hex = 256 bits). ' +
        'Generate with: openssl rand -hex 32'
    );
  }
  return secret;
}

/**
 * Sign a random token with HMAC-SHA256.
 * Returns `<random>.<hmac_hex>` which is stored as the cookie value.
 * Middleware recomputes the HMAC on every request and compares via
 * timingSafeEqual. No server-side session store needed.
 */
function signSessionToken(random: string): string {
  const secret = getSessionSecret();
  const hmac = crypto.createHmac('sha256', secret).update(random).digest('hex');
  return `${random}.${hmac}`;
}

/**
 * POST /api/auth/login
 *
 * Validates password and creates session cookie.
 * Password is compared against DASHBOARD_PASSWORD env var.
 */
export async function POST(request: NextRequest) {
  try {
    const body = await request.json();
    const { password } = body;

    if (!password) {
      return NextResponse.json(
        { error: 'Password required' },
        { status: 400 }
      );
    }

    // Get password from environment
    const correctPassword = process.env.DASHBOARD_PASSWORD;

    if (!correctPassword) {
      console.error('[auth/login] DASHBOARD_PASSWORD not configured');
      return NextResponse.json(
        { error: 'Server configuration error' },
        { status: 500 }
      );
    }

    // Constant-time comparison to prevent timing attacks
    const passwordBuffer = Buffer.from(password);
    const correctBuffer = Buffer.from(correctPassword);

    const isValid = passwordBuffer.length === correctBuffer.length &&
      crypto.timingSafeEqual(passwordBuffer, correctBuffer);

    if (!isValid) {
      return NextResponse.json(
        { error: 'Invalid password' },
        { status: 401 }
      );
    }

    // Generate random token (64 hex chars = 256 bits) and HMAC-sign it.
    // Cookie value = `<random>.<hmac>`. Middleware validates HMAC on every
    // request. BUG-14 (SEC-04): previously the cookie was just the random
    // token with no signature, so forged cookies were accepted.
    const randomToken = crypto.randomBytes(32).toString('hex');
    let signedToken: string;
    try {
      signedToken = signSessionToken(randomToken);
    } catch (err) {
      console.error('[auth/login] SESSION_SECRET misconfigured:', err);
      return NextResponse.json(
        { error: 'Server configuration error' },
        { status: 500 }
      );
    }

    // Note: secure=false allows HTTP (internal VPS). Set HTTPS_ENABLED=true for HTTPS.
    const cookieStore = await cookies();
    cookieStore.set(SESSION_COOKIE_NAME, signedToken, {
      httpOnly: true,
      secure: process.env.HTTPS_ENABLED === 'true',
      sameSite: 'lax',
      maxAge: SESSION_MAX_AGE,
      path: '/',
    });

    return NextResponse.json({ success: true });

  } catch (error) {
    console.error('[auth/login] Error:', error);
    return NextResponse.json(
      { error: 'Login failed' },
      { status: 500 }
    );
  }
}
