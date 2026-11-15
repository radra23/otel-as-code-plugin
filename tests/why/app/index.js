const express = require('express');
const orders = require('./lib/orders');

const app = express();
app.use(express.json());

app.get('/health', (req, res) => res.json({ status: 'ok' }));

app.post('/checkout', async (req, res, next) => {
  try {
    res.json(await orders.checkout(req.body.cartId || 'cart-1', req.body.userId || 'user-1'));
  } catch (err) {
    next(err);
  }
});

const PORT = process.env.PORT || 3000;
app.listen(PORT, () => console.log(`why-checkout listening on port ${PORT}`));
