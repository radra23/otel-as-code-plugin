// Serves the compiled route handler (dist/orders.js, from `npm run build`) over node:http.
const http = require('node:http');
const { POST } = require('./dist/orders');

const server = http.createServer((req, res) => {
  if (req.url === '/health') {
    res.end('{"status":"ok"}');
    return;
  }
  let raw = '';
  req.on('data', (c) => { raw += c; });
  req.on('end', async () => {
    const out = await POST({ json: async () => JSON.parse(raw || '{}') });
    res.writeHead(out.status, { 'Content-Type': 'application/json' });
    res.end(out.body);
  });
});

const PORT = process.env.PORT || 3000;
server.listen(PORT, () => console.log(`enrich-ts-orders listening on port ${PORT}`));
