const crypto = require('crypto');
const carts = require('./carts');
const inventory = require('./inventory');
const pricing = require('./pricing');

// Work factor for the order signature, from config.
const SIGN_WORK = Number(process.env.SIGN_WORK || 1000);

function signOrder(order) {
  return crypto.pbkdf2Sync(JSON.stringify(order), 'order-signing', SIGN_WORK, 32, 'sha256').toString('hex');
}

async function checkout(cartId, userId) {
  const cart = carts.getCart(cartId);
  const lines = await inventory.loadLines(cart);
  const percentOff = await pricing.activeDiscount(userId);
  const order = { cartId, userId, lines, totalCents: pricing.total(lines, percentOff) };
  return { ...order, signature: signOrder(order), status: 'confirmed' };
}

module.exports = { checkout, signOrder };
