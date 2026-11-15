const express = require('express');
const orders = require('./lib/orders');
const { Pricing } = require('./lib/pricing');

const app = express();
app.use(express.json());
const pricing = new Pricing(10);

app.get('/health', (req, res) => res.json({ status: 'ok' }));

app.post('/checkout', async (req, res, next) => {
  try {
    const order = await orders.checkout(req.body.cartId || 'cart-1', req.body.fail === true);
    res.json({ ...order, totalCents: pricing.total(order.lines) });
  } catch (err) {
    next(err);
  }
});

app.use((err, req, res, next) => res.status(500).json({ error: err.message }));

const PORT = process.env.PORT || 3000;
app.listen(PORT, () => console.log(`enrich-orders listening on port ${PORT}`));
