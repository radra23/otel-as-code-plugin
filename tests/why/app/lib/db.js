// In-memory stand-in for the product catalogue database, with a realistic round trip.
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const ROUND_TRIP_MS = Number(process.env.DB_ROUND_TRIP_MS || 20);
const CATALOGUE = new Map(
  Array.from({ length: 100 }, (_, i) => [`sku-${i}`, { sku: `sku-${i}`, priceCents: 500 + i * 7 }])
);

async function getProduct(sku) {
  await sleep(ROUND_TRIP_MS);
  return CATALOGUE.get(sku);
}

module.exports = { getProduct };
