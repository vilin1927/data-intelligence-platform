// Sentry edge runtime initialization — BUG-17 / DEPLOY-09
//
// Loaded by instrumentation.ts when NEXT_RUNTIME === 'edge'. We do not run
// edge routes today, but adding this file ensures any future middleware or
// edge route is covered without a silent gap.

import * as Sentry from '@sentry/nextjs';

const dsn = process.env.SENTRY_DSN ?? process.env.NEXT_PUBLIC_SENTRY_DSN;

if (dsn) {
  Sentry.init({
    dsn,
    tracesSampleRate: 0.1,
    environment: process.env.SENTRY_ENV ?? process.env.NODE_ENV ?? 'production',
    sendDefaultPii: false,
  });
}
