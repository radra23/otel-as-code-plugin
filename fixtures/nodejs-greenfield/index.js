const express = require('express');
const app = express();

app.use(express.json());

app.get('/health', (req, res) => {
  res.json({ status: 'ok' });
});

app.post('/checkout', (req, res) => {
  const { cartId, userId } = req.body;
  // Simulate checkout processing
  const orderId = `order-${Date.now()}`;
  res.json({ orderId, cartId, userId, status: 'confirmed' });
});

app.get('/orders/:orderId', (req, res) => {
  res.json({ orderId: req.params.orderId, status: 'fulfilled' });
});

const PORT = process.env.PORT || 3000;
app.listen(PORT, () => {
  console.log(`checkout-api listening on port ${PORT}`);
});
