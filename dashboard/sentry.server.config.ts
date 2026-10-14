// Sentry server (Node runtime) initialization — BUG-17 / DEPLOY-09
//
// Loaded by instrumentation.ts when NEXT_RUNTIME === 'nodejs'. Captures
// errors inside route handlers, server components, and server actions.
//
// DSN precedence: SENTRY_DSN (server-only) > NEXT_PUBLIC_SENTRY_DSN.

import * as Sentry from '@sentry/nextjs';

const dsn = process.env.SENTRY_DSN ?? process.env.NEXT_PUBLIC_SENTRY_DSN;

if (dsn) {
  Sentry.init({
    dsn,
    tracesSampleRate: 0.1,
    environment: process.env.SENTRY_ENV ?? process.env.NODE_ENV ?? 'production',
    // Never ship PII off the box; we run on a single VPS with client data.
    sendDefaultPii: false,
  });
}
