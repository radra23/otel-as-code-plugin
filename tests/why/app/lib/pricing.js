// Asks the promotions service for the active discount.
const http = require('http');
const PROMOTIONS_URL = process.env.PROMOTIONS_URL || 'http://127.0.0.1:4600/promotions';

function activeDiscount(userId) {
  return new Promise((resolve, reject) => {
    http
      .get(`${PROMOTIONS_URL}?user=${encodeURIComponent(userId)}`, (res) => {
        let body = '';
        res.on('data', (c) => (body += c));
        res.on('end', () => resolve(JSON.parse(body).percentOff || 0));
      })
      .on('error', reject);
  });
}

function total(lines, percentOff) {
  const subtotal = lines.reduce((acc, l) => acc + l.priceCents * l.qty, 0);
  return Math.round(subtotal * (1 - percentOff / 100));
}

module.exports = { activeDiscount, total };
