// next@^14.2.0 requires the instrumentation hook to be opted into explicitly (auto-detected only
// from Next.js 15+) — present here so this fixture is a realistic pre-15 project, not just a
// version number in package.json.
module.exports = {
  experimental: { instrumentationHook: true },
}
