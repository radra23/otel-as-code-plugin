// Carts come from seed data; which seed is loaded is deployment config.
const path = require('path');
const SEED = process.env.CART_SEED || 'small';
const CARTS = require(path.join(__dirname, '..', 'data', `carts-${SEED}.json`));

function getCart(cartId) {
  return CARTS[cartId] || CARTS['cart-1'];
}

module.exports = { getCart };
