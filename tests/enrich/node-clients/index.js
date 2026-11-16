'use strict';
const express = require('express');
const store = require('./lib/store');

const app = express();

app.get('/health', (req, res) => res.json({ status: 'ok' }));

app.get('/items/:id', (req, res) => {
  const item = store.findItem(Number(req.params.id));
  if (!item) return res.status(404).json({ error: 'not found' });
  res.json(item);
});

const PORT = process.env.PORT || 3000;
app.listen(PORT, () => console.log(`enrich-catalog listening on port ${PORT}`));
