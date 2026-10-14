import { NextRequest, NextResponse } from 'next/server';

/**
 * Session-based Authentication Middleware
 * + Security Headers (SEC-01d)
 * + Rate Limiting (SEC-01e)
 * + HMAC Cookie Verification (BUG-14 / SEC-04, 2026-04-12)
 *
 * Protects all routes except /login and public API endpoints.
 * Users must log in via /login to access the dashboard.
 *
 * Session stored in httpOnly cookie, HMAC-signed with SESSION_SECRET.
 * Cookie value format: `<random_hex>.<hmac_hex>`. Middleware recomputes
 * the HMAC-SHA256 of the random half and constant-time-compares to the
 * hmac half using Web Crypto API `verify` (which is constant-time).
 *
 * BUG-14 (SEC-04, 2026-04-12): previously this middleware only checked
 * cookie existence, so a forged `moppity_session=ANYTHING` header was
 * accepted. Fixed by requiring a valid HMAC signature.
 *
 * Uses Web Crypto API (`globalThis.crypto.subtle`) instead of `node:crypto`
 * because Next.js 14 middleware runs on the Edge Runtime where node:crypto
 * is not supported.
 */

const SESSION_COOKIE_NAME = 'moppity_session';

// Routes that don't require authentication
const PUBLIC_PATHS = [
  '/login',
  '/api/auth/login',
  '/api/health',
];

// INFRA-04 owner-preflight harness: read-only export routes that accept
// MOPPITY_PREFLIGHT_TOKEN header in lieu of session cookie. Session check
// still applies if no token header (backward compatible). Add new export
// routes here when the harness expands. NEVER add mutation routes.
const PREFLIGHT_BYPASS_PATHS = [
  '/api/customers/export',
  '/api/skus/export',
  '/api/export/combined-data',
  '/api/legacy-data',
];

/**
 * Constant-time string equality. Both args must be strings. Returns false
 * fast-path on length mismatch (length is not a secret here — token length
 * is fixed by env config). XOR-fold to a single mismatch flag so the loop
 * runs the full length regardless of where mismatches occur.
 */
function constantTimeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let mismatch = 0;
  for (let i = 0; i < a.length; i++) {
    mismatch |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return mismatch === 0;
}

// ─── Rate Limiting (SEC-01e) ────────────────────────────────────────────
// In-memory store — resets on server restart. Fine for single-instance VPS.
const rateLimitStore = new Map<string, { count: number; resetAt: number }>();

const RATE_LIMITS = {
  login: { max: 5, windowMs: 60_000 },    // 5 login attempts/min
  api: { max: 60, windowMs: 60_000 },      // 60 API requests/min
};

let lastCleanup = 0;

function checkRateLimit(ip: string, type: 'login' | 'api'): boolean {
  const key = `${type}:${ip}`;
  const limit = RATE_LIMITS[type];
  const now = Date.now();

  // Lazy cleanup: purge stale entries every 5 minutes
  if (now - lastCleanup > 300_000) {
    lastCleanup = now;
    rateLimitStore.forEach((entry, k) => {
      if (now > entry.resetAt) rateLimitStore.delete(k);
    });
  }

  const entry = rateLimitStore.get(key);

  if (!entry || now > entry.resetAt) {
    rateLimitStore.set(key, { count: 1, resetAt: now + limit.windowMs });
    return true;
  }

  entry.count++;
  return entry.count <= limit.max;
}

// ─── Security Headers (SEC-01d) ─────────────────────────────────────────
function addSecurityHeaders(response: NextResponse): NextResponse {
  response.headers.set('X-Content-Type-Options', 'nosniff');
  response.headers.set('X-Frame-Options', 'DENY');
  response.headers.set('X-XSS-Protection', '1; mode=block');
  response.headers.set('Referrer-Policy', 'strict-origin-when-cross-origin');
  response.headers.set('Permissions-Policy', 'camera=(), microphone=(), geolocation=()');
  response.headers.set('Strict-Transport-Security', 'max-age=31536000; includeSubDomains');
  return response;
}

// ─── HMAC Cookie Verification (BUG-14 / SEC-04) ─────────────────────────
// Cache the imported HMAC key per secret string so we don't re-import on every
// request. Edge Runtime keeps module state alive between invocations.
let cachedSecret: string | null = null;
let cachedKey: CryptoKey | null = null;

/**
 * Read and validate SESSION_SECRET. Fail loud — never silent.
 * A missing/weak secret means every request fails closed (401), which
 * is the correct failure mode for an auth system.
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
 * Import SESSION_SECRET as a Web Crypto HMAC-SHA256 verify/sign key.
 * Cached so we don't reimport on every request.
 */
async function getHmacKey(): Promise<CryptoKey> {
  const secret = getSessionSecret();
  if (cachedKey && cachedSecret === secret) {
    return cachedKey;
  }

  const encoder = new TextEncoder();
  const key = await globalThis.crypto.subtle.importKey(
    'raw',
    encoder.encode(secret) as unknown as BufferSource,
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign', 'verify']
  );

  cachedSecret = secret;
  cachedKey = key;
  return key;
}

/**
 * Convert a hex string to a Uint8Array backed by a fresh ArrayBuffer.
 * Returns null on malformed input.
 *
 * The explicit `new ArrayBuffer(...)` backing is needed because some TS lib
 * configurations type `new Uint8Array(n)` as `Uint8Array<ArrayBufferLike>`,
 * which is not assignable to Web Crypto's `BufferSource`.
 */
function hexToBytes(hex: string): Uint8Array | null {
  if (hex.length % 2 !== 0) {
    return null;
  }
  const buf = new ArrayBuffer(hex.length / 2);
  const bytes = new Uint8Array(buf);
  for (let i = 0; i < bytes.length; i++) {
    const byte = parseInt(hex.slice(i * 2, i * 2 + 2), 16);
    if (Number.isNaN(byte)) {
      return null;
    }
    bytes[i] = byte;
  }
  return bytes;
}

/**
 * Verify that `cookieValue` has the shape `<random>.<hmac_hex>` and that
 * the hmac_hex half is HMAC-SHA256(random, SESSION_SECRET). Uses
 * `crypto.subtle.verify` which performs a constant-time comparison.
 *
 * Returns true only if the signature matches. Any other case (missing dot,
 * empty halves, non-hex hmac, wrong length, wrong signature, crypto error)
 * returns false. Fails closed on configuration errors.
 */
async function verifySessionCookie(cookieValue: string): Promise<boolean> {
  if (!cookieValue || typeof cookieValue !== 'string') {
    return false;
  }

  // Split on first dot. Old cookies (pre-BUG-14) have no dot → rejected.
  const dotIndex = cookieValue.indexOf('.');
  if (dotIndex === -1) {
    return false;
  }

  const random = cookieValue.slice(0, dotIndex);
  const providedHmacHex = cookieValue.slice(dotIndex + 1);

  if (!random || !providedHmacHex) {
    return false;
  }

  // HMAC-SHA256 is 32 bytes = 64 hex chars. Reject anything else up front.
  if (providedHmacHex.length !== 64) {
    return false;
  }
  if (!/^[0-9a-f]+$/i.test(providedHmacHex)) {
    return false;
  }

  const providedBytes = hexToBytes(providedHmacHex);
  if (!providedBytes || providedBytes.length !== 32) {
    return false;
  }

  let key: CryptoKey;
  try {
    key = await getHmacKey();
  } catch (err) {
    console.error('[middleware] SESSION_SECRET misconfigured:', err);
    // Fail closed — treat as invalid. API calls will get 401, pages redirect.
    return false;
  }

  try {
    const encoder = new TextEncoder();
    // crypto.subtle.verify is constant-time.
    // Casts to BufferSource work around a TS 5.x lib mismatch where
    // `Uint8Array` is typed as `Uint8Array<ArrayBufferLike>` which does not
    // satisfy `ArrayBufferView<ArrayBuffer>`. Runtime behavior is identical.
    return await globalThis.crypto.subtle.verify(
      'HMAC',
      key,
      providedBytes as unknown as BufferSource,
      encoder.encode(random) as unknown as BufferSource
    );
  } catch (err) {
    console.error('[middleware] HMAC verify threw:', err);
    return false;
  }
}

/**
 * Build an "unauthenticated" response that also clears the (bad) cookie so
 * the browser stops sending it. API routes get 401 JSON, pages get a 302
 * redirect to /login. Always wrapped in security headers.
 *
 * Graceful re-login (acceptance criterion 4): old valid-looking cookies
 * without a dot land here, user logs in again, done. No hard 500.
 */
function unauthorized(request: NextRequest): NextResponse {
  const { pathname } = request.nextUrl;
  let response: NextResponse;

  if (pathname.startsWith('/api/')) {
    response = NextResponse.json(
      { error: 'Authentication required' },
      { status: 401 }
    );
  } else {
    const loginUrl = new URL('/login', request.url);
    loginUrl.searchParams.set('redirect', pathname);
    response = NextResponse.redirect(loginUrl);
  }

  // Clear the bad cookie so the client doesn't keep presenting it.
  response.cookies.set(SESSION_COOKIE_NAME, '', {
    httpOnly: true,
    secure: process.env.HTTPS_ENABLED === 'true',
    sameSite: 'lax',
    maxAge: 0,
    path: '/',
  });

  return addSecurityHeaders(response);
}

// ─── Middleware ──────────────────────────────────────────────────────────
// RECONCILIATION-GATE (2026-05-17): the /reconciliation module is dev-stage
// and not validated. We block it SERVER-SIDE so the real page bundle and
// /api/reconciliation data never reach the browser — there is no hidden DOM
// to un-blur or delete in DevTools, because the real content is never sent.
// A client-side CSS overlay would be trivially removable; this is not.
// Reversible with zero code change: set RECONCILIATION_ENABLED=true in .env.
const RECONCILIATION_GATE_HTML = `<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Under development</title>
<style>
  html,body{margin:0;height:100%;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif}
  body{display:flex;align-items:center;justify-content:center;
    background:#0d1117;color:#e6edf3}
  .wrap{position:fixed;inset:0;display:flex;align-items:center;justify-content:center;
    background:rgba(13,17,23,.92);backdrop-filter:blur(14px);-webkit-backdrop-filter:blur(14px)}
  .card{max-width:520px;margin:24px;padding:40px;border-radius:16px;text-align:center;
    background:#161b22;border:1px solid #30363d;box-shadow:0 24px 60px rgba(0,0,0,.5)}
  .badge{font-size:13px;letter-spacing:.12em;text-transform:uppercase;color:#d29922;font-weight:700}
  h1{margin:14px 0 10px;font-size:24px}
  p{margin:0;color:#9da7b3;line-height:1.6;font-size:15px}
  .mark{margin-bottom:18px;font-size:34px}
</style></head>
<body><div class="wrap"><div class="card">
  <div class="mark">🚧</div>
  <div class="badge">Under development</div>
  <h1>Reconciliation is being finalised</h1>
  <p>The DWS Reconciliation module is not yet validated and is temporarily
  unavailable. It will be enabled once the figures are confirmed against the
  source records.</p>
</div></div></body></html>`;

function isReconciliationPath(pathname: string): boolean {
  return (
    pathname === '/reconciliation' ||
    pathname.startsWith('/reconciliation/') ||
    pathname === '/api/reconciliation' ||
    pathname.startsWith('/api/reconciliation/')
  );
}

export async function middleware(request: NextRequest) {
  const { pathname } = request.nextUrl;
  const ip = request.headers.get('x-forwarded-for')?.split(',')[0]?.trim()
    || request.headers.get('x-real-ip')
    || 'unknown';

  // Rate limit login attempts (applies BEFORE public-path bypass so brute force is capped)
  if (pathname === '/api/auth/login') {
    if (!checkRateLimit(ip, 'login')) {
      return addSecurityHeaders(
        NextResponse.json({ error: 'Too many login attempts. Try again in 1 minute.' }, { status: 429 })
      );
    }
  }

  // Rate limit all API routes
  if (pathname.startsWith('/api/')) {
    if (!checkRateLimit(ip, 'api')) {
      return addSecurityHeaders(
        NextResponse.json({ error: 'Rate limit exceeded. Try again shortly.' }, { status: 429 })
      );
    }
  }

  // ─── VIEW-ONLY GATE (demo mirror) ──────────────────────────────────────
  // The prospect-facing demo runs the SAME code with VIEW_ONLY=true. Every
  // mutating request is refused SERVER-SIDE (fail-closed): any method other
  // than GET/HEAD/OPTIONS to /api/* is 403 UNLESS the path is a known
  // read-only POST (login/logout, the predefined-SELECT query route, the AI
  // chat route). Runs BEFORE the public-path bypass so any unauthenticated
  // write route is blocked too. New write routes are
  // caught automatically — they are non-GET and not on the allow-list.
  // Data confidentiality is handled separately by pointing this instance at
  // the anonymized moppity_demo database; this gate protects demo integrity
  // (no edits, no /api/sync ETL trigger), not secrecy.
  if (process.env.VIEW_ONLY === 'true') {
    // Hide the /admin tooling tree entirely in the demo. Pages bounce to the
    // dashboard home; its write APIs are already refused by the block below.
    // Keeps the mirror "plain" without editing every admin component.
    if (pathname === '/admin' || pathname.startsWith('/admin/')) {
      return addSecurityHeaders(NextResponse.redirect(new URL('/', request.url)));
    }
    // Hide the raw Data Browser in the demo. GET /api/browse?table=X, /api/tables
    // and /api/legacy-data expose SELECT * / schema enumeration over every table —
    // incl. raw staging_* PII (Vinsight bank/tax, Xero contacts). moppity_demo
    // deliberately OMITS those raw tables, but we block the surface too (defense
    // in depth). /legacy-data page bounces home.
    if (pathname === '/legacy-data' || pathname.startsWith('/legacy-data/')) {
      return addSecurityHeaders(NextResponse.redirect(new URL('/', request.url)));
    }
    const RAW_BROWSE_APIS = ['/api/browse', '/api/tables', '/api/legacy-data'];
    if (
      pathname.startsWith('/api/') &&
      RAW_BROWSE_APIS.some((p) => pathname === p || pathname.startsWith(p + '/'))
    ) {
      return addSecurityHeaders(
        NextResponse.json({ error: 'Not available in the demo.' }, { status: 403 })
      );
    }
    // Refuse every mutating API request (fail-closed): any method other than
    // GET/HEAD/OPTIONS to /api/* is 403 UNLESS it is a known read-only POST
    // (login/logout, the predefined-SELECT query route, the AI chat route).
    // New write routes are caught automatically — non-GET and not allow-listed.
    if (pathname.startsWith('/api/')) {
      const method = request.method.toUpperCase();
      const isReadMethod = method === 'GET' || method === 'HEAD' || method === 'OPTIONS';
      const isReadOnlyPost =
        pathname === '/api/auth/login' ||
        pathname === '/api/auth/logout' ||
        pathname === '/api/query' ||
        pathname === '/api/chat';
      if (!isReadMethod && !isReadOnlyPost) {
        return addSecurityHeaders(
          NextResponse.json(
            { error: 'Read-only demo — editing is disabled.' },
            { status: 403 }
          )
        );
      }
    }
  }

  // Allow public paths
  if (PUBLIC_PATHS.some((path) => pathname.startsWith(path))) {
    return addSecurityHeaders(NextResponse.next());
  }

  // INFRA-04 owner-preflight token bypass — read-only export routes only.
  // If MOPPITY_PREFLIGHT_TOKEN env is set AND request carries matching
  // X-Preflight-Token header AND path is in the allow-list, skip session
  // check. Server-only token (.env), constant-time compare, never logged.
  // Allow-list is explicit for auditability — add new export routes here.
  if (PREFLIGHT_BYPASS_PATHS.some((path) => pathname === path || pathname.startsWith(path + '?'))) {
    const expectedToken = process.env.MOPPITY_PREFLIGHT_TOKEN;
    const providedToken = request.headers.get('x-preflight-token');
    if (
      expectedToken &&
      expectedToken.length >= 32 &&
      providedToken &&
      constantTimeEqual(providedToken, expectedToken)
    ) {
      return addSecurityHeaders(NextResponse.next());
    }
  }

  // Check for session cookie
  const sessionCookie = request.cookies.get(SESSION_COOKIE_NAME);

  if (!sessionCookie?.value) {
    return unauthorized(request);
  }

  // Verify HMAC signature. Any failure → 401 + clear cookie.
  const isValid = await verifySessionCookie(sessionCookie.value);
  if (!isValid) {
    return unauthorized(request);
  }

  // RECONCILIATION-GATE — applied AFTER auth so unauthenticated probes
  // (L4-lite / L8 / health) keep seeing the prior 401 unchanged (zero gate
  // drift). A logged-in user navigating here gets only the dev notice; the
  // real reconciliation page bundle and API data are never sent to them.
  if (process.env.RECONCILIATION_ENABLED !== 'true' && isReconciliationPath(pathname)) {
    if (pathname.startsWith('/api/')) {
      return addSecurityHeaders(
        NextResponse.json(
          { error: 'Reconciliation is under development and temporarily unavailable.' },
          { status: 503 }
        )
      );
    }
    return addSecurityHeaders(
      new NextResponse(RECONCILIATION_GATE_HTML, {
        status: 200,
        headers: { 'content-type': 'text/html; charset=utf-8' },
      })
    );
  }

  // Session is valid — allow request with security headers
  return addSecurityHeaders(NextResponse.next());
}

// Configure which routes use this middleware
export const config = {
  matcher: [
    '/((?!_next/static|_next/image|favicon.ico|images/).*)',
  ],
};
