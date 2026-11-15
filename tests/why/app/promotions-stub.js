// The promotions service this app calls. Not traced: it is someone else's service.
const http = require('http');
const DELAY_MS = Number(process.env.PROMO_DELAY_MS || 5);
const PORT = Number(process.env.PROMO_PORT || 4600);
http
  .createServer((req, res) => {
    setTimeout(() => {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ percentOff: 10 }));
    }, DELAY_MS);
  })
  .listen(PORT, '127.0.0.1', () => console.log(`promotions stub on ${PORT}, delay ${DELAY_MS} ms`));
