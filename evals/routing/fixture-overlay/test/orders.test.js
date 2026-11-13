const test = require('node:test');
const assert = require('node:assert');
const { orderTotal } = require('../lib/orders');

test('applies the discount and rounds to the nearest cent', () => {
  const lines = [{ priceCents: 999, qty: 1 }];
  assert.strictEqual(orderTotal(lines, 15), 849); // 849.15 -> 849
  assert.strictEqual(orderTotal([{ priceCents: 1999, qty: 1 }], 15), 1699); // 1699.15 -> 1699
  assert.strictEqual(orderTotal([{ priceCents: 1001, qty: 1 }], 50), 501); // 500.5 -> 501
});
