const express = require('express');
const { loadLines } = require('./lib/inventory');
const { orderTotal } = require('./lib/orders');

const app = express();

app.use(express.json());

app.get('/health', (req, res) => {
  res.json({ status: 'ok' });
});

app.post('/checkout', async (req, res, next) => {
  try {
    const { cartId = 'cart-1', userId = 'user-1' } = req.body || {};
    const lines = await loadLines(cartId);
    const totalCents = orderTotal(lines, 10);
    res.json({ orderId: `order-${Date.now()}`, cartId, userId, totalCents, status: 'confirmed' });
  } catch (err) {
    next(err);
  }
});

app.get('/orders/:orderId', (req, res) => {
  res.json({ orderId: req.params.orderId, status: 'fulfilled' });
});

const PORT = process.env.PORT || 3000;
app.listen(PORT, () => {
  console.log(`checkout-api listening on port ${PORT}`);
});
