const express = require('express');

const app = express();
app.post('/checkout', (req, res) => res.status(201).json({ ok: true }));
app.get('/healthz', (_req, res) => res.json({ status: 'ok' }));
app.listen(process.env.PORT || 3000);
