// Sentry browser (client) initialization — BUG-17 / DEPLOY-09
//
// Loaded automatically by @sentry/nextjs on every page render.
// DSN is read from NEXT_PUBLIC_SENTRY_DSN so it ships to the browser.
// If the DSN is empty (local dev, CI), Sentry.init is a no-op.

import * as Sentry from '@sentry/nextjs';

const dsn = process.env.NEXT_PUBLIC_SENTRY_DSN;

if (dsn) {
  Sentry.init({
    dsn,
    // Keep perf sampling low — free tier quota.
    tracesSampleRate: 0.1,
    // Replay is opt-in; leave disabled until we have budget.
    replaysSessionSampleRate: 0,
    replaysOnErrorSampleRate: 0,
    // Tag environment so VPS errors don't mix with local dev.
    environment: process.env.NEXT_PUBLIC_SENTRY_ENV ?? 'production',
  });
}
