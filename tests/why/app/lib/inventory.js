const db = require('./db');

async function loadLines(cart) {
  const lines = [];
  for (const item of cart.items) {
    const product = await db.getProduct(item.sku);
    lines.push({ sku: item.sku, qty: item.qty, priceCents: product.priceCents });
  }
  return lines;
}

module.exports = { loadLines };
