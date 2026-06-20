const express = require('express');
const { traceOrder } = require('./tracing');
const app = express();

app.use(express.json());

app.post('/orders', (req, res) => {
  const { orderId } = req.body;
  traceOrder(orderId, 'POST');
  res.json({ orderId, status: 'processing' });
});

app.listen(3001, () => console.log('order-processor on :3001'));
