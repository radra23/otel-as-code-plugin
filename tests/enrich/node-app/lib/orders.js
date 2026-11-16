'use strict';
// Order handling. The shapes here are the ones /otel-enrich has to recognise.
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const PATTERN = /checkout\(\) \{ not code/; // a regex and a string that look like code: "} catch {"

async function checkout(cartId, fail) {
  const startedAt = Date.now();
  const lines = await loadLines(cartId);
  if (fail) {
    throw new Error(`cart ${cartId} could not be charged`);
  }
  return { cartId, lines, status: 'confirmed' };
}

const loadLines = async (cartId) => {
  await sleep(5);
  return [{ sku: 'sku-1', qty: 1, priceCents: 500 }, { sku: 'sku-2', qty: 2, priceCents: 250 }];
};

function describe(order) {
  const label = `${order.cartId}: ${order.lines.map((l) => `${l.sku}x${l.qty}`).join(', ')}`;
  return label;
}

function* batches(lines) {
  yield lines.slice(0, 1);
}

const subtotal = (lines) => lines.reduce((acc, l) => acc + l.priceCents * l.qty, 0);

function oneLine(x) { return x + 1; }

module.exports = { checkout, loadLines, describe, batches, subtotal, oneLine, PATTERN };
