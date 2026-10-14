import { NextResponse } from 'next/server';
import { cookies } from 'next/headers';

export const dynamic = 'force-dynamic';

const SESSION_COOKIE_NAME = 'moppity_session';

/**
 * POST /api/auth/logout
 *
 * Clears the session cookie.
 */
export async function POST() {
  const cookieStore = await cookies();

  cookieStore.set(SESSION_COOKIE_NAME, '', {
    httpOnly: true,
    secure: process.env.HTTPS_ENABLED === 'true',
    sameSite: 'lax',
    maxAge: 0, // Expire immediately
    path: '/',
  });

  return NextResponse.json({ success: true });
}
