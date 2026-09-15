const amqp = require('amqplib');

async function main() {
  const conn = await amqp.connect(process.env.AMQP_URL || 'amqp://localhost');
  const ch = await conn.createChannel();
  await ch.consume('billing', (msg) => msg && ch.ack(msg));
}

main();
