const { app } = require('@azure/functions');

// No outbound call at all, so this route emits NOTHING without a generated server-span
// wrapper — not an orphaned span, not a partial trace. Silence.
app.http('orderStatus', {
  methods: ['GET'],
  route: 'orders/{id}',
  authLevel: 'function',
  handler: async (req) => ({ status: 200, jsonBody: { id: req.params.id, state: 'pending' } }),
});
