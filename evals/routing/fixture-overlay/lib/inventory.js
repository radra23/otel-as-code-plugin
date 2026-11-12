const db = require('./db');

async function loadLines(cartId) {
  const skus = Array.from({ length: 30 }, (_, i) => `sku-${i * 3}`);
  const lines = [];
  for (const sku of skus) {
    const product = await db.getProduct(sku);
    lines.push({ sku, qty: 1, priceCents: product.priceCents });
  }
  return lines;
}

module.exports = { loadLines };
