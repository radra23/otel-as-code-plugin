// In-memory stand-in for the product catalogue database.
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const CATALOGUE = new Map(
  Array.from({ length: 100 }, (_, i) => [`sku-${i}`, { sku: `sku-${i}`, priceCents: 500 + i * 7 }])
);

async function getProduct(sku) {
  await sleep(20); // network round-trip to the database
  return CATALOGUE.get(sku);
}

module.exports = { getProduct };
