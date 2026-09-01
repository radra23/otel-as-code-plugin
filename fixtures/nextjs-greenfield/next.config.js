/** @type {import('next').NextConfig} */
// Greenfield fixture — a minimal Next.js App Router app with NO OpenTelemetry. The e2e harness
// overlays the golden instrumentation.js + @vercel/otel dep on a throwaway copy (see
// tests/e2e/run.sh). Next.js 15 auto-detects instrumentation.js — no experimental flag needed.
const nextConfig = {
  eslint: { ignoreDuringBuilds: true },
};

module.exports = nextConfig;
