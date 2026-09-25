const { app } = require('@azure/functions');

// A non-HTTP trigger: there is no request to wrap, so the wrapper has to cover timer
// invocations too or scheduled work is silently uninstrumented.
app.timer('reconcile', {
  schedule: '0 */15 * * * *',
  handler: async (_timer, ctx) => {
    ctx.log('reconciling pending orders');
  },
});
