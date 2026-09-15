const { app } = require('@azure/functions');

// Liveness probe — the one registration that SHOULD stay unwrapped. A span per health check
// is pure cost, and the field report named excluding it as a correct deliberate decision.
// Its presence is what makes the wrapped-over-total count meaningful rather than "all of them".
app.http('healthz', {
  methods: ['GET'],
  route: 'healthz',
  authLevel: 'anonymous',
  handler: async () => ({ status: 200, jsonBody: { status: 'ok' } }),
});
