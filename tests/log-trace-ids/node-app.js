// App for tests/e2e/log-trace-ids.sh: one route that logs through pino, winston, bunyan and
// console.log, behind the golden tracing.js (loaded with --require).
const express = require('express');
const pino = require('pino')();
const winston = require('winston');
const bunyan = require('bunyan');

const winstonLogger = winston.createLogger({ transports: [new winston.transports.Console()] });
const bunyanLogger = bunyan.createLogger({ name: 'orders' });

const app = express();
app.get('/health', (req, res) => res.json({ ok: true }));
app.get('/orders/:id', (req, res) => {
  pino.info('pino order line');
  winstonLogger.info('winston order line');
  bunyanLogger.info('bunyan order line');
  console.log('console order line');
  res.json({ id: req.params.id });
});
app.listen(Number(process.env.PORT || 3920));
