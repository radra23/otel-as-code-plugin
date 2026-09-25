const functions = require('@google-cloud/functions-framework');
const { request } = require('undici');

// UNLIKE Azure Functions and Lambda, the Functions Framework runs a real in-process Express
// server (it depends on express and calls app.listen), so instrumentation-http and
// instrumentation-express already produce SERVER spans here. Wrapping these handlers the way
// the other two serverless hosts require would emit a SECOND SERVER span per request.
functions.http('sendNotification', async (req, res) => {
  const { statusCode } = await request('https://push.internal/send', {
    method: 'POST',
    body: JSON.stringify(req.body || {}),
  });
  res.status(statusCode === 200 ? 202 : 502).json({ queued: statusCode === 200 });
});

// A CloudEvent trigger still arrives as an HTTP POST to the same process, so it too gets a
// SERVER span — one describing the transport, not the event that caused it.
functions.cloudEvent('onBillingEvent', (cloudEvent) => {
  console.log(`billing event ${cloudEvent.id} (${cloudEvent.type})`);
});
