const { app } = require('@azure/functions');
const { request } = require('undici');

// The shape that makes the serverless gap invisible in the field: this handler makes an
// OUTBOUND call, so instrumentation-http produces a CLIENT span — with no inbound SERVER
// span to parent it, that span is orphaned and every call becomes its own one-span trace.
// It looks instrumented. It cannot be used to reconstruct a request.
app.http('createOrder', {
  methods: ['POST'],
  route: 'orders',
  authLevel: 'function',
  handler: async (req, ctx) => {
    const { statusCode } = await request('https://inventory.internal/reserve', {
      method: 'POST',
      body: await req.text(),
    });
    ctx.log(`reserve responded ${statusCode}`);
    return { status: statusCode === 200 ? 201 : 502, jsonBody: { reserved: statusCode === 200 } };
  },
});
