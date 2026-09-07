// Regression fixture for #124: a hand-wired `onRequestError` export that predates this plugin's
// involvement (commonly landed via the Sentry Next.js SDK's own setup instructions), pinned to a
// Next.js version where the hook cannot fire. `onRequestError` only exists from Next.js 15
// onward; on next@^14.2.0 (see package.json) this export is present but Next.js never calls it —
// dead code that instrumentation-gen/brownfield-auditor must flag (frameworkVersion below 15),
// not silently accept as "already covered" under the extend-never-clobber rule.
import * as Sentry from '@sentry/nextjs'

export async function register() {
  if (process.env.NEXT_RUNTIME === 'nodejs') {
    await import('./sentry.server.config')
  }
}

export const onRequestError = Sentry.captureRequestError
