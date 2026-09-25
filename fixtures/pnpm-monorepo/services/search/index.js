const Fastify = require('fastify');

const app = Fastify();
app.get('/search', async () => ({ ok: true }));
app.listen({ port: process.env.PORT || 3000 });
