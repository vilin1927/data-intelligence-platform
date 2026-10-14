// Next.js instrumentation hook — BUG-17 / DEPLOY-09
//
// Next.js 14 calls register() once per runtime boot. We use it to load the
// correct Sentry config for whichever runtime the server is using so errors
// are captured without needing to import Sentry in every route handler.

export async function register() {
  if (process.env.NEXT_RUNTIME === 'nodejs') {
    await import('./sentry.server.config');
  }
  if (process.env.NEXT_RUNTIME === 'edge') {
    await import('./sentry.edge.config');
  }
}
