const express = require('express');
const app = express();

app.use(express.json());

app.get('/health', (req, res) => {
  res.json({ status: 'ok' });
});

app.get('/items/:itemId', (req, res) => {
  res.json({ itemId: req.params.itemId, inStock: true });
});

const PORT = process.env.PORT || 3000;
app.listen(PORT, () => {
  console.log(`inventory-api listening on port ${PORT}`);
});
